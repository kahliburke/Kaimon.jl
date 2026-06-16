# ─────────────────────────────────────────────────────────────────────────────
# Kaimon gate client · EvalState/EvalRecord/REPLConnection · display name · stalled diagnostics  (split from gate_client.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── Types ─────────────────────────────────────────────────────────────────────

@enum EvalState EVAL_IDLE EVAL_SENDING EVAL_STREAMING

mutable struct EvalRecord
    eval_id::String           # 8-hex-char ID
    session_key::String       # first 8 of session_id
    code::String              # original code (truncated to 500 chars for storage)
    started_at::Float64       # time()
    finished_at::Float64      # 0.0 while running
    last_update::Float64      # time() of last stash/progress/stdout activity
    status::Symbol            # :running, :completed, :failed, :timeout, :promoted
    result_preview::String    # first 500 chars of formatted result (empty while running)
    full_result::String       # complete formatted result (stored for promoted jobs)
    promoted::Bool            # true if promoted to background job
    stash::Dict{String,String} # key => repr(value) from KaimonGate.stash()
end

struct ProcessDiagnostics
    rss_mb::Float64
    cpu_pct::Float64
    sampled_at::DateTime
end

mutable struct REPLConnection
    session_id::String
    name::String
    display_name::String         # derived from project_path, with dedup suffix
    socket_path::String          # filesystem path to .sock
    endpoint::String             # ipc:// endpoint
    stream_endpoint::String      # ipc:// endpoint for PUB/SUB streaming
    req_channel::Union{RequestChannel,Nothing}  # persistent DEALER (protocol v2)
    sub_socket::Union{ZMQ.Socket,Nothing}   # SUB for streaming stdout/stderr
    zmq_context::Union{ZMQ.Context,Nothing} # shared context for socket recreation
    req_lock::ReentrantLock      # protects REQ socket access (connect/disconnect)
    eval_state::Ref{EvalState}   # current eval lifecycle state
    _eval_inboxes::Dict{String,Channel{Any}}  # per-request_id channels for concurrent evals
    _eval_inboxes_lock::ReentrantLock          # protects _eval_inboxes dict
    status::Symbol               # :connected, :evaluating, :disconnected, :connecting, :stalled
    project_path::String
    julia_version::String
    kaimon_version::String
    pid::Int
    connected_at::DateTime
    last_seen::DateTime
    last_ping::DateTime
    tool_call_count::Int
    pending_queue::Vector{Any}
    session_tools::Vector{Dict{String,Any}}  # Tool metadata from pong (dynamic)
    namespace::String            # Stable tool name prefix from gate (e.g. "gatetooltest")
    tools_hash::UInt64           # Hash of serialized tool metadata for change detection
    allow_restart::Bool          # Whether this session allows manage_repl restart
    allow_mirror::Bool           # Whether mirroring is allowed for this session
    mirror_repl::Bool            # Whether REPL mirroring is currently active
    debug_paused::Bool           # True when session is paused at an @infiltrate breakpoint
    diagnostics::Union{ProcessDiagnostics,Nothing}  # populated when stalled
    backtrace_sample::Union{String,Nothing}  # stack sample captured when stalled
    spawned_by::String           # "user" or "agent" — how this session was started
    auth_token::String           # TCP auth token (empty = no auth)
    server_pubkey::String        # CURVE server public key to pin (empty = plain TCP/IPC)
    stall_reason::Symbol         # why stalled (TCP): :none|:offline|:key_changed|:unresponsive
end

function REPLConnection(;
    session_id::String,
    name::String = "julia",
    display_name::String = "",
    socket_path::String = "",
    endpoint::String = "",
    stream_endpoint::String = "",
    project_path::String = "",
    julia_version::String = "",
    kaimon_version::String = "",
    pid::Int = 0,
    session_tools::Vector{Dict{String,Any}} = Dict{String,Any}[],
    namespace::String = "",
    tools_hash::UInt64 = UInt64(0),
    spawned_by::String = "user",
    auth_token::String = "",
    server_pubkey::String = "",
)
    t = now()
    REPLConnection(
        session_id,
        name,
        display_name,
        socket_path,
        endpoint,
        stream_endpoint,
        nothing,
        nothing,
        nothing,
        ReentrantLock(),
        Ref(EVAL_IDLE),
        Dict{String,Channel{Any}}(),
        ReentrantLock(),
        :disconnected,
        project_path,
        julia_version,
        kaimon_version,
        pid,
        t,
        t,
        t,
        0,
        [],
        session_tools,
        namespace,
        tools_hash,
        true,  # allow_restart — updated from pong
        true,  # allow_mirror — updated from pong
        false, # mirror_repl — updated from pong
        false, # debug_paused
        nothing, # diagnostics
        nothing, # backtrace_sample
        spawned_by,
        auth_token,
        server_pubkey,
        :none,  # stall_reason
    )
end

"""Apply CURVE client options to `sock` (before connect) when the connection pins
a server public key. Uses this Kaimon instance's persistent client keypair."""
function _apply_curve_client!(sock::ZMQ.Socket, conn::REPLConnection)
    isempty(conn.server_pubkey) && return
    cpub, csec = KaimonGate._load_or_create_client_keypair()
    KaimonGate.make_curve_client!(sock, conn.server_pubkey, cpub, csec)
    return nothing
end

"""TCP sessions have no local socket file — identified by empty socket_path."""
_is_tcp(conn::REPLConnection) = isempty(conn.socket_path)

"""Parse a `tcp://host:port` endpoint into `(host, port)`, or `nothing`."""
function _endpoint_host_port(endpoint::AbstractString)
    m = match(r"^tcp://(.+):(\d+)$", endpoint)
    m === nothing && return nothing
    return (String(m.captures[1]), parse(Int, m.captures[2]))
end

"""Best-effort: is `host:port` accepting TCP connections? Distinguishes a downed
gate (connection refused) from one that's up but failing our ZMQ/CURVE handshake
— a distinction that is invisible in-band (a wrong CURVE key just goes silent).
Returns false on refusal, unreachability, or timeout."""
function _tcp_port_open(host::AbstractString, port::Integer; timeout::Float64 = 1.5)
    done = Ref(false)
    ok = Ref(false)
    @async begin
        try
            s = Sockets.connect(host, port)
            close(s)
            ok[] = true
        catch
            ok[] = false
        finally
            done[] = true
        end
    end
    Base.timedwait(() -> done[], timeout; pollint = 0.05)
    return ok[]
end

"""Classify why a session just went stalled. TCP only (IPC stays `:none`):
- `:offline`      — TCP refused/unreachable: the gate process is down.
- `:key_changed`  — reachable, no pong, and we hold a pinned CURVE key: the
                    encrypted handshake is failing (key rotated, or MITM).
- `:unresponsive` — reachable, no pong, no pinned key: gate hung, or a CURVE
                    gate we connected to plain (needs a pin)."""
function _classify_stall(conn::REPLConnection)
    _is_tcp(conn) || return :none
    hp = _endpoint_host_port(conn.endpoint)
    hp === nothing && return :none
    host, port = hp
    if !_tcp_port_open(host, port)
        return :offline
    elseif !isempty(conn.server_pubkey)
        return :key_changed
    else
        return :unresponsive
    end
end

# ── Display Name Derivation ───────────────────────────────────────────────────

"""
    _derive_display_name(project_path, julia_version, existing_names; namespace="") -> String

Derive a short display name from the project path, deduplicating against
already-assigned names.  Rules:
  - Non-empty `namespace` → use it directly (e.g. extension "smlabnotes")
  - Non-empty project_path → `basename(project_path)` (e.g. "MyApp")
  - Global env or empty path → `@v<julia_version>` (e.g. "@v1.12")
  - Collisions get a `-2`, `-3`, … suffix
"""
function _derive_display_name(
    project_path::String,
    julia_version::String,
    existing_names::Vector{String};
    namespace::String = "",
)::String
    base = if !isempty(namespace)
        namespace
    elseif isempty(project_path) || project_path == homedir()
        # Global environment — use Julia version
        "@v$(julia_version)"
    else
        basename(project_path)
    end
    # Deduplicate: if "Foo" exists, try "Foo-2", "Foo-3", ...
    name = base
    n = 2
    while name in existing_names
        name = "$base-$n"
        n += 1
    end
    return name
end

# ── Stalled Session Diagnostics ──────────────────────────────────────────────

"""Probe a process for RSS and CPU% via `ps`. Returns `nothing` on failure."""
function _probe_process(pid::Int)::Union{ProcessDiagnostics,Nothing}
    try
        out = read(pipeline(`ps -o rss=,%cpu= -p $pid`; stderr=devnull), String)
        parts = split(strip(out))
        length(parts) >= 2 || return nothing
        rss_kb = parse(Float64, parts[1])
        cpu_pct = parse(Float64, parts[2])
        return ProcessDiagnostics(rss_kb / 1024.0, cpu_pct, now())
    catch
        return nothing
    end
end

"""
    trigger_backtrace(conn::REPLConnection) -> Union{String, Nothing}

Send SIGINFO/SIGUSR1 to a stalled session to trigger a profile peek.
The gate overrides `Profile.peek_report[]` to write to a file instead of
stderr. Waits briefly for the file to appear, then reads and returns it.

Returns the backtrace text, or `nothing` if the file doesn't appear in time.
"""
function trigger_backtrace(conn::REPLConnection)::Union{String,Nothing}
    bt_path = joinpath(KaimonGate.sock_dir(), "$(conn.session_id)-backtrace.txt")
    # Remove stale file from previous trigger
    rm(bt_path; force=true)
    # Send SIGINFO (macOS) or SIGUSR1 (Linux) via POSIX kill(2)
    sig = Sys.isbsd() ? 29 : 10
    ret = ccall(:kill, Cint, (Cint, Cint), conn.pid, sig)
    if ret != 0
        @debug "kill() failed" pid=conn.pid sig errno=Base.Libc.errno()
        return nothing
    end
    # Poll for the file (profile peek takes ~1s by default + write time)
    # Wait up to 5s — peek_duration default is 1s but writing can take time
    for _ in 1:50
        if isfile(bt_path) && filesize(bt_path) > 0
            sleep(0.3)  # let it finish writing
            try
                txt = read(bt_path, String)
                conn.backtrace_sample = txt
                return txt
            catch
                return nothing
            end
        end
        sleep(0.1)
    end
    return nothing
end

"""Return a human-readable activity assessment from process diagnostics."""
function _diagnose_activity(diag::ProcessDiagnostics)::String
    if diag.cpu_pct > 50
        "actively computing (compilation, GC, or heavy workload)"
    elseif diag.cpu_pct > 10
        "moderately active (may be compiling or performing background work)"
    elseif diag.cpu_pct < 1
        "process appears idle — may be deadlocked or waiting on I/O"
    else
        "low activity"
    end
end


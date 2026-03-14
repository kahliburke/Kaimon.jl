# ═══════════════════════════════════════════════════════════════════════════════
# Gate Client — TUI-side connection manager for REPL gate sockets
#
# Discovers gate sockets in ~/.cache/kaimon/sock/, connects via ZMQ REQ,
# sends eval requests, handles reconnection and health checks.
# ═══════════════════════════════════════════════════════════════════════════════

# ZMQ, Serialization, Dates, JSON are available from the Kaimon module scope.

# ── Types ─────────────────────────────────────────────────────────────────────

@enum EvalState EVAL_IDLE EVAL_SENDING EVAL_STREAMING

struct EvalRecord
    eval_id::String           # 8-hex-char ID
    session_key::String       # first 8 of session_id
    code::String              # original code (truncated to 500 chars for storage)
    started_at::Float64       # time()
    finished_at::Float64      # 0.0 while running
    status::Symbol            # :running, :completed, :failed, :timeout
    result_preview::String    # first 500 chars of formatted result (empty while running)
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
    req_socket::Union{ZMQ.Socket,Nothing}
    sub_socket::Union{ZMQ.Socket,Nothing}   # SUB for streaming stdout/stderr
    zmq_context::Union{ZMQ.Context,Nothing} # shared context for socket recreation
    req_lock::ReentrantLock      # protects REQ socket access (connect/disconnect)
    eval_state::Ref{EvalState}   # current eval lifecycle state
    _eval_inboxes::Dict{String,Channel{Any}}  # per-request_id channels for concurrent evals
    _eval_inboxes_lock::ReentrantLock          # protects _eval_inboxes dict
    status::Symbol               # :connected, :evaluating, :disconnected, :connecting, :stalled
    project_path::String
    julia_version::String
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
    pid::Int = 0,
    session_tools::Vector{Dict{String,Any}} = Dict{String,Any}[],
    namespace::String = "",
    tools_hash::UInt64 = UInt64(0),
    spawned_by::String = "user",
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
    )
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
    bt_path = joinpath(Gate.SOCK_DIR, "$(conn.session_id)-backtrace.txt")
    # Remove stale file from previous trigger
    rm(bt_path; force=true)
    # Send the signal
    sig = Sys.isbsd() ? 29 : 10
    try
        ccall(:uv_kill, Cint, (Cint, Cint), conn.pid, sig)
    catch
        return nothing
    end
    # Poll for the file (profile peek takes ~1s by default + write time)
    for _ in 1:30  # up to 3s
        if isfile(bt_path) && filesize(bt_path) > 0
            sleep(0.2)  # let it finish writing
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

# ── Connection Manager ────────────────────────────────────────────────────────

mutable struct ConnectionManager
    connections::Vector{REPLConnection}
    zmq_context::ZMQ.Context
    sock_dir::String
    running::Bool
    watcher_task::Union{Task,Nothing}
    health_task::Union{Task,Nothing}
    lock::ReentrantLock
    on_sessions_changed::Union{Function,Nothing}  # called when session list changes
    eval_history::Vector{EvalRecord}       # ring buffer, capped at 64 entries
    eval_history_lock::ReentrantLock
end

function ConnectionManager(; sock_dir::String = joinpath(kaimon_cache_dir(), "sock"))
    ConnectionManager(
        REPLConnection[],
        Context(),
        sock_dir,
        false,
        nothing,
        nothing,
        ReentrantLock(),
        nothing,
        EvalRecord[],
        ReentrantLock(),
    )
end

"""Fire the sessions-changed callback (if registered). Swallows errors."""
function _fire_sessions_changed(mgr::ConnectionManager)
    cb = mgr.on_sessions_changed
    cb !== nothing && try
        cb()
    catch
    end
end

# ── Eval History Helpers ─────────────────────────────────────────────────────

const _EVAL_HISTORY_MAX = 64

"""Record the start of an eval in the history ring buffer."""
function _record_eval_start!(mgr::ConnectionManager, eval_id::String, session_key::String, code::String)
    record = EvalRecord(
        eval_id,
        session_key,
        first(code, 500),
        time(),
        0.0,
        :running,
        "",
    )
    lock(mgr.eval_history_lock) do
        push!(mgr.eval_history, record)
        # Trim to max size
        while length(mgr.eval_history) > _EVAL_HISTORY_MAX
            popfirst!(mgr.eval_history)
        end
    end
    return nothing
end

"""Record the completion of an eval in the history ring buffer."""
function _record_eval_done!(mgr::ConnectionManager, eval_id::String, status::Symbol, result_preview::String)
    lock(mgr.eval_history_lock) do
        for (i, r) in enumerate(mgr.eval_history)
            if r.eval_id == eval_id
                mgr.eval_history[i] = EvalRecord(
                    r.eval_id,
                    r.session_key,
                    r.code,
                    r.started_at,
                    time(),
                    status,
                    first(result_preview, 500),
                )
                return
            end
        end
    end
    return nothing
end

# ── PID & Stale Session Helpers ──────────────────────────────────────────────

"""
    _is_pid_alive(pid::Int) -> Bool

Cross-platform check whether a process with the given PID exists.
Uses signal 0 (no actual signal sent) via libuv.
"""
function _is_pid_alive(pid::Int)
    pid > 0 || return false
    ccall(:uv_kill, Cint, (Cint, Cint), pid, 0) == 0 || return false
    # Zombie processes (defunct) still respond to signal 0.
    # Check the process state to filter them out.
    try
        state = strip(read(pipeline(`ps -o state= -p $pid`; stderr=devnull), String))
        !startswith(state, "Z")
    catch
        false
    end
end

"""
    _remove_session_files(sock_dir, session_id)

Delete .json, .sock, and -stream.sock files for a session.
"""
function _remove_session_files(sock_dir::String, session_id::String)
    for suffix in (".json", ".sock", "-stream.sock")
        f = joinpath(sock_dir, session_id * suffix)
        isfile(f) && try
            rm(f)
        catch
        end
    end
end

const _cleanup_done = Ref(false)

"""
    cleanup_stale_sessions!(sock_dir)

Scan the sock directory and remove files belonging to dead PIDs.
Also removes orphan `.sock` files with no corresponding `.json`.
"""
function cleanup_stale_sessions!(sock_dir::String)
    isdir(sock_dir) || return

    # Collect known session IDs from .json files
    json_sessions = Set{String}()

    for f in readdir(sock_dir)
        endswith(f, ".json") || continue
        session_id = replace(f, ".json" => "")
        push!(json_sessions, session_id)

        meta = try
            JSON.parsefile(joinpath(sock_dir, f))
        catch
            # Corrupt/unreadable JSON — remove it
            _remove_session_files(sock_dir, session_id)
            continue
        end

        pid = try
            parse(Int, string(get(meta, "pid", "0")))
        catch
            0
        end

        if !_is_pid_alive(pid)
            @debug "Cleaning stale session" session_id pid
            _remove_session_files(sock_dir, session_id)
            delete!(json_sessions, session_id)
        end
    end

    # Sweep orphan .sock files with no corresponding .json
    for f in readdir(sock_dir)
        endswith(f, ".sock") || continue
        # Skip non-session sockets (e.g. kaimon-service.sock)
        startswith(f, "kaimon-") && continue
        # Derive session_id: strip both "-stream.sock" and ".sock"
        session_id = if endswith(f, "-stream.sock")
            replace(f, "-stream.sock" => "")
        else
            replace(f, ".sock" => "")
        end
        if session_id ∉ json_sessions
            @debug "Removing orphan socket" f
            try
                rm(joinpath(sock_dir, f))
            catch
            end
        end
    end
end

# ── Socket Discovery ─────────────────────────────────────────────────────────

function discover_sessions(mgr::ConnectionManager)
    isdir(mgr.sock_dir) || return REPLConnection[]

    # One-time cleanup of stale sessions from previous crashes
    if !_cleanup_done[]
        _cleanup_done[] = true
        cleanup_stale_sessions!(mgr.sock_dir)
    end

    new_connections = REPLConnection[]

    # Map session_id → pid for sessions we already track.
    # Used to detect when a process restarts: same session_id, new PID.
    known_id_pids = lock(mgr.lock) do
        Dict(c.session_id => c.pid for c in mgr.connections)
    end

    # Track (name, pid) pairs already known — skip duplicate sessions from
    # the same process (e.g., stale socket files from a gate restart).
    known_name_pids = lock(mgr.lock) do
        Set((c.name, c.pid) for c in mgr.connections)
    end

    for f in readdir(mgr.sock_dir)
        endswith(f, ".json") || continue
        session_id = replace(f, ".json" => "")

        meta = try
            JSON.parsefile(joinpath(mgr.sock_dir, f))
        catch
            continue
        end

        pid = try
            parse(Int, string(get(meta, "pid", "0")))
        catch
            0
        end

        # Skip if we already track this session with the exact same PID —
        # nothing changed.  If the PID is different the process restarted:
        # don't skip so the watcher can replace the stale connection.
        if haskey(known_id_pids, session_id) && known_id_pids[session_id] == pid
            continue
        end

        # Skip and clean up sessions whose PID is no longer alive
        if !_is_pid_alive(pid)
            _remove_session_files(mgr.sock_dir, session_id)
            continue
        end

        name = get(meta, "name", "julia")

        # Skip duplicate sessions from the same process (same name + PID).
        # This happens when a gate restarts within the same process, leaving
        # a stale socket file alongside the new one.
        if (name, pid) in known_name_pids
            # Clean up the stale duplicate
            _remove_session_files(mgr.sock_dir, session_id)
            continue
        end

        conn = REPLConnection(
            session_id = session_id,
            name = name,
            socket_path = joinpath(mgr.sock_dir, "$(session_id).sock"),
            endpoint = get(
                meta,
                "endpoint",
                "ipc://$(joinpath(mgr.sock_dir, "$(session_id).sock"))",
            ),
            stream_endpoint = get(meta, "stream_endpoint", ""),
            project_path = get(meta, "project_path", ""),
            julia_version = get(meta, "julia_version", ""),
            pid = pid,
            spawned_by = get(meta, "spawned_by", "user"),
        )

        # If this session_id was already known (PID changed = process restarted),
        # preserve the existing display name so the session keeps its "Foo" name
        # instead of being assigned "Foo-2".
        # For genuinely new sessions derive a fresh deduplicated name.
        if haskey(known_id_pids, session_id)
            # Restarted session — steal the old conn's display name
            conn.display_name = lock(mgr.lock) do
                idx = findfirst(c -> c.session_id == session_id, mgr.connections)
                idx !== nothing ? mgr.connections[idx].display_name : ""
            end
        end
        if isempty(conn.display_name)
            # Derive display name from project_path, deduplicating against existing
            existing = lock(mgr.lock) do
                [c.display_name for c in mgr.connections]
            end
            # Also account for other new connections discovered in this batch
            append!(
                existing,
                [c.display_name for c in new_connections if !isempty(c.display_name)],
            )
            conn.display_name =
                _derive_display_name(conn.project_path, conn.julia_version, existing)
        end

        push!(known_name_pids, (name, pid))
        push!(new_connections, conn)
    end

    return new_connections
end

function connect!(mgr::ConnectionManager, conn::REPLConnection)
    conn.status = :connecting
    try
        socket = Socket(mgr.zmq_context, REQ)
        socket.rcvtimeo = 5000   # 5s timeout for responses
        socket.sndtimeo = 2000   # 2s timeout for sends
        socket.linger = 0        # don't block on close
        connect(socket, conn.endpoint)
        conn.req_socket = socket
        conn.zmq_context = mgr.zmq_context  # shared context for ephemeral sockets

        # Connect SUB socket for streaming output (non-blocking)
        if !isempty(conn.stream_endpoint)
            try
                sub = Socket(mgr.zmq_context, SUB)
                sub.rcvtimeo = 0  # non-blocking recv
                sub.linger = 0    # don't block on close
                sub.rcvhwm = 0    # unlimited receive buffer — never drop messages
                subscribe(sub, "")  # receive all messages
                connect(sub, conn.stream_endpoint)
                conn.sub_socket = sub
            catch e
                @debug "Failed to connect stream socket" exception = e
            end
        end

        conn.status = :connected
        conn.last_seen = now()
        # Apply runtime gate options from persisted preferences,
        # with per-session overrides taking priority.
        try
            session_prefs = load_session_prefs()
            mirror_val = resolve_session_pref(session_prefs, conn.project_path, :mirror_repl)
            mirror_enabled = mirror_val !== nothing ? mirror_val : get_gate_mirror_repl_preference()
            set_mirror_repl!(conn, mirror_enabled)
        catch e
            @debug "Failed to apply mirror_repl preference to gate" exception = e
        end
        return true
    catch e
        @debug "Failed to connect to gate" session_id = conn.session_id exception = e
        conn.status = :disconnected
        conn.req_socket = nothing
        return false
    end
end

function disconnect!(conn::REPLConnection)
    lock(conn.req_lock) do
        if conn.req_socket !== nothing
            try
                close(conn.req_socket)
            catch
            end
            conn.req_socket = nothing
        end
        if conn.sub_socket !== nothing
            try
                close(conn.sub_socket)
            catch
            end
            conn.sub_socket = nothing
        end
        conn.status = :disconnected
    end

    # Wake any pending eval callers so they fail immediately instead of
    # blocking until the hard timeout.  Closing a Channel causes `take!`
    # and `isready` to throw, which the polling loop handles gracefully.
    lock(conn._eval_inboxes_lock) do
        for (_, inbox) in conn._eval_inboxes
            try
                close(inbox)
            catch
            end
        end
    end
end

# ── Async REQ Send/Recv ──────────────────────────────────────────────────────
# Each request spawns its own async task with an ephemeral REQ socket. This
# means a stalled or timed-out request on one socket cannot block any other
# requests — they're fully independent. The ZMQ context is shared (thread-safe)
# and multiple REQ sockets can connect to the same REP endpoint simultaneously.

"""
    _req_send_recv(conn, request; caller_timeout=10.0) -> NamedTuple

Send a request to the gate asynchronously and wait up to `caller_timeout`
seconds for the response. Returns `(ok=true, response=...)` on success, or
`(ok=false, error="...")` on failure/timeout.

Internally spawns an async task with an ephemeral REQ socket, so the calling
task never blocks on ZMQ. Multiple concurrent calls are fully independent —
a stalled request cannot starve others.
"""
function _req_send_recv(conn::REPLConnection, request; caller_timeout::Float64 = 10.0)
    ctx = conn.zmq_context
    if ctx === nothing || conn.status ∉ (:connected, :evaluating, :stalled)
        return (ok = false, error = "Gate not connected (status=$(conn.status))")
    end

    endpoint = conn.endpoint
    io = IOBuffer()
    serialize(io, request)
    request_bytes = take!(io)

    # Response channel — the async task puts its result here
    response_ch = Channel{Any}(1)

    @async begin
        local sock = nothing
        try
            sock = Socket(ctx, REQ)
            sock.rcvtimeo = min(round(Int, caller_timeout * 1000), 30000)
            sock.sndtimeo = 2000
            sock.linger = 0
            connect(sock, endpoint)
            send(sock, Message(request_bytes))
            raw = recv(sock)
            response = deserialize(IOBuffer(raw))
            conn.last_seen = now()
            put!(response_ch, (ok = true, response = response))
        catch e
            msg = if e isa ZMQ.TimeoutError
                "Gate request timed out"
            else
                "Connection error: $(sprint(showerror, e))"
            end
            try
                put!(response_ch, (ok = false, error = msg))
            catch
            end
        finally
            if sock !== nothing
                try
                    close(sock)
                catch
                end
            end
        end
    end

    # Wait for result with timeout (polling Julia Channel, not ZMQ)
    deadline = time() + caller_timeout
    while time() < deadline
        if isready(response_ch)
            result = try
                take!(response_ch)
            catch
                return (ok = false, error = "Response channel error")
            end
            return result
        end
        sleep(0.05)
    end

    # Timed out — the async task may still complete later, but we don't care
    close(response_ch)
    return (ok = false, error = "Caller timeout after $(caller_timeout)s")
end

# ── Eval / Communication ─────────────────────────────────────────────────────

function eval_remote(
    conn::REPLConnection,
    code::String;
    timeout_ms::Int = 30000,
    display_code::String = code,
)
    _no_conn = (
        stdout = "",
        stderr = "",
        value_repr = "",
        exception = "Gate not connected (session=$(conn.session_id), status=$(conn.status))",
        backtrace = nothing,
    )
    if conn.status ∉ (:connected, :evaluating) || conn.req_socket === nothing
        return _no_conn
    end

    request = (type = :eval, code = code, display_code = display_code)
    result = _req_send_recv(conn, request; caller_timeout = timeout_ms / 1000.0)

    if result.ok
        conn.tool_call_count += 1
        return result.response
    else
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = result.error,
            backtrace = nothing,
        )
    end
end

"""
    eval_remote_async(conn, code; timeout_ms=120000, display_code=code, on_output=nothing)

Asynchronous eval: sends `:eval_async` via REQ, gets `:accepted` ack immediately,
then polls SUB socket for stdout/stderr/eval_complete/eval_error messages.

This avoids blocking the REQ socket during long-running evals, allowing health
pings and other operations to proceed.

`on_output` callback, if provided, is called as `on_output(channel::String, data::String)`
for each stdout/stderr chunk received during streaming.

Returns the same NamedTuple format as `eval_remote`.
"""
function eval_remote_async(
    conn::REPLConnection,
    code::String;
    timeout_ms::Int = 600000,  # 10 min hard timeout (keepalive messages sent meanwhile)
    display_code::String = code,
    on_output::Union{Function,Nothing} = nothing,
    request_id::String = "",  # caller-supplied ID (used for eval tracking)
)
    if conn.status ∉ (:connected, :evaluating) || conn.req_socket === nothing
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Gate not connected (session=$(conn.session_id), status=$(conn.status))",
            backtrace = nothing,
        )
    end

    # Generate a unique request ID to correlate response with this caller
    if isempty(request_id)
        request_id = bytes2hex(rand(UInt8, 8))
    end

    # Phase 1: Send eval_async request via REQ worker (non-blocking)
    conn.eval_state[] = EVAL_SENDING
    request = (
        type = :eval_async,
        code = code,
        display_code = display_code,
        request_id = request_id,
    )
    result = _req_send_recv(conn, request; caller_timeout = 10.0)

    ack = if result.ok
        result.response
    else
        (type = :error, message = result.error)
    end

    # Check handshake result
    ack_type = get(ack, :type, :error)
    if ack_type == :error
        conn.eval_state[] = EVAL_IDLE
        msg = get(ack, :message, "Unknown handshake error")
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = string(msg),
            backtrace = nothing,
        )
    end
    if ack_type != :accepted
        conn.eval_state[] = EVAL_IDLE
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Unexpected ack type: $ack_type",
            backtrace = nothing,
        )
    end

    # Phase 2: Wait for eval_complete/eval_error on a per-request inbox channel.
    # The TUI drain loop reads the SUB socket and routes messages by request_id
    # to the correct inbox so concurrent evals don't steal each other's results.
    conn.eval_state[] = EVAL_STREAMING

    # Register a per-request inbox channel.
    # Use unbounded capacity so put! in drain_stream_messages! never blocks
    # (a full Channel blocks the drain loop which holds mgr.lock, stalling the TUI).
    my_inbox = Channel{Any}(Inf)
    lock(conn._eval_inboxes_lock) do
        conn._eval_inboxes[request_id] = my_inbox
    end

    start_time = time()
    last_activity = start_time  # tracks last stdout/stderr/any message
    silence_threshold = 60.0    # send keepalive after this much silence
    keepalive_interval = 30.0   # seconds between repeated keepalives
    last_keepalive = 0.0
    hard_timeout = timeout_ms / 1000.0  # safety valve

    try
        while (time() - start_time) < hard_timeout
            silence = time() - last_activity

            # If no output for a while, send periodic keepalive progress
            # messages so the agent knows the session is still running.
            if on_output !== nothing && silence >= silence_threshold &&
               (time() - last_keepalive) >= keepalive_interval
                elapsed = time() - start_time
                mins = round(Int, elapsed ÷ 60)
                secs = round(Int, elapsed % 60)
                elapsed_str = mins > 0 ? "$(mins)m $(secs)s" : "$(secs)s"
                on_output("stderr",
                    "⏳ Evaluation running ($elapsed_str elapsed, no output for $(round(Int, silence))s). " *
                    "Session may be compiling, performing a long computation, or stuck.\n")
                last_keepalive = time()
            end

            # Bail immediately if the session disconnected while we were waiting
            if !isopen(my_inbox) || conn.status == :disconnected
                return (
                    stdout = "",
                    stderr = "",
                    value_repr = "",
                    exception = "Session disconnected during evaluation. The process may have exited or been restarted.",
                    backtrace = nothing,
                )
            end

            # Poll the per-request inbox
            msg = if isready(my_inbox)
                try
                    take!(my_inbox)
                catch
                    nothing
                end
            else
                sleep(0.1)
                nothing
            end

            msg === nothing && continue

            ch = string(get(msg, :channel, ""))
            data = get(msg, :data, "")

            if ch == "stdout" || ch == "stderr"
                last_activity = time()
                on_output !== nothing && on_output(ch, string(data))
            elseif ch == "breakpoint_hit"
                # The eval triggered an @infiltrate breakpoint. Parse the
                # breakpoint info and return it as a special non-exception
                # result so the MCP tool can inform the agent.
                bp_info = try
                    deserialize(IOBuffer(Vector{UInt8}(data)))
                catch
                    (file = "unknown", line = 0, locals = Dict(), locals_types = Dict())
                end
                bp_file = get(bp_info, :file, "unknown")
                bp_line = get(bp_info, :line, 0)
                n_locals = length(get(bp_info, :locals, Dict()))
                conn.tool_call_count += 1
                return (
                    stdout = "",
                    stderr = "",
                    value_repr = "⏸ Execution paused at breakpoint ($bp_file:$bp_line) — $n_locals local variables captured.\nUse debug_ctrl to inspect locals, debug_eval to evaluate expressions, and debug_ctrl(action=\"continue\") to resume.",
                    exception = nothing,
                    backtrace = nothing,
                )
            elseif ch == "eval_complete"
                result = try
                    deserialize(IOBuffer(Vector{UInt8}(data)))
                catch
                    (
                        stdout = "",
                        stderr = "",
                        value_repr = string(data),
                        exception = nothing,
                        backtrace = nothing,
                    )
                end
                conn.tool_call_count += 1
                return result
            elseif ch == "eval_error"
                result = try
                    deserialize(IOBuffer(Vector{UInt8}(data)))
                catch
                    (
                        stdout = "",
                        stderr = "",
                        value_repr = "",
                        exception = string(data),
                        backtrace = nothing,
                    )
                end
                conn.tool_call_count += 1
                return result
            end
        end

        # Hard timeout safety valve
        mins = round(Int, (time() - start_time) ÷ 60)
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Gate eval timed out after $(mins) minutes with no result. Unless you were anticipating that this would take considerable time, the session process may be stuck. You can use manage_repl to restart it.",
            backtrace = nothing,
        )
    catch e
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Error during async eval streaming: $(sprint(showerror, e))",
            backtrace = nothing,
        )
    finally
        # Always clean up: deregister inbox and update state
        lock(conn._eval_inboxes_lock) do
            delete!(conn._eval_inboxes, request_id)
        end
        # Only go IDLE if no other evals are pending
        if isempty(conn._eval_inboxes)
            conn.eval_state[] = EVAL_IDLE
        end
    end
end

function get_remote_options(conn::REPLConnection)
    if conn.status ∉ (:connected, :evaluating) || conn.req_socket === nothing
        return nothing
    end
    result = _req_send_recv(conn, (type = :get_options,); caller_timeout = 10.0)
    return result.ok ? result.response : nothing
end

function set_mirror_repl!(conn::REPLConnection, enabled::Bool)
    if conn.status ∉ (:connected, :evaluating) || conn.req_socket === nothing
        return false
    end
    result = _req_send_recv(conn, (type = :set_option, key = "mirror_repl", value = enabled); caller_timeout = 10.0)
    return result.ok && get(result.response, :type, :error) == :ok
end

"""
    set_tty!(conn, path) -> Bool

Send a `:set_tty` request to `conn`, detecting the terminal size, pausing the
remote shell via SIGSTOP, and disabling echo. Returns `true` on success.
Call `restore_tty!()` after the TUI exits to resume the shell and restore echo.
"""
function set_tty!(conn::REPLConnection, path::String)
    conn.status in (:connected, :evaluating) && conn.req_socket !== nothing || return false
    result = _req_send_recv(conn, (type = :set_tty, path = path); caller_timeout = 10.0)
    return result.ok && get(result.response, :type, :error) == :ok
end

function ping(conn::REPLConnection)
    if conn.status ∉ (:connected, :stalled) || conn.req_socket === nothing
        return nothing
    end

    # Short timeout — ping should be fast. If the worker is busy processing
    # a long eval handshake, the request queues behind it but we don't wait
    # forever. Return :busy equivalent (nothing) on timeout so the health
    # checker can fall back to PID liveness.
    result = _req_send_recv(conn, (type = :ping,); caller_timeout = 8.0)
    if result.ok
        conn.last_ping = now()
        return result.response
    else
        return nothing
    end
end


"""
    send_restart!(conn::REPLConnection) -> Bool

Send a `:restart` command to the gate. Returns `true` if the gate acknowledged.
The gate will exec a fresh Julia process after replying.
"""
function send_restart!(conn::REPLConnection)
    (conn.status ∉ (:connected, :evaluating) || conn.req_socket === nothing) && return false
    result = _req_send_recv(conn, (type = :restart, name = conn.name); caller_timeout = 10.0)
    return result.ok && get(result.response, :type, :error) == :ok
end

"""
    send_shutdown!(conn::REPLConnection) -> Bool

Send a `:shutdown` command to the gate. Returns `true` if the gate acknowledged.
The gate will stop its event loop and the Julia process will exit.
"""
function send_shutdown!(conn::REPLConnection)
    (conn.status ∉ (:connected, :evaluating, :stalled) || conn.req_socket === nothing) && return false
    result = _req_send_recv(conn, (type = :shutdown, name = conn.name); caller_timeout = 10.0)
    return result.ok && get(result.response, :type, :error) == :ok
end

# ── Debug Protocol ──────────────────────────────────────────────────────────

"""
    _gate_send_recv(conn::REPLConnection, request::NamedTuple) -> NamedTuple

Send a request to the gate and wait for a response. Lightweight wrapper for
non-eval protocol messages (debug_status, debug_eval, debug_continue).
"""
function _gate_send_recv(conn::REPLConnection, request::NamedTuple)
    if conn.status ∉ (:connected, :evaluating) || conn.req_socket === nothing
        return (type = :error, message = "Gate not connected (status=$(conn.status))")
    end
    result = _req_send_recv(conn, request; caller_timeout = 10.0)
    if result.ok
        return result.response
    else
        return (type = :error, message = result.error)
    end
end

"""
    drain_stream_messages!(mgr::ConnectionManager) -> Vector{NamedTuple}

Non-blocking drain of all pending streaming messages from connected gates.
Returns a vector of `(channel, data, session_name)` tuples.
"""
function drain_stream_messages!(mgr::ConnectionManager)
    messages = NamedTuple{(:channel, :data, :session_name),Tuple{String,String,String}}[]
    lock(mgr.lock) do
        for conn in mgr.connections
            conn.sub_socket === nothing && continue
            # Drain pending messages (non-blocking, capped per call).
            # The cap prevents holding mgr.lock too long when the gate produces
            # a burst of stdout — any remainder is picked up on the next render frame.
            n_drained = 0
            while n_drained < 500
                n_drained += 1
                raw = try
                    recv(conn.sub_socket)
                catch
                    break  # timeout or error — no more messages
                end
                msg = try
                    deserialize(IOBuffer(raw))
                catch
                    continue
                end
                ch = string(get(msg, :channel, "stdout"))
                data = string(get(msg, :data, ""))
                msg_request_id = string(get(msg, :request_id, ""))

                # Route eval and tool lifecycle messages to the correct per-request inbox
                # so concurrent eval_remote_async / _call_session_tool_async callers
                # each get their own results.
                routed = false
                if ch in (
                    "eval_complete",
                    "eval_error",
                    "tool_complete",
                    "tool_error",
                    "tool_progress",
                ) && !isempty(msg_request_id)
                    inbox = lock(conn._eval_inboxes_lock) do
                        get(conn._eval_inboxes, msg_request_id, nothing)
                    end
                    if inbox !== nothing
                        try
                            put!(inbox, (channel = ch, data = data))
                            routed = true
                        catch
                            # Channel full or closed
                        end
                    end
                end

                # Track debug paused state on the connection for fast checks
                if ch == "breakpoint_hit"
                    conn.debug_paused = true
                elseif ch == "breakpoint_resumed"
                    conn.debug_paused = false
                end

                if !routed
                    dname = isempty(conn.display_name) ? conn.name : conn.display_name
                    push!(messages, (channel = ch, data = data, session_name = dname))
                end

                # Forward stdout/stderr/breakpoint_hit to all active inboxes during
                # streaming so on_output callbacks (SSE progress) can see them.
                # These aren't tagged with request_id (they come from the REPL's
                # shared stdout/stderr, or from _breakpoint_hook which doesn't
                # know which eval triggered it), so broadcast to all.
                if ch in ("stdout", "stderr", "breakpoint_hit") && conn.eval_state[] == EVAL_STREAMING
                    lock(conn._eval_inboxes_lock) do
                        for (_, inbox) in conn._eval_inboxes
                            try
                                put!(inbox, (channel = ch, data = data))
                            catch
                            end
                        end
                    end
                end
            end
        end
    end
    return messages
end

# ── Background Tasks ──────────────────────────────────────────────────────────

function start!(mgr::ConnectionManager)
    mgr.running = true
    mkpath(mgr.sock_dir)

    # Socket directory watcher — discovers new gate sessions
    mgr.watcher_task = Threads.@spawn begin
        while mgr.running
            try
                new_conns = discover_sessions(mgr)
                added = false
                for conn in new_conns
                    if connect!(mgr, conn)
                        lock(mgr.lock) do
                            # If a stale connection for the same session_id exists
                            # (process restarted before the TUI cleaned it up),
                            # replace it in-place so we don't accumulate duplicates
                            # and the display name slot is freed atomically.
                            old_idx = findfirst(
                                c -> c.session_id == conn.session_id,
                                mgr.connections,
                            )
                            if old_idx !== nothing
                                old_conn = mgr.connections[old_idx]
                                _unregister_session_tools!(old_conn)
                                disconnect!(old_conn)
                                mgr.connections[old_idx] = conn
                                @debug "Replaced restarted gate connection" display_name =
                                    conn.display_name session_id = conn.session_id
                            else
                                push!(mgr.connections, conn)
                            end
                        end
                        added = true
                        @debug "Connected to gate" name = conn.name display_name =
                            conn.display_name session_id = conn.session_id
                    end
                end
                added && _fire_sessions_changed(mgr)
            catch e
                @debug "Watcher error" exception = e
            end
            sleep(2)  # Poll every 2 seconds
        end
    end

    # Health checker — pings connected sessions, removes stale ones.
    # IMPORTANT: We snapshot connections under the lock, then ping WITHOUT
    # holding the lock so we don't block the TUI render loop or stream drain.
    mgr.health_task = Threads.@spawn begin
        while mgr.running
            try
                # Snapshot current connections (cheap copy of references)
                conns = lock(mgr.lock) do
                    copy(mgr.connections)
                end

                to_remove = REPLConnection[]
                for conn in conns
                    if conn.status in (:connected, :evaluating, :stalled)
                        result = ping(conn)
                        if result === :busy
                            # Socket locked (eval in progress) — check PID
                            if !_is_pid_alive(conn.pid)
                                @debug "Gate process dead (busy socket), removing session" name = conn.name pid = conn.pid
                                disconnect!(conn)
                                push!(to_remove, conn)
                            elseif conn.status != :evaluating
                                conn.status = :evaluating
                                _fire_sessions_changed(mgr)
                            end
                        elseif result !== nothing
                            # Successful pong — session is idle and responsive
                            if conn.status != :connected
                                conn.diagnostics = nothing
                                conn.status = :connected
                                _fire_sessions_changed(mgr)
                            end
                            # Update project_path from live pong data
                            new_path = get(result, :project_path, "")
                            if !isempty(new_path) && new_path != conn.project_path
                                conn.project_path = new_path
                                existing = lock(mgr.lock) do
                                    [c.display_name for c in mgr.connections if c !== conn]
                                end
                                conn.display_name = _derive_display_name(
                                    new_path,
                                    conn.julia_version,
                                    existing;
                                    namespace = conn.namespace,
                                )
                                _fire_sessions_changed(mgr)
                            end

                            # Sync session tools from pong data (hash-based change detection)
                            pong_tools = get(result, :tools, nothing)
                            pong_ns = string(get(result, :namespace, ""))
                            if pong_tools isa Vector
                                new_hash = hash(pong_tools)
                                if new_hash != conn.tools_hash
                                    _unregister_session_tools!(conn)
                                    conn.session_tools = pong_tools
                                    conn.tools_hash = new_hash
                                    if !isempty(pong_ns)
                                        old_ns = conn.namespace
                                        conn.namespace = pong_ns
                                        _resolve_namespace!(conn, mgr)
                                        # Re-derive display name for extension sessions
                                        # once namespace is known (replaces project basename)
                                        if isempty(old_ns) && conn.spawned_by == "extension"
                                            existing = lock(mgr.lock) do
                                                [c.display_name for c in mgr.connections if c !== conn]
                                            end
                                            conn.display_name = _derive_display_name(
                                                conn.project_path,
                                                conn.julia_version,
                                                existing;
                                                namespace = pong_ns,
                                            )
                                        end
                                    end
                                    _register_session_tools!(conn)
                                    _fire_sessions_changed(mgr)
                                end
                            end

                            # Sync flags from pong
                            conn.allow_restart = Bool(get(result, :allow_restart, true))
                            conn.allow_mirror = Bool(get(result, :allow_mirror, true))
                            conn.mirror_repl = Bool(get(result, :mirror_repl, false))
                        else
                            # Check if the gate process is still alive.
                            # If it is, this is likely a GC pause or CPU stall —
                            # mark as stalled so the user sees why it's unresponsive.
                            # If the PID is gone, disconnect immediately.
                            if _is_pid_alive(conn.pid)
                                @debug "Gate ping failed but process alive (GC pause?), marking stalled" name = conn.name pid = conn.pid
                                conn.diagnostics = _probe_process(conn.pid)
                                if conn.status != :stalled
                                    conn.status = :stalled
                                    _fire_sessions_changed(mgr)
                                end
                            else
                                @debug "Gate process dead, removing session" name = conn.name pid = conn.pid
                                disconnect!(conn)
                                push!(to_remove, conn)
                            end
                        end
                    elseif conn.status == :disconnected
                        if ispath(conn.socket_path)
                            connect!(mgr, conn)
                        else
                            push!(to_remove, conn)
                        end
                    end
                end

                # Remove dead sessions under the lock
                if !isempty(to_remove)
                    lock(mgr.lock) do
                        for conn in to_remove
                            idx = findfirst(c -> c === conn, mgr.connections)
                            if idx !== nothing
                                # Unregister session tools before disconnect
                                _unregister_session_tools!(conn)
                                disconnect!(conn)
                                _remove_session_files(mgr.sock_dir, conn.session_id)
                                deleteat!(mgr.connections, idx)
                            end
                        end
                    end
                    _fire_sessions_changed(mgr)
                end
            catch e
                @debug "Health check error" exception = e
            end
            sleep(5)  # Health check every 5 seconds
        end
    end

    return mgr
end

function stop!(mgr::ConnectionManager)
    mgr.running = false

    # Disconnect all sockets immediately (linger=0 ensures close doesn't block)
    lock(mgr.lock) do
        for conn in mgr.connections
            disconnect!(conn)
        end
    end

    # Close the main ZMQ context.
    # All sockets have linger=0 so this should return promptly.
    try
        close(mgr.zmq_context)
    catch
    end

    # Let background tasks finish (they'll exit on next loop since running=false)
    Threads.@spawn begin
        for task in [mgr.watcher_task, mgr.health_task]
            if task !== nothing && !istaskdone(task)
                try
                    wait(task)
                catch
                end
            end
        end
    end
end

# ── Convenience ───────────────────────────────────────────────────────────────

"""
    get_connection(mgr, name_or_id) -> Union{REPLConnection, Nothing}

Find a connection by name or session ID.
"""
function get_connection(mgr::ConnectionManager, name_or_id::String)
    lock(mgr.lock) do
        for conn in mgr.connections
            if conn.name == name_or_id || conn.session_id == name_or_id
                return conn
            end
        end
        return nothing
    end
end

"""
    get_default_connection(mgr) -> Union{REPLConnection, Nothing}

Get the first connected REPL, or nothing if none available.
"""
function get_default_connection(mgr::ConnectionManager)
    lock(mgr.lock) do
        for conn in mgr.connections
            if conn.status in (:connected, :evaluating)
                return conn
            end
        end
        return nothing
    end
end

"""
    connected_sessions(mgr) -> Vector{REPLConnection}

List all currently connected sessions.
"""
function connected_sessions(mgr::ConnectionManager)
    lock(mgr.lock) do
        filter(c -> c.status in (:connected, :evaluating, :stalled), mgr.connections)
    end
end

"""First 8 chars of the session UUID — short, unique, token-efficient."""
short_key(conn::REPLConnection) = first(conn.session_id, 8)

"""Look up a connection by its 8-char short key. Returns nothing if not found.
Includes stalled sessions so tools can still interact with them."""
function get_connection_by_key(mgr::ConnectionManager, key::String)
    lock(mgr.lock) do
        for conn in mgr.connections
            if conn.status in (:connected, :evaluating, :stalled) && startswith(conn.session_id, key)
                return conn
            end
        end
        return nothing
    end
end

# ── Session-Scoped Tool Support ──────────────────────────────────────────────
# Translates reflected Julia type metadata from gate sessions into MCP-compliant
# JSON schemas and creates MCPTool wrappers that route calls through the gate.

"""
    _type_meta_to_schema(meta::Dict) -> Dict{String,Any}

Convert a Julia type metadata Dict (from `_type_to_meta` on the gate side)
into an MCP-compliant JSON schema fragment.
"""
function _type_meta_to_schema(meta::Dict)::Dict{String,Any}
    kind = get(meta, "kind", "any")

    kind == "string" && return Dict{String,Any}("type" => "string")
    kind == "integer" && return Dict{String,Any}("type" => "integer")
    kind == "number" && return Dict{String,Any}("type" => "number")
    kind == "boolean" && return Dict{String,Any}("type" => "boolean")

    if kind == "enum"
        schema = Dict{String,Any}(
            "type" => "string",
            "enum" => get(meta, "enum_values", String[]),
        )
        desc = get(meta, "description", "")
        !isempty(desc) && (schema["description"] = desc)
        return schema
    end

    if kind == "struct"
        props = Dict{String,Any}()
        required = String[]
        for field in get(meta, "fields", Dict[])
            fname = get(field, "name", "")
            isempty(fname) && continue
            fprop = _type_meta_to_schema(get(field, "type_meta", Dict()))
            fdesc = get(field, "description", "")
            !isempty(fdesc) && (fprop["description"] = fdesc)
            props[fname] = fprop
            # Struct fields are always required (unless their type is Union{T,Nothing})
            field_kind = get(get(field, "type_meta", Dict()), "kind", "any")
            push!(required, fname)
        end
        schema = Dict{String,Any}("type" => "object", "properties" => props)
        !isempty(required) && (schema["required"] = required)
        desc = get(meta, "description", "")
        !isempty(desc) && (schema["description"] = desc)
        return schema
    end

    if kind == "array"
        elem_meta = get(meta, "element_type", Dict())
        return Dict{String,Any}(
            "type" => "array",
            "items" => _type_meta_to_schema(elem_meta),
        )
    end

    # "any" or unrecognized → string fallback
    jt = get(meta, "julia_type", "Any")
    schema = Dict{String,Any}("type" => "string")
    jt != "Any" && jt != "String" && (schema["description"] = "Julia type: $jt")
    return schema
end

"""
    _reflect_to_schema(tool_meta::Dict) -> Dict{String,Any}

Convert reflected tool metadata into an MCP-compliant `inputSchema` Dict.
"""
function _reflect_to_schema(tool_meta::Dict)::Dict{String,Any}
    properties = Dict{String,Any}()
    required = String[]

    for arg in get(tool_meta, "arguments", Dict[])
        name = get(arg, "name", "")
        isempty(name) && continue
        prop = _type_meta_to_schema(get(arg, "type_meta", Dict()))
        properties[name] = prop
        if get(arg, "required", false)
            push!(required, name)
        end
    end

    schema = Dict{String,Any}("type" => "object", "properties" => properties)
    !isempty(required) && (schema["required"] = required)
    return schema
end

"""
    _call_session_tool(conn, tool_name, args) -> String

Send a `:tool_call` message through the gate's ZMQ REQ socket and return
the result as a string.
"""
function _call_session_tool(conn::REPLConnection, tool_name::String, args::Dict)
    if conn.status ∉ (:connected, :evaluating) || conn.req_socket === nothing
        return "Error: Gate not connected (session=$(conn.session_id))"
    end

    request = (
        type = :tool_call,
        name = tool_name,
        arguments = Dict{String,Any}(string(k) => v for (k, v) in args),
    )
    result = _req_send_recv(conn, request; caller_timeout = 30.0)
    if result.ok
        conn.tool_call_count += 1
        resp_type = get(result.response, :type, :error)
        if resp_type == :error
            return "Error: $(get(result.response, :message, "unknown"))"
        end
        return string(get(result.response, :value, ""))
    else
        return "Error: $(result.error)"
    end
end

"""
    _call_session_tool_async(conn, tool_name, args; timeout_ms=300000, on_progress=nothing)

Asynchronous session tool call: sends `:tool_call_async` via REQ, gets `:accepted`
ack immediately, then polls SUB socket for tool_complete/tool_error/tool_progress
messages via a per-request inbox.

This avoids blocking the REQ socket during long-running tool calls, allowing health
pings and other operations to proceed. Mirrors the `eval_remote_async` pattern.

`on_progress` callback, if provided, is called as `on_progress(message::String)`
for each progress update received during streaming.

Returns the tool result as a String.
"""
function _call_session_tool_async(
    conn::REPLConnection,
    tool_name::String,
    args::Dict;
    timeout_ms::Int = 300_000,
    on_progress::Union{Function,Nothing} = nothing,
)
    if conn.status ∉ (:connected, :evaluating) || conn.req_socket === nothing
        return "Error: Gate not connected (session=$(conn.session_id))"
    end

    # Generate a unique request ID to correlate response with this caller
    request_id = bytes2hex(rand(UInt8, 8))

    # Phase 1: Send tool_call_async request via REQ worker (non-blocking)
    request = (
        type = :tool_call_async,
        name = tool_name,
        arguments = Dict{String,Any}(string(k) => v for (k, v) in args),
        request_id = request_id,
    )
    hs_result = _req_send_recv(conn, request; caller_timeout = 10.0)

    ack = if hs_result.ok
        hs_result.response
    else
        (type = :error, message = hs_result.error)
    end

    # Check handshake result
    ack_type = get(ack, :type, :error)
    if ack_type == :error
        return "Error: $(get(ack, :message, "Unknown handshake error"))"
    end
    if ack_type != :accepted
        return "Error: Unexpected ack type: $ack_type"
    end

    # Phase 2: Wait for tool_complete/tool_error on a per-request inbox channel.
    # The drain loop reads the SUB socket and routes messages by request_id.
    # Use unbounded capacity so put! in drain_stream_messages! never blocks.
    my_inbox = Channel{Any}(Inf)
    lock(conn._eval_inboxes_lock) do
        conn._eval_inboxes[request_id] = my_inbox
    end

    try
        deadline = time() + timeout_ms / 1000.0
        while time() < deadline
            if !isopen(my_inbox) || conn.status == :disconnected
                return "Error: Session disconnected during tool call. The process may have exited or been restarted."
            end

            msg = if isready(my_inbox)
                try
                    take!(my_inbox)
                catch
                    nothing
                end
            else
                sleep(0.1)
                nothing
            end

            msg === nothing && continue

            ch = string(get(msg, :channel, ""))
            data = string(get(msg, :data, ""))

            if ch == "tool_progress"
                on_progress !== nothing && on_progress(data)
            elseif ch == "tool_complete"
                conn.tool_call_count += 1
                return data
            elseif ch == "tool_error"
                conn.tool_call_count += 1
                return "Error: $data"
            end
        end
        return "Error: Gate tool call timed out after $(timeout_ms)ms"
    finally
        lock(conn._eval_inboxes_lock) do
            delete!(conn._eval_inboxes, request_id)
        end
    end
end

"""
    _create_session_tools(conn::REPLConnection) -> Vector{MCPTool}

Create MCPTool wrappers for all session-scoped tools declared by a gate session.
Tool names are namespaced by the connection's namespace: `<namespace>.<tool_name>`.
"""
function _create_session_tools(conn::REPLConnection)::Vector{MCPTool}
    tools = MCPTool[]
    prefix = conn.namespace

    for tool_meta in conn.session_tools
        raw_name = get(tool_meta, "name", "")
        isempty(raw_name) && continue

        tool_name = "$(prefix).$(raw_name)"
        tool_id = Symbol(replace(tool_name, "." => "_"))
        description = get(tool_meta, "description", "Session tool: $raw_name")
        schema = _reflect_to_schema(tool_meta)

        # Capture raw_name and conn in closure
        local_name = raw_name
        local_conn = conn
        handler = function (args)
            on_progress = pop!(args, "_on_progress", nothing)
            if on_progress !== nothing
                _call_session_tool_async(
                    local_conn,
                    local_name,
                    args;
                    on_progress = on_progress,
                )
            else
                _call_session_tool(local_conn, local_name, args)
            end
        end

        tool_title = get(tool_meta, "title", join(titlecase.(split(raw_name, "_")), " "))
        push!(tools, MCPTool(tool_id, tool_name, tool_title, description, schema, handler))
    end

    return tools
end

"""
    _resolve_namespace!(conn, mgr) -> String

Resolve namespace collisions. If another connected session already owns the
same namespace prefix, add a dedup suffix (_2, _3, …). Updates `conn.namespace`
in place and returns the final namespace.

Extension sessions (spawned_by="extension") are singletons by namespace:
when a new extension claims a namespace already held by a stale extension
connection, the old connection is evicted instead of deduplicating.
"""
function _resolve_namespace!(conn::REPLConnection, mgr::ConnectionManager)
    base_ns = conn.namespace
    isempty(base_ns) && return base_ns

    # Find colliding connections
    colliders = lock(mgr.lock) do
        [
            c for c in mgr.connections if
            c !== conn && c.namespace == base_ns && c.status in (:connected, :evaluating, :stalled, :connecting)
        ]
    end

    if isempty(colliders)
        return base_ns
    end

    # Extension sessions are singletons — evict stale extension connections
    # with the same namespace instead of deduplicating
    if conn.spawned_by == "extension"
        lock(mgr.lock) do
            for old in colliders
                if old.spawned_by == "extension"
                    @debug "Evicting stale extension connection" namespace = base_ns old_key = short_key(old) new_key = short_key(conn)
                    _unregister_session_tools!(old)
                    disconnect!(old)
                    idx = findfirst(c -> c === old, mgr.connections)
                    if idx !== nothing
                        _remove_session_files(mgr.sock_dir, old.session_id)
                        deleteat!(mgr.connections, idx)
                    end
                end
            end
        end
        _fire_sessions_changed(mgr)
        return base_ns
    end

    # Non-extension collision — add dedup suffix
    taken = lock(mgr.lock) do
        Set(
            c.namespace for c in mgr.connections if
            c !== conn && c.status in (:connected, :evaluating) && !isempty(c.namespace)
        )
    end
    n = 2
    candidate = "$(base_ns)_$n"
    while candidate in taken
        n += 1
        candidate = "$(base_ns)_$n"
    end
    conn.namespace = candidate
    @debug "Namespace collision resolved" original = base_ns resolved = candidate
    return candidate
end

"""
    _register_session_tools!(conn::REPLConnection)

Create MCPTool wrappers for session tools and register them in the global
tool registry. Sends `tools/list_changed` notification.
"""
function _register_session_tools!(conn::REPLConnection)
    isempty(conn.session_tools) && return

    session_mcp_tools = _create_session_tools(conn)
    isempty(session_mcp_tools) && return

    _register_dynamic_tools!(session_mcp_tools)
    @debug "Registered session tools" session = short_key(conn) namespace = conn.namespace count =
        length(session_mcp_tools)
end

"""
    _unregister_session_tools!(conn::REPLConnection)

Remove all MCPTool wrappers for a session from the global tool registry.
Sends `tools/list_changed` notification.
"""
function _unregister_session_tools!(conn::REPLConnection)
    isempty(conn.session_tools) && return
    prefix = "$(conn.namespace)."
    _unregister_dynamic_tools!(prefix)
    @debug "Unregistered session tools" session = short_key(conn) namespace = conn.namespace
end

# ─────────────────────────────────────────────────────────────────────────────
# Kaimon gate client · PID & stale-session helpers · socket discovery  (split from gate_client.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── PID & Stale Session Helpers ──────────────────────────────────────────────

"""
    _is_pid_alive(pid::Int) -> Bool

Cross-platform check whether a process with the given PID exists.
Uses signal 0 (no actual signal sent) via libuv.
"""
function _is_pid_alive(pid::Int)
    pid > 0 || return false
    ccall(:uv_kill, Cint, (Cint, Cint), pid, 0) == 0 || return false
    # Zombie processes (defunct) still respond to signal 0; filter them via process state.
    # Windows has no `ps` and no Unix zombies, so the uv_kill existence check suffices —
    # WITHOUT this the `ps` call below throws, the catch returns false, and EVERY live
    # process reads as dead (reaping live local sessions during discovery).
    Sys.iswindows() && return true
    try
        state = strip(read(pipeline(`ps -o state= -p $pid`; stderr=devnull), String))
        !startswith(state, "Z")
    catch
        false
    end
end

"""
    _is_local_host(host::AbstractString) -> Bool

Whether `host` refers to the local machine — `127.0.0.1`, `::1`, `localhost`,
or empty. Only for these does a PID-liveness check make sense; a genuinely
remote TCP gate's PID belongs to another machine and must never be reaped here.
"""
function _is_local_host(host::AbstractString)
    h = lowercase(strip(host))
    return h == "" || h == "127.0.0.1" || h == "::1" || h == "localhost" ||
           h == "0.0.0.0" || startswith(h, "127.")
end

"""
    _endpoint_host(endpoint::AbstractString) -> String

Extract the host from a `tcp://host:port` endpoint (returns "" if not parseable).
Handles bracketed IPv6 (`tcp://[::1]:9100`).
"""
function _endpoint_host(endpoint::AbstractString)
    m = match(r"^tcp://(\[[^\]]+\]|[^:/]+)", endpoint)
    m === nothing && return ""
    return strip(m.captures[1], ['[', ']'])
end

"`host:port` of a TCP gate, with every loopback spelling of the host (`localhost`, `127.0.0.1`, …) written alike."
_gate_address_key(host::AbstractString, port) =
    string(_is_local_host(host) ? "loopback" : lowercase(strip(host)), ":", port)

"""
    _same_machine(machine, endpoint) -> Bool

Whether a TCP gate runs where this process can look up its PID. Decided by the identity the gate
reports in its pong (`KaimonGate.machine_id()`), since a loopback address does not settle it: an
SSH tunnel, a container's port-forward and WSL1's loopback shared with Windows all put another
machine's gate there. A gate too old to report one is judged by its address.
"""
_same_machine(machine::AbstractString, endpoint::AbstractString) =
    isempty(machine) ? _is_local_host(_endpoint_host(endpoint)) : machine == KaimonGate.machine_id()

# ── Gates on the Windows side of WSL ──────────────────────────────────────────

const _WINDOWS_SOCK_DIR = Ref{Union{String,Nothing}}(nothing)

"""
    _windows_sock_dir() -> String

Where gates on the Windows side of this WSL machine write their session files, or `""`. Only when
Linux and Windows share one loopback (WSL1, or WSL2 with mirrored networking): under NAT, a
Windows gate's 127.0.0.1 is not this machine's. `KAIMON_WINDOWS_SOCK_DIR` names the directory
instead, or turns this off with `off`. Worked out once per process.
"""
function _windows_sock_dir()
    d = _WINDOWS_SOCK_DIR[]
    d === nothing || return d
    return _WINDOWS_SOCK_DIR[] = try
        _find_windows_sock_dir()
    catch e
        @debug "No Windows session directory" exception = e
        ""
    end
end

function _find_windows_sock_dir()
    explicit = get(ENV, "KAIMON_WINDOWS_SOCK_DIR", nothing)
    explicit === nothing || return explicit == "off" ? "" : explicit
    _wsl_shares_loopback() || return ""
    # From a Windows directory, so cmd.exe does not warn about a UNC working directory.
    out = read(pipeline(Cmd(`cmd.exe /c echo %LOCALAPPDATA%`; dir = "/mnt/c"); stderr = devnull), String)
    appdata = strip(out)
    (isempty(appdata) || startswith(appdata, "%")) && return ""
    return joinpath(readchomp(pipeline(`wslpath -u $appdata`; stderr = devnull)), "Kaimon", "sock")
end

"Whether this is WSL with Windows on the same loopback: WSL1, or WSL2 with mirrored networking."
function _wsl_shares_loopback()
    Sys.islinux() || return false
    release = lowercase(try read("/proc/sys/kernel/osrelease", String) catch; "" end)
    occursin("microsoft", release) || return false
    occursin("wsl2", release) || return true
    mode = try readchomp(pipeline(`wslinfo --networking-mode`; stderr = devnull)) catch; "" end
    return strip(mode) == "mirrored"
end

# Session id → session file of each gate found in the Windows directory. A gate that exits removes
# its file; one that dies without doing so is found by its PID in Windows' process list.
const _WINDOWS_SESSION_FILES = Dict{String,String}()
const _WINDOWS_SESSION_FILES_LOCK = ReentrantLock()

"Whether `conn` is a gate found in the Windows directory whose session file is gone."
function _windows_session_ended(conn)
    path = lock(() -> get(_WINDOWS_SESSION_FILES, conn.session_id, nothing), _WINDOWS_SESSION_FILES_LOCK)
    return path !== nothing && !isfile(path)
end

"""
    _tasklist_julia_pids() -> Union{Set{Int},Nothing}

The PIDs of the Julia processes running on the Windows side of WSL, read from `tasklist.exe`, or
`nothing` when the list can't be read. A PID that now names another program counts as gone.
"""
function _tasklist_julia_pids()
    out = try
        read(pipeline(Cmd(`tasklist.exe /FO CSV /NH`; dir = "/mnt/c"); stderr = devnull), String)
    catch
        return nothing
    end
    return _julia_pids_in_tasklist(out)
end

# Rows of `tasklist /FO CSV /NH` start with the quoted image name and PID.
function _julia_pids_in_tasklist(out::AbstractString)
    rows = collect(eachmatch(r"^\"([^\"]*)\",\"(\d+)\""m, out))
    isempty(rows) && return nothing   # Windows always runs some process: the output was not understood
    return Set(parse(Int, m.captures[2]) for m in rows if startswith(lowercase(m.captures[1]), "julia"))
end

# How the Windows process list is read; tests replace it.
const _WINDOWS_JULIA_PIDS = Ref{Function}(_tasklist_julia_pids)

"Whether `pid`, of a gate found in the Windows directory, is missing from Windows' process list."
function _windows_pid_gone(pid::Integer, pids = _WINDOWS_JULIA_PIDS[]())
    return pid > 0 && pids !== nothing && !(pid in pids)
end

"Whether `conn` is a gate found in the Windows directory whose process Windows no longer lists."
function _windows_process_gone(conn)
    lock(() -> haskey(_WINDOWS_SESSION_FILES, conn.session_id), _WINDOWS_SESSION_FILES_LOCK) || return false
    return conn.pid > 0 && _windows_pid_gone(conn.pid)
end

# The identity of a gate found in the Windows directory: its own, or, from a gate too old to
# report one, a stand-in that is never this machine's.
_windows_machine(meta) = (m = string(get(meta, "machine", "")); isempty(m) ? "NT:unreported" : m)   # Sys.KERNEL is :NT on Windows

"""
    _is_local_tcp(conn::REPLConnection) -> Bool

True for a TCP gate on this machine (see `_same_machine`). Its PID is subject to liveness
reaping just like an IPC session's; any other TCP gate's PID names a process elsewhere.
"""
_is_local_tcp(conn::REPLConnection) = _is_tcp(conn) && _same_machine(conn.machine, conn.endpoint)

"""
    _local_gate_token() -> String

The auth token a LOCAL gate on this machine expects — resolved the SAME way the gate
derived it: `KAIMON_GATE_TOKEN` env, else the first API key of a non-lax security
config (`""` for a lax config, which leaves the gate open). A gate binds TCP not only
when explicitly remote but also when a requested local IPC gate is coerced to TCP
because the platform has no IPC transport (Windows). That coerced-local gate still
applies the config's token — so the discovery watcher, which spawned it and shares the
same config, must present that token or be rejected with "Authentication required"
(the gate is on loopback but a TCP port isn't filesystem-protected like an IPC socket,
so we authenticate rather than exempt it). Mirrors `connect_tcp!`'s token resolution.
"""
function _local_gate_token()
    tok = get(ENV, "KAIMON_GATE_TOKEN", "")
    isempty(tok) || return tok
    try
        config = load_global_config()
        (config.mode != :lax && !isempty(config.api_keys)) && return first(config.api_keys)
    catch
    end
    return ""
end

"""
    _update_session_metadata!(sock_dir, session_id; kwargs...)

Update fields in an existing session metadata JSON file. Reads the file,
merges the new fields, and writes it back. No-op if the file doesn't exist.
"""
function _update_session_metadata!(sock_dir::String, session_id::String; kwargs...)
    meta_path = joinpath(sock_dir, "$(session_id).json")
    isfile(meta_path) || return
    try
        meta = JSON.parsefile(meta_path)
        for (k, v) in kwargs
            meta[string(k)] = v
        end
        open(meta_path, "w") do io
            JSON.print(io, meta, 2)
            println(io)
        end
    catch
    end
end

"""
    _maybe_cleanup_stale_session!(sock_dir, session_id)

Remove metadata files for a session if its last successful pong (or started_at)
is older than 30 minutes. Returns true if cleaned up.
"""
function _maybe_cleanup_stale_session!(sock_dir::String, session_id::String)
    meta_path = joinpath(sock_dir, "$(session_id).json")
    isfile(meta_path) || return false
    try
        meta = JSON.parsefile(meta_path)
        last_pong = get(meta, "last_pong", "")
        ref_time = if !isempty(last_pong)
            last_pong
        else
            get(meta, "started_at", "")
        end
        isempty(ref_time) && return false
        age = now() - DateTime(ref_time, Dates.ISODateTimeFormat)
        if Dates.value(age) > 30 * 60 * 1000
            _remove_session_files(sock_dir, session_id)
            return true
        end
    catch
    end
    return false
end

"""
    _remove_session_files(sock_dir, session_id)

Delete .json, .sock, and -stream.sock files for a session.
"""
function _remove_session_files(sock_dir::String, session_id::String)
    for suffix in (".json", ".sock", "-stream.sock", ".events.sock")
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

        # Reap dead-PID sessions: IPC always, and *localhost* TCP gates whose
        # PID is known (>0) and dead. Genuinely remote TCP gates run on another
        # machine, so their PID can't be checked here and is never reaped. The
        # TCP meta `pid` is the gate's own getpid() once a pong has landed.
        session_mode = Symbol(get(meta, "mode", "ipc"))
        local_reapable = session_mode != :tcp ||
            (_same_machine(string(get(meta, "machine", "")), get(meta, "endpoint", "")) && pid > 0)
        if local_reapable && !_is_pid_alive(pid)
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

    # host:port of TCP gates explicitly REGISTERED in tcp_gates.json — those are owned by
    # _poll_tcp_gates! (it holds their auth tokens), so the watcher must not touch them.
    # Everything else that's TCP + localhost is a locally-spawned, tokenless session (the
    # only kind possible on Windows, which has no ZMQ IPC) and IS the watcher's job.
    registered_tcp = try
        Set(_gate_address_key(e.host, e.port) for e in load_tcp_gates_config())
    catch
        Set{String}()
    end

    # The session files: this machine's, then those of gates on the Windows side of WSL. Those are
    # cleaned up from here only when Windows' process list shows the gate has died.
    files = [(mgr.sock_dir, f, false) for f in readdir(mgr.sock_dir)]
    wdir = _windows_sock_dir()
    if !isempty(wdir) && isdir(wdir)
        append!(files, [(wdir, f, true) for f in (try readdir(wdir) catch; String[] end)])
    end
    windows_pids = missing   # Windows' process list, read once per sweep and only if needed

    for (dir, f, windows) in files
        endswith(f, ".json") || continue
        session_id = replace(f, ".json" => "")

        meta = try
            JSON.parsefile(joinpath(dir, f))
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
        session_mode = Symbol(get(meta, "mode", "ipc"))
        windows && session_mode != :tcp && continue    # a Windows socket is no use here
        # TCP markers for REGISTERED or REMOTE gates are owned by _poll_tcp_gates! (it
        # holds the auth token from tcp_gates.json). The watcher has no token, so a
        # tokenless connect there is rejected ("Authentication required") — and a
        # poll-connect drops its own mode=:tcp marker that the watcher would otherwise
        # double-connect. So skip those. But a LOCAL, UNREGISTERED TCP session — the only
        # kind possible on Windows (no ZMQ IPC), a locally-spawned tokenless gate on
        # 127.0.0.1 — must be discovered and connected here exactly like an IPC session,
        # else nothing connects it. (#50, Windows)
        if session_mode == :tcp
            _tcp_host = _endpoint_host(get(meta, "endpoint", ""))
            _tcp_m = match(r"tcp://(?:\[[^\]]+\]|[^:/]+):(\d+)", get(meta, "endpoint", ""))
            _tcp_key = _gate_address_key(_tcp_host, _tcp_m === nothing ? "" : _tcp_m.captures[1])
            # Skip registered/remote TCP (owned by _poll_tcp_gates!), AND any local TCP session
            # we ALREADY track: its `tcp-*.json` is the reconnection cache `connect_tcp!` wrote,
            # not a new gate. Re-discovering it makes the watcher reconnect + replace the live
            # connection every 2s sweep — a flap that churns session-list / list_changed
            # notifications (the KaimonSlate-worker flap). Skip by session_id regardless of PID:
            # a TCP session_id is stable per host:port, a same-port restart is adopted by the
            # health checker via its pong, and a different-port restart has a new session_id that
            # IS still discovered.
            if _tcp_key in registered_tcp || !_is_local_host(_tcp_host) ||
               haskey(known_id_pids, session_id)
                continue
            end
        end
        if session_mode != :tcp && haskey(known_id_pids, session_id) && known_id_pids[session_id] == pid
            continue
        end

        # Skip and clean up sessions whose PID is no longer alive. IPC always;
        # localhost TCP gates with a known (>0), dead PID too. Remote TCP gates
        # run elsewhere, so their PID is unverifiable here and never reaped.
        machine = windows ? _windows_machine(meta) : string(get(meta, "machine", ""))
        local_reapable = session_mode != :tcp ||
            (_same_machine(machine, get(meta, "endpoint", "")) && pid > 0)
        if local_reapable && !_is_pid_alive(pid)
            @debug "Removing the files of a session whose process has gone" session_id pid
            _remove_session_files(mgr.sock_dir, session_id)
            continue
        end
        if windows && pid > 0
            windows_pids === missing && (windows_pids = _WINDOWS_JULIA_PIDS[]())
            if _windows_pid_gone(pid, windows_pids)
                @debug "Removing the file of a Windows session whose process has gone" session_id pid
                _remove_session_files(dir, session_id)
                continue
            end
        end

        name = get(meta, "name", "julia")

        # Skip duplicate sessions from the same process (same name + PID).
        # This happens when a gate restarts within the same process, leaving
        # a stale socket file alongside the new one.
        # TCP sessions are exempt — a process can legitimately host both IPC and TCP gates.
        if session_mode != :tcp && (name, pid) in known_name_pids
            # Clean up the stale duplicate
            _remove_session_files(mgr.sock_dir, session_id)
            continue
        end

        ipc_sock = joinpath(mgr.sock_dir, "$(session_id).sock")
        # CURVE: a reconnected TCP session must re-present the pinned server key —
        # otherwise it connects PLAIN to an encrypted gate and stalls (no handshake,
        # no health pong). Prefer a key stored in metadata, else the TOFU pin for
        # this host:port (connect_tcp! pins it on first connect).
        server_pubkey = string(get(meta, "server_pubkey", ""))
        if isempty(server_pubkey) && session_mode == :tcp
            mh = match(r"tcp://(\[[^\]]+\]|[^:/]+):(\d+)", get(meta, "endpoint", ""))
            if mh !== nothing
                p = tryparse(Int, mh.captures[2])
                if p !== nothing
                    pinned = KaimonGate._pinned_server(String(mh.captures[1]), p)
                    pinned === nothing || (server_pubkey = pinned)
                end
            end
        end
        conn = REPLConnection(
            session_id = session_id,
            name = name,
            socket_path = session_mode == :tcp ? "" : ipc_sock,
            endpoint = get(meta, "endpoint", "ipc://$(ipc_sock)"),
            stream_endpoint = get(meta, "stream_endpoint", ""),
            project_path = get(meta, "project_path", ""),
            julia_version = get(meta, "julia_version", ""),
            pid = pid,
            machine = machine,
            spawned_by = get(meta, "spawned_by", "user"),
            server_pubkey = server_pubkey,
            # A local coerced-TCP gate (Windows IPC substitute) enforces the config's
            # auth token; present it so the watcher isn't rejected. IPC gates need none.
            auth_token = session_mode == :tcp ? _local_gate_token() : "",
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

        windows && lock(() -> _WINDOWS_SESSION_FILES[session_id] = joinpath(dir, f), _WINDOWS_SESSION_FILES_LOCK)
        push!(known_name_pids, (name, pid))
        push!(new_connections, conn)
    end

    return new_connections
end

"""
    connect_tcp!(mgr::ConnectionManager, host::String, port::Int; name="") -> REPLConnection

Manually connect to a TCP gate at `host:port`. The PUB stream endpoint is
resolved from the gate's pong response (supports ephemeral ports).

Returns the connected `REPLConnection`, or throws on failure.
"""
function connect_tcp!(mgr::ConnectionManager, host::String, port::Int;
                      name::String = "", token::String = "", stream_port::Int = 0,
                      server_key::String = "", label::String = "")
    endpoint = "tcp://$(host):$(port)"
    stream_endpoint = stream_port > 0 ? "tcp://$(host):$(stream_port)" : ""
    sid = "tcp-$(host)-$(port)"

    # An existing LIVE connection to this endpoint is a real conflict — but a :disconnected
    # corpse must not block reconnecting: `disconnect!` tears the sockets down and marks the
    # status, yet leaves the registry entry in `mgr.connections` (e.g. Slate detaching a remote
    # worker's kernel, then reattaching to the same host:port). Reap the corpse and proceed.
    # The live-status set mirrors the discovery loop's "already connected?" check.
    lock(mgr.lock) do
        idx = findfirst(c -> c.session_id == sid, mgr.connections)
        if idx !== nothing
            if mgr.connections[idx].status in (:connected, :evaluating, :stalled, :connecting)
                error("Already connected to $endpoint")
            end
            deleteat!(mgr.connections, idx)
        end
    end

    # Fast-fail if nothing is even accepting TCP on the port: a downed gate refuses
    # instantly, so this avoids building sockets and then burning the multi-second ZMQ
    # ping on an unreachable endpoint (a real gate's port accepts at the TCP layer before
    # the ZMQ/CURVE handshake, so this never false-negatives a live gate).
    if !_tcp_port_open(host, port)
        error("TCP gate at $endpoint is not reachable (connection refused or timed out)")
    end

    # Resolve auth token: explicit > env var > security config
    if isempty(token)
        token = get(ENV, "KAIMON_GATE_TOKEN", "")
    end
    if isempty(token)
        try
            config = load_global_config()
            if config.mode != :lax && !isempty(config.api_keys)
                token = first(config.api_keys)
            end
        catch
        end
    end

    # Resolve CURVE server key (for an encrypted gate): explicit > env > pinned
    # (TOFU). CURVE has no in-band key exchange, so we must hold the key before
    # connecting; without one we connect plain (and an encrypted gate won't answer).
    if isempty(server_key)
        server_key = get(ENV, "KAIMON_GATE_CURVE_SERVERKEY", "")
    end
    if isempty(server_key)
        pinned = KaimonGate._pinned_server(host, port)
        pinned === nothing || (server_key = pinned)
    end

    display_name = !isempty(label) ? label : (isempty(name) ? "$(host):$(port)" : name)
    conn = REPLConnection(
        session_id = sid,
        name = isempty(name) ? "tcp" : name,
        display_name = display_name,
        socket_path = "",  # empty = TCP session
        endpoint = endpoint,
        stream_endpoint = stream_endpoint,
        project_path = "",
        julia_version = "",
        pid = 0,
        spawned_by = "user",
        auth_token = token,
        server_pubkey = server_key,
        label = label,
    )

    if !connect!(mgr, conn)
        error("Failed to connect to TCP gate at $endpoint")
    end

    # Verify the gate is actually reachable with a ping
    pong = ping(conn)
    if pong === nothing
        # Gate not responding — clean up the socket and bail
        disconnect!(conn)
        msg = "TCP gate at $endpoint is not responding"
        if isempty(conn.server_pubkey)
            msg *= " (if it requires CURVE, pass server_key)"
        else
            # A pinned CURVE link that goes silent is indistinguishable in-band
            # from a changed key — the wrong key just fails the handshake. Say so.
            msg *= " (CURVE: the gate may be down, or its server key may have CHANGED " *
                   "since it was pinned — verify out-of-band, e.g. " *
                   "KaimonGate.verify_server_key_via_ssh(\"$host\", $port), then re-pin)"
        end
        error(msg)
    end
    # TOFU: the successful CURVE handshake proves this server key — pin it for
    # `host:port` so future connects can resolve it and detect key changes.
    isempty(conn.server_pubkey) || KaimonGate.pin_server!(host, port, conn.server_pubkey)

    # Populate connection from pong
    # Prefer pre-set stream_endpoint (from stream_port config) over pong value
    pong_stream = !isempty(conn.stream_endpoint) ? conn.stream_endpoint :
        string(get(pong, :stream_endpoint, ""))
    # Skip if connect! already wired the SUB (a fixed stream_port sets stream_endpoint
    # before connect!, so it connects there); only ephemeral gates reach it via the pong.
    if !isempty(pong_stream) && conn.sub_socket === nothing
        conn.stream_endpoint = pong_stream
        try
            # On the conn's own context (dedicated for TCP — see connect!).
            sub = _zmq_socket(conn.zmq_context, SUB)
            sub.rcvtimeo = 0
            sub.linger = 0
            sub.rcvhwm = 0
            _apply_curve_client!(sub, conn)   # CURVE (no-op unless server_pubkey set)
            subscribe(sub, "")
            ZMQ.connect(sub, pong_stream)
            conn.sub_socket = sub
            _push_log!(:info, "TCP stream connected: $pong_stream ($(conn.display_name))")
        catch e
            _push_log!(:warn, "TCP stream connect failed: $pong_stream — $(sprint(showerror, e))")
        end
    end
    new_path = string(get(pong, :project_path, ""))
    !isempty(new_path) && (conn.project_path = new_path)
    conn.julia_version = string(get(pong, :julia_version, ""))
    conn.pid = Int(get(pong, :pid, 0))
    pong_machine = string(get(pong, :machine, ""))
    isempty(pong_machine) || (conn.machine = pong_machine)

    # Now that the gate answered and project_path is known, apply the mirror pref (deferred
    # from connect! for TCP — see there). A dead gate already bailed at the ping above.
    _apply_mirror_pref!(conn)

    lock(mgr.lock) do
        push!(mgr.connections, conn)
    end
    _fire_sessions_changed(mgr)

    # Write a local metadata file so reconnect works after TUI restart
    KaimonGate.write_metadata(sid, conn.name, endpoint, conn.stream_endpoint; spawned_by = "user", mode = :tcp)
    # `write_metadata` records the process calling it, here Kaimon: give the file the gate's own.
    _update_session_metadata!(mgr.sock_dir, sid; pid = conn.pid, machine = conn.machine,
        project_path = conn.project_path, julia_version = conn.julia_version)

    return conn
end

# Backoff state for TCP gate polling — keyed by "host:port"
const _TCP_POLL_BACKOFF = Dict{String, @NamedTuple{failures::Int, next_try::Float64}}()
const _TCP_POLL_BACKOFF_SCHEDULE = [5.0, 15.0, 30.0, 60.0, 120.0]  # seconds

"""Poll registered TCP gate endpoints with exponential backoff on failure."""
function _poll_tcp_gates!(mgr::ConnectionManager)
    entries = load_tcp_gates_config()
    isempty(entries) && return

    for entry in entries
        entry.enabled || continue
        isempty(entry.host) && continue

        sid = "tcp-$(entry.host)-$(entry.port)"
        backoff_key = "$(entry.host):$(entry.port)"

        # Already connected?
        already = lock(mgr.lock) do
            any(c -> c.session_id == sid && c.status in (:connected, :evaluating, :stalled, :connecting), mgr.connections)
        end
        if already
            # Reset backoff and sync display name from config
            delete!(_TCP_POLL_BACKOFF, backoff_key)
            if !isempty(entry.name)
                lock(mgr.lock) do
                    for c in mgr.connections
                        if c.session_id == sid && c.display_name != entry.name
                            c.display_name = entry.name
                            _fire_sessions_changed(mgr)
                        end
                    end
                end
            end
            continue
        end

        # Check backoff — don't retry too soon
        state = get(_TCP_POLL_BACKOFF, backoff_key, nothing)
        if state !== nothing && time() < state.next_try
            continue
        end

        # Try to connect
        try
            connect_tcp!(mgr, entry.host, entry.port; name = entry.name, token = entry.token, stream_port = entry.stream_port, server_key = entry.server_key)
            delete!(_TCP_POLL_BACKOFF, backoff_key)
            _push_log!(:info, "TCP gate connected: $(entry.name) ($(entry.host):$(entry.port))")
        catch
            # Failed — increase backoff
            failures = state !== nothing ? state.failures + 1 : 1
            idx = min(failures, length(_TCP_POLL_BACKOFF_SCHEDULE))
            delay = _TCP_POLL_BACKOFF_SCHEDULE[idx]
            _TCP_POLL_BACKOFF[backoff_key] = (failures = failures, next_try = time() + delay)
        end
    end
end

"""Apply the persisted mirror_repl preference to a connected gate: per-session override >
per-project pref > global default. Best-effort — a failure is non-fatal to the connection."""
function _apply_mirror_pref!(conn::REPLConnection)
    try
        session_prefs = load_session_prefs()
        mirror_val = resolve_session_pref(session_prefs, conn.project_path, :mirror_repl)
        mirror_enabled = mirror_val !== nothing ? mirror_val : get_gate_mirror_repl_preference()
        set_mirror_repl!(conn, mirror_enabled)
    catch e
        @debug "Failed to apply mirror_repl preference to gate" exception = e
    end
end

function connect!(mgr::ConnectionManager, conn::REPLConnection)
    conn.status = :connecting
    try
        # TCP/CURVE sessions get a DEDICATED ZMQ context so their CURVE handshake
        # doesn't contend for the one I/O thread of mgr.zmq_context that serves
        # every IPC session (under load that could exceed the connect ping
        # timeout); the whole context is parked + closed in disconnect!. IPC
        # sessions share mgr.zmq_context. Each connection now creates just ONE
        # DEALER (+ one SUB), created once — no per-request socket churn.
        ctx = _is_tcp(conn) ? Context() : mgr.zmq_context
        conn.zmq_context = ctx

        # Persistent DEALER for this connection (protocol v2) — created once, CURVE
        # applied once. All requests multiplex over it (see RequestChannel).
        conn.req_channel = RequestChannel(ctx, conn.endpoint;
            curve! = sock -> _apply_curve_client!(sock, conn))

        # Connect the stream SUB when the endpoint is already known: IPC always, and TCP
        # when it came from session metadata (the watcher/discovery path — a locally-spawned
        # TCP gate on Windows). For an ephemeral TCP gate reached via connect_tcp!,
        # stream_endpoint is empty here and the SUB is wired after the pong instead
        # (idempotent — that path checks sub_socket first).
        if conn.sub_socket === nothing && !isempty(conn.stream_endpoint)
            try
                sub = _zmq_socket(ctx, SUB)
                sub.rcvtimeo = 0  # non-blocking recv
                sub.linger = 0    # don't block on close
                sub.rcvhwm = 0    # unlimited receive buffer — never drop messages
                _apply_curve_client!(sub, conn)   # no-op unless CURVE (TCP + pinned server key)
                subscribe(sub, "")  # receive all messages
                connect(sub, conn.stream_endpoint)
                conn.sub_socket = sub
            catch e
                @debug "Failed to connect stream socket" exception = e
            end
        end

        conn.status = :connected
        conn.last_seen = now()
        # Apply runtime gate options from persisted preferences, with per-session
        # overrides taking priority. TCP sessions defer this to connect_tcp! AFTER the
        # reachability pong: (1) a dead gate then fails fast on the ping instead of first
        # burning the set_option timeout here, and (2) conn.project_path is only known
        # once the pong populates it, so resolving a per-project pref is correct only then.
        if !_is_tcp(conn)
            _apply_mirror_pref!(conn)
        end
        return true
    catch e
        @debug "Failed to connect to gate" session_id = conn.session_id exception = e
        conn.status = :disconnected
        rc = conn.req_channel
        rc === nothing || _close_request_channel!(rc)
        conn.req_channel = nothing
        # Clean up the SUB socket if it was created before we threw.
        if conn.sub_socket !== nothing
            _zmq_close!(conn.sub_socket)   # close + drop its ctx.sockets weakref
            conn.sub_socket = nothing
        end
        # A TCP/CURVE connect owns a DEDICATED Context (created above). If we threw
        # after creating it, park it for deferred termination instead of leaving it
        # dangling on conn.zmq_context — otherwise the next reconnect overwrites that
        # field (line ~521), orphaning the Context so GC runs its finalizer
        # (close → iterate sockets → zmq_ctx_term) on a GC thread, racing libzmq:
        # a heap-corruption hazard. Mirrors disconnect!. IPC shares mgr.zmq_context
        # and must NOT be touched here.
        if _is_tcp(conn) && conn.zmq_context !== nothing
            _park_context!(conn.zmq_context)
            conn.zmq_context = nothing
        end
        return false
    end
end


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

"""
    _is_local_tcp(conn::REPLConnection) -> Bool

True for a TCP gate whose endpoint resolves to the local machine. Localhost TCP
gates are subject to PID-liveness reaping just like IPC sessions; remote ones
are not (their PID is meaningless here).
"""
_is_local_tcp(conn::REPLConnection) = _is_tcp(conn) && _is_local_host(_endpoint_host(conn.endpoint))

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
            (_is_local_host(_endpoint_host(get(meta, "endpoint", ""))) && pid > 0)
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
        session_mode = Symbol(get(meta, "mode", "ipc"))
        # TCP gates are owned exclusively by _poll_tcp_gates!, which connects them
        # via connect_tcp! with the auth token from tcp_gates.json. The file-watcher
        # must NOT connect them: it has no token, so its connection is rejected with
        # "Authentication required". And on a successful poll-connect the gate drops a
        # mode=:tcp marker into sock_dir (for reconnect bookkeeping) — which the
        # watcher would otherwise pick up and double-connect tokenless, the bad
        # connection winning. So ignore TCP markers here entirely. (#50)
        if session_mode == :tcp
            continue
        end
        if session_mode != :tcp && haskey(known_id_pids, session_id) && known_id_pids[session_id] == pid
            continue
        end

        # Skip and clean up sessions whose PID is no longer alive. IPC always;
        # localhost TCP gates with a known (>0), dead PID too. Remote TCP gates
        # run elsewhere, so their PID is unverifiable here and never reaped.
        local_reapable = session_mode != :tcp ||
            (_is_local_host(_endpoint_host(get(meta, "endpoint", ""))) && pid > 0)
        if local_reapable && !_is_pid_alive(pid)
            _remove_session_files(mgr.sock_dir, session_id)
            continue
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
            spawned_by = get(meta, "spawned_by", "user"),
            server_pubkey = server_pubkey,
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

"""
    connect_tcp!(mgr::ConnectionManager, host::String, port::Int; name="") -> REPLConnection

Manually connect to a TCP gate at `host:port`. The PUB stream endpoint is
resolved from the gate's pong response (supports ephemeral ports).

Returns the connected `REPLConnection`, or throws on failure.
"""
function connect_tcp!(mgr::ConnectionManager, host::String, port::Int;
                      name::String = "", token::String = "", stream_port::Int = 0,
                      server_key::String = "")
    endpoint = "tcp://$(host):$(port)"
    stream_endpoint = stream_port > 0 ? "tcp://$(host):$(stream_port)" : ""
    sid = "tcp-$(host)-$(port)"

    # Check for existing connection to this endpoint
    existing = lock(mgr.lock) do
        findfirst(c -> c.session_id == sid, mgr.connections)
    end
    existing !== nothing && error("Already connected to $endpoint")

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

    display_name = isempty(name) ? "$(host):$(port)" : name
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
    if !isempty(pong_stream)
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

    lock(mgr.lock) do
        push!(mgr.connections, conn)
    end
    _fire_sessions_changed(mgr)

    # Write a local metadata file so reconnect works after TUI restart
    KaimonGate.write_metadata(sid, conn.name, endpoint, conn.stream_endpoint; spawned_by = "user", mode = :tcp)

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

        # IPC: connect the stream SUB now. TCP: its PUB port may be ephemeral, so
        # the SUB is created after the pong in connect_tcp! (on this same context).
        if !_is_tcp(conn) && !isempty(conn.stream_endpoint)
            try
                sub = _zmq_socket(ctx, SUB)
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
        rc = conn.req_channel
        rc === nothing || _close_request_channel!(rc)
        conn.req_channel = nothing
        # Clean up the SUB socket if it was created before we threw.
        if conn.sub_socket !== nothing
            try; close(conn.sub_socket); catch; end
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


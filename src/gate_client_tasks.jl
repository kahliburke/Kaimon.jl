# ─────────────────────────────────────────────────────────────────────────────
# Kaimon gate client · background tasks · convenience  (split from gate_client.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── Background Tasks ──────────────────────────────────────────────────────────

function start!(mgr::ConnectionManager)
    mgr.running = true
    mkpath(mgr.sock_dir)

    # Global event PUB socket for extensions
    _start_event_pub!(mgr)

    # Clean up stale per-extension event sockets from old PUSH/PULL system
    for f in readdir(mgr.sock_dir; join=true)
        endswith(f, ".events.sock") && try; rm(f); catch; end
    end

    # Socket directory watcher — discovers new gate sessions
    mgr.watcher_task = Threads.@spawn begin
        _discovery_failures = Dict{String,Int}()
        while mgr.running
            try
                new_conns = discover_sessions(mgr)
                if !isempty(new_conns)
                    # Connect all discovered sessions in parallel
                    connect_tasks = [(conn, Threads.@spawn connect!(mgr, conn)) for conn in new_conns]
                    added = false
                    for (conn, task) in connect_tasks
                        ok = try; fetch(task); catch; false; end
                        if ok
                            lock(mgr.lock) do
                                old_idx = findfirst(
                                    c -> c.session_id == conn.session_id,
                                    mgr.connections,
                                )
                                if old_idx !== nothing
                                    old_conn = mgr.connections[old_idx]
                                    _unregister_session_tools!(old_conn)
                                    disconnect!(old_conn)
                                    mgr.connections[old_idx] = conn
                                else
                                    push!(mgr.connections, conn)
                                end
                            end
                            added = true
                        else
                            _maybe_cleanup_stale_session!(mgr.sock_dir, conn.session_id)
                        end
                    end
                    added && _fire_sessions_changed(mgr)
                end
            catch e
                @debug "Watcher error" exception = e
            end

            # Poll registered TCP gates
            try
                _poll_tcp_gates!(mgr)
            catch e
                @debug "TCP gate poll error" exception = e
            end

            sleep(2)  # Poll every 2 seconds
        end
    end

    # Health checker — fire-and-forget pings with async result collection.
    # Each cycle: collect any pong replies from previous pings, update status,
    # then send new pings to sessions that need them. A stalled session never
    # blocks health checks for others.
    mgr.health_task = Threads.@spawn begin
        # Outstanding ping tasks keyed by session_id
        pending_pings = Dict{String, Task}()

        while mgr.running
            try
                conns = lock(mgr.lock) do
                    copy(mgr.connections)
                end

                _reap_parked_contexts!()   # terminate dead TCP contexts past grace (#51)

                to_remove = REPLConnection[]

                for conn in conns
                    sid = conn.session_id

                    if conn.status in (:connected, :evaluating, :stalled)
                        # Collect result from previous ping if ready
                        if haskey(pending_pings, sid)
                            task = pending_pings[sid]
                            if istaskdone(task)
                                delete!(pending_pings, sid)
                                result = try; fetch(task); catch; nothing; end
                                _process_health_result!(mgr, conn, result, to_remove)
                            else
                                # Still waiting — check if it's been too long
                                # (the task has its own timeout via _req_send_recv)
                            end
                        end

                        # Send a new ping if we don't have one outstanding
                        if !haskey(pending_pings, sid)
                            pending_pings[sid] = Threads.@spawn ping(conn)
                        end

                    elseif conn.status == :disconnected
                        delete!(pending_pings, sid)
                        if isempty(conn.socket_path) || ispath(conn.socket_path)
                            connect!(mgr, conn)
                        else
                            push!(to_remove, conn)
                        end
                    end
                end

                # Clean up pending pings for sessions that no longer exist
                active_sids = Set(c.session_id for c in conns)
                for sid in collect(keys(pending_pings))
                    if sid ∉ active_sids
                        delete!(pending_pings, sid)
                    end
                end

                # Remove dead sessions under the lock
                if !isempty(to_remove)
                    lock(mgr.lock) do
                        for conn in to_remove
                            idx = findfirst(c -> c === conn, mgr.connections)
                            if idx !== nothing
                                _unregister_session_tools!(conn)
                                disconnect!(conn)
                                _remove_session_files(mgr.sock_dir, conn.session_id)
                                _clear_gate_error!(conn)   # drop its error-throttle entry
                                deleteat!(mgr.connections, idx)
                            end
                        end
                    end
                    _fire_sessions_changed(mgr)
                end
            catch e
                @debug "Health check error" exception = e
            end
            sleep(5)
        end
    end

    # Stream drain — headless only. Eval results arrive on the SUB stream and are
    # routed to the waiting caller's inbox by drain_stream_messages!, which in the
    # TUI is driven by the render loop. Headless (task_queue === nothing) has no
    # render loop, so without this every eval_complete is never read and `ex` hangs
    # then promotes to a stuck background job (#50). Rather than poll, we run an
    # event-driven per-connection SUB reader (persistent FDWatcher, like the DEALER
    # reader). A lightweight supervisor keeps one reader per connection; the readers
    # self-exit on disconnect. The supervisor's coarse cadence is bookkeeping only —
    # the draining itself is event-driven (a reader parks until its SUB is readable).
    if mgr.task_queue === nothing
        mgr.drain_task = Threads.@spawn begin
            readers = Dict{UInt,Task}()   # objectid(conn) → reader task
            while mgr.running
                try
                    conns = lock(mgr.lock) do; copy(mgr.connections) end
                    live = Set{UInt}()
                    for conn in conns
                        key = objectid(conn)
                        push!(live, key)
                        t = get(readers, key, nothing)
                        if t === nothing || istaskdone(t)
                            readers[key] = Threads.@spawn _sub_reader(mgr, conn)
                        end
                    end
                    # Forget readers for connections that are gone (they self-exit).
                    for key in collect(keys(readers))
                        key in live || delete!(readers, key)
                    end
                catch e
                    @debug "Headless drain supervisor error" exception = e
                end
                sleep(1.0)
            end
        end
    end

    return mgr
end

# Track which sessions we've already warned about to avoid spamming
const _VERSION_WARNED = Set{String}()

function _protocol_mismatch_warning!(mgr::ConnectionManager, conn::REPLConnection, app_proto::Int, gate_proto::Int, gate_ver::String)
    conn.session_id in _VERSION_WARNED && return
    push!(_VERSION_WARNED, conn.session_id)
    name = isempty(conn.display_name) ? conn.session_id : conn.display_name
    gv = isempty(gate_ver) ? "?" : gate_ver
    msg = "Gate protocol mismatch: kaimon speaks gate protocol v$app_proto but session " *
          "'$name' (reports v$gv) speaks v$gate_proto. Update KaimonGate (`]up KaimonGate`) " *
          "or the kaimon app so both sides match."
    @warn msg
    _emit_event!(mgr, :version_mismatch, (
        session_id = conn.session_id,
        display_name = name,
        app_version = string(app_proto),
        gate_version = string(gate_proto),
    ))
end

# Once-per-message throttle for gate-error health replies (session_id → last message),
# so a persistent rejection — pinged every few seconds — logs once, not every cycle.
const _GATE_ERROR_NOTED = Dict{String,String}()
const _GATE_ERROR_NOTED_LOCK = ReentrantLock()

"""Log a gate that answered a health ping with an error, but only when the message is
new or changed for this session (a steady rejection shouldn't flood the log)."""
function _note_gate_error!(conn::REPLConnection, message::AbstractString)
    changed = lock(_GATE_ERROR_NOTED_LOCK) do
        get(_GATE_ERROR_NOTED, conn.session_id, "") == message && return false
        _GATE_ERROR_NOTED[conn.session_id] = String(message)
        return true
    end
    changed && _push_log!(:warn,
        "Gate '$(conn.display_name)' answered a health ping with an error — not ready: $message")
end

"""Clear the gate-error throttle for a session (on a real pong, or when it's removed),
so a later error logs afresh instead of being suppressed as a duplicate."""
_clear_gate_error!(conn::REPLConnection) =
    lock(_GATE_ERROR_NOTED_LOCK) do; delete!(_GATE_ERROR_NOTED, conn.session_id); end

"""Process the result of a health check ping for one connection."""
function _process_health_result!(mgr::ConnectionManager, conn::REPLConnection, result, to_remove::Vector{REPLConnection})
    if result === :busy
        if !_is_tcp(conn) && !_is_pid_alive(conn.pid)
            disconnect!(conn)
            push!(to_remove, conn)
        elseif conn.status != :evaluating
            conn.status = :evaluating
            _fire_sessions_changed(mgr)
        end
    elseif result isa NamedTuple && get(result, :type, :pong) === :error
        # The gate ANSWERED but refused the request: a (type=:error, message=…) reply,
        # most often "Authentication required" when the client reached a token-guarded
        # gate without presenting the token. It carries no :tools/:namespace, so counting
        # it as a healthy pong silently wedges an extension at :starting until the startup
        # timeout — with nothing explaining why. Log it (once per distinct message) and do
        # NOT treat it as a successful pong.
        _note_gate_error!(conn, string(get(result, :message, "unknown error")))
    elseif result !== nothing
        _clear_gate_error!(conn)   # a real pong — reset the once-per-message error throttle
        # Successful pong
        if conn.status != :connected
            conn.diagnostics = nothing
            conn.stall_reason = :none
            conn.status = :connected
            _fire_sessions_changed(mgr)
        end

        # Refresh the PID from the pong (the gate's own getpid() — authoritative).
        # On TCP port reuse, a new process can rebind the same host:port and pings
        # keep succeeding, so conn.pid must adopt the fresh PID rather than keep the
        # dead predecessor's — both for display and for the dead-pid reaper below.
        pong_pid = Int(get(result, :pid, 0))
        if pong_pid > 0 && pong_pid != conn.pid
            conn.pid = pong_pid
            _fire_sessions_changed(mgr)
        end

        # Record the gate's reported package version for display only. The gate
        # (KaimonGate) and this client (Kaimon) are now separate packages with
        # independent version numbers, so version equality is not a compat signal.
        gate_kv = string(get(result, :kaimon_version, ""))
        if !isempty(gate_kv) && gate_kv != "unknown"
            conn.kaimon_version = gate_kv
        end

        # Wire-protocol version is the authoritative compatibility check. Pongs
        # without a protocol_version (older gates) are assumed compatible.
        gate_proto = get(result, :protocol_version, nothing)
        if gate_proto isa Integer && Int(gate_proto) != KaimonGate.PROTOCOL_VERSION
            _protocol_mismatch_warning!(mgr, conn, KaimonGate.PROTOCOL_VERSION, Int(gate_proto), gate_kv)
        end

        # Update metadata file with fresh pong data
        _update_session_metadata!(mgr.sock_dir, conn.session_id;
            last_pong = Dates.format(now(), Dates.ISODateTimeFormat),
            failed_pongs = 0,
            project_path = conn.project_path,
            pid = conn.pid,
            name = conn.display_name,
            julia_version = conn.julia_version)

        # Notify TUI of successful pong
        _emit_event!(mgr, :session_pong, (
            session_id = conn.session_id,
            display_name = conn.display_name,
            pid = Int(get(result, :pid, 0)),
            uptime = Float64(get(result, :uptime, 0.0)),
            tools = length(get(result, :tools, [])),
        ))

        # Worker-reported display label (e.g. a notebook filename) is authoritative — it names the session
        # regardless of the project (several notebooks share one project), so it wins over project derivation.
        pong_label = string(get(result, :label, ""))
        if !isempty(pong_label) && pong_label != conn.label
            conn.label = pong_label
            existing = lock(mgr.lock) do
                [c.display_name for c in mgr.connections if c !== conn]
            end
            conn.display_name = _derive_display_name(conn.project_path, conn.julia_version, existing; label = pong_label)
            _fire_sessions_changed(mgr)
        end

        # Update project_path from pong
        new_path = get(result, :project_path, "")
        if !isempty(new_path) && new_path != conn.project_path
            conn.project_path = new_path
            if !_is_tcp(conn) || conn.name == "tcp"
                existing = lock(mgr.lock) do
                    [c.display_name for c in mgr.connections if c !== conn]
                end
                conn.display_name = _derive_display_name(
                    new_path, conn.julia_version, existing;
                    namespace = conn.namespace, label = conn.label,
                )
            end
            _fire_sessions_changed(mgr)
        end

        # Sync session tools from pong (hash-based change detection)
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
                    if isempty(old_ns) && is_extension(conn)
                        existing = lock(mgr.lock) do
                            [c.display_name for c in mgr.connections if c !== conn]
                        end
                        conn.display_name = _derive_display_name(
                            conn.project_path, conn.julia_version, existing;
                            namespace = pong_ns, label = conn.label,
                        )
                    end
                end
                _register_session_tools!(conn)
                _fire_sessions_changed(mgr)
            end
        end

        # Sync flags
        conn.allow_restart = Bool(get(result, :allow_restart, true))
        conn.allow_mirror = Bool(get(result, :allow_mirror, true))
        conn.mirror_repl = Bool(get(result, :mirror_repl, false))

        # Connect or reconnect SUB socket from pong stream_endpoint.
        # When a gate restarts on the same REQ port, the PUB port changes but
        # the old SUB socket is still set — detect this via endpoint mismatch
        # and replace the stale SUB socket. (#35)
        pong_stream = string(get(result, :stream_endpoint, ""))
        if !isempty(pong_stream)
            needs_sub = conn.sub_socket === nothing
            if !needs_sub && pong_stream != conn.stream_endpoint
                # Gate restarted — PUB port changed. Close the stale SUB socket.
                _push_log!(:info, "TCP stream endpoint changed: $(conn.stream_endpoint) → $pong_stream ($(conn.display_name))")
                # Serialize with the drain (which recvs sub_socket under req_lock)
                # so we never close it mid-recv (#51).
                lock(conn.req_lock) do
                    _zmq_close!(conn.sub_socket)   # close + drop its ctx.sockets weakref
                    conn.sub_socket = nothing
                end
                needs_sub = true
            end
            if needs_sub
                conn.stream_endpoint = pong_stream
                try
                    sub_ctx = Context()
                    sub = _zmq_socket(sub_ctx, SUB)
                    sub.rcvtimeo = 0
                    sub.linger = 0
                    sub.rcvhwm = 0
                    _apply_curve_client!(sub, conn)   # CURVE (no-op unless server_pubkey set)
                    subscribe(sub, "")
                    ZMQ.connect(sub, pong_stream)
                    # Publish the new socket under req_lock so a concurrent drain
                    # sees a consistent socket, never a torn swap (#51).
                    lock(conn.req_lock) do
                        conn.sub_socket = sub
                    end
                    _push_log!(:info, "TCP stream connected: $pong_stream ($(conn.display_name))")
                catch e
                    _push_log!(:warn, "TCP stream connect failed: $pong_stream — $(sprint(showerror, e))")
                end
                # Update metadata file with new stream_endpoint
                _update_session_metadata!(mgr.sock_dir, conn.session_id;
                    stream_endpoint = pong_stream)
            end
        end
    else
        # Ping failed — increment failed count in metadata
        meta_path = joinpath(mgr.sock_dir, "$(conn.session_id).json")
        prev_fails = 0
        try
            isfile(meta_path) && (prev_fails = get(JSON.parsefile(meta_path), "failed_pongs", 0))
        catch; end
        _update_session_metadata!(mgr.sock_dir, conn.session_id;
            failed_pongs = prev_fails + 1,
            last_failed_pong = Dates.format(now(), Dates.ISODateTimeFormat))
        # Reap a session whose own process is provably dead: IPC, or a localhost
        # TCP gate (getpid() checkable here). Remote TCP, a live local PID, or an
        # unknown PID (≤0, not yet ponged) stays :stalled. Relies on conn.pid being
        # the gate's own getpid() (refreshed above) so port-reuse reaps correctly.
        local_pid_dead =
            (!_is_tcp(conn) || _is_local_tcp(conn)) && conn.pid > 0 && !_is_pid_alive(conn.pid)
        if local_pid_dead
            disconnect!(conn)
            push!(to_remove, conn)
        else
            if !_is_tcp(conn)
                conn.diagnostics = _probe_process(conn.pid)
            end
            if conn.status != :stalled
                conn.stall_reason = _classify_stall(conn)
                conn.status = :stalled
                _fire_sessions_changed(mgr)
            end
        end
    end
end

function stop!(mgr::ConnectionManager)
    mgr.running = false

    # Stop global event PUB
    _stop_event_pub!(mgr)

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
        for task in [mgr.watcher_task, mgr.health_task, mgr.drain_task]
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
    connected_sessions(mgr; include_extensions=false) -> Vector{REPLConnection}

List currently connected, *addressable* sessions. Extension runtimes (see
`is_extension`) are excluded by default: they are not REPLs an agent can bind to,
target with `ses=`, or eval in. Only the extension-management machinery, which
tracks extensions by namespace, passes `include_extensions=true`.
"""
function connected_sessions(mgr::ConnectionManager; include_extensions::Bool = false)
    lock(mgr.lock) do
        filter(mgr.connections) do c
            c.status in (:connected, :evaluating, :stalled) &&
                (include_extensions || !is_extension(c))
        end
    end
end

"""Short unique session key — first 8 chars for UUIDs, full ID for TCP sessions.
The 8-char truncation collides for local TCP ids (`tcp-127.0.0.1-9100`, `…-9102` all
start with `tcp-127.`), so anything keying per-session (ECG, health) must use this,
not a raw `session_id[1:8]`."""
short_key(sid::AbstractString) = startswith(sid, "tcp-") ? String(sid) : first(sid, 8)
short_key(conn::REPLConnection) = short_key(conn.session_id)

"""Look up an *addressable* connection by its 8-char short key. Returns nothing if
not found. Includes stalled sessions so tools can still interact with them, but
excludes extension runtimes by default (see `is_extension`) — an agent must not be
able to resolve an extension via `ses=`. Pass `include_extensions=true` from the
extension-management machinery that legitimately addresses them."""
function get_connection_by_key(mgr::ConnectionManager, key::String;
                               include_extensions::Bool = false)
    lock(mgr.lock) do
        for conn in mgr.connections
            if conn.status in (:connected, :evaluating, :stalled) &&
               startswith(conn.session_id, key) &&
               (include_extensions || !is_extension(conn))
                return conn
            end
        end
        return nothing
    end
end


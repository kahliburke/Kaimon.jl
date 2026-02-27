# ═══════════════════════════════════════════════════════════════════════════════
# Gate Client — TUI-side connection manager for REPL gate sockets
#
# Discovers gate sockets in ~/.cache/kaimon/sock/, connects via ZMQ REQ,
# sends eval requests, handles reconnection and health checks.
# ═══════════════════════════════════════════════════════════════════════════════

# ZMQ, Serialization, Dates, JSON are available from the Kaimon module scope.

# ── Types ─────────────────────────────────────────────────────────────────────

@enum EvalState EVAL_IDLE EVAL_SENDING EVAL_STREAMING

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
    req_lock::ReentrantLock      # protects REQ socket access
    eval_state::Ref{EvalState}   # current eval lifecycle state
    _eval_inboxes::Dict{String,Channel{Any}}  # per-request_id channels for concurrent evals
    _eval_inboxes_lock::ReentrantLock          # protects _eval_inboxes dict
    status::Symbol               # :connected, :disconnected, :connecting
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
    )
end

# ── Display Name Derivation ───────────────────────────────────────────────────

"""
    _derive_display_name(project_path, julia_version, existing_names) -> String

Derive a short display name from the project path, deduplicating against
already-assigned names.  Rules:
  - Non-empty project_path → `basename(project_path)` (e.g. "MyApp")
  - Global env or empty path → `@v<julia_version>` (e.g. "@v1.12")
  - Collisions get a `-2`, `-3`, … suffix
"""
function _derive_display_name(
    project_path::String,
    julia_version::String,
    existing_names::Vector{String},
)::String
    base = if isempty(project_path) || project_path == homedir()
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

# ── PID & Stale Session Helpers ──────────────────────────────────────────────

"""
    _is_pid_alive(pid::Int) -> Bool

Cross-platform check whether a process with the given PID exists.
Uses signal 0 (no actual signal sent) via libuv.
"""
function _is_pid_alive(pid::Int)
    pid > 0 || return false
    ccall(:uv_kill, Cint, (Cint, Cint), pid, 0) == 0
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

    known_ids = lock(mgr.lock) do
        Set(c.session_id for c in mgr.connections)
    end

    for f in readdir(mgr.sock_dir)
        endswith(f, ".json") || continue
        session_id = replace(f, ".json" => "")

        # Skip already-known sessions
        session_id in known_ids && continue

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

        # Skip and clean up sessions whose PID is no longer alive
        if !_is_pid_alive(pid)
            _remove_session_files(mgr.sock_dir, session_id)
            continue
        end

        conn = REPLConnection(
            session_id = session_id,
            name = get(meta, "name", "julia"),
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
        )

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
        conn.zmq_context = mgr.zmq_context  # store for _reconnect_req!

        # Connect SUB socket for streaming output (non-blocking)
        if !isempty(conn.stream_endpoint)
            try
                sub = Socket(mgr.zmq_context, SUB)
                sub.rcvtimeo = 0  # non-blocking recv
                sub.linger = 0    # don't block on close
                subscribe(sub, "")  # receive all messages
                connect(sub, conn.stream_endpoint)
                conn.sub_socket = sub
            catch e
                @debug "Failed to connect stream socket" exception = e
            end
        end

        conn.status = :connected
        conn.last_seen = now()
        # Apply runtime gate options from persisted preferences.
        try
            set_mirror_repl!(conn, get_gate_mirror_repl_preference())
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

"""
Reset a poisoned REQ socket after a ZMQ timeout. REQ sockets enter
an invalid state when a send completes but recv times out — they can
never send again. The only fix is to close and reconnect.

Reuses the provided ZMQ context instead of creating a new one (which
leaked contexts and caused resource exhaustion).
"""
function _reconnect_req!(conn::REPLConnection)
    ctx = conn.zmq_context
    if ctx === nothing
        conn.req_socket = nothing
        conn.status = :disconnected
        return
    end
    old = conn.req_socket
    try
        old.linger = 0
        close(old)
    catch
    end
    try
        socket = Socket(ctx, REQ)
        socket.rcvtimeo = 5000
        socket.sndtimeo = 2000
        socket.linger = 0
        connect(socket, conn.endpoint)
        conn.req_socket = socket
    catch
        conn.req_socket = nothing
        conn.status = :disconnected
    end
end

# ── Eval / Communication ─────────────────────────────────────────────────────

function eval_remote(
    conn::REPLConnection,
    code::String;
    timeout_ms::Int = 30000,
    display_code::String = code,
)
    if conn.status != :connected || conn.req_socket === nothing
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Gate not connected (session=$(conn.session_id), status=$(conn.status))",
            backtrace = nothing,
        )
    end

    request = (type = :eval, code = code, display_code = display_code)
    lock(conn.req_lock) do
        try
            # Serialize and send
            io = IOBuffer()
            serialize(io, request)
            send(conn.req_socket, Message(take!(io)))

            # Receive response
            raw = recv(conn.req_socket)
            response = deserialize(IOBuffer(raw))
            conn.last_seen = now()
            conn.tool_call_count += 1
            return response
        catch e
            if e isa ZMQ.TimeoutError
                # REQ socket is now in a broken state (sent request, never got
                # reply). We must close and reconnect or all future calls fail.
                _reconnect_req!(conn)
                return (
                    stdout = "",
                    stderr = "",
                    value_repr = "",
                    exception = "Gate eval timed out after $(timeout_ms)ms",
                    backtrace = nothing,
                )
            end
            # Connection likely broken — mark disconnected
            conn.status = :disconnected
            return (
                stdout = "",
                stderr = "",
                value_repr = "",
                exception = "Gate communication error: $(sprint(showerror, e))",
                backtrace = nothing,
            )
        end
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
    timeout_ms::Int = 120000,
    display_code::String = code,
    on_output::Union{Function,Nothing} = nothing,
)
    if conn.status != :connected || conn.req_socket === nothing
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Gate not connected (session=$(conn.session_id), status=$(conn.status))",
            backtrace = nothing,
        )
    end

    # Generate a unique request ID to correlate response with this caller
    request_id = bytes2hex(rand(UInt8, 8))

    # Phase 1: Send eval_async request via REQ socket (short lock)
    conn.eval_state[] = EVAL_SENDING
    ack = lock(conn.req_lock) do
        try
            request = (
                type = :eval_async,
                code = code,
                display_code = display_code,
                request_id = request_id,
            )
            io = IOBuffer()
            serialize(io, request)
            send(conn.req_socket, Message(take!(io)))
            raw = recv(conn.req_socket)
            response = deserialize(IOBuffer(raw))
            conn.last_seen = now()
            return response
        catch e
            if e isa ZMQ.TimeoutError
                _reconnect_req!(conn)
                return (type = :error, message = "Gate eval_async handshake timed out")
            end
            conn.status = :disconnected
            return (
                type = :error,
                message = "Gate communication error: $(sprint(showerror, e))",
            )
        end
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

    # Register a per-request inbox channel
    my_inbox = Channel{Any}(32)
    lock(conn._eval_inboxes_lock) do
        conn._eval_inboxes[request_id] = my_inbox
    end

    deadline = time() + timeout_ms / 1000.0

    try
        while time() < deadline
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
                on_output !== nothing && on_output(ch, string(data))
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

        # Timeout
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Gate eval timed out after $(timeout_ms)ms (async streaming)",
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
    if conn.status != :connected || conn.req_socket === nothing
        return nothing
    end
    lock(conn.req_lock) do
        req = (type = :get_options,)
        try
            io = IOBuffer()
            serialize(io, req)
            send(conn.req_socket, Message(take!(io)))
            raw = recv(conn.req_socket)
            response = deserialize(IOBuffer(raw))
            conn.last_seen = now()
            return response
        catch e
            if e isa ZMQ.TimeoutError
                _reconnect_req!(conn)
            else
                conn.status = :disconnected
            end
            return nothing
        end
    end
end

function set_mirror_repl!(conn::REPLConnection, enabled::Bool)
    if conn.status != :connected || conn.req_socket === nothing
        return false
    end
    lock(conn.req_lock) do
        req = (type = :set_option, key = "mirror_repl", value = enabled)
        try
            io = IOBuffer()
            serialize(io, req)
            send(conn.req_socket, Message(take!(io)))
            raw = recv(conn.req_socket)
            response = deserialize(IOBuffer(raw))
            conn.last_seen = now()
            return get(response, :type, :error) == :ok
        catch e
            if e isa ZMQ.TimeoutError
                _reconnect_req!(conn)
            else
                conn.status = :disconnected
            end
            return false
        end
    end
end

"""
    set_tty!(conn, path) -> Bool

Send a `:set_tty` request to `conn`, detecting the terminal size, pausing the
remote shell via SIGSTOP, and disabling echo. Returns `true` on success.
Call `restore_tty!()` after the TUI exits to resume the shell and restore echo.
"""
function set_tty!(conn::REPLConnection, path::String)
    conn.status == :connected && conn.req_socket !== nothing || return false
    lock(conn.req_lock) do
        req = (type = :set_tty, path = path)
        try
            io = IOBuffer()
            serialize(io, req)
            send(conn.req_socket, Message(take!(io)))
            raw = recv(conn.req_socket)
            response = deserialize(IOBuffer(raw))
            conn.last_seen = now()
            return get(response, :type, :error) == :ok
        catch e
            if e isa ZMQ.TimeoutError
                _reconnect_req!(conn)
            else
                conn.status = :disconnected
            end
            return false
        end
    end
end

function ping(conn::REPLConnection; skip_if_busy::Bool = false)
    # When called from health check, skip if an eval is in progress —
    # the REQ socket is either locked or the gate is busy.
    # Check this BEFORE the socket check so it works even when the socket
    # is temporarily nil during reconnect.
    if skip_if_busy && conn.eval_state[] != EVAL_IDLE
        return (type = :pong, skipped = true)  # synthetic pong to avoid disconnect
    end
    if conn.status != :connected || conn.req_socket === nothing
        return nothing
    end

    lock(conn.req_lock) do
        try
            io = IOBuffer()
            serialize(io, (type = :ping,))
            send(conn.req_socket, Message(take!(io)))

            raw = recv(conn.req_socket)
            response = deserialize(IOBuffer(raw))
            conn.last_seen = now()
            conn.last_ping = now()
            return response
        catch e
            if e isa ZMQ.TimeoutError
                # REQ socket is poisoned after timeout — must reconnect
                _reconnect_req!(conn)
            else
                conn.status = :disconnected
            end
            return nothing
        end
    end
end

"""
    send_restart!(conn::REPLConnection) -> Bool

Send a `:restart` command to the gate. Returns `true` if the gate acknowledged.
The gate will exec a fresh Julia process after replying.
"""
function send_restart!(conn::REPLConnection)
    (conn.status != :connected || conn.req_socket === nothing) && return false
    lock(conn.req_lock) do
        try
            io = IOBuffer()
            serialize(io, (type = :restart, name = conn.name))
            send(conn.req_socket, Message(take!(io)))
            raw = recv(conn.req_socket)
            response = deserialize(IOBuffer(raw))
            conn.last_seen = now()
            return get(response, :type, :error) == :ok
        catch e
            if e isa ZMQ.TimeoutError
                _reconnect_req!(conn)
            else
                conn.status = :disconnected
            end
            return false
        end
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
            # Drain all pending messages (non-blocking due to rcvtimeo=0)
            while true
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

                if !routed
                    dname = isempty(conn.display_name) ? conn.name : conn.display_name
                    push!(messages, (channel = ch, data = data, session_name = dname))
                end

                # Forward stdout/stderr to all active inboxes during streaming
                # so on_output callbacks (SSE progress) can see them.
                # stdout/stderr aren't tagged with request_id (they come from
                # the REPL's stdout/stderr which is shared), so broadcast to all.
                if ch in ("stdout", "stderr") && conn.eval_state[] == EVAL_STREAMING
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
                            push!(mgr.connections, conn)
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
                    if conn.status == :connected
                        result = ping(conn; skip_if_busy = true)
                        if result !== nothing
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
                                    existing,
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
                                        conn.namespace = pong_ns
                                        _resolve_namespace!(conn, mgr)
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
                            @debug "Gate unresponsive, disconnecting" name = conn.name
                            disconnect!(conn)
                            if !isfile(conn.socket_path)
                                push!(to_remove, conn)
                            end
                        end
                    elseif conn.status == :disconnected
                        if isfile(conn.socket_path)
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
            if conn.status == :connected
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
        filter(c -> c.status == :connected, mgr.connections)
    end
end

"""First 8 chars of the session UUID — short, unique, token-efficient."""
short_key(conn::REPLConnection) = first(conn.session_id, 8)

"""Look up a connection by its 8-char short key. Returns nothing if not found."""
function get_connection_by_key(mgr::ConnectionManager, key::String)
    lock(mgr.lock) do
        for conn in mgr.connections
            if conn.status == :connected && startswith(conn.session_id, key)
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
    if conn.status != :connected || conn.req_socket === nothing
        return "Error: Gate not connected (session=$(conn.session_id))"
    end

    lock(conn.req_lock) do
        try
            request = (
                type = :tool_call,
                name = tool_name,
                arguments = Dict{String,Any}(string(k) => v for (k, v) in args),
            )
            io = IOBuffer()
            Serialization.serialize(io, request)
            send(conn.req_socket, Message(take!(io)))
            raw = recv(conn.req_socket)
            response = Serialization.deserialize(IOBuffer(raw))
            conn.last_seen = now()
            resp_type = get(response, :type, :error)
            if resp_type == :error
                return "Error: $(get(response, :message, "unknown"))"
            end
            return string(get(response, :value, ""))
        catch e
            if e isa ZMQ.TimeoutError
                _reconnect_req!(conn)
                return "Error: Gate tool call timed out"
            end
            conn.status = :disconnected
            return "Error: $(sprint(showerror, e))"
        end
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
    if conn.status != :connected || conn.req_socket === nothing
        return "Error: Gate not connected (session=$(conn.session_id))"
    end

    # Generate a unique request ID to correlate response with this caller
    request_id = bytes2hex(rand(UInt8, 8))

    # Phase 1: Send tool_call_async request via REQ socket (short lock)
    ack = lock(conn.req_lock) do
        try
            request = (
                type = :tool_call_async,
                name = tool_name,
                arguments = Dict{String,Any}(string(k) => v for (k, v) in args),
                request_id = request_id,
            )
            io = IOBuffer()
            Serialization.serialize(io, request)
            send(conn.req_socket, Message(take!(io)))
            raw = recv(conn.req_socket)
            response = Serialization.deserialize(IOBuffer(raw))
            conn.last_seen = now()
            return response
        catch e
            if e isa ZMQ.TimeoutError
                _reconnect_req!(conn)
                return (type = :error, message = "Gate tool_call_async handshake timed out")
            end
            conn.status = :disconnected
            return (
                type = :error,
                message = "Gate communication error: $(sprint(showerror, e))",
            )
        end
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
    my_inbox = Channel{Any}(32)
    lock(conn._eval_inboxes_lock) do
        conn._eval_inboxes[request_id] = my_inbox
    end

    try
        deadline = time() + timeout_ms / 1000.0
        while time() < deadline
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

        push!(tools, MCPTool(tool_id, tool_name, description, schema, handler))
    end

    return tools
end

"""
    _resolve_namespace!(conn, mgr) -> String

Resolve namespace collisions. If another connected session already owns the
same namespace prefix, add a dedup suffix (_2, _3, …). Updates `conn.namespace`
in place and returns the final namespace.
"""
function _resolve_namespace!(conn::REPLConnection, mgr::ConnectionManager)
    base_ns = conn.namespace
    isempty(base_ns) && return base_ns

    # Collect namespaces already in use by OTHER connected sessions
    taken = lock(mgr.lock) do
        Set(
            c.namespace for c in mgr.connections if
            c !== conn && c.status == :connected && !isempty(c.namespace)
        )
    end

    if base_ns ∉ taken
        return base_ns
    end

    # Collision — add dedup suffix
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

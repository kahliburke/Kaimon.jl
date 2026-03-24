# ── Extension Process Manager ─────────────────────────────────────────────────
# Manages Julia subprocesses for Kaimon extensions. Each extension runs in its
# own isolated process with its own project environment and connects back as
# a gate session.

"""
    ManagedExtension

Tracks the lifecycle of a managed extension subprocess.
"""
mutable struct ManagedExtension
    config::ExtensionConfig
    process::Union{Base.Process,Nothing}
    status::Symbol          # :stopped, :starting, :running, :crashed, :stopping
    started_at::Float64     # time() when last started
    last_heartbeat::Float64 # time() of last confirmed alive
    restart_count::Int
    session_key::String     # gate session key once connected (8-char)
    error_log::Vector{String}
    log_file::String        # path to stderr/stdout log
end

function ManagedExtension(config::ExtensionConfig)
    log_dir = joinpath(kaimon_cache_dir(), "extensions")
    mkpath(log_dir)
    log_file = joinpath(log_dir, "$(config.manifest.namespace).log")
    ManagedExtension(config, nothing, :stopped, 0.0, 0.0, 0, "", String[], log_file)
end

# ── Global state ─────────────────────────────────────────────────────────────

const MANAGED_EXTENSIONS = ManagedExtension[]
const MANAGED_EXTENSIONS_LOCK = ReentrantLock()

function _push_error!(ext::ManagedExtension, msg::String)
    push!(ext.error_log, msg)
    length(ext.error_log) > 20 && deleteat!(ext.error_log, 1:length(ext.error_log) - 20)
end

# ── Spawn / Stop / Restart ───────────────────────────────────────────────────

"""
    _build_extension_script(config::ExtensionConfig) -> String

Generate the Julia `-e` script that boots the extension subprocess.
"""
function _build_extension_script(config::ExtensionConfig)
    m = config.manifest
    e = config.entry
    # The subprocess is launched with --project=<extension path>, so the
    # extension package and its deps are available immediately.
    # Kaimon is added to LOAD_PATH explicitly so it doesn't need to be
    # in the user's global environment.
    kaimon_dir = pkgdir(Kaimon)
    on_shutdown_kwarg = if !isempty(m.shutdown_function)
        ", on_shutdown=$(m.module_name).$(m.shutdown_function)"
    else
        ""
    end
    event_hook = if !isempty(m.event_topics)
        # If the extension wants events, start a PULL socket after serve()
        # and call the module's event handler in a background loop.
        """
    # Event forwarding: create PULL socket for Kaimon to push events to
    using Serialization
    let sid = Kaimon.Gate._SESSION_ID[]
        sock_path = joinpath(Kaimon.Gate.SOCK_DIR, "\$(sid).events.sock")
        pull = Kaimon.ZMQ.Socket(Kaimon.Gate._GATE_CONTEXT[], Kaimon.ZMQ.PULL)
        Kaimon.ZMQ.bind(pull, "ipc://\$sock_path")
        @async begin
            while true
                try
                    raw = Kaimon.ZMQ.recv(pull)
                    msg = deserialize(IOBuffer(raw))
                    $(m.module_name).on_event(msg.channel, msg.data, msg.session_name)
                catch e
                    e isa InterruptException && break
                    @debug "Event recv error" exception=e
                    sleep(0.1)
                end
            end
        end
    end"""
    else
        ""
    end

    return """
    try
        using Revise
    catch; end
    insert!(LOAD_PATH, 1, $(repr(kaimon_dir)))
    using Kaimon
    # Auto-flushing logger so extension output is visible immediately in the log file
    using LoggingExtras, Logging, Dates
    let _fmt = DateFormat("HH:MM:SS")
        global_logger(MinLevelLogger(
            FormatLogger(stderr; always_flush=true) do io, args
                println(io, "[", Dates.format(now(), _fmt), " ", args.level, "] ", args.message)
            end,
            Logging.Info,
        ))
    end
    using $(m.module_name)
    tools = $(m.module_name).$(m.tools_function)(Kaimon.Gate.GateTool)
    Kaimon.Gate.serve(tools=tools, namespace=$(repr(m.namespace)), force=true, allow_mirror=false, allow_restart=false, spawned_by="extension"$on_shutdown_kwarg)
    $event_hook
    while true; sleep(60); end
    """
end

"""
    spawn_extension!(ext::ManagedExtension)

Launch the extension subprocess. Non-blocking.
"""
function spawn_extension!(ext::ManagedExtension)
    ext.status == :running && return

    # Kill any existing process before spawning a new one.
    # This prevents orphan processes when an extension is marked as crashed
    # (e.g. startup timeout) but the old process is still alive.
    if ext.process !== nothing && Base.process_running(ext.process)
        try
            kill(ext.process, Base.SIGTERM)
            # Give it a moment to exit gracefully
            t0 = time()
            while Base.process_running(ext.process) && time() - t0 < 3.0
                sleep(0.1)
            end
            if Base.process_running(ext.process)
                kill(ext.process, Base.SIGKILL)
            end
        catch
        end
    end
    ext.process = nothing

    ext.status = :starting
    ext.started_at = time()
    empty!(ext.error_log)

    script = _build_extension_script(ext.config)
    log_io = nothing

    try
        # Use julia with threads for responsiveness.
        # Clear JULIA_LOAD_PATH and JULIA_PROJECT so --project controls the
        # active environment and the default LOAD_PATH ["@", "@v#.#", "@stdlib"]
        # is used.  The parent process may have these set (e.g. from the launcher).
        julia_bin = joinpath(Sys.BINDIR, "julia")
        project = ext.config.entry.project_path
        env = copy(ENV)
        delete!(env, "JULIA_LOAD_PATH")
        delete!(env, "JULIA_PROJECT")
        flags = ext.config.manifest.julia_flags
        if isempty(flags)
            flags = ["-t", "auto"]
        end
        cmd = setenv(`$julia_bin $flags --startup-file=no --project=$project -e $script`, env)

        # Redirect output to log file
        log_io = open(ext.log_file, "a")
        println(log_io, "\n--- Extension $(ext.config.manifest.namespace) starting at $(Dates.now()) ---")
        flush(log_io)

        proc = run(pipeline(cmd; stdout = log_io, stderr = log_io); wait = false)
        ext.process = proc
        ext.status = :starting
        ext.last_heartbeat = time()

        # Background task to detect process exit
        @async begin
            try
                wait(proc)
            catch
            end
            # Process exited — update status if we haven't already stopped it
            if ext.status in (:starting, :running)
                prev = ext.status
                ext.status = :crashed
                uptime_s = round(time() - ext.started_at, digits=1)
                exit_code = try; proc.exitcode; catch; "unknown"; end
                _push_error!(ext, "Process exited at $(Dates.now()) (exit=$exit_code)")
                _push_log!(
                    :warn,
                    "Extension '$(ext.config.manifest.namespace)' crashed (was $prev, exit=$exit_code, after $(uptime_s)s)",
                )
            end
            try
                close(log_io)
            catch
            end
        end

        flags_str = join(flags, " ")
        _push_log!(:info, "Extension '$(ext.config.manifest.namespace)' spawning (PID=$(getpid(proc)), flags: $flags_str)")
    catch e
        if log_io !== nothing
            try; close(log_io); catch; end
        end
        ext.status = :crashed
        _push_error!(ext, "Spawn failed: $(sprint(showerror, e))")
        _push_log!(
            :error,
            "Failed to spawn extension '$(ext.config.manifest.namespace)': $(sprint(showerror, e))",
        )
    end
end

"""
    stop_extension!(ext::ManagedExtension; timeout::Float64=5.0)

Stop an extension subprocess gracefully, then force-kill after timeout.
"""
function stop_extension!(ext::ManagedExtension; timeout::Float64 = 5.0)
    ext.status == :stopped && return
    ext.status = :stopping

    proc = ext.process
    if proc !== nothing && Base.process_running(proc)
        # Try graceful gate shutdown first — this lets the on_shutdown hook run
        gate_ok = _try_gate_shutdown!(ext)

        if gate_ok
            # Gate acknowledged — wait for the process to exit cleanly
            deadline = time() + timeout
            while Base.process_running(proc) && time() < deadline
                sleep(0.1)
            end
        end

        # Fall back to SIGTERM if gate shutdown didn't work or process is still alive
        if Base.process_running(proc)
            try
                kill(proc, Base.SIGTERM)
            catch
            end

            deadline = time() + timeout
            while Base.process_running(proc) && time() < deadline
                sleep(0.1)
            end
        end

        # Force kill if still running
        if Base.process_running(proc)
            try
                kill(proc, Base.SIGKILL)
            catch
            end
        end
    end

    # Clean up event forwarding before clearing state
    mgr = GATE_CONN_MGR[]
    mgr !== nothing && _cleanup_event_listener!(mgr, ext)

    uptime = ext.started_at > 0 ? format_uptime(time() - ext.started_at) : "n/a"
    ext.process = nothing
    ext.status = :stopped
    ext.session_key = ""
    _push_log!(:info, "Extension '$(ext.config.manifest.namespace)' stopped (uptime: $uptime)")
end

"""
    _try_gate_shutdown!(ext::ManagedExtension) -> Bool

Attempt to send a `:shutdown` command to the extension's gate connection.
Returns `true` if the gate acknowledged the shutdown request.
"""
function _try_gate_shutdown!(ext::ManagedExtension)
    mgr = GATE_CONN_MGR[]
    mgr === nothing && return false
    ns = ext.config.manifest.namespace

    # Find the extension's connection by namespace
    conn = nothing
    for c in connected_sessions(mgr)
        if c.namespace == ns
            conn = c
            break
        end
    end
    conn === nothing && return false

    try
        return send_shutdown!(conn)
    catch e
        _push_log!(:debug, "Gate shutdown failed for '$ns': $(sprint(showerror, e))")
        return false
    end
end

"""
    restart_extension!(ext::ManagedExtension)

Stop then re-spawn an extension.
"""
function restart_extension!(ext::ManagedExtension)
    ns = ext.config.manifest.namespace
    stop_extension!(ext)
    ext.restart_count += 1
    _push_log!(:info, "Extension '$ns' restarting (attempt #$(ext.restart_count))")
    spawn_extension!(ext)
end

# ── Event Forwarding ─────────────────────────────────────────────────────────

# Active PUSH sockets for event forwarding, keyed by extension namespace
const _EXT_EVENT_SOCKETS = Dict{String,ZMQ.Socket}()
const _EXT_EVENT_SOCKETS_LOCK = ReentrantLock()

"""
    _event_socket_path(session_id::String) -> String

Convention-based IPC path for the extension's event PULL socket.
"""
function _event_socket_path(session_id::String)
    joinpath(kaimon_cache_dir(), "sock", "$(session_id).events.sock")
end

"""
    _maybe_register_event_listener!(conn_mgr, ext)

If the extension declares event_topics, connect a PUSH socket to the
extension's PULL socket and register an event listener on the connection manager.
"""
function _maybe_register_event_listener!(conn_mgr, ext::ManagedExtension)
    topics = ext.config.manifest.event_topics
    isempty(topics) && return

    ns = ext.config.manifest.namespace

    # Find the full session_id for the socket path (session_key is only first 8 chars)
    full_sid = ""
    for conn in connected_sessions(conn_mgr)
        if conn.namespace == ns
            full_sid = conn.session_id
            break
        end
    end
    isempty(full_sid) && return
    sock_path = _event_socket_path(full_sid)

    # Wait briefly for the extension to create its PULL socket
    # (it may still be initializing)
    deadline = time() + 5.0
    while !ispath(sock_path) && time() < deadline
        sleep(0.2)
    end
    if !ispath(sock_path)
        _push_log!(:warn, "Extension '$ns' event socket not found at $sock_path")
        return
    end

    try
        push_sock = Socket(conn_mgr.zmq_context, PUSH)
        push_sock.sndtimeo = 100  # 100ms send timeout — don't block on slow extensions
        push_sock.linger = 0
        push_sock.sndhwm = 1000   # drop events if extension can't keep up
        ZMQ.connect(push_sock, "ipc://$sock_path")

        lock(_EXT_EVENT_SOCKETS_LOCK) do
            # Close any existing socket for this namespace
            if haskey(_EXT_EVENT_SOCKETS, ns)
                try; close(_EXT_EVENT_SOCKETS[ns]); catch; end
            end
            _EXT_EVENT_SOCKETS[ns] = push_sock
        end

        topic_set = Set{String}(topics)
        callback = function(channel::String, data::String, session_name::String)
            sock = lock(_EXT_EVENT_SOCKETS_LOCK) do
                get(_EXT_EVENT_SOCKETS, ns, nothing)
            end
            sock === nothing && return
            try
                io = IOBuffer()
                serialize(io, (channel=channel, data=data, session_name=session_name))
                send(sock, Message(take!(io)))
            catch
                # Send failed — extension may be gone, will be cleaned up on stop
            end
        end
        listener = EventListener(ns, topic_set, callback)

        add_event_listener!(conn_mgr, listener)
        _push_log!(:info, "Extension '$ns' event forwarding registered (topics: $(join(topics, ", ")))")
    catch e
        _push_log!(:warn, "Failed to set up event forwarding for '$ns': $(sprint(showerror, e))")
    end
end

"""
    _cleanup_event_listener!(conn_mgr, ext)

Remove the event listener and close the PUSH socket for an extension.
"""
function _cleanup_event_listener!(conn_mgr, ext::ManagedExtension)
    ns = ext.config.manifest.namespace
    isempty(ext.config.manifest.event_topics) && return

    if conn_mgr !== nothing
        remove_event_listener!(conn_mgr, ns)
    end

    lock(_EXT_EVENT_SOCKETS_LOCK) do
        if haskey(_EXT_EVENT_SOCKETS, ns)
            try; close(_EXT_EVENT_SOCKETS[ns]); catch; end
            delete!(_EXT_EVENT_SOCKETS, ns)
        end
    end

    # Remove stale event socket file so a restart gets a clean path
    if conn_mgr !== nothing && !isempty(ext.session_key)
        for conn in connected_sessions(conn_mgr)
            if conn.namespace == ns
                sock_path = _event_socket_path(conn.session_id)
                try; isfile(sock_path) && rm(sock_path); catch; end
                break
            end
        end
    end
end

# ── Monitor ──────────────────────────────────────────────────────────────────

const _EXTENSION_RESTART_BACKOFF = [5.0, 10.0, 30.0, 60.0]  # seconds

"""
    _monitor_extensions!(conn_mgr)

Called periodically from the TUI view tick. Checks extension health:
- Matches gate sessions to extensions by namespace
- Detects crashed processes and restarts with backoff
- Updates status from :starting to :running when gate connects
"""
function _monitor_extensions!(conn_mgr)
    conn_mgr === nothing && return
    lock(MANAGED_EXTENSIONS_LOCK) do
        for ext in MANAGED_EXTENSIONS
            ns = ext.config.manifest.namespace

            if ext.status == :starting || ext.status == :running
                # Check if process is still alive
                proc = ext.process
                if proc !== nothing && !Base.process_running(proc)
                    if ext.status != :crashed
                        ext.status = :crashed
                        _push_error!(ext, "Process died at $(Dates.now())")
                    end
                end
            end

            if ext.status == :starting
                # Look for a matching gate session by namespace
                for conn in connected_sessions(conn_mgr)
                    if conn.namespace == ns
                        ext.status = :running
                        ext.session_key = short_key(conn)
                        ext.last_heartbeat = time()
                        n_tools = length(conn.session_tools)
                        elapsed = round(time() - ext.started_at, digits=1)
                        _push_log!(
                            :info,
                            "Extension '$ns' ready — $n_tools tools, session=$(ext.session_key), started in $(elapsed)s",
                        )
                        # Register event listener if extension declares event_topics
                        # (async to avoid blocking the monitor lock with socket wait)
                        if !isempty(ext.config.manifest.event_topics)
                            let ext=ext, conn_mgr=conn_mgr
                                Threads.@spawn _maybe_register_event_listener!(conn_mgr, ext)
                            end
                        end
                        break
                    end
                end

                # Timeout: if starting for >60s, mark as crashed
                if ext.status == :starting && time() - ext.started_at > 60.0
                    ext.status = :crashed
                    _push_error!(ext, "Startup timeout at $(Dates.now())")
                    _push_log!(:warn, "Extension '$ns' startup timed out")
                end
            end

            if ext.status == :running
                ext.last_heartbeat = time()
            end

            if ext.status == :crashed && ext.config.entry.auto_start
                # Auto-restart with backoff
                backoff_idx = min(ext.restart_count + 1, length(_EXTENSION_RESTART_BACKOFF))
                backoff = _EXTENSION_RESTART_BACKOFF[backoff_idx]
                if time() - ext.started_at > backoff
                    _push_log!(
                        :info,
                        "Auto-restarting extension '$ns' (attempt $(ext.restart_count + 1))",
                    )
                    ext.restart_count += 1
                    spawn_extension!(ext)
                end
            end
        end
    end
end

# ── Lifecycle hooks ──────────────────────────────────────────────────────────

"""
    start_extensions!()

Load extension configs and spawn all enabled+auto_start extensions.
Called from TUI init.
"""
function start_extensions!()
    configs = load_extension_configs()
    lock(MANAGED_EXTENSIONS_LOCK) do
        empty!(MANAGED_EXTENSIONS)
        for config in configs
            ext = ManagedExtension(config)
            push!(MANAGED_EXTENSIONS, ext)
            if config.entry.enabled && config.entry.auto_start
                spawn_extension!(ext)
            end
        end
    end
    if !isempty(configs)
        n_auto = count(c -> c.entry.enabled && c.entry.auto_start, configs)
        names = join([c.manifest.namespace for c in configs], ", ")
        _push_log!(:info, "Loaded $(length(configs)) extension(s): $names ($n_auto auto-starting)")
    end
end

"""
    stop_all_extensions!()

Stop all managed extension processes. Called from TUI cleanup.
"""
function stop_all_extensions!()
    lock(MANAGED_EXTENSIONS_LOCK) do
        for ext in MANAGED_EXTENSIONS
            try
                stop_extension!(ext)
            catch
            end
        end
    end
end

"""
    get_managed_extensions() -> Vector{ManagedExtension}

Thread-safe snapshot of current managed extensions.
"""
function get_managed_extensions()
    lock(MANAGED_EXTENSIONS_LOCK) do
        copy(MANAGED_EXTENSIONS)
    end
end

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

"""Send SIGTERM, wait up to 3s, then SIGKILL if still alive."""
function _kill_process!(proc::Base.Process)
    try
        kill(proc, Base.SIGTERM)
        t0 = time()
        while Base.process_running(proc) && time() - t0 < 3.0
            sleep(0.1)
        end
        Base.process_running(proc) && kill(proc, Base.SIGKILL)
    catch
    end
end

"""
    _kill_orphan_extension_processes!(project_path, namespace)

Find and kill any Julia processes marked as Kaimon extensions for the same
namespace. Uses the KAIMON_EXTENSION env var set on spawned processes to
positively identify Kaimon-owned processes (won't accidentally kill user processes).
"""
function _kill_orphan_extension_processes!(project_path::String, namespace::String)
    Sys.isunix() || return
    my_pid = getpid()
    try
        # Read /proc/<pid>/environ on Linux, or use ps -E on macOS
        if Sys.isapple()
            # On macOS, ps -E shows environment. Use pgrep to find julia processes,
            # then check their environment via /proc simulation or launchctl.
            # Simpler: check command line for the spawned_by marker AND project path
            out = read(pipeline(`pgrep -f julia`; stderr=devnull), String)
        else
            out = read(pipeline(`pgrep -f julia`; stderr=devnull), String)
        end
        for line in split(strip(out), '\n')
            isempty(line) && continue
            pid = tryparse(Int, strip(line))
            pid === nothing && continue
            pid == my_pid && continue
            # Check if this process has our KAIMON_EXTENSION env var
            is_our_extension = false
            try
                if Sys.islinux()
                    # Linux: read /proc/pid/environ
                    environ = read("/proc/$pid/environ", String)
                    is_our_extension = contains(environ, "KAIMON_EXTENSION=$namespace")
                else
                    # macOS: fall back to command-line matching (env not easily readable)
                    cmdline = read(pipeline(`ps -p $pid -o command=`; stderr=devnull), String)
                    is_our_extension = contains(cmdline, project_path) &&
                        contains(cmdline, "spawned_by=\"extension\"")
                end
            catch
            end
            if is_our_extension
                _push_log!(:info, "Killing orphan extension '$namespace' (PID=$pid)")
                try
                    run(pipeline(`kill $pid`; stderr=devnull); wait=false)
                    sleep(1.0)
                    # Force kill if still alive
                    try
                        run(pipeline(`kill -0 $pid`; stderr=devnull))
                        run(pipeline(`kill -9 $pid`; stderr=devnull); wait=false)
                    catch; end
                catch; end
            end
        end
    catch
        # pgrep not available or no matches
    end
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
    on_shutdown_kwarg = if !isempty(m.shutdown_function)
        ", on_shutdown=$(m.module_name).$(m.shutdown_function)"
    else
        ""
    end
    event_hook = if !isempty(m.event_topics)
        # Subscribe to Kaimon's global event PUB socket with topic filtering.
        # Uses recv(sub, Vector{UInt8}) to avoid Message finalizer segfaults.
        topics_code = join(["Kaimon.ZMQ.subscribe(sub, $(repr(t)))" for t in m.event_topics], "\n        ")
        """
    # Event subscription: connect SUB to Kaimon's global event PUB
    using Serialization
    let sock_dir = Kaimon.Gate.SOCK_DIR
        sub = Kaimon.ZMQ.Socket(Kaimon.Gate._GATE_CONTEXT[], Kaimon.ZMQ.SUB)
        sub.rcvtimeo = 1000  # 1s timeout so loop can check for shutdown
        Kaimon.ZMQ.connect(sub, "ipc://\$(sock_dir)/kaimon-events.sock")
        $topics_code
        @async begin
            while true
                try
                    topic = Kaimon.ZMQ.recv(sub, String)       # frame 1: channel name
                    payload = Kaimon.ZMQ.recv(sub, Vector{UInt8})  # frame 2: serialized data
                    msg = deserialize(IOBuffer(payload))
                    $(m.module_name).on_event(msg.channel, msg.data, msg.session_name)
                catch e
                    e isa InterruptException && break
                    e isa Kaimon.ZMQ.TimeoutError && continue
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
    try; import Pkg; Pkg.resolve(io=devnull); catch e; @warn "Pkg.resolve failed" exception=e; end
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
        _kill_process!(ext.process)
    end
    ext.process = nothing

    # Also kill any orphan processes from previous Kaimon instances that match
    # this extension's project path. These survive TUI restarts because the
    # Process handle is lost but the Julia process keeps running.
    _kill_orphan_extension_processes!(ext.config.entry.project_path, ext.config.manifest.namespace)

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
        # Default LOAD_PATH: extension project (@), global env (@v#.#), stdlib
        # Kaimon is installed in the global env, so @v#.# provides it.
        env["JULIA_LOAD_PATH"] = "@:@v#.#:@stdlib"
        delete!(env, "JULIA_PROJECT")
        # Mark this process as Kaimon-spawned so we can identify orphans
        env["KAIMON_EXTENSION"] = ext.config.manifest.namespace
        env["KAIMON_PARENT_PID"] = string(getpid())
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
                # Cap auto-restart attempts to prevent infinite respawning
                max_restarts = 5
                if ext.restart_count >= max_restarts
                    if ext.restart_count == max_restarts  # log once
                        _push_log!(:warn, "Extension '$ns' exceeded max restarts ($max_restarts), giving up")
                        ext.restart_count += 1  # prevent repeat logging
                    end
                    continue
                end
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
    exts = lock(MANAGED_EXTENSIONS_LOCK) do
        copy(MANAGED_EXTENSIONS)
    end
    isempty(exts) && return

    # Send gate shutdown to all extensions in parallel so they can run
    # their cleanup hooks concurrently (up to 5s each)
    tasks = Task[]
    for ext in exts
        if ext.status in (:running, :starting)
            push!(tasks, Threads.@spawn try
                stop_extension!(ext; timeout=5.0)
            catch
            end)
        end
    end

    # Wait for all to finish (bounded by the per-extension timeout)
    for t in tasks
        try; wait(t); catch; end
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

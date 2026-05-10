# ── Session Process Manager ──────────────────────────────────────────────────
# Manages Julia subprocesses spawned by agents. Each session runs in its own
# process with its own project environment and connects back as a gate session.
# Mirrors the extension_manager.jl pattern.

"""
    ManagedSession

Tracks the lifecycle of a managed session subprocess spawned by an agent.
"""
mutable struct ManagedSession
    project_path::String
    name::String
    process::Union{Base.Process,Nothing}
    pty::Any                # Union{Tachikoma.PTY, Nothing} — PTY handle for terminal access
    status::Symbol          # :stopped, :starting, :running, :crashed
    started_at::Float64     # time() when last started
    session_key::String     # gate session key once connected (8-char)
    error_log::Vector{String}
    log_file::String        # path to stderr/stdout log
end

function ManagedSession(project_path::String; name::String = "")
    if isempty(name)
        name = basename(project_path)
    end
    log_dir = joinpath(kaimon_cache_dir(), "sessions")
    mkpath(log_dir)
    log_file = joinpath(log_dir, "$(basename(project_path)).log")
    ManagedSession(project_path, name, nothing, nothing, :stopped, 0.0, "", String[], log_file)
end

"""Return the PID of a managed session (from PTY or Process)."""
session_pid(ms::ManagedSession) =
    ms.pty !== nothing ? Int(ms.pty.child_pid) : (ms.process !== nothing ? getpid(ms.process) : 0)

# ── Global state ─────────────────────────────────────────────────────────────

const MANAGED_SESSIONS = ManagedSession[]
const MANAGED_SESSIONS_LOCK = ReentrantLock()

function _push_session_error!(ms::ManagedSession, msg::String)
    push!(ms.error_log, msg)
    length(ms.error_log) > 20 && deleteat!(ms.error_log, 1:length(ms.error_log) - 20)
end

# ── Spawn / Stop ─────────────────────────────────────────────────────────────

"""
    _build_session_script(project_path; name="") -> String

Generate the Julia `-e` script that boots a session subprocess.
"""
function _build_session_script(project_path::String;
                               name::String = "",
                               allow_restart::Bool = true)
    # The subprocess is launched with --project=<path>, so the project and its
    # deps are available immediately.  Kaimon is added to LOAD_PATH so it
    # doesn't need to be in the user's global environment.
    kaimon_dir = pkgdir(Kaimon)
    return """
    try; using Revise; catch; end
    insert!(LOAD_PATH, 1, $(repr(kaimon_dir)))
    using Kaimon
    import Pkg; Pkg.instantiate(; io=devnull)
    @async Kaimon.Gate.serve(force=true, allow_mirror=true, allow_restart=$(allow_restart), spawned_by="agent")
    """
end

"""
    _resolve_launch_config(project_path::String) -> LaunchConfig

Look up the LaunchConfig for a project from the projects config.
Returns default LaunchConfig if not found.
"""
function _resolve_launch_config(project_path::String)
    norm_path = normalize_path(project_path)
    entries = load_projects_config()
    for entry in entries
        entry_norm = normalize_path(entry.project_path)
        entry_norm == norm_path && return entry.launch_config
    end
    return LaunchConfig()
end

"""
    _build_julia_cmd(lc::LaunchConfig, script::String; project::String="") -> Vector{String}

Build the Julia command array from a LaunchConfig and boot script.
"""
function _build_julia_cmd(lc::LaunchConfig, script::String; project::String = "")
    julia_bin = joinpath(Sys.BINDIR, "julia")
    cmd = [julia_bin, "-i"]

    # Threads: use config or default to "auto"
    threads = isempty(lc.threads) ? "auto" : lc.threads
    append!(cmd, ["-t", threads])

    # GC threads (only if set)
    !isempty(lc.gcthreads) && push!(cmd, "--gcthreads=$(lc.gcthreads)")

    # Heap size hint (only if set)
    !isempty(lc.heap_size_hint) && push!(cmd, "--heap-size-hint=$(lc.heap_size_hint)")

    # Extra flags
    append!(cmd, lc.extra_flags)

    # Project activation via --project flag
    !isempty(project) && push!(cmd, "--project=$project")

    # Always include startup-file=no and the boot script
    append!(cmd, ["--startup-file=no", "-e", script])

    return cmd
end

"""
    spawn_session!(ms::ManagedSession)

Launch the session subprocess. Non-blocking.
"""
function spawn_session!(ms::ManagedSession)
    ms.status == :running && return
    ms.status = :starting
    ms.started_at = time()
    empty!(ms.error_log)

    # Resolve per-session allow_restart preference
    ar = let
        sp = load_session_prefs()
        v = resolve_session_pref(sp, ms.project_path, :allow_restart)
        v !== nothing ? v : true  # default: restart allowed
    end
    script = _build_session_script(ms.project_path; name = ms.name, allow_restart = ar)

    try
        lc = _resolve_launch_config(ms.project_path)
        cmd = _build_julia_cmd(lc, script; project = ms.project_path)
        # Override JULIA_LOAD_PATH to restore the default ["@", "@v#.#", "@stdlib"]
        # and clear JULIA_PROJECT so --project controls the active environment,
        # matching the behavior of running `julia --project=<path>` from the shell.
        # (pty_spawn merges env into the parent ENV, so we set explicit values.)
        env = Dict{String,String}(
            "JULIA_LOAD_PATH" => "@:@v#.#:@stdlib",
            "JULIA_PROJECT" => "",
        )
        pty = Tachikoma.pty_spawn(cmd; rows = 24, cols = 80, env)
        ms.pty = pty
        ms.process = nothing
        ms.status = :starting

        # Open log file and tee PTY output to disk so crashed sessions leave
        # a forensic trail. The TerminalWidget overrides `on_data` if/when the
        # user opens the session viewer, at which point logging stops and the
        # widget takes over consumption of the channel.
        log_io = try
            io = open(ms.log_file, "a")
            println(io, "\n--- Session $(ms.name) starting at $(Dates.now()) (PID=$(Int(pty.child_pid))) ---")
            flush(io)
            io
        catch e
            _push_log!(
                :warn,
                "Could not open session log $(ms.log_file): $(sprint(showerror, e))",
            )
            nothing
        end

        if log_io !== nothing
            pty.on_data = let log_io = log_io, ch = pty.output
                () -> begin
                    while isready(ch)
                        data = try
                            take!(ch)
                        catch
                            break
                        end
                        try
                            write(log_io, data)
                            flush(log_io)
                        catch
                        end
                    end
                end
            end
        end

        # Background task to detect PTY/process exit
        @async begin
            while Tachikoma.pty_alive(pty)
                sleep(2.0)
            end
            if ms.status in (:starting, :running)
                ms.status = :crashed
                _push_session_error!(ms, "Process exited at $(Dates.now())")
                _push_log!(
                    :warn,
                    "Managed session '$(ms.name)' process exited unexpectedly",
                )
            end
            # Final drain and close log
            if log_io !== nothing
                try
                    while isready(pty.output)
                        data = try
                            take!(pty.output)
                        catch
                            break
                        end
                        write(log_io, data)
                    end
                    println(log_io, "--- Session $(ms.name) exited at $(Dates.now()) ---")
                catch
                end
                try
                    close(log_io)
                catch
                end
            end
        end

        _push_log!(:info, "Session '$(ms.name)' subprocess spawning (PID=$(Int(pty.child_pid)))")
    catch e
        ms.status = :crashed
        _push_session_error!(ms, "Spawn failed: $(sprint(showerror, e))")
        _push_log!(
            :error,
            "Failed to spawn session '$(ms.name)': $(sprint(showerror, e))",
        )
    end
end

"""
    stop_session!(ms::ManagedSession; timeout::Float64=5.0)

Stop a session subprocess gracefully, then force-kill after timeout.
"""
function stop_session!(ms::ManagedSession; timeout::Float64 = 5.0)
    ms.status == :stopped && return
    prev_status = ms.status
    ms.status = :stopped

    # PTY-based session
    if ms.pty !== nothing
        try
            Tachikoma.pty_close!(ms.pty)
        catch
        end
        ms.pty = nothing
    end

    # Legacy pipeline-based session
    proc = ms.process
    if proc !== nothing && Base.process_running(proc)
        try
            kill(proc, Base.SIGTERM)
        catch
        end

        deadline = time() + timeout
        while Base.process_running(proc) && time() < deadline
            sleep(0.1)
        end

        if Base.process_running(proc)
            try
                kill(proc, Base.SIGKILL)
            catch
            end
        end
    end

    ms.process = nothing
    ms.session_key = ""
    _push_log!(:info, "Session '$(ms.name)' stopped")
end

"""
    stop_all_sessions!()

Stop all managed session processes. Called from TUI cleanup.
"""
function stop_all_sessions!()
    lock(MANAGED_SESSIONS_LOCK) do
        for ms in MANAGED_SESSIONS
            try
                stop_session!(ms)
            catch
            end
        end
    end
end

# ── Monitor ──────────────────────────────────────────────────────────────────

"""
    _monitor_managed_sessions!(conn_mgr)

Called periodically from the TUI view tick. Checks session health:
- Matches gate sessions to managed sessions by project_path
- Detects crashed processes
- Updates status from :starting to :running when gate connects
- No auto-restart (agent retries manually)
"""
function _monitor_managed_sessions!(conn_mgr)
    conn_mgr === nothing && return

    # Snapshot under lock — all slow I/O happens outside the lock
    sessions = lock(MANAGED_SESSIONS_LOCK) do
        copy(MANAGED_SESSIONS)
    end

    conns = connected_sessions(conn_mgr)

    for ms in sessions
        if ms.status == :starting || ms.status == :running
            # Check if process is still alive (PTY or legacy pipeline)
            alive = if ms.pty !== nothing
                Tachikoma.pty_alive(ms.pty)
            elseif ms.process !== nothing
                Base.process_running(ms.process)
            else
                false
            end
            if !alive
                if ms.status != :crashed
                    ms.status = :crashed
                    _push_session_error!(ms, "Process died at $(Dates.now())")
                end
            end
        end

        if ms.status == :starting
            # Look for a matching gate session by project_path
            norm_path = try
                realpath(ms.project_path)
            catch
                ms.project_path
            end
            for conn in conns
                conn_norm = try
                    realpath(conn.project_path)
                catch
                    conn.project_path
                end
                if conn_norm == norm_path && conn.spawned_by == "agent"
                    ms.status = :running
                    ms.session_key = short_key(conn)
                    _push_log!(
                        :info,
                        "Session '$(ms.name)' connected (session=$(ms.session_key))",
                    )
                    break
                end
            end

            # Timeout: if starting for >120s, mark as crashed
            if ms.status == :starting && time() - ms.started_at > 120.0
                ms.status = :crashed
                _push_session_error!(ms, "Startup timeout at $(Dates.now())")
                _push_log!(:warn, "Session '$(ms.name)' startup timed out")
            end
        end
    end
end

"""
    get_managed_sessions() -> Vector{ManagedSession}

Thread-safe snapshot of current managed sessions.
"""
function get_managed_sessions()
    lock(MANAGED_SESSIONS_LOCK) do
        copy(MANAGED_SESSIONS)
    end
end

"""
    find_managed_session(project_path::String) -> Union{ManagedSession,Nothing}

Find a managed session by project path (normalized).
"""
function find_managed_session(project_path::String)
    norm_path = try
        realpath(project_path)
    catch
        project_path
    end
    sessions = lock(MANAGED_SESSIONS_LOCK) do
        copy(MANAGED_SESSIONS)
    end
    for ms in sessions
        ms_norm = try
            realpath(ms.project_path)
        catch
            ms.project_path
        end
        ms_norm == norm_path && return ms
    end
    return nothing
end

# ── Session Process Manager ──────────────────────────────────────────────────
# Manages Julia subprocesses spawned by agents. Each session runs in its own
# process with its own project environment and connects back as a gate session.
# Mirrors the extension_manager.jl pattern.

"""
    ManagedSession

Tracks the lifecycle of a managed session subprocess spawned by an agent.

`owner` is the MCP session id of the agent that started it privately (see `start_session`'s
`private`), or `""` for a shared session. A private session is never handed to another agent
by `start_session` or picked for it by automatic binding.
"""
mutable struct ManagedSession
    project_path::String
    name::String
    process::Union{Base.Process,Nothing}
    pty::Any                # Union{Tachikoma.PTY, Nothing} — PTY handle for terminal access
    status::Symbol          # :stopped, :starting, :timed_out, :running, :stopping, :crashed
    started_at::Float64     # time() when last started
    connect_by::Float64     # time() by which its gate must connect; see session_startup_timeout
    session_key::String     # gate session key once connected (8-char)
    error_log::Vector{String}
    log_file::String        # path to stderr/stdout log
    owner::String           # MCP caller that owns it privately; "" = shared
end

function ManagedSession(project_path::String; name::String = "", owner::String = "")
    if isempty(name)
        name = isempty(owner) ? basename(project_path) : "$(basename(project_path)) (private)"
    end
    log_dir = joinpath(kaimon_cache_dir(), "sessions")
    mkpath(log_dir)
    stem = isempty(owner) ? basename(project_path) : "$(basename(project_path))-$(first(owner, 8))"
    log_file = joinpath(log_dir, "$stem.log")
    ManagedSession(project_path, name, nothing, nothing, :stopped, 0.0, 0.0, "", String[], log_file, owner)
end

"""Return the PID of a managed session (from PTY or Process)."""
session_pid(ms::ManagedSession) =
    ms.pty !== nothing ? Int(ms.pty.child_pid) : (ms.process !== nothing ? getpid(ms.process) : 0)

const _SESSION_STARTUP_TIMEOUT_DEFAULT = 120.0

"""
    session_startup_timeout() -> Float64

Seconds a spawned session has to connect its gate: `KAIMON_SESSION_STARTUP_TIMEOUT` > config.json
`"session_startup_timeout"` > default $(_SESSION_STARTUP_TIMEOUT_DEFAULT). A session that has not
connected by then is reported as timed out, and its process gets the same time again to connect
before it is stopped. Read on use, so a config edit applies to the next spawn.
"""
function session_startup_timeout()::Float64
    env = tryparse(Float64, strip(get(ENV, "KAIMON_SESSION_STARTUP_TIMEOUT", "")))
    (env !== nothing && env > 0) && return env
    t = _SESSION_STARTUP_TIMEOUT_DEFAULT
    try
        p = get_global_config_path()
        if isfile(p)
            data = JSON.parse(read(p, String); dicttype = Dict{String,Any})
            v = get(data, "session_startup_timeout", nothing)
            (v isa Real && v > 0) && (t = Float64(v))
        end
    catch
    end
    return t
end

# ── Global state ─────────────────────────────────────────────────────────────

const MANAGED_SESSIONS = ManagedSession[]
const MANAGED_SESSIONS_LOCK = ReentrantLock()

function _push_session_error!(ms::ManagedSession, msg::String)
    push!(ms.error_log, msg)
    length(ms.error_log) > 20 && deleteat!(ms.error_log, 1:length(ms.error_log) - 20)
end

# ── Spawn / Stop ─────────────────────────────────────────────────────────────

"""
    _build_session_script(project_path; name="", allow_restart=true, instantiate="auto") -> String

Generate the Julia `-e` script that boots a session subprocess. `instantiate` is the launch
config mode (see `LaunchConfig`); its output goes to the session log, and a failure is
reported there without stopping the session from connecting.
"""
function _build_session_script(project_path::String;
                               name::String = "",
                               allow_restart::Bool = true,
                               instantiate::String = "auto")
    # The subprocess is launched with --project=<target>, so the target project
    # and its deps are the active environment. It boots only the lightweight
    # `KaimonGate` (ZMQ + stdlib) — NOT the heavyweight Kaimon — so a session
    # never has to recompile Kaimon against the target's manifest (issue #47).
    # KaimonGate is made resolvable, and the host's identity (mirror preference,
    # personality, version) conveyed, via `_build_session_env`. The TUI enriches
    # the gate over the wire, so loading Kaimon here buys nothing.
    return """
    cd($(repr(project_path)))
    try; using Revise; catch; end
    using KaimonGate
    $(_instantiate_line(instantiate))
    @async KaimonGate.serve(force=true, allow_mirror=true, allow_restart=$(allow_restart), spawned_by="agent")
    """
end

# The script line for a launch config `instantiate` mode. "auto" turns off Pkg's automatic
# precompilation for the call: every stale package in the manifest would otherwise be
# compiled at each spawn, including dev'd packages the session never loads.
function _instantiate_line(mode::AbstractString)
    mode == "never" && return ""
    call = mode == "always" ? "Pkg.instantiate()" : "Pkg.instantiate(; allow_autoprecomp = false)"
    return "import Pkg; try; $call; catch e; @error \"Pkg.instantiate failed\" exception = e; end"
end

"""
    _build_session_env() -> Dict{String,String}

Build the environment-variable overlay for a spawned session subprocess.

`JULIA_LOAD_PATH` is the shell-default stack (`@:@v#.#:@stdlib`) so that
`--project=<target>` controls the active environment as usual, with KaimonGate's
own env (`pkgdir(KaimonGate)`, which carries a `Manifest.toml` pinning ZMQ)
appended so the lightweight gate is resolvable — and recompilable from source —
without requiring a global install, regardless of the target's manifest (#47).
`JULIA_PROJECT` is cleared so `--project` is the sole authority on the active env.

The `KAIMON_GATE_*` vars convey the host's identity to the standalone gate (which
doesn't load Kaimon): the user's REPL-mirror preference (so a joined session
console shows agent eval activity by default), personality emoji, and the Kaimon
version reported in the session's pong. KaimonGate's default providers read these.
"""
function _build_session_env()
    gate_env = pkgdir(KaimonGate)
    # OS-correct separator (`;` on Windows) — a hardcoded `:` breaks Windows drive
    # letters and drops @stdlib, so the spawned session can't find its stdlibs/gate.
    load_path = gate_env === nothing ?
        _join_load_path("@", "@v#.#", "@stdlib") :
        _join_load_path("@", "@v#.#", "@stdlib", gate_env)

    mirror = try
        get_gate_mirror_repl_preference()
    catch
        true
    end
    personality = try
        load_personality()
    catch
        ""
    end
    version = try
        string(PACKAGE_VERSION)
    catch
        ""
    end

    env = Dict{String,String}(
        "JULIA_LOAD_PATH" => load_path,
        "JULIA_PROJECT" => "",
        "KAIMON_GATE_MIRROR_REPL" => mirror ? "1" : "0",
    )
    isempty(personality) || (env["KAIMON_GATE_PERSONALITY"] = personality)
    isempty(version) || (env["KAIMON_GATE_VERSION"] = version)
    return env
end

"""
    _resolve_launch_config(project_path::String) -> LaunchConfig

Resolve the effective LaunchConfig for a project. The user's `projects.json` entry is
overlaid field-wise on the project's own checked-in `kaimon.toml [launch]` defaults, so a
repo can ship its launch recipe (typically a custom sysimage) while the local user still
overrides any single field. Returns the default LaunchConfig when neither source exists.
"""
function _resolve_launch_config(project_path::String)
    base = something(load_toml_launch_config(project_path), LaunchConfig())
    norm_path = normalize_path(project_path)
    for entry in load_projects_config()
        if normalize_path(entry.project_path) == norm_path
            return merge_launch_config(base, entry.launch_config)
        end
    end
    return base
end

"""
    _resolve_sysimage(lc::LaunchConfig, project::String) -> String

Resolve the configured sysimage to an absolute path, or `""` if unset/unusable. A relative
path is taken against the project root, so a repo's `kaimon.toml` can name the image its own
build script produces. A configured-but-missing image degrades to the default sysimage with a
warning rather than failing the spawn — a stale path shouldn't cost the user their session.
"""
function _resolve_sysimage(lc::LaunchConfig, project::String)
    isempty(lc.sysimage) && return ""
    path = expanduser(lc.sysimage)
    isabspath(path) || (path = joinpath(project, path))
    if !isfile(path)
        _push_log!(:warn, "Sysimage not found, using the default: $path")
        return ""
    end
    return abspath(path)
end

"""
    _launch_julia_exe(lc::LaunchConfig) -> String

The Julia binary a project should be launched with, in precedence order:

1. `julia_bin`, the explicit escape hatch. May be a wrapper script, so long as it forwards its
   arguments to julia. Outranks `julia_version`, including a `julia_version` juliaup could
   satisfy, because a path the user wrote down is not something to second-guess.
2. `julia_version`, resolved against the Julia running Kaimon and then juliaup's installs.
3. The Julia running Kaimon.

A requested version that isn't installed logs which Julia is being substituted rather than
failing the spawn: losing a session over a version preference costs the user more than running
on the wrong patch, and the warning names the mismatch so it is never silent. Offering to
install it is a separate, consenting step (`_maybe_offer_julia_install`).

Every spawn for a project — a session and a test run alike — resolves the binary here, so they
cannot disagree about which Julia. That matters beyond tidiness: a project's environment records
the Julia version it was resolved for, and a dependency whose `[compat]` admits a different
version per Julia resolves differently under each. Two spawns on two Julias therefore fight over
one manifest, and the loser is left with a dependency version its Julia cannot precompile.
"""
function _launch_julia_exe(lc::LaunchConfig)
    isempty(lc.julia_bin) || return expanduser(lc.julia_bin)
    isempty(lc.julia_version) && return joinpath(Sys.BINDIR, "julia")
    bin = resolve_julia_binary(lc.julia_version)
    bin === nothing || return bin
    _push_log!(
        :warn,
        "Julia $(lc.julia_version) is requested but not installed; using $(VERSION) instead. " *
        "Install it with `juliaup add $(lc.julia_version)` if dependency resolution, " *
        "precompilation or tests misbehave.",
    )
    return joinpath(Sys.BINDIR, "julia")
end

"""
    _build_julia_cmd(lc::LaunchConfig, script::String; project::String="") -> Vector{String}

Build the Julia command array from a LaunchConfig and boot script.
"""
function _build_julia_cmd(lc::LaunchConfig, script::String; project::String = "")
    cmd = [_launch_julia_exe(lc), "-i"]

    # Custom system image (before the boot script, so `using` in it hits the baked code)
    sysimage = _resolve_sysimage(lc, project)
    !isempty(sysimage) && push!(cmd, "--sysimage=$sysimage")

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

    # startup.jl is suppressed by default so a spawned session boots predictably; opt in
    # when the project's launch recipe depends on it.
    push!(cmd, lc.startup_file ? "--startup-file=yes" : "--startup-file=no")
    append!(cmd, ["-e", script])

    return cmd
end

# Wait for the session's process to exit, then record it, finish its log, and release its terminal.
"""
Why a session's PTY stopped: its process exited, or the reader of its terminal stopped while the
process was still running. Nothing reads the process's output after that, so it is closed too.
"""
function _pty_end_reason(pty)
    err = pty.reader_error
    err === nothing && return "process exited"
    return "terminal reader stopped while the process was running: $(sprint(showerror, err))"
end

"""
Open a session log for appending. Sessions of one project share a log, and the file is opened
with the OS append flag so each write lands at the end of the file even while another session
writes to it. Writes are unbuffered, so each marker is written whole with a single `write`.
"""
_open_session_log(path::AbstractString) = Base.Filesystem.open(
    path,
    Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_APPEND,
    0o644,
)

function _watch_session_exit!(ms::ManagedSession, pty, log_io; poll::Real = 2.0)
    while Tachikoma.pty_alive(pty)
        sleep(poll)
    end
    if ms.status in (:starting, :timed_out, :running)
        ms.status = :crashed
        reason = _pty_end_reason(pty)
        _push_session_error!(ms, "$(uppercasefirst(reason)) at $(Dates.now())")
        _push_log!(:warn, "Managed session '$(ms.name)' stopped unexpectedly: $reason")
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
            write(log_io, "--- Session $(ms.name) exited at $(Dates.now()) ---\n")
        catch
        end
        try
            close(log_io)
        catch
        end
    end
    # Release its terminal and reap it. Nothing to do if stop_session! already took the PTY.
    _close_pty!(_take_pty!(ms, pty))
end

"""
    spawn_session!(ms::ManagedSession)

Launch the session subprocess. Non-blocking.
"""
function spawn_session!(ms::ManagedSession)
    ms.status == :running && return
    ms.status = :starting
    ms.started_at = time()
    ms.connect_by = ms.started_at + session_startup_timeout()
    empty!(ms.error_log)

    # Resolve per-session allow_restart preference
    ar = let
        sp = load_session_prefs()
        v = resolve_session_pref(sp, ms.project_path, :allow_restart)
        v !== nothing ? v : true  # default: restart allowed
    end
    try
        lc = _resolve_launch_config(ms.project_path)
        script = _build_session_script(ms.project_path; name = ms.name, allow_restart = ar,
                                       instantiate = isempty(lc.instantiate) ? "auto" : lc.instantiate)
        cmd = _build_julia_cmd(lc, script; project = ms.project_path)
        # Build the env overlay: --project=<target> controls the active
        # environment, KaimonGate's own env is appended to JULIA_LOAD_PATH so the
        # lightweight gate stays resolvable for a from-source recompile (#47), and
        # KAIMON_GATE_* carry the host's identity to the standalone gate.
        # (pty_spawn merges env into the parent ENV, so we set explicit values.)
        env = _build_session_env()
        # the launch config's own variables, where Kaimon's environment does not already set them
        for (k, v) in lc.env
            haskey(ENV, k) || haskey(env, k) || (env[k] = v)
        end
        pty = Tachikoma.pty_spawn(cmd; rows = 24, cols = 80, env)
        ms.pty = pty
        ms.process = nothing
        ms.status = :starting

        # Open log file and tee PTY output to disk so crashed sessions leave
        # a forensic trail. The TerminalWidget overrides `on_data` if/when the
        # user opens the session viewer, at which point logging stops and the
        # widget takes over consumption of the channel.
        log_io = try
            io = _open_session_log(ms.log_file)
            write(io, "\n--- Session $(ms.name) starting at $(Dates.now()) (PID=$(Int(pty.child_pid))) ---\n")
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

        @async _watch_session_exit!(ms, pty, log_io)

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

# Detach the session's PTY so that exactly one caller closes it. The exit monitor and stop_session!
# can run on different threads, and a second close(2) could hit an fd number the OS has reused.
# With `expected`, the PTY is taken only if it is still that one.
function _take_pty!(ms::ManagedSession, expected = nothing)
    lock(MANAGED_SESSIONS_LOCK) do
        pty = ms.pty
        (pty === nothing || (expected !== nothing && pty !== expected)) && return nothing
        ms.pty = nothing
        return pty
    end
end

_close_pty!(::Nothing) = nothing
function _close_pty!(pty)
    try
        Tachikoma.pty_close!(pty)
    catch e
        _push_log!(:warn, "Closing a session terminal failed: $(sprint(showerror, e))")
    end
    return nothing
end

"""
    stop_session!(ms::ManagedSession; timeout::Float64=5.0)

Stop a session subprocess gracefully, then force-kill after timeout.
"""
function stop_session!(ms::ManagedSession; timeout::Float64 = 5.0)
    ms.status == :stopped && return
    prev_status = ms.status
    ms.status = :stopped

    # PTY-based session: closing the PTY hangs up the child, reaps it, and kills one that outlives the
    # grace period.
    _close_pty!(_take_pty!(ms))

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

_realpath_or_self(p::AbstractString) = try
    realpath(p)
catch
    String(p)
end

"""
    _match_gate(ms, sessions, conns) -> Union{REPLConnection,Nothing}

The connected gate of managed session `ms`, which is waiting for one. The process id decides,
since several sessions can share a project. It matches whatever the gate says started it: a startup
file the launch config runs may serve the gate before the session's own script does. The project
path is the fallback, for a `julia_bin` wrapper that runs Julia as a child with another pid, and
takes only an agent-spawned gate whose pid is no other managed session's. A gate another managed
session has claimed is never matched again.
"""
function _match_gate(ms::ManagedSession, sessions, conns)
    claimed = Set(s.session_key for s in sessions if s !== ms && !isempty(s.session_key))
    free = [c for c in conns if !(short_key(c) in claimed)]
    pid = session_pid(ms)
    if pid > 0
        i = findfirst(c -> c.pid == pid, free)
        i === nothing || return free[i]
    end
    other_pids = Set(p for p in (session_pid(s) for s in sessions if s !== ms) if p > 0)
    norm_path = _realpath_or_self(ms.project_path)
    i = findfirst(free) do c
        is_agent_spawned(c) && !(c.pid in other_pids) &&
            _realpath_or_self(c.project_path) == norm_path
    end
    return i === nothing ? nothing : free[i]
end

"""
    _unmatched_gate_reason(conn, sessions) -> String

Why agent-spawned gate `conn` matches none of the managed `sessions`, for the log.
"""
function _unmatched_gate_reason(conn::REPLConnection, sessions)
    if conn.pid > 0
        i = findfirst(s -> session_pid(s) == conn.pid, sessions)
        i === nothing || return "its process is session '$(sessions[i].name)''s, which is $(sessions[i].status)"
    end
    waiting = [s for s in sessions if s.status in (:starting, :timed_out)]
    isempty(waiting) && return "no session is waiting for a gate"
    gate_path = _realpath_or_self(conn.project_path)
    reasons = map(waiting) do s
        same_path = _realpath_or_self(s.project_path) == gate_path
        "'$(s.name)' has pid $(session_pid(s))" * (same_path ? "" : " and project $(s.project_path)")
    end
    return "pid differs from every waiting session (" * join(reasons, "; ") * ")"
end

# Keys of unclaimed agent-spawned gates already logged, so each is reported once.
const _UNMATCHED_GATES_LOGGED = Set{String}()
const _UNMATCHED_GATES_LOCK = ReentrantLock()

function _log_unmatched_gates!(sessions, conns)
    claimed = Set(s.session_key for s in sessions if !isempty(s.session_key))
    lock(_UNMATCHED_GATES_LOCK) do
        live = Set(short_key(c) for c in conns)
        intersect!(_UNMATCHED_GATES_LOGGED, live)
        for c in conns
            key = short_key(c)
            (is_agent_spawned(c) && !(key in claimed) && !(key in _UNMATCHED_GATES_LOGGED)) || continue
            push!(_UNMATCHED_GATES_LOGGED, key)
            _push_log!(
                :warn,
                "Agent-spawned gate $key (pid $(c.pid), project $(c.project_path)) matches no " *
                "managed session: $(_unmatched_gate_reason(c, sessions))",
            )
        end
    end
end

"""
    _monitor_managed_sessions!(conn_mgr)

Called periodically from the TUI view tick and while `start_session` waits. Checks session health:
- Matches each session waiting for its gate to the gate that connected for its process
- Marks a session `:timed_out` once its startup limit passes; its process keeps running and is
  still matched if its gate connects, until the same time again has passed, when it is stopped
- Detects crashed processes
- Logs an agent-spawned gate that matches no session, with the reason
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
        if ms.status in (:starting, :timed_out, :running)
            # Check if process is still alive (PTY or legacy pipeline)
            pty = ms.pty
            alive = if pty !== nothing
                Tachikoma.pty_alive(pty)
            elseif ms.process !== nothing
                Base.process_running(ms.process)
            else
                false
            end
            if !alive
                ms.status = :crashed
                reason = pty !== nothing ? _pty_end_reason(pty) : "process exited"
                _push_session_error!(ms, "$(uppercasefirst(reason)) at $(Dates.now())")
            end
        end

        # Reflect the user-provided session name (from `start_session(name=…)`)
        # in the linked connection's display name, so the Sessions table shows
        # "iocap-repro" rather than the name derived from the project directory.
        # Runs every tick so it also converges an already-connected session, and
        # _derive_display_name won't clobber it (it only fills an empty name).
        if !isempty(ms.name) && !isempty(ms.session_key)
            for conn in conns
                if short_key(conn) == ms.session_key && conn.display_name != ms.name
                    conn.display_name = ms.name
                end
            end
        end

        ms.status in (:starting, :timed_out) || continue
        conn = _match_gate(ms, sessions, conns)
        if conn !== nothing
            late = ms.status == :timed_out
            ms.status = :running
            ms.session_key = short_key(conn)
            _push_log!(
                :info,
                "Session '$(ms.name)' connected (session=$(ms.session_key))" *
                (late ? " $(round(Int, time() - ms.started_at))s after it started, past its startup limit" : ""),
            )
            continue
        end
        grace = session_startup_timeout()
        if ms.status == :starting && time() > ms.connect_by
            ms.status = :timed_out
            waited = round(Int, time() - ms.started_at)
            _push_session_error!(ms, "Startup timeout at $(Dates.now()): no gate connected within $(waited)s")
            _push_log!(
                :warn,
                "Session '$(ms.name)' startup timed out after $(waited)s; its process " *
                "(PID=$(session_pid(ms))) is used if its gate connects within another $(round(Int, grace))s",
            )
        elseif ms.status == :timed_out && time() > ms.connect_by + grace
            _push_log!(:warn, "Session '$(ms.name)' never connected; stopping its process")
            stop_session!(ms)
        end
    end

    _log_unmatched_gates!(sessions, conns)
    return nothing
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
    find_managed_session(project_path::String; owner=nothing) -> Union{ManagedSession,Nothing}

Find a managed session by project path (normalized). With `owner`, only a session with
exactly that owner (`""` = shared) matches.
"""
function find_managed_session(project_path::String; owner::Union{String,Nothing} = nothing)
    norm_path = try
        realpath(project_path)
    catch
        project_path
    end
    sessions = lock(MANAGED_SESSIONS_LOCK) do
        copy(MANAGED_SESSIONS)
    end
    for ms in sessions
        owner === nothing || ms.owner == owner || continue
        ms_norm = try
            realpath(ms.project_path)
        catch
            ms.project_path
        end
        ms_norm == norm_path && return ms
    end
    return nothing
end

"""Find the managed session connected as gate session `key`, or `nothing`."""
function find_managed_by_key(key::AbstractString)
    isempty(key) && return nothing
    lock(MANAGED_SESSIONS_LOCK) do
        for ms in MANAGED_SESSIONS
            ms.session_key == key && return ms
        end
        return nothing
    end
end

"""The MCP caller that owns gate session `key` privately, or `""` if it is shared (or not
an agent-spawned session at all)."""
function session_owner(key::AbstractString)
    ms = find_managed_by_key(key)
    return ms === nothing ? "" : ms.owner
end

"""True when gate session `key` is private to an agent other than `caller`."""
private_to_other(key::AbstractString, caller::AbstractString) =
    (o = session_owner(key); !isempty(o) && o != caller)

"""
    managed_session_for(conn) -> Union{ManagedSession,Nothing}

The managed session behind gate connection `conn`: found by session key, or, for an agent-spawned
session not yet linked to its key, by process id.
"""
function managed_session_for(conn::REPLConnection)
    ms = find_managed_by_key(short_key(conn))
    ms !== nothing && return ms
    (is_agent_spawned(conn) && conn.pid > 0) || return nothing
    lock(MANAGED_SESSIONS_LOCK) do
        for m in MANAGED_SESSIONS
            session_pid(m) == conn.pid && return m
        end
        return nothing
    end
end

"""
    shutdown_session!(mgr, conn; exit_wait=5.0) -> Symbol

Shut down gate session `conn`. Asks its gate to exit and removes the connection and its files. If
Kaimon spawned the process, it is then stopped: given `exit_wait` seconds to exit on its own after an
acknowledged shutdown, then its terminal is closed, which hangs it up, reaps it, and kills it if it
outlives the grace period. Its managed record is dropped. Returns `:acknowledged`, `:stalled` (it was
stalled and did not answer) or `:unacknowledged`.
"""
function shutdown_session!(mgr::ConnectionManager, conn::REPLConnection; exit_wait::Real = 5.0)
    was_stalled = conn.status == :stalled
    ms = managed_session_for(conn)
    # Before the gate is asked to exit, so its exit is not taken for a crash.
    ms === nothing || (ms.status = :stopping)
    ok = send_shutdown!(conn)
    disconnect!(conn)
    _unregister_session_tools!(conn)
    lock(mgr.lock) do
        idx = findfirst(c -> c === conn, mgr.connections)
        idx !== nothing && deleteat!(mgr.connections, idx)
    end
    _remove_session_files(mgr.sock_dir, conn.session_id)
    _fire_sessions_changed(mgr)
    if ms !== nothing
        if ok
            deadline = time() + exit_wait
            while (pty = ms.pty) !== nothing && Tachikoma.pty_alive(pty) && time() < deadline
                sleep(0.1)
            end
        end
        stop_session!(ms)
        lock(MANAGED_SESSIONS_LOCK) do
            filter!(m -> m !== ms, MANAGED_SESSIONS)
        end
    end
    return ok ? :acknowledged : was_stalled ? :stalled : :unacknowledged
end

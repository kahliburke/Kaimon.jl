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

# Per-extension log size cap. We append to one `<namespace>.log` across every restart, so a
# chatty extension started dozens of times accumulates unbounded (slate.log reached >1 GB).
# On start, if the log is over this, we rotate it to a single `.1` backup and begin fresh.
const _EXT_LOG_CAP_BYTES = 10 * 1024^2   # 10 MB

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
namespace — orphans from a previous Kaimon instance whose Process handle was lost.
Positively identifies our own processes so it won't kill user processes: Linux by the
`KAIMON_EXTENSION` env var (`/proc/<pid>/environ`), macOS and Windows by the boot-script
markers in the command line (`spawned_by="extension"` + `namespace=…`), since neither
exposes another process's environment. No-op on platforms without a supported probe.
"""
# Positively identify one of OUR extension boot processes from its command line, by the
# markers baked into the `-e` script (see `_build_extension_script`): `spawned_by=`
# "extension" and the `namespace=` assignment. Windows escapes embedded quotes when it
# builds the command line (`namespace="x"` → `namespace=\"x\"`), so we match that escaped
# form — the closing escaped-quote also pins the namespace exactly (so `"sla"` can't match
# a `"slate"` gate). All markers must be present; a plain `julia` process won't match.
function _extension_cmdline_matches(cmdline::AbstractString, namespace::AbstractString)
    isempty(cmdline) && return false
    ns_marker = "namespace=\\\"$(namespace)\\\""
    return occursin("spawned_by=", cmdline) &&
           occursin("extension", cmdline) &&
           occursin(ns_marker, cmdline)
end

# Windows has no `/proc`, no readable per-process environment, and no `pgrep`/`kill`. Use
# PowerShell/CIM to enumerate `julia.exe` processes and their command lines, then match ours
# in Julia (testable) via `_extension_cmdline_matches`. Records are NUL-delimited (PID and
# command line split by US, 0x1F) because the boot script is multi-line — a newline-delimited
# format would split one process's record across lines.
function _kill_orphan_extension_processes_windows!(namespace::String)
    my_pid = getpid()
    ps = """
    \$us = [char]0x1F; \$nul = [char]0
    Get-CimInstance Win32_Process -Filter "Name = 'julia.exe'" | ForEach-Object {
        [Console]::Out.Write("\$(\$_.ProcessId)\$us\$(\$_.CommandLine)\$nul")
    }
    """
    out = try
        read(pipeline(`powershell -NoProfile -NonInteractive -Command $ps`; stderr = devnull), String)
    catch
        return   # PowerShell/CIM unavailable — best-effort, leave orphans rather than throw
    end
    for record in split(out, '\0'; keepempty = false)
        us = findfirst('\x1f', record)
        us === nothing && continue
        pid = tryparse(Int, strip(record[1:prevind(record, us)]))
        (pid === nothing || pid == my_pid) && continue
        cmdline = record[nextind(record, us):end]
        _extension_cmdline_matches(cmdline, namespace) || continue
        _push_log!(:info, "Killing orphan extension '$namespace' (PID=$pid)")
        Utils.terminate_process(pid; force = true)
    end
    return
end

function _kill_orphan_extension_processes!(project_path::String, namespace::String)
    if Sys.iswindows()
        try
            _kill_orphan_extension_processes_windows!(namespace)
        catch e
            @debug "Windows orphan-extension reap failed" exception = e
        end
        return
    end
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

const _EXT_LOG_TIME_FORMAT = Dates.DateFormat("HH:MM:SS")

"""
    _format_extension_log(io, args)

`FormatLogger` sink for extension subprocess logs: one `[HH:MM:SS Level] message`
line, then each structured kwarg (`@warn "…" key=val`) on its own indented line.
An `exception=` kwarg — an exception or an `(exc, backtrace)` tuple — is rendered
with `showerror` so extension failures keep their error message and stack trace.
"""
function _format_extension_log(io, args)
    println(io, "[", Dates.format(Dates.now(), _EXT_LOG_TIME_FORMAT), " ", args.level, "] ",
        args.message)
    for (k, v) in args.kwargs
        str = try
            _render_extension_log_value(k, v)
        catch e
            "<error rendering value: $(sprint(showerror, e))>"
        end
        println(io, "  ", k, " = ", replace(str, "\n" => "\n  "))
    end
end

function _render_extension_log_value(k::Symbol, v)
    if k === :exception
        v isa Exception && return sprint(showerror, v)
        if v isa Tuple && length(v) == 2 && v[1] isa Exception
            return sprint(showerror, v[1], v[2])
        end
    end
    str = sprint(show, v; context = :limit => true)
    # Cap huge values so one kwarg can't bloat the log file.
    sizeof(str) <= 4096 ? str : first(str, 4096) * " ⋯"
end

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
    let sock_dir = Kaimon.KaimonGate.sock_dir()
        sub = Kaimon.ZMQ.Socket(Kaimon.KaimonGate._GATE_CONTEXT[], Kaimon.ZMQ.SUB)
        sub.rcvtimeo = 1000  # 1s timeout so loop can check for shutdown
        if Sys.iswindows()
            Kaimon.ZMQ.connect(sub, "tcp://127.0.0.1:\$(Kaimon._EVENT_PUB_TCP_PORT[])")
        else
            Kaimon.ZMQ.connect(sub, "ipc://\$(sock_dir)/kaimon-events.sock")
        end
        $topics_code
        @async begin
            while true
                try
                    topic = Kaimon.ZMQ.recv(sub, String)       # frame 1: channel name
                    payload = Kaimon.ZMQ.recv(sub, Vector{UInt8})  # frame 2: serialized data
                    msg = Kaimon._safe_deserialize(payload; label = "ext_event")
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
    # (formatter lives in Kaimon so it's testable and keeps structured kwargs).
    using LoggingExtras, Logging
    global_logger(MinLevelLogger(
        FormatLogger(Kaimon._format_extension_log, stderr; always_flush=true),
        Logging.Info,
    ))
    using $(m.module_name)
    tools = $(m.module_name).$(m.tools_function)(Kaimon.KaimonGate.GateTool)
    Kaimon.KaimonGate.serve(tools=tools, namespace=$(repr(m.namespace)), force=true, allow_mirror=false, allow_restart=false, spawned_by="extension"$on_shutdown_kwarg)
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
        # LOAD_PATH: extension project (@), Kaimon project (for Gate, LoggingExtras, etc.),
        # global env (@v#.#), stdlib.  Adding Kaimon's project path ensures extensions can
        # always find Kaimon and its deps without requiring them in their own Project.toml.
        kaimon_project = pkgdir(@__MODULE__)
        # OS-correct separator (`;` on Windows) — a hardcoded `:` breaks Windows drive
        # letters and drops @stdlib, so the extension can't even find Pkg/Kaimon.
        env["JULIA_LOAD_PATH"] = _join_load_path("@", kaimon_project, "@v#.#", "@stdlib")
        delete!(env, "JULIA_PROJECT")
        # Mark this process as Kaimon-spawned so we can identify orphans
        env["KAIMON_EXTENSION"] = ext.config.manifest.namespace
        env["KAIMON_PARENT_PID"] = string(getpid())
        flags = ext.config.manifest.julia_flags
        if isempty(flags)
            flags = ["-t", "auto"]
        end
        cmd = setenv(`$julia_bin $flags --startup-file=no --project=$project -e $script`, env)

        # Redirect output to log file. Rotate first if it's grown past the cap (across
        # restarts) so it can't accumulate without bound — keep one `.1` backup.
        try
            if isfile(ext.log_file) && filesize(ext.log_file) > _EXT_LOG_CAP_BYTES
                mv(ext.log_file, ext.log_file * ".1"; force = true)
            end
        catch
        end
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
    # Disconnect the old gate connection immediately so the monitor won't
    # falsely match it on restart (which would show :running too early).
    if !isempty(ext.session_key)
        mgr = GATE_CONN_MGR[]
        if mgr !== nothing
            lock(mgr.lock) do
                idx = findfirst(c -> short_key(c) == ext.session_key, mgr.connections)
                if idx !== nothing
                    _unregister_session_tools!(mgr.connections[idx])
                    disconnect!(mgr.connections[idx])
                    _remove_session_files(mgr.sock_dir, mgr.connections[idx].session_id)
                    deleteat!(mgr.connections, idx)
                end
            end
        end
    end
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

"""
    set_extension_config!(ext; enabled=nothing, auto_start=nothing) -> (enabled, auto_start)

Update an extension's `enabled` / `auto_start` flags, persist them to
extensions.json, and apply the start/stop side effects (disabling a running
extension stops it; enabling an auto-start extension that's stopped starts it).
Pass only the field you want to change. Shared by the TUI Extensions tab and the
`manage_extension` MCP tool.
"""
function set_extension_config!(ext::ManagedExtension; enabled = nothing, auto_start = nothing)
    old = ext.config.entry
    new_enabled = enabled === nothing ? old.enabled : enabled
    new_auto = auto_start === nothing ? old.auto_start : auto_start
    new_entry = ExtensionEntry(old.project_path, new_enabled, new_auto)
    ext.config = ExtensionConfig(new_entry, ext.config.manifest)

    # Persist to extensions.json (match by normalized project path).
    entries = load_extensions_config()
    target = normalize_path(old.project_path)
    for (i, e) in enumerate(entries)
        if normalize_path(e.project_path) == target
            entries[i] = new_entry
            break
        end
    end
    save_extensions_config(entries)

    # Side effects only when `enabled` actually changed.
    if enabled !== nothing
        if !new_enabled && ext.status in (:running, :starting)
            stop_extension!(ext)
        elseif new_enabled && new_auto && ext.status == :stopped
            spawn_extension!(ext)
        end
    end
    (enabled = new_enabled, auto_start = new_auto)
end

# ── Monitor ──────────────────────────────────────────────────────────────────

const _EXTENSION_RESTART_BACKOFF = [5.0, 10.0, 30.0, 60.0]  # seconds

# How long an extension may sit in :starting (process alive, gate not yet connected) before
# the monitor gives up and marks it crashed. A DEAD process is detected immediately and
# separately — this budget is purely for "alive but not serving yet," which on a cold machine
# is dominated by first-run precompilation of the extension's dep tree (Kaimon + e.g.
# KaimonSlate's web stack). That can take minutes, worst on Windows (slow FS + precompile);
# too short a budget kills the process mid-precompile and force-restarts it, so the cache
# never completes and it loops until "max restarts, giving up" — the extension never connects.
# Generous default; override with KAIMON_EXTENSION_STARTUP_TIMEOUT (seconds).
function _extension_startup_timeout()
    v = tryparse(Float64, get(ENV, "KAIMON_EXTENSION_STARTUP_TIMEOUT", ""))
    (v === nothing || v <= 0) ? 300.0 : v
end

# Diagnostic for a startup timeout: did ANY extension gate write discovery metadata into the
# sock dir the server scans? Metadata present ⇒ the gate served but the server couldn't
# discover/connect it (a discovery/connect bug); absent ⇒ serve() never ran or wrote nothing
# (the extension boot never reached the gate). Splits the two failure modes in the log.
function _extension_gate_advertised(sock_dir::AbstractString)
    isdir(sock_dir) || return false
    for f in readdir(sock_dir)
        endswith(f, ".json") || continue
        meta = try
            JSON.parsefile(joinpath(sock_dir, f))
        catch
            continue
        end
        get(meta, "spawned_by", "") == "extension" && return true
    end
    return false
end

# extensions.json watch state: the registry mtime we last reconciled against.
# `nothing` = not yet seeded (start_extensions! hasn't loaded a registry), so the
# watch stays dormant until extensions are actually managed — a bare `using Kaimon`
# or a headless run that never loads extensions won't spontaneously start any.
const _ext_registry_mtime = Ref{Union{Nothing,Float64}}(nothing)
const _EXT_REGISTRY_CHECK_SECS = 5.0      # how often the tick stats the registry
const _ext_registry_last_check = Ref(0.0)

_registry_mtime() = try
    p = get_extensions_config_path()
    isfile(p) ? mtime(p) : 0.0
catch
    0.0
end

# Throttled dispatch for the registry watch: at most once per _EXT_REGISTRY_CHECK_SECS
# (the tick itself may run every render frame), a cheap `stat`; only on an actual change
# do we reconcile off-thread (a removed extension's stop can block up to 5s and must not
# stall a render/housekeeping tick). Mirrors the `*_last_check` throttles elsewhere.
function _maybe_reconcile_registry!()
    _ext_registry_mtime[] === nothing && return
    now_t = time()
    now_t - _ext_registry_last_check[] < _EXT_REGISTRY_CHECK_SECS && return
    _ext_registry_last_check[] = now_t
    _registry_mtime() == _ext_registry_mtime[] && return
    Threads.@spawn try
        _rescan_registry_if_changed!()
    catch e
        _push_log!(:warn,
            "extension registry rescan failed: $(first(sprint(showerror, e), 200))")
    end
    return
end

# Reconcile iff extensions.json changed since we last looked (and the watch has been
# seeded). Returns true if a reconcile ran. Synchronous — the caller decides threading.
# This is the auto-pick-up of a manually-edited registry: it rides the existing
# `_monitor_extensions!` tick rather than a watcher of its own.
function _rescan_registry_if_changed!()
    baseline = _ext_registry_mtime[]
    baseline === nothing && return false
    mt = _registry_mtime()
    mt == baseline && return false
    _ext_registry_mtime[] = mt
    r = rescan_extensions!()
    (isempty(r.added) && isempty(r.removed)) ||
        _push_log!(:info,
            "extensions.json changed → rescan (added=$(r.added) removed=$(r.removed))")
    return true
end

"""
    _monitor_extensions!(conn_mgr)

The extension tick, driven both by the TUI view loop and the headless housekeeping
loop (`kaimon_lifecycle.jl`). Checks extension health:
- Matches gate sessions to extensions by namespace
- Detects crashed processes and restarts with backoff
- Updates status from :starting to :running when gate connects
- Reconciles a manually-edited extensions.json (auto-pick-up of added/removed)
"""
function _monitor_extensions!(conn_mgr)
    _maybe_reconcile_registry!()   # throttled auto-pick-up of extensions.json edits
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
                        break
                    end
                end

                # Timeout: give up only after a generous, precompile-aware budget (a dead
                # process is caught above; this is the "alive but not serving yet" case).
                timeout = _extension_startup_timeout()
                if ext.status == :starting && time() - ext.started_at > timeout
                    ext.status = :crashed
                    # Split the failure mode: did the extension's gate advertise at all?
                    advertised = try
                        _extension_gate_advertised(conn_mgr.sock_dir)
                    catch
                        false
                    end
                    diag = advertised ?
                        "gate metadata WAS found — the gate served but discovery/connect never completed" :
                        "no gate metadata found — serve() never ran or wrote nothing (extension boot didn't reach the gate)"
                    _push_error!(ext, "Startup timeout ($(round(Int, timeout))s) at $(Dates.now()); $diag")
                    _push_log!(:warn, "Extension '$ns' startup timed out after $(round(Int, timeout))s — $diag")
                end
            end

            if ext.status == :running
                ext.last_heartbeat = time()
                # Sync session key — after eviction the connection may have
                # a different session_id than what the monitor originally matched.
                for conn in connected_sessions(conn_mgr)
                    if conn.namespace == ns && short_key(conn) != ext.session_key
                        ext.session_key = short_key(conn)
                        break
                    end
                end
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
    # Seed the registry watch (see `_monitor_extensions!`) so it reconciles only edits
    # made AFTER this initial load, and only once extensions are actually managed.
    _ext_registry_mtime[] = _registry_mtime()
end

"""
    rescan_extensions!() -> (; added, removed, kept)

Reconcile `MANAGED_EXTENSIONS` against `extensions.json` on disk at runtime, so a
newly-added (or removed) extension is picked up WITHOUT restarting Kaimon — and
WITHOUT bouncing extensions that are unchanged. Newly-configured extensions are
added (and spawned when enabled + auto_start); extensions dropped from disk are
stopped and removed; existing ones keep running with their current state. Returns
the namespaces in each bucket. Runs in the main Kaimon process, where the
extension processes live (not a gate session).
"""
function rescan_extensions!()
    configs = load_extension_configs()
    disk_ns = Set(c.manifest.namespace for c in configs)

    # In memory but gone from disk → stop (outside the lock; stop_extension! blocks
    # up to 5s) then drop. This is the ordering fix: unlike a bare start_extensions!,
    # we terminate the process before removing it, so nothing is orphaned.
    to_remove = lock(MANAGED_EXTENSIONS_LOCK) do
        [e for e in MANAGED_EXTENSIONS if !(e.config.manifest.namespace in disk_ns)]
    end
    for e in to_remove
        try; stop_extension!(e); catch; end
    end

    added = String[]
    kept = String[]
    lock(MANAGED_EXTENSIONS_LOCK) do
        filter!(e -> e.config.manifest.namespace in disk_ns, MANAGED_EXTENSIONS)
        known = Set(e.config.manifest.namespace for e in MANAGED_EXTENSIONS)
        for config in configs
            ns = config.manifest.namespace
            if ns in known
                push!(kept, ns)
                continue
            end
            ext = ManagedExtension(config)
            push!(MANAGED_EXTENSIONS, ext)
            push!(added, ns)
            config.entry.enabled && config.entry.auto_start && spawn_extension!(ext)
        end
    end

    removed = String[e.config.manifest.namespace for e in to_remove]
    _push_log!(:info, "Extension rescan: added=$(added) removed=$(removed) kept=$(kept)")
    return (; added, removed, kept)
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

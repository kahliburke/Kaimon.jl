# ── Managed Qdrant ────────────────────────────────────────────────────────────
# Optionally run Qdrant as a Kaimon-managed child process instead of asking the
# user to stand up Docker themselves. Everything Kaimon needs from Qdrant is an
# HTTP API on a known port (see QdrantClient), so a self-contained binary works
# just as well as the container.
#
# The binary comes from `Qdrant_jll`, installed on demand into a small
# Kaimon-owned *service environment* (under the cache dir) — NOT the app/project
# environment. That choice matters:
#   • zero cost for Docker/remote users — nothing is downloaded unless asked;
#   • it never touches the app env or the Kaimon repo (no weakdep/extension to
#     break, no committed Project.toml to rewrite);
#   • it activates in-process via LOAD_PATH + `Base.require`, so enabling it needs
#     no restart and behaves identically whether Kaimon runs from a registered
#     app, a dev checkout, or a plain environment.
# Core owns the policy, the lifecycle, and the storage/log paths; the service env
# owns only the binary artifact.

const PREF_QDRANT_MANAGED = "qdrant_managed"

# Qdrant_jll — the JLL we install into the service env for the `qdrant` binary.
const _QDRANT_JLL = Base.PkgId(
    Base.UUID("49d5a0a8-0cca-57b3-8548-a2cd8c16dcd0"), "Qdrant_jll")
# Lower bound only — install the newest registered Qdrant_jll so we track upstream
# JLL updates automatically (the JLL itself lags mainline Qdrant; bumping it is a
# Yggdrasil build change, out of Kaimon's hands).
const _QDRANT_JLL_MIN = "1.17"

# The dynamically-loaded Qdrant_jll module — `nothing` until `load_qdrant_jll!`
# pulls it in from the service env.
const _QDRANT_JLL_MOD = Ref{Any}(nothing)

# The child process we started (if any), so we can health-check and reap it.
const _QDRANT_PROC = Ref{Any}(nothing)
const _QDRANT_LOCK = ReentrantLock()

# ── Policy ────────────────────────────────────────────────────────────────────

"""
    qdrant_managed_mode() -> Symbol

Policy for the managed-Qdrant launcher:

- `:auto` (default) — install/launch on demand only; if the binary isn't present
  and nothing answers on the port, tools fall back to the Docker guidance. Docker
  / remote users are unaffected: their Qdrant answers the ping, so we never spawn.
- `:always` — like `:auto` but warn loudly when the binary isn't installed rather
  than silently falling back.
- `:off` — never install or spawn; the user runs Qdrant themselves.

Resolved from `KAIMON_QDRANT_MANAGED` (auto|always|off), else the
`qdrant_managed` package preference, else `:auto`.
"""
function qdrant_managed_mode()::Symbol
    raw = get(ENV, "KAIMON_QDRANT_MANAGED", "")
    isempty(raw) && (raw = @load_preference(PREF_QDRANT_MANAGED, "auto"))
    v = lowercase(strip(String(raw)))
    v == "always" ? :always :
    v == "off"    ? :off    : :auto
end

"""
    set_qdrant_managed_mode!(mode) -> Symbol

Persist the managed-Qdrant policy (`:auto` / `:always` / `:off`) in
LocalPreferences.toml. The `KAIMON_QDRANT_MANAGED` env var still overrides it.
"""
function set_qdrant_managed_mode!(mode::Union{Symbol,AbstractString})::Symbol
    m = Symbol(lowercase(strip(String(mode))))
    m in (:auto, :always, :off) ||
        throw(ArgumentError("qdrant_managed must be :auto, :always, or :off (got $mode)"))
    @set_preferences!(PREF_QDRANT_MANAGED => String(m))
    return m
end

"""
    disable_managed_qdrant!() -> Symbol

Stop the managed Qdrant child (if we started one) and persist `:off` so it won't
auto-launch again. The binary stays installed and the on-disk index is kept — use
`uninstall_managed_qdrant!` to reclaim those. Returns `:off`.
"""
function disable_managed_qdrant!()::Symbol
    stop_managed_qdrant!()
    return set_qdrant_managed_mode!(:off)
end

"""
    enable_managed_qdrant!() -> Symbol

Persist `:auto` so managed Qdrant may launch on demand again. Returns `:auto`.
"""
enable_managed_qdrant!()::Symbol = set_qdrant_managed_mode!(:auto)

# ── Paths ─────────────────────────────────────────────────────────────────────

"""The Kaimon-owned environment that holds the Qdrant binary (`Qdrant_jll`)."""
qdrant_service_env() = mkpath(joinpath(kaimon_cache_dir(), "service-env"))

"""Directory holding the managed Qdrant's on-disk storage (collections, snapshots)."""
qdrant_storage_dir() = mkpath(joinpath(kaimon_cache_dir(), "qdrant", "storage"))

"""Path to the managed Qdrant's log file (stdout+stderr)."""
qdrant_log_path() = joinpath(mkpath(joinpath(kaimon_cache_dir(), "qdrant")), "qdrant.log")

"""The HTTP port the managed Qdrant should bind, parsed from the configured URL (default 6333)."""
function _qdrant_http_port()::Int
    m = match(r":(\d+)(?:/|$)", QdrantClient.QDRANT_URL[])
    m === nothing ? 6333 : parse(Int, m.captures[1])
end

# ── Installation / activation ─────────────────────────────────────────────────

"""
    qdrant_install_command() -> Cmd

A subprocess command that installs `Qdrant_jll` into the service env. Run
out-of-process so Pkg's precompile chatter and the (large) artifact download
don't disrupt the TUI; the running process is untouched until we `load` it.
"""
function qdrant_install_command()::Cmd
    env = qdrant_service_env()
    # No version pin → newest registered Qdrant_jll (currently 1.17.1; picks up
    # future bumps automatically). `_QDRANT_JLL_MIN` documents the floor we've tested.
    code = "import Pkg; Pkg.activate(raw\"$env\"); " *
           "Pkg.add(Pkg.PackageSpec(name=\"Qdrant_jll\"))"
    return `$(Base.julia_cmd()) --startup-file=no --color=no -e $code`
end

"""True if the Qdrant binary is installed in the service env (or already loaded)."""
function managed_qdrant_installed()::Bool
    _QDRANT_JLL_MOD[] !== nothing && return true
    manifest = joinpath(qdrant_service_env(), "Manifest.toml")
    isfile(manifest) || return false
    return occursin("Qdrant_jll", read(manifest, String))
end

"""True if the Qdrant binary is loaded into this process and ready to launch."""
managed_qdrant_ready()::Bool = _QDRANT_JLL_MOD[] !== nothing

"""
    load_qdrant_jll!() -> Bool

Load `Qdrant_jll` from the service env into this process (no restart). The service
env is added to `LOAD_PATH` so `Base.require` can resolve the JLL that lives there
rather than in the app env. Returns `true` on success.
"""
function load_qdrant_jll!()::Bool
    _QDRANT_JLL_MOD[] !== nothing && return true
    env = qdrant_service_env()
    isfile(joinpath(env, "Manifest.toml")) || return false
    env in LOAD_PATH || push!(LOAD_PATH, env)
    try
        _QDRANT_JLL_MOD[] = Base.require(_QDRANT_JLL)
        return true
    catch e
        @warn "Failed to load Qdrant_jll from the managed service env" env exception =
            (e, catch_backtrace())
        return false
    end
end

# ── Lifecycle ─────────────────────────────────────────────────────────────────

"""Launch the bundled Qdrant binary. Assumes `_QDRANT_JLL_MOD` is loaded."""
function _spawn_managed_qdrant(; storage_path::String, http_port::Int, log_path::String)
    mod = _QDRANT_JLL_MOD[]
    mod === nothing && error("Qdrant_jll is not loaded")
    env = copy(ENV)
    env["QDRANT__SERVICE__HTTP_PORT"] = string(http_port)
    env["QDRANT__SERVICE__GRPC_PORT"] = string(http_port + 1)  # Kaimon only uses HTTP
    env["QDRANT__STORAGE__STORAGE_PATH"] = storage_path
    env["QDRANT__STORAGE__SNAPSHOTS_PATH"] = joinpath(dirname(storage_path), "snapshots")
    env["QDRANT__TELEMETRY_DISABLED"] = "true"
    # `qdrant()` was defined by a just-loaded module — reach it past the current world.
    qdrant_cmd = Base.invokelatest(mod.qdrant)::Cmd
    logio = open(log_path, "a")
    # Run with the cache dir as the working directory. Qdrant writes a
    # `.qdrant-initialized` marker (and any other cwd-relative files) into its
    # working dir; without this it inherits the launching process's cwd — e.g. the
    # user's repo — and litters it.
    workdir = dirname(log_path)
    return run(pipeline(setenv(qdrant_cmd, env; dir = workdir);
                        stdout = logio, stderr = logio); wait = false)
end

"""True if the managed child we started (this session) is still alive."""
_qdrant_child_alive() =
    (_QDRANT_PROC[] isa Base.Process) && Base.process_running(_QDRANT_PROC[])

# In-memory handles (`_QDRANT_PROC`) don't survive a code reload or a process
# restart, so we ALSO record the child's PID in a file. That makes "is a
# Kaimon-managed Qdrant running, and is it ours to stop?" answerable across
# reloads/restarts — otherwise a managed instance from a prior session looks like
# an unowned Qdrant and its controls vanish.

_qdrant_pid_file() = joinpath(mkpath(joinpath(kaimon_cache_dir(), "qdrant")), "qdrant.pid")

function _write_qdrant_pid(pid::Integer)
    try; write(_qdrant_pid_file(), string(pid)); catch; end
end

function _read_qdrant_pid()::Union{Int,Nothing}
    f = _qdrant_pid_file()
    isfile(f) || return nothing
    return tryparse(Int, strip(read(f, String)))
end

"""Best-effort liveness check for a bare PID (no Process handle needed)."""
function _pid_alive(pid::Integer)::Bool
    try
        if Sys.iswindows()
            return occursin(string(pid), read(`tasklist /FI "PID eq $pid" /NH`, String))
        end
        return ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0  # sig 0 = existence probe
    catch
        return false
    end
end

"""Send a signal to a bare PID (SIGTERM, or SIGKILL when `force`)."""
function _kill_pid(pid::Integer; force::Bool = false)
    try
        if Sys.iswindows()
            run(pipeline(`taskkill $(force ? ["/F"] : String[]) /PID $pid`;
                         stdout = devnull, stderr = devnull))
        else
            ccall(:kill, Cint, (Cint, Cint), pid, force ? Base.SIGKILL : Base.SIGTERM)
        end
    catch
    end
end

"""
    managed_qdrant_running() -> Bool

True if a Kaimon-managed Qdrant is running — either a child we hold a handle to,
or one recorded in the PID file by any session (surviving reloads/restarts). A
stale PID file (process gone) is cleaned up and reports `false`.
"""
function managed_qdrant_running()::Bool
    _qdrant_child_alive() && return true
    pid = _read_qdrant_pid()
    pid === nothing && return false
    _pid_alive(pid) && return true
    try; rm(_qdrant_pid_file(); force = true); catch; end
    return false
end

"""
    ensure_qdrant!(; timeout=30.0) -> Bool

Make a Qdrant endpoint available, returning `true` if one is reachable by the
time we return.

Fast path: if `QdrantClient.ping()` already succeeds, return immediately — this
covers Docker, a remote instance, or a child we launched earlier.

Otherwise, if managed mode is on and the binary is installed, load it (if needed),
spawn a child bound to the configured port, and poll `/healthz` until ready (up to
`timeout`). Idempotent and thread-safe: concurrent callers are serialized and only
one child is ever spawned. Returns `false` (without spawning) when mode is `:off`
or the binary isn't installed.
"""
function ensure_qdrant!(; timeout::Real = 30.0)::Bool
    QdrantClient.ping() && return true

    mode = qdrant_managed_mode()
    mode === :off && return false

    if _QDRANT_JLL_MOD[] === nothing && !load_qdrant_jll!()
        if mode === :always
            @warn "Managed Qdrant requested (KAIMON_QDRANT_MANAGED=always) but the Qdrant \
                   binary isn't installed. Enable it from the Search tab, or install \
                   Qdrant_jll into Kaimon's service env: $(qdrant_service_env())."
        end
        return false
    end

    lock(_QDRANT_LOCK) do
        QdrantClient.ping() && return true  # another caller may have won the race

        if !_qdrant_child_alive()
            port = _qdrant_http_port()
            log = qdrant_log_path()
            @info "Starting managed Qdrant" port storage = qdrant_storage_dir() log
            try
                _QDRANT_PROC[] = _spawn_managed_qdrant(;
                    storage_path = qdrant_storage_dir(), http_port = port, log_path = log)
                _write_qdrant_pid(getpid(_QDRANT_PROC[]))
            catch e
                @error "Failed to launch managed Qdrant" exception = (e, catch_backtrace())
                return false
            end
        end

        deadline = time() + Float64(timeout)
        while time() < deadline
            QdrantClient.ping() && return true
            if !_qdrant_child_alive()
                @error "Managed Qdrant exited before becoming healthy; see log" log =
                    qdrant_log_path()
                return false
            end
            sleep(0.25)
        end
        @error "Managed Qdrant did not become healthy within $(timeout)s" log =
            qdrant_log_path()
        return false
    end
end

"""
    shutdown_qdrant!()

Reap ONLY the managed Qdrant child THIS process spawned. Registered via `atexit`,
so the owner (the TUI that started it) takes its child down on exit — but a
transient Kaimon subprocess (an agent session, a script, doc rendering) that
merely `using`s Kaimon and never spawned Qdrant is a no-op here and will NOT kill
a shared instance. For an explicit user-driven stop of any managed instance, use
`stop_managed_qdrant!`.
"""
function shutdown_qdrant!()
    lock(_QDRANT_LOCK) do
        proc = _QDRANT_PROC[]
        proc isa Base.Process || return   # we didn't spawn one — leave others alone
        if Base.process_running(proc)
            @info "Stopping managed Qdrant" pid = getpid(proc)
            try
                kill(proc)           # SIGTERM — Qdrant flushes and exits cleanly
                for _ in 1:20
                    Base.process_running(proc) || break
                    sleep(0.1)
                end
                Base.process_running(proc) && kill(proc, Base.SIGKILL)
            catch e
                @warn "Error stopping managed Qdrant" exception = e
            end
        end
        # Only clear the PID file if it points at OUR child.
        _read_qdrant_pid() == getpid(proc) &&
            (try; rm(_qdrant_pid_file(); force = true); catch; end)
        _QDRANT_PROC[] = nothing
    end
end

"""
    stop_managed_qdrant!()

Stop whichever managed Qdrant is running (via the PID file), even one started by a
prior session whose in-memory handle we no longer hold. This is the explicit
user-driven stop (the Search-tab `[l] stop` / `disable`); unlike `shutdown_qdrant!`
it is NOT what `atexit` uses, so it only fires when the user asks.
"""
function stop_managed_qdrant!()
    lock(_QDRANT_LOCK) do
        proc = _QDRANT_PROC[]
        pid = proc isa Base.Process ? getpid(proc) : _read_qdrant_pid()
        if pid !== nothing && _pid_alive(pid)
            @info "Stopping managed Qdrant" pid
            _kill_pid(pid; force = false)
            for _ in 1:20
                _pid_alive(pid) || break
                sleep(0.1)
            end
            _pid_alive(pid) && _kill_pid(pid; force = true)
        end
        _QDRANT_PROC[] = nothing
        try; rm(_qdrant_pid_file(); force = true); catch; end
    end
end

"""
    autostart_managed_qdrant!()

If managed Qdrant is enabled and installed, bring it up in the background (no-op
if it's already answering). Called on TUI launch so the managed instance is
available without a manual `[l]` — the symmetric partner to the `atexit` reap.
Deliberately NOT called from `__init__`, so non-interactive Kaimon processes
(agents, scripts, doc rendering) never spawn Qdrant.
"""
function autostart_managed_qdrant!()
    (qdrant_managed_mode() !== :off && managed_qdrant_installed()) || return
    Threads.@spawn try
        ensure_qdrant!()
    catch e
        @warn "Managed Qdrant auto-start failed" exception = (e, catch_backtrace())
    end
    return
end

"""
    uninstall_managed_qdrant!() -> Bool

Stop the child, disable auto-launch, and delete the service env (reclaiming the
binary artifact reference). The already-loaded module can't be unloaded from a
running process, so a full reclaim of memory needs a restart — but nothing will
launch again. The on-disk vector index is left intact (re-indexable); clear it
separately with `delete_qdrant_storage!`. Returns `true` if the env was removed.
"""
function uninstall_managed_qdrant!()::Bool
    disable_managed_qdrant!()
    env = qdrant_service_env()
    try
        isdir(env) && rm(env; recursive = true, force = true)
        return true
    catch e
        @warn "Failed to remove Qdrant service env" env exception = e
        return false
    end
end

"""Delete the managed Qdrant on-disk storage (the local vector index; re-indexable)."""
function delete_qdrant_storage!()
    dir = joinpath(kaimon_cache_dir(), "qdrant")
    isdir(dir) && rm(dir; recursive = true, force = true)
    return dir
end

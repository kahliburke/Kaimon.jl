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
#
# A managed instance binds to loopback and takes an API key generated at each launch, so on a
# shared machine other accounts cannot use or read the index, and Kaimon never mistakes another
# account's Qdrant for its own. Its port, key and owner are in a private record beside the storage
# (see search_services.jl); one machine at a time serves a given storage directory.

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
const _QDRANT_HEARTBEAT = Ref{Any}(nothing)   # Timer refreshing our record while the child runs

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

"""Directory holding the managed Qdrant's on-disk storage (collections), private to this account."""
qdrant_storage_dir() = private_dir(joinpath(private_dir(qdrant_storage_root()), "storage"))

"""Path to the managed Qdrant's log file (stdout+stderr) on this machine."""
qdrant_log_path() = joinpath(private_dir(qdrant_storage_root()), "qdrant-$(gethostname()).log")

"""The managed instance's record: host, pid, port, API key and heartbeat (see `ServiceRecord`)."""
qdrant_record_path() = joinpath(qdrant_storage_root(), "server.json")

"""
    qdrant_endpoint() -> (url, key)

Where Kaimon's Qdrant is and the key it takes, installed as `QdrantClient.ENDPOINT`:

1. a Qdrant the user configured (`qdrant.url`, with `qdrant.api_key`);
2. the managed instance recorded for this machine;
3. otherwise the configured port on loopback, for a Qdrant the user started there (a container).
   On Linux one owned by another account is not used: an unroutable address is returned instead,
   so it reads as down and a managed instance can be started.
"""
function qdrant_endpoint()::Tuple{String,String}
    ext = qdrant_url_setting()
    isempty(ext) || return (String(rstrip(ext, '/')), qdrant_api_key_setting())
    r = read_service_record(qdrant_record_path())
    (r !== nothing && record_live_here(r)) && return ("http://127.0.0.1:$(r.port)", r.key)
    port = qdrant_port_setting()
    loopback_listener_ok(port) || return ("http://127.0.0.1:0", "")
    return ("http://127.0.0.1:$port", "")
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
    return service_julia_cmd(`$(Base.julia_cmd()) --startup-file=no --color=no -e $code`)
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
    try
        mod = Utils.lazy_require(_QDRANT_JLL; env)
        jll_has_build(mod, "Qdrant") || return false
        _QDRANT_JLL_MOD[] = mod
        return true
    catch e
        @warn "Failed to load Qdrant_jll from the managed service env" env exception =
            (e, catch_backtrace())
        return false
    end
end

# ── Lifecycle ─────────────────────────────────────────────────────────────────

"""Launch the bundled Qdrant binary. Assumes `_QDRANT_JLL_MOD` is loaded."""
function _spawn_managed_qdrant(; storage_path::String, http_port::Int, grpc_port::Int,
                               api_key::String, log_path::String)
    mod = _QDRANT_JLL_MOD[]
    mod === nothing && error("Qdrant_jll is not loaded")
    env = _qdrant_env(; storage_path, http_port, grpc_port, api_key)
    # `qdrant()` was defined by a just-loaded module — reach it past the current world.
    qdrant_cmd = Base.invokelatest(mod.qdrant)::Cmd
    # Qdrant logs every request, so the log is rotated rather than appended to forever.
    logio = open_service_log(log_path)
    # Run with the cache dir as the working directory. Qdrant writes a
    # `.qdrant-initialized` marker (and any other cwd-relative files) into its
    # working dir; without this it inherits the launching process's cwd — e.g. the
    # user's repo — and litters it.
    workdir = dirname(log_path)
    return run(pipeline(setenv(qdrant_cmd, env; dir = workdir);
                        stdin = devnull, stdout = logio, stderr = logio); wait = false)
end

"""
The managed Qdrant's environment: loopback only, the launch's API key (which also guards gRPC,
unused by Kaimon but served anyway), and storage under the private root.
"""
function _qdrant_env(; storage_path::String, http_port::Int, grpc_port::Int, api_key::String)
    env = copy(ENV)
    env["QDRANT__SERVICE__HOST"] = "127.0.0.1"
    env["QDRANT__SERVICE__HTTP_PORT"] = string(http_port)
    env["QDRANT__SERVICE__GRPC_PORT"] = string(grpc_port)
    env["QDRANT__SERVICE__API_KEY"] = api_key
    env["QDRANT__STORAGE__STORAGE_PATH"] = storage_path
    env["QDRANT__STORAGE__SNAPSHOTS_PATH"] = private_dir(joinpath(dirname(storage_path), "snapshots"))
    env["QDRANT__TELEMETRY_DISABLED"] = "true"
    return env
end

"""True if the managed child we started (this session) is still alive."""
_qdrant_child_alive() =
    (_QDRANT_PROC[] isa Base.Process) && Base.process_running(_QDRANT_PROC[])

# In-memory handles (`_QDRANT_PROC`) don't survive a code reload or a process restart, so the
# instance is also described by its record (`qdrant_record_path`). That makes "is a
# Kaimon-managed Qdrant running, and is it ours to stop?" answerable across reloads and restarts,
# and across the machines that share a home directory.

"""
    _proc_pid(proc) -> Union{Int,Nothing}

The child's PID, or `nothing` once the handle is gone. `getpid` throws `ESRCH` on a
process that has already exited and been reaped, so every caller that may run after the
child dies — the `atexit` reaper above all — must go through this.
"""
function _proc_pid(proc::Base.Process)::Union{Int,Nothing}
    try
        return Int(getpid(proc))
    catch
        return nothing
    end
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

True if a Kaimon-managed Qdrant is running on this machine — a child we hold a handle to, or one
in the record from any session (surviving reloads/restarts). A record for this machine whose
process is gone is removed and reports `false`.
"""
function managed_qdrant_running()::Bool
    _qdrant_child_alive() && return true
    r = read_service_record(qdrant_record_path())
    (r === nothing || r.host != gethostname()) && return false
    record_live_here(r) && return true
    try; rm(qdrant_record_path(); force = true); catch; end
    return false
end

"""
    ensure_qdrant!(; timeout=30.0, max_wait=600.0) -> Bool

Make a Qdrant endpoint available, returning `true` if one is reachable by the
time we return.

Fast path: if `QdrantClient.ping()` already succeeds, return immediately — this
covers Docker, a remote instance, or a child we launched earlier. A Qdrant the user
configured (`qdrant.url`) is only connected to, never started.

Otherwise, if managed mode is on and the binary is installed, load it (if needed),
spawn a child on loopback (the configured port, else a per-account fallback) with a
new API key, record it, and poll until ready: `timeout` seconds
without startup progress in its log, or `max_wait` in total (see
[`_await_qdrant_healthy`](@ref)). Idempotent and thread-safe: concurrent callers are serialized and only
one child is ever spawned. Returns `false` (without spawning) when mode is `:off`
or the binary isn't installed.
"""
function ensure_qdrant!(; timeout::Real = 30.0, max_wait::Real = 600.0)::Bool
    QdrantClient.refresh!()
    QdrantClient.ping() && return true
    isempty(qdrant_url_setting()) || return false   # the user's own Qdrant: nothing to start

    mode = qdrant_managed_mode()
    mode === :off && return false

    if _QDRANT_JLL_MOD[] === nothing && !load_qdrant_jll!()
        if mode === :always && !("Qdrant" in JLLS_WITHOUT_BUILD)
            @warn "Managed Qdrant requested (KAIMON_QDRANT_MANAGED=always) but the Qdrant \
                   binary isn't installed. Enable it from the Search tab, or install \
                   Qdrant_jll into Kaimon's service env: $(qdrant_service_env())."
        end
        return false
    end

    lock(_QDRANT_LOCK) do
        QdrantClient.refresh!()
        QdrantClient.ping() && return true  # another caller may have won the race

        if !_qdrant_child_alive()
            rec = qdrant_record_path()
            r = read_service_record(rec)
            # Qdrant's storage is served by one process; two machines sharing a home directory
            # must not both open it.
            if r !== nothing && r.host != gethostname() && record_fresh(r)
                @warn "Kaimon on $(r.host) is serving the Qdrant index in $(qdrant_storage_root()). \
                       One machine at a time can serve an index: use that machine, or give this \
                       one its own qdrant.storage_dir."
                return false
            end
            fixed = qdrant_fixed_port()
            port = service_free_port(qdrant_port_setting(); fixed)
            grpc = port === nothing ? nothing : service_free_port(port + 1; exclude = [port], fixed)
            if port === nothing || grpc === nothing
                @error fixed ?
                    "Managed Qdrant is fixed to ports $(qdrant_port_setting()) and $(qdrant_port_setting() + 1), and one is in use" :
                    "No free port for managed Qdrant near $(qdrant_port_setting())"
                return false
            end
            key = new_service_key()
            log = qdrant_log_path()
            @info "Starting managed Qdrant" port storage = qdrant_storage_dir() log
            try
                proc = _spawn_managed_qdrant(; storage_path = qdrant_storage_dir(),
                    http_port = port, grpc_port = grpc, api_key = key, log_path = log)
                _QDRANT_PROC[] = proc
                write_service_record(rec, ServiceRecord(port, key; pid = getpid(proc)))
                _QDRANT_HEARTBEAT[] === nothing || close(_QDRANT_HEARTBEAT[])
                _QDRANT_HEARTBEAT[] = start_service_heartbeat!(rec, _qdrant_child_alive)
                QdrantClient.configure!("http://127.0.0.1:$port", key)
            catch e
                @error "Failed to launch managed Qdrant" exception = (e, catch_backtrace())
                return false
            end
        end

        log = qdrant_log_path()
        outcome = _await_qdrant_healthy(QdrantClient.ping, _qdrant_child_alive,
            () -> filesize(log); timeout, max_wait)
        outcome === :healthy && return true
        if outcome === :exited
            @error "Managed Qdrant exited before becoming healthy; see log" log
        elseif outcome === :stalled
            @error "Managed Qdrant made no startup progress for $(timeout)s" log
        else
            @error "Managed Qdrant did not become healthy within $(max_wait)s" log
        end
        return false
    end
end

"""
    _await_qdrant_healthy(ping, alive, progress; timeout, max_wait, interval=0.25) -> Symbol

Poll `ping()` until it succeeds (`:healthy`). Qdrant's startup time grows with the
number of collections it loads, and it logs each one, so `progress()` (the log size)
changing resets the `timeout`. Gives up with `:stalled` after `timeout` seconds without
progress, `:max_wait` after `max_wait` seconds in total, or `:exited` once `alive()` is
false.
"""
function _await_qdrant_healthy(ping, alive, progress; timeout::Real, max_wait::Real,
                               interval::Real = 0.25)
    started = time()
    last_progress = started
    last_seen = progress()
    while true
        ping() && return :healthy
        alive() || return :exited
        now_t = time()
        seen = progress()
        if seen != last_seen
            last_seen = seen
            last_progress = now_t
        end
        now_t - started >= max_wait && return :max_wait
        now_t - last_progress >= timeout && return :stalled
        sleep(interval)
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
        # Snapshot the pid up front: `getpid` throws ESRCH once the child has exited and
        # been reaped, and by the time the kill loop below finishes that is exactly the
        # expected state. Escaping from here means an error trace on every clean exit.
        pid = _proc_pid(proc)
        if Base.process_running(proc)
            @info "Stopping managed Qdrant" pid
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
        # Only remove the record if it describes OUR child — or, when the handle died before we
        # could read its pid, a process on this machine that is no longer alive.
        r = read_service_record(qdrant_record_path())
        if r !== nothing && r.host == gethostname() &&
           (r.pid == pid || (pid === nothing && !record_live_here(r)))
            try; rm(qdrant_record_path(); force = true); catch; end
        end
        _QDRANT_HEARTBEAT[] === nothing || (close(_QDRANT_HEARTBEAT[]); _QDRANT_HEARTBEAT[] = nothing)
        _QDRANT_PROC[] = nothing
        QdrantClient.refresh!()
    end
end

"""
    stop_managed_qdrant!()

Stop whichever managed Qdrant is running on this machine (via its record), even one started
by a prior session whose in-memory handle we no longer hold. This is the explicit
user-driven stop (the Search-tab `[l] stop` / `disable`); unlike `shutdown_qdrant!`
it is NOT what `atexit` uses, so it only fires when the user asks.
"""
function stop_managed_qdrant!()
    lock(_QDRANT_LOCK) do
        proc = _QDRANT_PROC[]
        pid = (proc isa Base.Process ? _proc_pid(proc) : nothing)
        r = read_service_record(qdrant_record_path())
        here = r !== nothing && r.host == gethostname()
        # The record's pid is stopped only while it still names the process the record was written for.
        pid = something(pid, here && record_live_here(r) ? r.pid : nothing, Some(nothing))
        if pid !== nothing && _pid_alive(pid)
            @info "Stopping managed Qdrant" pid
            _kill_pid(pid; force = false)
            for _ in 1:20
                _pid_alive(pid) || break
                sleep(0.1)
            end
            _pid_alive(pid) && _kill_pid(pid; force = true)
        end
        _QDRANT_HEARTBEAT[] === nothing || (close(_QDRANT_HEARTBEAT[]); _QDRANT_HEARTBEAT[] = nothing)
        _QDRANT_PROC[] = nothing
        here && (try; rm(qdrant_record_path(); force = true); catch; end)
        QdrantClient.refresh!()
    end
end

"""
    autostart_managed_qdrant!() -> Bool

If managed Qdrant is enabled and installed, bring it up (no-op if it's already
answering), blocking until it is healthy or has failed. Returns whether Qdrant answers.
Called on TUI launch, from a background task, so the managed instance is available
without a manual `[l]` — the symmetric partner to the `atexit` reap. Deliberately NOT
called from `__init__`, so non-interactive Kaimon processes (agents, scripts, doc
rendering) never spawn Qdrant.
"""
function autostart_managed_qdrant!()::Bool
    (qdrant_managed_mode() !== :off && managed_qdrant_installed()) || return QdrantClient.ping()
    try
        return ensure_qdrant!()
    catch e
        @warn "Managed Qdrant auto-start failed" exception = (e, catch_backtrace())
        return false
    end
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

"""
Delete the managed Qdrant on-disk storage (the local vector index; re-indexable). Only what Kaimon
put under the storage root is removed: the root may be a directory the user chose.
"""
function delete_qdrant_storage!()
    root = qdrant_storage_root()
    for d in ("storage", "snapshots")
        p = joinpath(root, d)
        isdir(p) && rm(p; recursive = true, force = true)
    end
    rm(qdrant_record_path(); force = true)
    return root
end

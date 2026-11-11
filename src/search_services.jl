# ── Search services on a shared machine ───────────────────────────────────────
# Search runs local services: Qdrant (the vector index) and, optionally, an embedding server. On a
# laptop 127.0.0.1 is private. On a shared machine, such as a cluster login node, every account can
# connect to it, and the home directory is usually shared by many machines. So a service Kaimon
# starts binds to loopback, takes a key generated at launch, and is described by a private record
# (`ServiceRecord`): the host it runs on, its pid, port and key, and a heartbeat from the Kaimon that
# owns it. Kaimon processes on that host read the record to reach the service; a record from
# another host that is still beating means that host's Kaimon owns it.
#
# Settings live in search.json (`load_search_config`) under "qdrant" and "embedding", and each has
# an environment variable that overrides it.

const SERVICE_PORT_RANGE = 20000:32767   # fallback ports: above common services, below Linux's ephemeral range
const SERVICE_PORT_TRIES = 50
const SERVICE_HEARTBEAT_S = 30.0
const SERVICE_STALE_S = 120.0

# ── Settings ──────────────────────────────────────────────────────────────────

"""
    search_setting(section, key, envvar, default)

A search setting: the environment variable `envvar` when set, else `search.json[section][key]`,
else `default`. Empty strings count as unset.
"""
function search_setting(section::AbstractString, key::AbstractString, envvar::AbstractString, default)
    v = strip(get(ENV, envvar, ""))
    isempty(v) || return String(v)
    sec = get(load_search_config(), section, nothing)
    sec isa AbstractDict || return default
    x = get(sec, key, nothing)
    (x === nothing || (x isa AbstractString && isempty(strip(x)))) && return default
    return x
end

_setting_int(x, default::Int) = x isa Integer ? Int(x) : something(tryparse(Int, strip(string(x))), default)
_setting_bool(x) = x === true || lowercase(strip(string(x))) in ("1", "true", "yes", "on")

"""
URL of a Qdrant the user runs (Docker, a server). Kaimon talks to exactly this server: it starts
nothing and does not check who owns it. Empty means Kaimon manages its own.
"""
qdrant_url_setting()::String = String(search_setting("qdrant", "url", "KAIMON_QDRANT_URL", ""))

"API key for the Qdrant at `qdrant_url_setting()`, if it requires one."
qdrant_api_key_setting()::String = String(search_setting("qdrant", "api_key", "KAIMON_QDRANT_API_KEY", ""))

"The port a managed Qdrant tries first; it falls back to per-account ports when that is taken."
qdrant_port_setting()::Int = _setting_int(search_setting("qdrant", "port", "KAIMON_QDRANT_PORT", 6333), 6333)

"Use `qdrant.port` (and the next port, for gRPC) and nothing else: a taken port is an error."
qdrant_fixed_port()::Bool = _setting_bool(search_setting("qdrant", "fixed_port", "KAIMON_QDRANT_FIXED_PORT", false))

"""
Where the managed Qdrant keeps its index, server record and logs. On a cluster, choose persistent
project storage: scratch space is purged after a period without use, which would delete the index.
"""
qdrant_storage_root()::String =
    abspath(expanduser(String(search_setting("qdrant", "storage_dir", "KAIMON_QDRANT_STORAGE",
                                             joinpath(kaimon_cache_dir(), "qdrant")))))

"`:ollama` (the default) or `:llamacpp`, Kaimon's own llama.cpp server."
function embedding_backend()::Symbol
    v = lowercase(strip(string(search_setting("embedding", "backend", "KAIMON_EMBEDDING_BACKEND", "ollama"))))
    return v in ("llamacpp", "llama.cpp", "llama_cpp") ? :llamacpp : :ollama
end

"Ollama's base URL. `OLLAMA_HOST` is honoured the way Ollama reads it (`host[:port]`, scheme optional)."
function ollama_url()::String
    v = String(search_setting("embedding", "ollama_url", "KAIMON_OLLAMA_URL", ""))
    isempty(v) && (v = strip(get(ENV, "OLLAMA_HOST", "")))
    isempty(v) && return "http://127.0.0.1:11434"
    occursin("://", v) || (v = "http://" * v)
    occursin(r"://[^/]*:\d+", v) || (v = replace(v, r"(://[^/]*)" => s"\1:11434"; count = 1))
    return rstrip(v, '/')
end

"The port Kaimon's llama.cpp embedding server tries first."
llamacpp_port_setting()::Int = _setting_int(search_setting("embedding", "llamacpp_port", "KAIMON_LLAMACPP_PORT", 11435), 11435)

"""
Where embedding models downloaded for the llama.cpp backend are kept. Models already in an Ollama
store are used in place. On a cluster, choose persistent project storage rather than scratch.
"""
embedding_model_dir()::String =
    abspath(expanduser(String(search_setting("embedding", "model_dir", "KAIMON_MODEL_DIR",
                                             joinpath(kaimon_cache_dir(), "models")))))

# ── Logs ──────────────────────────────────────────────────────────────────────

const SERVICE_LOG_ROTATE_BYTES = 32 * 1024^2

"""
    open_service_log(path) -> IO

Open a service's log for appending. A log past `SERVICE_LOG_ROTATE_BYTES` is first moved to
`<path>.1`, so one earlier log is kept and the next start does not erase a crash's output.
"""
function open_service_log(path::AbstractString)
    isfile(path) && filesize(path) > SERVICE_LOG_ROTATE_BYTES && mv(path, path * ".1"; force = true)
    return open(path, "a")
end

"The last `n` lines of the log at `path`, for an error message."
log_tail(path::AbstractString; n::Integer = 12) =
    isfile(path) ? join(last(readlines(path), n), "\n") : ""

# ── Subprocesses ──────────────────────────────────────────────────────────────

"""
    service_julia_cmd(cmd) -> Cmd

`cmd` (a Julia subprocess that installs or downloads for a service) with Julia's default load path.
The `kaimon` app launcher sets `JULIA_LOAD_PATH` to the Kaimon checkout alone, which a child would
inherit: it could then load neither the environment it activates nor the standard library.
"""
service_julia_cmd(cmd::Cmd) = addenv(cmd, "JULIA_LOAD_PATH" => _join_load_path("@", "@v#.#", "@stdlib"))

# ── Ports ─────────────────────────────────────────────────────────────────────

_service_user() = get(ENV, "USER", get(ENV, "USERNAME", string(Sys.isunix() ? ccall(:getuid, Cuint, ()) : 0)))

"""
    service_port_candidates(pref; user) -> Vector{Int}

Ports to try for a service, in order: the preference, then a sequence in `SERVICE_PORT_RANGE` fixed
by the account and the preference. The same account lands on the same fallback each time on a
machine, and different accounts spread over the range. SHA-256 keeps the sequence the same across
Julia versions.
"""
function service_port_candidates(pref::Integer; user::AbstractString = _service_user())
    out = Int[pref]
    i = 0
    while length(out) < SERVICE_PORT_TRIES
        d = SHA.sha256("$user|$pref|$i"); i += 1
        p = first(SERVICE_PORT_RANGE) + Int(mod(reinterpret(UInt32, d[1:4])[1], length(SERVICE_PORT_RANGE)))
        p in out || push!(out, p)
    end
    return out
end

"""
Nothing answers on loopback port `p` and it can be bound. The connect is bounded: a dropped
connection attempt would otherwise block until the kernel gives up on it.
"""
function service_port_free(p::Integer)::Bool
    _tcp_probe("127.0.0.1", p) === :open && return false   # something is serving there
    try
        close(Sockets.listen(Sockets.localhost, p))
        return true
    catch
        return false
    end
end

"""
The first free port among `service_port_candidates(pref)`, skipping `exclude`; `nothing` if none.
With `fixed`, only `pref` itself is considered.
"""
function service_free_port(pref::Integer; exclude = Int[], fixed::Bool = false)
    for p in (fixed ? [Int(pref)] : service_port_candidates(pref))
        p in exclude && continue
        service_port_free(p) && return p
    end
    return nothing
end

"""
    loopback_listener_uid(port) -> Union{Int,Nothing}

The uid owning the socket listening on loopback (or all interfaces) at `port`, from
`/proc/net/tcp{,6}`. Linux only; `nothing` elsewhere or when nothing listens there.
"""
function loopback_listener_uid(port::Integer)
    Sys.islinux() || return nothing
    tag = ":" * uppercase(string(port; base = 16, pad = 4))
    for f in ("/proc/net/tcp", "/proc/net/tcp6")
        isfile(f) || continue
        for line in Iterators.drop(eachline(f), 1)
            occursin(tag * " ", line) || continue
            fs = split(line)
            length(fs) >= 8 && fs[4] == "0A" || continue           # LISTEN
            endswith(fs[2], tag) || continue
            return tryparse(Int, fs[8])
        end
    end
    return nothing
end

"""
Whether a service listening on loopback `port` that Kaimon did not start may be used: it belongs to
this account or to root (a container runtime's port proxy). Unknown owners pass outside Linux.
"""
function loopback_listener_ok(port::Integer)::Bool
    uid = loopback_listener_uid(port)
    uid === nothing && return true
    return uid == 0 || uid == Int(ccall(:getuid, Cuint, ()))
end

"""
    jll_has_build(mod, name) -> Bool

Whether the JLL module `mod` has a binary for this platform. A JLL installs on any platform but
defines its products only where it has a build; without one this says so and returns `false`.
"""
function jll_has_build(mod::Module, name::AbstractString)::Bool
    Base.invokelatest(mod.is_available) && return true
    @warn no_build_message(name)
    push!(JLLS_WITHOUT_BUILD, String(name))
    return false
end

"Names given to `jll_has_build` that found no build for this platform."
const JLLS_WITHOUT_BUILD = Set{String}()

no_build_message(name::AbstractString) = "$name has no build for this platform ($(jll_platform()))"

"This platform as JLLs name it, such as `aarch64-linux-gnu`."
jll_platform() = Base.BinaryPlatforms.triplet(Base.BinaryPlatforms.HostPlatform())

# ── Service records ───────────────────────────────────────────────────────────

"Where a running service is, and whose it is. Written privately; `key` is the service's API key."
struct ServiceRecord
    host::String
    pid::Int
    port::Int
    key::String
    heartbeat::Float64
    started::String   # the process's `Utils.process_start_id`; empty when it couldn't be read
end

ServiceRecord(host, pid, port, key, heartbeat) = ServiceRecord(host, pid, port, key, heartbeat, "")

ServiceRecord(port::Integer, key::AbstractString; pid::Integer = getpid()) =
    ServiceRecord(gethostname(), Int(pid), Int(port), String(key), time(),
                  something(Utils.process_start_id(pid), ""))

"A fresh random key for a service Kaimon starts."
new_service_key()::String = bytes2hex(rand(Random.RandomDevice(), UInt8, 24))

"Create `dir` (and parents) and make it readable by this account only."
function private_dir(dir::AbstractString)::String
    mkpath(dir)
    Sys.isunix() && (try; chmod(dir, 0o700); catch; end)
    return String(dir)
end

function read_service_record(path::AbstractString)::Union{ServiceRecord,Nothing}
    isfile(path) || return nothing
    d = try; JSON.parse(read(path, String)); catch; return nothing; end
    d isa AbstractDict || return nothing
    try
        return ServiceRecord(String(d["host"]), Int(d["pid"]), Int(d["port"]), String(d["key"]),
                             Float64(d["heartbeat"]), String(get(d, "started", "")))
    catch
        return nothing
    end
end

"Write `r` to `path`, created readable by this account only, replacing any earlier record."
function write_service_record(path::AbstractString, r::ServiceRecord)
    private_dir(dirname(path))
    tmp = path * ".tmp"
    open(tmp, "w") do io
        Sys.isunix() && chmod(tmp, 0o600)
        write(io, JSON.json(Dict("host" => r.host, "pid" => r.pid, "port" => r.port, "key" => r.key,
                                 "heartbeat" => r.heartbeat, "started" => r.started)))
    end
    mv(tmp, path; force = true)
    return path
end

"""
The record names a process that is alive on this machine: the same pid and start time, or for a
record without a start time, any process with that pid.
"""
record_live_here(r::ServiceRecord)::Bool =
    r.host == gethostname() && (isempty(r.started) ? _pid_alive(r.pid) : Utils.same_process(r.pid, r.started))

"The record's owner has updated it recently (it may be on another machine)."
record_fresh(r::ServiceRecord; now::Float64 = time())::Bool = now - r.heartbeat < SERVICE_STALE_S

"""
    start_service_heartbeat!(path, alive) -> Timer

Refresh the heartbeat in the record at `path` while `alive()` holds and the record is still ours
(same host and pid). Stops itself otherwise.
"""
function start_service_heartbeat!(path::AbstractString, alive::Function)
    return Timer(SERVICE_HEARTBEAT_S; interval = SERVICE_HEARTBEAT_S) do t
        try
            r = read_service_record(path)
            if r === nothing || r.host != gethostname() || !alive()
                close(t)
            else
                write_service_record(path, ServiceRecord(r.host, r.pid, r.port, r.key, time(), r.started))
            end
        catch
            close(t)
        end
    end
end

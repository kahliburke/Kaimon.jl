# ── Managed llama.cpp embeddings ──────────────────────────────────────────────
# An embedding backend Kaimon runs itself, for machines where Ollama can't be made private:
# Ollama has no authentication and listens on TCP, so on a shared machine every account can use
# it. `llama-server` from `llama_cpp_jll` takes an API key, so Kaimon runs it on loopback with a
# key generated at each launch, recorded the way managed Qdrant is (search_services.jl).
#
# It runs the same GGUF file Ollama uses for a model (a model named like Ollama's, e.g.
# `qwen3-embedding:0.6b`), so vectors match Ollama's and existing indexes stay valid. The file is
# taken from an Ollama store when one has it, else downloaded once from Ollama's registry.
#
# Like Qdrant_jll, `llama_cpp_jll` lives in a Kaimon-owned service environment, installed only
# when this backend is chosen and loaded in-process via LOAD_PATH + `Base.require`.

const _LLAMACPP_JLL = Base.PkgId(Base.UUID("98bd2d0b-bc7c-583a-ba54-7299b0ad0e7f"), "llama_cpp_jll")
const _LLAMACPP_JLL_MOD = Ref{Any}(nothing)
const _LLAMACPP_PROCS = Dict{String,Any}()        # model => Process, for servers this process started
const _LLAMACPP_BEATS = Dict{String,Any}()        # model => heartbeat Timer
const _LLAMACPP_LOCK = ReentrantLock()

const OLLAMA_REGISTRY = "https://registry.ollama.ai"

# ── Installation ──────────────────────────────────────────────────────────────

"The Kaimon-owned environment that holds `llama_cpp_jll`."
llamacpp_service_env() = mkpath(joinpath(kaimon_cache_dir(), "service-env-llamacpp"))

"A subprocess command that installs `llama_cpp_jll` into its service environment."
function llamacpp_install_command()::Cmd
    env = llamacpp_service_env()
    code = "import Pkg; Pkg.activate(raw\"$env\"); Pkg.add(Pkg.PackageSpec(name=\"llama_cpp_jll\"))"
    return service_julia_cmd(`$(Base.julia_cmd()) --startup-file=no --color=no -e $code`)
end

"""
A `llama-server` binary to run instead of `llama_cpp_jll`'s — one built for this machine's CPU, or
with CUDA. Kaimon runs it exactly as it runs the JLL's, and the JLL need not be installed. Empty
means the JLL's.
"""
llamacpp_server_setting()::String =
    String(search_setting("embedding", "llamacpp_server", "KAIMON_LLAMACPP_SERVER", ""))

_llamacpp_custom_server() = (p = llamacpp_server_setting(); isempty(p) ? nothing : abspath(expanduser(p)))

"""
    llamacpp_server_cmd() -> Union{Cmd,Nothing}

The `llama-server` to start: the configured binary when `embedding.llamacpp_server` is set, else
`llama_cpp_jll`'s (loaded on demand). `nothing` when neither is available.
"""
function llamacpp_server_cmd()
    custom = _llamacpp_custom_server()
    if custom !== nothing
        isfile(custom) && return Cmd([custom])
        @warn "embedding.llamacpp_server names a file that does not exist" path = custom
        return nothing
    end
    load_llamacpp_jll!() || return nothing
    return Base.invokelatest(_LLAMACPP_JLL_MOD[].llama_server)::Cmd
end

"True if a `llama-server` is available: a configured one, or `llama_cpp_jll` installed in its service environment."
function llamacpp_installed()::Bool
    custom = _llamacpp_custom_server()
    custom === nothing || return isfile(custom)
    _LLAMACPP_JLL_MOD[] !== nothing && return true
    manifest = joinpath(llamacpp_service_env(), "Manifest.toml")
    return isfile(manifest) && occursin("llama_cpp_jll", read(manifest, String))
end

"Load `llama_cpp_jll` from its service environment into this process. Returns `true` on success."
function load_llamacpp_jll!()::Bool
    _LLAMACPP_JLL_MOD[] !== nothing && return true
    env = llamacpp_service_env()
    isfile(joinpath(env, "Manifest.toml")) || return false
    env in LOAD_PATH || push!(LOAD_PATH, env)
    try
        mod = Base.require(_LLAMACPP_JLL)
        jll_has_build(mod, "llama.cpp") || return false
        _LLAMACPP_JLL_MOD[] = mod
        return true
    catch e
        @warn "Failed to load llama_cpp_jll from its service env" env exception = (e, catch_backtrace())
        return false
    end
end

# ── Model files ───────────────────────────────────────────────────────────────

"Split an Ollama model name into (namespace, name, tag): `qwen3-embedding:0.6b` → (\"library\", ...)."
function split_model_name(model::AbstractString)
    base, tag = occursin(':', model) ? split(model, ':'; limit = 2) : (model, "latest")
    ns, name = occursin('/', base) ? split(base, '/'; limit = 2) : ("library", base)
    return (String(ns), String(name), String(tag))
end

"Ollama's model store: `OLLAMA_MODELS`, else `~/.ollama/models`."
ollama_models_dir() = expanduser(get(ENV, "OLLAMA_MODELS", joinpath("~", ".ollama", "models")))

# The weights layer of an Ollama manifest (`digest`, `size`), or `nothing`.
function _manifest_model_layer(manifest::AbstractDict)
    for l in get(manifest, "layers", [])
        endswith(String(get(l, "mediaType", "")), ".model") && return l
    end
    return nothing
end

"The GGUF file for `model` in an Ollama store, or `nothing`."
function ollama_store_model_file(model::AbstractString)
    ns, name, tag = split_model_name(model)
    mf = joinpath(ollama_models_dir(), "manifests", "registry.ollama.ai", ns, name, tag)
    isfile(mf) || return nothing
    layer = try; _manifest_model_layer(JSON.parse(read(mf, String))); catch; nothing; end
    layer === nothing && return nothing
    f = joinpath(ollama_models_dir(), "blobs", replace(String(layer["digest"]), ":" => "-"))
    return isfile(f) ? f : nothing
end

# Model names and tags contain hyphens; `+` is allowed in neither, so it separates the parts of a
# downloaded file's name unambiguously.
"Where a downloaded copy of `model` is kept: `<namespace>+<name>+<tag>.gguf`."
downloaded_model_path(model::AbstractString) =
    joinpath(embedding_model_dir(), join(split_model_name(model), "+") * ".gguf")

"The GGUF file to serve `model` from: an Ollama store's copy, else a downloaded one, else `nothing`."
function embedding_model_file(model::AbstractString)
    f = ollama_store_model_file(model)
    f === nothing || return f
    d = downloaded_model_path(model)
    return isfile(d) ? d : nothing
end

"""
    remove_downloaded_model!(model) -> Bool

Stop `model`'s llama.cpp server if this process runs it, and delete Kaimon's downloaded copy.
`false` when there is no downloaded copy. A file in an Ollama store is never touched: Ollama shares
blobs between models and removes them itself.
"""
function remove_downloaded_model!(model::AbstractString)::Bool
    lock(() -> _stop_llamacpp_locked!(String(model)), _LLAMACPP_LOCK)
    f = downloaded_model_path(model)
    isfile(f) || return false
    rm(f; force = true)
    return true
end

"Models available to the llama.cpp backend: those in an Ollama store and those downloaded."
function llamacpp_local_models()::Vector{String}
    out = String[]
    root = joinpath(ollama_models_dir(), "manifests", "registry.ollama.ai")
    if isdir(root)
        for ns in readdir(root), name in (isdir(joinpath(root, ns)) ? readdir(joinpath(root, ns)) : String[])
            dir = joinpath(root, ns, name)
            isdir(dir) || continue
            for tag in readdir(dir)
                push!(out, (ns == "library" ? name : "$ns/$name") * ":" * tag)
            end
        end
    end
    if isdir(embedding_model_dir())
        for f in readdir(embedding_model_dir())
            endswith(f, ".gguf") || continue
            parts = split(chopsuffix(f, ".gguf"), '+')
            length(parts) == 3 || continue
            ns, name, tag = parts
            push!(out, (ns == "library" ? name : "$ns/$name") * ":" * tag)
        end
    end
    return unique!(out)
end

"""
    download_embedding_model!(model; progress = nothing) -> String

Download `model`'s GGUF file from Ollama's registry into `embedding_model_dir()` and return its
path. The file is checked against the manifest's SHA-256 digest before it is kept. The transfer
runs in a subprocess using the `Downloads` standard library; `progress(done_bytes, total_bytes)`
is called about twice a second while it runs.
"""
function download_embedding_model!(model::AbstractString; progress = nothing)::String
    ns, name, tag = split_model_name(model)
    r = HTTP.get("$OLLAMA_REGISTRY/v2/$ns/$name/manifests/$tag",
                 ["Accept" => "application/vnd.docker.distribution.manifest.v2+json"];
                 status_exception = false)
    r.status == 200 || error("Ollama's registry has no model '$model' (HTTP $(r.status))")
    layer = _manifest_model_layer(JSON.parse(String(r.body)))
    layer === nothing && error("The manifest for '$model' names no model file")
    digest, total = String(layer["digest"]), Int(get(layer, "size", 0))
    dest = downloaded_model_path(model)
    mkpath(dirname(dest))
    tmp = dest * ".part"
    url = "$OLLAMA_REGISTRY/v2/$ns/$name/blobs/$digest"
    code = "using Downloads; Downloads.download(ARGS[1], ARGS[2])"
    # The subprocess's output goes to a log: inherited, it would be written over the TUI.
    log = joinpath(llamacpp_dir(), "download-$(_model_slug(model)).log")
    proc = open(log, "w") do io
        p = run(pipeline(service_julia_cmd(`$(Base.julia_cmd()) --startup-file=no -e $code $url $tmp`);
                         stdin = devnull, stdout = io, stderr = io); wait = false)
        while Base.process_running(p)
            progress === nothing || progress(isfile(tmp) ? filesize(tmp) : 0, total)
            sleep(0.5)
        end
        p
    end
    if !success(proc)
        rm(tmp; force = true)
        error("The download of '$model' failed:\n" * log_tail(log))
    end
    got = "sha256:" * bytes2hex(open(SHA.sha256, tmp))
    if got != digest
        rm(tmp; force = true)
        error("The download of '$model' does not match its digest ($got ≠ $digest)")
    end
    mv(tmp, dest; force = true)
    return dest
end

# ── Server ────────────────────────────────────────────────────────────────────

"Use `embedding.llamacpp_port` and nothing else: a taken port is an error."
llamacpp_fixed_port()::Bool =
    _setting_bool(search_setting("embedding", "llamacpp_fixed_port", "KAIMON_LLAMACPP_FIXED_PORT", false))

"CPU threads for the embedding server. Kept modest by default: it shares the machine."
llamacpp_threads()::Int =
    _setting_int(search_setting("embedding", "llamacpp_threads", "KAIMON_LLAMACPP_THREADS",
                                min(8, Sys.CPU_THREADS)), min(8, Sys.CPU_THREADS))

_model_slug(model::AbstractString) = replace(model, r"[^A-Za-z0-9._-]" => "_")

"Kaimon's directory for llama.cpp server records and logs, private to this account."
llamacpp_dir() = private_dir(joinpath(kaimon_cache_dir(), "llamacpp"))

"This machine's record for the server of `model`."
llamacpp_record_path(model::AbstractString) =
    joinpath(llamacpp_dir(), "$(gethostname())-$(_model_slug(model)).json")

llamacpp_log_path(model::AbstractString) =
    joinpath(llamacpp_dir(), "$(gethostname())-$(_model_slug(model)).log")

_llamacpp_child_alive(model) = (p = get(_LLAMACPP_PROCS, model, nothing); p isa Base.Process && Base.process_running(p))

"The server answers on `port` and accepts `key`."
function _llamacpp_ok(port::Integer, key::AbstractString)::Bool
    try
        r = HTTP.get("http://127.0.0.1:$port/v1/models", ["Authorization" => "Bearer $key"];
                     connect_timeout = 2, request_timeout = 5, status_exception = false, retry = false)
        return r.status == 200
    catch
        return false
    end
end

# llama.cpp embeds an input in one batch, so the batch is the longest input in tokens. Kaimon sends
# at most `context_chars` characters (4,000), and code runs about 2.5 characters to a token, so this
# leaves room for dense text. The server's memory grows with it.
const LLAMACPP_BATCH = 4096

"The arguments `llama-server` is started with. Pooling comes from the model file, as in Ollama."
llamacpp_server_args(file::AbstractString, port::Integer; threads::Integer = llamacpp_threads()) =
    ["-m", String(file), "--embeddings", "--host", "127.0.0.1", "--port", string(port),
     "-c", string(LLAMACPP_BATCH), "-b", string(LLAMACPP_BATCH),
     "-ub", string(LLAMACPP_BATCH), "-t", string(threads), "-ngl", "99"]

"""
The command that starts `llama-server`. The key goes in the environment, which only this account
can read; command-line arguments are visible to every user of the machine.
"""
llamacpp_server_command(exe, file::AbstractString, port::Integer, key::AbstractString) =
    addenv(`$exe $(llamacpp_server_args(file, port))`, "LLAMA_API_KEY" => String(key))

"""
    ensure_llamacpp!(model; timeout=120) -> Union{Tuple{String,String},Nothing}

The `(url, key)` of a llama.cpp server for `model` on this machine, starting one if needed.
`nothing` when the backend isn't installed, the model file isn't available, or the server didn't
come up. Concurrent callers share one server.
"""
function ensure_llamacpp!(model::AbstractString; timeout::Real = 120.0)
    model = String(model)
    rec = llamacpp_record_path(model)
    r = read_service_record(rec)
    (r !== nothing && record_live_here(r) && _llamacpp_ok(r.port, r.key)) &&
        return ("http://127.0.0.1:$(r.port)", r.key)
    lock(_LLAMACPP_LOCK) do
        r = read_service_record(rec)
        (r !== nothing && record_live_here(r) && _llamacpp_ok(r.port, r.key)) &&
            return ("http://127.0.0.1:$(r.port)", r.key)
        if r !== nothing && r.host == gethostname() && !record_live_here(r)
            @warn "The llama.cpp server for '$model' has exited; starting a new one" log = llamacpp_log_path(model)
        end
        exe = llamacpp_server_cmd()
        exe === nothing && return nothing
        file = embedding_model_file(model)
        if file === nothing
            @warn "No model file for '$model': pull it (the [p] key on the Search tab) or put it in $(embedding_model_dir())"
            return nothing
        end
        fixed = llamacpp_fixed_port()
        port = service_free_port(llamacpp_port_setting(); fixed)
        if port === nothing
            @error fixed ? "The llama.cpp server is fixed to port $(llamacpp_port_setting()), which is in use" :
                           "No free port for the llama.cpp server near $(llamacpp_port_setting())"
            return nothing
        end
        key = new_service_key()
        log = llamacpp_log_path(model)
        cmd = llamacpp_server_command(exe, file, port, key)
        @info "Starting llama.cpp embedding server" model port log
        logio = open_service_log(log)
        println(logio, "\n── $(Dates.now()) llama-server for $model on 127.0.0.1:$port ──")
        flush(logio)
        proc = run(pipeline(cmd; stdin = devnull, stdout = logio, stderr = logio); wait = false)
        _LLAMACPP_PROCS[model] = proc
        write_service_record(rec, ServiceRecord(port, key; pid = getpid(proc)))
        haskey(_LLAMACPP_BEATS, model) && close(_LLAMACPP_BEATS[model])
        _LLAMACPP_BEATS[model] = start_service_heartbeat!(rec, () -> _llamacpp_child_alive(model))
        t0 = time()
        while time() - t0 < timeout
            _llamacpp_ok(port, key) && return ("http://127.0.0.1:$port", key)
            Base.process_running(proc) || break
            sleep(0.25)
        end
        @error "The llama.cpp embedding server did not come up; see its log" model log
        _stop_llamacpp_locked!(model)
        return nothing
    end
end

function _stop_llamacpp_locked!(model::AbstractString)
    proc = pop!(_LLAMACPP_PROCS, model, nothing)
    if proc isa Base.Process && Base.process_running(proc)
        try
            kill(proc)
            for _ in 1:20
                Base.process_running(proc) || break
                sleep(0.1)
            end
            Base.process_running(proc) && kill(proc, Base.SIGKILL)
        catch
        end
    end
    t = pop!(_LLAMACPP_BEATS, model, nothing)
    t === nothing || close(t)
    rec = llamacpp_record_path(model)
    r = read_service_record(rec)
    (r !== nothing && r.host == gethostname() && !record_live_here(r)) && rm(rec; force = true)
    return nothing
end

"Stop the llama.cpp servers this process started (registered with `atexit`)."
function shutdown_llamacpp!()
    lock(_LLAMACPP_LOCK) do
        for model in collect(keys(_LLAMACPP_PROCS))
            _stop_llamacpp_locked!(model)
        end
    end
end

"""
    llamacpp_embedding(text, model; retries = 2) -> Vector{Float64}

Embed `text` with `model` through the managed llama.cpp server. A failed request is retried (a
server that died is restarted by `ensure_llamacpp!`); the last failure is logged. Empty on failure.
"""
function llamacpp_embedding(text::AbstractString, model::AbstractString; retries::Int = 2)::Vector{Float64}
    body = JSON.json(Dict("model" => model, "input" => String(text)))
    note = ""
    for attempt in 0:retries
        ep = ensure_llamacpp!(model)
        if ep === nothing
            note = "no server (see the messages above)"
            break
        end
        url, key = ep
        try
            r = HTTP.post("$url/v1/embeddings",
                          ["Content-Type" => "application/json", "Authorization" => "Bearer $key"],
                          body; status_exception = false, retry_non_idempotent = true)
            if r.status == 200
                data = get(JSON.parse(String(r.body)), "data", [])
                isempty(data) || return Float64.(first(data)["embedding"])
                note = "empty embeddings"
            else
                note = "status $(r.status): $(first(String(r.body), 200))"
            end
        catch e
            note = sprint(showerror, e)
        end
        attempt < retries && sleep(0.25 * (attempt + 1))
    end
    @warn "llama.cpp embedding failed" model attempts = (retries + 1) note log = llamacpp_log_path(model)
    return Float64[]
end

# `kaimon --setup-defaults`: what the first-run wizard sets up for one person on their own machine,
# done without the wizard, for an installer. Nothing already set is changed, so running it again is
# harmless.

"""
    setup_defaults!(; port = 2828, embedding_model = "", io = stdout, pull, install_qdrant, claude) -> Vector{String}

Set Kaimon up for one person on their own machine, as an installer would after installing it:

- settings, where there are none: lax mode (this machine's programs reach it, with no key), the
  loopback addresses only, `port`, and the gate setup marked as answered (other Julia sessions left
  alone until the person chooses otherwise in Kaimon);
- code search through Ollama, where no embedding is set, with `embedding_model` (Kaimon's default
  when empty), pulled into Ollama where it answers (`pull(url, model)`);
- the Qdrant Kaimon manages, installed where no other is set (`install_qdrant()`);
- Claude Code connected to Kaimon at `port`, where it is installed (`claude`, its command, empty for
  none) and Kaimon takes no key.

Each step is said on `io` as it is done or found done. Returns those lines.
"""
function setup_defaults!(; port::Integer = 2828, embedding_model::AbstractString = "", io::IO = stdout,
                         pull = _ollama_pull, install_qdrant = () -> run(qdrant_install_command()),
                         claude::AbstractString = something(Sys.which("claude"), ""))
    said = String[]
    say(line) = (push!(said, line); println(io, "  ", line))

    path = get_global_config_path()
    if load_global_config() === nothing
        mkpath(dirname(path))
        save_global_config(KaimonConfig(:lax, String[], ["127.0.0.1", "::1"], Int(port))) ||
            error("Could not write Kaimon's settings to $path")
        _set_gate_setup_version(GATE_SETUP_VERSION)
        say("Settings: lax, this machine only, port $port ($path)")
    else
        say("Settings: kept ($path)")
    end
    cfg = load_global_config()

    search = load_search_config()
    if haskey(search, "embedding_model") || haskey(search, "embedding")
        say("Code search: kept ($(get(search, "embedding_model", DEFAULT_EMBEDDING_MODEL)))")
    else
        model = isempty(embedding_model) ? DEFAULT_EMBEDDING_MODEL : String(embedding_model)
        search["embedding_model"] = model
        search["embedding"] = Dict{String,Any}("backend" => "ollama")
        mkpath(dirname(_search_config_path()))
        save_search_config(search)
        say("Code search: Ollama, with $model")
    end
    model = String(get(load_search_config(), "embedding_model", DEFAULT_EMBEDDING_MODEL))
    get(get(load_search_config(), "embedding", Dict()), "backend", "ollama") == "ollama" &&
        say(pull(ollama_url(), model) ? "Ollama: $model pulled" : "Ollama: not answering at $(ollama_url()); pull $model there")

    if !isempty(qdrant_url_setting())
        say("Qdrant: kept ($(qdrant_url_setting()))")
    elseif managed_qdrant_installed()
        say("Qdrant: installed")
    else
        install_qdrant()
        say("Qdrant: installed")
    end

    port = cfg.port == 0 ? Int(port) : cfg.port
    if isempty(claude)
        say("Claude Code: not installed")
    elseif cfg.mode !== :lax
        say("Claude Code: Kaimon takes a key ($(cfg.mode) mode); connect it from Kaimon's setup")
    elseif success(pipeline(`$claude mcp get kaimon`; stdout = devnull, stderr = devnull))
        say("Claude Code: connected")
    else
        run(pipeline(`$claude mcp add --scope user --transport http kaimon http://localhost:$port/mcp`; stdout = devnull))
        say("Claude Code: connected at http://localhost:$port/mcp")
    end
    return said
end

"Pull `model` into the Ollama at `url`; whether it answered and has the model now."
function _ollama_pull(url::AbstractString, model::AbstractString)
    try
        r = HTTP.post("$url/api/pull", ["Content-Type" => "application/json"], JSON.json(Dict("model" => model, "stream" => false));
                      connect_timeout = 5, request_timeout = 3600, status_exception = false, retry = false)
        return r.status == 200
    catch
        return false
    end
end

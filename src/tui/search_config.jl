"""Save embedding model choice to search.json."""
function _save_embedding_model(model::AbstractString)
    config = load_search_config()
    config["embedding_model"] = String(model)
    save_search_config(config)
end

"""Load embedding model from search.json, or return the default."""
function _load_embedding_model()
    config = load_search_config()
    get(config, "embedding_model", DEFAULT_EMBEDDING_MODEL)
end

"""Handle per-tab char keys on the Search tab."""
function _handle_search_key!(m::KaimonModel, evt::KeyEvent)
    @match evt.char begin

        '/' => begin
            m.search_query_editing = true
            if m.search_query_input === nothing
                m.search_query_input =
                    TextInput(text = "", label = "Query: ", tick = m.tick)
            end
        end
        'r' => _refresh_search_health_async!(m; force = true)
        'd' => begin
            m.search_chunk_type = if m.search_chunk_type == "all"
                "definitions"
            elseif m.search_chunk_type == "definitions"
                "windows"
            else
                "all"
            end
        end
        'p' => _pull_embedding_model_async!(m)
        # While a start is in progress `l` and `x` do nothing: a stop then would wait for the
        # start and stop Qdrant as soon as it answered.
        'l' => (managed_qdrant_starting() ? _set_search_status!("Managed Qdrant is starting") :
                managed_qdrant_running()  ? _disable_managed_qdrant!(m) :
                                            _start_managed_qdrant_async!(m))
        'x' => (managed_qdrant_starting() ? _set_search_status!("Managed Qdrant is starting") :
                _remove_managed_qdrant_async!(m))
        'c' => begin
            if !isempty(m.search_collections)
                m.search_collection_delete_confirm = false
                m.search_collection_picker_open = true
            end
        end
        'o' => _open_search_config!(m)
        'm' => _open_search_manage!(m)
        _ => nothing
    end
end

"""How often the Search tab re-checks service health while it is shown."""
const SEARCH_HEALTH_POLL_S = 5.0

"""
Spawn an async task to refresh Qdrant/embedder health status. Unless `force`d, skipped when a
check started less than `cooldown` seconds ago. One check runs at a time. A request made while
one is running starts a fresh check when it finishes, unless `queue` is false (the periodic poll).
"""
function _refresh_search_health_async!(m::KaimonModel; force::Bool = false,
                                       cooldown::Real = 10.0, queue::Bool = true)
    m._render_mode && return
    if !force && time() - m.search_health_last_check < cooldown
        return
    end
    if m._search_health_running
        queue && (m._search_health_again = true)
        return
    end
    m._search_health_running = true
    m.search_health_last_check = time()
    force && _set_search_status!("Refreshing...")
    model = m.search_embedding_model
    spawn_task!(m._task_queue, :search_health) do
        health = check_search_health(; model = model)
        collections = health.qdrant_up ? QdrantClient.list_collections() : String[]
        (
            qdrant_up = health.qdrant_up,
            embedder_up = health.embedder_up,
            embedding_backend = health.embedding_backend,
            embedding_where = health.embedding_where,
            model_available = health.model_available,
            collection_count = health.collection_count,
            collections = collections,
            managed_qdrant_enabled = health.managed_qdrant_enabled,
            managed_qdrant_installed = health.managed_qdrant_installed,
            managed_qdrant_running = health.managed_qdrant_running,
            managed_qdrant_starting = health.managed_qdrant_starting,
        )
    end
end

"""Spawn an async task to execute a semantic search."""
function _execute_search!(m::KaimonModel)
    m._render_mode && return
    query_text =
        m.search_query_input !== nothing ? Tachikoma.text(m.search_query_input) : ""
    isempty(strip(query_text)) && return

    # Need a collection
    if isempty(m.search_collections)
        m.search_results = [
            Dict(
                "payload" => Dict(
                    "name" => "Error",
                    "text" => "No collections available. Is Qdrant running?",
                    "file" => "",
                    "start_line" => 0,
                    "end_line" => 0,
                    "type" => "",
                    "signature" => "",
                ),
                "score" => 0.0,
            ),
        ]
        m.search_results_pane = nothing
        return
    end

    collection = m.search_collections[clamp(
        m.search_selected_collection,
        1,
        length(m.search_collections),
    )]
    chunk_type = m.search_chunk_type
    limit = m.search_result_count
    # Query with the model the COLLECTION was indexed with — not the configured
    # one. Vectors from different models are incompatible (even at equal dims),
    # so the [o] selection only governs (re)indexing; search follows the data.
    model = resolve_search_model(collection)

    # Clear results and show "Searching..."
    m.search_results = [
        Dict(
            "payload" => Dict(
                "name" => "Searching...",
                "text" => "Generating embedding and querying Qdrant...",
                "file" => "",
                "start_line" => 0,
                "end_line" => 0,
                "type" => "",
                "signature" => "",
            ),
            "score" => 0.0,
        ),
    ]
    m.search_results_pane = nothing

    spawn_task!(m._task_queue, :search_results) do
        # Pre-flight check
        svc_err = _require_services(need_embedder = true, model = model)
        if svc_err !== nothing
            return Dict[Dict(
                "payload" => Dict(
                    "name" => "Error",
                    "text" => svc_err,
                    "file" => "",
                    "start_line" => 0,
                    "end_line" => 0,
                    "type" => "",
                    "signature" => "",
                ),
                "score" => 0.0,
            )]
        end

        embedding = get_embedding(query_text; model = model)
        if isempty(embedding)
            return Dict[Dict(
                "payload" => Dict(
                    "name" => "Error",
                    "text" => "Failed to generate embedding with model '$model'",
                    "file" => "",
                    "start_line" => 0,
                    "end_line" => 0,
                    "type" => "",
                    "signature" => "",
                ),
                "score" => 0.0,
            )]
        end

        # Build filter
        filter = nothing
        if chunk_type == "definitions"
            filter = Dict(
                "should" => [
                    Dict("key" => "type", "match" => Dict("value" => "function")),
                    Dict("key" => "type", "match" => Dict("value" => "struct")),
                    Dict("key" => "type", "match" => Dict("value" => "macro")),
                    Dict("key" => "type", "match" => Dict("value" => "const")),
                    Dict("key" => "type", "match" => Dict("value" => "tool")),
                ],
            )
        elseif chunk_type == "windows"
            filter = Dict(
                "must" => [Dict("key" => "type", "match" => Dict("value" => "window"))],
            )
        end

        results = try
            QdrantClient.search(collection, embedding; limit = limit, filter = filter)
        catch e
            # A thrown HTTP error (e.g. a 400 dimension/model mismatch) used to
            # escape to the server log with no user-facing message — normalize it
            # into the error-result shape the block below already handles.
            Dict[Dict("error" => sprint(showerror, e))]
        end

        # Check for error results (returned by QdrantClient OR caught above)
        if length(results) == 1 && haskey(first(results), "error")
            err_text = first(results)["error"]
            is_dim_mismatch = _is_dimension_mismatch(err_text)
            if is_dim_mismatch
                err_text *= "\n\nCollection '$collection' was indexed with the '$(resolve_search_model(collection))' model. Press [o] → select that model → Enter to reindex (or reindex from the Collection Manager)."
            end
            _push_log!(:error, "Search failed on '$collection' (model=$model): $(first(results)["error"])")
            return Dict[Dict(
                "payload" => Dict(
                    "name" => "Error",
                    "text" => err_text,
                    "file" => "",
                    "start_line" => 0,
                    "end_line" => 0,
                    "type" => "",
                    "signature" => "",
                ),
                "score" => 0.0,
                "_dimension_mismatch" => is_dim_mismatch,
            )]
        end

        return Dict[r for r in results]
    end
end

"""Detect dimension/vector mismatch errors from Qdrant error messages."""
function _is_dimension_mismatch(err::String)
    err_lower = lowercase(err)
    return contains(err_lower, "dimension") ||
           contains(err_lower, "vector size") ||
           contains(err_lower, "expected dim") ||
           contains(err_lower, "wrong input dimension") ||
           (contains(err_lower, "400") && contains(err_lower, "vector"))
end

"""Delete the currently selected collection from Qdrant."""
function _delete_search_collection!(m::KaimonModel)
    isempty(m.search_collections) && return
    sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
    col_name = m.search_collections[sel]
    _set_search_status!("Deleting '$col_name'...")
    spawn_task!(m._task_queue, :search_delete_collection) do
        ok = QdrantClient.delete_collection(col_name)
        (name = col_name, success = ok)
    end
end

"""
Get the embedding model in the background: Ollama pulls it, or for the llama.cpp backend the same
model file is downloaded from Ollama's registry into the model directory.
"""
function _pull_embedding_model_async!(
    m::KaimonModel;
    model::String = m.search_embedding_model,
)
    if _MODEL_PULL[] !== nothing
        _set_search_status!("Already pulling '$(_MODEL_PULL[].model)'")
        return
    end
    started = time()
    if m.search_embedding_backend === :llamacpp
        _set_model_pull!((model = model, started, done = 0, total = 0))
        _push_log!(:info, "Downloading '$model' from Ollama's registry into $(embedding_model_dir())")
        spawn_task!(m._task_queue, :search_pull_model) do
            try
                download_embedding_model!(model;
                    progress = (d, t) -> _set_model_pull!((model = model, started, done = d, total = t)))
                (success = true, model = model, status = "success")
            catch e
                (success = false, model = model, status = sprint(showerror, e))
            finally
                _set_model_pull!(nothing)
            end
        end
        return
    end
    if !m.search_embedder_up
        _set_search_status!("Cannot pull: Ollama not running")
        return
    end
    _set_model_pull!((model = model, started, done = 0, total = 0))
    _push_log!(:info, "Pulling model '$model' via Ollama...")
    spawn_task!(m._task_queue, :search_pull_model) do
        try
            # ollama pull streams JSON — we just need the final status
            response = HTTP.post(
                "$(ollama_url())/api/pull",
                ["Content-Type" => "application/json"],
                JSON.json(Dict("name" => model, "stream" => false));
                request_timeout = 600,  # models can be large
            )
            data = JSON.parse(String(response.body))
            status = get(data, "status", "unknown")
            (success = status == "success", model = model, status = status)
        catch e
            (success = false, model = model, status = sprint(showerror, e))
        finally
            _set_model_pull!(nothing)
        end
    end
end


"""
Enable managed Qdrant from the Search tab. Picks the right step for the current
state: start it if the launcher is live, activate the extension if `Qdrant_jll`
is merely installed, or install `Qdrant_jll` first if it's missing — all in the
background so the (potentially large) download never blocks the UI.
"""
function _start_managed_qdrant_async!(m::KaimonModel)
    if m.search_qdrant_up
        _set_search_status!("Qdrant already running")
        return
    end
    qdrant_managed_mode() === :off && enable_managed_qdrant!()
    if managed_qdrant_installed()
        # Binary present → ensure_qdrant! loads it (if needed) and spawns.
        _set_search_status!("Starting managed Qdrant...")
        _push_log!(:info, "Starting managed Qdrant child process...")
        # Shown now; the next health check replaces it with what ensure_qdrant! reports.
        m.search_managed_qdrant_enabled = true
        m.search_managed_qdrant_starting = true
        spawn_task!(m._task_queue, :search_start_qdrant) do
            ok = try
                ensure_qdrant!()
            catch e
                _push_log!(:warn, "ensure_qdrant! error: $(sprint(showerror, e))")
                false
            end
            problem = managed_qdrant_start_problem()
            (success = ok, error_msg = ok ? "" :
                "Qdrant" in JLLS_WITHOUT_BUILD ? no_build_message("Qdrant") :
                isempty(problem) ? "did not become healthy (see qdrant.log)" : problem)
        end
    else
        _install_managed_qdrant_async!(m)
    end
end

"""Install the Qdrant binary into Kaimon's service env (subprocess), then load +
start it in-process — no restart, and the app env / repo are never touched."""
function _install_managed_qdrant_async!(m::KaimonModel)
    _set_search_status!("Installing Qdrant (downloading binary)...")
    _push_log!(:info, "Installing Qdrant_jll into Kaimon's service env — this downloads a binary artifact.")
    cmd = qdrant_install_command()
    spawn_task!(m._task_queue, :search_install_qdrant) do
        io = IOBuffer()
        installed = try
            proc = run(pipeline(cmd; stdout = io, stderr = io); wait = false)
            wait(proc)
            proc.exitcode == 0
        catch e
            print(io, "\n", sprint(showerror, e))
            false
        end
        loaded = installed && (try load_qdrant_jll!() catch; false end)
        started = loaded && (try ensure_qdrant!() catch; false end)
        out = String(take!(io))
        tail = join(last(split(out, '\n'; keepempty = false), 12), "\n")
        (installed = installed, active = loaded, started = started, output = tail)
    end
end

"""
Switch the embedding backend and save it in search.json. Choosing llama.cpp installs it into its
service environment first if needed. `KAIMON_EMBEDDING_BACKEND`, when set, still wins.
"""
function _set_embedding_backend!(m::KaimonModel, backend::Symbol)
    cfg = load_search_config()
    emb = get!(() -> Dict{String,Any}(), cfg, "embedding")
    emb["backend"] = String(backend)
    save_search_config(cfg)
    name = backend === :llamacpp ? "llama.cpp" : "Ollama"
    if embedding_backend() !== backend
        _set_search_status!("Saved $name, but KAIMON_EMBEDDING_BACKEND overrides it")
    else
        _set_search_status!("Embedding backend: $name")
        _push_log!(:info, "Embedding backend set to $name")
    end
    m.search_embedding_backend = embedding_backend()
    if m.search_embedding_backend === :llamacpp && !llamacpp_installed()
        _install_llamacpp_async!(m)
    else
        m.search_health_last_check = 0.0
        _refresh_search_health_async!(m)
    end
end

"""Install `llama_cpp_jll` into its service environment (subprocess), then load it in-process."""
function _install_llamacpp_async!(m::KaimonModel)
    _set_search_status!("Installing llama.cpp (downloading binary)...")
    _push_log!(:info, "Installing llama_cpp_jll into Kaimon's service env — this downloads a binary artifact.")
    cmd = llamacpp_install_command()
    spawn_task!(m._task_queue, :search_install_llamacpp) do
        io = IOBuffer()
        installed = try
            proc = run(pipeline(cmd; stdout = io, stderr = io); wait = false)
            wait(proc)
            proc.exitcode == 0
        catch e
            print(io, "\n", sprint(showerror, e))
            false
        end
        loaded = installed && (try load_llamacpp_jll!() catch; false end)
        out = String(take!(io))
        tail = join(last(split(out, '\n'; keepempty = false), 12), "\n")
        (installed = installed, loaded = loaded, output = tail)
    end
end

"""Stop the managed Qdrant child and disable auto-launch (persist mode=off)."""
function _disable_managed_qdrant!(m::KaimonModel)
    disable_managed_qdrant!()
    _set_search_status!("Managed Qdrant stopped & disabled")
    _push_log!(:info, "Stopped managed Qdrant; auto-launch disabled (mode=off)")
    m.search_health_last_check = 0.0
    _refresh_search_health_async!(m)
end

"""Stop, disable, and delete Kaimon's managed Qdrant install (service env). Keeps the
on-disk index. No-op with a note if nothing is installed."""
function _remove_managed_qdrant_async!(m::KaimonModel)
    if !managed_qdrant_installed()
        _set_search_status!("Managed Qdrant is not installed")
        return
    end
    _set_search_status!("Removing managed Qdrant...")
    _push_log!(:info, "Removing Kaimon's managed Qdrant (service env); on-disk index kept.")
    spawn_task!(m._task_queue, :search_remove_qdrant) do
        ok = try
            uninstall_managed_qdrant!()
        catch e
            _push_log!(:warn, "uninstall error: $(sprint(showerror, e))")
            false
        end
        (removed = ok,)
    end
end


# ── Search config panel ──────────────────────────────────────────────────────

"""Open the search config overlay panel and fire async info gathering."""
function _open_search_config!(m::KaimonModel)
    m.search_config_open = true

    # Position cursor on the currently active model
    model_names = sort!(collect(keys(EMBEDDING_CONFIGS)))
    idx = findfirst(==(m.search_embedding_model), model_names)
    # If active model is custom (not in EMBEDDING_CONFIGS), select last entry (Custom)
    is_custom = idx === nothing && !isempty(m.search_embedding_model)
    m.search_config_selected = idx !== nothing ? idx : length(model_names) + 1

    # Seed model list immediately (installed status filled async)
    # Add "Custom..." entry at the end
    m.search_config_models = [
        [(name = n, dims = EMBEDDING_CONFIGS[n].dims, ctx = EMBEDDING_CONFIGS[n].context_tokens, installed = false) for n in model_names];
        [(name = "Custom...", dims = 0, ctx = 0, installed = false)]
    ]
    m.search_config_custom_input = TextInput(
        text = is_custom ? m.search_embedding_model : "",
        label = "Model: ", tick = m.tick)
    m.search_config_custom_editing = false

    _refresh_search_config_info!(m)
end

"""Re-read which models the backend has and the selected collection's info, in the background."""
function _refresh_search_config_info!(m::KaimonModel)
    model_names = sort!(collect(keys(EMBEDDING_CONFIGS)))
    col_name = if !isempty(m.search_collections)
        sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
        m.search_collections[sel]
    else
        ""
    end
    spawn_task!(m._task_queue, :search_config_info) do
        installed_models = list_embedding_models()
        models = [
            (
                name = n,
                dims = EMBEDDING_CONFIGS[n].dims,
                ctx = EMBEDDING_CONFIGS[n].context_tokens,
                installed = any(
                    im -> _model_matches(im, n),
                    installed_models,
                ),
            ) for n in model_names
        ]
        col_info = if !isempty(col_name)
            try
                QdrantClient.get_collection_info(col_name)
            catch
                Dict()
            end
        else
            Dict()
        end
        (models = models, col_info = col_info)
    end
end

"""
`[x]` on a model in the config panel: the first press asks, the second removes it from the current
backend — Ollama deletes it, or for llama.cpp Kaimon's downloaded copy is deleted (a file in Ollama's
store is left to Ollama).
"""
function _remove_selected_model!(m::KaimonModel)
    n = length(m.search_config_models)
    n == 0 && return
    entry = m.search_config_models[clamp(m.search_config_selected, 1, n)]
    model = entry.name
    if model == "Custom..." || !entry.installed
        m.search_config_remove_confirm = ""
        return _set_search_status!("'$model' is not installed")
    end
    if m.search_config_remove_confirm != model
        m.search_config_remove_confirm = model
        return
    end
    m.search_config_remove_confirm = ""
    backend = m.search_embedding_backend
    _set_search_status!("Removing '$model'...")
    spawn_task!(m._task_queue, :search_remove_model) do
        if backend === :llamacpp
            removed = try; remove_downloaded_model!(model); catch; false; end
            note = removed ? "" :
                   ollama_store_model_file(model) !== nothing ?
                   "it is in Ollama's store; remove it with Ollama (switch with [b])" : "no downloaded copy"
            (model = model, removed = removed, note = note)
        else
            removed = remove_ollama_model(model)
            (model = model, removed = removed, note = removed ? "" : "Ollama did not remove it")
        end
    end
end

"""Handle key input inside the search config panel."""
function _handle_search_config_key!(m::KaimonModel, evt::KeyEvent)
    n_models = length(m.search_config_models)

    # Custom model editing mode
    if m.search_config_custom_editing
        if evt.key == :enter
            custom_name = strip(Tachikoma.text(m.search_config_custom_input))
            if !isempty(custom_name)
                m.search_embedding_model = custom_name
                _save_embedding_model(custom_name)
                m.search_config_open = false
            end
            m.search_config_custom_editing = false
        elseif evt.key == :escape
            m.search_config_custom_editing = false
        else
            m.search_config_custom_input !== nothing && handle_key!(m.search_config_custom_input, evt)
        end
        return
    end

    # A pending removal waits for a second [x]; any other key cancels it.
    (evt.key == :char && evt.char == 'x') || (m.search_config_remove_confirm = "")

    @match evt.key begin
        :escape => begin
            m.search_config_open = false
        end
        :up => begin
            if n_models > 0
                m.search_config_selected =
                    m.search_config_selected <= 1 ? n_models : m.search_config_selected - 1
            end
        end
        :down => begin
            if n_models > 0
                m.search_config_selected =
                    m.search_config_selected >= n_models ? 1 : m.search_config_selected + 1
            end
        end
        :enter => begin
            if n_models > 0
                sel = clamp(m.search_config_selected, 1, n_models)
                new_model = m.search_config_models[sel].name
                if new_model == "Custom..."
                    m.search_config_custom_editing = true
                    return
                end
                if new_model != m.search_embedding_model
                    m.search_embedding_model = new_model
                    _save_embedding_model(new_model)
                    m.search_model_available = m.search_config_models[sel].installed
                    _push_log!(:info, "Embedding model set to '$new_model' — applies to new indexing; reindex a collection to switch it.")
                end
                m.search_config_open = false
            end
        end
        :char => begin
            if evt.char == 'x'
                _remove_selected_model!(m)
            elseif evt.char == 'b'
                # On llama.cpp that isn't installed yet, [b] installs it; otherwise it switches.
                if m.search_embedding_backend === :llamacpp && !m.search_embedder_up
                    _install_llamacpp_async!(m)
                else
                    _set_embedding_backend!(m, m.search_embedding_backend === :llamacpp ? :ollama : :llamacpp)
                end
            elseif evt.char == '+' || evt.char == '='
                m.search_result_count = min(50, m.search_result_count + 1)
            elseif evt.char == '-'
                m.search_result_count = max(1, m.search_result_count - 1)
            end
        end
        _ => nothing
    end
end

"""Collect (project_path => collection_name) pairs for all connected sessions whose
collections already exist in Qdrant."""






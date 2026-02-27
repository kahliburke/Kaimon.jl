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
        'o' => _open_search_config!(m)
        'm' => _open_search_manage!(m)
        _ => nothing
    end
end

"""Spawn an async task to refresh Qdrant/Ollama health status."""
function _refresh_search_health_async!(m::KaimonModel; force::Bool = false)
    m._render_mode && return
    # Cooldown: don't re-check within 10 seconds
    if !force && time() - m.search_health_last_check < 10.0
        return
    end
    force && _set_search_status!("Refreshing...")
    model = m.search_embedding_model
    spawn_task!(m._task_queue, :search_health) do
        health = check_search_health(; model = model)
        collections = health.qdrant_up ? QdrantClient.list_collections() : String[]
        (
            qdrant_up = health.qdrant_up,
            ollama_up = health.ollama_up,
            model_available = health.model_available,
            collection_count = health.collection_count,
            collections = collections,
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
    model = m.search_embedding_model

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
        svc_err = _require_services(need_ollama = true, model = model)
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

        embedding = get_ollama_embedding(query_text; model = model)
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

        results = QdrantClient.search(collection, embedding; limit = limit, filter = filter)

        # Check for error results
        if length(results) == 1 && haskey(first(results), "error")
            err_text = first(results)["error"]
            is_dim_mismatch = _is_dimension_mismatch(err_text)
            if is_dim_mismatch
                err_text *= "\n\nThe collection was indexed with a different embedding model. Press [o] → select model → Enter to reindex."
            end
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

"""Pull the embedding model via Ollama in the background."""
function _pull_embedding_model_async!(
    m::KaimonModel;
    model::String = m.search_embedding_model,
)
    if !m.search_ollama_up
        _set_search_status!("Cannot pull: Ollama not running")
        return
    end
    _set_search_status!("Pulling model '$model'...")
    _push_log!(:info, "Pulling model '$model' via Ollama...")
    spawn_task!(m._task_queue, :search_pull_model) do
        try
            # ollama pull streams JSON — we just need the final status
            response = HTTP.post(
                "http://localhost:11434/api/pull",
                ["Content-Type" => "application/json"],
                JSON.json(Dict("name" => model, "stream" => false));
                readtimeout = 600,  # models can be large
            )
            data = JSON.parse(String(response.body))
            status = get(data, "status", "unknown")
            (success = status == "success", model = model, status = status)
        catch e
            (success = false, model = model, status = sprint(showerror, e))
        end
    end
end

"""Index the current project into Qdrant in the background."""
function _index_project_async!(m::KaimonModel; recreate::Bool = false)
    # Need both services + model
    if !(m.search_qdrant_up && m.search_ollama_up && m.search_model_available)
        _set_search_status!("Cannot index: services not ready")
        _push_log!(
            :warn,
            "Cannot index: Qdrant=$(m.search_qdrant_up) Ollama=$(m.search_ollama_up) Model=$(m.search_model_available)",
        )
        return
    end
    project_path = pwd()
    model = m.search_embedding_model
    label = recreate ? "Reindexing" : "Indexing"
    _set_search_status!("$label '$(basename(project_path))'...")
    _push_log!(:info, "$label project '$(basename(project_path))'...")
    spawn_task!(m._task_queue, :search_index_project) do
        try
            result = index_project(project_path; silent = true, recreate = recreate)
            col_name = get_project_collection_name(project_path)
            (
                success = true,
                collection = col_name,
                project = basename(project_path),
                error_msg = "",
            )
        catch e
            (
                success = false,
                collection = "",
                project = basename(project_path),
                error_msg = sprint(showerror, e),
            )
        end
    end
end

# ── Search config panel ──────────────────────────────────────────────────────

"""Open the search config overlay panel and fire async info gathering."""
function _open_search_config!(m::KaimonModel)
    m.search_config_open = true
    m.search_config_confirm = false

    # Position cursor on the currently active model
    model_names = sort!(collect(keys(EMBEDDING_CONFIGS)))
    idx = findfirst(==(m.search_embedding_model), model_names)
    m.search_config_selected = idx !== nothing ? idx : 1

    # Seed model list immediately (installed status filled async)
    m.search_config_models = [
        (
            name = n,
            dims = EMBEDDING_CONFIGS[n].dims,
            ctx = EMBEDDING_CONFIGS[n].context_tokens,
            installed = false,
        ) for n in model_names
    ]

    # Fire async task to check Ollama availability + collection info
    col_name = if !isempty(m.search_collections)
        sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
        m.search_collections[sel]
    else
        ""
    end
    spawn_task!(m._task_queue, :search_config_info) do
        installed_models = list_ollama_models()
        models = [
            (
                name = n,
                dims = EMBEDDING_CONFIGS[n].dims,
                ctx = EMBEDDING_CONFIGS[n].context_tokens,
                installed = any(
                    im -> im == n || startswith(im, split(n, ":")[1]),
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

"""Handle key input inside the search config panel."""
function _handle_search_config_key!(m::KaimonModel, evt::KeyEvent)
    # Reindex confirmation sub-state
    if m.search_config_confirm
        if evt.char == 'y'
            m.search_config_confirm = false
            m.search_config_open = false
            _reindex_session_collections!(m)
        elseif evt.char == 'n' || evt.key == :escape
            m.search_config_confirm = false
            m.search_config_open = false
            _push_log!(:warn, "Collections may be stale — built with a different model")
        end
        return
    end

    n_models = length(m.search_config_models)

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
                if new_model != m.search_embedding_model
                    m.search_embedding_model = new_model
                    m.search_model_available = m.search_config_models[sel].installed
                    # Collect session collections that exist in Qdrant
                    m.search_config_reindex_paths = _collect_session_collections(m)
                    if !isempty(m.search_config_reindex_paths)
                        m.search_config_confirm = true
                    else
                        m.search_config_open = false
                    end
                else
                    m.search_config_open = false
                end
            end
        end
        :char => begin
            @match evt.char begin
                'p' => begin
                    if n_models > 0
                        sel = clamp(m.search_config_selected, 1, n_models)
                        _pull_embedding_model_async!(
                            m;
                            model = m.search_config_models[sel].name,
                        )
                    end
                end
                '+' || '=' => begin
                    m.search_result_count = min(50, m.search_result_count + 1)
                end
                '-' => begin
                    m.search_result_count = max(1, m.search_result_count - 1)
                end
                _ => nothing
            end
        end
        _ => nothing
    end
end

"""Collect (project_path => collection_name) pairs for all connected sessions whose
collections already exist in Qdrant."""
function _collect_session_collections(m::KaimonModel)
    existing = Set(m.search_collections)
    pairs = Pair{String,String}[]
    # From connected sessions
    if m.conn_mgr !== nothing
        conns = lock(m.conn_mgr.lock) do
            copy(m.conn_mgr.connections)
        end
        for conn in conns
            conn.status == :connected || continue
            isempty(conn.project_path) && continue
            col = get_project_collection_name(conn.project_path)
            if col in existing && !any(p -> p.second == col, pairs)
                push!(pairs, conn.project_path => col)
            end
        end
    end
    # Also include the current working directory if it has a collection
    cwd = pwd()
    cwd_col = get_project_collection_name(cwd)
    if cwd_col in existing && !any(p -> p.second == cwd_col, pairs)
        push!(pairs, cwd => cwd_col)
    end
    return pairs
end

"""Resolve the project path for a given collection name by checking connected sessions and pwd."""
function _resolve_project_for_collection(m::KaimonModel, col_name::String)
    if m.conn_mgr !== nothing
        conns = lock(m.conn_mgr.lock) do
            copy(m.conn_mgr.connections)
        end
        for conn in conns
            conn.status == :connected || continue
            isempty(conn.project_path) && continue
            if get_project_collection_name(conn.project_path) == col_name
                return conn.project_path
            end
        end
    end
    if get_project_collection_name(pwd()) == col_name
        return pwd()
    end
    return ""
end

"""Sync the currently selected collection (incremental — only changed/deleted files)."""
function _sync_current_collection!(m::KaimonModel)
    if !(m.search_qdrant_up && m.search_ollama_up && m.search_model_available)
        _set_search_status!("Cannot sync: services not ready")
        _push_log!(
            :warn,
            "Cannot sync: Qdrant=$(m.search_qdrant_up) Ollama=$(m.search_ollama_up) Model=$(m.search_model_available)",
        )
        return
    end
    isempty(m.search_collections) && return
    sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
    col_name = m.search_collections[sel]
    project_path = _resolve_project_for_collection(m, col_name)
    if isempty(project_path)
        _set_search_status!("Cannot sync '$col_name': no project found")
        _push_log!(:warn, "Cannot sync '$col_name': no matching project found")
        return
    end
    _set_search_status!("Syncing '$col_name'...")
    _push_log!(:info, "Syncing collection '$col_name'...")
    spawn_task!(m._task_queue, :search_sync_collection) do
        try
            result = sync_index(
                project_path;
                collection = col_name,
                silent = true,
                verbose = false,
            )
            (
                success = true,
                collection = col_name,
                project = basename(project_path),
                reindexed = result.reindexed,
                deleted = result.deleted,
                chunks = result.chunks,
            )
        catch e
            (
                success = false,
                collection = col_name,
                project = basename(project_path),
                reindexed = 0,
                deleted = 0,
                chunks = 0,
                error_msg = sprint(showerror, e),
            )
        end
    end
end

"""Sync all connected session collections (incremental)."""
function _sync_all_session_collections!(m::KaimonModel)
    if !(m.search_qdrant_up && m.search_ollama_up && m.search_model_available)
        _set_search_status!("Cannot sync: services not ready")
        _push_log!(
            :warn,
            "Cannot sync: Qdrant=$(m.search_qdrant_up) Ollama=$(m.search_ollama_up) Model=$(m.search_model_available)",
        )
        return
    end
    pairs = _collect_session_collections(m)
    if isempty(pairs)
        _set_search_status!("No session collections to sync")
        _push_log!(:warn, "No session collections to sync")
        return
    end
    n = length(pairs)
    _set_search_status!("Syncing $n collection(s)...")
    _push_log!(:info, "Syncing $n session collection(s)...")
    for (proj_path, col_name) in pairs
        spawn_task!(m._task_queue, :search_sync_collection) do
            try
                result = sync_index(
                    proj_path;
                    collection = col_name,
                    silent = true,
                    verbose = false,
                )
                (
                    success = true,
                    collection = col_name,
                    project = basename(proj_path),
                    reindexed = result.reindexed,
                    deleted = result.deleted,
                    chunks = result.chunks,
                )
            catch e
                (
                    success = false,
                    collection = col_name,
                    project = basename(proj_path),
                    reindexed = 0,
                    deleted = 0,
                    chunks = 0,
                    error_msg = sprint(showerror, e),
                )
            end
        end
    end
end

"""Open collection detail overlay for the currently selected collection."""
function _open_collection_detail!(m::KaimonModel)
    isempty(m.search_collections) && return
    sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
    col_name = m.search_collections[sel]
    project_path = _resolve_project_for_collection(m, col_name)
    m.search_detail_open = true
    m.search_detail_info = Dict()
    m.search_detail_index_state = Dict()
    m.search_detail_project_path = project_path
    spawn_task!(m._task_queue, :search_detail_info) do
        col_info = try
            QdrantClient.get_collection_info(col_name)
        catch
            Dict()
        end
        idx_state = if !isempty(project_path)
            try
                load_index_state(project_path)
            catch
                Dict()
            end
        else
            Dict()
        end
        (col_info = col_info, index_state = idx_state)
    end
end

"""Reindex all session collections with the current embedding model."""
function _reindex_session_collections!(m::KaimonModel)
    paths = m.search_config_reindex_paths
    isempty(paths) && return
    n = length(paths)
    names = join([p.second for p in paths], ", ")
    _push_log!(:info, "Reindexing $n collection(s): $names")
    for (proj_path, col_name) in paths
        spawn_task!(m._task_queue, :search_index_project) do
            try
                result = index_project(proj_path; silent = true, recreate = true)
                derived = get_project_collection_name(proj_path)
                (
                    success = true,
                    collection = derived,
                    project = basename(proj_path),
                    error_msg = "",
                )
            catch e
                (
                    success = false,
                    collection = col_name,
                    project = basename(proj_path),
                    error_msg = sprint(showerror, e),
                )
            end
        end
    end
end


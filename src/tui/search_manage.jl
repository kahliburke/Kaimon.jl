# ── Collection Manager Modal ─────────────────────────────────────────────────
# Opened via `m` on the Search tab. Lists all connected sessions + pwd(),
# shows Qdrant collection status, and allows per-session operations.

"""Open the Collection Manager modal and populate entries from connected sessions + pwd()."""
function _open_search_manage!(m::KaimonModel)
    m.search_manage_open = true
    m.search_manage_selected = 1
    m.search_manage_confirm = :none
    m.search_manage_op_status = Dict{String,String}()

    entries = @NamedTuple{
        label::String,
        project_path::String,
        collection::String,
        session_id::String,
        status::Symbol,
    }[]

    # Gather connected sessions
    seen_collections = Set{String}()
    if m.conn_mgr !== nothing
        conns = lock(m.conn_mgr.lock) do
            copy(m.conn_mgr.connections)
        end
        for conn in conns
            proj = conn.project_path
            col = isempty(proj) ? "" : get_project_collection_name(proj)
            label = isempty(conn.display_name) ? conn.name : conn.display_name
            push!(
                entries,
                (
                    label = label,
                    project_path = proj,
                    collection = col,
                    session_id = conn.session_id,
                    status = conn.status,
                ),
            )
            !isempty(col) && push!(seen_collections, col)
        end
    end

    # Add pwd() entry if its collection isn't already covered
    cwd = pwd()
    cwd_col = get_project_collection_name(cwd)
    if cwd_col ∉ seen_collections
        push!(
            entries,
            (
                label = "pwd()",
                project_path = cwd,
                collection = cwd_col,
                session_id = "",
                status = :pwd,
            ),
        )
        push!(seen_collections, cwd_col)
    end

    # Add external projects from the project registry
    registry = load_project_registry()
    for (path, config) in get(registry, "projects", Dict())
        source = get(config, "source", "")
        col = get(config, "collection", "")
        if source == "manual" && !isempty(col) && col ∉ seen_collections
            push!(
                entries,
                (
                    label = basename(path),
                    project_path = path,
                    collection = col,
                    session_id = "",
                    status = :external,
                ),
            )
            push!(seen_collections, col)
        end
    end

    m.search_manage_entries = entries
    m.search_manage_col_info = Dict{String,Dict}()
    m.search_manage_stale = Dict{String,Int}()

    # Fire async task to gather Qdrant info + stale counts for all entries
    entry_data = [(e.collection, e.project_path) for e in entries if !isempty(e.collection)]
    existing_collections = Set(m.search_collections)
    spawn_task!(m._task_queue, :search_manage_info) do
        col_info = Dict{String,Dict}()
        stale_counts = Dict{String,Int}()
        for (col, proj_path) in entry_data
            # Get Qdrant collection info
            if col in existing_collections
                info = try
                    QdrantClient.get_collection_info(col)
                catch
                    Dict()
                end
                col_info[col] = info
            end
            # Count stale files
            if !isempty(proj_path) && isdir(proj_path)
                try
                    state = load_index_state(proj_path)
                    dirs = get(get(state, "config", Dict()), "dirs", String[])
                    extensions = get(
                        get(state, "config", Dict()),
                        "extensions",
                        DEFAULT_INDEX_EXTENSIONS,
                    )
                    if isempty(dirs)
                        src = joinpath(proj_path, "src")
                        dirs = isdir(src) ? [src] : [proj_path]
                    end
                    total_stale = 0
                    for d in dirs
                        total_stale +=
                            length(get_stale_files(proj_path, d; extensions = extensions))
                    end
                    stale_counts[col] = total_stale
                catch
                    stale_counts[col] = -1
                end
            end
        end
        (col_info = col_info, stale_counts = stale_counts)
    end
end

"""Handle key input inside the Collection Manager modal."""
function _handle_search_manage_key!(m::KaimonModel, evt::KeyEvent)
    n = length(m.search_manage_entries)

    # ── Add external project sub-state ──
    if m.search_manage_adding
        _handle_search_manage_add!(m, evt)
        return
    end

    # ── Configure project sub-state ──
    if m.search_manage_configuring
        _handle_search_manage_configure!(m, evt)
        return
    end

    # Confirmation sub-state (delete / reindex)
    if m.search_manage_confirm != :none
        if evt.char == 'y'
            sel = clamp(m.search_manage_selected, 1, max(1, n))
            entry = n > 0 ? m.search_manage_entries[sel] : nothing
            if entry !== nothing
                if m.search_manage_confirm == :delete
                    _manage_delete_collection!(m, entry)
                elseif m.search_manage_confirm == :reindex
                    _manage_reindex_collection!(m, entry)
                end
            end
            m.search_manage_confirm = :none
        elseif evt.char == 'n' || evt.key == :escape
            m.search_manage_confirm = :none
        end
        return
    end

    @match evt.key begin
        :escape => begin
            m.search_manage_open = false
        end
        :up => begin
            n > 0 && (
                m.search_manage_selected =
                    m.search_manage_selected <= 1 ? n : m.search_manage_selected - 1
            )
        end
        :down => begin
            n > 0 && (
                m.search_manage_selected =
                    m.search_manage_selected >= n ? 1 : m.search_manage_selected + 1
            )
        end
        :char => begin
            sel = clamp(m.search_manage_selected, 1, max(1, n))
            entry = n > 0 ? m.search_manage_entries[sel] : nothing
            @match evt.char begin
                'i' => entry !== nothing && _manage_index_collection!(m, entry)
                's' => entry !== nothing && _manage_sync_collection!(m, entry)
                'R' => begin
                    if entry !== nothing
                        m.search_manage_confirm = :reindex
                    end
                end
                'x' => begin
                    if entry !== nothing && !isempty(entry.collection)
                        m.search_manage_confirm = :delete
                    end
                end
                'r' => _refresh_search_manage!(m)
                'a' => _start_add_project!(m)
                'c' => begin
                    entry !== nothing && _start_configure_project!(m, entry)
                end
                _ => nothing
            end
        end
        _ => nothing
    end
end

# ── Add external project flow ────────────────────────────────────────────────

"""Start the add-external-project sub-flow."""
function _start_add_project!(m::KaimonModel)
    m.search_manage_adding = true
    m.search_manage_add_phase = 1
    m.search_manage_path_input = TextInput(text = "", label = "Path: ", tick = m.tick)
    m.search_manage_detected = (type = "", dirs = String[], extensions = String[])
    m.search_manage_config_path = ""
    m.search_manage_config_dirs = ""
    m.search_manage_config_exts = ""
    m.search_manage_config_field = 1
end

"""Handle key events during the add-project sub-flow."""
function _handle_search_manage_add!(m::KaimonModel, evt::KeyEvent)
    if evt.key == :escape
        if m.search_manage_add_phase == 2
            # Go back to path input
            m.search_manage_add_phase = 1
            m.search_manage_detected = (type = "", dirs = String[], extensions = String[])
            return
        end
        m.search_manage_adding = false
        m.search_manage_path_input = nothing
        return
    end

    if m.search_manage_add_phase == 1
        # Phase 1: path input
        _handle_add_path_input!(m, evt)
    else
        # Phase 2: editable config form (reuses configure field editing)
        _handle_add_config_edit!(m, evt)
    end
end

"""Phase 1: handle path input for add flow."""
function _handle_add_path_input!(m::KaimonModel, evt::KeyEvent)
    input = m.search_manage_path_input
    input === nothing && return

    if evt.key == :tab
        _complete_path!(input)
        return
    end

    if evt.key == :enter
        path = expanduser(strip(Tachikoma.text(input)))
        if !isdir(path)
            return
        end
        path = abspath(path)

        # Detect project type and transition to phase 2 with editable fields
        detected = detect_project_type(path)
        m.search_manage_detected = detected
        m.search_manage_config_path = path
        m.search_manage_config_dirs =
            join([_make_relative(d, path) for d in detected.dirs], ", ")
        m.search_manage_config_exts = join(detected.extensions, ", ")
        m.search_manage_config_field = 1
        m.search_manage_add_phase = 2
        return
    end

    handle_key!(input, evt)
end

"""Phase 2: handle editable config fields for add flow."""
function _handle_add_config_edit!(m::KaimonModel, evt::KeyEvent)
    field = m.search_manage_config_field

    if evt.key == :tab || evt.key == :down
        m.search_manage_config_field = field >= 4 ? 1 : field + 1
        return
    elseif evt.key == :up
        m.search_manage_config_field = field <= 1 ? 4 : field - 1
        return
    end

    if evt.key == :enter
        if field == 4
            # Cancel button
            m.search_manage_add_phase = 1
            m.search_manage_detected = (type = "", dirs = String[], extensions = String[])
            return
        end
        # Save (fields 1, 2, or 3)
        path = m.search_manage_config_path
        dirs_raw = filter(!isempty, strip.(split(m.search_manage_config_dirs, ",")))
        exts_raw = filter(!isempty, strip.(split(m.search_manage_config_exts, ",")))

        abs_dirs = String[]
        for d in dirs_raw
            full = d == "." ? path : joinpath(path, d)
            push!(abs_dirs, abspath(full))
        end

        col_name = get_project_collection_name(path)
        register_project!(
            path;
            collection = col_name,
            dirs = abs_dirs,
            extensions = Vector{String}(exts_raw),
            source = "manual",
        )

        entry = (
            label = basename(path),
            project_path = path,
            collection = col_name,
            session_id = "",
            status = :external,
        )
        _manage_index_collection!(m, entry)

        # Reset and refresh
        m.search_manage_adding = false
        m.search_manage_path_input = nothing
        m.search_manage_detected = (type = "", dirs = String[], extensions = String[])
        _open_search_manage!(m)
        return
    end

    # Edit the active field text (only on text fields)
    if evt.key == :char || evt.key == :backspace
        if field == 1
            m.search_manage_config_dirs = _edit_string(m.search_manage_config_dirs, evt)
        elseif field == 2
            m.search_manage_config_exts = _edit_string(m.search_manage_config_exts, evt)
        end
    end
end

# ── Configure project flow ───────────────────────────────────────────────────

"""Start the configure-project sub-flow for the selected entry."""
function _start_configure_project!(m::KaimonModel, entry)
    isempty(entry.project_path) && return
    m.search_manage_configuring = true
    m.search_manage_config_field = 1

    # Load current config from registry, or detect if not registered
    config = get_project_config(entry.project_path)
    if config !== nothing
        dirs = get(config, "dirs", String[])
        exts = get(config, "extensions", DEFAULT_INDEX_EXTENSIONS)
        m.search_manage_config_dirs =
            join([_make_relative(d, entry.project_path) for d in dirs], ", ")
        m.search_manage_config_exts = join(exts, ", ")
    else
        detected = detect_project_type(entry.project_path)
        m.search_manage_config_dirs =
            join([_make_relative(d, entry.project_path) for d in detected.dirs], ", ")
        m.search_manage_config_exts = join(detected.extensions, ", ")
    end
end

"""Convert an absolute dir path to relative if it's under project_path."""
function _make_relative(dir::String, project_path::String)
    pp = abspath(project_path)
    ad = abspath(dir)
    if ad == pp
        return "."
    elseif startswith(ad, pp * "/")
        return ad[length(pp)+2:end]
    end
    return ad
end

"""Handle key events during the configure-project sub-flow."""
function _handle_search_manage_configure!(m::KaimonModel, evt::KeyEvent)
    if evt.key == :escape
        m.search_manage_configuring = false
        return
    end

    n = length(m.search_manage_entries)
    sel = clamp(m.search_manage_selected, 1, max(1, n))
    entry = n > 0 ? m.search_manage_entries[sel] : nothing
    entry === nothing && return

    field = m.search_manage_config_field

    if evt.key == :tab || evt.key == :down
        m.search_manage_config_field = field >= 4 ? 1 : field + 1
        return
    elseif evt.key == :up
        m.search_manage_config_field = field <= 1 ? 4 : field - 1
        return
    end

    if evt.key == :enter
        if field == 4
            # Cancel button
            m.search_manage_configuring = false
            return
        end
        # Save (fields 1, 2, or 3)
        dirs_raw = filter(!isempty, strip.(split(m.search_manage_config_dirs, ",")))
        exts_raw = filter(!isempty, strip.(split(m.search_manage_config_exts, ",")))

        abs_dirs = String[]
        for d in dirs_raw
            full = d == "." ? entry.project_path : joinpath(entry.project_path, d)
            push!(abs_dirs, abspath(full))
        end

        existing_config = get_project_config(entry.project_path)
        existing_source =
            existing_config !== nothing ? get(existing_config, "source", "gate") : "gate"
        register_project!(
            entry.project_path;
            collection = entry.collection,
            dirs = abs_dirs,
            extensions = Vector{String}(exts_raw),
            source = existing_source,
        )

        m.search_manage_configuring = false
        _refresh_search_manage!(m)
        return
    end

    # Edit the active field text (only on text fields)
    if evt.key == :char || evt.key == :backspace
        if field == 1
            m.search_manage_config_dirs = _edit_string(m.search_manage_config_dirs, evt)
        elseif field == 2
            m.search_manage_config_exts = _edit_string(m.search_manage_config_exts, evt)
        end
    end
end

"""Simple inline string editing for configure flow fields."""
function _edit_string(s::String, evt::KeyEvent)
    if evt.key == :backspace
        isempty(s) ? s : s[1:prevind(s, lastindex(s))]
    elseif evt.key == :char && evt.char != '\0'
        s * evt.char
    else
        s
    end
end

"""Refresh Collection Manager info (re-run the async info gather)."""
function _refresh_search_manage!(m::KaimonModel)
    entry_data = [
        (e.collection, e.project_path) for
        e in m.search_manage_entries if !isempty(e.collection)
    ]
    existing_collections = Set(m.search_collections)
    m.search_manage_op_status = Dict{String,String}()
    spawn_task!(m._task_queue, :search_manage_info) do
        col_info = Dict{String,Dict}()
        stale_counts = Dict{String,Int}()
        for (col, proj_path) in entry_data
            if col in existing_collections
                info = try
                    QdrantClient.get_collection_info(col)
                catch
                    Dict()
                end
                col_info[col] = info
            end
            if !isempty(proj_path) && isdir(proj_path)
                try
                    state = load_index_state(proj_path)
                    dirs = get(get(state, "config", Dict()), "dirs", String[])
                    extensions = get(
                        get(state, "config", Dict()),
                        "extensions",
                        DEFAULT_INDEX_EXTENSIONS,
                    )
                    if isempty(dirs)
                        src = joinpath(proj_path, "src")
                        dirs = isdir(src) ? [src] : [proj_path]
                    end
                    total_stale = 0
                    for d in dirs
                        total_stale +=
                            length(get_stale_files(proj_path, d; extensions = extensions))
                    end
                    stale_counts[col] = total_stale
                catch
                    stale_counts[col] = -1
                end
            end
        end
        (col_info = col_info, stale_counts = stale_counts)
    end
end

"""Index a collection for a specific entry."""
function _manage_index_collection!(m::KaimonModel, entry)
    isempty(entry.project_path) && return
    if !(m.search_qdrant_up && m.search_ollama_up && m.search_model_available)
        m.search_manage_op_status[entry.collection] = "Services not ready"
        return
    end
    col = entry.collection
    m.search_manage_op_status[col] = "Indexing..."
    proj_path = entry.project_path
    spawn_task!(m._task_queue, :search_manage_op) do
        try
            index_project(proj_path; silent = true, recreate = false)
            derived = get_project_collection_name(proj_path)
            (op = :index, collection = derived, success = true, msg = "Indexed")
        catch e
            (op = :index, collection = col, success = false, msg = sprint(showerror, e))
        end
    end
end

"""Sync a collection for a specific entry."""
function _manage_sync_collection!(m::KaimonModel, entry)
    isempty(entry.project_path) && return
    if !(m.search_qdrant_up && m.search_ollama_up && m.search_model_available)
        m.search_manage_op_status[entry.collection] = "Services not ready"
        return
    end
    col = entry.collection
    m.search_manage_op_status[col] = "Syncing..."
    proj_path = entry.project_path
    spawn_task!(m._task_queue, :search_manage_op) do
        try
            result = sync_index(proj_path; collection = col, silent = true, verbose = false)
            (
                op = :sync,
                collection = col,
                success = true,
                msg = "$(result.reindexed) reindexed, $(result.deleted) deleted",
            )
        catch e
            (op = :sync, collection = col, success = false, msg = sprint(showerror, e))
        end
    end
end

"""Reindex (recreate) a collection for a specific entry."""
function _manage_reindex_collection!(m::KaimonModel, entry)
    isempty(entry.project_path) && return
    if !(m.search_qdrant_up && m.search_ollama_up && m.search_model_available)
        m.search_manage_op_status[entry.collection] = "Services not ready"
        return
    end
    col = entry.collection
    m.search_manage_op_status[col] = "Reindexing..."
    proj_path = entry.project_path
    spawn_task!(m._task_queue, :search_manage_op) do
        try
            index_project(proj_path; silent = true, recreate = true)
            derived = get_project_collection_name(proj_path)
            (op = :reindex, collection = derived, success = true, msg = "Reindexed")
        catch e
            (op = :reindex, collection = col, success = false, msg = sprint(showerror, e))
        end
    end
end

"""Delete a collection for a specific entry."""
function _manage_delete_collection!(m::KaimonModel, entry)
    col = entry.collection
    isempty(col) && return
    m.search_manage_op_status[col] = "Deleting..."
    proj_path = entry.project_path
    is_external = entry.status == :external
    spawn_task!(m._task_queue, :search_manage_op) do
        try
            # Try to delete the Qdrant collection (may not exist yet for external projects)
            ok = try
                QdrantClient.delete_collection(col)
            catch
                # Collection may not exist — that's fine for external projects
                is_external
            end
            # Always unregister manually-added external projects from the registry
            if is_external && !isempty(proj_path)
                unregister_project!(proj_path)
            end
            (op = :delete, collection = col, success = ok || is_external, msg = "Deleted")
        catch e
            # Still try to unregister even if something else failed
            if is_external && !isempty(proj_path)
                try
                    unregister_project!(proj_path)
                catch
                end
            end
            (op = :delete, collection = col, success = false, msg = sprint(showerror, e))
        end
    end
end

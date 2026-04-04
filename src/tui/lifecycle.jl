# ── Background Reindex (gate → TUI files_changed notifications) ────────────

const REINDEX_DEBOUNCE_SECONDS = 5.0
const REINDEX_MAX_WAIT_SECONDS = 30.0

# Concurrent reindex guard: prevents multiple simultaneous reindexes for the same project
const _REINDEX_IN_PROGRESS = Set{String}()
const _REINDEX_LOCK = ReentrantLock()

"""
    _process_pending_reindexes!(m)

Check `_reindex_pending` for projects whose last notification is older than the
debounce window (5s) OR whose first notification in the burst exceeds the max-wait
cap (30s), and kick off a background sync for each.
"""
function _process_pending_reindexes!(m::KaimonModel)
    m._render_mode && return
    isempty(m._reindex_pending) && return
    now_t = time()
    ready = String[]
    for (path, last_ts) in m._reindex_pending
        debounce_elapsed = now_t - last_ts >= REINDEX_DEBOUNCE_SECONDS
        first_seen = get(m._reindex_first_seen, path, now_t)
        max_wait_exceeded = now_t - first_seen >= REINDEX_MAX_WAIT_SECONDS
        if debounce_elapsed || max_wait_exceeded
            push!(ready, path)
        end
    end
    for path in ready
        delete!(m._reindex_pending, path)
        delete!(m._reindex_first_seen, path)
        _trigger_background_reindex(path)
    end
end

"""
    _trigger_background_reindex(project_path)

Async reindex: check that a Qdrant collection exists for this project, then
run `sync_index` silently. Results are logged to the TUI server log.
Skips if a reindex is already in progress for this project.
"""
function _trigger_background_reindex(project_path::String, render_mode::Bool = false)
    render_mode && return
    # Skip if project_path is empty or would result in "default" collection
    if isempty(project_path) || project_path == "/"
        return
    end
    # Concurrent guard — skip if already reindexing this project
    lock(_REINDEX_LOCK) do
        project_path in _REINDEX_IN_PROGRESS && return
        push!(_REINDEX_IN_PROGRESS, project_path)
    end
    @async Logging.with_logger(TUILogger()) do
        try
            col_name = String(get_project_collection_name(project_path))
            if col_name == "default"
                return
            end
            collections = QdrantClient.list_collections()
            if !(col_name in collections)
                return
            end
            result = sync_index(
                project_path;
                collection = col_name,
                verbose = false,
                silent = true,
            )
            if result.reindexed > 0 || result.deleted > 0
                _push_log!(
                    :info,
                    "Auto-reindex ($col_name): $(result.reindexed) reindexed, $(result.deleted) deleted, $(result.chunks) chunks",
                )
            end
        catch e
            _push_log!(:warn, "Auto-reindex failed: $(sprint(showerror, e))")
        finally
            lock(_REINDEX_LOCK) do
                delete!(_REINDEX_IN_PROGRESS, project_path)
            end
        end
    end
end

# ── Auto-Index on Gate Connect ──────────────────────────────────────────────

"""
    _auto_index_on_connect!(project_path::String)

Async function that auto-indexes a gate project on first connect.
Only triggers for actual Julia projects (must have `Project.toml`).
If the collection exists, does incremental sync; if not, detects project type
and runs a full index with detected defaults.
Uses the `_REINDEX_IN_PROGRESS` guard to prevent concurrent operations.
"""
function _auto_index_on_connect!(project_path::String, render_mode::Bool = false)
    render_mode && return
    if isempty(project_path) || project_path == "/"
        return
    end
    # Only auto-index actual Julia projects (must have Project.toml)
    if !isfile(joinpath(project_path, "Project.toml"))
        return
    end
    _auto_index_project!(project_path)
end

"""
    _auto_index_project!(project_path::String)

Core async auto-index: sync or full-index a project in the background.
Called by gate auto-connect (with Project.toml guard) and by approved-project
indexing at startup (no guard needed — user already approved it).
"""
function _auto_index_project!(project_path::String)
    # Concurrent guard — skip if already reindexing this project
    already_running = lock(_REINDEX_LOCK) do
        if project_path in _REINDEX_IN_PROGRESS
            true
        else
            push!(_REINDEX_IN_PROGRESS, project_path)
            false
        end
    end
    already_running && return

    @async Logging.with_logger(TUILogger()) do
        try
            # Check search services health
            health = check_search_health()
            if !health.qdrant_up || !health.ollama_up || !health.model_available
                return
            end

            col_name = String(get_project_collection_name(project_path))
            if col_name == "default"
                return
            end

            collections = QdrantClient.list_collections()
            if col_name in collections
                # Collection exists → incremental sync
                result = sync_index(
                    project_path;
                    collection = col_name,
                    verbose = false,
                    silent = true,
                )
                if result.reindexed > 0 || result.deleted > 0
                    _push_log!(
                        :info,
                        "Auto-index sync ($col_name): $(result.reindexed) reindexed, $(result.deleted) deleted",
                    )
                end
            else
                # Collection doesn't exist → detect project type and full index
                detected = detect_project_type(project_path)
                _push_log!(
                    :info,
                    "Auto-indexing new project ($col_name) — detected type: $(detected.type)",
                )
                index_project(
                    project_path;
                    collection = col_name,
                    silent = true,
                    extensions = detected.extensions,
                    source = "gate",
                )
                _push_log!(:info, "Auto-index complete ($col_name)")
            end
        catch e
            _push_log!(:warn, "Auto-index failed: $(sprint(showerror, e))")
        finally
            lock(_REINDEX_LOCK) do
                delete!(_REINDEX_IN_PROGRESS, project_path)
            end
        end
    end
end

# ── Lifecycle ─────────────────────────────────────────────────────────────────

function Tachikoma.init!(m::KaimonModel, _t::Tachikoma.Terminal)
    # In render mode (asset generation), skip all real initialization.
    # The mock model already has everything set up.
    m._render_mode && return

    TUI_MODEL[] = m

    try
        Tachikoma.load_theme!()
    catch
        set_theme!(KOKAKU)
    end

    # Open persistent log file
    _open_log_file!()

    # Redirect logging into the TUI ring buffer so @info/@warn from the MCP
    # server, HTTP.jl, etc. show up in the Server tab instead of on stderr.
    _TUI_OLD_LOGGER[] = global_logger()
    global_logger(TUILogger())

    # Capture stderr so background code can't corrupt the terminal
    _start_stderr_capture!()

    # Capture stdout so background println()/print() can't corrupt the TUI.
    # Must happen BEFORE anything else uses stdout — Tachikoma renders to
    # the duped real terminal fd via _t.io instead of the global stdout.
    _start_stdout_capture!()
    _t.io = _TUI_REAL_STDOUT[]

    # Start connection manager (discovers REPL gates)
    # Reuse existing gate services if start!(gate=true) was called before tui()
    if GATE_MODE[] && GATE_CONN_MGR[] !== nothing
        m.conn_mgr = GATE_CONN_MGR[]
    else
        m.conn_mgr = ConnectionManager(task_queue = m._task_queue)
        start!(m.conn_mgr)
        register_sessions_changed_callback!(m.conn_mgr)

        GATE_MODE[] = true
        GATE_CONN_MGR[] = m.conn_mgr

        # Start service endpoint for gate → Kaimon reverse calls (Qdrant, Ollama)
        try
            start_service_endpoint!()
        catch e
            _push_log!(:warn, "Failed to start service endpoint: $(sprint(showerror, e))")
        end

        # Start managed extensions (spawns subprocesses for auto_start extensions)
        start_extensions!()

        # Reconcile stale background jobs after sessions connect
        Threads.@spawn begin
            sleep(10)  # give sessions time to connect
            _reconcile_stale_jobs!(m.conn_mgr)
        end
    end

    m.gate_mirror_repl = get_gate_mirror_repl_preference()

    # Load editor preference from global config
    _cfg = load_global_config()
    m.editor = _cfg !== nothing ? _cfg.editor : "vscode"

    # Load allowed projects config
    m.project_entries = load_projects_config()
    m.tcp_gate_entries = load_tcp_gates_config()

    # Auto-index approved projects in the background.  Each enabled project
    # gets an incremental sync (or a fresh index if its collection doesn't
    # exist yet).  Uses the same concurrency guard as gate auto-index so
    # nothing runs twice if a REPL for the project also connects.
    if !m._render_mode
        for entry in m.project_entries
            entry.enabled || continue
            isdir(entry.project_path) || continue
            _auto_index_project!(entry.project_path)
        end
    end

    # MCP server is started on the first view() tick so the TUI is already
    # rendering and can report status in the Server tab.

    m.start_time = time()
end

function Tachikoma.cleanup!(m::KaimonModel)
    # In render mode (asset generation), skip all real teardown.
    m._render_mode && return

    # Skip teardown on restart — we're coming right back
    m._restart_requested && return

    # Stop service endpoint (gate → Kaimon reverse channel)
    try
        stop_service_endpoint!()
    catch
    end

    # Stop managed sessions and extensions before disconnecting gates
    stop_all_sessions!()
    stop_all_extensions!()

    # Disable gate mode
    GATE_MODE[] = false
    GATE_CONN_MGR[] = nothing

    # Stop MCP server
    if m.mcp_server !== nothing
        try
            stop_mcp_server(m.mcp_server)
        catch
        end
        m.mcp_server = nothing
        m.server_running = false
        SERVER[] = nothing
        ALL_TOOLS[] = nothing
    end

    # Stop connection manager
    if m.conn_mgr !== nothing
        stop!(m.conn_mgr)
    end

    # Restore stdout/stderr before logger so logging can write to stderr again
    _stop_stdout_capture!()
    _stop_stderr_capture!()

    # Restore original logger so post-TUI Julia session isn't silenced
    if _TUI_OLD_LOGGER[] !== nothing
        global_logger(_TUI_OLD_LOGGER[])
        _TUI_OLD_LOGGER[] = nothing
    end

    # Close log file
    _close_log_file!()
end

Tachikoma.should_quit(m::KaimonModel) = m.quit || m._restart_requested
Tachikoma.task_queue(m::KaimonModel) = m._task_queue

# ═══════════════════════════════════════════════════════════════════════════════
# Code staleness / Revise reload
# ═══════════════════════════════════════════════════════════════════════════════

"""Check if any source files have been modified since the last Revise reload."""
function _check_code_stale!(m::KaimonModel)
    m._revise_polling && return  # Revise handles staleness via pre_render!
    now = time()
    now - m._code_last_check < 3.0 && return  # check every 3 seconds
    m._code_last_check = now

    pkg = pkgdir(Kaimon)
    pkg === nothing && return
    src_dir = joinpath(pkg, "src")
    isdir(src_dir) || return

    for (root, dirs, files) in walkdir(src_dir)
        for f in files
            endswith(f, ".jl") || continue
            fpath = joinpath(root, f)
            if mtime(fpath) > m._code_last_revise
                m._code_stale = true
                return
            end
        end
    end
    m._code_stale = false
end

const _REVISE_PENDING = Threads.Atomic{Bool}(false)

"""Start a background task that waits on Revise's file-change event and sets an atomic flag."""
function _start_revise_watcher!(_Revise)
    Threads.@spawn begin
        evt = _Revise.revision_event
        while true
            try
                wait(evt)
                reset(evt)
                _REVISE_PENDING[] = true
                _push_log!(:info, "Revise: file changes detected")
            catch e
                e isa InterruptException && break
            end
        end
    end
end

function Tachikoma.pre_render!(m::KaimonModel)
    m._revise_polling || return
    _REVISE_PENDING[] || return
    _Revise = m._revise_mod
    _Revise === nothing && return
    _REVISE_PENDING[] = false
    try
        _Revise.revise()
        m._code_stale = false
        m._code_last_revise = time()
        _push_log!(:info, "Revise: applied source changes")
    catch e
        _push_log!(:warn, "Revise.revise() failed: $e")
    end
end

"""Request TUI restart — sets flag so app() exits, tui() loop calls Revise and re-enters."""
function _revise_reload!(m::KaimonModel)
    m._restart_requested = true
end

function _try_revise!()
    for (pkg_id, mod) in Base.loaded_modules
        if pkg_id.name == "Revise"
            revise_fn = getfield(mod, :revise)
            Base.invokelatest(revise_fn)
            return true
        end
    end
    return false
end

"""
    tui(; port=2828, theme=:kokaku)

Launch the Kaimon TUI. This is a blocking call that takes over the terminal.

Starts the MCP HTTP server in a background task and watches for REPL gate
connections in `~/.cache/kaimon/sock/`.

# Arguments
- `port::Int=2828`: Port for the MCP HTTP server
- `theme::Symbol=:kokaku`: Tachikoma theme name
"""
function tui(; port::Int = 2828, theme_name::Union{Symbol,Nothing} = nothing, revise_polling::Bool = false, revise_mod::Any = nothing)
    if Threads.nthreads() < 2
        @warn """Kaimon TUI running with only 1 thread — UI may be unresponsive.
                 Start Julia with: julia -t auto
                 Or set: JULIA_NUM_THREADS=auto"""
    end

    # Load markdown extension early so it's in the world age before app() compiles
    try
        enable_markdown()
    catch
    end
    if theme_name !== nothing
        set_theme!(theme_name)
    end
    model = KaimonModel(server_port = port, _revise_polling = revise_polling, _revise_mod = revise_mod)
    model.search_embedding_model = _load_embedding_model()

    while true
        # invokelatest so that after Revise updates, the new method bodies
        # for view()/update!() are visible inside Tachikoma's event loop.
        Base.invokelatest(app, model; fps = 30)

        if model._restart_requested
            model._restart_requested = false
            model.quit = false

            revised = _try_revise!()
            model._code_stale = false
            model._code_last_revise = time()
            _push_log!(
                :info,
                revised ? "Ctrl-U: Revise reload complete — restarting TUI" :
                "Ctrl-U: Revise not available — restarting TUI",
            )
            # Theme is loaded from preferences in init!
            continue
        end

        break  # Normal quit
    end
end

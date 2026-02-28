# ── Update ────────────────────────────────────────────────────────────────────

function Tachikoma.update!(m::KaimonModel, evt::MouseEvent)
    # Tab bar click detection
    if evt.button == mouse_left &&
       evt.action == mouse_press &&
       Base.contains(m._tab_bar_area, evt.x, evt.y)
        tab = _tab_hit(m, evt.x)
        tab > 0 && (_switch_tab!(m, tab); return)
    end

    # Route mouse events to scroll panes and resizable layouts
    @match m.active_tab begin
        1 => begin
            handle_resize!(m.server_layout, evt)
            m.log_pane !== nothing && handle_mouse!(m.log_pane, evt)
        end
        2 => begin
            handle_resize!(m.sessions_layout, evt)
            handle_resize!(m.sessions_left_layout, evt)
            if Base.contains(m._sessions_detail_area, evt.x, evt.y)
                if evt.button == mouse_scroll_up
                    m.sessions_detail_scroll = max(0, m.sessions_detail_scroll - 1)
                elseif evt.button == mouse_scroll_down
                    m.sessions_detail_scroll =
                        min(m.sessions_detail_max_scroll, m.sessions_detail_scroll + 1)
                end
            end
        end
        3 => begin
            handle_resize!(m.activity_layout, evt)
            if m.detail_paragraph !== nothing &&
               Base.contains(m._activity_detail_area, evt.x, evt.y)
                handle_mouse!(m.detail_paragraph, evt)
            end
            _handle_activity_mouse!(m, evt)
        end
        4 => begin
            handle_resize!(m.search_layout, evt)
            m.search_results_pane !== nothing &&
                handle_mouse!(m.search_results_pane, evt)
        end
        5 => begin
            handle_resize!(m.tests_layout, evt)
            if m.test_view_mode == :results && m.test_tree_view !== nothing
                handle_mouse!(m.test_tree_view, evt)
            elseif m.test_output_pane !== nothing
                handle_mouse!(m.test_output_pane, evt)
            end
        end
        6 => begin
            handle_resize!(m.config_layout, evt)
            handle_resize!(m.config_left_layout, evt)
        end
        7 => begin
            handle_resize!(m.advanced_layout, evt)
            m.stress_scroll_pane !== nothing && handle_mouse!(m.stress_scroll_pane, evt)
        end
        _ => nothing
    end
end

function Tachikoma.update!(m::KaimonModel, evt::TaskEvent)
    if evt.id == :client_status
        # Merge a single client detection result into the statuses list
        name, detected = evt.value::Pair{String,Bool}
        idx = findfirst(p -> p.first == name, m.client_statuses)
        if idx !== nothing
            m.client_statuses[idx] = name => detected
        else
            push!(m.client_statuses, name => detected)
        end
    elseif evt.id == :search_health
        # Only clear if we're showing "Refreshing..." (not another op's status)
        first(_SEARCH_STATUS[]) == "Refreshing..." && _set_search_status!("")
        h = evt.value::NamedTuple
        m.search_qdrant_up = h.qdrant_up
        m.search_ollama_up = h.ollama_up
        m.search_model_available = h.model_available
        m.search_collection_count = h.collection_count
        m.search_health_last_check = time()
        # Also refresh collections list if Qdrant is up
        if h.qdrant_up
            m.search_collections = h.collections
            if m.search_selected_collection > length(m.search_collections)
                m.search_selected_collection = max(1, length(m.search_collections))
            end
        else
            m.search_collections = String[]
            m.search_selected_collection = 1
        end
    elseif evt.id == :search_results
        m.search_results = evt.value::Vector{Dict}
        m.search_results_pane = nothing  # force rebuild
        # Check for dimension mismatch in error results
        if length(m.search_results) == 1 &&
           get(first(m.search_results), "_dimension_mismatch", false)
            m.search_dimension_mismatch = true
        else
            m.search_dimension_mismatch = false
        end
    elseif evt.id == :search_delete_collection
        result = evt.value::NamedTuple
        if result.success
            _set_search_status!("Deleted '$(result.name)'")
            # Remove from local list and refresh
            filter!(c -> c != result.name, m.search_collections)
            m.search_collection_count = length(m.search_collections)
            if m.search_selected_collection > length(m.search_collections)
                m.search_selected_collection = max(1, length(m.search_collections))
            end
        else
            _set_search_status!("Delete failed for '$(result.name)'")
        end
        # Force a full health refresh to stay in sync
        m.search_health_last_check = 0.0
        _refresh_search_health_async!(m)
    elseif evt.id == :search_pull_model
        result = evt.value::NamedTuple
        if result.success
            _set_search_status!("Model '$(result.model)' ready")
            _push_log!(:info, "Model '$(result.model)' pulled successfully")
        else
            _set_search_status!("Pull failed: $(result.status)")
            _push_log!(:warn, "Model pull failed: $(result.status)")
        end
        # Refresh health to pick up the new model
        m.search_health_last_check = 0.0
        _refresh_search_health_async!(m)
    elseif evt.id == :search_index_project
        result = evt.value::NamedTuple
        if result.success
            _set_search_status!("Indexed '$(result.project)' → $(result.collection)")
            _push_log!(:info, "Project '$(result.project)' indexed → $(result.collection)")
        else
            _set_search_status!("Index failed: $(result.error_msg)")
            _push_log!(:warn, "Index failed: $(result.error_msg)")
        end
        # Refresh to pick up the new collection
        m.search_health_last_check = 0.0
        _refresh_search_health_async!(m)
    elseif evt.id == :search_config_info
        result = evt.value::NamedTuple
        m.search_config_models = result.models
        m.search_config_col_info = result.col_info
    elseif evt.id == :search_sync_collection
        result = evt.value::NamedTuple
        if result.success
            _set_search_status!(
                "Synced '$(result.collection)': $(result.reindexed) reindexed, $(result.deleted) deleted",
            )
            _push_log!(
                :info,
                "Synced '$(result.collection)': $(result.reindexed) reindexed, $(result.deleted) deleted, $(result.chunks) chunks",
            )
        else
            _set_search_status!("Sync failed: $(result.error_msg)")
            _push_log!(:warn, "Sync failed for '$(result.collection)': $(result.error_msg)")
        end
        m.search_health_last_check = 0.0
        _refresh_search_health_async!(m)
    elseif evt.id == :search_detail_info
        result = evt.value::NamedTuple
        m.search_detail_info = result.col_info
        m.search_detail_index_state = result.index_state
    elseif evt.id == :search_manage_info
        result = evt.value::NamedTuple
        m.search_manage_col_info = result.col_info
        m.search_manage_stale = result.stale_counts
    elseif evt.id == :search_manage_op
        result = evt.value::NamedTuple
        col = result.collection
        if result.success
            m.search_manage_op_status[col] = result.msg
            _push_log!(:info, "Collection Manager: $(result.op) '$(col)' — $(result.msg)")
        else
            m.search_manage_op_status[col] = "Failed"
            _push_log!(
                :warn,
                "Collection Manager: $(result.op) '$(col)' failed — $(result.msg)",
            )
        end
        # Refresh health + modal info
        m.search_health_last_check = 0.0
        _refresh_search_health_async!(m)
        if m.search_manage_open
            if result.op == :delete
                # Rebuild the full entry list (external projects may have been unregistered)
                _open_search_manage!(m)
            else
                _refresh_search_manage!(m)
            end
        end
    end
end

function Tachikoma.update!(m::KaimonModel, evt::KeyEvent)
    # Ignore input while shutting down
    m.shutting_down && return

    # When a modal flow is active, route all input there
    if m.config_flow != FLOW_IDLE
        evt.key == :escape && (m.config_flow = FLOW_IDLE; return)
        handle_flow_input!(m, evt)
        return
    end

    # When a stress test form field is in edit mode, capture all input
    if m.active_tab == 7 && m.stress_editing
        _handle_stress_field_edit!(m, evt)
        return
    end

    # When search config panel is open, capture all input
    if m.active_tab == 4 && m.search_config_open
        _handle_search_config_key!(m, evt)
        return
    end

    # When collection manager modal is open, capture all input
    if m.active_tab == 4 && m.search_manage_open
        _handle_search_manage_key!(m, evt)
        return
    end

    # When collection detail overlay is open, any key closes it
    if m.active_tab == 4 && m.search_detail_open
        m.search_detail_open = false
        return
    end

    # When test session picker is open, route all input there
    if m.active_tab == 5 && m.test_session_picker_open
        _handle_test_picker_key!(m, evt)
        return
    end

    # When search query is being edited, capture all input
    if m.active_tab == 4 && m.search_query_editing
        _handle_search_query_edit!(m, evt)
        return
    end

    tab = m.active_tab

    # ── Global keys (handled before per-tab dispatch) ──
    @match (evt.key, evt.char) begin
        # Quit
        (:char, 'q') => (m.shutting_down = true; return)

        # Ctrl-U: Revise reload
        (:ctrl, 'u') => (_revise_reload!(m); return)

        # Tab switching: number keys
        (:char, c) where {'1' <= c <= '7'} => begin
            _switch_tab!(m, Int(c) - Int('0'))
            return
        end

        # Tab switching: function keys
        (:f1, _) => (_switch_tab!(m, 1); return)
        (:f2, _) => (_switch_tab!(m, 2); return)
        (:f3, _) => (_switch_tab!(m, 3); return)
        (:f4, _) => (_switch_tab!(m, 4); return)
        (:f5, _) => (_switch_tab!(m, 5); return)
        (:f6, _) => (_switch_tab!(m, 6); return)
        (:f7, _) => (_switch_tab!(m, 7); return)

        # Pane focus cycling
        (:tab, _) => begin
            n_panes = get(_PANE_COUNTS, tab, 0)
            if n_panes > 1
                cur = get(m.focused_pane, tab, 1)
                m.focused_pane[tab] = mod1(cur + 1, n_panes)
            end
            return
        end
        (:backtab, _) => begin
            n_panes = get(_PANE_COUNTS, tab, 0)
            if n_panes > 1
                cur = get(m.focused_pane, tab, 1)
                m.focused_pane[tab] = mod1(cur - 1, n_panes)
            end
            return
        end

        # Navigation keys → delegate to per-tab/pane handler
        (:up, _) ||
            (:down, _) ||
            (:pageup, _) ||
            (:pagedown, _) ||
            (:left, _) ||
            (:right, _) ||
            (:enter, _) ||
            (:home, _) ||
            (:end_key, _) => begin
            _handle_nav!(m, evt)
            return
        end

        # Escape — per-tab cancel or quit
        (:escape, _) => begin
            # Ignore escape events during startup — stale terminal probe responses
            # (e.g. partial CSI sequences timing out in read_csi) arrive as
            # spurious KeyEvent(:escape) events within the first second.
            time() - m.start_time < 1.0 && return
            @match tab begin
                7 => (m.stress_state == STRESS_RUNNING && _cancel_stress_test!(m); return)
                5 => (_handle_tests_escape!(m); return)
                4 => begin
                    if m.search_query_editing
                        m.search_query_editing = false
                    else
                        m.shutting_down = true
                    end
                    return
                end
                _ => (m.shutting_down = true)
            end
            return
        end

        _ => nothing  # fall through to per-tab char handling
    end

    # ── Per-tab char key actions ──
    evt.key == :char || return

    @match tab begin
        1 => @match evt.char begin
            'w' => (m.log_word_wrap = !m.log_word_wrap; _rebuild_log_pane!(m))
            'F' => (
                m.log_pane !== nothing && (m.log_pane.following = !m.log_pane.following)
            )
            _ => nothing
        end

        3 => @match evt.char begin
            'f' => (m.activity_mode == :live && _cycle_activity_filter!(m))
            'F' =>
                (m.activity_mode == :live && (m.activity_follow = !m.activity_follow))
            'w' => begin
                m.activity_mode == :live && begin
                    m.result_word_wrap = !m.result_word_wrap
                    m._detail_for_result = -1
                end
            end
            'd' => begin
                m.activity_mode = m.activity_mode == :live ? :analytics : :live
                m.activity_mode == :analytics && _refresh_analytics!(m)
            end
            'r' =>
                (m.activity_mode == :analytics && _refresh_analytics!(m; force = true))
            _ => nothing
        end

        4 => _handle_search_key!(m, evt)
        5 => _handle_tests_key!(m, evt)

        6 => @match evt.char begin
            'o' => begin_onboarding!(m)
            'i' => begin_client_config!(m)
            'g' => begin_global_gate!(m)
            'm' => toggle_gate_mirror_repl!(m)
            _ => nothing
        end

        7 => _handle_stress_key!(m, evt)
        _ => nothing
    end
end

function _handle_nav!(m::KaimonModel, evt::KeyEvent)
    tab = m.active_tab
    fp = get(m.focused_pane, tab, 1)

    @match (tab, fp) begin
        (1, 2) => (m.log_pane !== nothing && handle_key!(m.log_pane, evt))

        (2, 1) => @match evt.key begin
            :up => begin
                m.selected_connection = max(1, m.selected_connection - 1)
                m.sessions_detail_scroll = 0
            end
            :down => begin
                m.conn_mgr !== nothing && begin
                    n_conns = length(m.conn_mgr.connections)
                    m.selected_connection =
                        min(max(1, n_conns), m.selected_connection + 1)
                end
                m.sessions_detail_scroll = 0
            end
            _ => nothing
        end

        (2, 3) => @match evt.key begin
            :up => (m.sessions_detail_scroll = max(0, m.sessions_detail_scroll - 1))
            :down => (
                m.sessions_detail_scroll =
                    min(m.sessions_detail_max_scroll, m.sessions_detail_scroll + 1)
            )
            :page_up =>
                (m.sessions_detail_scroll = max(0, m.sessions_detail_scroll - 5))
            :page_down => (
                m.sessions_detail_scroll =
                    min(m.sessions_detail_max_scroll, m.sessions_detail_scroll + 5)
            )
            :home => (m.sessions_detail_scroll = 0)
            :end => (m.sessions_detail_scroll = m.sessions_detail_max_scroll)
            _ => nothing
        end

        (3, _) => begin
            m.activity_mode == :analytics && return
            if fp == 1
                _handle_activity_scroll!(m, evt)
            elseif fp == 2
                m.detail_paragraph !== nothing && handle_key!(m.detail_paragraph, evt)
            end
        end

        (4, 1) => @match evt.key begin
            :left => begin
                n = length(m.search_collections)
                n > 0 && (
                    m.search_selected_collection =
                        max(1, m.search_selected_collection - 1)
                )
            end
            :right => begin
                n = length(m.search_collections)
                n > 0 && (
                    m.search_selected_collection =
                        min(n, m.search_selected_collection + 1)
                )
            end
            :enter => _open_collection_detail!(m)
            _ => nothing
        end
        (4, 2) => @match evt.key begin
            :enter => begin
                m.search_query_editing = true
                if m.search_query_input === nothing
                    m.search_query_input =
                        TextInput(text = "", label = "Query: ", tick = m.tick)
                end
            end
            _ => nothing
        end
        (4, 3) =>
            (m.search_results_pane !== nothing && handle_key!(m.search_results_pane, evt))

        (5, 1) => begin
            n = length(m.test_runs)
            n > 0 || return
            m.test_follow = false
            @match evt.key begin
                :up => begin
                    m.selected_test_run = min(n, m.selected_test_run + 1)
                    _reset_test_panes!(m)
                end
                :down => begin
                    m.selected_test_run = max(1, m.selected_test_run - 1)
                    _reset_test_panes!(m)
                end
                _ => nothing
            end
        end
        (5, 2) => begin
            # TreeView handles up/down/left/right/enter/home/end_key
            if m.test_view_mode == :results && m.test_tree_view !== nothing
                handle_key!(m.test_tree_view, evt)
            elseif m.test_output_pane !== nothing
                handle_key!(m.test_output_pane, evt)
            end
        end

        (7, 1) => @match evt.key begin
            :up => (m.stress_field_idx = max(1, m.stress_field_idx - 1))
            :down => (m.stress_field_idx = min(6, m.stress_field_idx + 1))
            :enter => _handle_stress_enter!(m)
            _ => nothing
        end
        (7, 2) => begin
            step = evt.key in (:pageup, :pagedown) ? 5 : 1
            @match evt.key begin
                :up || :pageup =>
                    (m.stress_horde_scroll = max(0, m.stress_horde_scroll - step))
                :down || :pagedown => (m.stress_horde_scroll += step)
                _ => nothing
            end
        end
        (7, 3) =>
            (m.stress_scroll_pane !== nothing && handle_key!(m.stress_scroll_pane, evt))

        _ => nothing
    end
end

"""Reset test output panes and tree view (used on run selection change)."""
function _reset_test_panes!(m::KaimonModel)
    m._test_output_synced = 0
    m.test_output_pane = nothing
    m.test_tree_view = nothing
    m._test_tree_synced = 0
end

"""Navigate the activity tool call list (in-flight + completed, filtered)."""
function _handle_activity_scroll!(m::KaimonModel, evt::KeyEvent)
    m.activity_follow = false
    filter_key = m.activity_filter

    # Build filtered in-flight indices (display order: reversed)
    fi_indices = Int[]
    for i = 1:length(m.inflight_calls)
        if isempty(filter_key) || m.inflight_calls[i].session_key == filter_key
            push!(fi_indices, i)
        end
    end
    reverse!(fi_indices)

    # Build filtered completed indices (display order: reversed)
    fc_indices = Int[]
    for i = 1:length(m.tool_results)
        if isempty(filter_key) || m.tool_results[i].session_key == filter_key
            push!(fc_indices, i)
        end
    end
    reverse!(fc_indices)

    total = length(fi_indices) + length(fc_indices)
    total == 0 && return

    # Find current position in combined list
    cur = 0
    if m.selected_inflight > 0
        pos = findfirst(==(m.selected_inflight), fi_indices)
        pos !== nothing && (cur = pos)
    elseif m.selected_result > 0
        pos = findfirst(==(m.selected_result), fc_indices)
        pos !== nothing && (cur = length(fi_indices) + pos)
    end

    # Move selection
    new_pos = @match evt.key begin
        :up => max(1, cur - 1)
        :down => min(total, cur + 1)
        _ => cur
    end
    new_pos == 0 && (new_pos = 1)

    # Map position back to inflight or completed
    if new_pos <= length(fi_indices)
        m.selected_inflight = fi_indices[new_pos]
        m.selected_result = 0
    else
        m.selected_inflight = 0
        m.selected_result = fc_indices[new_pos-length(fi_indices)]
    end
    m.result_scroll = 0
    m._detail_for_result = -1
end

function _handle_activity_mouse!(m::KaimonModel, evt::MouseEvent)
    w = m._activity_list_widget
    w === nothing && return

    prev_sel = w.selected
    prev_off = w.offset
    handled = handle_mouse!(w, evt)
    handled || return

    # Sync offset back to model
    m._activity_list_offset = w.offset

    # If selection changed (click), map display index to inflight/completed
    if w.selected != prev_sel
        m.activity_follow = false
        _select_activity_by_display_index!(m, w.selected)
        m.focused_pane[3] = 1
    end
end

function _select_activity_by_display_index!(m::KaimonModel, display_idx::Int)
    filter_key = m.activity_filter

    # Rebuild filtered in-flight indices (display order: reversed)
    fi_indices = Int[]
    for i = 1:length(m.inflight_calls)
        if isempty(filter_key) || m.inflight_calls[i].session_key == filter_key
            push!(fi_indices, i)
        end
    end
    reverse!(fi_indices)

    # Rebuild filtered completed indices (display order: reversed)
    fc_indices = Int[]
    for i = 1:length(m.tool_results)
        if isempty(filter_key) || m.tool_results[i].session_key == filter_key
            push!(fc_indices, i)
        end
    end
    reverse!(fc_indices)

    if display_idx <= length(fi_indices)
        m.selected_inflight = fi_indices[display_idx]
        m.selected_result = 0
    elseif display_idx - length(fi_indices) <= length(fc_indices)
        m.selected_inflight = 0
        m.selected_result = fc_indices[display_idx-length(fi_indices)]
    end
    m._detail_for_result = -1
    m.detail_paragraph = nothing
end

# ── Tab switching ────────────────────────────────────────────────────────────

function _switch_tab!(m::KaimonModel, tab::Int)
    m.active_tab = tab
    # Trigger async refresh when entering certain tabs
    if tab == 4
        _refresh_search_health_async!(m)
    elseif tab == 6
        _refresh_client_status_async!(m)
    end
end

# Tab label lengths for mouse hit testing (must match the TabBar labels in view)
const _TAB_LABEL_LENS = [8, 10, 10, 8, 7, 8, 10]  # "1 Server", "2 Sessions", "3 Activity", "4 Search", "5 Tests", "6 Config", "7 Advanced"
const _TAB_SEPARATOR_LEN = 3  # " │ "

"""Determine which tab (1-7) was clicked at `click_x`, or 0 if none."""
function _tab_hit(m::KaimonModel, click_x::Int)
    vis = m._tab_visible_range
    has_left = first(vis) > 1
    # Start x after the left "…" indicator if present
    x = m._tab_bar_area.x + (has_left ? 1 : 0)
    for real_idx in vis
        if real_idx > first(vis)
            x += _TAB_SEPARATOR_LEN
        end
        tab_w = _TAB_LABEL_LENS[real_idx] + 2
        if click_x >= x && click_x < x + tab_w
            return real_idx
        end
        x += tab_w
    end
    return 0
end

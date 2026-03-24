# ── Update ────────────────────────────────────────────────────────────────────

function Tachikoma.update!(m::KaimonModel, evt::MouseEvent)
    # Quit confirmation modal captures all mouse input
    if m.quit_confirm && m.quit_confirm_modal !== nothing
        result = handle_mouse!(m.quit_confirm_modal, evt)
        if result == :confirm
            m.quit_confirm = false
            m.quit_confirm_modal = nothing
            m.shutting_down = true
        elseif result == :cancel
            m.quit_confirm = false
            m.quit_confirm_modal = nothing
        end
        return
    end

    # Backtrace viewer captures mouse (scrolling)
    if m.backtrace_viewer !== nothing
        handle_mouse!(m.backtrace_viewer, evt)
        return
    end

    # Backtrace modal captures mouse
    if m.backtrace_modal !== nothing
        result = handle_mouse!(m.backtrace_modal, evt)
        if result == :cancel || result == :confirm
            m.backtrace_modal = nothing
            m.backtrace_collecting = false
        end
        return
    end

    # Debug consent modal captures all mouse input
    if m.debug_agent_continue_pending
        Base.invokelatest(_handle_debug_consent_key!, m, evt)
        return
    end

    # Tab bar click detection — fully delegated to Tachikoma TabBar
    result = handle_mouse!(m.tab_bar, evt)
    if result == :changed
        _switch_tab!(m, m.tab_bar.active)
        return
    end

    # Route mouse events to scroll panes and resizable layouts
    @match m.tab_bar.active begin
        $TAB_SERVER => begin
            handle_resize!(m.server_layout, evt)
            m.log_pane !== nothing && handle_mouse!(m.log_pane, evt)
        end
        $TAB_SESSIONS => begin
            if m.session_terminal_open && m.session_terminal !== nothing
                handle_mouse!(m.session_terminal, evt)
                return  # terminal captures all mouse in full-screen mode
            end
            # Prioritize col_drag on either DataTable
            _st_drag = m.sessions_table !== nothing && m.sessions_table.col_drag > 0
            _at_drag = m.agents_table !== nothing && m.agents_table.col_drag > 0
            if !_st_drag && !_at_drag
                handle_resize!(m.sessions_layout, evt)
                handle_resize!(m.sessions_left_layout, evt)
            end
            _lr = m.sessions_left_layout.rects
            _rr = m.sessions_layout.rects
            _in_pane(rects, i, e) = length(rects) >= i && Base.contains(rects[i], e.x, e.y)
            if m.sessions_table !== nothing &&
               (m.sessions_table.col_drag > 0 || _in_pane(_lr, 1, evt))
                prev = m.sessions_table.selected
                handle_mouse!(m.sessions_table, evt)
                if m.sessions_table.selected != prev && m.sessions_table.selected > 0
                    m.selected_connection = m.sessions_table.selected
                    m.sessions_detail_scroll = 0
                    m.focused_pane[2] = 1
                end
            elseif m.agents_table !== nothing &&
                   (m.agents_table.col_drag > 0 || _in_pane(_lr, 2, evt))
                handle_mouse!(m.agents_table, evt)
            elseif _in_pane(_rr, 2, evt)
                if evt.button == mouse_scroll_up
                    m.sessions_detail_scroll = max(0, m.sessions_detail_scroll - 1)
                elseif evt.button == mouse_scroll_down
                    m.sessions_detail_scroll =
                        min(m.sessions_detail_max_scroll, m.sessions_detail_scroll + 1)
                end
            end
        end
        $TAB_ACTIVITY => begin
            _dt_drag3 = m.activity_table !== nothing && m.activity_table.col_drag > 0
            if !_dt_drag3
                handle_resize!(m.activity_layout, evt)
            end
            _ar = m.activity_layout.rects
            if m.activity_table !== nothing &&
               (m.activity_table.col_drag > 0 || (length(_ar) >= 1 && Base.contains(_ar[1], evt.x, evt.y)))
                _handle_activity_mouse!(m, evt)
            elseif m.detail_paragraph !== nothing &&
                   length(_ar) >= 2 && Base.contains(_ar[2], evt.x, evt.y)
                handle_mouse!(m.detail_paragraph, evt)
            end
        end
        $TAB_SEARCH => begin
            handle_resize!(m.search_layout, evt)
            if m.search_manage_open && m.search_manage_table !== nothing
                handle_mouse!(m.search_manage_table, evt)
                m.search_manage_selected = m.search_manage_table.selected
            end
            m.search_results_pane !== nothing &&
                handle_mouse!(m.search_results_pane, evt)
        end
        $TAB_TESTS => begin
            _dt_drag5 = m.tests_table !== nothing && m.tests_table.col_drag > 0
            if !_dt_drag5
                handle_resize!(m.tests_layout, evt)
            end
            _tr = m.tests_layout.rects
            if m.tests_table !== nothing &&
               (m.tests_table.col_drag > 0 || (length(_tr) >= 1 && Base.contains(_tr[1], evt.x, evt.y)))
                prev = m.tests_table.selected
                handle_mouse!(m.tests_table, evt)
                if m.tests_table.selected != prev
                    n = length(m.test_runs)
                    m.test_follow = false
                    m.selected_test_run = n - m.tests_table.selected + 1
                    _reset_test_panes!(m)
                end
            elseif length(_tr) >= 2 && Base.contains(_tr[2], evt.x, evt.y)
                if m.test_view_mode == :results && m.test_results_pane !== nothing
                    handled = handle_mouse!(m.test_results_pane, evt)
                    if !handled
                        _handle_tree_click!(m, evt)
                    end
                elseif m.test_output_pane !== nothing
                    handle_mouse!(m.test_output_pane, evt)
                end
            end
        end
        $TAB_CONFIG => begin
            handle_resize!(m.config_layout, evt)
            handle_resize!(m.config_left_layout, evt)
            handle_resize!(m.config_right_layout, evt)
        end
        $TAB_DEBUG => begin
            handle_resize!(m.debug_layout, evt)
            m.debug_locals_pane !== nothing && handle_mouse!(m.debug_locals_pane, evt)
            m.debug_console_pane !== nothing && handle_mouse!(m.debug_console_pane, evt)
        end
        $TAB_EXTENSIONS => begin
            if m.ext_detail_open && m.ext_detail_pane !== nothing
                handle_mouse!(m.ext_detail_pane, evt)
            else
                handle_resize!(m.extensions_layout, evt)
                # Route mouse to side detail ScrollPane
                _er = m.extensions_layout.rects
                if m.ext_detail_side_pane !== nothing &&
                   length(_er) >= 2 && Base.contains(_er[2], evt.x, evt.y)
                    handle_mouse!(m.ext_detail_side_pane, evt)
                end
            end
        end
        $TAB_ADVANCED => begin
            handle_resize!(m.advanced_layout, evt)
            if Base.contains(m._stress_horde_area, evt.x, evt.y)
                if evt.button == mouse_scroll_up
                    m.stress_horde_scroll = max(0, m.stress_horde_scroll - 1)
                elseif evt.button == mouse_scroll_down
                    m.stress_horde_scroll += 1
                end
            end
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
            m.search_collections = sort(h.collections)
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
    elseif evt.id == :session_pong
        # Health check pong arrived — trigger ECG blip for this session
        info = evt.value
        key = info.session_id[1:min(8, length(info.session_id))]
        ecg = _get_ecg!(m, key)
        ecg.pending_blips += 1
    end
end

function Tachikoma.update!(m::KaimonModel, evt::KeyEvent)
    # Ignore input while shutting down
    m.shutting_down && return

    # Session terminal captures all input except Escape
    if m.session_terminal_open && m.session_terminal !== nothing && m.tab_bar.active == TAB_SESSIONS
        if evt.key == :escape
            _close_session_terminal!(m)
            return
        end
        handle_key!(m.session_terminal, evt)
        return
    end

    # Backtrace viewer overlay (ScrollPane with trace results)
    if m.backtrace_viewer !== nothing
        if evt.key == :escape
            m.backtrace_viewer = nothing
            m.backtrace_result = nothing
            return
        elseif evt.key == :char && evt.char == 's'
            _save_backtrace!(m)
            return
        else
            handle_key!(m.backtrace_viewer, evt)
            return
        end
    end

    # Backtrace modal (collecting spinner or timeout message)
    if m.backtrace_modal !== nothing
        result = if evt isa MouseEvent
            handle_mouse!(m.backtrace_modal, evt)
        else
            handle_key!(m.backtrace_modal, evt)
        end
        if result == :cancel || result == :confirm || evt.key == :escape
            m.backtrace_modal = nothing
            m.backtrace_collecting = false
        end
        return
    end

    # Quit confirmation modal captures all input
    if m.quit_confirm && m.quit_confirm_modal !== nothing
        result = if evt isa MouseEvent
            handle_mouse!(m.quit_confirm_modal, evt)
        else
            # y/n shortcuts
            if evt.key == :char && evt.char == 'y'
                :confirm
            elseif evt.key == :char && (evt.char == 'n' || evt.char == 'q')
                :cancel
            else
                handle_key!(m.quit_confirm_modal, evt)
            end
        end
        if result == :confirm
            m.quit_confirm = false
            m.quit_confirm_modal = nothing
            m.shutting_down = true
        elseif result == :cancel
            m.quit_confirm = false
            m.quit_confirm_modal = nothing
        end
        return
    end

    # When a modal flow is active, route all input there
    if m.config_flow != FLOW_IDLE
        evt.key == :escape && (m.config_flow = FLOW_IDLE; return)
        handle_flow_input!(m, evt)
        return
    end

    # When an extension TUI panel is open, capture all input
    if m.tab_bar.active == TAB_EXTENSIONS && m.ext_panel !== nothing
        if evt.key == :escape
            close_ext_panel!(m)
        else
            _ext_panel_handle_key!(m.ext_panel, evt)
        end
        return
    end

    # When an extension flow is active, route all input there
    if m.tab_bar.active == TAB_EXTENSIONS && m.ext_flow != :idle
        evt.key == :escape && (m.ext_flow = :idle; return)
        _handle_ext_flow_input!(m, evt)
        return
    end

    # When a debug consent modal is open, capture all input
    if m.debug_agent_continue_pending
        Base.invokelatest(_handle_debug_consent_key!, m, evt)
        return
    end

    # When a stress modal is open, capture all input
    if m.tab_bar.active == TAB_ADVANCED && m.stress_modal != :none
        _handle_stress_modal_key!(m, evt)
        return
    end

    # When a stress test form field is in edit mode, capture all input
    if m.tab_bar.active == TAB_ADVANCED && m.stress_editing
        _handle_stress_field_edit!(m, evt)
        return
    end

    # When activity filter popup is open, capture all input
    if m.tab_bar.active == TAB_ACTIVITY && m.activity_filter_open
        _handle_activity_filter_key!(m, evt)
        return
    end

    # When collection picker popup is open, capture all input
    if m.tab_bar.active == TAB_SEARCH && m.search_collection_picker_open
        _handle_collection_picker_key!(m, evt)
        return
    end

    # When search config panel is open, capture all input
    if m.tab_bar.active == TAB_SEARCH && m.search_config_open
        _handle_search_config_key!(m, evt)
        return
    end

    # When collection manager modal is open, capture all input
    if m.tab_bar.active == TAB_SEARCH && m.search_manage_open
        _handle_search_manage_key!(m, evt)
        return
    end

    # When collection detail overlay is open, any key closes it
    if m.tab_bar.active == TAB_SEARCH && m.search_detail_open
        m.search_detail_open = false
        return
    end

    # When test session picker is open, route all input there
    if m.tab_bar.active == TAB_TESTS && m.test_session_picker_open
        _handle_test_picker_key!(m, evt)
        return
    end

    # When search query is being edited, capture all input
    if m.tab_bar.active == TAB_SEARCH && m.search_query_editing
        _handle_search_query_edit!(m, evt)
        return
    end

    # When debug input is being edited, capture all input
    if m.tab_bar.active == TAB_DEBUG && m.debug_input_editing
        Base.invokelatest(_handle_debug_input_edit!, m, evt)
        return
    end

    tab = m.tab_bar.active

    # ── Global keys (handled before per-tab dispatch) ──
    @match (evt.key, evt.char) begin
        # Quit (skip when debug console is active — let it type)
        (:char, 'q') => begin
            if m.tab_bar.active == TAB_DEBUG && m.debug_state == :paused && get(m.focused_pane, TAB_DEBUG, 1) == 2
                # Fall through to per-tab dispatch
            else
                m.quit_confirm = true; return
            end
        end

        # Ctrl-C: quit confirmation
        (:ctrl_c, _) => (m.quit_confirm = true; return)

        # Ctrl-U: Revise reload
        (:ctrl, 'u') => (_revise_reload!(m); return)

        # Tab switching: number keys
        (:char, c) where {'1' <= c <= '9'} => begin
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
                $TAB_DEBUG => begin
                    if m.debug_input_editing
                        m.debug_input_editing = false
                    else
                        m.quit_confirm = true
                    end
                    return
                end
                $TAB_TESTS => (_handle_tests_escape!(m); return)
                $TAB_EXTENSIONS => begin
                    if m.ext_panel !== nothing
                        close_ext_panel!(m)
                    elseif m.ext_flow != :idle
                        m.ext_flow = :idle
                    elseif m.ext_detail_open
                        m.ext_detail_open = false
                        m.ext_detail_pane = nothing
                    else
                        m.quit_confirm = true
                    end
                    return
                end
                $TAB_ADVANCED => begin
                    if m.stress_modal != :none
                        m.stress_modal = :none
                    elseif m.stress_state == STRESS_RUNNING
                        _cancel_stress_test!(m)
                    else
                        m.quit_confirm = true
                    end
                    return
                end
                $TAB_SEARCH => begin
                    if m.search_query_editing
                        m.search_query_editing = false
                    else
                        m.quit_confirm = true
                    end
                    return
                end
                _ => (m.quit_confirm = true)
            end
            return
        end

        _ => nothing  # fall through to per-tab char handling
    end

    # ── Per-tab char key actions ──
    evt.key == :char || return

    @match tab begin
        $TAB_SERVER => @match evt.char begin
            'w' => (m.log_word_wrap = !m.log_word_wrap; _rebuild_log_pane!(m, m._log_pane_width))
            'F' => (
                m.log_pane !== nothing && (m.log_pane.following = !m.log_pane.following)
            )
            _ => nothing
        end

        $TAB_SESSIONS => @match evt.char begin
            'x' => _shutdown_selected_session!(m)
            't' => begin
                conns = _visible_connections(m)
                if m.selected_connection >= 1 && m.selected_connection <= length(conns)
                    conn = conns[m.selected_connection]
                    if conn.status in (:connected, :evaluating, :stalled)
                        m.backtrace_collecting = true
                        m.backtrace_result = nothing
                        m.backtrace_conn_name = conn.name
                        m.backtrace_modal = Modal(
                            title = "Profile Trace",
                            message = "Collecting profile trace\nfor $(conn.name)...",
                            confirm_label = "Cancel",
                            cancel_label = "",
                            selected = :confirm,
                        )
                        Threads.@spawn begin
                            try
                                name = conn.name
                                bt = trigger_backtrace(conn)
                                m.backtrace_collecting = false
                                if bt !== nothing
                                    m.backtrace_result = bt
                                    m.backtrace_modal = nothing
                                    sp = ScrollPane(Vector{Span}[]; following = false)
                                    sp.block = Block(
                                        title = "Profile Trace — $name  [s] save  [Esc] close",
                                        border_style = tstyle(:accent),
                                        title_style = tstyle(:accent, bold = true),
                                    )
                                    for line in split(bt, '\n')
                                        push_line!(sp, [Span(line, tstyle(:text))])
                                    end
                                    m.backtrace_viewer = sp
                                else
                                    m.backtrace_modal = Modal(
                                        title = "Profile Trace",
                                        message = "Timed out — no trace received.",
                                        confirm_label = "OK",
                                        cancel_label = "",
                                        selected = :confirm,
                                    )
                                end
                            catch e
                                _push_log!(:warn, "Profile trace error: $(sprint(showerror, e))")
                                m.backtrace_collecting = false
                                m.backtrace_modal = Modal(
                                    title = "Profile Trace",
                                    message = "Error: $(sprint(showerror, e))",
                                    confirm_label = "OK",
                                    cancel_label = "",
                                    selected = :confirm,
                                )
                            end
                        end
                    end
                end
            end
            _ => nothing
        end

        $TAB_ACTIVITY => @match evt.char begin
            'f' => (m.activity_mode == :live && _open_activity_filter!(m))
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

        $TAB_SEARCH => _handle_search_key!(m, evt)
        $TAB_TESTS => _handle_tests_key!(m, evt)

        $TAB_CONFIG => @match evt.char begin
            'i' => begin_client_config!(m)
            'g' => begin_global_gate!(m)
            'm' => toggle_gate_mirror_repl!(m)
            'p' => begin_project_add!(m)
            'D' => begin_project_remove!(m)
            'e' => begin_project_edit_launch!(m)
            'E' => cycle_editor!(m)
            'Q' => _cycle_qdrant_prefix!(m)
            'T' => begin_tcp_gate_add!(m)
            'X' => _remove_tcp_gate!(m)
            'v' => _install_vscode_remote_control!(m)
            _ => nothing
        end

        $TAB_DEBUG => Base.invokelatest(_handle_debug_key!, m, evt)
        $TAB_EXTENSIONS => _handle_extensions_key!(m, evt)
        $TAB_ADVANCED => _handle_stress_key!(m, evt)
        _ => nothing
    end
end

function _handle_nav!(m::KaimonModel, evt::KeyEvent)
    tab = m.tab_bar.active
    fp = get(m.focused_pane, tab, 1)

    @match (tab, fp) begin
        ($TAB_SERVER, 2) => (m.log_pane !== nothing && handle_key!(m.log_pane, evt))

        ($TAB_SESSIONS, 1) => begin
            dt = m.sessions_table
            if dt !== nothing
                prev = dt.selected
                if evt.key == :enter
                    # Open PTY terminal for agent-spawned sessions (skip stalled)
                    conns = _visible_connections(m)
                    if m.selected_connection >= 1 && m.selected_connection <= length(conns)
                        conn = conns[m.selected_connection]
                        if conn.spawned_by == "agent" && conn.status != :stalled
                            ms = find_managed_session(conn.project_path)
                            ms !== nothing && _open_session_terminal!(m, ms)
                        end
                    end
                else
                    handle_key!(dt, evt)
                    if dt.selected != prev && dt.selected > 0
                        m.selected_connection = dt.selected
                        m.sessions_detail_scroll = 0
                    end
                end
            end
        end

        ($TAB_SESSIONS, 3) => @match evt.key begin
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

        ($TAB_ACTIVITY, _) => begin
            m.activity_mode == :analytics && return
            if fp == 1
                dt = m.activity_table
                if dt !== nothing
                    prev = dt.selected
                    handle_key!(dt, evt)
                    if dt.selected != prev
                        m.activity_follow = false
                        _select_activity_by_display_index!(m, dt.selected)
                    end
                end
            elseif fp == 2
                m.detail_paragraph !== nothing && handle_key!(m.detail_paragraph, evt)
            end
        end

        ($TAB_SEARCH, 1) => @match evt.key begin
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
            :enter => begin
                if !isempty(m.search_collections)
                    m.search_collection_delete_confirm = false
                    m.search_collection_picker_open = true
                end
            end
            _ => nothing
        end
        ($TAB_SEARCH, 2) => @match evt.key begin
            :enter => begin
                m.search_query_editing = true
                if m.search_query_input === nothing
                    m.search_query_input =
                        TextInput(text = "", label = "Query: ", tick = m.tick)
                end
            end
            _ => nothing
        end
        ($TAB_SEARCH, 3) =>
            (m.search_results_pane !== nothing && handle_key!(m.search_results_pane, evt))

        ($TAB_TESTS, 1) => begin
            n = length(m.test_runs)
            n > 0 || return
            dt = m.tests_table
            if dt !== nothing
                prev = dt.selected
                handle_key!(dt, evt)
                if dt.selected != prev
                    m.test_follow = false
                    # DataTable shows newest first (reversed), convert back to runs index
                    m.selected_test_run = n - dt.selected + 1
                    _reset_test_panes!(m)
                end
            end
        end
        ($TAB_TESTS, 2) => begin
            if m.test_view_mode == :results
                _handle_tree_nav_key!(m, evt)
            elseif m.test_output_pane !== nothing
                handle_key!(m.test_output_pane, evt)
            end
        end

        ($TAB_DEBUG, 1) =>
            (m.debug_locals_pane !== nothing && handle_key!(m.debug_locals_pane, evt))
        ($TAB_DEBUG, 2) => begin
            if m.debug_input_editing && m.debug_input !== nothing
                handle_key!(m.debug_input, evt)
            elseif m.debug_console_pane !== nothing
                handle_key!(m.debug_console_pane, evt)
            end
        end

        ($TAB_EXTENSIONS, _) => _handle_extensions_nav!(m, evt, fp)

        (9, 1) => @match evt.key begin
            :up => (m.stress_field_idx = max(1, m.stress_field_idx - 1))
            :down => (m.stress_field_idx = min(8, m.stress_field_idx + 1))
            :enter => _handle_stress_enter!(m)
            # PageUp/PageDown scroll the horde/log without leaving the form
            :pageup => (m.stress_horde_scroll = max(0, m.stress_horde_scroll - 5))
            :pagedown => (m.stress_horde_scroll += 5)
            _ => nothing
        end
        (9, 2) => begin
            step = evt.key in (:pageup, :pagedown) ? 5 : 1
            @match evt.key begin
                :up || :pageup =>
                    (m.stress_horde_scroll = max(0, m.stress_horde_scroll - step))
                :down || :pagedown => (m.stress_horde_scroll += step)
                _ => nothing
            end
        end
        (9, 3) =>
            (m.stress_scroll_pane !== nothing && handle_key!(m.stress_scroll_pane, evt))

        (6, 4) => @match evt.key begin
            :up => (m.selected_project = max(1, m.selected_project - 1))
            :down => begin
                n = length(m.project_entries)
                n > 0 && (m.selected_project = min(n, m.selected_project + 1))
            end
            _ => nothing
        end

        (6, 5) => @match evt.key begin
            :up => (m.selected_tcp_gate = max(1, m.selected_tcp_gate - 1))
            :down => begin
                n = length(m.tcp_gate_entries)
                n > 0 && (m.selected_tcp_gate = min(n, m.selected_tcp_gate + 1))
            end
            _ => nothing
        end

        _ => nothing
    end
end

"""Count visible (non-extension) sessions for nav bounds checking."""
function _visible_session_count(m::KaimonModel)
    m.conn_mgr === nothing && return 0
    conns = lock(m.conn_mgr.lock) do
        copy(m.conn_mgr.connections)
    end
    ext_namespaces = Set(
        ext.config.manifest.namespace for ext in get_managed_extensions()
    )
    return count(c -> c.spawned_by != "extension" && !(c.namespace in ext_namespaces), conns)
end

"""Reset test output panes and tree view (used on run selection change)."""
function _reset_test_panes!(m::KaimonModel)
    m._test_output_synced = 0
    m.test_output_pane = nothing
    m.test_results_pane = nothing
    m._test_tree_root = nothing
    m._test_tree_flat = Any[]
    m._test_tree_selected = 1
    m._test_tree_synced = 0
end

"""Navigate the activity tool call list (in-flight + completed, filtered)."""

function _handle_activity_mouse!(m::KaimonModel, evt::MouseEvent)
    dt = m.activity_table
    dt === nothing && return

    # Scroll wheel: move selection (not viewport) so detail pane updates
    is_scroll = evt.button in (mouse_scroll_up, mouse_scroll_down) && evt.action == mouse_press
    if is_scroll
        n = sum(length(c.values) for c in dt.columns; init=0) ÷ max(1, length(dt.columns))
        n == 0 && return
        m.activity_follow = false
        step = evt.button == mouse_scroll_up ? -3 : 3
        new_sel = clamp(dt.selected + step, 1, n)
        if new_sel != dt.selected
            dt.selected = new_sel
            # Keep selection visible
            vis_h = max(1, dt.last_content_area.height - 1)
            if dt.selected < dt.offset + 1
                dt.offset = max(0, dt.selected - 1)
            elseif dt.selected > dt.offset + vis_h
                dt.offset = dt.selected - vis_h
            end
            _select_activity_by_display_index!(m, new_sel)
            m.focused_pane[3] = 1
        end
        return
    end

    # Click/drag: delegate to DataTable (handles col resize + row selection)
    prev_sel = dt.selected
    handle_mouse!(dt, evt)
    if dt.selected != prev_sel
        m.activity_follow = false
        _select_activity_by_display_index!(m, dt.selected)
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
    m.tab_bar.active = tab
    # Trigger async refresh when entering certain tabs
    if tab == TAB_SEARCH
        _refresh_search_health_async!(m)
    elseif tab == TAB_CONFIG
        _refresh_client_status_async!(m)
    end
end


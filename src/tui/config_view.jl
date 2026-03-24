# ── Config Tab ────────────────────────────────────────────────────────────────

function view_config(m::KaimonModel, area::Rect, buf::Buffer)
    view_config_base(m, area, buf)
    if m.config_flow != FLOW_IDLE
        view_config_flow(m, area, buf)
    end
end

function view_config_base(m::KaimonModel, area::Rect, buf::Buffer)
    cols = split_layout(m.config_layout, area)
    length(cols) < 2 && return
    render_resize_handles!(buf, m.config_layout)

    # ── Left column: Server + Actions ──
    left_rows = split_layout(m.config_left_layout, cols[1])
    length(left_rows) < 2 && return
    render_resize_handles!(buf, m.config_left_layout)

    # Server info
    srv_block = Block(
        title = "Server",
        border_style = _pane_border(m, 6, 1),
        title_style = _pane_title(m, 6, 1),
    )
    srv = render(srv_block, left_rows[1], buf)
    if srv.width >= 4
        y = srv.y
        x = srv.x + 1
        n_conns = 0
        n_exts = 0
        if m.conn_mgr !== nothing
            for c in connected_sessions(m.conn_mgr)
                if c.spawned_by == "extension"
                    n_exts += 1
                else
                    n_conns += 1
                end
            end
        end
        status_icon = m.server_running ? "●" : "○"
        status_style = m.server_running ? tstyle(:success) : tstyle(:error)
        srx = right(srv)
        set_string!(buf, x, y, "$status_icon ", status_style; max_x=srx)
        set_string!(buf, x + 2, y, "Port $(m.server_port)", tstyle(:text); max_x=srx)
        status_text = m.server_running ? "running" : "stopped"
        status_x = x + 2 + length("Port $(m.server_port)") + 2
        if status_x + length(status_text) <= srx
            set_string!(buf, status_x, y, status_text, status_style; max_x=srx)
        end
        y += 1
        set_string!(buf, x, y, rpad("Sessions", 14), tstyle(:text_dim); max_x=srx)
        session_str = "$n_conns connected"
        n_exts > 0 && (session_str *= " · $n_exts ext")
        set_string!(buf, x + 14, y, session_str, tstyle(:text); max_x=srx)
        y += 1
        set_string!(buf, x, y, rpad("Tool Calls", 14), tstyle(:text_dim); max_x=srx)
        set_string!(buf, x + 14, y, string(m.total_tool_calls), tstyle(:text); max_x=srx)
        y += 1
        set_string!(buf, x, y, rpad("Uptime", 14), tstyle(:text_dim); max_x=srx)
        uptime_s = round(Int, (time() - m.start_time))
        uptime_str = if uptime_s < 60
            "$(uptime_s)s"
        elseif uptime_s < 3600
            "$(uptime_s ÷ 60)m $(uptime_s % 60)s"
        else
            h = uptime_s ÷ 3600
            mins = (uptime_s % 3600) ÷ 60
            "$(h)h $(mins)m"
        end
        set_string!(buf, x + 14, y, uptime_str, tstyle(:text); max_x=srx)
    end

    # Actions
    act_block = Block(
        title = "Actions",
        border_style = _pane_border(m, 6, 2),
        title_style = _pane_title(m, 6, 2),
    )
    act = render(act_block, left_rows[2], buf)
    m._config_actions_area = act
    if act.width >= 4
        y = act.y
        x = act.x + 1
        arx = right(act)
        # Row 0: [g] Global gate
        set_string!(buf, x, y, "[g]", tstyle(:accent, bold = true); max_x=arx)
        set_string!(buf, x + 4, y, "Global gate (startup.jl)", tstyle(:text); max_x=arx)
        y += 1
        # Row 1: [i] Install MCP
        set_string!(buf, x, y, "[i]", tstyle(:accent, bold = true); max_x=arx)
        set_string!(buf, x + 4, y, "Install MCP client config", tstyle(:text); max_x=arx)
        y += 1
        # Row 2: [m] Mirror
        set_string!(buf, x, y, "[m]", tstyle(:accent, bold = true); max_x=arx)
        set_string!(buf, x + 4, y, "Mirror host REPL output", tstyle(:text); max_x=arx)
        y += 1
        mirror_status = m.gate_mirror_repl ? "enabled" : "disabled"
        mirror_style = m.gate_mirror_repl ? tstyle(:success) : tstyle(:text_dim)
        set_string!(buf, x + 4, y, "status: $mirror_status", mirror_style; max_x=arx)
        y += 1
        # Row 4: [E] Editor
        set_string!(buf, x, y, "[E]", tstyle(:accent, bold = true); max_x=arx)
        set_string!(buf, x + 4, y, "Editor for file links", tstyle(:text); max_x=arx)
        y += 1
        set_string!(buf, x + 4, y, "current: $(m.editor)", tstyle(:success); max_x=arx)
        y += 1
        # Row 6: [Q] Qdrant prefix
        set_string!(buf, x, y, "[Q]", tstyle(:accent, bold = true); max_x=arx)
        set_string!(buf, x + 4, y, "Qdrant collection prefix", tstyle(:text); max_x=arx)
        y += 1
        prefix = get_collection_prefix()
        if isempty(prefix)
            set_string!(buf, x + 4, y, "none (default)", tstyle(:text_dim); max_x=arx)
        else
            set_string!(buf, x + 4, y, "prefix: $prefix", tstyle(:success); max_x=arx)
        end
        y += 1
        # Row 8: [v] VSCode
        set_string!(buf, x, y, "[v]", tstyle(:accent, bold = true); max_x=arx)
        set_string!(buf, x + 4, y, "VSCode Remote Control ext", tstyle(:text); max_x=arx)
    end

    # ── Right column: MCP Clients (top) + Projects & TCP Gates side-by-side (bottom) ──
    right_rows = split_layout(m.config_right_layout, cols[2])
    length(right_rows) < 2 && return
    render_resize_handles!(buf, m.config_right_layout)
    # Split bottom row into two columns for Projects and TCP Gates
    bottom_cols = tsplit(Layout(Horizontal, [Percent(55), Fill()]), right_rows[2])

    # ── MCP Client Status ──
    client_block = Block(
        title = "MCP Clients",
        border_style = _pane_border(m, 6, 3),
        title_style = _pane_title(m, 6, 3),
    )
    client_inner = render(client_block, right_rows[1], buf)
    if client_inner.width >= 4
        y = client_inner.y
        x = client_inner.x + 1
        max_x = right(client_inner)

        for (label, configured) in m.client_statuses
            y > bottom(client_inner) - 2 && break
            icon = configured ? "●" : "○"
            icon_style = configured ? tstyle(:success) : tstyle(:text_dim)
            name_style = configured ? tstyle(:text) : tstyle(:text_dim)
            status_text = configured ? "configured" : "—"
            set_string!(buf, x, y, "$icon ", icon_style)
            set_string!(buf, x + 2, y, label, name_style)
            # Right-align status
            status_x = max_x - length(status_text)
            if status_x > x + 2 + length(label) + 1
                set_string!(buf, status_x, y, status_text, icon_style)
            end
            y += 1
        end

        hint_y = bottom(client_inner)
        if hint_y > client_inner.y
            set_string!(buf, x, hint_y, "[i] configure a client", tstyle(:text_dim))
        end
    end

    # ── Allowed Projects ──
    n_projects = length(m.project_entries)
    managed = get_managed_sessions()
    proj_block = Block(
        title = "Allowed Projects ($n_projects)",
        border_style = _pane_border(m, 6, 4),
        title_style = _pane_title(m, 6, 4),
    )
    proj_inner = render(proj_block, bottom_cols[1], buf)
    if proj_inner.width >= 4
        y = proj_inner.y
        x = proj_inner.x + 1

        if isempty(m.project_entries)
            set_string!(buf, x, y, "No projects configured", tstyle(:text_dim))
            y += 1
            set_string!(buf, x, y, "Press [p] to add a project", tstyle(:text_dim))
        else
            for (i, entry) in enumerate(m.project_entries)
                y > bottom(proj_inner) - 2 && break
                # Check if a session is running for this project
                running = any(ms -> begin
                    normalize_path(ms.project_path) == normalize_path(entry.project_path) && ms.status == :running
                end, managed)

                marker = i == m.selected_project ? "▸ " : "  "
                icon = entry.enabled ? (running ? "⚡" : "●") : "○"
                icon_style = running ? tstyle(:accent) : entry.enabled ? tstyle(:success) : tstyle(:text_dim)
                name_style = i == m.selected_project ? tstyle(:accent, bold = true) : tstyle(:text)
                status_text = running ? "running" : entry.enabled ? "enabled" : "disabled"

                rx = right(proj_inner)
                set_string!(buf, x, y, marker, name_style; max_x=rx)
                set_string!(buf, x + 2, y, "$icon ", icon_style; max_x=rx)
                set_string!(buf, x + 4, y, _short_path(entry.project_path), name_style; max_x=rx)
                # Show launch config summary after name
                lc_summary = launch_config_summary(entry.launch_config)
                if !isempty(lc_summary)
                    name_len = length(_short_path(entry.project_path))
                    lc_x = x + 4 + name_len + 1
                    max_lc_w = rx - length(status_text) - lc_x - 2
                    if max_lc_w > 4
                        display_lc = length(lc_summary) > max_lc_w ? lc_summary[1:max_lc_w-1] * "…" : lc_summary
                        set_string!(buf, lc_x, y, display_lc, tstyle(:text_dim); max_x=rx)
                    end
                end
                # Show status at the right edge
                status_x = rx - length(status_text)
                if status_x > x + 20
                    set_string!(buf, status_x, y, status_text, icon_style; max_x=rx)
                end
                y += 1
            end
        end

        y = bottom(proj_inner)
        if y >= proj_inner.y + 1
            set_string!(buf, x, y, "[p] Add  [D] Remove  [e] Launch Config", tstyle(:text_dim);
                max_x=right(proj_inner))
        end
    end

    # ── TCP Gates ──
    n_tcp = length(m.tcp_gate_entries)
    tcp_block = Block(
        title = "TCP Gates ($n_tcp)",
        border_style = _pane_border(m, 6, 5),
        title_style = _pane_title(m, 6, 5),
    )
    tcp_inner = render(tcp_block, bottom_cols[2], buf)
    if tcp_inner.width >= 4
        y = tcp_inner.y
        x = tcp_inner.x + 1

        if isempty(m.tcp_gate_entries)
            set_string!(buf, x, y, "No TCP gates registered", tstyle(:text_dim))
            y += 1
            set_string!(buf, x, y, "Press [T] to add one", tstyle(:text_dim))
        else
            for (i, entry) in enumerate(m.tcp_gate_entries)
                y > bottom(tcp_inner) - 2 && break
                # Check if connected
                sid = "tcp-$(entry.host)-$(entry.port)"
                connected = m.conn_mgr !== nothing && any(
                    c -> c.session_id == sid && c.status in (:connected, :evaluating),
                    connected_sessions(m.conn_mgr),
                )
                marker = i == m.selected_tcp_gate ? "▸ " : "  "
                icon = entry.enabled ? (connected ? "⬤" : "○") : "○"
                icon_style = connected ? tstyle(:success) : entry.enabled ? tstyle(:warning) : tstyle(:text_dim)
                name_style = i == m.selected_tcp_gate ? tstyle(:accent, bold = true) : tstyle(:text)

                label = isempty(entry.name) ? "$(entry.host):$(entry.port)" : entry.name
                status_text = if connected
                    "connected"
                elseif !entry.enabled
                    "disabled"
                else
                    backoff_key = "$(entry.host):$(entry.port)"
                    bstate = get(_TCP_POLL_BACKOFF, backoff_key, nothing)
                    if bstate !== nothing && bstate.next_try > time()
                        secs = round(Int, bstate.next_try - time())
                        "retry $(secs)s"
                    else
                        "waiting"
                    end
                end

                trx = right(tcp_inner)
                set_string!(buf, x, y, marker, name_style; max_x=trx)
                set_string!(buf, x + 2, y, "$icon ", icon_style; max_x=trx)
                set_string!(buf, x + 4, y, label, name_style; max_x=trx)
                # Host:port after name if name is set
                if !isempty(entry.name)
                    addr = "$(entry.host):$(entry.port)"
                    addr_x = x + 4 + length(label) + 1
                    if addr_x + length(addr) < trx - length(status_text) - 2
                        set_string!(buf, addr_x, y, addr, tstyle(:text_dim); max_x=trx)
                    end
                end
                status_x = trx - length(status_text)
                if status_x > x + 20
                    set_string!(buf, status_x, y, status_text, icon_style; max_x=trx)
                end
                y += 1
            end
        end

        y = bottom(tcp_inner)
        if y >= tcp_inner.y + 1
            set_string!(buf, x, y, "[T] Add  [X] Remove  [v] VSCode ext", tstyle(:text_dim);
                max_x=right(tcp_inner))
        end
    end
end

# ── Config Flow Overlay ──────────────────────────────────────────────────────

function view_config_flow(m::KaimonModel, area::Rect, buf::Buffer)
    flow = m.config_flow

    # Dim background
    _dim_area!(buf, area)

    if flow == FLOW_CLIENT_SELECT
        _render_selection_modal(
            buf,
            area,
            "Select Client",
            CLIENT_LABELS,
            m.flow_selected,
            "[↑↓] select  [Enter] confirm  [Esc] cancel";
            tick = m.tick,
        )

    elseif flow == FLOW_CLIENT_CONFIRM
        client_label = get(CLIENT_LABEL, m.client_target, string(m.client_target))
        # Check if already configured
        configured = any(p -> p.first == client_label && p.second, m.client_statuses)
        status_text = configured ? "● configured" : "○ not configured"
        status_style = configured ? tstyle(:success) : tstyle(:text_dim)

        w = min(44, area.width - 4)
        h = 8
        rect = center(area, w, h)
        border_s = tstyle(:accent, bold = true)
        inner = if animations_enabled()
            border_shimmer!(buf, rect, border_s.fg, m.tick; box = BOX_HEAVY, intensity = 0.12)
            if rect.width > 4
                set_string!(buf, rect.x + 2, rect.y, " $client_label ", border_s)
            end
            Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
        else
            render(
                Block(
                    title = "$client_label",
                    border_style = border_s,
                    title_style = border_s,
                    box = BOX_HEAVY,
                ),
                rect,
                buf,
            )
        end
        if inner.width >= 4
            for row = inner.y:bottom(inner)
                for col = inner.x:right(inner)
                    set_char!(buf, col, row, ' ', Style(bg=Tachikoma.theme().bg))
                end
            end
            y = inner.y
            x = inner.x + 1
            set_string!(buf, x, y, "Status: ", tstyle(:text_dim))
            set_string!(buf, x + 8, y, status_text, status_style)
            y += 1
            if m.client_target == :startup_jl
                set_string!(buf, x, y, "Installs: ~/.julia/config/startup.jl", tstyle(:text_dim))
            elseif m.client_target in (:claude, :gemini)
                set_string!(buf, x, y, "Scope: user (global)", tstyle(:text_dim))
            else
                set_string!(buf, x, y, "Scope: user-level (global)", tstyle(:text_dim))
            end
            y += 2
            set_string!(
                buf,
                x,
                y,
                configured ? "[Enter] Update" : "[Enter] Install",
                tstyle(:accent),
            )
            if configured
                set_string!(buf, x + 24, y, "[r] Remove", tstyle(:error))
            end
            y += 1
            set_string!(buf, x, y, "[Esc] Cancel", tstyle(:text_dim))
        end

    elseif flow == FLOW_CLIENT_RESULT
        _render_result_modal(buf, area, m.flow_success, m.flow_message; tick = m.tick)

    elseif flow == FLOW_PROJECT_ADD_PATH
        if m.project_path_input !== nothing
            m.project_path_input.tick = m.tick
        end
        _render_text_input_modal(
            buf,
            area,
            "Add Allowed Project",
            "Enter project path:",
            m.project_path_input,
            "[Enter] confirm  [Tab] complete  [Esc] cancel";
            tick = m.tick,
        )

    elseif flow == FLOW_PROJECT_ADD_CONFIRM
        msg = "Allow agents to spawn sessions for this project?\n\nPath: $(_short_path(m.onboard_path))"
        render(
            Modal(
                title = "Confirm",
                message = msg,
                confirm_label = "Add",
                cancel_label = "Cancel",
                selected = m.flow_modal_selected,
                tick = m.tick,
            ),
            area,
            buf,
        )

    elseif flow == FLOW_PROJECT_ADD_RESULT
        _render_result_modal(buf, area, m.flow_success, m.flow_message; tick = m.tick)

    elseif flow == FLOW_PROJECT_REMOVE_CONFIRM
        entry = if m.selected_project >= 1 && m.selected_project <= length(m.project_entries)
            m.project_entries[m.selected_project]
        else
            nothing
        end
        path_str = entry !== nothing ? _short_path(entry.project_path) : "?"
        msg = "Remove project from allowed list?\n\nPath: $path_str"
        render(
            Modal(
                title = "Confirm Remove",
                message = msg,
                confirm_label = "Remove",
                cancel_label = "Cancel",
                selected = m.flow_modal_selected,
                tick = m.tick,
            ),
            area,
            buf,
        )

    elseif flow == FLOW_PROJECT_REMOVE_RESULT
        _render_result_modal(buf, area, m.flow_success, m.flow_message; tick = m.tick)

    elseif flow == FLOW_PROJECT_EDIT_LAUNCH
        _render_launch_config_modal(m, buf, area)

    elseif flow == FLOW_TCP_GATE_ADD
        _render_tcp_gate_add_modal(m, buf, area)

    elseif flow == FLOW_TCP_GATE_ADD_RESULT
        _render_result_modal(buf, area, m.flow_success, m.flow_message; tick = m.tick)

    elseif flow == FLOW_QDRANT_PREFIX
        _render_qdrant_prefix_modal(m, buf, area)

    elseif flow == FLOW_QDRANT_PREFIX_RESULT
        _render_result_modal(buf, area, m.flow_success, m.flow_message; tick = m.tick)
    end
end

function _render_qdrant_prefix_modal(m::KaimonModel, buf::Buffer, area::Rect)
    w = min(50, area.width - 4)
    h = 6
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = render(
        Block(title = "Qdrant Collection Prefix", border_style = border_s, title_style = border_s, box = BOX_HEAVY),
        rect, buf,
    )
    inner.width < 4 && return

    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style(bg = Tachikoma.theme().bg))
        end
    end

    y = inner.y
    x = inner.x + 1
    set_string!(buf, x, y, "Prefix for shared Qdrant (empty = none):", tstyle(:text_dim))
    y += 1
    if m.qdrant_prefix_input !== nothing
        m.qdrant_prefix_input.tick = m.tick
        render(m.qdrant_prefix_input, Rect(x, y, inner.width - 2, 1), buf)
    end
    y += 2
    if y <= bottom(inner)
        set_string!(buf, x, y, "[Enter] save  [Esc] cancel", tstyle(:text_dim))
    end
end

function _render_launch_config_modal(m::KaimonModel, buf::Buffer, area::Rect)
    idx = m.selected_project
    proj_name = if idx >= 1 && idx <= length(m.project_entries)
        basename(m.project_entries[idx].project_path)
    else
        "?"
    end

    w = min(50, area.width - 4)
    h = 11
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    title = "Launch Config: $proj_name"
    inner = if animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, m.tick; box = BOX_HEAVY, intensity = 0.12)
        if rect.width > 4
            set_string!(buf, rect.x + 2, rect.y, " $title ", border_s)
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = title,
                border_style = border_s,
                title_style = border_s,
                box = BOX_HEAVY,
            ),
            rect,
            buf,
        )
    end
    inner.width < 4 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style(bg=Tachikoma.theme().bg))
        end
    end

    y = inner.y
    x = inner.x + 1
    label_w = 18
    input_w = max(4, inner.width - label_w - 3)

    field_labels = ["Threads (-t):", "GC threads:", "Heap size hint:", "Extra flags:"]
    field_keys = [:threads, :gcthreads, :heap_size_hint, :extra_flags]

    for (i, (label, key)) in enumerate(zip(field_labels, field_keys))
        y > bottom(inner) - 2 && break
        selected = i == m.launch_config_selected
        label_style = selected ? tstyle(:accent, bold = true) : tstyle(:text_dim)
        marker = selected ? "▸ " : "  "
        set_string!(buf, x, y, marker, label_style)
        set_string!(buf, x + 2, y, rpad(label, label_w), label_style)

        input = m.launch_config_inputs[key]
        if selected
            input.tick = m.tick
        end
        render(input, Rect(x + 2 + label_w, y, input_w, 1), buf)
        y += 1
    end

    y += 1
    if y <= bottom(inner)
        set_string!(buf, x, y, "[Enter] Save  [Esc] Cancel", tstyle(:text_dim))
    end
end

# ── Flow rendering helpers ───────────────────────────────────────────────────

function _dim_area!(buf::Buffer, area::Rect)
    for row = area.y:bottom(area)
        for col = area.x:right(area)
            set_char!(buf, col, row, ' ', tstyle(:text_dim))
        end
    end
end

function _render_text_input_modal(
    buf::Buffer,
    area::Rect,
    title::String,
    prompt::String,
    input,
    hint::String;
    tick::Union{Int,Nothing} = nothing,
)
    w = min(60, area.width - 4)
    h = 7
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = if tick !== nothing && animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, tick; box = BOX_HEAVY, intensity = 0.12)
        if !isempty(title) && rect.width > 4
            set_string!(buf, rect.x + 2, rect.y, " $title ", tstyle(:accent, bold = true))
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = title,
                border_style = border_s,
                title_style = border_s,
                box = BOX_HEAVY,
            ),
            rect,
            buf,
        )
    end
    inner.width < 4 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style(bg=Tachikoma.theme().bg))
        end
    end

    y = inner.y
    x = inner.x + 1
    set_string!(buf, x, y, prompt, tstyle(:text))
    y += 1
    y += 1  # blank line
    render(input, Rect(x, y, inner.width - 2, 1), buf)
    y += 1
    y += 1
    set_string!(buf, x, y, hint, tstyle(:text_dim))
end

function _render_selection_modal(
    buf::Buffer,
    area::Rect,
    title::String,
    options::Vector{String},
    selected::Int,
    hint::String;
    tick::Union{Int,Nothing} = nothing,
)
    w = min(50, area.width - 4)
    h = length(options) + 5
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = if tick !== nothing && animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, tick; box = BOX_HEAVY, intensity = 0.12)
        if !isempty(title) && rect.width > 4
            set_string!(buf, rect.x + 2, rect.y, " $title ", tstyle(:accent, bold = true))
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = title,
                border_style = border_s,
                title_style = border_s,
                box = BOX_HEAVY,
            ),
            rect,
            buf,
        )
    end
    inner.width < 4 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style(bg=Tachikoma.theme().bg))
        end
    end

    y = inner.y
    x = inner.x + 1
    for (i, label) in enumerate(options)
        y > bottom(inner) - 2 && break
        marker = i == selected ? "▸ " : "  "
        style = i == selected ? tstyle(:accent, bold = true) : tstyle(:text)
        set_string!(buf, x, y, marker * label, style)
        y += 1
    end
    y += 1
    if y <= bottom(inner)
        set_string!(buf, x, y, hint, tstyle(:text_dim))
    end
end

function _render_result_modal(
    buf::Buffer,
    area::Rect,
    success::Bool,
    message::String;
    tick::Union{Int,Nothing} = nothing,
)
    lines = Base.split(message, '\n')
    w = min(max(maximum(length.(lines); init = 20) + 6, 30), area.width - 4)
    h = length(lines) + 5
    rect = center(area, w, h)

    border_style = success ? tstyle(:success, bold = true) : tstyle(:error, bold = true)
    title = success ? "Success" : "Error"
    inner = if tick !== nothing && animations_enabled()
        border_shimmer!(buf, rect, border_style.fg, tick; box = BOX_HEAVY, intensity = 0.12)
        if rect.width > 4
            set_string!(buf, rect.x + 2, rect.y, " $title ", border_style)
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = title,
                border_style = border_style,
                title_style = border_style,
                box = BOX_HEAVY,
            ),
            rect,
            buf,
        )
    end
    inner.width < 4 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style(bg=Tachikoma.theme().bg))
        end
    end

    y = inner.y
    x = inner.x + 1
    text_style = success ? tstyle(:success) : tstyle(:error)
    for line in lines
        y > bottom(inner) - 2 && break
        set_string!(buf, x, y, String(line), text_style)
        y += 1
    end
    y += 1
    if y <= bottom(inner)
        set_string!(buf, x, y, "Press any key to close", tstyle(:text_dim))
    end
end

function _render_tcp_gate_add_modal(m::KaimonModel, buf::Buffer, area::Rect)
    w = min(50, area.width - 4)
    h = 10
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    title = "Add TCP Gate"
    inner = render(
        Block(title = title, border_style = border_s, title_style = border_s, box = BOX_HEAVY),
        rect, buf,
    )
    inner.width < 4 && return

    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style(bg = Tachikoma.theme().bg))
        end
    end

    y = inner.y
    x = inner.x + 1
    label_w = 12

    # Helper to render a text input field row
    function _field!(field_idx, label, input)
        y > bottom(inner) && return
        active = m._tcp_gate_field == field_idx
        set_string!(buf, x, y, rpad(label, label_w), active ? tstyle(:accent) : tstyle(:text_dim))
        if input !== nothing
            input.tick = m.tick
            input_area = Rect(x + label_w, y, inner.width - label_w - 2, 1)
            if active
                render(input, input_area, buf)
            else
                set_string!(buf, x + label_w, y, Tachikoma.text(input), tstyle(:text))
            end
        end
        y += 1
    end

    _field!(1, "Host:Port", m.tcp_gate_input)
    _field!(2, "Name", m.tcp_gate_name_input)
    _field!(3, "Token", m.tcp_gate_token_input)
    _field!(4, "Stream port", m.tcp_gate_stream_port_input)
    y += 1

    if y <= bottom(inner)
        set_string!(buf, x, y, "[Tab] switch  [Enter] add  [Esc] cancel", tstyle(:text_dim))
    end
end

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
        title = " Server ",
        border_style = _pane_border(m, 4, 1),
        title_style = _pane_title(m, 4, 1),
    )
    srv = render(srv_block, left_rows[1], buf)
    if srv.width >= 4
        y = srv.y
        x = srv.x + 1
        n_conns = m.conn_mgr !== nothing ? length(connected_sessions(m.conn_mgr)) : 0
        status_icon = m.server_running ? "●" : "○"
        status_style = m.server_running ? tstyle(:success) : tstyle(:error)
        set_string!(buf, x, y, "$status_icon ", status_style)
        set_string!(buf, x + 2, y, "Port $(m.server_port)", tstyle(:text))
        y += 1
        set_string!(buf, x, y, rpad("Status", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, m.server_running ? "running" : "stopped", status_style)
        y += 1
        set_string!(buf, x, y, rpad("Sessions", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, "$n_conns connected", tstyle(:text))
        y += 1
        set_string!(buf, x, y, rpad("Tool Calls", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, string(m.total_tool_calls), tstyle(:text))
        y += 1
        set_string!(buf, x, y, rpad("Socket Dir", 14), tstyle(:text_dim))
        set_string!(buf, x + 14, y, "~/.cache/kaimon/sock", tstyle(:text))
    end

    # Actions
    act_block = Block(
        title = " Actions ",
        border_style = _pane_border(m, 4, 2),
        title_style = _pane_title(m, 4, 2),
    )
    act = render(act_block, left_rows[2], buf)
    if act.width >= 4
        y = act.y
        x = act.x + 1
        set_string!(buf, x, y, "[o]", tstyle(:accent, bold = true))
        set_string!(buf, x + 4, y, "Onboard project (gate setup)", tstyle(:text))
        y += 1
        set_string!(buf, x, y, "[g]", tstyle(:accent, bold = true))
        set_string!(buf, x + 4, y, "Global gate (startup.jl)", tstyle(:text))
        y += 1
        set_string!(buf, x, y, "[i]", tstyle(:accent, bold = true))
        set_string!(buf, x + 4, y, "Install MCP client config", tstyle(:text))
        y += 1
        set_string!(buf, x, y, "[m]", tstyle(:accent, bold = true))
        set_string!(buf, x + 4, y, "Mirror host REPL output", tstyle(:text))
        y += 1
        mirror_status = m.gate_mirror_repl ? "enabled" : "disabled"
        mirror_style = m.gate_mirror_repl ? tstyle(:success) : tstyle(:text_dim)
        set_string!(buf, x + 4, y, "status: $mirror_status", mirror_style)
    end

    # ── Right column: MCP Client Status ──
    client_block = Block(
        title = " MCP Clients ",
        border_style = _pane_border(m, 4, 3),
        title_style = _pane_title(m, 4, 3),
    )
    client_inner = render(client_block, cols[2], buf)
    client_inner.width < 4 && return

    y = client_inner.y
    x = client_inner.x + 1

    for (label, configured) in m.client_statuses
        y > bottom(client_inner) && break
        icon = configured ? "●" : "○"
        icon_style = configured ? tstyle(:success) : tstyle(:text_dim)
        status_text = configured ? "configured" : "not configured"
        set_string!(buf, x, y, "$icon ", icon_style)
        set_string!(buf, x + 2, y, rpad(label, 16), tstyle(:text))
        set_string!(buf, x + 18, y, status_text, icon_style)
        y += 1
    end

    y += 1
    if y + 2 <= bottom(client_inner)
        set_string!(buf, x, y, "Press [i] to configure a client", tstyle(:text_dim))
    end
end

# ── Config Flow Overlay ──────────────────────────────────────────────────────

function view_config_flow(m::KaimonModel, area::Rect, buf::Buffer)
    flow = m.config_flow

    # Dim background
    _dim_area!(buf, area)

    if flow == FLOW_ONBOARD_PATH
        if m.path_input !== nothing
            m.path_input.tick = m.tick
        end
        _render_text_input_modal(
            buf,
            area,
            " Add Project ",
            "Enter project path:",
            m.path_input,
            "[Enter] confirm  [Esc] cancel";
            tick = m.tick,
        )

    elseif flow == FLOW_ONBOARD_CONFIRM
        msg = "Install gate snippet?\n\nPath: $(_short_path(m.onboard_path))\nScope: project-level"
        render(
            Modal(
                title = "Confirm Setup",
                message = msg,
                confirm_label = "Install",
                cancel_label = "Cancel",
                selected = m.flow_modal_selected,
                tick = m.tick,
            ),
            area,
            buf,
        )

    elseif flow == FLOW_ONBOARD_RESULT
        _render_result_modal(buf, area, m.flow_success, m.flow_message; tick = m.tick)

    elseif flow == FLOW_CLIENT_SELECT
        _render_selection_modal(
            buf,
            area,
            " Select Client ",
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
                    title = " $client_label ",
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
                    set_char!(buf, col, row, ' ', Style())
                end
            end
            y = inner.y
            x = inner.x + 1
            set_string!(buf, x, y, "Status: ", tstyle(:text_dim))
            set_string!(buf, x + 8, y, status_text, status_style)
            y += 1
            scope_str = if m.client_target == :startup_jl
                "Installs: ~/.julia/config/startup.jl"
            elseif m.client_target in (:claude, :gemini)
                "Scope: project-level"
            else
                "Scope: user-level (global)"
            end
            set_string!(buf, x, y, scope_str, tstyle(:text_dim))
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
            set_char!(buf, col, row, ' ', Style())
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
            set_char!(buf, col, row, ' ', Style())
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
    title = success ? " Success " : " Error "
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
            set_char!(buf, col, row, ' ', Style())
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

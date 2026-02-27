# ── Sessions Tab (REPL gates + MCP agents) ────────────────────────────────

function view_sessions(m::KaimonModel, area::Rect, buf::Buffer)
    cols = split_layout(m.sessions_layout, area)
    length(cols) < 2 && return
    render_resize_handles!(buf, m.sessions_layout)

    # ── Left column: REPL gates (top) + MCP agents (bottom) ──
    # Pull live MCP agent sessions
    agent_sessions = lock(STANDALONE_SESSIONS_LOCK) do
        collect(values(STANDALONE_SESSIONS))
    end
    filter!(s -> s.state == Session.INITIALIZED, agent_sessions)

    left_rows = split_layout(m.sessions_left_layout, cols[1])
    length(left_rows) < 2 && return
    render_resize_handles!(buf, m.sessions_left_layout)

    # ── REPL gates list ──
    connections = if m.conn_mgr !== nothing
        lock(m.conn_mgr.lock) do
            copy(m.conn_mgr.connections)
        end
    else
        REPLConnection[]
    end

    items = ListItem[]
    for conn in connections
        icon = conn.status == :connected ? "●" : conn.status == :connecting ? "◐" : "○"
        style =
            conn.status == :connected ? tstyle(:success) :
            conn.status == :connecting ? tstyle(:warning) : tstyle(:error)
        dname = isempty(conn.display_name) ? conn.name : conn.display_name
        label = "$icon $dname"
        padded = rpad(label, 20)
        status_text = string(conn.status)
        push!(items, ListItem("$padded $status_text", style))
    end

    if isempty(items)
        push!(items, ListItem("  No REPL sessions found", tstyle(:text_dim)))
        push!(items, ListItem("", tstyle(:text_dim)))
        push!(items, ListItem("  Start a gate in your REPL:", tstyle(:text_dim)))
        push!(items, ListItem("  Gate.serve()", tstyle(:accent)))
    end

    render(
        SelectableList(
            items;
            selected = m.selected_connection,
            block = Block(
                title = " REPL Sessions ($(length(connections))) ",
                border_style = _pane_border(m, 2, 1),
                title_style = _pane_title(m, 2, 1),
            ),
            highlight_style = tstyle(:accent, bold = true),
            tick = m.tick,
        ),
        left_rows[1],
        buf,
    )

    # ── MCP agents table ──
    if isempty(agent_sessions)
        agent_block = Block(
            title = " Agents ",
            border_style = _pane_border(m, 2, 2),
            title_style = _pane_title(m, 2, 2),
        )
        inner = render(agent_block, left_rows[2], buf)
        if inner.width >= 4
            set_string!(buf, inner.x + 1, inner.y, "No agents connected", tstyle(:text_dim))
        end
    else
        header = ["CLIENT", "SESSION", "ACTIVE"]
        rows = Vector{String}[]
        for s in agent_sessions
            client_name = get(s.client_info, "name", "unknown")
            push!(
                rows,
                [
                    string(client_name),
                    s.id[1:min(8, length(s.id))] * "…",
                    _time_ago(s.last_activity),
                ],
            )
        end
        render(
            Table(
                header,
                rows;
                block = Block(
                    title = " Agents ($(length(agent_sessions))) ",
                    border_style = _pane_border(m, 2, 2),
                    title_style = _pane_title(m, 2, 2),
                ),
            ),
            left_rows[2],
            buf,
        )
    end

    # ── Right: detail panel for selected gate connection ──
    scroll_indicator = m.sessions_detail_scroll > 0 ? " ↑$(m.sessions_detail_scroll) " : ""
    detail_block = Block(
        title = " Details$scroll_indicator",
        border_style = _pane_border(m, 2, 3),
        title_style = _pane_title(m, 2, 3),
    )
    detail_area = render(detail_block, cols[2], buf)
    m._sessions_detail_area = detail_area

    if !isempty(connections) && m.selected_connection <= length(connections)
        conn = connections[m.selected_connection]
        # Virtual y starts above detail_area.y by scroll amount; rows outside the
        # visible window are simply skipped by the in_view guard below.
        scroll = m.sessions_detail_scroll
        x = detail_area.x + 1
        y_virtual = detail_area.y - scroll  # may be negative when scrolled
        virtual_bottom = 0                  # track last content row for max_scroll

        in_view(yv) = detail_area.y <= yv <= bottom(detail_area)
        advance(yv) = (virtual_bottom = max(virtual_bottom, yv); yv + 1)

        dname = isempty(conn.display_name) ? conn.name : conn.display_name
        mirror_str = if !conn.allow_mirror
            "disabled"
        elseif conn.mirror_repl
            "active"
        else
            "off"
        end
        restart_str = conn.allow_restart ? "allowed" : "disabled"
        fields = [
            ("Name", dname),
            ("Status", string(conn.status)),
            ("Path", _short_path(conn.project_path)),
            ("Julia", conn.julia_version),
            ("PID", string(conn.pid)),
            ("Uptime", _time_ago(conn.connected_at)),
            ("Last seen", _time_ago(conn.last_seen)),
            ("Tool calls", string(conn.tool_call_count)),
            ("Mirroring", mirror_str),
            ("Restart", restart_str),
            ("Session", conn.session_id[1:min(8, length(conn.session_id))] * "..."),
        ]

        for (label, value) in fields
            in_view(y_virtual) && begin
                set_string!(
                    buf,
                    x,
                    y_virtual,
                    "$(rpad(label, 12))",
                    tstyle(:text_dim),
                    detail_area,
                )
                set_string!(buf, x + 13, y_virtual, value, tstyle(:text), detail_area)
            end
            y_virtual = advance(y_virtual)
        end

        # Health gauge (error-rate, per-session)
        conn_key = conn.session_id[1:min(8, length(conn.session_id))]
        y_virtual = advance(y_virtual)  # blank separator
        health, _ = _compute_health(m, conn_key)
        in_view(y_virtual) && set_string!(buf, x, y_virtual, "Health", tstyle(:text_dim))
        y_virtual = advance(y_virtual)
        if in_view(y_virtual)
            gs =
                health >= 0.7 ? tstyle(:success) :
                health >= 0.3 ? tstyle(:warning) : tstyle(:error)
            render(
                Gauge(
                    health;
                    filled_style = gs,
                    empty_style = tstyle(:text_dim),
                    tick = m.tick,
                ),
                Rect(x, y_virtual, detail_area.width - 2, 1),
                buf,
            )
        end
        y_virtual = advance(y_virtual)

        # ECG heartbeat
        ecg_h = 3
        ecg_w = detail_area.width - 2
        y_virtual = advance(y_virtual)  # blank separator
        in_view(y_virtual) && set_string!(buf, x, y_virtual, "Heartbeat", tstyle(:text_dim))
        y_virtual = advance(y_virtual)
        if ecg_w >= 10
            ecg_rect = Rect(x, y_virtual, ecg_w, ecg_h)
            # Only render when at least the first row of ECG is in view
            y_virtual <= bottom(detail_area) &&
                y_virtual + ecg_h - 1 >= detail_area.y &&
                _render_ecg_trace(m, ecg_rect, buf, conn_key)
            for _ = 1:ecg_h
                y_virtual = advance(y_virtual)
            end
        end

        # Session tools
        if !isempty(conn.session_tools)
            y_virtual = advance(y_virtual)  # blank separator
            n_tools = length(conn.session_tools)
            in_view(y_virtual) &&
                set_string!(buf, x, y_virtual, "Tools ($n_tools)", tstyle(:text_dim))
            y_virtual = advance(y_virtual)
            for tool_meta in conn.session_tools
                in_view(y_virtual) && begin
                    tname = get(tool_meta, "name", "?")
                    args = get(tool_meta, "arguments", Dict[])
                    arg_names = join([get(a, "name", "") for a in args], ", ")
                    sig = isempty(arg_names) ? tname * "()" : tname * "($arg_names)"
                    set_string!(buf, x + 1, y_virtual, sig, tstyle(:accent), detail_area)
                end
                y_virtual = advance(y_virtual)
            end
        end

        # Update max scroll: how far can we scroll before content leaves view
        visible_h = detail_area.height
        content_h = virtual_bottom - detail_area.y + scroll + 1
        m.sessions_detail_max_scroll = max(0, content_h - visible_h)
        # Clamp current scroll in case the pane resized or content shrank
        m.sessions_detail_scroll =
            min(m.sessions_detail_scroll, m.sessions_detail_max_scroll)
    else
        set_string!(
            buf,
            detail_area.x + 1,
            detail_area.y,
            "Select a session",
            tstyle(:text_dim),
        )
        m.sessions_detail_scroll = 0
        m.sessions_detail_max_scroll = 0
    end
end

const _QRS_WAVEFORM = Float64[
    0.5,
    0.45,
    0.55,
    0.5,   # P-wave
    0.35,                     # Q dip
    0.95,                     # R peak (sharp spike)
    0.1,                      # S trough
    0.5,
    0.55,
    0.6,
    0.55,
    0.5,  # T-wave + return to baseline
]

function _advance_ecg!(m::KaimonModel)
    new = _ECG_NEW_COMPLETIONS[]
    if new > 0
        _ECG_NEW_COMPLETIONS[] = 0
        m.ecg_pending_blips += new
    end
    # Heartbeat from gate health-check pings — one blip per new ping
    if m.conn_mgr !== nothing
        latest = lock(m.conn_mgr.lock) do
            foldl((acc, c) -> max(acc, c.last_ping), m.conn_mgr.connections; init = DateTime(0))
        end
        if latest > m.ecg_last_ping_seen
            m.ecg_pending_blips += 1
            m.ecg_last_ping_seen = latest
        end
    end
    if m.ecg_inject_countdown <= 0 && m.ecg_pending_blips > 0
        m.ecg_inject_countdown = length(_QRS_WAVEFORM)
        m.ecg_pending_blips -= 1
    end
    # Scroll left
    trace = m.ecg_trace
    for i = 1:(length(trace)-1)
        trace[i] = trace[i+1]
    end
    # New rightmost value
    if m.ecg_inject_countdown > 0
        idx = length(_QRS_WAVEFORM) - m.ecg_inject_countdown + 1
        trace[end] = _QRS_WAVEFORM[idx]
        m.ecg_inject_countdown -= 1
    else
        trace[end] = 0.5
    end
end

function _render_ecg_trace(m::KaimonModel, rect::Rect, buf::Buffer, key::String = "")
    w, h = rect.width, rect.height
    (w < 2 || h < 1) && return

    health, _ = _compute_health(m, key)
    style =
        health >= 0.7 ? tstyle(:success) : health >= 0.3 ? tstyle(:warning) : tstyle(:error)

    c = PixelCanvas(w, h; style = style)
    dot_w = w * 2
    dot_h = h * 4
    trace = m.ecg_trace
    n = length(trace)
    start_idx = max(1, n - dot_w + 1)

    prev_dx, prev_dy = -1, -1
    for dx = 0:(dot_w-1)
        tidx = start_idx + dx
        val = (tidx >= 1 && tidx <= n) ? trace[tidx] : 0.5
        dy = round(Int, (1.0 - clamp(val, 0.0, 1.0)) * (dot_h - 1))
        dy = clamp(dy, 0, dot_h - 1)
        set_point!(c, dx, dy)
        prev_dx >= 0 && line!(c, prev_dx, prev_dy, dx, dy)
        prev_dx, prev_dy = dx, dy
    end
    render(c, rect, buf)
end

"""Compute error-rate health from recent tool results. Returns (health, has_data).
When `key` is non-empty, only results matching that session key are counted."""
function _compute_health(m::KaimonModel, key::String = "")::Tuple{Float64,Bool}
    results = m.tool_results
    if isempty(key)
        isempty(results) && return (1.0, false)
        n = min(50, length(results))
        recent = @view results[(end-n+1):end]
        errors = count(r -> !r.success, recent)
        return (1.0 - errors / n, true)
    else
        # Filter to this session's results, take last 50
        matched = 0
        errors = 0
        for i = length(results):-1:1
            r = results[i]
            r.session_key == key || continue
            matched += 1
            r.success || (errors += 1)
            matched >= 50 && break
        end
        matched == 0 && return (1.0, false)
        return (1.0 - errors / matched, true)
    end
end

# ── Sessions Tab (REPL gates + MCP agents) ────────────────────────────────

const _EVAL_SPINNER = ("⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷")
_eval_icon(tick::Int) = _EVAL_SPINNER[mod1(tick ÷ 4 + 1, length(_EVAL_SPINNER))]

function view_sessions(m::KaimonModel, area::Rect, buf::Buffer)
    # Full-screen session terminal takes over entire tab
    if m.session_terminal_open && m.session_terminal !== nothing
        _view_session_terminal(m, area, buf)
        return
    end

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

    # Filter out extension connections (they appear in the Extensions tab)
    ext_namespaces = Set(
        ext.config.manifest.namespace for ext in get_managed_extensions()
    )
    filter!(conn -> conn.spawned_by != "extension" && !(conn.namespace in ext_namespaces), connections)

    _sync_sessions_table!(m, connections)
    dt = m.sessions_table
    if dt !== nothing
        dt.tick = m.tick
        render(dt, left_rows[1], buf)
    end

    # ── MCP agents table ──
    _sync_agents_table!(m, agent_sessions)
    adt = m.agents_table
    if adt !== nothing
        adt.tick = m.tick
        render(adt, left_rows[2], buf)
    end

    # ── Right: detail panel for selected gate connection ──
    scroll_indicator = m.sessions_detail_scroll > 0 ? " ↑$(m.sessions_detail_scroll)" : ""
    detail_block = Block(
        title = "Details$scroll_indicator",
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
        spawned_str = conn.spawned_by == "agent" ? "agent $(m.personality_icon)" : "user"
        fields = [
            ("Name", dname),
            ("Status", string(conn.status)),
            ("Path", _short_path(conn.project_path)),
            ("Julia", conn.julia_version),
            ("PID", string(conn.pid)),
            ("Spawned by", spawned_str),
            ("Uptime", _time_ago(conn.connected_at)),
            ("Last seen", _time_ago(conn.last_seen)),
        ]
        if conn.diagnostics !== nothing
            d = conn.diagnostics
            push!(fields, ("Memory", "$(round(d.rss_mb; digits=1)) MB"))
            push!(fields, ("CPU", "$(round(d.cpu_pct; digits=1))%"))
            push!(fields, ("Diagnosis", _diagnose_activity(d)))
        end
        if conn.status in (:connected, :evaluating, :stalled)
            push!(fields, ("Trace", "[t] profile"))
        end
        append!(fields, [
            ("Tool calls", string(conn.tool_call_count)),
            ("Mirroring", mirror_str),
            ("Restart", restart_str),
            ("Session", conn.session_id[1:min(8, length(conn.session_id))] * "..."),
        ])

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

# ── Session Terminal (PTY console) ────────────────────────────────────────────

function _view_session_terminal(m::KaimonModel, area::Rect, buf::Buffer)
    tw = m.session_terminal
    try
        drain!(tw)  # drain PTY output, feed VT parser
    catch e
        _push_log!(:warn, "Terminal drain error: $(sprint(showerror, e))")
        _close_session_terminal!(m)
        return
    end

    block = Block(
        title = "Session Console [$(m.session_terminal_key)]  [Esc] close",
        border_style = tstyle(:accent),
        title_style = tstyle(:accent, bold = true),
    )
    inner = render(block, area, buf)
    try
        render(tw, inner, buf)
    catch e
        _push_log!(:warn, "Terminal render error: $(sprint(showerror, e))")
        _close_session_terminal!(m)
    end
end

"""Open a full-screen terminal widget for an agent-spawned session's PTY."""
function _open_session_terminal!(m::KaimonModel, ms::ManagedSession)
    ms.pty === nothing && return
    Tachikoma.pty_alive(ms.pty) || return
    reopen = m.session_terminal_key == ms.session_key
    _close_session_terminal!(m)
    try
        m.session_terminal = TerminalWidget(ms.pty; show_scrollbar = true, focused = true)
        m.session_terminal_key = ms.session_key
        m.session_terminal_open = true
        # On re-open, nudge the REPL so it prints a fresh prompt
        reopen && Tachikoma.pty_write(ms.pty, "\n")
    catch e
        _push_log!(:warn, "Failed to open session terminal: $(sprint(showerror, e))")
        _close_session_terminal!(m)
    end
end

"""Close the session terminal overlay without killing the PTY."""
function _close_session_terminal!(m::KaimonModel)
    # Do NOT call close!(tw) — that kills the PTY/process.
    # Just drop the widget reference; PTY stays alive in ManagedSession.
    m.session_terminal = nothing
    m.session_terminal_key = ""
    m.session_terminal_open = false
end

"""Build/rebuild the sessions DataTable from live connections."""
function _sync_sessions_table!(m::KaimonModel, connections::Vector{REPLConnection})
    n = length(connections)
    dt_hash = hash((n, m.selected_connection, m.tick ÷ 4))
    old_dt = m.sessions_table

    if old_dt !== nothing && m._sessions_table_hash == dt_hash
        return
    end

    col_names = Any[]
    col_status = Any[]
    col_pid = Any[]
    row_styles = Style[]

    for conn in connections
        icon = if conn.status == :connected
            "⬤"
        elseif conn.status == :evaluating
            _eval_icon(m.tick)
        elseif conn.status == :stalled
            "⬤"
        elseif conn.status == :connecting
            "◌"
        else
            "⬤"
        end
        style =
            conn.status == :connected ? tstyle(:success) :
            conn.status == :evaluating ? tstyle(:accent) :
            conn.status == :stalled ? tstyle(:warning) :
            conn.status == :connecting ? tstyle(:warning) : tstyle(:error)
        dname = isempty(conn.display_name) ? conn.name : conn.display_name
        agent_tag = conn.spawned_by == "agent" ? " $(m.personality_icon)" : ""
        push!(col_names, Span("$icon $dname$agent_tag", style))
        push!(col_status, Span(string(conn.status), style))
        push!(col_pid, string(conn.pid))
        push!(row_styles, style)
    end

    if isempty(col_names)
        push!(col_names, "No REPL sessions")
        push!(col_status, "")
        push!(col_pid, "")
        push!(row_styles, tstyle(:text_dim))
    end

    dt = DataTable(
        [
            DataColumn("Name", col_names),
            DataColumn("Status", col_status; width=12),
            DataColumn("PID", col_pid; width=7),
        ];
        selected = n > 0 ? clamp(m.selected_connection, 1, n) : 0,
        block = Block(
            title = "REPL Sessions ($n) [x] shutdown [t] trace",
            border_style = _pane_border(m, 2, 1),
            title_style = _pane_title(m, 2, 1),
        ),
        tick = m.tick,
        row_styles = row_styles,
    )
    m._sessions_table_hash = dt_hash

    # Preserve mouse/drag state across rebuilds
    if old_dt !== nothing
        dt.last_content_area = old_dt.last_content_area
        dt.last_col_positions = old_dt.last_col_positions
        dt.last_widths = old_dt.last_widths
        dt.offset = old_dt.offset
        dt.col_widths = old_dt.col_widths
        dt.col_drag = old_dt.col_drag
        dt.col_drag_start_x = old_dt.col_drag_start_x
        dt.col_drag_start_w = old_dt.col_drag_start_w
    end
    m.sessions_table = dt
end

"""Build/rebuild the agents DataTable from live MCP sessions."""
function _sync_agents_table!(m::KaimonModel, agent_sessions)
    n = length(agent_sessions)
    dt_hash = hash((n, m.tick ÷ 8))
    old_dt = m.agents_table

    if old_dt !== nothing && m._agents_table_hash == dt_hash
        return
    end

    col_client = Any[]
    col_session = Any[]
    col_active = Any[]

    if isempty(agent_sessions)
        push!(col_client, "No agents connected")
        push!(col_session, "")
        push!(col_active, "")
    else
        for s in agent_sessions
            client_name = get(s.client_info, "name", "unknown")
            push!(col_client, string(client_name))
            push!(col_session, s.id[1:min(8, length(s.id))] * "…")
            push!(col_active, _time_ago(s.last_activity))
        end
    end

    dt = DataTable(
        [
            DataColumn("Client", col_client),
            DataColumn("Session", col_session; width=10),
            DataColumn("Active", col_active; width=8),
        ];
        selected = 0,
        block = Block(
            title = n > 0 ? "Agents ($n)" : "Agents",
            border_style = _pane_border(m, 2, 2),
            title_style = _pane_title(m, 2, 2),
        ),
        tick = m.tick,
    )
    m._agents_table_hash = dt_hash

    if old_dt !== nothing
        dt.last_content_area = old_dt.last_content_area
        dt.last_col_positions = old_dt.last_col_positions
        dt.last_widths = old_dt.last_widths
        dt.offset = old_dt.offset
        dt.col_widths = old_dt.col_widths
        dt.col_drag = old_dt.col_drag
        dt.col_drag_start_x = old_dt.col_drag_start_x
        dt.col_drag_start_w = old_dt.col_drag_start_w
    end
    m.agents_table = dt
end

"""Get the filtered list of visible (non-extension) REPL connections."""
function _visible_connections(m::KaimonModel)
    m.conn_mgr === nothing && return REPLConnection[]
    conns = lock(m.conn_mgr.lock) do
        copy(m.conn_mgr.connections)
    end
    ext_namespaces = Set(
        ext.config.manifest.namespace for ext in get_managed_extensions()
    )
    filter!(conn -> conn.spawned_by != "extension" && !(conn.namespace in ext_namespaces), conns)
    return conns
end

"""Shutdown the selected session from the Sessions tab."""
function _shutdown_selected_session!(m::KaimonModel)
    conns = _visible_connections(m)
    (m.selected_connection < 1 || m.selected_connection > length(conns)) && return
    conn = conns[m.selected_connection]
    sk = short_key(conn)
    dname = isempty(conn.display_name) ? conn.name : conn.display_name
    mgr = m.conn_mgr

    # Close terminal widget if open for this session
    if m.session_terminal_open && m.session_terminal_key == sk
        _close_session_terminal!(m)
    end

    # Fire-and-forget: shutdown gate + stop managed process without blocking the TUI
    Threads.@spawn begin
        send_shutdown!(conn)
        if conn.spawned_by == "agent"
            ms = find_managed_session(conn.project_path)
            ms !== nothing && stop_session!(ms)
        end
    end

    # Immediately remove from connection manager
    if mgr !== nothing
        lock(mgr.lock) do
            _unregister_session_tools!(conn)
            disconnect!(conn)
            _remove_session_files(mgr.sock_dir, conn.session_id)
            idx = findfirst(c -> c === conn, mgr.connections)
            idx !== nothing && deleteat!(mgr.connections, idx)
        end
        _fire_sessions_changed(mgr)
    end

    # Fix selection bounds
    n = _visible_session_count(m)
    m.selected_connection = clamp(m.selected_connection, 1, max(1, n))

    _push_log!(:info, "Shutdown session '$dname' ($sk)")
end

"""Save the current backtrace result to a file near the session's project."""
function _save_backtrace!(m::KaimonModel)
    bt = m.backtrace_result
    bt === nothing && return
    conns = _visible_connections(m)
    dir = if m.selected_connection >= 1 && m.selected_connection <= length(conns)
        conn = conns[m.selected_connection]
        isempty(conn.project_path) ? tempdir() : conn.project_path
    else
        tempdir()
    end
    ts = Dates.format(now(), "yyyymmdd_HHMMss")
    fname = "profile_trace_$(ts).txt"
    path = joinpath(dir, fname)
    try
        write(path, bt)
        _push_log!(:info, "Saved profile trace to $path")
    catch
        path = joinpath(tempdir(), fname)
        write(path, bt)
        _push_log!(:info, "Saved profile trace to $path")
    end
end

# ── ECG / Health ─────────────────────────────────────────────────────────────

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

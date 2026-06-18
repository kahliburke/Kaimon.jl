# ── Sessions Tab (REPL gates + MCP agents) ────────────────────────────────

const _EVAL_SPINNER = ("⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷")
_eval_icon(tick::Int) = _EVAL_SPINNER[mod1(tick ÷ 4 + 1, length(_EVAL_SPINNER))]

"""Short, display-friendly fingerprint of a CURVE key (40-char Z85): `head…tail`."""
_key_fingerprint(k::AbstractString) =
    length(k) > 12 ? string(k[1:6], "…", k[end-3:end]) : String(k)

"""Terse tag for a stall reason, shown after the session name (empty for :none)."""
_stall_tag(r::Symbol) =
    r === :offline ? "offline" :
    r === :key_changed ? "key?" :
    r === :unresponsive ? "no pong" : ""

"""Full explanation of a stall reason, shown on the Details Status line."""
_stall_detail(r::Symbol) =
    r === :offline ? "gate offline (TCP refused)" :
    r === :key_changed ? "reachable — CURVE handshake failing; server key may have changed (verify & re-pin)" :
    r === :unresponsive ? "reachable — no pong; if CURVE, pin/verify its key" : ""

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
    mcp_clients = lock(STANDALONE_SESSIONS_LOCK) do
        collect(values(STANDALONE_SESSIONS))
    end
    filter!(s -> s.state == Session.INITIALIZED, mcp_clients)

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

    # Filter out extension-spawned connections (they appear in the Extensions tab)
    filter!(conn -> conn.spawned_by != "extension", connections)

    _sync_sessions_table!(m, connections)
    dt = m.sessions_table
    if dt !== nothing
        dt.tick = m.tick
        render(dt, left_rows[1], buf)
    end

    # ── MCP clients table ──
    _sync_clients_table!(m, mcp_clients)
    adt = m.clients_table
    if adt !== nothing
        adt.tick = m.tick
        render(adt, left_rows[2], buf)
    end

    # ── Right: detail panel for selected gate connection ──
    scroll_indicator = m.sessions_detail_scroll > 0 ? " ↑$(m.sessions_detail_scroll)" : ""
    detail_block = Block(
        title = "Details$scroll_indicator",
        border_style = _pane_border(m, TAB_SESSIONS, 3),
        title_style = _pane_title(m, TAB_SESSIONS, 3),
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
            ("Status", (conn.status == :stalled && conn.stall_reason != :none) ?
                "stalled — $(_stall_detail(conn.stall_reason))" : string(conn.status)),
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
            ("Session", startswith(conn.session_id, "tcp-") ? conn.session_id : conn.session_id[1:min(8, length(conn.session_id))] * "..."),
        ])
        # CURVE transport: a non-empty pinned server key means the link is encrypted.
        # Status only here — the key/fingerprint lives in Key Management (not on this page).
        if !isempty(conn.server_pubkey)
            push!(fields, ("Encryption", "🔒 CURVE"))
        end

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
        lock_tag = isempty(conn.server_pubkey) ? "" : " 🔒"   # CURVE-encrypted link
        stall_tag = (conn.status == :stalled && conn.stall_reason != :none) ?
            " · $(_stall_tag(conn.stall_reason))" : ""
        push!(col_names, Span("$icon $dname$agent_tag$lock_tag$stall_tag", style))
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
            title = "REPL Sessions ($n) [r]estart [x]shutdown [t]race [k]eys",
            border_style = _pane_border(m, TAB_SESSIONS, 1),
            title_style = _pane_title(m, TAB_SESSIONS, 1),
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
function _sync_clients_table!(m::KaimonModel, mcp_clients)
    n = length(mcp_clients)
    dt_hash = hash((n, m.tick ÷ 8))
    old_dt = m.clients_table

    if old_dt !== nothing && m._clients_table_hash == dt_hash
        return
    end

    col_client = Any[]
    col_session = Any[]
    col_active = Any[]

    if isempty(mcp_clients)
        push!(col_client, "No clients connected")
        push!(col_session, "")
        push!(col_active, "")
    else
        for s in mcp_clients
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
            title = n > 0 ? "Clients ($n)" : "Clients",
            border_style = _pane_border(m, TAB_SESSIONS, 2),
            title_style = _pane_title(m, TAB_SESSIONS, 2),
        ),
        tick = m.tick,
    )
    m._clients_table_hash = dt_hash

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
    m.clients_table = dt
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

"""Restart the selected session from the Sessions tab."""
function _restart_selected_session!(m::KaimonModel)
    conns = _visible_connections(m)
    (m.selected_connection < 1 || m.selected_connection > length(conns)) && return
    conn = conns[m.selected_connection]
    sk = short_key(conn)
    dname = isempty(conn.display_name) ? conn.name : conn.display_name

    # Close terminal widget if open for this session
    if m.session_terminal_open && m.session_terminal_key == sk
        _close_session_terminal!(m)
    end

    # Fire-and-forget: send restart command to gate.
    # Unlike shutdown, we do NOT call stop_session! — execvp replaces the
    # process image (same PID, same PTY) so the managed session stays valid
    # and the gate will reconnect with the same session ID.
    Threads.@spawn begin
        send_restart!(conn)
    end

    _push_log!(:info, "Restart session '$dname' ($sk)")
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

function _get_ecg!(m::KaimonModel, key::String)
    get!(m.ecg_states, key) do
        ECGState()
    end
end

function _advance_ecg!(m::KaimonModel)
    # Collect new tool completions per session
    completions = lock(_ECG_NEW_COMPLETIONS_LOCK) do
        if isempty(_ECG_NEW_COMPLETIONS)
            nothing
        else
            snap = copy(_ECG_NEW_COMPLETIONS)
            empty!(_ECG_NEW_COMPLETIONS)
            snap
        end
    end
    if completions !== nothing
        for (sk, count) in completions
            isempty(sk) && continue
            ecg = _get_ecg!(m, sk)
            ecg.pending_blips += count
        end
    end

    # Heartbeat blips are now pushed via :session_pong TaskEvents
    # from the health check loop — no polling needed here.

    # Advance all active ECG traces
    for ecg in values(m.ecg_states)
        if ecg.inject_countdown <= 0 && ecg.pending_blips > 0
            ecg.inject_countdown = length(_QRS_WAVEFORM)
            ecg.pending_blips -= 1
        end
        trace = ecg.trace
        for i = 1:(length(trace)-1)
            trace[i] = trace[i+1]
        end
        if ecg.inject_countdown > 0
            idx = length(_QRS_WAVEFORM) - ecg.inject_countdown + 1
            trace[end] = _QRS_WAVEFORM[idx]
            ecg.inject_countdown -= 1
        else
            trace[end] = 0.5
        end
    end
end

function _render_ecg_trace(m::KaimonModel, rect::Rect, buf::Buffer, key::String = "")
    w, h = rect.width, rect.height
    (w < 2 || h < 1) && return

    health, _ = _compute_health(m, key)
    style =
        health >= 0.7 ? tstyle(:success) : health >= 0.3 ? tstyle(:warning) : tstyle(:error)

    ecg = get(m.ecg_states, key, nothing)
    trace = ecg !== nothing ? ecg.trace : fill(0.5, 240)

    c = PixelCanvas(w, h; style = style)
    dot_w = w * 2
    dot_h = h * 4
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

# ── CURVE Key-Management Modal (Sessions tab, [k]) ─────────────────────────────
# Visibility + management for this Kaimon instance's CURVE identity and trust
# stores: the client/server fingerprints, the client allow-list (authorized_clients,
# server-side), and the TOFU server pins (known_servers, client-side). Reads/writes
# go through KaimonGate's curve helpers — same files the gate + gate_client use.

"""Reload the allow-list + pins (and identity, once) into the model cache."""
function _refresh_curve_data!(m::KaimonModel)
    try
        m.curve_authorized = KaimonGate.authorized_clients()
    catch
        m.curve_authorized = String[]
    end
    try
        m.curve_pins = KaimonGate.known_servers()
    catch
        m.curve_pins = Tuple{String,String}[]
    end
    if isempty(m.curve_client_pub)
        try
            m.curve_client_pub = KaimonGate._load_or_create_client_keypair()[1]
        catch
        end
    end
    if isempty(m.curve_server_pub)
        try
            m.curve_server_pub = KaimonGate._load_or_create_server_keypair()[1]
        catch
        end
    end
    return nothing
end

"""Open the CURVE key-management modal."""
function _open_curve_modal!(m::KaimonModel)
    _refresh_curve_data!(m)
    m.curve_modal_section = 1
    m.curve_modal_sel = 1
    m.curve_modal_msg = ""
    m.curve_confirm_action = :none
    m.curve_confirm_arg = ""
    m.curve_modal = :main
    return nothing
end

_curve_close_modal!(m::KaimonModel) = (m.curve_modal = :none; m.curve_client_input = nothing)

"""Number of selectable rows in the active section (1=clients, 2=pins)."""
_curve_section_len(m::KaimonModel) =
    m.curve_modal_section == 1 ? length(m.curve_authorized) : length(m.curve_pins)

"""The full key of the currently-selected row (clients: pubkey; pins: server key)."""
function _curve_selected_key(m::KaimonModel)
    if m.curve_modal_section == 1
        i = m.curve_modal_sel
        return (1 <= i <= length(m.curve_authorized)) ? m.curve_authorized[i] : ""
    else
        i = m.curve_modal_sel
        return (1 <= i <= length(m.curve_pins)) ? m.curve_pins[i][2] : ""
    end
end

function _view_curve_modal(m::KaimonModel, area::Rect, buf::Buffer)
    _dim_area!(buf, area)

    nc = length(m.curve_authorized)
    np = length(m.curve_pins)
    # Top-down content rows: identity(3) + blank + clients-hdr + rows + blank +
    # pins-hdr + rows + blank + rule + zone(2) + blank + hint.
    body = 3 + 1 + 1 + max(1, nc) + 1 + 1 + max(1, np) + 1 + 1 + 2 + 1 + 1
    w = min(84, area.width - 4)
    h = clamp(body + 2, 16, area.height - 2)
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = render(
        Block(title = "🔒 CURVE Key Management", border_style = border_s,
              title_style = border_s, box = BOX_HEAVY),
        rect, buf,
    )
    inner.width < 8 && return
    for row = inner.y:bottom(inner), col = inner.x:right(inner)
        set_char!(buf, col, row, ' ', Style(bg = Tachikoma.theme().bg))
    end

    x = inner.x + 1
    y = inner.y
    bot = bottom(inner)
    fp(k) = _key_fingerprint(k)
    nextrow() = (y += 1)

    # ── This instance (identity, read-only) ──
    set_string!(buf, x, y, "This instance", tstyle(:text_dim)); nextrow()
    set_string!(buf, x + 1, y, rpad("Client key", 12), tstyle(:text_dim), inner)
    set_string!(buf, x + 13, y, isempty(m.curve_client_pub) ? "—" : fp(m.curve_client_pub),
        tstyle(:accent), inner)
    set_string!(buf, x + 27, y, "enroll on remote gates", tstyle(:text_dim), inner); nextrow()
    set_string!(buf, x + 1, y, rpad("Server key", 12), tstyle(:text_dim), inner)
    set_string!(buf, x + 13, y, isempty(m.curve_server_pub) ? "—" : fp(m.curve_server_pub),
        tstyle(:text), inner)
    set_string!(buf, x + 27, y, "gates on this host present", tstyle(:text_dim), inner)
    nextrow(); nextrow()

    sec1 = m.curve_modal_section == 1
    sec2 = m.curve_modal_section == 2

    # ── Authorized clients (allow-list) ──
    set_string!(buf, x, y, "Authorized clients ($nc)",
        sec1 ? tstyle(:accent, bold = true) : tstyle(:text_dim))
    set_string!(buf, right(inner) - 18, y, "[a] add  [d] revoke", tstyle(:text_dim), inner)
    nextrow()
    if nc == 0
        set_string!(buf, x + 2, y, "(none — fail-closed)", tstyle(:text_dim), inner); nextrow()
    else
        for (i, k) in enumerate(m.curve_authorized)
            y > bot && break
            sel = sec1 && i == m.curve_modal_sel
            st = sel ? tstyle(:accent, bold = true) : tstyle(:text)
            set_string!(buf, x, y, sel ? "▸ " : "  ", st)
            set_string!(buf, x + 2, y, fp(k), st, inner)
            nextrow()
        end
    end
    nextrow()

    # ── Pinned servers (known hosts, TOFU) ──
    set_string!(buf, x, y, "Pinned servers ($np)",
        sec2 ? tstyle(:accent, bold = true) : tstyle(:text_dim))
    set_string!(buf, right(inner) - 21, y, "[u] unpin  [s] verify", tstyle(:text_dim), inner)
    nextrow()
    if np == 0
        set_string!(buf, x + 2, y, "(none)", tstyle(:text_dim), inner); nextrow()
    else
        for (i, (hostport, key)) in enumerate(m.curve_pins)
            y > bot && break
            sel = sec2 && i == m.curve_modal_sel
            st = sel ? tstyle(:accent, bold = true) : tstyle(:text)
            set_string!(buf, x, y, sel ? "▸ " : "  ", st)
            set_string!(buf, x + 2, y, rpad(hostport, 22), st, inner)
            set_string!(buf, x + 24, y, fp(key), st, inner)
            nextrow()
        end
    end
    nextrow()

    # ── Action zone (rule + 2 rows) — never overlaps the lists ──
    set_string!(buf, x, y, "─"^max(0, inner.width - 2), tstyle(:border), inner); nextrow()
    if m.curve_modal == :add_client
        set_string!(buf, x, y, "Add client key (40-char Z85):", tstyle(:text)); nextrow()
        if m.curve_client_input !== nothing
            m.curve_client_input.tick = m.tick
            render(m.curve_client_input, Rect(x, y, max(8, inner.width - 2), 1), buf)
        end
        nextrow()
    elseif m.curve_modal == :confirm
        if m.curve_confirm_action == :repin
            set_string!(buf, x, y, "⚠️  SERVER KEY CHANGED for $(m.curve_confirm_arg)",
                tstyle(:error)); nextrow()
            old = ""
            for (hp, k) in m.curve_pins
                hp == m.curve_confirm_arg && (old = k)
            end
            set_string!(buf, x, y, "old $(fp(old))   →   new $(fp(m.curve_confirm_key))",
                tstyle(:secondary), inner); nextrow()
        else
            verb = m.curve_confirm_action == :revoke ? "Revoke client" : "Unpin server"
            set_string!(buf, x, y, "$verb:", tstyle(:warning)); nextrow()
            set_string!(buf, x, y, m.curve_confirm_arg, tstyle(:secondary), inner); nextrow()
        end
    else
        section_label = sec1 ? "Selected client key" : "Selected server key"
        sel_full = _curve_selected_key(m)
        set_string!(buf, x, y, isempty(sel_full) ? "Selected key" : section_label,
            tstyle(:text_dim)); nextrow()
        set_string!(buf, x, y,
            isempty(sel_full) ? "(select a row to view its full key)" : sel_full,
            isempty(sel_full) ? tstyle(:text_dim) : tstyle(:secondary), inner)
        nextrow()
    end
    nextrow()

    # ── Hint / transient status ──
    if m.curve_modal == :confirm
        if m.curve_confirm_action == :repin
            set_string!(buf, x, y, "[y] re-pin (trust NEW key)   [n] keep old",
                tstyle(:warning), inner)
        else
            set_string!(buf, x, y, "[y] yes   [n] no", tstyle(:warning), inner)
        end
    elseif m.curve_modal == :add_client
        set_string!(buf, x, y, "[enter] authorize   [esc] cancel", tstyle(:text_dim), inner)
    else
        hint = "[tab] section  [↑↓] select  [a]dd  [d]revoke  [u]npin  [s]sh-verify  [esc] close"
        if isempty(m.curve_modal_msg)
            set_string!(buf, x, y, hint, tstyle(:text_dim), inner)
        else
            st = startswith(m.curve_modal_msg, "✗") ? tstyle(:error) : tstyle(:success)
            set_string!(buf, x, y, m.curve_modal_msg, st, inner)
        end
    end
    return nothing
end

# ── Mutations ──────────────────────────────────────────────────────────────────

function _curve_do_authorize!(m::KaimonModel, key::AbstractString)
    k = strip(String(key))
    if length(k) != 40
        m.curve_modal_msg = "✗ Not a 40-char Z85 key"
        return
    end
    r = try
        KaimonGate.authorize_client!(k)
    catch e
        m.curve_modal_msg = "✗ $(sprint(showerror, e))"
        return
    end
    _refresh_curve_data!(m)
    m.curve_modal_msg = r == :added ? "✓ Authorized $(_key_fingerprint(k))" :
                                      "• Already authorized"
    return
end

function _curve_do_revoke!(m::KaimonModel, key::AbstractString)
    r = try
        KaimonGate.revoke_client!(key)
    catch e
        m.curve_modal_msg = "✗ $(sprint(showerror, e))"
        return
    end
    _refresh_curve_data!(m)
    m.curve_modal_sel = clamp(m.curve_modal_sel, 1, max(1, length(m.curve_authorized)))
    m.curve_modal_msg = r == :removed ? "✓ Revoked $(_key_fingerprint(key))" : "• Not found"
    return
end

function _curve_do_unpin!(m::KaimonModel, hostport::AbstractString)
    r = try
        KaimonGate.unpin_server!(hostport)
    catch e
        m.curve_modal_msg = "✗ $(sprint(showerror, e))"
        return
    end
    _refresh_curve_data!(m)
    m.curve_modal_sel = clamp(m.curve_modal_sel, 1, max(1, length(m.curve_pins)))
    m.curve_modal_msg = r == :removed ? "✓ Unpinned $hostport" : "• Not found"
    return
end

"""Replace the pin for `hostport` with `newkey` (after an SSH-verified key change)."""
function _curve_do_repin!(m::KaimonModel, hostport::AbstractString, newkey::AbstractString)
    idx = findlast(==(':'), String(hostport))
    if idx === nothing
        m.curve_modal_msg = "✗ Bad host:port '$hostport'"
        return
    end
    try
        host = String(hostport)[1:idx-1]
        port = parse(Int, String(hostport)[idx+1:end])
        KaimonGate.unpin_server!(String(hostport))
        KaimonGate.pin_server!(host, port, String(newkey))
    catch e
        m.curve_modal_msg = "✗ $(sprint(showerror, e))"
        return
    end
    _refresh_curve_data!(m)
    m.curve_modal_msg = "✓ Re-pinned $hostport → $(_key_fingerprint(newkey))"
    return
end

# ── Key routing ────────────────────────────────────────────────────────────────

function _handle_curve_modal_key!(m::KaimonModel, evt::KeyEvent)
    if m.curve_modal == :add_client
        @match evt.key begin
            :escape => (m.curve_modal = :main; m.curve_client_input = nothing)
            :enter => begin
                key = m.curve_client_input === nothing ? "" :
                      Tachikoma.text(m.curve_client_input)
                _curve_do_authorize!(m, key)
                m.curve_modal = :main
                m.curve_client_input = nothing
            end
            _ => begin
                if m.curve_client_input !== nothing
                    m.curve_client_input.tick = m.tick
                    handle_key!(m.curve_client_input, evt)
                end
            end
        end
        return
    end

    if m.curve_modal == :confirm
        @match (evt.key, evt.char) begin
            (:char, 'y') || (:enter, _) => begin
                if m.curve_confirm_action == :revoke
                    _curve_do_revoke!(m, m.curve_confirm_arg)
                elseif m.curve_confirm_action == :unpin
                    _curve_do_unpin!(m, m.curve_confirm_arg)
                elseif m.curve_confirm_action == :repin
                    _curve_do_repin!(m, m.curve_confirm_arg, m.curve_confirm_key)
                end
                m.curve_confirm_action = :none
                m.curve_confirm_arg = ""
                m.curve_confirm_key = ""
                m.curve_modal = :main
            end
            _ => begin   # n / esc / anything else cancels
                m.curve_confirm_action = :none
                m.curve_confirm_arg = ""
                m.curve_confirm_key = ""
                m.curve_modal = :main
            end
        end
        return
    end

    # :main
    @match (evt.key, evt.char) begin
        (:escape, _) => _curve_close_modal!(m)
        (:tab, _) || (:backtab, _) => begin
            m.curve_modal_section = m.curve_modal_section == 1 ? 2 : 1
            m.curve_modal_sel = 1
            m.curve_modal_msg = ""
        end
        (:up, _) => (m.curve_modal_sel = max(1, m.curve_modal_sel - 1))
        (:down, _) =>
            (m.curve_modal_sel = min(max(1, _curve_section_len(m)), m.curve_modal_sel + 1))
        (:char, 'a') => begin
            m.curve_client_input = TextInput(text = "", label = "")
            m.curve_modal_msg = ""
            m.curve_modal = :add_client
        end
        (:char, 'd') => begin
            if m.curve_modal_section == 1 && !isempty(m.curve_authorized)
                m.curve_confirm_action = :revoke
                m.curve_confirm_arg = _curve_selected_key(m)
                m.curve_modal = :confirm
            end
        end
        (:char, 'u') => begin
            if m.curve_modal_section == 2 && !isempty(m.curve_pins)
                i = m.curve_modal_sel
                m.curve_confirm_action = :unpin
                m.curve_confirm_arg = m.curve_pins[i][1]   # host:port
                m.curve_modal = :confirm
            end
        end
        (:char, 's') => begin
            # SSH-verify the selected pin against the host's authoritative key.
            # Runs off-thread (ssh can block ~10s) — result lands in the task
            # queue as :curve_ssh_verify.
            if m.curve_modal_section == 2 && !isempty(m.curve_pins)
                hostport = m.curve_pins[m.curve_modal_sel][1]
                idx = findlast(==(':'), hostport)
                if idx !== nothing
                    host = hostport[1:idx-1]
                    port = parse(Int, hostport[idx+1:end])
                    m.curve_modal_msg = "⏳ Verifying $hostport via SSH…"
                    spawn_task!(m._task_queue, :curve_ssh_verify) do
                        (; hostport, result = KaimonGate.verify_server_key_via_ssh(host, port))
                    end
                end
            end
        end
        _ => nothing
    end
    return
end

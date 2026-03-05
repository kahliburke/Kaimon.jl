# ── Debug Tab ─────────────────────────────────────────────────────────────────
#
# Tab 8: Infiltrator/breakpoint integration. Two panes:
#   Pane 1 (top): Status + locals display
#   Pane 2 (bottom): Debug console with history + infil> input

# ── View ─────────────────────────────────────────────────────────────────────

function view_debug(m::KaimonModel, area::Rect, buf::Buffer)
    panes = split_layout(m.debug_layout, area)
    length(panes) < 2 && return

    _view_debug_locals(m, panes[1], buf)
    _view_debug_console(m, panes[2], buf)

    render_resize_handles!(buf, m.debug_layout)
end

"""Render the status + locals pane (top)."""
function _view_debug_locals(m::KaimonModel, area::Rect, buf::Buffer)
    if m.debug_state == :idle
        render(
            Block(
                title = "Debug",
                border_style = _pane_border(m, 8, 1),
                title_style = _pane_title(m, 8, 1),
            ),
            area,
            buf,
        )
        inner = Rect(area.x + 1, area.y + 1, max(0, area.width - 2), max(0, area.height - 2))
        inner.width < 4 && return
        msg = "No active debug session."
        set_string!(buf, inner.x + 1, inner.y, msg, tstyle(:text_dim))
        set_string!(
            buf,
            inner.x + 1,
            inner.y + 1,
            "Insert @infiltrate in your code to pause here.",
            tstyle(:text_dim),
        )
        return
    end

    # Sync locals into ScrollPane
    _sync_debug_locals_pane!(m)

    pane = m.debug_locals_pane
    if pane !== nothing
        loc = isempty(m.debug_file) ? "" : " $(basename(m.debug_file)):$(m.debug_line)"
        sess = isempty(m.debug_session_key) ? "" : "  [$(m.debug_session_key)]"
        title = "◉ Paused$loc$sess"
        pane.block = Block(
            title = title,
            border_style = _pane_border(m, 8, 1),
            title_style = tstyle(:error, bold = true),
        )
        render(pane, area, buf)
    end
end

"""Render the debug console pane (bottom)."""
function _view_debug_console(m::KaimonModel, area::Rect, buf::Buffer)
    _sync_debug_console_pane!(m)

    pane = m.debug_console_pane
    if pane === nothing
        render(
            Block(
                title = "Console",
                border_style = _pane_border(m, 8, 2),
                title_style = _pane_title(m, 8, 2),
            ),
            area,
            buf,
        )
        return
    end

    # Reserve bottom row for input when paused
    if m.debug_state == :paused
        console_area = Rect(area.x, area.y, area.width, max(1, area.height - 1))
        input_area = Rect(area.x, area.y + area.height - 1, area.width, 1)
    else
        console_area = area
        input_area = nothing
    end

    title_str = if m.debug_state == :paused
        help = m.debug_input_editing ? "[Enter]eval [Esc]cancel [C-c]abort" :
            "[i]nput [c]ontinue [a]bort"
        "Console $help"
    else
        "Console"
    end
    pane.block = Block(
        title = title_str,
        border_style = _pane_border(m, 8, 2),
        title_style = _pane_title(m, 8, 2),
    )
    render(pane, console_area, buf)

    # Render input line
    if input_area !== nothing && m.debug_state == :paused
        if m.debug_input_editing && m.debug_input !== nothing
            inp = m.debug_input
            inp.tick = m.tick
            render(inp, input_area, buf)
        else
            prompt_style = tstyle(:accent)
            set_string!(buf, input_area.x + 1, input_area.y, "infil> ", prompt_style)
            if m.debug_agent_continue_pending
                set_string!(
                    buf,
                    input_area.x + 8,
                    input_area.y,
                    "Agent requests continue... [Enter=Allow, Esc=Deny]",
                    tstyle(:warning),
                )
            end
        end
    end
end

# ── Pane Sync ────────────────────────────────────────────────────────────────

function _ensure_debug_locals_pane!(m::KaimonModel)
    if m.debug_locals_pane === nothing
        m.debug_locals_pane = ScrollPane(
            Vector{Span}[];
            following = false,
            reverse = false,
            block = nothing,
            show_scrollbar = true,
        )
        m._debug_locals_synced = 0
    end
end

function _ensure_debug_console_pane!(m::KaimonModel)
    if m.debug_console_pane === nothing
        m.debug_console_pane = ScrollPane(
            Vector{Span}[];
            following = true,
            reverse = false,
            block = nothing,
            show_scrollbar = true,
        )
        m._debug_history_synced = 0
    end
end

"""Sync locals data into the ScrollPane."""
function _sync_debug_locals_pane!(m::KaimonModel)
    _ensure_debug_locals_pane!(m)
    pane = m.debug_locals_pane::ScrollPane
    n = length(m.debug_locals)
    n == m._debug_locals_synced && return

    # Rebuild completely (locals change as a batch, not incrementally)
    lines = Vector{Span}[]
    sorted = sort(m.debug_locals; by = x -> x.name)
    for local_var in sorted
        name = local_var.name
        typ = local_var.type
        val = local_var.value
        # Truncate long values
        if length(val) > 200
            val = val[1:197] * "..."
        end
        push!(
            lines,
            [
                Span(name, tstyle(:accent, bold = true)),
                Span("::", tstyle(:text_dim)),
                Span(typ, tstyle(:text_dim)),
                Span(" = ", tstyle(:text_dim)),
                Span(val, tstyle(:text)),
            ],
        )
    end
    pane.content = lines
    m._debug_locals_synced = n
end

"""Sync history entries into the console ScrollPane."""
function _sync_debug_console_pane!(m::KaimonModel)
    _ensure_debug_console_pane!(m)
    pane = m.debug_console_pane::ScrollPane
    n = length(m.debug_history)
    synced = m._debug_history_synced
    synced >= n && return

    for i in (synced+1):n
        entry = m.debug_history[i]
        # Source label line
        prefix = entry.source == :agent ? "agent" : "user"
        prefix_style =
            entry.source == :agent ? tstyle(:warning, bold = true) : tstyle(:accent, bold = true)
        push_line!(pane, [Span("$prefix> ", prefix_style), Span(entry.code, tstyle(:text))])
        # Result line(s)
        result_style =
            startswith(entry.result, "ERROR") ? tstyle(:error) : tstyle(:text_dim)
        for rline in split(entry.result, '\n')
            push_line!(pane, [Span("  → $rline", result_style)])
        end
    end
    m._debug_history_synced = n
end

# ── Input Handling ───────────────────────────────────────────────────────────

"""Handle char keys on the Debug tab (when not in edit mode)."""
function _handle_debug_key!(m::KaimonModel, evt::KeyEvent)
    if m.debug_agent_continue_pending
        @match evt.char begin
            'y' => begin
                _debug_send_continue!(m, :continue)
                m.debug_agent_continue_pending = false
            end
            'n' => (m.debug_agent_continue_pending = false)
            _ => nothing
        end
        return
    end

    @match evt.char begin
        'c' => begin
            m.debug_state == :paused && _debug_send_continue!(m, :continue)
        end
        'a' => begin
            m.debug_state == :paused && _debug_send_continue!(m, :abort)
        end
        'i' || 'e' => begin
            if m.debug_state == :paused
                m.debug_input_editing = true
                if m.debug_input === nothing
                    m.debug_input = TextInput(text = "", label = "infil> ", tick = m.tick)
                end
            end
        end
        _ => nothing
    end
end

"""Handle input when debug TextInput is in edit mode."""
function _handle_debug_input_edit!(m::KaimonModel, evt::KeyEvent)
    @match evt.key begin
        :enter => begin
            inp = m.debug_input
            inp === nothing && return
            code = strip(Tachikoma.text(inp))
            if !isempty(code)
                _debug_eval_expression!(m, String(code))
                # Reset input
                m.debug_input = TextInput(text = "", label = "infil> ", tick = m.tick)
            end
        end
        :escape => (m.debug_input_editing = false)
        :ctrl => begin
            if evt.char == 'c'
                m.debug_input_editing = false
                m.debug_state == :paused && _debug_send_continue!(m, :abort)
            else
                m.debug_input !== nothing && handle_key!(m.debug_input, evt)
            end
        end
        _ => (m.debug_input !== nothing && handle_key!(m.debug_input, evt))
    end
end

# ── Gate Communication ───────────────────────────────────────────────────────

"""Evaluate an expression in the paused debug context, push result to history."""
function _debug_eval_expression!(m::KaimonModel, code::String)
    conn = _debug_resolve_conn(m)
    conn === nothing && return

    result = try
        resp = _gate_send_recv(conn, (type = :debug_eval, code = code))
        error_msg = get(resp, :error, nothing)
        if error_msg !== nothing
            "ERROR: $error_msg"
        else
            something(get(resp, :result, nothing), "nothing")
        end
    catch e
        "ERROR: $e"
    end

    push!(
        m.debug_history,
        (source = :user, code = code, result = result),
    )
end

"""Send continue/abort to the paused gate session."""
function _debug_send_continue!(m::KaimonModel, action::Symbol)
    conn = _debug_resolve_conn(m)
    conn === nothing && return
    try
        _gate_send_recv(conn, (type = :debug_continue, action = action))
    catch
    end
    # Don't set state to idle here — wait for breakpoint_resumed PUB message
end

"""Resolve the gate connection for the debug session."""
function _debug_resolve_conn(m::KaimonModel)
    mgr = m.conn_mgr
    mgr === nothing && return nothing
    key = m.debug_session_key
    isempty(key) && return nothing
    get_connection_by_key(mgr, key)
end

# ── Stream Message Handlers ──────────────────────────────────────────────────

"""Handle a breakpoint_hit PUB message from a gate session."""
function _handle_breakpoint_hit!(m::KaimonModel, msg)
    # Parse serialized breakpoint info
    info = try
        deserialize(IOBuffer(Vector{UInt8}(msg.data)))
    catch
        # Try as plain text fallback
        nothing
    end
    info === nothing && return

    m.debug_state = :paused
    m.debug_file = string(get(info, :file, "unknown"))
    m.debug_line = Int(get(info, :line, 0))

    # Find session key from display name
    m.debug_session_key = ""
    if m.conn_mgr !== nothing
        for conn in connected_sessions(m.conn_mgr)
            dname = isempty(conn.display_name) ? conn.name : conn.display_name
            if dname == msg.session_name
                m.debug_session_key = short_key(conn)
                break
            end
        end
    end

    # Parse locals
    locals_dict = get(info, :locals, Dict())
    types_dict = get(info, :locals_types, Dict())
    m.debug_locals = [
        (name = string(k), type = string(get(types_dict, k, "Any")), value = string(v))
        for (k, v) in locals_dict
    ]

    # Reset panes for new session
    m.debug_locals_pane = nothing
    m.debug_console_pane = nothing
    m.debug_input = nothing
    m.debug_input_editing = false
    m.debug_agent_continue_pending = false
    m._debug_locals_synced = 0
    m._debug_history_synced = 0

    # Clear previous history, add status message
    empty!(m.debug_history)
    loc = isempty(m.debug_file) ? "" : " at $(m.debug_file):$(m.debug_line)"
    push!(
        m.debug_history,
        (source = :agent, code = "breakpoint hit$loc", result = "$(length(m.debug_locals)) local variables captured"),
    )

    # Auto-switch to Debug tab
    _switch_tab!(m, 8)
end

"""Handle a breakpoint_resumed PUB message."""
function _handle_breakpoint_resumed!(m::KaimonModel)
    m.debug_state == :paused || return
    m.debug_state = :idle
    m.debug_input_editing = false
    m.debug_agent_continue_pending = false
    push!(
        m.debug_history,
        (source = :agent, code = "execution resumed", result = "debug session ended"),
    )
end

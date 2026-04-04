# ── Debug Tab ─────────────────────────────────────────────────────────────────
#
# Tab 7: Infiltrator/breakpoint integration. Two panes:
#   Pane 1 (top): Status + locals display
#   Pane 2 (bottom): Debug console with history + infil> input

# ── View ─────────────────────────────────────────────────────────────────────

function view_debug(m::KaimonModel, area::Rect, buf::Buffer)
    panes = split_layout(m.debug_layout, area)
    length(panes) < 2 && return

    _view_debug_locals(m, panes[1], buf)
    _view_debug_console(m, panes[2], buf)

    render_resize_handles!(buf, m.debug_layout)

    # Consent modal overlay
    if m.debug_agent_continue_pending
        if m._debug_consent_modal === nothing
            req = _DEBUG_CONTINUE_REQUEST[]
            action_str = req !== nothing ? string(req.action) : "continue"
            m._debug_consent_modal = Modal(
                title = "Agent Request",
                message = "The agent wants to $action_str\nthe debug session.",
                confirm_label = "Allow",
                cancel_label = "Deny",
                selected = :cancel,
            )
        end
        m._debug_consent_modal.tick = m.tick
        render(m._debug_consent_modal, area, buf)
    end
end

"""Render the status + locals pane (top)."""
function _view_debug_locals(m::KaimonModel, area::Rect, buf::Buffer)
    if m.debug_state == :idle
        render(
            Block(
                title = "Debug",
                border_style = _pane_border(m, TAB_DEBUG, 1),
                title_style = _pane_title(m, TAB_DEBUG, 1),
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
            border_style = _pane_border(m, TAB_DEBUG, 1),
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
                border_style = _pane_border(m, TAB_DEBUG, 2),
                title_style = _pane_title(m, TAB_DEBUG, 2),
            ),
            area,
            buf,
        )
        return
    end

    # Sync wrap setting
    pane.word_wrap = m.debug_console_wrap

    wrap_hint = m.debug_console_wrap ? "wrap:on" : "wrap:off"
    title_str = if m.debug_state == :paused
        help = m.debug_input_editing ? "[Enter]eval [Esc]nav" :
            "[c]ontinue [w]rap"
        "Console [$wrap_hint] $help"
    else
        "Console [$wrap_hint]"
    end
    pane.block = Block(
        title = title_str,
        border_style = _pane_border(m, TAB_DEBUG, 2),
        title_style = _pane_title(m, TAB_DEBUG, 2),
    )

    # Add infil> prompt as last line in pane content when paused
    if m.debug_state == :paused
        # Ensure the prompt line is always at the end of content
        _sync_debug_prompt_line!(m)
    end

    render(pane, area, buf)

    # Overlay TextInput on top of the prompt line when editing.
    # The console pane has following=true, so the prompt (last content line)
    # is always rendered at the bottom of the visible area.
    if m.debug_state == :paused && m.debug_input_editing && m.debug_input !== nothing
        inner_x = area.x + 1
        inner_w = max(0, area.width - 2)
        inner_top = area.y + 1
        inner_h = max(0, area.height - 2)
        inner_h < 1 && return

        # Compute total visual lines (accounting for word wrap)
        if pane.word_wrap
            wrap_w = inner_w - (pane.show_scrollbar ? 1 : 0)
            total = length(Tachikoma._wrap_content(pane.content, max(1, wrap_w)))
        else
            total = pane.content isa Vector{Vector{Span}} ? length(pane.content) : 0
        end

        # Place input at the last occupied row, clamped to the pane bottom
        visible_rows = min(total, inner_h)
        screen_row = inner_top + visible_rows - 1

        if screen_row >= inner_top
            input_area = Rect(inner_x, screen_row, inner_w, 1)
            inp = m.debug_input
            inp.tick = m.tick
            render(inp, input_area, buf)
        end
    end
end

"""Add/update the infil> prompt as the last line in console content."""
function _sync_debug_prompt_line!(m::KaimonModel)
    pane = m.debug_console_pane
    pane === nothing && return
    content = pane.content
    content isa Vector{Vector{Span}} || return

    prompt_line = [Span("infil> ", tstyle(:accent))]

    # Check if the last line is already our prompt
    if !isempty(content) && length(content[end]) == 1 &&
       content[end][1].content == "infil> "
        # Already there
        return
    end
    push!(content, prompt_line)
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
            word_wrap = true,
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
            word_wrap = m.debug_console_wrap,
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
        val_lines = split(val, '\n')
        # First line: name::type = first_line_of_value
        push!(
            lines,
            [
                Span(name, tstyle(:accent, bold = true)),
                Span("::", tstyle(:text_dim)),
                Span(typ, tstyle(:text_dim)),
                Span(" = ", tstyle(:text_dim)),
                Span(String(val_lines[1]), tstyle(:text)),
            ],
        )
        # Continuation lines indented
        for i in 2:length(val_lines)
            push!(lines, [Span("  " * String(val_lines[i]), tstyle(:text))])
        end
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

    # Remove trailing infil> prompt before appending new history lines
    content = pane.content
    if content isa Vector{Vector{Span}} && !isempty(content) &&
       length(content[end]) == 1 && content[end][1].content == "infil> "
        pop!(content)
    end

    for i in (synced+1):n
        entry = m.debug_history[i]
        # Agent evals get "agent>" prefix; user evals show as "infil>" (matching the prompt)
        if entry.source == :agent
            push_line!(pane, [Span("agent> ", tstyle(:warning, bold = true)), Span(entry.code, tstyle(:text))])
        else
            push_line!(pane, [Span("infil> ", tstyle(:accent)), Span(entry.code, tstyle(:text))])
        end
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
        _handle_debug_consent_key!(m, evt)
        return
    end

    # When paused and on console pane, any printable char enters edit mode
    # with that character pre-typed — no shortcuts steal keystrokes here.
    if m.debug_state == :paused && get(m.focused_pane, 7, 1) == 2
        m.debug_input_editing = true
        if m.debug_input === nothing
            m.debug_input = TextInput(text = "", label = "infil> ", tick = m.tick)
        end
        handle_key!(m.debug_input, evt)
        return
    end

    @match evt.char begin
        'c' => begin
            m.debug_state == :paused && _debug_send_continue!(m, :continue)
        end
        'w' => begin
            m.debug_console_wrap = !m.debug_console_wrap
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
                # Check for : commands
                cmd = lowercase(strip(code))
                if cmd in (":c", ":continue")
                    _debug_send_continue!(m, :continue)
                    m.debug_input = TextInput(text = "", label = "infil> ", tick = m.tick)
                elseif cmd in (":w", ":wrap")
                    m.debug_console_wrap = !m.debug_console_wrap
                    if m.debug_console_pane !== nothing
                        m.debug_console_pane.word_wrap = m.debug_console_wrap
                    end
                    m.debug_input = TextInput(text = "", label = "infil> ", tick = m.tick)
                elseif cmd in (":h", ":help", "?")
                    push!(m.debug_history, (source = :user, code = cmd, result = ":c continue  :w wrap  :h help  ? help\nEsc exit edit  Ctrl-W toggle wrap\nType Julia expressions to eval in breakpoint scope"))
                    m.debug_input = TextInput(text = "", label = "infil> ", tick = m.tick)
                else
                    # Save to history
                    push!(m.debug_cmd_history, String(code))
                    m.debug_cmd_history_idx = 0
                    m.debug_user_interacted = true
                    _debug_eval_expression!(m, String(code))
                    m.debug_input = TextInput(text = "", label = "infil> ", tick = m.tick)
                end
            end
        end
        :escape => begin
            m.debug_input_editing = false
            m.debug_cmd_history_idx = 0
        end
        :up => begin
            # Browse history (up = older)
            hist = m.debug_cmd_history
            if !isempty(hist)
                idx = m.debug_cmd_history_idx
                new_idx = min(idx + 1, length(hist))
                if new_idx != idx
                    m.debug_cmd_history_idx = new_idx
                    cmd = hist[end - new_idx + 1]
                    m.debug_input !== nothing && set_text!(m.debug_input, cmd)
                end
            end
        end
        :down => begin
            # Browse history (down = newer)
            idx = m.debug_cmd_history_idx
            if idx > 1
                m.debug_cmd_history_idx = idx - 1
                cmd = m.debug_cmd_history[end - (idx - 2)]
                m.debug_input !== nothing && set_text!(m.debug_input, cmd)
            elseif idx == 1
                m.debug_cmd_history_idx = 0
                m.debug_input !== nothing && set_text!(m.debug_input, "")
            end
        end
        :tab => begin
            # Tab completion: query gate for completions
            inp = m.debug_input
            inp !== nothing && _debug_tab_complete!(m, inp)
        end
        :ctrl => begin
            if evt.char == 'w'
                m.debug_console_wrap = !m.debug_console_wrap
                # Rebuild console pane with new wrap setting
                if m.debug_console_pane !== nothing
                    m.debug_console_pane.word_wrap = m.debug_console_wrap
                end
            else
                m.debug_input !== nothing && handle_key!(m.debug_input, evt)
            end
        end
        _ => (m.debug_input !== nothing && handle_key!(m.debug_input, evt))
    end
end

"""Tab-complete the current input against locals and the eval module's names."""
function _debug_tab_complete!(m::KaimonModel, inp::TextInput)
    conn = _debug_resolve_conn(m)
    conn === nothing && return
    text = String(Tachikoma.text(inp))
    isempty(text) && return

    # : commands — complete from known commands
    if startswith(text, ":")
        cmds = [":c", ":continue", ":w", ":wrap", ":h", ":help"]
        matches = filter(c -> startswith(c, text), cmds)
        if length(matches) == 1
            set_text!(inp, matches[1])
        elseif length(matches) > 1
            prefix = matches[1]
            for c in matches[2:end]
                while !startswith(c, prefix)
                    prefix = prefix[1:prevind(prefix, lastindex(prefix))]
                    isempty(prefix) && break
                end
            end
            if length(prefix) > length(text)
                set_text!(inp, prefix)
            else
                push!(m.debug_history, (source = :user, code = "<tab>", result = join(matches, "  ")))
            end
        end
        return
    end

    # Extract the partial identifier at the end of the input (the word being completed)
    # e.g. "length(res" → partial="res", prefix_text="length("
    ident_start = something(findlast(c -> !Base.is_id_char(c), text), 0) + 1
    partial = text[ident_start:end]
    prefix_text = text[1:ident_start-1]
    isempty(partial) && return

    # Get completions from the eval module — locals, imports, and macros from
    # imported modules (e.g. Infiltrator's @exfiltrate).
    is_macro = startswith(partial, "@")
    result = try
        code = """let _ns = Set{String}(), _M = @__MODULE__
            _pat = "$(escape_string(partial))"
            # Local/imported names from eval module
            for n in names(_M; all=true, imported=true)
                s = string(n)
                (startswith(s, "#") || startswith(s, "var\\"")) && continue
                startswith(s, _pat) && push!(_ns, s)
            end
            # Also search exported names from modules imported via `using`
            for n in names(_M; all=true)
                s = string(n)
                (startswith(s, "#") || startswith(s, "var\\"")) && continue
                isdefined(_M, n) || continue
                v = getfield(_M, n)
                v isa Module || continue
                v === _M && continue
                for en in names(v)
                    es = string(en)
                    startswith(es, _pat) && push!(_ns, es)
                end
            end
            join(sort!(collect(_ns)), "\\n")
        end"""
        resp = _gate_send_recv(conn, (type = :debug_eval, source = :user, code = code))
        s = something(get(resp, :result, nothing), "")
        # Strip surrounding quotes from repr output
        startswith(s, '"') && endswith(s, '"') ? s[2:end-1] : s
    catch
        ""
    end
    isempty(result) && return

    completions = split(result, "\\n")
    filter!(!isempty, completions)
    isempty(completions) && return

    if length(completions) == 1
        set_text!(inp, prefix_text * String(completions[1]))
    else
        # Find common prefix among completions
        common = String(completions[1])
        for c in completions[2:end]
            while !startswith(c, common)
                common = common[1:prevind(common, lastindex(common))]
                isempty(common) && break
            end
            isempty(common) && break
        end
        if length(common) > length(partial)
            set_text!(inp, prefix_text * common)
        else
            # Show completions in console
            comp_str = join(completions, "  ")
            push!(m.debug_history, (source = :user, code = "<tab> $partial", result = comp_str))
        end
    end
end

# ── Gate Communication ───────────────────────────────────────────────────────

"""Evaluate an expression in the paused debug context, push result to history."""
function _debug_eval_expression!(m::KaimonModel, code::String)
    conn = _debug_resolve_conn(m)
    conn === nothing && return

    result = try
        resp = _gate_send_recv(conn, (type = :debug_eval, code = code, source = :user))
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

"""Send continue to the paused gate session."""
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

# ── Agent Consent Coordination ────────────────────────────────────────────────

"""Poll for agent debug continue requests and show consent prompt."""
function _poll_debug_consent!(m::KaimonModel)
    m.debug_state == :paused || return
    req = _DEBUG_CONTINUE_REQUEST[]
    req === nothing && return
    m.debug_agent_continue_pending && return  # already showing prompt
    if !m.debug_user_interacted
        # User hasn't typed in the console — auto-approve without prompting
        _debug_approve_continue!(m)
        return
    end
    m.debug_agent_continue_pending = true
    _switch_tab!(m, 7)
end

"""Handle key/mouse events for the consent modal."""
function _handle_debug_consent_key!(m::KaimonModel, evt)
    modal = m._debug_consent_modal
    modal === nothing && return

    result = if evt isa MouseEvent
        handle_mouse!(modal, evt)
    else
        # y/n shortcuts
        if evt.key == :char && evt.char == 'y'
            :confirm
        elseif evt.key == :char && evt.char == 'n'
            :cancel
        else
            handle_key!(modal, evt)
        end
    end
    if result == :confirm
        m._debug_consent_modal = nothing
        _debug_approve_continue!(m)
    elseif result == :cancel
        m._debug_consent_modal = nothing
        _debug_deny_continue!(m)
    end
end

"""Approve the agent's continue request."""
function _debug_approve_continue!(m::KaimonModel)
    m.debug_agent_continue_pending = false
    resp_ch = _DEBUG_CONTINUE_RESPONSE[]
    if resp_ch !== nothing
        try
            put!(resp_ch, :approved)
        catch
        end
    end
end

"""Deny the agent's continue request."""
function _debug_deny_continue!(m::KaimonModel)
    m.debug_agent_continue_pending = false
    resp_ch = _DEBUG_CONTINUE_RESPONSE[]
    if resp_ch !== nothing
        try
            put!(resp_ch, :denied)
        catch
        end
    end
end

# ── Stream Message Handlers ──────────────────────────────────────────────────

"""Handle a debug_eval PUB message — agent eval result to show in console."""
function _handle_debug_eval_pub!(m::KaimonModel, msg)
    info = try
        deserialize(IOBuffer(Vector{UInt8}(msg.data)))
    catch
        nothing
    end
    info === nothing && return
    source = get(info, :source, :agent)
    # Skip user-sourced evals — the TUI already pushed those in _debug_eval_expression!
    source == :user && return
    code = string(get(info, :code, ""))
    result = string(get(info, :result, ""))
    push!(m.debug_history, (source = source, code = code, result = result))
end

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
    m.debug_user_interacted = false
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
    _switch_tab!(m, 7)
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

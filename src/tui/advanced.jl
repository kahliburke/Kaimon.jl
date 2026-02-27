# ── Advanced Tab: Stress Test Runner ─────────────────────────────────────────
# StressAgentResult, _write_stress_script, _STRESS_SCRIPT_SOURCE,
# _parse_stress_kv, and _parse_stress_results live in stress_test.jl

"""Launch the stress test process."""
function _launch_stress_test!(m::KaimonModel)
    m.stress_state == STRESS_RUNNING && return

    # Get session info
    sessions = m.conn_mgr !== nothing ? connected_sessions(m.conn_mgr) : []
    if isempty(sessions)
        m.stress_state = STRESS_ERROR
        lock(m.stress_output_lock) do
            push!(
                m.stress_output,
                "ERROR agent=0 elapsed=0.0 message=no_connected_sessions",
            )
        end
        return
    end

    idx = clamp(m.stress_session_idx, 1, length(sessions))
    sess = sessions[idx]
    sess_key = short_key(sess)

    code = m.stress_code
    n_agents = tryparse(Int, m.stress_agents)
    n_agents === nothing && (n_agents = 5)
    stagger_val = tryparse(Float64, m.stress_stagger)
    stagger_val === nothing && (stagger_val = 0.0)
    timeout_val = tryparse(Int, m.stress_timeout)
    timeout_val === nothing && (timeout_val = 30)

    # Reset state
    lock(m.stress_output_lock) do
        empty!(m.stress_output)
    end
    m.stress_scroll_pane = ScrollPane(
        Vector{Span}[];
        following = true,
        reverse = false,
        block = nothing,
        show_scrollbar = true,
    )
    m.stress_result_file = ""
    m.stress_state = STRESS_RUNNING

    script_path = _write_stress_script()
    project_dir = pkgdir(@__MODULE__)
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project_dir $script_path $(m.server_port) $sess_key $code $n_agents $stagger_val $timeout_val`

    Threads.@spawn try
        process = open(cmd, "r")
        m.stress_process = process
        while !eof(process)
            line = readline(process; keep = false)
            isempty(line) && continue
            lock(m.stress_output_lock) do
                push!(m.stress_output, line)
            end
        end
        # Process finished
        exit_code = try
            wait(process)
            process.exitcode
        catch
            -1
        end
        m.stress_process = nothing

        # Write results file
        _write_stress_results!(m, code, sess_key, n_agents, stagger_val, timeout_val)

        # Check actual results — did any agents fail?
        all_output = lock(m.stress_output_lock) do
            copy(m.stress_output)
        end
        agents = _parse_stress_results(all_output)
        has_failures = any(a -> a.status == :fail, agents)

        if exit_code != 0
            m.stress_state = STRESS_ERROR
        elseif has_failures
            m.stress_state = STRESS_ERROR
        else
            m.stress_state = STRESS_COMPLETE
        end
    catch e
        m.stress_process = nothing
        lock(m.stress_output_lock) do
            push!(
                m.stress_output,
                "ERROR agent=0 elapsed=0.0 message=$(sprint(showerror, e))",
            )
        end
        m.stress_state = STRESS_ERROR
    end
end

"""Cancel a running stress test."""
function _cancel_stress_test!(m::KaimonModel)
    m.stress_state != STRESS_RUNNING && return
    proc = m.stress_process
    if proc !== nothing
        try
            kill(proc)
        catch
        end
        m.stress_process = nothing
    end
    lock(m.stress_output_lock) do
        push!(m.stress_output, "CANCELLED")
    end
    m.stress_state = STRESS_IDLE
end

"""Write stress test results to a file (delegates to shared _write_stress_results_to_file)."""
function _write_stress_results!(m::KaimonModel, code, sess_key, n_agents, stagger, timeout)
    all_output = lock(m.stress_output_lock) do
        copy(m.stress_output)
    end
    path = _write_stress_results_to_file(
        all_output,
        code,
        sess_key,
        n_agents,
        stagger,
        timeout,
    )
    if path !== nothing
        m.stress_result_file = path
    end
end

"""Drain buffered stress output lines into the ScrollPane each frame."""
function _drain_stress_output!(m::KaimonModel)
    m.stress_scroll_pane === nothing && return
    pane = m.stress_scroll_pane::ScrollPane
    new_lines = lock(m.stress_output_lock) do
        if isempty(m.stress_output)
            return String[]
        end
        # Return lines that haven't been synced to pane yet
        # We track by comparing lengths
        total = length(m.stress_output)
        synced = length(pane.content)
        if total > synced
            return m.stress_output[synced+1:total]
        end
        return String[]
    end
    for line in new_lines
        push_line!(pane, _stress_line_spans(line, m.tick))
    end
end

"""Convert a stress output line to styled Spans."""
function _stress_line_spans(line::String, tick::Int)::Vector{Span}
    if startswith(line, "INIT ")
        kv = _parse_stress_kv(line)
        aid = get(kv, "agent", "?")
        sid = get(kv, "session", "?")
        return Span[
            Span("[Agent $aid] ", tstyle(:secondary)),
            Span("initialized ", tstyle(:text_dim)),
            Span("session=$sid", tstyle(:text_dim)),
        ]
    elseif startswith(line, "SEND ")
        kv = _parse_stress_kv(line)
        aid = get(kv, "agent", "?")
        return Span[
            Span("[Agent $aid] ", tstyle(:secondary)),
            Span("SENDING tool call...", tstyle(:accent)),
        ]
    elseif startswith(line, "SEND_ALL ")
        kv = _parse_stress_kv(line)
        n = get(kv, "count", "?")
        return Span[
            Span(">>> ", tstyle(:accent, bold = true)),
            Span("Firing $n tool calls concurrently", tstyle(:accent, bold = true)),
        ]
    elseif startswith(line, "PROGRESS ")
        kv = _parse_stress_kv(line)
        aid = get(kv, "agent", "?")
        elapsed = get(kv, "elapsed", "?")
        step = get(kv, "step", "?")
        msg = get(kv, "message", "")
        return Span[
            Span("[Agent $aid] ", tstyle(:secondary)),
            Span("(+$(elapsed)s) ", tstyle(:text_dim)),
            Span("PROGRESS #$step ", tstyle(:warning)),
            Span(msg, tstyle(:text)),
        ]
    elseif startswith(line, "RESULT ")
        kv = _parse_stress_kv(line)
        aid = get(kv, "agent", "?")
        elapsed = get(kv, "elapsed", "?")
        ok = get(kv, "ok", "false")
        is_ok = ok == "true"
        result_text = get(kv, "result", "")
        return Span[
            Span("[Agent $aid] ", tstyle(:secondary)),
            Span("(+$(elapsed)s) ", tstyle(:text_dim)),
            Span(is_ok ? "OK " : "FAIL ", tstyle(is_ok ? :success : :error, bold = true)),
            Span(result_text, tstyle(:text)),
        ]
    elseif startswith(line, "ERROR ")
        kv = _parse_stress_kv(line)
        aid = get(kv, "agent", "?")
        elapsed = get(kv, "elapsed", "?")
        msg = get(kv, "message", "unknown")
        return Span[
            Span("[Agent $aid] ", tstyle(:secondary)),
            Span("(+$(elapsed)s) ", tstyle(:text_dim)),
            Span("ERROR: ", tstyle(:error, bold = true)),
            Span(msg, tstyle(:error)),
        ]
    elseif startswith(line, "SUMMARY ")
        kv = _parse_stress_kv(line)
        tt = get(kv, "total_time", "?")
        succ = get(kv, "succeeded", "?")
        fail = get(kv, "failed", "?")
        return Span[
            Span("SUMMARY ", tstyle(:accent, bold = true)),
            Span("$(tt)s total  ", tstyle(:text)),
            Span("$succ ok  ", tstyle(:success, bold = true)),
            Span("$fail failed", tstyle(parse(Int, fail) > 0 ? :error : :text_dim)),
        ]
    elseif startswith(line, "START ")
        kv = _parse_stress_kv(line)
        n = get(kv, "agents", "?")
        return Span[
            Span(">>> ", tstyle(:accent, bold = true)),
            Span("Stress test: $n agents", tstyle(:accent, bold = true)),
        ]
    elseif line == "DONE"
        return Span[Span(">>> Complete", tstyle(:success, bold = true))]
    elseif line == "CANCELLED"
        return Span[Span(">>> Cancelled by user", tstyle(:warning, bold = true))]
    else
        return Span[Span(line, tstyle(:text))]
    end
end

"""Handle all key events while a stress form field is in edit mode.
This intercepts ALL input (including numbers, letters) so global shortcuts don't fire."""
function _handle_stress_field_edit!(m::KaimonModel, evt::KeyEvent)
    fi = m.stress_field_idx

    @match fi begin
        1 where {m.stress_code_area!==nothing} => begin
            if evt.key == :escape
                m.stress_code = Tachikoma.text(m.stress_code_area)
                m.stress_editing = false
                return
            end
            m.stress_code_area.tick = m.tick
            handle_key!(m.stress_code_area, evt)
        end
        2 => begin
            @match evt.key begin
                :escape || :enter => (m.stress_editing = false)
                :left => begin
                    sessions = m.conn_mgr !== nothing ? connected_sessions(m.conn_mgr) : []
                    m.stress_session_idx =
                        mod1(m.stress_session_idx - 1, max(1, length(sessions)))
                end
                :right => begin
                    sessions = m.conn_mgr !== nothing ? connected_sessions(m.conn_mgr) : []
                    m.stress_session_idx =
                        mod1(m.stress_session_idx + 1, max(1, length(sessions)))
                end
                _ => nothing
            end
        end
        _ => begin
            # Inline text fields (Agents=3, Stagger=4, Timeout=5)
            @match evt.key begin
                :escape || :enter => (m.stress_editing = false)
                :char => @match fi begin
                    3 => (m.stress_agents *= evt.char)
                    4 => (m.stress_stagger *= evt.char)
                    5 => (m.stress_timeout *= evt.char)
                    _ => nothing
                end
                :backspace => @match fi begin
                    3 => (m.stress_agents = _stress_backspace(m.stress_agents))
                    4 => (m.stress_stagger = _stress_backspace(m.stress_stagger))
                    5 => (m.stress_timeout = _stress_backspace(m.stress_timeout))
                    _ => nothing
                end
                _ => nothing
            end
        end
    end
end

"""Handle char key events on the Advanced tab (when NOT in field edit mode)."""
function _handle_stress_key!(m::KaimonModel, evt::KeyEvent)
    # Nothing to do for char events when not editing — form navigation is
    # handled by up/down in _handle_scroll!, and Enter opens edit mode.
end

"""Handle Enter on the Advanced tab — open field for editing or run."""
function _handle_stress_enter!(m::KaimonModel)
    m.stress_state == STRESS_RUNNING && return
    get(m.focused_pane, 5, 1) == 1 || return

    @match m.stress_field_idx begin
        1 => begin
            m.stress_code_area =
                CodeEditor(text = m.stress_code, focused = true, tick = m.tick)
            m.stress_editing = true
        end
        6 => _launch_stress_test!(m)
        _ => (m.stress_editing = true)
    end
end

"""Handle left/right arrow keys on the Advanced tab (not in edit mode)."""
function _handle_stress_arrow!(m::KaimonModel, evt::KeyEvent)
    # Left/right do nothing outside of edit mode
end

"""Delete the last character from a string."""
function _stress_backspace(s::String)::String
    isempty(s) ? s : s[1:prevind(s, lastindex(s))]
end


# ── Advanced Tab View ────────────────────────────────────────────────────────

function view_advanced(m::KaimonModel, area::Rect, buf::Buffer)
    panes = split_layout(m.advanced_layout, area)
    length(panes) < 2 && return

    # ── Top pane: Configuration form ──
    _view_stress_form(m, panes[1], buf)

    # ── Bottom pane: Output with live agent visualization ──
    _view_stress_output(m, panes[2], buf)

    render_resize_handles!(buf, m.advanced_layout)
end

"""Render the stress test configuration form."""
function _view_stress_form(m::KaimonModel, area::Rect, buf::Buffer)
    is_running = m.stress_state == STRESS_RUNNING
    fp = get(m.focused_pane, 5, 1)
    form_focused = fp == 1

    # If code editor is open, render it as an overlay instead of the form
    if m.stress_editing && m.stress_field_idx == 1 && m.stress_code_area !== nothing
        _view_stress_code_editor(m, area, buf)
        return
    end

    # Animated border when running
    if is_running && animations_enabled()
        border_shimmer!(
            buf,
            area,
            tstyle(:warning).fg,
            m.tick;
            box = BOX_HEAVY,
            intensity = 0.2,
        )
        if area.width > 4
            si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
            title = " $(SPINNER_BRAILLE[si]) Stress Test Running... "
            set_string!(buf, area.x + 2, area.y, title, tstyle(:warning, bold = true))
        end
        inner =
            Rect(area.x + 1, area.y + 1, max(0, area.width - 2), max(0, area.height - 2))
    else
        title_style = form_focused ? tstyle(:accent, bold = true) : tstyle(:text_dim)
        border_style = form_focused ? tstyle(:accent) : tstyle(:border)
        block = Block(
            title = " Stress Test Configuration ",
            border_style = border_style,
            title_style = title_style,
        )
        inner = render(block, area, buf)
    end
    inner.width < 10 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style())
        end
    end

    x = inner.x + 1
    y = inner.y
    label_w = 10
    fi = m.stress_field_idx

    sessions = m.conn_mgr !== nothing ? connected_sessions(m.conn_mgr) : []
    sess_name = if !isempty(sessions)
        idx = clamp(m.stress_session_idx, 1, length(sessions))
        sessions[idx].name
    else
        "(no sessions)"
    end

    # ── Field 1: Code (multiline preview, Enter to edit) ──
    is_code_active = !is_running && form_focused && fi == 1
    set_string!(buf, x, y, rpad("Code:", label_w), tstyle(:text_dim))
    vx = x + label_w
    vw = inner.width - label_w - 2
    # Show first line of code as preview
    code_lines = Base.split(m.stress_code, '\n')
    preview = first(code_lines)
    n_extra = length(code_lines) - 1
    suffix = n_extra > 0 ? " (+$(n_extra) lines)" : ""
    if is_code_active
        set_string!(
            buf,
            vx,
            y,
            first(string(preview), max(1, vw - length(suffix))),
            tstyle(:accent, bold = true),
        )
        set_string!(
            buf,
            vx + min(length(preview), vw - length(suffix)),
            y,
            suffix,
            tstyle(:text_dim),
        )
        # Hint
        hint = " [Enter] edit"
        hint_x = right(inner) - length(hint)
        if hint_x > vx + length(preview) + length(suffix)
            set_string!(buf, hint_x, y, hint, tstyle(:accent))
        end
    else
        display = first(string(preview) * suffix, vw)
        set_string!(buf, vx, y, display, tstyle(:text))
    end
    y += 1

    # ── Fields 2-5: Session, Agents, Stagger, Timeout ──
    inline_fields = [
        ("Session:", sess_name, 2),
        ("Agents:", m.stress_agents, 3),
        ("Stagger:", m.stress_stagger, 4),
        ("Timeout:", m.stress_timeout, 5),
    ]

    for (label, value, idx) in inline_fields
        y > bottom(inner) - 2 && break
        is_focused = !is_running && form_focused && fi == idx
        is_editing_this = is_focused && m.stress_editing

        set_string!(buf, x, y, rpad(label, label_w), tstyle(:text_dim))

        display_val = if idx == 2
            n = length(sessions)
            n > 1 ? "◂ $value ▸" : value
        else
            value
        end

        if is_editing_this
            # In edit mode — bright highlight + cursor
            field_text = length(display_val) > vw ? first(display_val, vw) : display_val
            set_string!(buf, vx, y, field_text, tstyle(:accent, bold = true))
            if idx != 2  # text cursor on text fields
                cursor_x = vx + min(length(display_val), vw)
                if cursor_x <= right(inner) && m.tick % 30 < 20
                    set_char!(buf, cursor_x, y, '▎', tstyle(:accent))
                end
            end
            # Hints for editing mode
            hint = idx == 2 ? " [◂▸] cycle  [Esc/Enter] done" : " [Esc/Enter] done"
            hint_x = right(inner) - length(hint)
            if hint_x > vx + length(display_val)
                set_string!(buf, hint_x, y, hint, tstyle(:text_dim))
            end
        elseif is_focused
            # Focused but not editing — dim highlight + Enter hint
            field_text = length(display_val) > vw ? first(display_val, vw) : display_val
            set_string!(buf, vx, y, field_text, tstyle(:accent))
            hint = " [Enter] edit"
            hint_x = right(inner) - length(hint)
            if hint_x > vx + length(display_val)
                set_string!(buf, hint_x, y, hint, tstyle(:text_dim))
            end
        else
            set_string!(buf, vx, y, first(display_val, vw), tstyle(:text))
        end
        y += 1
    end

    # ── Field 6: Run / Cancel button ──
    y += 1
    if y <= bottom(inner)
        if is_running
            cancel_label = "[ Cancel (Esc) ]"
            if animations_enabled()
                p = pulse(m.tick; period = 40, lo = 0.5, hi = 1.0)
                base = to_rgb(tstyle(:error).fg)
                pulsed = brighten(base, (1.0 - p) * 0.3)
                set_string!(buf, x + 2, y, cancel_label, Style(fg = pulsed, bold = true))
            else
                set_string!(buf, x + 2, y, cancel_label, tstyle(:error, bold = true))
            end
        else
            run_label = "[ Run Stress Test ]"
            btn_x = x + 2
            btn_focused = form_focused && fi == 6
            if btn_focused
                if animations_enabled()
                    p = pulse(m.tick; period = 60, lo = 0.0, hi = 0.25)
                    base = to_rgb(tstyle(:accent).fg)
                    pulsed = brighten(base, p)
                    set_string!(buf, btn_x, y, run_label, Style(fg = pulsed, bold = true))
                else
                    set_string!(buf, btn_x, y, run_label, tstyle(:accent, bold = true))
                end
                hint_x = btn_x + length(run_label) + 2
                if hint_x + 10 <= right(inner)
                    set_string!(buf, hint_x, y, "[Enter] run", tstyle(:text_dim))
                end
            else
                set_string!(buf, btn_x, y, run_label, tstyle(:text_dim))
            end
        end
    end

    # ── Bottom hint bar ──
    y += 1
    if y <= bottom(inner) && !is_running
        set_string!(
            buf,
            x,
            y,
            "[↑↓] navigate  [Tab] switch pane  [Enter] interact",
            tstyle(:text_dim),
        )
    end
end

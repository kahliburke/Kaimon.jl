"""Render the code editor overlay (TextArea in a bordered panel)."""
function _view_stress_code_editor(m::KaimonModel, area::Rect, buf::Buffer)
    ce = m.stress_code_area
    ce.tick = m.tick

    # Shimmer border for the editor
    if animations_enabled()
        border_shimmer!(
            buf,
            area,
            tstyle(:accent).fg,
            m.tick;
            box = BOX_HEAVY,
            intensity = 0.12,
        )
        if area.width > 4
            set_string!(
                buf,
                area.x + 2,
                area.y,
                " Code Editor ",
                tstyle(:accent, bold = true),
            )
        end
        inner =
            Rect(area.x + 1, area.y + 1, max(0, area.width - 2), max(0, area.height - 2))
    else
        block = Block(
            title = " Code Editor ",
            border_style = tstyle(:accent, bold = true),
            title_style = tstyle(:accent, bold = true),
            box = BOX_HEAVY,
        )
        inner = render(block, area, buf)
    end
    inner.width < 4 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style())
        end
    end

    # Render the CodeEditor in the main area, leaving 1 row for the hint
    editor_h = max(1, inner.height - 1)
    render(ce, Rect(inner.x, inner.y, inner.width, editor_h), buf)

    # Hint bar at bottom
    hint_y = inner.y + editor_h
    if hint_y <= bottom(inner)
        set_string!(
            buf,
            inner.x + 1,
            hint_y,
            "[Esc] save and close  [Tab] indent",
            tstyle(:text_dim),
        )
        # Show line count
        n_lines = length(ce.lines)
        line_info = "$(ce.cursor_row):$(ce.cursor_col) ($(n_lines) lines)"
        info_x = right(inner) - length(line_info)
        if info_x > inner.x + 36
            set_string!(buf, info_x, hint_y, line_info, tstyle(:text_dim))
        end
    end
end

"""Render the stress test output pane with live agent visualization."""
function _view_stress_output(m::KaimonModel, area::Rect, buf::Buffer)
    fp = get(m.focused_pane, 5, 1)
    horde_focused = fp == 2
    log_focused = fp == 3

    all_output = lock(m.stress_output_lock) do
        copy(m.stress_output)
    end
    agents = _parse_stress_results(all_output)

    # If we have agent data and enough space, split into visualization + log
    has_agents = !isempty(agents)
    show_viz = has_agents && area.height > 8 && area.width > 30

    if show_viz
        # Split: left side for agent horde visualization, right side for log
        viz_w = min(max(area.width ÷ 3, 24), 40)
        log_w = area.width - viz_w

        viz_area = Rect(area.x, area.y, viz_w, area.height)
        log_area = Rect(area.x + viz_w, area.y, log_w, area.height)

        _view_agent_horde(m, viz_area, buf, agents, horde_focused)
        _view_stress_log(m, log_area, buf, log_focused)
    else
        _view_stress_log(m, area, buf, log_focused)
    end
end

"""Render the scrollable log output."""
function _view_stress_log(m::KaimonModel, area::Rect, buf::Buffer, focused::Bool)
    # Build title
    title = if m.stress_state == STRESS_RUNNING
        si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
        " $(SPINNER_BRAILLE[si]) Output "
    elseif m.stress_state == STRESS_COMPLETE
        result_hint = isempty(m.stress_result_file) ? "" : " saved "
        " Output (complete$result_hint) "
    elseif m.stress_state == STRESS_ERROR
        " Output (error) "
    else
        " Output "
    end

    # Ensure scroll pane exists
    if m.stress_scroll_pane === nothing
        m.stress_scroll_pane = ScrollPane(
            Vector{Span}[];
            following = true,
            reverse = false,
            block = nothing,
            show_scrollbar = true,
        )
    end
    pane = m.stress_scroll_pane::ScrollPane
    pane.block = Block(
        title = title,
        border_style = focused ? tstyle(:accent) : tstyle(:border),
        title_style = focused ? tstyle(:accent, bold = true) : tstyle(:text_dim),
    )

    render(pane, area, buf)
end

"""Render the agent horde visualization — a live view of all agents' status."""
function _view_agent_horde(
    m::KaimonModel,
    area::Rect,
    buf::Buffer,
    agents::Vector{StressAgentResult},
    focused::Bool = false,
)
    n = length(agents)
    n == 0 && return

    is_running = m.stress_state == STRESS_RUNNING
    is_complete = m.stress_state in (STRESS_COMPLETE, STRESS_ERROR)
    has_failures = any(a -> a.status == :fail, agents)

    # Compute content height to clamp scroll
    w_est = max(1, max(0, area.width - 4))
    cell_w_est = max(8, min(12, w_est ÷ max(1, min(n, 5))))
    grid_cols_est = max(1, w_est ÷ cell_w_est)
    rows_needed_est = cld(n, grid_cols_est)
    # Total content: 2 rows for gauge + rows_needed*3 for agent cells + 6 for sparkline
    content_h = 2 + rows_needed_est * 3 + (is_complete ? 6 : 0)
    viewport_h = max(0, area.height - 2)  # inner height
    max_scroll = max(0, content_h - viewport_h)
    m.stress_horde_scroll = clamp(m.stress_horde_scroll, 0, max_scroll)
    scroll_off = m.stress_horde_scroll

    # Scroll indicator suffix for title
    scroll_hint = if max_scroll > 0
        top_row = scroll_off + 1
        bot_row = min(content_h, scroll_off + viewport_h)
        " [$top_row-$bot_row/$content_h]"
    else
        ""
    end

    # Border with shimmer when running
    if is_running && animations_enabled()
        border_shimmer!(
            buf,
            area,
            focused ? tstyle(:accent).fg : tstyle(:border).fg,
            m.tick;
            box = BOX_HEAVY,
            intensity = focused ? 0.3 : 0.2,
        )
        if area.width > 4
            set_string!(
                buf,
                area.x + 2,
                area.y,
                " Agent Horde$scroll_hint ",
                tstyle(:accent, bold = true),
            )
        end
        inner =
            Rect(area.x + 1, area.y + 1, max(0, area.width - 2), max(0, area.height - 2))
    elseif is_complete && animations_enabled()
        border_color = has_failures ? tstyle(:warning).fg : tstyle(:success).fg
        border_shimmer!(
            buf,
            area,
            focused ? border_color : tstyle(:border).fg,
            m.tick;
            box = BOX_HEAVY,
            intensity = focused ? 0.2 : 0.1,
        )
        if area.width > 4
            n_ok = count(a -> a.status == :ok, agents)
            title =
                has_failures ? " Horde ($n_ok/$n)$scroll_hint " :
                " Horde (all passed)$scroll_hint "
            set_string!(
                buf,
                area.x + 2,
                area.y,
                title,
                tstyle(has_failures ? :warning : :success, bold = true),
            )
        end
        inner =
            Rect(area.x + 1, area.y + 1, max(0, area.width - 2), max(0, area.height - 2))
    else
        block = Block(
            title = " Agent Horde$scroll_hint ",
            border_style = focused ? tstyle(:accent) : tstyle(:border),
            title_style = focused ? tstyle(:accent, bold = true) : tstyle(:text_dim),
        )
        inner = render(block, area, buf)
    end
    inner.width < 6 && return

    # Animated noise background while running
    if is_running && animations_enabled()
        fill_noise!(
            buf,
            inner,
            tstyle(:border).fg,
            tstyle(:text_dim).fg,
            m.tick;
            scale = 0.3,
            speed = 0.02,
        )
    else
        for row = inner.y:bottom(inner)
            for col = inner.x:right(inner)
                set_char!(buf, col, row, ' ', Style())
            end
        end
    end

    x = inner.x + 1
    y_base = inner.y  # top of the viewport
    w = inner.width - 2
    y_bottom = bottom(inner)

    # All content is rendered at virtual y positions, then shifted by -scroll_off.
    # We only draw cells that fall within the viewport.
    vy = 0  # virtual y offset from content top

    # Summary stats
    n_ok = count(a -> a.status == :ok, agents)
    n_fail = count(a -> a.status == :fail, agents)
    n_active = count(a -> a.status in (:sending, :running), agents)

    if is_complete
        # Completion gauge with shimmer
        screen_y = y_base + vy - scroll_off
        if screen_y >= y_base && screen_y <= y_bottom
            ratio = n > 0 ? n_ok / n : 0.0
            gauge = Gauge(
                ratio;
                label = "$(n_ok)/$(n) passed",
                filled_style = tstyle(:success),
                empty_style = n_fail > 0 ? tstyle(:error) : tstyle(:text_dim),
                tick = m.tick,
            )
            render(gauge, Rect(x, screen_y, w, 1), buf)
        end
        vy += 2
    elseif is_running
        # Animated running progress bar
        screen_y = y_base + vy - scroll_off
        if screen_y >= y_base && screen_y <= y_bottom
            done_count = n_ok + n_fail
            ratio = n > 0 ? done_count / n : 0.0
            si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
            gauge = Gauge(
                ratio;
                label = "$(SPINNER_BRAILLE[si]) $(done_count)/$(n) ($n_active active)",
                filled_style = tstyle(:accent),
                empty_style = tstyle(:text_dim),
                tick = m.tick,
            )
            render(gauge, Rect(x, screen_y, w, 1), buf)
        end
        vy += 2
    end

    # Agent grid — each agent as a compact cell with animated effects
    cell_w = max(8, min(12, w ÷ max(1, min(n, 5))))
    grid_cols = max(1, w ÷ cell_w)
    rows_needed = cld(n, grid_cols)

    # Color wave palette for active agents
    wave_colors = [tstyle(:accent).fg, tstyle(:primary).fg, tstyle(:secondary).fg]

    for (i, agent) in enumerate(agents)
        ci = mod1(i, grid_cols) - 1
        ri = (i - 1) ÷ grid_cols
        ax = x + ci * cell_w
        ay_virtual = vy + ri * 3  # virtual y position for this agent cell

        # Convert to screen coordinates
        ay = y_base + ay_virtual - scroll_off

        # Skip if entirely above viewport
        ay + 2 < y_base && continue
        # Stop if entirely below viewport
        ay > y_bottom && break

        # Agent icon and status with per-agent animation
        icon, icon_style = if agent.status == :ok
            "●", tstyle(:success, bold = true)
        elseif agent.status == :fail
            "✗", tstyle(:error, bold = true)
        elseif agent.status == :running
            si = mod1(m.tick ÷ 2 + i * 3, length(SPINNER_BRAILLE))
            if animations_enabled()
                wave_fg = color_wave(m.tick, i, wave_colors; speed = 0.06, spread = 0.12)
                "$(SPINNER_BRAILLE[si])", Style(fg = wave_fg, bold = true)
            else
                "$(SPINNER_BRAILLE[si])", tstyle(:accent)
            end
        elseif agent.status == :sending
            si = mod1(m.tick ÷ 3 + i * 5, length(SPINNER_BRAILLE))
            if animations_enabled()
                p = breathe(m.tick + i * 11; period = 45)
                base = to_rgb(tstyle(:warning).fg)
                "$(SPINNER_BRAILLE[si])", Style(fg = brighten(base, p * 0.3), bold = true)
            else
                "$(SPINNER_BRAILLE[si])", tstyle(:warning)
            end
        elseif agent.status == :init
            "◐", tstyle(:text_dim)
        else
            "○", tstyle(:text_dim)
        end

        # Row 1: icon + agent id (only if on screen)
        if ay >= y_base && ay <= y_bottom
            set_string!(buf, ax, ay, icon, icon_style)
            id_style = if agent.status in (:running, :sending) && animations_enabled()
                f = flicker(m.tick, i; intensity = 0.15, speed = 0.1)
                base = to_rgb(tstyle(:text).fg)
                Style(fg = brighten(base, (1.0 - f) * 0.2))
            else
                tstyle(:text)
            end
            set_string!(buf, ax + 2, ay, "A$(agent.agent_id)", id_style)
        end

        # Row 2: elapsed time or status text
        if ay + 1 >= y_base && ay + 1 <= y_bottom
            if agent.elapsed > 0
                time_str = "$(round(agent.elapsed, digits=1))s"
                time_style = if agent.status == :ok
                    tstyle(:success)
                elseif agent.status == :fail
                    tstyle(:error)
                else
                    tstyle(:text_dim)
                end
                set_string!(buf, ax, ay + 1, time_str, time_style)
            else
                status_str = string(agent.status)
                set_string!(
                    buf,
                    ax,
                    ay + 1,
                    first(status_str, cell_w - 1),
                    tstyle(:text_dim),
                )
            end
        end

        # Row 3: animated progress bar
        if ay + 2 >= y_base && ay + 2 <= y_bottom
            bar_w = min(cell_w - 1, 8)
            if agent.status in (:running, :sending)
                if animations_enabled()
                    scan_pos = mod(m.tick ÷ 2 + i * 3, bar_w * 2)
                    for bx = 0:bar_w-1
                        dist =
                            abs(bx - (scan_pos < bar_w ? scan_pos : bar_w * 2 - scan_pos))
                        brightness = max(0.0, 1.0 - dist / 3.0)
                        ch =
                            brightness > 0.6 ? '█' :
                            brightness > 0.3 ? '▓' : brightness > 0.1 ? '░' : ' '
                        base = to_rgb(tstyle(:accent).fg)
                        fg = dim_color(base, 1.0 - brightness * 0.8)
                        set_char!(buf, ax + bx, ay + 2, ch, Style(fg = fg))
                    end
                else
                    set_string!(buf, ax, ay + 2, repeat("░", bar_w), tstyle(:text_dim))
                end
            elseif agent.progress > 0 || agent.events > 0
                max_ev = max(agent.events, agent.progress, 1)
                filled = min(bar_w, cld(agent.progress * bar_w, max_ev))
                bar = repeat("█", filled) * repeat("░", bar_w - filled)
                set_string!(
                    buf,
                    ax,
                    ay + 2,
                    bar,
                    tstyle(agent.status == :ok ? :success : :accent),
                )
            end
        end
    end

    # Bottom section: sparkline chart for completed tests
    if is_complete && !isempty(agents)
        times = [a.elapsed for a in agents if a.elapsed > 0]
        if !isempty(times)
            spark_vy = vy + rows_needed * 3 + 1
            spark_y = y_base + spark_vy - scroll_off
            spark_h = y_bottom - spark_y + 1
            if spark_h >= 2 && spark_y >= y_base && spark_y <= y_bottom
                sparkline = Sparkline(
                    times;
                    block = Block(
                        title = " Response Times ",
                        border_style = tstyle(:border),
                        title_style = tstyle(:text_dim),
                    ),
                    style = tstyle(:accent),
                )
                render(sparkline, Rect(x, spark_y, w, min(spark_h, 5)), buf)
            end
        end
    end
end

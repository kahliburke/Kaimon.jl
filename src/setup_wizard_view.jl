# ─────────────────────────────────────────────────────────────────────────────
# Kaimon setup wizard · view base · mode-select · intro animation views  (split from setup_wizard_tui.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── View ─────────────────────────────────────────────────────────────────────

function Tachikoma.view(m::SetupWizardModel, f::Frame)
    m.tick += 1
    _update_face_transition!(m)
    update_animations!(m)

    if m.phase == PHASE_MODE_SELECT
        view_mode_select(m, f)
    elseif m.phase == PHASE_INTRO_ANIM
        view_intro_anim(m, f)
    elseif m.phase == PHASE_ACKNOWLEDGE
        view_acknowledge(m, f)
    elseif m.phase == PHASE_DONE
        view_done(m, f)
    else
        view_config_step(m, f)
    end
end

# ── Mode Select View ────────────────────────────────────────────────────────

function view_mode_select(m::SetupWizardModel, f::Frame)
    buf = f.buffer
    area = f.area

    # Outer border
    outer = Block(
        title = "SETUP",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true),
        box = BOX_HEAVY,
    )
    inner = render(outer, area, buf)
    inner.width < 10 && return

    # Layout: header (logo + title) | mode columns | hint bar
    rows = tsplit(Layout(Vertical, [Fixed(7), Fill(), Fixed(1)]), inner)
    length(rows) < 3 && return

    # Header: logo on left, BigText "SETUP" centred in full header width
    header_area = rows[1]
    logo_w = min(14, header_area.width ÷ 4)
    if logo_w >= 4 && header_area.width > logo_w + 10
        logo_area = Rect(header_area.x, header_area.y, logo_w, header_area.height)
        _render_logo!(logo_area, f; tick = m.tick)
    end
    bt = BigText("SETUP"; style = tstyle(:accent, bold = true))
    bt_w, _ = intrinsic_size(bt)
    bt_area = center(header_area, min(bt_w, header_area.width), 5)
    render(bt, bt_area, buf)

    # Three mode columns
    cols_area = rows[2]
    col_w = cols_area.width ÷ 3
    col_w < 5 && return

    mode_names = ["STANDARD", "GENTLE", "L33T"]
    mode_descs = [
        "Dramatic fire-breathing\ndragon intro with heavy\nmetal vibes",
        "Gentle sparkles and\nsupportive messages\nfor a calm setup",
        "Cyberpunk matrix rain\nand hacker aesthetics\nfor the l33t",
    ]
    mode_colors = [Color256(196), Color256(219), Color256(46)]
    mode_previews = [DRAGON_PREVIEW_LINES, BUTTERFLY_PREVIEW_LINES]

    for (i, name) in enumerate(mode_names)
        col_x = cols_area.x + (i - 1) * col_w
        col_rect = Rect(col_x, cols_area.y, col_w - 1, cols_area.height)

        is_selected = i == m.mode_selected
        border_style =
            is_selected ? Style(; fg = mode_colors[i], bold = true) : tstyle(:border)
        box_type = is_selected ? BOX_HEAVY : BOX_ROUNDED

        blk = Block(
            title = "$name",
            border_style = border_style,
            title_style = Style(; fg = mode_colors[i], bold = true),
            box = box_type,
        )
        blk_inner = render(blk, col_rect, buf)
        blk_inner.width < 3 && continue

        # Render art preview
        art_rows = 0
        if i == 3
            # L33T: animated cyber face (same as companion area)
            face_h = min(10, blk_inner.height - 5)
            face_area = Rect(blk_inner.x, blk_inner.y, blk_inner.width, face_h)
            render_cyber_face(m, face_area, buf)
            art_rows = face_h
        else
            # Standard / Gentle: static art with color cycling
            preview = mode_previews[i]
            for (j, line) in enumerate(preview)
                j > blk_inner.height - 3 && break
                cy = is_selected ? (m.tick ÷ 4 + j) : j
                c256 = Color256(FIRE_COLORS[mod1(cy, length(FIRE_COLORS))])
                if i == 2
                    c256 = Color256(BUTTERFLY_COLORS[mod1(cy, length(BUTTERFLY_COLORS))])
                end
                style = Style(; fg = c256)
                safe_line = length(line) > blk_inner.width ? line[1:blk_inner.width] : line
                set_string!(buf, blk_inner.x, blk_inner.y + j - 1, safe_line, style)
            end
            art_rows = min(length(preview), blk_inner.height - 5)
        end

        # Description below art
        desc_y = blk_inner.y + art_rows
        for (j, dline) in enumerate(split(mode_descs[i], '\n'))
            y = desc_y + j
            y > bottom(blk_inner) && break
            set_string!(buf, blk_inner.x + 1, y, dline, tstyle(:text_dim))
        end

        # Selection indicator
        if is_selected
            indicator_y = bottom(blk_inner)
            indicator_y > 0 && set_string!(
                buf,
                blk_inner.x + blk_inner.width ÷ 2 - 3,
                indicator_y,
                "  >>  ",
                Style(; fg = mode_colors[i], bold = true),
            )
        end
    end

    # Hint bar
    set_string!(
        buf,
        rows[3].x + 1,
        rows[3].y,
        " </>  select mode    Enter  confirm    Esc  quit",
        tstyle(:text_dim),
    )
end

# ── Intro Animation Views ───────────────────────────────────────────────────

function view_intro_anim(m::SetupWizardModel, f::Frame)
    buf = f.buffer
    area = f.area

    if m.mode == STANDARD
        view_dragon_intro(m, area, buf)
    elseif m.mode == GENTLE
        view_butterfly_intro(m, area, buf)
    else
        view_neuromancer_intro(m, area, buf)
    end
end

function view_dragon_intro(m::SetupWizardModel, area::Rect, buf::Buffer)
    t = m.tick

    # Determine if mouth is open (during active breathing)
    breathing = (80 <= t <= 170) || (200 <= t <= 310) || (340 <= t <= 480)
    dragon_art = breathing ? DRAGON_MOUTH_OPEN : DRAGON_ASCII
    lines = split(dragon_art, '\n')
    total_lines = length(lines)

    # Reveal progress: how many lines to show
    reveal = val(m.animator, :dragon_reveal)
    visible = max(1, Int(round(reveal * total_lines)))

    # Center the dragon art
    art_width = maximum(length.(lines); init = 0)
    start_x = max(area.x, area.x + (area.width - art_width) ÷ 2)
    start_y = max(area.y, area.y + (area.height - total_lines) ÷ 2)

    # Draw visible dragon lines with fire color gradient
    for i = 1:min(visible, total_lines)
        y = start_y + i - 1
        y > bottom(area) && break
        line = lines[i]

        # The last 2 lines are the danger warning — render them differently
        is_warning = i >= total_lines - 1
        if is_warning && t > 60  # show warning after reveal completes
            # Flashing red/yellow for the danger line
            warn_color = (t ÷ 15) % 2 == 0 ? Color256(196) : Color256(226)
            style = Style(; fg = warn_color, bold = true)
        else
            # Fire gradient for dragon body, pulsing during breaths
            color_idx = mod1(t ÷ 3 + i, length(FIRE_COLORS))
            if breathing
                # Brighter cycling during fire breath
                color_idx = mod1(t ÷ 2 + i, length(FIRE_COLORS))
            end
            style = Style(; fg = Color256(FIRE_COLORS[color_idx]))
        end

        max_len = right(area) - start_x + 1
        safe_line = length(line) > max_len ? line[1:max_len] : line
        set_string!(buf, start_x, y, safe_line, style)
    end

    # Draw fire particles with varied chars
    for p in m.fire_particles
        px = Int(round(p.x)) + start_x
        py = Int(round(p.y)) + start_y
        if px >= area.x && px < right(area) && py >= area.y && py <= bottom(area)
            cidx = mod1(p.color_idx, length(FIRE_COLORS))
            # Hot particles near mouth = solid blocks, distant = lighter chars
            char_idx = if p.life > 35
                1  # █
            elseif p.life > 25
                2  # ▓
            elseif p.life > 15
                3  # ▒
            elseif p.life > 8
                4  # ░
            else
                rand(5:6)  # # or *
            end
            ch = FIRE_PARTICLE_CHARS[char_idx]
            style = Style(; fg = Color256(FIRE_COLORS[cidx]), bold = (p.life > 20))
            set_char!(buf, px, py, ch, style)
        end
    end

    # Red flash border during mega breath finale
    if t >= 360
        flash_val = val(m.animator, :dragon_flash)
        if flash_val > 0.4
            border_style = Style(; fg = Color256(196), bold = true)
            blk = Block(
                title = "DANGER",
                border_style = border_style,
                title_style = Style(; fg = Color256(226), bold = true),
                box = BOX_HEAVY,
            )
            render(blk, area, buf)
        end
    elseif breathing
        heat = val(m.animator, :dragon_heat)
        if heat > 0.6
            cidx = mod1(t ÷ 4, length(FIRE_COLORS))
            blk =
                Block(title = "", border_style = Style(; fg = Color256(FIRE_COLORS[cidx])))
            render(blk, area, buf)
        end
    end

    # Danger text overlay below the dragon (after initial reveal)
    if t > 120
        warn_y = bottom(area) - 2
        warn_msg = "YOU ARE ABOUT TO ENABLE REMOTE CODE EXECUTION"
        warn_x = area.x + max(1, (area.width - length(warn_msg)) ÷ 2)
        flash = (t ÷ 20) % 2 == 0
        warn_style = Style(; fg = flash ? Color256(196) : Color256(226), bold = true)
        if warn_y > area.y && warn_y < bottom(area)
            set_string!(buf, warn_x, warn_y, warn_msg, warn_style)
        end
    end

    set_string!(
        buf,
        area.x + 1,
        bottom(area),
        " Press any key to continue... ",
        tstyle(:text_dim),
    )
end

function view_butterfly_intro(m::SetupWizardModel, area::Rect, buf::Buffer)
    lines = split(GENTLE_BUTTERFLY_ASCII, '\n')
    total_lines = length(lines)
    reveal = val(m.animator, :butterfly_reveal)
    glow = val(m.animator, :butterfly_glow)

    # Use textwidth for proper Unicode display width
    art_width = maximum(textwidth.(lines); init = 0)
    start_x = max(area.x, area.x + (area.width - art_width) ÷ 2)
    start_y = max(area.y, area.y + (area.height - total_lines) ÷ 2)

    # Soft pastel border that breathes
    border_cidx = mod1(m.tick ÷ 8, length(BUTTERFLY_COLORS))
    border_color = BUTTERFLY_COLORS[border_cidx]
    if glow > 0.5
        blk = Block(
            title = "~",
            border_style = Style(; fg = Color256(border_color)),
            title_style = Style(; fg = Color256(border_color)),
        )
        render(blk, area, buf)
    end

    # Draw art with staggered reveal — each line fades in separately
    for (i, line) in enumerate(lines)
        # Each line has its own stagger: line i starts revealing at reveal = i/total
        line_start = (i - 1) / (total_lines + 4.0)
        line_progress = clamp((reveal - line_start) / 0.15, 0.0, 1.0)
        line_progress <= 0.0 && continue

        y = start_y + i - 1
        y > bottom(area) - 1 && break

        # Color wave: slow drift through pink/purple palette
        color_idx = mod1(m.tick ÷ 6 + i * 2, length(BUTTERFLY_COLORS))
        style = if line_progress < 1.0
            Style(; fg = Color256(BUTTERFLY_COLORS[color_idx]), dim = true)
        else
            Style(; fg = Color256(BUTTERFLY_COLORS[color_idx]))
        end

        set_string!(buf, start_x, y, line, style)
    end

    # Sparkle field — springs drive y positions, scattered across the screen
    sparkle_chars = ['✧', '⋆', '*', '.', ':', '+']
    for (si, spring) in enumerate(m.sparkle_springs)
        si > length(m.sparkle_xs) && break
        sx = area.x + 1 + mod(m.sparkle_xs[si] + m.tick ÷ 20, area.width - 2)
        raw_y = Int(round(spring.value))
        sy = area.y + 1 + mod(raw_y, max(1, area.height - 2))
        if sx >= area.x + 1 && sx < right(area) && sy >= area.y + 1 && sy < bottom(area)
            # Fade sparkles in/out based on tick
            visible = (m.tick + si * 7) % 40 < 30
            if visible
                ch = sparkle_chars[mod1(si + m.tick ÷ 12, length(sparkle_chars))]
                cidx = mod1(m.tick ÷ 4 + si * 3, length(BUTTERFLY_COLORS))
                dim = (m.tick + si * 5) % 40 > 20
                set_char!(
                    buf,
                    sx,
                    sy,
                    ch,
                    Style(; fg = Color256(BUTTERFLY_COLORS[cidx]), dim = dim),
                )
            end
        end
    end

    # Motivational text that fades in after art is revealed
    if m.tick > 140
        phrases = MOTIVATIONAL_PHRASES
        phrase_idx = mod1(m.tick ÷ 240, length(phrases))
        phrase = strip(phrases[phrase_idx])
        px = area.x + max(1, (area.width - textwidth(phrase)) ÷ 2)
        py = bottom(area) - 2
        if py > area.y
            fade = clamp((m.tick - 140) / 30.0, 0.0, 1.0)
            pstyle =
                fade < 1.0 ? Style(; fg = Color256(219), dim = true) :
                Style(; fg = Color256(219), bold = true)
            set_string!(buf, px, py, phrase, pstyle)
        end
    end

    set_string!(
        buf,
        area.x + 1,
        bottom(area),
        " Press any key to continue... ",
        tstyle(:text_dim),
    )
end

function view_neuromancer_intro(m::SetupWizardModel, area::Rect, buf::Buffer)
    # 1. Background texture — DotWave vortex, dimmed green
    render_background!(
        m.l33t_bg,
        buf,
        area,
        m.tick;
        brightness = 0.12,
        saturation = 0.3,
        speed = 0.3,
    )

    # 2. Cyber face — centered, large, fades in over first ~2s
    face_reveal = val(m.animator, :face_reveal)
    if face_reveal > 0.01
        # Size the face to fill most of the screen
        face_w = min(area.width - 4, 60)
        face_h = min(area.height - 8, 30)
        if face_w >= 10 && face_h >= 6
            face_x = area.x + (area.width - face_w) ÷ 2
            face_y = area.y + (area.height - face_h) ÷ 2 - 2
            face_area = Rect(face_x, face_y, face_w, face_h)
            render_cyber_face(m, face_area, buf)
        end
    end

    # 3. Typewriter text over the face
    if !isempty(m.typed_text)
        type_y = bottom(area) - 4
        type_x = area.x + 3
        # Draw a dim box behind the text
        for dx = 0:min(length(m.typed_target) + 4, area.width - 4)
            for dy = -1:1
                ty = type_y + dy
                tx = type_x - 1 + dx
                if ty >= area.y && ty <= bottom(area) && tx >= area.x && tx < right(area)
                    set_char!(buf, tx, ty, ' ', Style(; bg = Color256(233)))
                end
            end
        end

        set_string!(
            buf,
            type_x,
            type_y,
            m.typed_text,
            Style(; fg = Color256(46), bold = true),
        )
        # Blinking block cursor
        if m.tick % 16 < 9
            cursor_x = type_x + length(m.typed_text)
            if cursor_x < right(area)
                set_char!(buf, cursor_x, type_y, '█', Style(; fg = Color256(46)))
            end
        end
    end

    set_string!(
        buf,
        area.x + 1,
        bottom(area),
        " Press any key to continue... ",
        tstyle(:text_dim),
    )
end

# ── Acknowledge View ─────────────────────────────────────────────────────────

const ACK_WARNING_LINES = [
    "",
    "  ⚠  DANGER ZONE: REMOTE CODE EXECUTION  ⚠",
    "",
    "  This server will execute ANY code sent to it by",
    "  authenticated clients. While Kaimon includes security",
    "  features, it is still fundamentally a powerful and",
    "  potentially dangerous tool.",
    "",
    "  YOU MUST:",
    "    • Keep API keys secret and secure",
    "    • Only allow trusted IPs in production",
    "    • Understand that API keys grant FULL code",
    "      execution rights",
    "    • Take responsibility for any code executed",
    "      through this server",
    "",
]

const ACK_NEURO_WARNING_LINES = [
    "",
    "  > WARNING: UNRESTRICTED EXECUTION GATEWAY",
    "",
    "  This node runs ANY code from authenticated",
    "  connections. Kaimon has countermeasures, but",
    "  the attack surface is real.",
    "",
    "  PROTOCOL:",
    "    > Secure all API keys — leaked creds = pwned",
    "    > Lock down IPs in production — zero trust",
    "    > API keys = root access to code execution",
    "    > You own every consequence of what runs here",
    "",
]

const ACK_BUTTERFLY_WARNING_LINES = [
    "",
    "  Important Safety Information",
    "",
    "  This server will run code from connected clients.",
    "  Kaimon has protections, but please understand",
    "  the risks.",
    "",
    "  Please remember to:",
    "    ♡ Keep your API keys private and safe",
    "    ♡ Only allow trusted IPs in production",
    "    ♡ API keys grant full code execution access",
    "    ♡ You're responsible for code that runs",
    "      through this server",
    "",
]

function view_acknowledge(m::SetupWizardModel, f::Frame)
    buf = f.buffer
    area = f.area

    # Border style based on mode
    border_style = if m.mode == STANDARD
        Style(; fg = Color256(FIRE_COLORS[mod1(m.tick ÷ 4, length(FIRE_COLORS))]), bold = true)
    elseif m.mode == L33T
        Style(; fg = Color256(NEURO_GREENS[mod1(m.tick ÷ 3, length(NEURO_GREENS))]))
    else
        tstyle(:border)
    end

    title = if m.mode == STANDARD
        " ⚠ DANGER ⚠ "
    elseif m.mode == L33T
        " SECURITY CLEARANCE "
    else
        " Safety Acknowledgement "
    end

    outer = Block(
        title = title,
        border_style = border_style,
        title_style = Style(; fg = border_style.fg, bold = true),
        box = BOX_HEAVY,
    )
    inner = render(outer, area, buf)
    inner.width < 40 && return

    # Layout: warning box | typing area | hint
    rows = tsplit(Layout(Vertical, [Fill(), Fixed(5), Fixed(1)]), inner)
    length(rows) < 3 && return

    # Warning box — render text inside an inner Block that adapts to width
    warn_area = rows[1]
    warning_lines = if m.mode == STANDARD
        ACK_WARNING_LINES
    elseif m.mode == L33T
        ACK_NEURO_WARNING_LINES
    else
        ACK_BUTTERFLY_WARNING_LINES
    end

    # Inner warning Block for framing
    warn_box_style = if m.mode == STANDARD
        Style(; fg = Color256(FIRE_COLORS[mod1(m.tick ÷ 5, length(FIRE_COLORS))]), bold = true)
    elseif m.mode == L33T
        Style(; fg = Color256(NEURO_GREENS[mod1(m.tick ÷ 4, length(NEURO_GREENS))]))
    else
        Style(; fg = Color256(183))
    end

    warn_box = if m.mode == L33T
        Block(border_style = warn_box_style, box = BOX_ROUNDED)
    elseif m.mode == GENTLE
        Block(border_style = warn_box_style, box = BOX_ROUNDED)
    else
        Block(border_style = warn_box_style, box = BOX_HEAVY)
    end
    warn_inner = render(warn_box, warn_area, buf)

    # Center vertically within the inner area
    start_y = warn_inner.y + max(0, (warn_inner.height - length(warning_lines)) ÷ 2)

    for (i, line) in enumerate(warning_lines)
        y = start_y + i - 1
        y > bottom(warn_inner) && break
        y < warn_inner.y && continue

        # Color the warning lines
        style = if m.mode == STANDARD
            if i == 2  # DANGER ZONE line
                Style(; fg = Color256(m.tick % 8 < 4 ? 196 : 226), bold = true)
            elseif i == 9  # YOU MUST
                Style(; fg = Color256(51), bold = true)
            else
                Style(; fg = Color256(255))
            end
        elseif m.mode == L33T
            if i == 2  # WARNING line
                Style(; fg = Color256(46), bold = true)
            elseif i == 8  # PROTOCOL
                Style(; fg = Color256(46), bold = true)
            else
                Style(; fg = Color256(34))
            end
        else  # GENTLE
            if i == 2  # Important Safety
                Style(; fg = Color256(213), bold = true)
            elseif i == 8  # Please remember
                Style(; fg = Color256(219), bold = true)
            else
                Style(; fg = Color256(252))
            end
        end

        # Center horizontally, clamp to available width
        line_w = textwidth(line)
        start_x = warn_inner.x + max(0, (warn_inner.width - line_w) ÷ 2)
        safe_line = line_w > warn_inner.width ? line[1:warn_inner.width] : line
        set_string!(buf, start_x, y, safe_line, style)
    end

    # Typing area
    type_area = rows[2]
    progress = length(m.ack_typed) / length(m.ack_target)

    # Prompt text
    prompt = if m.mode == STANDARD
        "Hold SPACE to continue (or type 'I UNDERSTAND THE RISKS'):"
    elseif m.mode == L33T
        "> Hold SPACE for clearance (or type 'I UNDERSTAND THE RISKS'):"
    else
        "Hold SPACE to acknowledge (or type 'I UNDERSTAND THE RISKS'):"
    end

    prompt_style = if m.mode == STANDARD
        Style(; fg = Color256(196), bold = true)
    elseif m.mode == L33T
        Style(; fg = Color256(46))
    else
        Style(; fg = Color256(213), bold = true)
    end

    prompt_x = type_area.x + 2
    prompt_y = type_area.y + 1
    set_string!(buf, prompt_x, prompt_y, prompt, prompt_style)

    # Typed text display — show what they've typed so far
    typed_y = prompt_y + 1
    typed_style = if m.mode == STANDARD
        Style(; fg = Color256(226), bold = true)
    elseif m.mode == L33T
        Style(; fg = Color256(46), bold = true)
    else
        Style(; fg = Color256(219), bold = true)
    end

    # Show typed portion bright, remaining portion dim
    set_string!(buf, prompt_x, typed_y, m.ack_typed, typed_style)
    remaining = m.ack_target[nextind(m.ack_target, 0, length(m.ack_typed) + 1):end]
    dim_style = Style(; fg = Color256(240), dim = true)
    set_string!(buf, prompt_x + length(m.ack_typed), typed_y, remaining, dim_style)

    # Blinking cursor
    if m.tick % 16 < 9
        cursor_x = prompt_x + length(m.ack_typed)
        if cursor_x < right(type_area) - 1
            cursor_style = if m.mode == STANDARD
                Style(; fg = Color256(196), bold = true)
            elseif m.mode == L33T
                Style(; fg = Color256(46), bold = true)
            else
                Style(; fg = Color256(213), bold = true)
            end
            set_char!(buf, cursor_x, typed_y, '█', cursor_style)
        end
    end

    # Progress gauge at bottom of typing area
    gauge_y = typed_y + 1
    gauge_width = min(type_area.width - 4, length(m.ack_target))
    filled = round(Int, progress * gauge_width)
    gauge_x = prompt_x

    for i = 1:gauge_width
        x = gauge_x + i - 1
        x >= right(type_area) && break
        if i <= filled
            bar_style = if m.mode == STANDARD
                cidx = mod1(m.tick ÷ 3 + i, length(FIRE_COLORS))
                Style(; fg = Color256(FIRE_COLORS[cidx]), bold = true)
            elseif m.mode == L33T
                cidx = mod1(i, length(NEURO_GREENS))
                Style(; fg = Color256(NEURO_GREENS[cidx]))
            else
                cidx = mod1(i, length(BUTTERFLY_COLORS))
                Style(; fg = Color256(BUTTERFLY_COLORS[cidx]))
            end
            set_char!(buf, x, gauge_y, '█', bar_style)
        else
            set_char!(buf, x, gauge_y, '░', Style(; fg = Color256(240), dim = true))
        end
    end

    # Neuromancer: background rain
    if m.mode == L33T
        render_dim_rain(m, inner, buf)
    end

    # Hint
    hint = " Hold SPACE or type to acknowledge    Esc  quit"
    set_string!(buf, rows[3].x + 1, rows[3].y, hint, tstyle(:text_dim))
end


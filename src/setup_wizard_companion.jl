# ─────────────────────────────────────────────────────────────────────────────
# Kaimon setup wizard · companion art · cyber-face transition  (split from setup_wizard_tui.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── Companion Art ────────────────────────────────────────────────────────────

# Small butterfly shapes for gentle mode companion decoration
const SMALL_BUTTERFLY = [" _ \" _ ", "(_\\|/_)", " (/|\\) "]

function render_companion_art(m::SetupWizardModel, area::Rect, buf::Buffer)
    # L33T mode: animated halftone cyber face (bottom-right, constrained like wizard)
    if m.mode == L33T
        face_w = min(30, area.width ÷ 2)
        face_h = min(20, area.height - 2)
        face_w < 10 && return
        face_h < 6 && return
        face_area = Rect(right(area) - face_w - 1, bottom(area) - face_h, face_w, face_h)
        render_cyber_face(m, face_area, buf)
        return
    end

    # Standard + Gentle: wizard with decorations
    lines = COMPANION_WIZ

    art_height = min(length(lines), area.height - 2)
    art_width = maximum(length.(lines); init = 0)
    art_height < 3 && return
    area.width < art_width + 5 && return

    # Bottom-right placement
    start_x = right(area) - art_width - 1
    start_y = bottom(area) - art_height

    colors = m.mode == STANDARD ? WIZARD_COLORS : BUTTERFLY_COLORS

    for (i, line) in enumerate(lines)
        i > art_height && break
        y = start_y + i - 1
        y > bottom(area) && break
        cidx = mod1(m.tick ÷ 3 + i, length(colors))
        style = Style(; fg = Color256(colors[cidx]), dim = true)
        safe_line = length(line) > art_width ? line[1:art_width] : line
        set_string!(buf, start_x, y, safe_line, style)
    end

    # Gentle mode: small butterflies floating around the wizard
    if m.mode == GENTLE
        butterfly_positions = [
            (start_x - 9, start_y + 1),                          # left of wizard
            (start_x + art_width + 2, start_y + art_height ÷ 2), # right of wizard
        ]
        for (bi, (bx, by)) in enumerate(butterfly_positions)
            y_offset = ((m.tick ÷ 20 + bi * 7) % 5) - 2  # -2 to +2
            for (li, bline) in enumerate(SMALL_BUTTERFLY)
                bw = length(bline)
                draw_y = by + li - 1 + y_offset
                draw_x = bx
                draw_y < area.y && continue
                draw_y > bottom(area) && continue
                draw_x < area.x && continue
                draw_x + bw > right(area) && continue
                cidx = mod1(m.tick ÷ 5 + bi * 3 + li, length(PASTEL_COLORS))
                style = Style(; fg = Color256(PASTEL_COLORS[cidx]))
                set_string!(buf, draw_x, draw_y, bline, style)
            end
        end
    end

    # Standard mode: sparkles around the wizard
    if m.mode == STANDARD
        sparkle_chars = ['✧', '⋆', '*', '.', ':', '+']
        for si = 1:8
            sx = start_x - 3 + ((m.tick ÷ 15 + si * 11) % (art_width + 10))
            sy = start_y - 1 + ((m.tick ÷ 18 + si * 7) % (art_height + 4))
            sx < area.x && continue
            sx >= right(area) && continue
            sy < area.y && continue
            sy > bottom(area) && continue
            visible = (m.tick + si * 9) % 30 < 20
            if visible
                ch = sparkle_chars[mod1(si + m.tick ÷ 10, length(sparkle_chars))]
                cidx = mod1(m.tick ÷ 6 + si, length(WIZARD_COLORS))
                set_char!(
                    buf,
                    sx,
                    sy,
                    ch,
                    Style(; fg = Color256(WIZARD_COLORS[cidx]), dim = true),
                )
            end
        end
    end
end

# ── Cyber Face Transition Logic ───────────────────────────────────────────────

const FACE_MEAN_INTERVAL = 300        # mean frames between switches (~5s), Poisson

function _poisson_next_interval()
    # Exponential distribution for Poisson process inter-arrival times
    # Clamp to reasonable range: 2-10 seconds (120-600 frames)
    clamp(round(Int, -FACE_MEAN_INTERVAL * log(max(1e-10, rand()))), 120, 600)
end

# Random transition duration: short base (6-18 frames, ~0.1-0.3s)
_rand_transition_duration() = rand(6:18)

function _update_face_transition!(m::SetupWizardModel)
    m.mode != L33T && return
    isempty(m.face_params) && return

    if m.face_transition_start > 0
        elapsed = m.tick - m.face_transition_start
        if elapsed >= m.face_transition_duration
            m.face_transition_start = 0
            m.face_next_switch = m.tick + _poisson_next_interval()
        end
    elseif m.tick >= m.face_next_switch
        m.face_params_prev = copy(m.face_params)
        m.face_params = _randomize_face_params!()
        m.face_transition_start = m.tick
        m.face_transition_duration = _rand_transition_duration()
    end
end

# Halftone character sets for L33T mode face rendering
const CYBER_CHARS = [' ', '.', ':', ';', '1', 'x', '0', 'X', '#', '@']

# Signed distance field for a human face shape
# p contains randomized parameters for per-session variation
# Returns density 0..1 where 1 = brightest
function _face_density(fx::Float64, fy::Float64, p::Dict{Symbol,Float64})
    cx = fx - 0.5
    cy = fy - 0.38

    # Head: wider at temples, tapered jaw/chin
    jt = get(p, :jaw_taper, 0.40)
    jaw_taper = cy > 0.08 ? 1.0 - jt * min(1.0, max(0.0, (cy - 0.08) / 0.42))^0.6 : 1.0
    hrx = get(p, :head_rx, 0.28) * jaw_taper
    head_ry = 0.52
    hrx < 0.01 && return 0.0
    head_d = (cx / hrx)^2 + (cy / head_ry)^2
    head_d > 1.0 && return 0.0

    sd = sqrt(head_d)  # 0 at center, 1 at boundary

    # Smooth density falloff
    density = (1.0 - head_d^0.3) * 0.70

    # Subtle inner contour — thin brightness bump for face edge detail
    contour_dist = abs(sd - 0.65)
    contour_dist < 0.03 && (density += 0.10 * (1.0 - contour_dist / 0.03))

    # Forehead highlight
    cy < -0.18 && (density = min(1.0, density + 0.08 * max(0.0, 1.0 - abs(cx) / 0.16)))

    # Brow ridge — bright horizontal band (scaled to head width)
    brow_y = get(p, :brow_y, -0.08)
    if abs(cy - brow_y) < 0.022 && abs(cx) < hrx * 0.9
        s = max(0.0, 1.0 - abs(cx) / (hrx * 0.9)) * max(0.0, 1.0 - abs(cy - brow_y) / 0.022)
        density = min(1.0, density + 0.20 * s)
    end

    # Under-brow shadow
    ub_top = brow_y + 0.01
    ub_bot = brow_y + 0.05
    if cy > ub_top && cy < ub_bot && abs(cx) > 0.04 && abs(cx) < hrx * 0.85
        shadow = max(0.0, 1.0 - (cy - ub_bot) / (ub_top - ub_bot))
        density *= (0.5 + 0.5 * (1.0 - shadow))
    end

    # Eyes — subtle darkening, not deep black
    eye_cy = 0.0
    eye_h = get(p, :eye_h, 0.035)
    eye_w = get(p, :eye_w, 0.055)
    eye_sep = get(p, :eye_sep, 0.10)
    for side in (-1.0, 1.0)
        ex = cx - side * eye_sep
        ey = cy - eye_cy
        ed = (ex / eye_w)^2 + (ey / eye_h)^2
        if ed < 1.0
            # Gentle shading — darkens toward center but doesn't go black
            density *= (0.3 + 0.7 * ed)
        end
    end

    # Nose bridge highlight
    nose_tip_y = get(p, :nose_len, 0.17)
    nose_w = get(p, :nose_w, 0.030)
    if cy > 0.02 && cy < nose_tip_y + 0.01
        t_n = (cy - 0.02) / max(0.01, nose_tip_y - 0.01)
        nw = 0.016 + 0.024 * t_n
        if abs(cx) < nw
            ridge = max(0.0, 1.0 - abs(cx) / (nw * 0.5))
            density = max(density, density * 0.8 + 0.13 * ridge)
        end
        if abs(cx) > nw && abs(cx) < nw + 0.04
            ns = max(0.0, 1.0 - (abs(cx) - nw) / 0.04)
            density *= (0.65 + 0.35 * (1.0 - ns))
        end
    end

    # Nose tip
    nt_d = (cx / nose_w)^2 + ((cy - nose_tip_y) / 0.02)^2
    nt_d < 1.0 && (density = min(1.0, density + 0.15 * (1.0 - nt_d)))

    # Nostrils
    for side in (-1.0, 1.0)
        nd = ((cx - side * 0.025) / 0.015)^2 + ((cy - nose_tip_y - 0.02) / 0.012)^2
        nd < 1.0 && (density *= 0.1)
    end

    # Nasolabial folds (scaled)
    for side in (-1.0, 1.0)
        if cy > 0.10 && cy < 0.28
            t_f = max(0.0, (cy - 0.10) / 0.18)
            fold_x = side * (0.03 + 0.07 * sqrt(t_f))
            fd = abs(cx - fold_x)
            fd < 0.010 && (density *= (0.6 + 0.4 * fd / 0.010))
        end
    end

    # Philtrum
    mouth_y = get(p, :mouth_y, 0.26)
    if cy > mouth_y - 0.07 && cy < mouth_y - 0.02 && abs(cx) < 0.012
        density *= 0.7
    end

    # Upper lip (scaled)
    lip_w = get(p, :lip_w, 0.08)
    cupid = 0.004 * cos(cx / 0.028 * pi)
    if abs(cy - (mouth_y - 0.015) - cupid) < 0.01 && abs(cx) < lip_w
        le = max(0.0, 1.0 - abs(cx) / lip_w)
        density = min(1.0, max(density, 0.4 * le + 0.30))
    end

    # Mouth gap
    if abs(cy - mouth_y) < 0.007 && abs(cx) < lip_w * 0.77
        density *= 0.05
    end

    # Lower lip
    if abs(cy - (mouth_y + 0.015)) < 0.012 && abs(cx) < lip_w * 0.77
        le = max(0.0, 1.0 - abs(cx) / (lip_w * 0.77))
        density = min(1.0, density + 0.14 * le)
    end

    # Chin highlight (scaled)
    chin_y = get(p, :chin_y, 0.36)
    cd = (cx / 0.04)^2 + ((cy - chin_y) / 0.035)^2
    cd < 1.0 && (density = min(1.0, density + 0.12 * (1.0 - cd)))

    # Cheekbone highlights (scaled to head)
    cheek_x = get(p, :cheek_x, 0.17)
    for side in (-1.0, 1.0)
        chd = ((cx - side * cheek_x) / 0.06)^2 + ((cy + 0.0) / 0.08)^2
        chd < 1.0 && (density = min(1.0, density + 0.14 * (1.0 - chd)))
    end

    # Temple shadows (scaled)
    for side in (-1.0, 1.0)
        td = ((cx - side * 0.22) / 0.05)^2 + ((cy + 0.02) / 0.10)^2
        td < 1.0 && (density *= (0.5 + 0.5 * td))
    end

    # Jaw edge
    if cy > 0.18 && head_d > 0.65
        density *= max(0.45, 1.0 - (head_d - 0.65) / 0.35 * 0.35)
    end

    return clamp(density, 0.0, 1.0)
end

# Cable attachment points on the head boundary (normalized coords, scaled to head_rx=0.28)
# Each cable: (head_x, head_y, direction_angle, length_fraction)
const CABLE_ANCHORS = [
    (0.22, 0.0, -0.3, 0.9),    # right temple, angling up-right
    (0.20, 0.12, -0.1, 0.8),   # right cheek, angling right
    (0.15, 0.24, 0.2, 0.7),    # right jaw, angling down-right
    (-0.22, 0.0, -2.8, 0.9),   # left temple, angling up-left
    (-0.20, 0.12, -3.0, 0.8),  # left cheek, angling left
    (-0.15, 0.24, 2.9, 0.7),   # left jaw, angling down-left
    (0.04, -0.38, -1.3, 0.6),  # top of head right, angling up
    (-0.04, -0.38, -1.8, 0.6), # top of head left, angling up
]

# Blue color palette for cables (deep blue to moderate sky, not too bright)
const CABLE_BLUES = (17, 18, 19, 20, 25, 26, 27, 33, 39, 75)

# Animated halftone cyber face with data cables for L33T companion area
function render_cyber_face(m::SetupWizardModel, area::Rect, buf::Buffer)
    area.width < 8 && return
    area.height < 5 && return

    t = m.tick / 60.0
    p = m.face_params

    # Bitrot transition state
    in_transition = m.face_transition_start > 0
    transition_frac =
        in_transition ?
        clamp((m.tick - m.face_transition_start) / m.face_transition_duration, 0.0, 1.0) :
        0.0
    p_prev = m.face_params_prev

    # Scan line sweeping down (faster during transition)
    scan_speed = in_transition ? 2 : 4
    scan_row = (m.tick ÷ scan_speed) % (area.height + 6) - 3

    # --- Render cables first (behind face) ---
    cx_mid = area.width / 2.0
    cy_mid = area.height * 0.38  # face center offset
    for (ci, (ax, ay, angle, len_frac)) in enumerate(CABLE_ANCHORS)
        # Cable start in pixel coords
        sx = area.x + round(Int, cx_mid + ax * area.width)
        sy = area.y + round(Int, cy_mid + ay * area.height)
        # Cable extends outward
        cable_len = round(Int, len_frac * min(area.width, area.height) * 0.5)
        cable_len < 3 && continue
        for seg = 1:cable_len
            frac = seg / cable_len
            # Slight curve: cable bends under gravity
            sag = 0.15 * frac^2 * area.height
            px = sx + round(Int, seg * cos(angle) * 1.5)
            py = sy + round(Int, seg * sin(angle) + sag)

            # Smooth wavelike pulse — regular sine wave traveling outward
            wave = (sin(frac * 8.0 - t * 2.5 + ci * 0.8) + 1.0) * 0.5
            wave2 = (sin(frac * 16.0 - t * 4.0 + ci * 1.3) + 1.0) * 0.25
            pulse = wave * 0.7 + wave2 * 0.3
            fade = 1.0 - frac * 0.5
            brightness = pulse * fade
            brightness < 0.08 && continue

            data_chars = ('0', '1', '.', ':', '1', '0', 'x')
            char_idx = ((seg + m.tick ÷ 3 + ci * 5) % length(data_chars)) + 1
            ch = data_chars[char_idx]
            bi = clamp(
                round(Int, brightness * (length(CABLE_BLUES) - 1)) + 1,
                1,
                length(CABLE_BLUES),
            )
            style = Style(; fg = Color256(CABLE_BLUES[bi]), dim = brightness < 0.3)

            # Draw cable 2 pixels wide (perpendicular to cable direction)
            perp_x = round(Int, -sin(angle))
            perp_y = round(Int, cos(angle))
            for offset in (0, 1)
                cx2 = px + offset * perp_x
                cy2 = py + offset * perp_y
                cx2 < area.x && continue
                cx2 >= right(area) && continue
                cy2 < area.y && continue
                cy2 > bottom(area) && continue
                set_char!(buf, cx2, cy2, ch, style)
            end
        end
    end

    # Glitch scan band — 3 rows that sweep down with displacement + noise + desaturation
    # Grayscale palette for scan glitch (232-255 are grays in xterm-256)
    scan_grays = (240, 244, 248, 252, 255, 252, 248)  # dark→bright→dark

    # --- Render face (on top of cables) ---
    for dy = 0:(area.height-1)
        y = area.y + dy
        y > bottom(area) && break
        fy = dy / max(1, area.height - 1)

        # Scan band: 2 rows with glitch effects
        scan_dist = dy - scan_row
        in_scan = scan_dist == 0 || scan_dist == 1

        # Horizontal glitch — subtle during transition, not disruptive
        hash_v = ((dy * 7 + m.tick * 13) % 97)
        glitch_thresh = in_transition ? 10 + round(Int, 15 * sin(transition_frac * pi)) : 6
        base_shift = sin(t * 5.0 + dy * 0.3) * (in_transition ? 2.0 : 2.0)

        # Scan band gets extra horizontal displacement
        if in_scan
            scan_shift = round(Int, sin(t * 8.0 + scan_dist * 2.0) * (4.0 + abs(scan_dist)))
            x_shift = scan_shift
        else
            x_shift = hash_v < glitch_thresh ? round(Int, base_shift) : 0
        end

        for dx = 0:(area.width-1)
            x = area.x + dx
            x >= right(area) && break

            # Sample with glitch offset
            fx = (dx - x_shift) / max(1, area.width - 1)

            if in_transition && !isempty(p_prev)
                # Crossfade between old and new face — never obliterate
                d_new = _face_density(fx, fy, p)
                d_old = _face_density(fx, fy, p_prev)
                density = d_old * (1.0 - transition_frac) + d_new * transition_frac
                # Subtle noise perturbation during transition
                pixel_hash = (dx * 73 + dy * 137 + m.tick * 11) % 100
                if pixel_hash < 12
                    density = clamp(density + (pixel_hash / 100.0 - 0.06) * 0.2, 0.0, 1.0)
                end
            else
                density = _face_density(fx, fy, p)
            end

            # Edge dissolution
            if density > 0.0 && density < 0.4
                noise = sin(fx * 25.0 + t * 2.0) * cos(fy * 18.0 + t * 1.3) * 0.25
                density = clamp(density + noise * (1.0 - density * 2.5), 0.0, 1.0)
            end

            # Scan band effects: noise injection + dropout
            if in_scan
                scan_noise = ((dx * 41 + dy * 23 + m.tick * 17) % 67) / 67.0
                if scan_noise < 0.15  # 15% dropout
                    continue
                end
                # Inject noise into density
                density = clamp(density + (scan_noise - 0.5) * 0.3, 0.0, 1.0)
            end

            density < 0.05 && continue

            # Map to cyber character
            cci = round(Int, density * (length(CYBER_CHARS) - 1)) + 1
            ch = CYBER_CHARS[cci]
            ch == ' ' && continue

            # Char glitch — subtle during transition, not obliterating
            glitch_rate = in_transition ? 8 : (in_scan ? 8 : 3)
            hash2 = (dx * 31 + dy * 17 + m.tick * 7) % 200
            if hash2 < glitch_rate
                glitch_pool = ('0', '1', 'x', 'F', 'A', 'E', 'C')
                ch = glitch_pool[hash2%length(glitch_pool)+1]
            end

            # Color: desaturate toward gray during transition, scan band always gray
            if in_scan
                si = clamp(
                    round(Int, density * (length(scan_grays) - 1)) + 1,
                    1,
                    length(scan_grays),
                )
                set_char!(buf, x, y, ch, Style(; fg = Color256(scan_grays[si])))
            elseif in_transition
                # Desaturation peaks at midpoint of transition (sin curve)
                desat = sin(transition_frac * pi) * 0.85
                gi = round(Int, density * (length(NEURO_GREENS) - 1)) + 1
                # Blend: green palette → grayscale palette
                green_c = NEURO_GREENS[gi]
                gray_i = clamp(round(Int, density * 6) + 1, 1, length(scan_grays))
                gray_c = scan_grays[gray_i]
                # Pick green or gray based on desat probability per-pixel
                desat_hash = (dx * 19 + dy * 43 + m.tick * 3) % 100
                color = desat_hash < round(Int, desat * 100) ? gray_c : green_c
                dim = density < 0.3
                set_char!(buf, x, y, ch, Style(; fg = Color256(color), dim = dim))
            else
                gi = round(Int, density * (length(NEURO_GREENS) - 1)) + 1
                dim = density < 0.3
                set_char!(
                    buf,
                    x,
                    y,
                    ch,
                    Style(; fg = Color256(NEURO_GREENS[gi]), dim = dim),
                )
            end
        end
    end
end

# ── Dim Rain Background (Neuromancer config steps) ──────────────────────────

function render_dim_rain(m::SetupWizardModel, area::Rect, buf::Buffer)
    # Very sparse rain — only every 4th column, so it doesn't obscure config text
    for col_idx = 1:4:min(length(m.rain_columns), area.width)
        x = area.x + col_idx - 1
        col_y = m.rain_columns[col_idx]
        y = area.y + col_y % area.height
        if y >= area.y && y <= bottom(area) && x >= area.x && x < right(area)
            set_char!(buf, x, y, '.', Style(; fg = Color256(NEURO_GREENS[1]), dim = true))
        end
    end
end

# ── Helper Functions ─────────────────────────────────────────────────────────

function phase_title(m::SetupWizardModel)
    titles = Dict(
        PHASE_SECURITY_MODE => " Security Mode ",
        PHASE_PORT => " Server Port ",
        PHASE_API_KEY_GEN => " API Key ",
        PHASE_QUICK_OR_ADV => " Save Options ",
        PHASE_IP_ALLOWLIST => " IP Allowlist ",
        PHASE_INDEX_DIRS => " Index Directories ",
        PHASE_SUMMARY => " Summary ",
        PHASE_GATE => " Auto-connect ",
        PHASE_SAVING => " Saving ",
    )
    get(titles, m.phase, " Setup ")
end

function step_title_text(m::SetupWizardModel)
    texts = Dict(
        PHASE_SECURITY_MODE => "MODE",
        PHASE_PORT => "PORT",
        PHASE_API_KEY_GEN => "KEY",
        PHASE_QUICK_OR_ADV => "SAVE",
        PHASE_IP_ALLOWLIST => "IPS",
        PHASE_INDEX_DIRS => "DIRS",
        PHASE_SUMMARY => "REVIEW",
        PHASE_GATE => "CONNECT",
        PHASE_SAVING => "SAVE",
    )
    get(texts, m.phase, "SETUP")
end

function step_hints(m::SetupWizardModel)
    hints = Dict(
        PHASE_SECURITY_MODE => " Up/Down  select    Enter  confirm    Esc  quit",
        PHASE_PORT => " Enter  confirm    Esc  quit",
        PHASE_API_KEY_GEN => " Enter  continue    [c]  copy key    Esc  quit",
        PHASE_QUICK_OR_ADV => " Enter  save defaults    [a]  advanced    Esc  quit",
        PHASE_IP_ALLOWLIST => " Enter  add/continue    Up/Down  select    [d]  remove    Esc  quit",
        PHASE_INDEX_DIRS => " Enter  add/continue    Up/Down  select    [d]  remove    Esc  quit",
        PHASE_SUMMARY => " Left/Right  toggle    Enter  confirm    Esc  quit",
        PHASE_GATE => " Up/Down  select    Enter  confirm    Esc  quit",
        PHASE_SAVING => " Saving...",
    )
    get(hints, m.phase, " Esc  quit")
end

function mode_flavor_text(m::SetupWizardModel)
    if m.mode == STANDARD
        Dict(
            :strict => "Fortify the castle gates",
            :relaxed => "Lower the drawbridge",
            :lax => "Brave, or foolish?",
            :api_key => "Guard this with your life!",
            :gate_tagline => "Summon every session to the gate.",
            :gate_yes => "Open the gate — every REPL answers the call",
            :gate_no => "Hold the gate shut, for now",
            :gate_never => "Seal it — you'll raise the gate by hand",
        )
    elseif m.mode == GENTLE
        Dict(
            :strict => "Maximum protection for safety",
            :relaxed => "Flexible but secure",
            :lax => "Simple and local",
            :api_key => "Keep this safe and sound!",
            :gate_tagline => "Let every session find its way home.",
            :gate_yes => "Yes please — connect them all for me",
            :gate_no => "Maybe later — leave things as they are",
            :gate_never => "No thanks — I'll connect when I want",
        )
    else
        Dict(
            :strict => "Full ICE deployment",
            :relaxed => "Partial countermeasures",
            :lax => "Running dark - local only",
            :api_key => "Don't let it leak into the matrix",
            :gate_tagline => "Jack every session into the grid.",
            :gate_yes => "Wire the rig — auto-jack every console",
            :gate_no => "Hold — stay off the grid for now",
            :gate_never => "Run dark — manual jack only",
        )
    end
end

# ── Public API ───────────────────────────────────────────────────────────────

"""
    setup_wizard_tui(; mode::Symbol=:auto)

Launch the animated TUI setup wizard for Kaimon security configuration.

# Modes
- `:auto` — show personality selector (Standard, Gentle, L33T)
- `:standard` — dramatic fire-breathing dragon intro
- `:gentle` — gentle sparkles and supportive messages
- `:l33t` — cyberpunk matrix rain aesthetic

Configuration is saved globally to `~/.config/kaimon/config.json`.
"""
function _randomize_face_params!()
    Dict{Symbol,Float64}(
        :eye_sep => 0.10 + (rand() - 0.5) * 0.015,       # 0.0925..0.1075
        :eye_w => 0.055 + (rand() - 0.5) * 0.01,        # 0.05..0.06
        :eye_h => 0.035 + (rand() - 0.5) * 0.008,       # 0.031..0.039
        :brow_y => -0.08 + (rand() - 0.5) * 0.02,       # -0.09..-0.07
        :nose_w => 0.030 + (rand() - 0.5) * 0.008,      # 0.026..0.034
        :nose_len => 0.17 + (rand() - 0.5) * 0.02,      # 0.16..0.18
        :lip_w => 0.08 + (rand() - 0.5) * 0.02,         # 0.07..0.09
        :mouth_y => 0.26 + (rand() - 0.5) * 0.01,       # 0.255..0.265
        :chin_y => 0.36 + (rand() - 0.5) * 0.02,        # 0.35..0.37
        :cheek_x => 0.17 + (rand() - 0.5) * 0.02,       # 0.16..0.18
        :jaw_taper => 0.40 + (rand() - 0.5) * 0.06,     # 0.37..0.43
        :head_rx => 0.28 + (rand() - 0.5) * 0.02,       # 0.27..0.29
    )
end

function setup_wizard_tui(; mode::Symbol = :auto)
    model = SetupWizardModel()
    model.face_params = _randomize_face_params!()

    if mode != :auto
        mode_map = Dict(:standard => STANDARD, :gentle => GENTLE, :l33t => L33T)
        if haskey(mode_map, mode)
            model.mode = mode_map[mode]
            enter_phase!(model, PHASE_INTRO_ANIM)
        end
    end

    app(model; fps = 60)
    # The TUI has closed — apply the gate auto-connect choice here, in the
    # console, where the (slow) Pkg work and its output belong.
    if model.save_success
        _apply_wizard_gate_choice!(model.gate_choice)
        return load_global_config()
    end
    return nothing
end

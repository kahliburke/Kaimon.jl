# ─────────────────────────────────────────────────────────────────────────────
# Kaimon setup wizard · update · tick animations · config saving  (split from setup_wizard_tui.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── Update ───────────────────────────────────────────────────────────────────

function Tachikoma.update!(m::SetupWizardModel, evt::KeyEvent)
    # Escape always quits
    if evt.key == :escape
        m.quit = true
        return
    end

    if m.phase == PHASE_MODE_SELECT
        update_mode_select!(m, evt)
    elseif m.phase == PHASE_INTRO_ANIM
        # Any key skips intro
        m.intro_done = true
        advance_phase!(m)
    elseif m.phase == PHASE_ACKNOWLEDGE
        update_acknowledge!(m, evt)
    elseif m.phase == PHASE_SECURITY_MODE
        update_security_mode!(m, evt)
    elseif m.phase == PHASE_PORT
        update_port!(m, evt)
    elseif m.phase == PHASE_API_KEY_GEN
        update_api_key!(m, evt)
    elseif m.phase == PHASE_QUICK_OR_ADV
        update_quick_or_adv!(m, evt)
    elseif m.phase == PHASE_IP_ALLOWLIST
        update_ip_allowlist!(m, evt)
    elseif m.phase == PHASE_INDEX_DIRS
        update_index_dirs!(m, evt)
    elseif m.phase == PHASE_SUMMARY
        update_summary!(m, evt)
    elseif m.phase == PHASE_GATE
        update_gate!(m, evt)
    elseif m.phase == PHASE_SAVING
        # No user input during save
    elseif m.phase == PHASE_DONE
        # Any key exits
        m.quit = true
    end
end

function update_mode_select!(m::SetupWizardModel, evt::KeyEvent)
    if evt.key == :left || evt.key == :up
        m.mode_selected = mod1(m.mode_selected - 1, 3)
    elseif evt.key == :right || evt.key == :down
        m.mode_selected = mod1(m.mode_selected + 1, 3)
    elseif evt.key == :enter
        m.mode = [STANDARD, GENTLE, L33T][m.mode_selected]
        advance_phase!(m)
    end
end

function update_acknowledge!(m::SetupWizardModel, evt::KeyEvent)
    target = m.ack_target
    typed = m.ack_typed

    if evt.key == :char && evt.char == ' '
        # Spacebar auto-types the next character of the target
        if length(typed) < length(target)
            m.ack_typed = typed * string(target[nextind(target, 0, length(typed) + 1)])
        end
        if m.ack_typed == target
            advance_phase!(m)
        end
    elseif evt.key == :backspace
        if !isempty(typed)
            m.ack_typed = typed[1:prevind(typed, lastindex(typed))]
        end
    elseif evt.key == :enter
        if m.ack_typed == target
            advance_phase!(m)
        end
    elseif evt.key == :char && isprint(evt.char)
        # Manual typing — accept if it matches the target so far
        next_pos = length(typed) + 1
        if next_pos <= length(target)
            expected = uppercase(target[nextind(target, 0, next_pos)])
            if uppercase(evt.char) == expected
                m.ack_typed = typed * string(target[nextind(target, 0, next_pos)])
                if m.ack_typed == target
                    advance_phase!(m)
                end
            end
        end
    end
end

function update_security_mode!(m::SetupWizardModel, evt::KeyEvent)
    if evt.key == :up
        m.sec_mode_selected = max(1, m.sec_mode_selected - 1)
    elseif evt.key == :down
        m.sec_mode_selected = min(3, m.sec_mode_selected + 1)
    elseif evt.key == :enter
        m.sec_mode = [:strict, :relaxed, :lax][m.sec_mode_selected]
        advance_phase!(m)
    end
end

function update_port!(m::SetupWizardModel, evt::KeyEvent)
    if evt.key == :enter
        port_str = Tachikoma.text(m.port_input)
        port_val = tryparse(Int, port_str)
        if port_val !== nothing && 1024 <= port_val <= 65535
            m.port = port_val
            advance_phase!(m)
        else
            # Reset to default on invalid input
            m.port_input = TextInput(text = "2828", label = "Port: ")
        end
    else
        handle_key!(m.port_input, evt)
    end
end

function update_api_key!(m::SetupWizardModel, evt::KeyEvent)
    if evt.key == :enter
        advance_phase!(m)
    elseif evt.key == :char && evt.char == 'c'
        try
            clipboard_cmd =
                Sys.isapple() ? `pbcopy` :
                Sys.islinux() ? (haskey(ENV, "WAYLAND_DISPLAY") ? `wl-copy` : `xclip -selection clipboard`) :
                nothing
            if clipboard_cmd !== nothing
                open(clipboard_cmd, "w") do io
                    print(io, m.api_key)
                end
                m.api_key_copied = true
            end
        catch
            # Clipboard not available
        end
    end
end

function update_quick_or_adv!(m::SetupWizardModel, evt::KeyEvent)
    if evt.key == :enter
        m.advanced = false
        advance_phase!(m)
    elseif evt.key == :char && evt.char == 'a'
        m.advanced = true
        advance_phase!(m)
    end
end

function update_ip_allowlist!(m::SetupWizardModel, evt::KeyEvent)
    if evt.key == :enter
        ip_str = strip(Tachikoma.text(m.ip_input))
        if isempty(ip_str)
            # Empty enter advances to next phase
            advance_phase!(m)
        else
            # Validate and add IP
            if occursin(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$", ip_str) ||
               occursin(r"^[0-9a-fA-F:]+$", ip_str)
                push!(m.allowed_ips, ip_str)
                m.ip_input = TextInput(text = "", label = "IP: ")
            end
        end
    elseif evt.key == :char && evt.char == 'd' && !isempty(m.allowed_ips)
        # Delete selected IP (but protect localhost entries)
        if m.ip_list_selected <= length(m.allowed_ips)
            ip = m.allowed_ips[m.ip_list_selected]
            if ip != "127.0.0.1" && ip != "::1"
                deleteat!(m.allowed_ips, m.ip_list_selected)
                m.ip_list_selected = min(m.ip_list_selected, max(1, length(m.allowed_ips)))
            end
        end
    elseif evt.key == :up
        m.ip_list_selected = max(1, m.ip_list_selected - 1)
    elseif evt.key == :down
        m.ip_list_selected = min(length(m.allowed_ips), m.ip_list_selected + 1)
    else
        handle_key!(m.ip_input, evt)
    end
end

function update_index_dirs!(m::SetupWizardModel, evt::KeyEvent)
    if evt.key == :enter
        dir_str = strip(Tachikoma.text(m.index_input))
        if isempty(dir_str)
            advance_phase!(m)
        else
            push!(m.index_dirs, dir_str)
            m.index_input = TextInput(text = "", label = "Dir: ")
        end
    elseif evt.key == :char && evt.char == 'd' && !isempty(m.index_dirs)
        if m.index_list_selected <= length(m.index_dirs)
            deleteat!(m.index_dirs, m.index_list_selected)
            m.index_list_selected = min(m.index_list_selected, max(1, length(m.index_dirs)))
        end
    elseif evt.key == :up
        m.index_list_selected = max(1, m.index_list_selected - 1)
    elseif evt.key == :down
        m.index_list_selected = min(max(1, length(m.index_dirs)), m.index_list_selected + 1)
    else
        handle_key!(m.index_input, evt)
    end
end

function update_summary!(m::SetupWizardModel, evt::KeyEvent)
    if evt.key == :left || evt.key == :right
        m.summary_selected = m.summary_selected == :confirm ? :cancel : :confirm
    elseif evt.key == :enter
        if m.summary_selected == :confirm
            advance_phase!(m)
        else
            m.quit = true
        end
    end
end

# ── Tick-based animation updates (called from view) ─────────────────────────

function update_gate!(m::SetupWizardModel, evt::KeyEvent)
    if evt.key == :up
        m.gate_selected = max(1, m.gate_selected - 1)
    elseif evt.key == :down
        m.gate_selected = min(3, m.gate_selected + 1)
    elseif evt.key == :enter
        m.gate_choice = [:yes, :no, :never][m.gate_selected]
        advance_phase!(m)
    end
end

function update_animations!(m::SetupWizardModel)
    tick!(m.animator)

    if m.phase == PHASE_INTRO_ANIM && !m.intro_done
        if m.mode == STANDARD
            update_dragon_anim!(m)
        elseif m.mode == GENTLE
            update_butterfly_anim!(m)
        elseif m.mode == L33T
            update_neuromancer_anim!(m)
        end

        # Auto-advance after animation duration
        max_frames = m.mode == STANDARD ? 480 : m.mode == L33T ? 360 : 480
        if m.tick >= max_frames
            m.intro_done = true
            advance_phase!(m)
        end
    elseif m.phase == PHASE_ACKNOWLEDGE && m.mode == L33T
        # Keep rain falling during acknowledge screen
        for i in eachindex(m.rain_columns)
            m.rain_columns[i] += 1
            if m.tick % 3 == 0
                m.rain_chars[i] = rand([
                    '0',
                    '1',
                    'ﾊ',
                    'ﾐ',
                    'ﾋ',
                    'ｰ',
                    'ｳ',
                    'ｼ',
                    'ﾅ',
                    'ﾓ',
                    'ﾆ',
                    'ｻ',
                    'ﾜ',
                    'ﾂ',
                    'ｵ',
                    'ﾘ',
                    'ｱ',
                    'ｶ',
                ])
            end
        end
    elseif m.phase == PHASE_SAVING
        m.save_progress = val(m.animator, :save_gauge)
        # At midpoint, perform save
        if m.tick == 45 && !m.save_done
            m.save_done = true
            do_save!(m)
        end
        # Auto-advance when gauge completes
        if m.tick >= 90
            advance_phase!(m)
        end
    end
end

const FIRE_PARTICLE_CHARS = ['█', '▓', '▒', '░', '#', '*']

function update_dragon_anim!(m::SetupWizardModel)
    t = m.tick
    # Convert 1-indexed art coords to 0-indexed offsets from start_x/start_y
    _row, _col = _detect_dragon_mouth()
    mouth_row = _row - 1
    mouth_col = _col - 1

    # Three breath cycles with escalating intensity
    # Breath 1 (frames 80-170):  proving the dragon is alive
    # Breath 2 (frames 200-310): bigger, wider cone
    # Breath 3 (frames 340-480): massive wall of fire
    intensity = if 80 <= t <= 170
        clamp((t - 80) / 30.0, 0.0, 1.0)
    elseif 200 <= t <= 310
        clamp((t - 200) / 25.0, 0.0, 1.3)
    elseif 340 <= t <= 480
        min(2.0, clamp((t - 340) / 15.0, 0.0, 2.0))
    else
        0.0
    end

    if intensity > 0
        n_particles = max(1, Int(round(intensity * 7)))
        for _ = 1:n_particles
            spread = intensity * 2.0
            push!(
                m.fire_particles,
                FireParticle(
                    Float64(mouth_col) + rand(-1.0:0.5:1.0),  # spawn AT the mouth
                    Float64(mouth_row) + rand(-spread:0.3:spread),
                    rand(1:length(FIRE_COLORS)),
                    rand(20:50),
                    -rand(0.8:0.2:3.0) * (0.6 + intensity * 0.5),  # stream LEFT
                    rand(-0.3:0.05:0.3),
                ),
            )
        end
    end

    # Lingering smoke between breaths
    for gap_start in (171, 311)
        if t in gap_start:gap_start+5
            for _ = 1:2
                push!(
                    m.fire_particles,
                    FireParticle(
                        Float64(mouth_col - rand(5:15)),
                        Float64(mouth_row) + rand(-3.0:0.5:3.0),
                        1,
                        rand(30:60),
                        -rand(0.2:0.1:0.6),
                        rand(-0.2:0.05:0.2),
                    ),
                )
            end
        end
    end

    # Update existing particles
    new_particles = FireParticle[]
    for p in m.fire_particles
        if p.life > 1
            fade_rate = p.life < 15 ? 1 : (p.life < 8 ? 2 : 0)
            new_color = max(1, p.color_idx - fade_rate)
            push!(
                new_particles,
                FireParticle(
                    p.x + p.dx,
                    p.y + p.dy,
                    new_color,
                    p.life - 1,
                    p.dx * 0.97,
                    p.dy + rand(-0.06:0.02:0.06),
                ),
            )
        end
    end
    m.fire_particles = new_particles
end

function update_butterfly_anim!(m::SetupWizardModel)
    for s in m.sparkle_springs
        advance!(s)
    end
    # Retarget springs every 45 frames for continuous gentle motion
    if m.tick > 0 && m.tick % 45 == 0
        for s in m.sparkle_springs
            retarget!(s, Float64(rand(2:28)))
        end
    end
end

function update_neuromancer_anim!(m::SetupWizardModel)
    # Typewriter effect: 1 char per 3 frames, starting at frame 90
    if m.tick >= 90 && m.typed_index < length(m.typed_target)
        if (m.tick - 90) % 3 == 0
            m.typed_index += 1
            m.typed_text = m.typed_target[1:m.typed_index]
        end
    end
end

# ── Config Saving ────────────────────────────────────────────────────────────

const _PERSONALITY_MAP = Dict(STANDARD => "dragon", GENTLE => "butterfly", L33T => "l33t")

function _save_personality(config_path::String, mode::WizardMode)
    try
        data = JSON.parse(read(config_path, String); dicttype = Dict{String,Any})
        data["personality"] = _PERSONALITY_MAP[mode]
        write(config_path, JSON.json(data, 2))
    catch
    end
end

function do_save!(m::SetupWizardModel)
    if m._render_mode
        m.save_done = true
        m.save_success = true
        m.save_message = "(render mode — no config written)"
        return
    end
    try
        api_keys = m.sec_mode == :lax ? String[] : [m.api_key]
        config = SecurityConfig(
            m.sec_mode,
            api_keys,
            m.allowed_ips,
            m.port,
        )
        global_path = get_global_config_path()
        global_dir = dirname(global_path)
        if !isdir(global_dir)
            mkpath(global_dir)
        end
        save_global_config(config)
        # Save personality mode as extra metadata in the config JSON
        _save_personality(global_path, m.mode)
        # Persist the theme matching the personality
        theme_name = m.mode == STANDARD ? "kaneda" : m.mode == GENTLE ? "catppuccin" : "neuromancer"
        Tachikoma.save_theme(theme_name)
        m.save_success = true
        m.save_message = "Config saved to $global_path"
    catch e
        m.save_success = false
        m.save_message = "Save failed: $(sprint(showerror, e))"
    end
end


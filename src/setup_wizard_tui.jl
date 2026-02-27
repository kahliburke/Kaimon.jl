# ═══════════════════════════════════════════════════════════════════════════════
# Setup Wizard TUI — 3-Mode Animated Security Setup
#
# Tachikoma-based TUI wizard with Dragon, Butterfly, and Neuromancer personality
# modes. Collects security configuration and saves to ~/.config/kaimon/security.json.
# ═══════════════════════════════════════════════════════════════════════════════

# Additional Tachikoma imports not already brought in by tui.jl
import Tachikoma:
    BOX_ROUNDED,
    BigText,
    intrinsic_size,
    ProgressList,
    ProgressItem,
    TaskStatus,
    task_pending,
    task_running,
    task_done,
    PixelImage,
    load_pixels!

# ── ASCII Art ────────────────────────────────────────────────────────────────

const DRAGON_ASCII = raw"""
                                                     __----~~~~~~~~~~~------___
                                    .  .   ~~//====......          __--~ ~~
                    -.            \_|//     |||\\  ~~~~~~::::... /~
                 ___-==_       _-~o~  \/    |||  \\            _/~~-
         __---~~~.==~||\=_    -_--~/_-~|-   |\\   \\        _/~
     _-~~     .=~    |  \\-_    '-~7  /-   /  ||    \      /
   .~       .~       |   \\ -_    /  /-   /   ||      \   /
  /  ____  /         |     \\ ~-_/  /|- _/   .||       \ /
  |~~    ~~|--~~~~--_ \     ~==-/   | \~--===~~        .\
           '         ~-|      /|    |-~\~~       __--~~
                       |-~~-_/ |    |   ~\_   _-~            /\
                            /  \     \__   \/~                \__
                        _--~ _/ | .-~~____--~-/                  ~~==.
                       ((->/~   '.|||' -_|    ~~-/ ,              . _||
                                  -_     ~\      ~~---l__i__i__i--~~_/
                                  _-~-__   ~)  \--______________--~~
                                //.-~~~-~_--~- |-------~~~~~~~~
                                       //.-~~~--\
"""

const DRAGON_MOUTH_OPEN = raw"""
                                                     __----~~~~~~~~~~~------___
                                    .  .   ~~//====......          __--~ ~~
                    -.            \_|//     |||\\  ~~~~~~::::... /~
                 ___-==_       _-~O~  \/    |||  \\            _/~~-
         __---~~~.==~||\=_    - --~/_-~|-   |\\   \\        _/~
     _-~~     .=~    |  \\-_   <-/- > /-   /  ||    \      /
   .~       .~       |   \\ -_    /  /-   /   ||      \   /
  /  ____  /         |     \\ ~-_/  /|- _/   .||       \ /
  |~~    ~~|--~~~~--_ \     ~==-/   | \~--===~~        .\
           '         ~-|      /|    |-~\~~       __--~~
                       |-~~-_/ |    |   ~\_   _-~            /\
                            /  \     \__   \/~                \__
                        _--~ _/ | .-~~____--~-/                  ~~==.
                       ((->/~   '.|||' -_|    ~~-/ ,              . _||
                                  -_     ~\      ~~---l__i__i__i--~~_/
                                  _-~-__   ~)  \--______________--~~
                                //.-~~~-~_--~- |-------~~~~~~~~
                                       //.-~~~--\
"""

# Detect mouth position for fire particle emission.

function _detect_dragon_mouth()
    lines = split(DRAGON_ASCII, '\n')
    for (i, line) in enumerate(lines)
        idx = findfirst("'-~7", line)
        if idx !== nothing
            return (i, first(idx) + 2)
        end
    end
    return (7, 31)
end

# TUI-safe butterfly art (pure ASCII — no fullwidth/emoji chars that break set_string!)
const GENTLE_BUTTERFLY_ASCII = raw"""
                              .  *  .       _ " _
             _ " _          .  *  .  *    (_\|/_)
            (_\|/_)       *  .  *  .       (/|\)
     _ " _   (/|\)      .  *  .  *  .
    (_\|/_)           *              _ " _
     (/|\)    _ " _     *  .  *    (_\|/_)     _ " _
             (_\|/_)      .  *      (/|\)     (_\|/_)
              (/|\)     *  .  *  .             (/|\)
                      .  *  .  *  .
        _ " _       *  .  *  .  *  .  *    _ " _
       (_\|/_)        .  *  .  *  .       (_\|/_)
        (/|\)       *  .  *  .  *  .       (/|\)
                      .  *  .  *  .
     _ " _          *  .       .  *        _ " _
    (_\|/_)           .  *  .  *          (_\|/_)
     (/|\)              *  .  *            (/|\)

        *  .  You've got this!  .  *
            *  .  .  *  .  .  *
"""

# Motivational phrases for butterfly (gentle) intro animation
const MOTIVATIONAL_PHRASES = [
    "You're doing great!",
    "Security is self-care.",
    "One step at a time.",
    "Almost there!",
    "You've got this!",
    "Safe and sound.",
]

# Color palettes
const FIRE_COLORS = [196, 202, 208, 214, 220, 226, 220, 214, 208, 202]
const BUTTERFLY_COLORS = [219, 183, 147, 111, 75, 39, 75, 111, 147, 183]
const PASTEL_COLORS = [218, 225, 189, 195, 159, 153, 183, 219, 225, 189]
const WIZARD_COLORS = [33, 39, 45, 51, 87, 123, 159, 105, 69]
const NEURO_GREENS = [22, 28, 34, 40, 46, 82, 118, 154, 190, 226]

# Small companion art (first ~10 lines)
const DRAGON_PREVIEW_LINES = split(DRAGON_ASCII, '\n')[1:min(10, end)]
const BUTTERFLY_PREVIEW_LINES = split(GENTLE_BUTTERFLY_ASCII, '\n')[1:min(10, end)]

# Wizard companion art
const _WIZ_ART = raw"""
                      ____
                    .'* *.'
                 __/_*_*(_
                / _______ \
               _\_)/___\(_/_
              / _((\O O/))_ \
              \ \())(-)(()/ /
               ' \(((()))/ '
              / ' \)).))/ ' \
             / _ \ - | - /_  \
            (   ( .;''';. .'  )
            _\"__ /    )\ __"/_
              \/  \   ' /  \/
               .'  '...' ' )
                / /  |  \ \
               / .   .   . \
              /   .     .   \
             /   /   |   \   \
           .'   /    b    '.  '.
       _.-'    /     Bb     '-. '-._
   _.-'       |      BBb       '-.  '-.
  (________mrf\____.dBBBb.________)____)
  """

const _WIZ_B_ART = raw"""

   _ " _
  (_\|/_)
   (/|\)

"""

const COMPANION_WIZ = split(_WIZ_ART, '\n')
const COMPANION_WIZ_B = split(_WIZ_B_ART, '\n')

# ── Enums ────────────────────────────────────────────────────────────────────

@enum WizardMode STANDARD GENTLE L33T

@enum WizardPhase begin
    PHASE_MODE_SELECT      # Choose personality mode (3 columns with art previews)
    PHASE_INTRO_ANIM       # Animated intro (auto-advance after ~3-4s or any keypress)
    PHASE_ACKNOWLEDGE      # Hold SPACE or type "I UNDERSTAND THE RISKS"
    PHASE_SECURITY_MODE    # Choose :strict / :relaxed / :lax
    PHASE_PORT             # TextInput for port (default 2828)
    PHASE_API_KEY_GEN      # Generate + display key, [c] to copy
    PHASE_QUICK_OR_ADV     # [Enter] save defaults / [a] advanced settings
    PHASE_IP_ALLOWLIST     # (Advanced) Add/remove IPs
    PHASE_INDEX_DIRS       # (Advanced) Add index directories
    PHASE_SUMMARY          # (Advanced) Review + confirm/cancel Modal
    PHASE_SAVING           # Animated Gauge progress, writes config at midpoint
    PHASE_DONE             # Success screen, any key exits
end

# ── Model ────────────────────────────────────────────────────────────────────

struct FireParticle
    x::Float64
    y::Float64
    color_idx::Int
    life::Int
    dx::Float64
    dy::Float64
end

@kwdef mutable struct SetupWizardModel <: Model
    quit::Bool = false
    tick::Int = 0
    mode::WizardMode = STANDARD
    phase::WizardPhase = PHASE_MODE_SELECT
    advanced::Bool = false
    animator::Animator = Animator()
    intro_done::Bool = false

    # Acknowledgement state
    ack_target::String = "I UNDERSTAND THE RISKS"
    ack_typed::String = ""

    # UI selection state
    mode_selected::Int = 1
    sec_mode_selected::Int = 1
    sec_mode::Symbol = :strict

    # Config values being collected
    port_input::Any = nothing
    port::Int = 2828
    api_key::String = ""
    api_key_copied::Bool = false
    ip_input::Any = nothing
    allowed_ips::Vector{String} = ["127.0.0.1", "::1"]
    ip_list_selected::Int = 1
    index_input::Any = nothing
    index_dirs::Vector{String} = String[]
    index_list_selected::Int = 1
    summary_selected::Symbol = :confirm

    # Save state
    save_progress::Float64 = 0.0
    save_done::Bool = false
    save_success::Bool = false
    save_message::String = ""

    # Dragon animation
    fire_particles::Vector{FireParticle} = FireParticle[]

    # Neuromancer animation
    rain_columns::Vector{Int} = Int[]       # y position per column
    rain_chars::Vector{Char} = Char[]       # char per column
    typed_text::String = ""
    typed_target::String = "> JACK IN, COWBOY. THE ICE IS THIN HERE."
    typed_index::Int = 0

    # Butterfly animation
    sparkle_springs::Vector{Spring} = Spring[]
    sparkle_xs::Vector{Int} = Int[]

    # Cyber face — randomized params with glitchy transitions
    face_params::Dict{Symbol,Float64} = Dict{Symbol,Float64}()
    face_params_prev::Dict{Symbol,Float64} = Dict{Symbol,Float64}()
    face_transition_start::Int = 0          # tick when bitrot transition began (0 = idle)
    face_transition_duration::Int = 10      # randomized per transition
    face_next_switch::Int = 300             # tick when next face swap triggers

    # Background texture (L33T intro)
    l33t_bg::DotWaveBackground =
        DotWaveBackground(preset = 4, amplitude = 2.0, cam_height = 8.0)

    _render_mode::Bool = false  # true during asset generation — disables do_save!
end

# ── Lifecycle ────────────────────────────────────────────────────────────────

function Tachikoma.init!(::SetupWizardModel, ::Tachikoma.Terminal)
    set_theme!(KOKAKU)
end

Tachikoma.should_quit(m::SetupWizardModel) = m.quit

# ── Phase Transitions ────────────────────────────────────────────────────────

function enter_phase!(m::SetupWizardModel, phase::WizardPhase)
    m.phase = phase
    m.tick = 0

    if phase == PHASE_INTRO_ANIM
        # Set theme based on selected mode
        if m.mode == STANDARD
            set_theme!(KANEDA)
        elseif m.mode == GENTLE
            set_theme!(CATPPUCCIN)
        else
            set_theme!(NEUROMANCER)
        end
        setup_intro_animations!(m)
    elseif phase == PHASE_ACKNOWLEDGE
        m.ack_typed = ""
    elseif phase == PHASE_SECURITY_MODE
        m.sec_mode_selected = 1
    elseif phase == PHASE_PORT
        m.port_input = TextInput(text = "2828", label = "Port: ")
    elseif phase == PHASE_API_KEY_GEN
        m.api_key = generate_api_key()
        m.api_key_copied = false
    elseif phase == PHASE_IP_ALLOWLIST
        m.ip_input = TextInput(text = "", label = "IP: ")
        m.ip_list_selected = 1
    elseif phase == PHASE_INDEX_DIRS
        m.index_input = TextInput(text = "", label = "Dir: ")
        m.index_list_selected = 1
    elseif phase == PHASE_SUMMARY
        m.summary_selected = :confirm
    elseif phase == PHASE_SAVING
        m.save_done = false
        m.save_success = false
        m.save_progress = 0.0
        animate!(
            m.animator,
            :save_gauge,
            tween(0.0, 1.0; duration = 90, easing = ease_in_out_cubic),
        )
    end
end

function advance_phase!(m::SetupWizardModel)
    if m.phase == PHASE_MODE_SELECT
        enter_phase!(m, PHASE_INTRO_ANIM)
    elseif m.phase == PHASE_INTRO_ANIM
        enter_phase!(m, PHASE_ACKNOWLEDGE)
    elseif m.phase == PHASE_ACKNOWLEDGE
        enter_phase!(m, PHASE_SECURITY_MODE)
    elseif m.phase == PHASE_SECURITY_MODE
        enter_phase!(m, PHASE_PORT)
    elseif m.phase == PHASE_PORT
        enter_phase!(m, PHASE_API_KEY_GEN)
    elseif m.phase == PHASE_API_KEY_GEN
        enter_phase!(m, PHASE_QUICK_OR_ADV)
    elseif m.phase == PHASE_QUICK_OR_ADV
        if m.advanced
            enter_phase!(m, PHASE_IP_ALLOWLIST)
        else
            enter_phase!(m, PHASE_SAVING)
        end
    elseif m.phase == PHASE_IP_ALLOWLIST
        enter_phase!(m, PHASE_INDEX_DIRS)
    elseif m.phase == PHASE_INDEX_DIRS
        enter_phase!(m, PHASE_SUMMARY)
    elseif m.phase == PHASE_SUMMARY
        enter_phase!(m, PHASE_SAVING)
    elseif m.phase == PHASE_SAVING
        enter_phase!(m, PHASE_DONE)
    elseif m.phase == PHASE_DONE
        m.quit = true
    end
end

# ── Intro Animation Setup ───────────────────────────────────────────────────

function setup_intro_animations!(m::SetupWizardModel)
    m.intro_done = false
    m.fire_particles = FireParticle[]

    if m.mode == STANDARD
        # Phase 1 (0-120): Slow dramatic reveal, line by line
        animate!(
            m.animator,
            :dragon_reveal,
            tween(0.0, 1.0; duration = 120, easing = ease_out_cubic),
        )
        # Phase 2 (60-360): Fire particles — 3 bursts of breathing
        # Phase 3 (360-480): Flash pulse finale
        animate!(
            m.animator,
            :dragon_flash,
            tween(0.0, 1.0; duration = 40, easing = ease_in_out_quad, loop = :pingpong),
        )
        # Color heat tween cycles the palette faster during fire
        animate!(
            m.animator,
            :dragon_heat,
            tween(0.0, 1.0; duration = 60, easing = ease_in_out_cubic, loop = :pingpong),
        )

    elseif m.mode == GENTLE
        # Slow staggered line reveal over 120 frames
        animate!(
            m.animator,
            :butterfly_reveal,
            tween(0.0, 1.0; duration = 120, easing = ease_out_cubic),
        )
        # Gentle glow pulse on the art
        animate!(
            m.animator,
            :butterfly_glow,
            tween(0.0, 1.0; duration = 90, easing = ease_in_out_quad, loop = :pingpong),
        )
        # Setup sparkle springs — more of them, spread wider
        m.sparkle_springs =
            [Spring(Float64(rand(3:25)); stiffness = 40.0, damping = 5.0) for _ = 1:18]
        m.sparkle_xs = [rand(3:75) for _ = 1:18]

    elseif m.mode == L33T
        # Initialize rain columns for dim_rain during config steps
        m.rain_columns = [rand(1:40) for _ = 1:100]
        m.rain_chars = [rand(['0', '1', '.', ':', 'x']) for _ = 1:100]
        # Face reveal: fades in over 90 frames (~1.5s)
        animate!(
            m.animator,
            :face_reveal,
            tween(0.0, 1.0; duration = 90, easing = ease_out_cubic),
        )
        # Face should start transitioning during intro
        m.face_next_switch = 180
        m.typed_text = ""
        m.typed_index = 0
    end
end

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
            m.index_dirs,
            DEFAULT_INDEX_EXTENSIONS,
        )
        global_path = get_global_security_config_path()
        global_dir = dirname(global_path)
        if !isdir(global_dir)
            mkpath(global_dir)
        end
        save_global_security_config(config)
        # Save personality mode as extra metadata in the config JSON
        _save_personality(global_path, m.mode)
        m.save_success = true
        m.save_message = "Config saved to $global_path"
    catch e
        m.save_success = false
        m.save_message = "Save failed: $(sprint(showerror, e))"
    end
end

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
        title = " SETUP ",
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
            title = " $name ",
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
                title = " DANGER ",
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
            title = " ~ ",
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

# ── Config Step Layout ───────────────────────────────────────────────────────

function view_config_step(m::SetupWizardModel, f::Frame)
    buf = f.buffer
    area = f.area

    # Outer border
    outer = Block(
        title = phase_title(m),
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true),
        box = BOX_HEAVY,
    )
    inner = render(outer, area, buf)
    inner.width < 20 && return

    # Layout: BigText title | progress + content | hints
    rows = tsplit(Layout(Vertical, [Fixed(7), Fill(), Fixed(1)]), inner)
    length(rows) < 3 && return

    # BigText step title
    title_text = step_title_text(m)
    bt = BigText(title_text; style = tstyle(:accent, bold = true))
    bt_w, _ = intrinsic_size(bt)
    bt_area =
        Rect(rows[1].x + 1, rows[1].y, min(bt_w, rows[1].width), min(5, rows[1].height))
    render(bt, bt_area, buf)

    # Content area split: progress list | step content
    content_area = rows[2]
    cols = tsplit(Layout(Horizontal, [Fixed(22), Fill()]), content_area)
    length(cols) < 2 && return

    # Progress list (left sidebar)
    view_progress_list(m, cols[1], buf)

    # Step content (right side)
    step_area = cols[2]

    # Neuromancer: subtle rain background during config
    if m.mode == L33T
        render_dim_rain(m, step_area, buf)
    end

    if m.phase == PHASE_SECURITY_MODE
        view_security_mode_step(m, step_area, buf)
    elseif m.phase == PHASE_PORT
        view_port_step(m, step_area, buf)
    elseif m.phase == PHASE_API_KEY_GEN
        view_api_key_step(m, step_area, buf)
    elseif m.phase == PHASE_QUICK_OR_ADV
        view_quick_or_adv_step(m, step_area, buf)
    elseif m.phase == PHASE_IP_ALLOWLIST
        view_ip_allowlist_step(m, step_area, buf)
    elseif m.phase == PHASE_INDEX_DIRS
        view_index_dirs_step(m, step_area, buf)
    elseif m.phase == PHASE_SUMMARY
        view_summary_step(m, step_area, buf)
    elseif m.phase == PHASE_SAVING
        view_saving_step(m, step_area, buf)
    end

    # Companion art in bottom-right of step area
    render_companion_art(m, step_area, buf)

    # Hint bar
    hints = step_hints(m)
    set_string!(buf, rows[3].x + 1, rows[3].y, hints, tstyle(:text_dim))
end

# ── Progress List ────────────────────────────────────────────────────────────

function phase_to_step_index(phase::WizardPhase)
    phase == PHASE_SECURITY_MODE && return 1
    phase == PHASE_PORT && return 2
    phase == PHASE_API_KEY_GEN && return 3
    phase == PHASE_QUICK_OR_ADV && return 4
    phase == PHASE_IP_ALLOWLIST && return 5
    phase == PHASE_INDEX_DIRS && return 6
    phase == PHASE_SUMMARY && return 7
    phase == PHASE_SAVING && return 8
    return 0
end

function view_progress_list(m::SetupWizardModel, area::Rect, buf::Buffer)
    current_step = phase_to_step_index(m.phase)

    steps =
        m.advanced ?
        [
            "Security Mode",
            "Port",
            "API Key",
            "Quick/Advanced",
            "IP Allowlist",
            "Index Dirs",
            "Summary",
            "Save",
        ] : ["Security Mode", "Port", "API Key", "Quick/Advanced", "Save"]

    items = ProgressItem[]
    for (i, label) in enumerate(steps)
        real_step = m.advanced ? i : (i <= 4 ? i : 8)
        status = if real_step < current_step
            task_done
        elseif real_step == current_step
            task_running
        else
            task_pending
        end
        push!(items, ProgressItem(label; status = status))
    end

    blk = Block(
        title = " Steps ",
        border_style = tstyle(:border),
        title_style = tstyle(:text_dim),
    )
    blk_inner = render(blk, area, buf)

    pl = ProgressList(items; tick = m.tick)
    render(pl, blk_inner, buf)
end

# ── Step Content Views ───────────────────────────────────────────────────────

function view_security_mode_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    flavor = mode_flavor_text(m)

    options = [
        ("STRICT", flavor[:strict], ":strict - API key + IP allowlist"),
        ("RELAXED", flavor[:relaxed], ":relaxed - API key, any IP"),
        ("LAX", flavor[:lax], ":lax - Localhost only, no key"),
    ]

    for (i, (name, desc, detail)) in enumerate(options)
        row_y = y + (i - 1) * 3
        row_y + 1 > bottom(area) && break

        is_sel = i == m.sec_mode_selected
        marker = is_sel ? ">" : " "
        name_style = is_sel ? tstyle(:accent, bold = true) : tstyle(:text)
        desc_style = is_sel ? tstyle(:text) : tstyle(:text_dim)

        set_string!(buf, area.x + 1, row_y, "$marker $name", name_style)
        set_string!(buf, area.x + 4, row_y + 1, desc, desc_style)
        set_string!(buf, area.x + 4, row_y + 2, detail, tstyle(:text_dim, dim = true))
    end
end

function view_port_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    set_string!(buf, area.x + 1, y, "Server port (1024-65535):", tstyle(:text))

    ti_area = Rect(area.x + 1, y + 2, min(30, area.width - 2), 1)
    render(m.port_input, ti_area, buf)

    set_string!(buf, area.x + 1, y + 4, "Default: 2828", tstyle(:text_dim))
end

function view_api_key_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    flavor = mode_flavor_text(m)

    set_string!(buf, area.x + 1, y, flavor[:api_key], tstyle(:text))
    y += 2

    if m.sec_mode == :lax
        set_string!(buf, area.x + 1, y, "No API key needed in lax mode.", tstyle(:text_dim))
        set_string!(buf, area.x + 1, y + 2, "Press Enter to continue.", tstyle(:text))
    else
        set_string!(buf, area.x + 1, y, "Generated API key:", tstyle(:text))
        y += 1

        # Display key with accent color (truncate if needed)
        key_display =
            length(m.api_key) > area.width - 4 ? m.api_key[1:area.width-7] * "..." :
            m.api_key
        set_string!(buf, area.x + 2, y, key_display, tstyle(:warning, bold = true))
        y += 2

        if m.api_key_copied
            set_string!(
                buf,
                area.x + 1,
                y,
                "Copied to clipboard!",
                tstyle(:success, bold = true),
            )
        else
            set_string!(
                buf,
                area.x + 1,
                y,
                "Press [c] to copy to clipboard",
                tstyle(:text_dim),
            )
        end
        y += 2
        set_string!(buf, area.x + 1, y, "Press Enter to continue", tstyle(:text))
    end
end

function view_quick_or_adv_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    set_string!(
        buf,
        area.x + 1,
        y,
        "Configuration complete!",
        tstyle(:success, bold = true),
    )
    y += 2
    set_string!(buf, area.x + 1, y, "Press Enter to save with defaults:", tstyle(:text))
    y += 1
    set_string!(buf, area.x + 3, y, "IPs: 127.0.0.1, ::1", tstyle(:text_dim))
    y += 1
    set_string!(buf, area.x + 3, y, "Index: default extensions", tstyle(:text_dim))
    y += 2
    set_string!(buf, area.x + 1, y, "Press [a] for advanced settings:", tstyle(:text))
    y += 1
    set_string!(buf, area.x + 3, y, "Customize IPs, index directories", tstyle(:text_dim))
end

function view_ip_allowlist_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    set_string!(buf, area.x + 1, y, "IP Allowlist:", tstyle(:text, bold = true))
    y += 1

    # Show existing IPs
    for (i, ip) in enumerate(m.allowed_ips)
        row_y = y + i - 1
        row_y > bottom(area) - 5 && break
        is_sel = i == m.ip_list_selected
        marker = is_sel ? ">" : " "
        style = is_sel ? tstyle(:accent, bold = true) : tstyle(:text)
        protected = (ip == "127.0.0.1" || ip == "::1") ? " (locked)" : ""
        set_string!(buf, area.x + 1, row_y, "$marker $ip$protected", style)
    end

    # Input field at bottom
    input_y = y + length(m.allowed_ips) + 1
    set_string!(buf, area.x + 1, input_y, "Add IP (empty to continue):", tstyle(:text_dim))
    ti_area = Rect(area.x + 1, input_y + 1, min(30, area.width - 2), 1)
    render(m.ip_input, ti_area, buf)
end

function view_index_dirs_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    set_string!(buf, area.x + 1, y, "Index Directories:", tstyle(:text, bold = true))
    y += 1

    if isempty(m.index_dirs)
        set_string!(buf, area.x + 3, y, "(default: src/)", tstyle(:text_dim))
        y += 1
    else
        for (i, dir) in enumerate(m.index_dirs)
            row_y = y + i - 1
            row_y > bottom(area) - 5 && break
            is_sel = i == m.index_list_selected
            marker = is_sel ? ">" : " "
            style = is_sel ? tstyle(:accent, bold = true) : tstyle(:text)
            set_string!(buf, area.x + 1, row_y, "$marker $dir", style)
        end
        y += length(m.index_dirs)
    end

    input_y = y + 1
    set_string!(
        buf,
        area.x + 1,
        input_y,
        "Add directory (empty to continue):",
        tstyle(:text_dim),
    )
    ti_area = Rect(area.x + 1, input_y + 1, min(40, area.width - 2), 1)
    render(m.index_input, ti_area, buf)
end

function view_summary_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + 1
    set_string!(buf, area.x + 1, y, "Configuration Summary", tstyle(:text, bold = true))
    y += 2

    items = [
        ("Mode", string(m.sec_mode)),
        ("Port", string(m.port)),
        (
            "API Key",
            m.sec_mode == :lax ? "(none)" : m.api_key[1:min(20, length(m.api_key))] * "...",
        ),
        ("IPs", join(m.allowed_ips, ", ")),
        ("Index Dirs", isempty(m.index_dirs) ? "(default)" : join(m.index_dirs, ", ")),
    ]

    for (label, val_str) in items
        y > bottom(area) - 4 && break
        set_string!(buf, area.x + 2, y, "$label:", tstyle(:text_dim))
        set_string!(buf, area.x + 16, y, val_str, tstyle(:text))
        y += 1
    end

    y += 2
    # Confirm / Cancel buttons
    confirm_style =
        m.summary_selected == :confirm ? tstyle(:success, bold = true) : tstyle(:text_dim)
    cancel_style =
        m.summary_selected == :cancel ? tstyle(:error, bold = true) : tstyle(:text_dim)

    set_string!(buf, area.x + 5, y, "[ Confirm ]", confirm_style)
    set_string!(buf, area.x + 20, y, "[ Cancel ]", cancel_style)
end

function view_saving_step(m::SetupWizardModel, area::Rect, buf::Buffer)
    y = area.y + area.height ÷ 2 - 2

    set_string!(buf, area.x + 2, y, "Saving configuration...", tstyle(:text))
    y += 2

    gauge_area = Rect(area.x + 2, y, min(area.width - 4, 50), 1)
    g = Gauge(
        m.save_progress;
        filled_style = tstyle(:accent),
        empty_style = tstyle(:text_dim, dim = true),
        label_style = tstyle(:text_bright, bold = true),
    )
    render(g, gauge_area, buf)

    if m.save_done
        y += 2
        if m.save_success
            set_string!(buf, area.x + 2, y, "Config saved!", tstyle(:success, bold = true))
        else
            set_string!(buf, area.x + 2, y, m.save_message, tstyle(:error))
        end
    end
end

function view_done(m::SetupWizardModel, f::Frame)
    buf = f.buffer
    area = f.area

    outer = Block(
        title = " COMPLETE ",
        border_style = tstyle(:success, bold = true),
        title_style = tstyle(:success, bold = true),
        box = BOX_HEAVY,
    )
    inner = render(outer, area, buf)

    # BigText "DONE"
    bt = BigText("DONE"; style = tstyle(:success, bold = true))
    bt_w, _ = intrinsic_size(bt)
    bt_area = center(inner, min(bt_w, inner.width), 5)
    bt_area = Rect(bt_area.x, inner.y + 2, bt_area.width, 5)
    render(bt, bt_area, buf)

    y = inner.y + 9

    if m.save_success
        msg =
            m.mode == STANDARD ? "The castle defenses are set!" :
            m.mode == GENTLE ? "Your workspace is safe and sound!" :
            "ICE deployed. You're in the clear, cowboy."
        set_string!(
            buf,
            inner.x + (inner.width - length(msg)) ÷ 2,
            y,
            msg,
            tstyle(:accent, bold = true),
        )
        y += 2

        path = get_global_security_config_path()
        path_msg = "Config: $path"
        set_string!(
            buf,
            inner.x + max(1, (inner.width - length(path_msg)) ÷ 2),
            y,
            path_msg,
            tstyle(:text_dim),
        )
        y += 2

        if m.sec_mode != :lax && !isempty(m.api_key)
            key_msg = "API Key: $(m.api_key[1:min(20, length(m.api_key))])..."
            set_string!(
                buf,
                inner.x + max(1, (inner.width - length(key_msg)) ÷ 2),
                y,
                key_msg,
                tstyle(:warning),
            )
        end
    else
        set_string!(buf, inner.x + 3, y, "Save failed: $(m.save_message)", tstyle(:error))
    end

    y = bottom(inner) - 1
    set_string!(
        buf,
        inner.x + (inner.width - 28) ÷ 2,
        y,
        " Press any key to exit... ",
        tstyle(:text_dim),
    )
end

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
        )
    elseif m.mode == GENTLE
        Dict(
            :strict => "Maximum protection for safety",
            :relaxed => "Flexible but secure",
            :lax => "Simple and local",
            :api_key => "Keep this safe and sound!",
        )
    else
        Dict(
            :strict => "Full ICE deployment",
            :relaxed => "Partial countermeasures",
            :lax => "Running dark - local only",
            :api_key => "Don't let it leak into the matrix",
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

Configuration is saved globally to `~/.config/kaimon/security.json`.
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
    model.save_success ? load_global_security_config() : nothing
end

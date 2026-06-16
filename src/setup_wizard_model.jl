# ─────────────────────────────────────────────────────────────────────────────
# Kaimon setup wizard · enums · model · lifecycle · phase transitions · intro setup  (split from setup_wizard_tui.jl)
# ─────────────────────────────────────────────────────────────────────────────

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
    PHASE_GATE             # Auto-connect every Julia session? (Yes / Not now / Never)
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

    # Gate auto-connect choice (first-run setup)
    gate_selected::Int = 1
    gate_choice::Symbol = :yes   # :yes / :no / :never

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
    elseif phase == PHASE_GATE
        m.gate_selected = 1
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
            enter_phase!(m, PHASE_GATE)
        end
    elseif m.phase == PHASE_IP_ALLOWLIST
        enter_phase!(m, PHASE_INDEX_DIRS)
    elseif m.phase == PHASE_INDEX_DIRS
        enter_phase!(m, PHASE_SUMMARY)
    elseif m.phase == PHASE_SUMMARY
        enter_phase!(m, PHASE_GATE)
    elseif m.phase == PHASE_GATE
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


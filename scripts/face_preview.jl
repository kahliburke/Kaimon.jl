#!/usr/bin/env julia
# Standalone preview of the L33T cyber face with cables + bitrot transitions.
# Reuses the face renderer from setup_wizard_tui.jl via Kaimon internals.
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Kaimon
using Tachikoma
import Tachikoma:
    Model,
    view,
    init!,
    should_quit,
    update!,
    KeyEvent,
    Frame,
    Buffer,
    Rect,
    Block,
    BOX_HEAVY,
    Style,
    Color256,
    set_char!,
    set_string!,
    right,
    bottom,
    app,
    DotWaveBackground,
    render_background!

# Grab internals from Kaimon's setup wizard
const _face_density = Kaimon._face_density
const _randomize_face_params! = Kaimon._randomize_face_params!
const _poisson_next_interval = Kaimon._poisson_next_interval
const render_cyber_face_standalone = Kaimon.render_cyber_face
const _rand_transition_duration = Kaimon._rand_transition_duration
const NEURO_GREENS = Kaimon.NEURO_GREENS

# Minimal model that wraps SetupWizardModel fields needed by render_cyber_face
@kwdef mutable struct FacePreviewModel <: Model
    quit::Bool = false
    tick::Int = 0
    bg::DotWaveBackground = DotWaveBackground(preset = 4, amplitude = 2.0, cam_height = 8.0)
    # Embed a SetupWizardModel for the face renderer
    inner::Kaimon.SetupWizardModel = Kaimon.SetupWizardModel()
end

function init!(m::FacePreviewModel, ::Tachikoma.Terminal)
    m.inner.mode = Kaimon.L33T
    m.inner.face_params = _randomize_face_params!()
    m.inner.face_next_switch = 300
    m.inner.rain_columns = rand(0:40, 200)
    m.inner.rain_chars = rand(['0', '1', '.', ':', 'x'], 200)
end

should_quit(m::FacePreviewModel) = m.quit

function update!(m::FacePreviewModel, evt::KeyEvent)
    if evt.key == :escape || evt.char == 'q'
        m.quit = true
    end
end

function view(m::FacePreviewModel, f::Frame)
    m.tick += 1
    wiz = m.inner
    wiz.tick = m.tick

    # Update face transition
    if wiz.face_transition_start > 0
        elapsed = wiz.tick - wiz.face_transition_start
        if elapsed >= wiz.face_transition_duration
            wiz.face_transition_start = 0
            wiz.face_next_switch = wiz.tick + _poisson_next_interval()
        end
    elseif wiz.tick >= wiz.face_next_switch
        wiz.face_params_prev = copy(wiz.face_params)
        wiz.face_params = _randomize_face_params!()
        wiz.face_transition_start = wiz.tick
        wiz.face_transition_duration = _rand_transition_duration()
    end

    buf = f.buffer
    area = f.area

    # Background texture
    render_background!(
        m.bg,
        buf,
        area,
        m.tick;
        brightness = 0.12,
        saturation = 0.3,
        speed = 0.3,
    )

    # Border
    outer = Block(
        title = " CYBER FACE PREVIEW ",
        border_style = Style(; fg = Color256(NEURO_GREENS[4])),
        title_style = Style(; fg = Color256(NEURO_GREENS[8]), bold = true),
        box = BOX_HEAVY,
    )
    inner = render(outer, area, buf)

    # Render the face using the wizard's renderer
    render_cyber_face_standalone(wiz, inner, buf)

    # Status
    in_transition = wiz.face_transition_start > 0
    status =
        in_transition ? " ▓▓ BITROT ▓▓" : " next swap: $(wiz.face_next_switch - wiz.tick)"
    hint = "  q/Esc quit"
    set_string!(
        buf,
        inner.x + 1,
        bottom(inner),
        status,
        Style(; fg = Color256(in_transition ? NEURO_GREENS[8] : NEURO_GREENS[3])),
    )
    set_string!(
        buf,
        right(inner) - length(hint) - 1,
        bottom(inner),
        hint,
        Style(; fg = Color256(NEURO_GREENS[2]), dim = true),
    )
end

app(FacePreviewModel(); fps = 60)

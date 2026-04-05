# ── HelloExtension TUI Panel ──────────────────────────────────────────────────
#
# Demonstrates the ext_panel protocol — a lightweight TUI that runs inside
# Kaimon's Extensions tab when the user presses [u] on this extension.
#
# Protocol functions (all required except update! and cleanup!):
#   init(ctx)                       → create panel state
#   update!(state, ctx)             → called each frame; read pushed data here
#   view(state, area, buf)          → render into a Tachikoma buffer region
#   handle_key!(state, evt) → Bool  → process keyboard input; true = consumed
#   cleanup!(state, ctx)            → tear down when panel closes
#
# Layout:
#   ┌──────────────┬──────────────┐
#   │  Greetings   │  Dice Rolls  │  ← top 2/3
#   ├──────────────┴──────────────┤
#   │  Activity Log               │  ← bottom 1/3
#   └─────────────────────────────┘

using Tachikoma
using Match
using Dates

# ── State ────────────────────────────────────────────────────────────────────

mutable struct HelloPanelState
    greetings::Vector{String}
    rolls::Vector{String}
    activity::Vector{String}   # timestamped event log
    selected::Int              # focused pane: 1=greetings, 2=rolls, 3=activity
    tick::Int
    push_count::Int            # total Gate.push_panel() updates received
    session_key::String        # extension's gate session key
end

const MAX_ACTIVITY = 50

function _log!(state::HelloPanelState, msg::String)
    ts = Dates.format(Dates.now(), "HH:MM:SS")
    push!(state.activity, "[$ts] $msg")
    length(state.activity) > MAX_ACTIVITY && popfirst!(state.activity)
end

# ── Protocol: init ───────────────────────────────────────────────────────────
# Called once when the panel opens. `ctx` provides session_key, tick, _cache,
# eval(code), and request(tool, args) for communicating with the extension.

function init(ctx)
    state = HelloPanelState(String[], String[], String[], 1, 0, 0, ctx.session_key)
    _log!(state, "Panel initialized — session $(ctx.session_key)")
    _log!(state, "Waiting for Gate.push_panel() events via PUB/SUB...")
    return state
end

# ── Protocol: update! ────────────────────────────────────────────────────────
# Called every frame (~60 fps). Read pushed state from ctx._cache[:panel_state]
# which is populated automatically by Gate.push_panel() calls in the extension.

function update!(state::HelloPanelState, ctx)
    state.tick = ctx.tick
    ps = get(ctx._cache, :panel_state, nothing)
    ps === nothing && return
    if haskey(ps, "greetings")
        prev = length(state.greetings)
        state.greetings = ps["greetings"]
        n_new = length(state.greetings) - prev
        if n_new > 0
            state.push_count += 1
            _log!(state, "push #$(state.push_count): greetings (+$n_new, total $(length(state.greetings)))")
        end
    end
    if haskey(ps, "rolls")
        prev = length(state.rolls)
        state.rolls = ps["rolls"]
        n_new = length(state.rolls) - prev
        if n_new > 0
            state.push_count += 1
            _log!(state, "push #$(state.push_count): rolls (+$n_new, total $(length(state.rolls)))")
        end
    end
end

# ── Protocol: view ───────────────────────────────────────────────────────────
# Render into a Tachikoma buffer region. No access to ctx here — everything
# needed for display must be on the state struct.

function view(state::HelloPanelState, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    outer = Tachikoma.Block(
        title = " Hello Extension [g]reet [r]oll [Tab] switch [Esc] close ",
        border_style = Tachikoma.tstyle(:border_focus),
    )
    content = Tachikoma.render(outer, area, buf)

    # Vertical split: data panes (2/3) + activity log (1/3)
    vparts = Tachikoma.split_layout(
        Tachikoma.Layout(Tachikoma.Vertical, [Tachikoma.Fill(2), Tachikoma.Fill(1)]),
        content,
    )

    # Horizontal split for greetings | rolls
    panes = Tachikoma.split_layout(
        Tachikoma.Layout(Tachikoma.Horizontal, [Tachikoma.Fill(1), Tachikoma.Fill(1)]; spacing=1),
        vparts[1],
    )

    _render_list!(buf, panes[1], "Greetings", state.greetings, state.selected == 1)
    _render_list!(buf, panes[2], "Dice Rolls", state.rolls, state.selected == 2)
    _render_activity!(buf, vparts[2], state)
end

function _render_list!(buf, area, title, items, focused)
    style = focused ? Tachikoma.tstyle(:border_focus) : Tachikoma.tstyle(:border)
    block = Tachikoma.Block(title = " $title ($(length(items))) ", border_style = style)
    inner = Tachikoma.render(block, area, buf)
    for (i, msg) in enumerate(Iterators.reverse(items))
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        Tachikoma.set_string!(buf, inner.x, y, msg, Tachikoma.tstyle(:text))
    end
end

function _render_activity!(buf, area, state)
    style = state.selected == 3 ? Tachikoma.tstyle(:border_focus) : Tachikoma.tstyle(:border)
    block = Tachikoma.Block(
        title = " Activity Log ($(length(state.activity))) — ses=$(state.session_key) pushes=$(state.push_count) ",
        border_style = style,
    )
    inner = Tachikoma.render(block, area, buf)
    dim = Tachikoma.Style(fg=Tachikoma.Color256(245))
    text = Tachikoma.tstyle(:text)
    for (i, msg) in enumerate(Iterators.reverse(state.activity))
        y = inner.y + i - 1
        y > Tachikoma.bottom(inner) && break
        bracket_end = findfirst(']', msg)
        if bracket_end !== nothing && bracket_end < length(msg)
            Tachikoma.set_string!(buf, inner.x, y, msg[1:bracket_end], dim)
            Tachikoma.set_string!(buf, inner.x + bracket_end, y, msg[bracket_end+1:end], text)
        else
            Tachikoma.set_string!(buf, inner.x, y, msg, text)
        end
    end
end

# ── Protocol: handle_key! ────────────────────────────────────────────────────
# Return true if the key was consumed, false to let Kaimon handle it.
# Use @match for clean dispatch (Match.jl is a Kaimon dependency).

function handle_key!(state::HelloPanelState, evt::Tachikoma.KeyEvent)::Bool
    @match (evt.key, evt.char) begin
        (:tab, _) => begin
            state.selected = mod1(state.selected + 1, 3)
            true
        end
        (:char, 'g') => begin
            name = "User#$(rand(100:999))"
            push!(state.greetings, "Hello, $(name)!")
            _log!(state, "local: greeted $name")
            true
        end
        (:char, 'r') => begin
            result = rand(1:6)
            push!(state.rolls, "🎲 Rolled a $result (d6)")
            _log!(state, "local: rolled $result (d6)")
            true
        end
        _ => false
    end
end

# ── Protocol: cleanup! ───────────────────────────────────────────────────────
# Called when the panel is closed (user presses Esc). Free resources here.

function cleanup!(state::HelloPanelState, ctx)
end

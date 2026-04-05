# ── HelloExtension TUI Panel ──────────────────────────────────────────────────
#
# Lightweight panel shown inside Kaimon's Extensions tab when the user
# presses [u] on the hello extension. Demonstrates the ext_panel protocol.

using Tachikoma

mutable struct HelloPanelState
    greetings::Vector{String}
    rolls::Vector{String}
    selected::Int       # 1 = greetings pane, 2 = rolls pane
    tick::Int
end

function init(ctx)
    # Fetch any existing greetings/rolls from the extension session
    HelloPanelState(String[], String[], 1, 0)
end

function update!(state::HelloPanelState, ctx)
    state.tick = ctx.tick
end

function view(state::HelloPanelState, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    # Outer block
    outer = Tachikoma.Block(
        title = " Hello Extension [g]reet [r]oll [Tab] switch [Esc] close ",
        border_style = Tachikoma.tstyle(:border_focus),
    )
    content = Tachikoma.render(outer, area, buf)

    # Two panes side by side
    layout = Tachikoma.Layout(
        Tachikoma.Horizontal,
        [Tachikoma.Fill(1), Tachikoma.Fill(1)];
        spacing = 1,
    )
    panes = Tachikoma.split_layout(layout, content)

    # Greetings pane
    g_style = state.selected == 1 ? Tachikoma.tstyle(:border_focus) : Tachikoma.tstyle(:border)
    g_block = Tachikoma.Block(title = " Greetings ($(length(state.greetings))) ", border_style = g_style)
    g_inner = Tachikoma.render(g_block, panes[1], buf)
    for (i, msg) in enumerate(Iterators.reverse(state.greetings))
        y = g_inner.y + i - 1
        y > Tachikoma.bottom(g_inner) && break
        Tachikoma.set_string!(buf, g_inner.x, y, msg, Tachikoma.tstyle(:text))
    end

    # Rolls pane
    r_style = state.selected == 2 ? Tachikoma.tstyle(:border_focus) : Tachikoma.tstyle(:border)
    r_block = Tachikoma.Block(title = " Dice Rolls ($(length(state.rolls))) ", border_style = r_style)
    r_inner = Tachikoma.render(r_block, panes[2], buf)
    for (i, msg) in enumerate(Iterators.reverse(state.rolls))
        y = r_inner.y + i - 1
        y > Tachikoma.bottom(r_inner) && break
        Tachikoma.set_string!(buf, r_inner.x, y, msg, Tachikoma.tstyle(:text))
    end
end

function handle_key!(state::HelloPanelState, evt::Tachikoma.KeyEvent)
    if evt.key == :tab
        state.selected = state.selected == 1 ? 2 : 1
        return true
    elseif evt.key == :char && evt.char == 'g'
        name = "User#$(rand(100:999))"
        push!(state.greetings, "Hello, $name!")
        return true
    elseif evt.key == :char && evt.char == 'r'
        result = rand(1:6)
        push!(state.rolls, "🎲 Rolled a $result (d6)")
        return true
    end
    return false
end

function cleanup!(state::HelloPanelState, ctx)
    # Nothing to clean up
end

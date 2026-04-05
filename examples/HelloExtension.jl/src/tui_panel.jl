# ── HelloExtension TUI Panel ──────────────────────────────────────────────────
#
# Lightweight panel shown inside Kaimon's Extensions tab when the user
# presses [u] on the hello extension. Demonstrates the ext_panel protocol.
#
# The panel shows greetings and dice rolls — both from local keypresses
# AND from agent tool calls (synced via ext_panel_eval polling).

using Tachikoma

mutable struct HelloPanelState
    greetings::Vector{String}
    rolls::Vector{String}
    selected::Int       # 1 = greetings pane, 2 = rolls pane
    tick::Int
    last_sync::Int      # tick of last remote sync
end

function init(ctx)
    state = HelloPanelState(String[], String[], 1, 0, 0)
    # Initial sync from extension process
    _sync_from_extension!(state, ctx)
    return state
end

function update!(state::HelloPanelState, ctx)
    state.tick = ctx.tick
    # Sync every ~60 frames (~1s at 60fps) to pick up agent tool calls
    if state.tick - state.last_sync > 60
        _sync_from_extension!(state, ctx)
        state.last_sync = state.tick
    end
end

function _sync_from_extension!(state::HelloPanelState, ctx)
    try
        result = Kaimon.ext_panel_eval(ctx, "using HelloExtension; (HelloExtension.GREETINGS, HelloExtension.ROLLS)")
        repr_str = result.value_repr
        isempty(repr_str) && return
        # Parse the tuple of vectors from the repr
        val = Main.eval(Meta.parse(repr_str))
        if val isa Tuple && length(val) == 2
            remote_greetings, remote_rolls = val
            # Merge: add any entries we don't have
            for g in remote_greetings
                g in state.greetings || push!(state.greetings, g)
            end
            for r in remote_rolls
                r in state.rolls || push!(state.rolls, r)
            end
        end
    catch
        # Extension not ready or eval failed — skip
    end
end

function view(state::HelloPanelState, area::Tachikoma.Rect, buf::Tachikoma.Buffer)
    outer = Tachikoma.Block(
        title = " Hello Extension [g]reet [r]oll [Tab] switch [Esc] close ",
        border_style = Tachikoma.tstyle(:border_focus),
    )
    content = Tachikoma.render(outer, area, buf)

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
        push!(state.greetings, "Hello, $(name)!")
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

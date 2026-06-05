# ── Agents Tab ────────────────────────────────────────────────────────────────
#
# Tab 9: Kaimon-owned AI agent sessions monitor. Two panes:
#   Pane 1 (left):  agent list with status + running cost
#   Pane 2 (right): detail for the selected agent — fields + live event feed
#
# Read-only. Data comes from the in-process AgentSession registry (list_agents,
# agent_recent) — the TUI runs in the same process as the manager. See
# agent_session.jl / AGENT_SESSION_SERVICE_PLAN.md.

# Stable, newest-first-friendly ordering (by creation time).
function _agents_sorted()
    ags = list_agents()
    sort!(ags, by = a -> get(a, "created_at", 0.0))
    ags
end

function _agent_status_display(status::Symbol)
    @match status begin
        :idle     => ("⬤", tstyle(:success))
        :working  => ("◌", tstyle(:warning))
        :starting => ("◌", tstyle(:warning))
        :dead     => ("⬤", tstyle(:error))
        _         => ("○", tstyle(:text_dim))
    end
end

function _agent_kind_style(kind::Symbol)
    @match kind begin
        :assistant_text => tstyle(:text)
        :thought        => tstyle(:text_dim)
        :user_text      => tstyle(:primary)
        :tool_use       => tstyle(:accent)
        :tool_result    => tstyle(:success)
        :result         => tstyle(:secondary)
        :status         => tstyle(:warning)
        :error          => tstyle(:error)
        :permission     => tstyle(:warning, bold = true)
        _               => tstyle(:text_dim)
    end
end

_agent_cost(a) = get(get(a, "usage", Dict{String,Any}()), "costUsd", nothing)
_oneline(s) = replace(replace(string(s), '\n' => ' '), '\t' => ' ')
function _ago(t::Real)
    d = max(0.0, time() - t)
    d < 60 ? "$(round(Int, d))s" : d < 3600 ? "$(round(Int, d / 60))m" : "$(round(Int, d / 3600))h"
end

# ── View ─────────────────────────────────────────────────────────────────────

function view_agents(m::KaimonModel, area::Rect, buf::Buffer)
    panes = split_layout(m.agentmon_layout, area)
    length(panes) < 2 && return
    render_resize_handles!(buf, m.agentmon_layout)

    ags = _agents_sorted()
    isempty(ags) || (m.agentmon_selected = clamp(m.agentmon_selected, 1, length(ags)))

    _view_agents_list(m, panes[1], buf, ags)
    _view_agents_detail(m, panes[2], buf, ags)
end

function _view_agents_list(m::KaimonModel, area::Rect, buf::Buffer, ags)
    block = Block(
        title = "Agents ($(length(ags)))",
        border_style = _pane_border(m, TAB_AGENTS, 1),
        title_style = _pane_title(m, TAB_AGENTS, 1),
    )
    inner = render(block, area, buf)
    inner.width < 4 && return

    if isempty(ags)
        set_string!(buf, inner.x + 1, inner.y, "No agents running.", tstyle(:text_dim))
        set_string!(buf, inner.x + 1, inner.y + 1,
            "Open one with the agent_open MCP tool.", tstyle(:text_dim))
        return
    end

    y = inner.y
    for (i, a) in enumerate(ags)
        y > bottom(inner) && break
        icon, istyle = _agent_status_display(Symbol(get(a, "status", "?")))
        selected = i == m.agentmon_selected
        line_style = selected ? tstyle(:accent, bold = true) : tstyle(:text)

        set_string!(buf, inner.x + 1, y, icon, istyle)
        set_string!(buf, inner.x + 3, y, get(a, "id", "?"), line_style)

        cost = _agent_cost(a)
        info = cost === nothing ? "" : "\$$(round(cost, digits = 3))"
        if !isempty(info)
            info_x = inner.x + inner.width - length(info) - 1
            info_x > inner.x + 12 && set_string!(buf, info_x, y, info, tstyle(:secondary))
        end
        y += 1
    end

    hint_y = bottom(inner)
    hint_y > y && set_string!(buf, inner.x + 1, hint_y, "[↑↓] select",
        tstyle(:text_dim); max_x = right(inner))
end

function _view_agents_detail(m::KaimonModel, area::Rect, buf::Buffer, ags)
    block = Block(
        title = "Detail",
        border_style = _pane_border(m, TAB_AGENTS, 2),
        title_style = _pane_title(m, TAB_AGENTS, 2),
    )
    inner = render(block, area, buf)
    inner.width < 4 && return

    if isempty(ags) || m.agentmon_selected < 1 || m.agentmon_selected > length(ags)
        set_string!(buf, inner.x + 1, inner.y, "Select an agent.", tstyle(:text_dim))
        return
    end

    a = ags[m.agentmon_selected]
    id = get(a, "id", "")
    label_w = 9
    y = inner.y
    _row!(label, value, vstyle = tstyle(:text)) = begin
        if y <= bottom(inner)
            set_string!(buf, inner.x + 1, y, rpad(label, label_w), tstyle(:text_dim))
            set_string!(buf, inner.x + 1 + label_w, y, _oneline(value), vstyle;
                max_x = right(inner))
            y += 1
        end
    end

    icon, istyle = _agent_status_display(Symbol(get(a, "status", "?")))
    _row!("Agent", id, tstyle(:accent, bold = true))
    _row!("Status", "$icon $(get(a, "status", "?"))", istyle)
    _row!("Model", get(a, "model", "?"))
    _row!("Cwd", _short_path(get(a, "cwd", "")))
    _row!("Turn", string(get(a, "turn", 0)))

    usage = get(a, "usage", Dict{String,Any}())
    cost = get(usage, "costUsd", nothing)
    toks = "$(get(usage, "inputTokens", 0))in / $(get(usage, "outputTokens", 0))out"
    _row!("Tokens", toks)
    _row!("Cost", cost === nothing ? "—" : "\$$(round(cost, digits = 4))", tstyle(:secondary))
    _row!("Active", _ago(get(a, "last_activity", time())) * " ago")

    # ── Event feed (scrollable; newest at bottom) ──
    y <= bottom(inner) && (set_string!(buf, inner.x + 1, y,
        "─"^max(0, inner.width - 2), tstyle(:border)); y += 1)
    feed_top = y
    avail = bottom(inner) - feed_top + 1
    avail <= 0 && return

    recent = agent_recent(id)
    n = length(recent)
    if n == 0
        set_string!(buf, inner.x + 1, feed_top, "(no events yet)", tstyle(:text_dim))
        return
    end
    m.agentmon_scroll = clamp(m.agentmon_scroll, 0, max(0, n - 1))
    last_idx = n - m.agentmon_scroll
    first_idx = max(1, last_idx - avail + 1)

    yy = feed_top
    for i in first_idx:last_idx
        ev = recent[i]
        age = rpad(_ago(ev.t), 4)
        kindstr = rpad(string(ev.kind), 14)
        set_string!(buf, inner.x + 1, yy, age, tstyle(:text_dim))
        set_string!(buf, inner.x + 6, yy, kindstr, _agent_kind_style(ev.kind))
        sx = inner.x + 6 + length(kindstr) + 1
        sx < right(inner) &&
            set_string!(buf, sx, yy, _oneline(ev.summary), tstyle(:text); max_x = right(inner))
        yy += 1
    end
end

# ── Key handling ──────────────────────────────────────────────────────────────

function _handle_agents_nav!(m::KaimonModel, evt::KeyEvent, fp::Int)
    n = length(_agents_sorted())
    if fp == 2
        @match evt.key begin
            :up       => (m.agentmon_scroll += 1)            # scroll back in history
            :down     => (m.agentmon_scroll = max(0, m.agentmon_scroll - 1))
            :pageup   => (m.agentmon_scroll += 10)
            :pagedown => (m.agentmon_scroll = max(0, m.agentmon_scroll - 10))
            _ => nothing
        end
    else
        @match evt.key begin
            :up   => (m.agentmon_selected = max(1, m.agentmon_selected - 1); m.agentmon_scroll = 0)
            :down => (m.agentmon_selected = min(max(1, n), m.agentmon_selected + 1); m.agentmon_scroll = 0)
            _ => nothing
        end
    end
end

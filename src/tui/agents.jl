# ── Agents Tab ────────────────────────────────────────────────────────────────
#
# Tab 9: Kaimon-owned AI agent sessions monitor. Two panes:
#   Pane 1 (left):  agent list with status
#   Pane 2 (right): detail for the selected agent — fields + live event feed
#
# Read-only. Data comes from the in-process AgentSession registry (list_agents,
# agent_recent) — the TUI runs in the same process as the manager. See
# agent_session.jl / docs/src/agents.md.

# Stable, newest-first-friendly ordering (by creation time).
function _agents_sorted()
    ags = list_agents()
    sort!(ags, by = a -> get(a, "created_at", 0.0))
    ags
end

# A `:working` agent with no events for this long is treated as stalled (amber).
# `last_activity` updates on every relayed event incl. token deltas, so a healthy
# streaming agent stays well under this; only a genuinely stuck one trips it.
const _AGENT_STALL_SECS = 30.0
# Semantic, theme-INDEPENDENT status colors. Theme `primary`/`accent` are reassigned
# per theme (KOKAKU blue, KANEDA red, …) so they can't reliably mean "blue = active";
# success/warning/error stay green/amber/red across themes and are used as-is.
const _AGENT_BLUE  = ColorRGB(0x4a, 0x9e, 0xff)   # :working — active
const _AGENT_CYAN  = ColorRGB(0x3f, 0xc8, 0xd6)   # :starting — warming up
const _AGENT_AMBER = ColorRGB(0xff, 0x9a, 0x3a)   # :working — stalled

# (icon, style) reflecting the agent's real status. The active/starting states
# breathe via `tick`; idle is steady green, dead is dim red. The icon is rendered
# as a list prefix so the selection highlight never overrides its status color.
function _agent_status_icon(status::Symbol, last_activity::Real, tick::Int)
    breath(c) = Style(fg = brighten(c, pulse(tick; period = 70, lo = 0.0, hi = 1.0) * 0.4),
                      bold = true)
    @match status begin
        :working  => ((time() - last_activity) > _AGENT_STALL_SECS ?
                         ("⬤", breath(_AGENT_AMBER)) : ("⬤", breath(_AGENT_BLUE)))
        :starting => ("⬤", breath(_AGENT_CYAN))
        :idle     => ("⬤", tstyle(:success, bold = true))
        :dead     => ("⬤", tstyle(:error, dim = true))
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

_oneline(s) = replace(replace(string(s), '\n' => ' '), '\t' => ' ')
function _ago(t::Real)
    d = max(0.0, time() - t)
    d < 60 ? "$(round(Int, d))s" : d < 3600 ? "$(round(Int, d / 60))m" : "$(round(Int, d / 3600))h"
end

# ── View ─────────────────────────────────────────────────────────────────────

function view_agents(m::KaimonModel, area::Rect, buf::Buffer)
    if m.agentmon_history_open
        _view_agents_history(m, area, buf)
        return
    end
    panes = split_layout(m.agentmon_layout, area)
    length(panes) < 2 && return
    render_resize_handles!(buf, m.agentmon_layout)

    ags = _agents_sorted()
    isempty(ags) || (m.agentmon_selected = clamp(m.agentmon_selected, 1, length(ags)))

    _view_agents_list(m, panes[1], buf, ags)
    _view_agents_detail(m, panes[2], buf, ags)
    m.agentmon_popup === nothing || _view_agent_event_popup(m, area, buf)
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

    # Reserve the bottom inner row for the key hint; the list fills the rest via a
    # SelectableList (widget-managed clipping, auto-scroll-to-selection, scrollbar).
    foot = bottom(inner)
    body = Rect(inner.x, inner.y, inner.width, max(1, inner.height - 1))

    items = ListItem[]
    for a in ags
        icon, istyle = _agent_status_icon(Symbol(get(a, "status", "?")),
            Float64(get(a, "last_activity", 0.0)), m.tick)
        # Icon goes in the styled prefix so it keeps its status color when the row is
        # selected; only the id text takes the selection highlight.
        push!(items, ListItem(string(get(a, "id", "?")), tstyle(:text);
            prefix = "$icon ", prefix_style = istyle))
    end
    lst = SelectableList(items; selected = m.agentmon_selected, tick = m.tick)
    render(lst, body, buf)
    m.agentmon_selected = lst.selected   # widget clamps selection to a valid row
    m.agentmon_list = lst                # stored for mouse hit-testing in update.jl

    set_string!(buf, inner.x + 1, foot, "[↑↓] select  [x] close/dismiss",
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

    icon, istyle = _agent_status_icon(Symbol(get(a, "status", "?")),
        Float64(get(a, "last_activity", 0.0)), m.tick)
    _row!("Agent", id, tstyle(:accent, bold = true))
    _row!("Status", "$icon $(get(a, "status", "?"))", istyle)
    _row!("Model", get(a, "model", "?"))
    _row!("Cwd", _short_path(get(a, "cwd", "")))
    _row!("Turn", string(get(a, "turn", 0)))

    usage = get(a, "usage", Dict{String,Any}())
    toks = "$(get(usage, "inputTokens", 0))in / $(get(usage, "outputTokens", 0))out"
    _row!("Tokens", toks)
    _row!("Active", _ago(get(a, "last_activity", time())) * " ago")

    # ── Event feed (scrollable; newest at top) ──
    y <= bottom(inner) && (set_string!(buf, inner.x + 1, y,
        "─"^max(0, inner.width - 2), tstyle(:border)); y += 1)
    feed_top = y
    avail = bottom(inner) - feed_top + 1
    avail <= 0 && return

    events = collect(Iterators.reverse(agent_recent(id)))   # newest first, indexable
    nev = length(events)
    if nev == 0
        m.agentmon_event_sel = 0
        set_string!(buf, inner.x + 1, feed_top, "(no events yet)", tstyle(:text_dim))
        return
    end

    # Selectable, newest-at-top event rows (one line each). ↑↓ moves
    # `agentmon_event_sel`; Enter/click opens the full-text popup. The feed scrolls to
    # keep the selection visible; the rendered rect + offset are stored so update.jl
    # can map a click to an event.
    m.agentmon_event_sel = clamp(m.agentmon_event_sel, 0, nev)
    sel = m.agentmon_event_sel
    off = m.agentmon_scroll
    if sel > 0
        sel - 1 < off && (off = sel - 1)
        sel > off + avail && (off = sel - avail)
    end
    off = clamp(off, 0, max(0, nev - avail))
    m.agentmon_scroll = off
    m.agentmon_feed_area = Rect(inner.x + 1, feed_top, max(1, inner.width - 2), avail)
    m.agentmon_feed_off = off

    max_cx = right(inner) - 1
    for row in 1:avail
        idx = off + row
        idx > nev && break
        ev = events[idx]
        y = feed_top + row - 1
        age = rpad(_ago(ev.t), 4) * " "
        kind = rpad(string(ev.kind), 14) * " "
        if idx == sel
            line = age * kind * _oneline(ev.summary)
            set_string!(buf, inner.x + 1, y, rpad(line, max(0, inner.width - 2)),
                tstyle(:accent, bold = true); max_x = max_cx)
        else
            set_string!(buf, inner.x + 1, y, age, tstyle(:text_dim))
            set_string!(buf, inner.x + 1 + length(age), y, kind, _agent_kind_style(ev.kind))
            set_string!(buf, inner.x + 1 + length(age) + length(kind), y,
                _oneline(ev.summary), tstyle(:text); max_x = max_cx)
        end
    end
    off > 0 && set_string!(buf, right(inner), feed_top, "▲", tstyle(:text_dim))
    off + avail < nev && set_string!(buf, right(inner), feed_top + avail - 1, "▼", tstyle(:text_dim))
end

# Centered overlay showing one event's full text (Enter/click on a feed row; Esc closes).
function _view_agent_event_popup(m::KaimonModel, area::Rect, buf::Buffer)
    ev = m.agentmon_popup
    ev === nothing && return
    w = clamp(round(Int, area.width * 0.7), 40, max(40, area.width - 4))
    h = clamp(round(Int, area.height * 0.6), 8, max(8, area.height - 2))
    rect = Rect(area.x + (area.width - w) ÷ 2, area.y + (area.height - h) ÷ 2, w, h)
    for r in area.y:bottom(area), c in area.x:right(area)   # dim the tab behind it
        set_char!(buf, c, r, ' ', tstyle(:text_dim))
    end
    block = Block(
        title = "$(get(ev, :kind, "event")) · $(_ago(get(ev, :t, time()))) ago",
        border_style = tstyle(:accent),
        title_style = tstyle(:accent, bold = true),
    )
    inner = render(block, rect, buf)
    (inner.width < 2 || inner.height < 2) && return
    for r in inner.y:bottom(inner), c in inner.x:right(inner)   # clear interior
        set_char!(buf, c, r, ' ', tstyle(:text))
    end
    foot = bottom(inner)
    body = Rect(inner.x + 1, inner.y, max(1, inner.width - 2), max(1, inner.height - 1))
    # Render the event text as Markdown (assistant/thought bodies are markdown). The
    # MarkdownPane is cached on the model and owns its own scroll (see update.jl).
    m.agentmon_popup_pane === nothing || render(m.agentmon_popup_pane, body, buf)
    set_string!(buf, inner.x + 1, foot, "[↑↓/PgUp/PgDn] scroll  [Esc] close",
        tstyle(:text_dim); max_x = right(inner))
end

# Selected agent id (or "") + freeze the selected event into the popup.
function _selected_agent_id(m::KaimonModel, ags)
    (isempty(ags) || m.agentmon_selected < 1 || m.agentmon_selected > length(ags)) && return ""
    string(get(ags[m.agentmon_selected], "id", ""))
end

function _agent_event_count(m::KaimonModel, ags)
    id = _selected_agent_id(m, ags)
    isempty(id) ? 0 : length(agent_recent(id))
end

function _open_event_popup!(m::KaimonModel)
    ags = _agents_sorted()
    id = _selected_agent_id(m, ags)
    isempty(id) && return
    events = collect(Iterators.reverse(agent_recent(id)))
    sel = m.agentmon_event_sel
    (sel < 1 || sel > length(events)) && return
    ev = events[sel]
    m.agentmon_popup = ev
    # Plain-text body in a word-wrapping ScrollPane (owns its own scroll). Tool input/
    # output keeps its line structure and long lines wrap to the pane width instead of
    # overflowing. Start at the top (no auto-follow) so the header is visible first.
    body = string(get(ev, :detail, get(ev, :summary, "")))
    m.agentmon_popup_pane = ScrollPane(String.(split(body, '\n'));
        word_wrap = true, following = false, show_scrollbar = true)
end

# ── Key handling ──────────────────────────────────────────────────────────────

function _handle_agents_nav!(m::KaimonModel, evt::KeyEvent, fp::Int)
    ags = _agents_sorted()
    n = length(ags)
    if evt.key === :enter
        if fp == 2
            _open_event_popup!(m)            # Enter on a feed event → full-text popup
        else
            (n == 0 || m.agentmon_selected < 1 || m.agentmon_selected > n) && return
            _open_agent_history!(m, get(ags[m.agentmon_selected], "id", ""))
        end
        return
    end
    if fp == 2
        # Event selection in the feed (newest-first); the view scrolls to keep it visible.
        nev = _agent_event_count(m, ags)
        nev == 0 && return
        cur = m.agentmon_event_sel
        @match evt.key begin
            :up       => (m.agentmon_event_sel = clamp(cur == 0 ? 1 : cur - 1, 1, nev))
            :down     => (m.agentmon_event_sel = clamp(cur == 0 ? 1 : cur + 1, 1, nev))
            :pageup   => (m.agentmon_event_sel = clamp(cur == 0 ? 1 : cur - 10, 1, nev))
            :pagedown => (m.agentmon_event_sel = clamp(cur == 0 ? 1 : cur + 10, 1, nev))
            _ => nothing
        end
    else
        @match evt.key begin
            :up   => (m.agentmon_selected = max(1, m.agentmon_selected - 1); m.agentmon_scroll = 0; m.agentmon_event_sel = 0)
            :down => (m.agentmon_selected = min(max(1, n), m.agentmon_selected + 1); m.agentmon_scroll = 0; m.agentmon_event_sel = 0)
            _ => nothing
        end
    end
end

# ── Full event-history overlay (Enter on the detail pane) ─────────────────────
# Reads the complete Kaimon-owned event log from disk (not the 200-cap ring) so it
# shows the entire history, scrollable; Esc closes.

import JSON

# extract a readable one-line (possibly multi-line) body from a log record's data
function _log_record_text(kind::Symbol, data)
    g(d, k, default = "") = d isa AbstractDict ? get(d, k, default) : default
    if kind in (:assistant_text, :thought, :user_text)
        return string(g(g(data, "content", Dict()), "text", ""))
    elseif kind === :tool_use
        call = g(data, "call", Dict())
        return "▶ $(g(call, "title", "?")) ($(g(call, "kind", "?")))  in=$(JSON.json(g(call, "rawInput", nothing)))"
    elseif kind === :tool_result
        upd = g(data, "update", Dict())
        return "↳ $(g(upd, "status", "?")) $(g(upd, "toolCallId", ""))"
    elseif kind === :result
        return "stop=$(g(data, "stopReason", "?"))"
    elseif kind === :status
        return string(g(data, "status", ""))
    elseif kind === :plan
        return "plan: $(length(g(data, "entries", [])))  step(s)"
    end
    ""
end

# Build a Markdown transcript of the agent's full event log (read from disk — the
# entire history, not just the in-memory ring). Each event is a labelled section so
# assistant/thought bodies render with their own markdown; `---` separates them.
function _agent_history_markdown(id::AbstractString)
    path = _event_log_path(id)
    isfile(path) || return "_(no events logged)_"
    io = IOBuffer()
    for ln in eachline(path)
        isempty(strip(ln)) && continue
        rec = try
            JSON.parse(ln)
        catch
            continue
        end
        kind = Symbol(get(rec, "kind", "?"))
        body = _log_record_text(kind, get(rec, "data", Dict()))
        println(io, "**", kind, "**\n")
        isempty(strip(body)) || println(io, body, "\n")
        println(io, "---\n")
    end
    s = String(take!(io))
    isempty(strip(s)) ? "_(no events logged)_" : s
end

function _open_agent_history!(m::KaimonModel, id::AbstractString)
    isempty(id) && return
    m.agentmon_history_id = String(id)
    # Cached MarkdownPane (parses once; owns its own scroll — see update.jl).
    m.agentmon_history_pane = MarkdownPane(_agent_history_markdown(id); show_scrollbar = true)
    m.agentmon_history_open = true
end

function _handle_agents_history_key!(m::KaimonModel, evt::KeyEvent)
    if evt.key === :escape
        m.agentmon_history_open = false
        m.agentmon_history_pane = nothing
        return
    end
    m.agentmon_history_pane === nothing || handle_key!(m.agentmon_history_pane, evt)  # widget clamps
end

function _view_agents_history(m::KaimonModel, area::Rect, buf::Buffer)
    block = Block(
        title = "Agent $(m.agentmon_history_id) — full transcript",
        border_style = tstyle(:accent),
        title_style = tstyle(:accent, bold = true),
    )
    inner = render(block, area, buf)
    inner.width < 4 && return
    foot = bottom(inner)
    body = Rect(inner.x, inner.y, inner.width, max(0, inner.height - 1))
    m.agentmon_history_pane === nothing || render(m.agentmon_history_pane, body, buf)
    set_string!(buf, inner.x + 1, foot, "[↑↓/PgUp/PgDn] scroll  [Esc] close",
        tstyle(:text_dim); max_x = right(inner))
end

# Char keys: [x] closes a live agent (→ stays as :dead) or dismisses a dead one.
function _handle_agents_key!(m::KaimonModel, evt::KeyEvent)
    evt.key === :char || return
    ags = _agents_sorted()
    (isempty(ags) || m.agentmon_selected < 1 || m.agentmon_selected > length(ags)) && return
    a = ags[m.agentmon_selected]
    id = get(a, "id", "")
    if evt.char == 'x'
        if Symbol(get(a, "status", "")) === :dead
            _dismiss_agent!(id)            # remove a finished agent from the list
        else
            agent_close(id)                # kill → becomes :dead, stays for review
        end
        m.agentmon_selected = max(1, m.agentmon_selected - 1)
    end
end

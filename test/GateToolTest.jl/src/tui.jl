# ═══════════════════════════════════════════════════════════════════════════════
# TodoBoardModel — Tachikoma TUI for the kanban board
#
# Minimal Elm-pattern app: Model holds state, view() renders 3 columns,
# update!() handles key/mouse events for navigation.
# ═══════════════════════════════════════════════════════════════════════════════

using Tachikoma

# ── Model ─────────────────────────────────────────────────────────────────────

"""
    TodoBoardModel <: Tachikoma.Model

Holds the kanban board state: tasks, theme, selection cursor, and event log.
"""
@kwdef mutable struct TodoBoardModel <: Tachikoma.Model
    tasks::Vector{TaskItem} = TaskItem[]
    theme::BoardTheme = colorful
    event_log::Vector{String} = String[]
    selected_task::Int = 0
    selected_column::Int = 1   # 1=todo, 2=in_progress, 3=done
    quit::Bool = false
    tick::Int = 0
    show_detail::Bool = false
    # Cached layout rects from last view() for mouse hit-testing
    col_rects::Vector{Tachikoma.Rect} = Tachikoma.Rect[]
    log_rect::Tachikoma.Rect = Tachikoma.Rect(0, 0, 0, 0)
    # Resizable columns: relative weights, divider x positions, drag state
    col_weights::Vector{Int} = [10, 10, 10]
    divider_xs::Vector{Int} = Int[]
    dragging_divider::Int = 0   # 0=none, 1=between col1&2, 2=between col2&3
    drag_start_x::Int = 0
end

const MAX_EVENT_LOG = 50
const COLUMNS = (todo, in_progress, done)
const COLUMN_NAMES = ("Todo", "In Progress", "Done")

# ── Lifecycle ─────────────────────────────────────────────────────────────────

Tachikoma.should_quit(m::TodoBoardModel) = m.quit

# ── Update ────────────────────────────────────────────────────────────────────

function Tachikoma.update!(m::TodoBoardModel, evt::Tachikoma.Event)
    if evt isa Tachikoma.KeyEvent
        _handle_key!(m, evt)
    elseif evt isa Tachikoma.MouseEvent
        _handle_mouse!(m, evt)
    end
end

function _handle_key!(m::TodoBoardModel, evt::Tachikoma.KeyEvent)
    k = evt.key

    # Modal consumes all keys when open
    if m.show_detail
        if k == :escape ||
           (k == :char && evt.char == 'd') ||
           (k == :char && evt.char == 'q')
            m.show_detail = false
        end
        return
    end

    if k == :char && evt.char == 'q'
        m.quit = true
    elseif k == :left || (k == :char && evt.char == 'h')
        m.selected_column = max(1, m.selected_column - 1)
        _clamp_task_selection!(m)
    elseif k == :right || (k == :char && evt.char == 'l')
        m.selected_column = min(3, m.selected_column + 1)
        _clamp_task_selection!(m)
    elseif k == :up || (k == :char && evt.char == 'k')
        m.selected_task = max(1, m.selected_task - 1)
    elseif k == :down || (k == :char && evt.char == 'j')
        col_tasks = _column_tasks(m, m.selected_column)
        m.selected_task = min(length(col_tasks), m.selected_task + 1)
    elseif k == :enter
        _move_selected_task!(m)
    elseif k == :char && evt.char == 'd'
        _open_detail!(m)
    end
end

function _handle_mouse!(m::TodoBoardModel, evt::Tachikoma.MouseEvent)
    # Modal consumes all mouse events; click anywhere to close
    if m.show_detail
        if evt.button == Tachikoma.mouse_left
            m.show_detail = false
        end
        return
    end

    # Divider drag in progress — handle drag and release
    if m.dragging_divider > 0
        if evt.action == Tachikoma.mouse_drag
            delta = evt.x - m.drag_start_x
            delta == 0 && return
            i = m.dragging_divider
            new_w1 = m.col_weights[i] + delta
            new_w2 = m.col_weights[i+1] - delta
            if new_w1 >= 3 && new_w2 >= 3
                m.col_weights[i] = new_w1
                m.col_weights[i+1] = new_w2
                m.drag_start_x = evt.x
            end
        else
            push!(m.event_log, "Columns: [$(join(m.col_weights, " | "))]")
            _trim_log!(m)
            m.dragging_divider = 0
        end
        return
    end

    # Only handle presses below this point
    evt.action == Tachikoma.mouse_press || return

    # Check for divider hit (left-click on the │ separator)
    if evt.button == Tachikoma.mouse_left
        for (i, dx) in enumerate(m.divider_xs)
            if evt.x == dx
                m.dragging_divider = i
                m.drag_start_x = evt.x
                return
            end
        end
    end

    # Scroll wheel on any pane
    if evt.button == Tachikoma.mouse_scroll_up || evt.button == Tachikoma.mouse_scroll_down
        # (reserved for future scrolling)
        return
    end

    evt.button == Tachikoma.mouse_left || return

    # Hit-test column panes
    for (i, rect) in enumerate(m.col_rects)
        if _in_rect(rect, evt.x, evt.y)
            col_tasks = _column_tasks(m, i)
            row = evt.y - rect.y + 1
            if row >= 1 && row <= length(col_tasks)
                if m.selected_column == i && m.selected_task == row
                    _open_detail!(m)
                else
                    m.selected_column = i
                    m.selected_task = row
                end
            else
                m.selected_column = i
                _clamp_task_selection!(m)
            end
            return
        end
    end

    # Hit-test event log pane — left-click does nothing (scroll wheel reserved)
    if _in_rect(m.log_rect, evt.x, evt.y)
        return
    end
end

function _in_rect(r::Tachikoma.Rect, x::Int, y::Int)
    r.width == 0 && return false
    x >= r.x && x <= Tachikoma.right(r) && y >= r.y && y <= Tachikoma.bottom(r)
end

function _column_tasks(m::TodoBoardModel, col::Int)
    status = COLUMNS[clamp(col, 1, 3)]
    return filter(t -> t.status == status, m.tasks)
end

function _clamp_task_selection!(m::TodoBoardModel)
    col_tasks = _column_tasks(m, m.selected_column)
    m.selected_task = clamp(m.selected_task, isempty(col_tasks) ? 0 : 1, length(col_tasks))
end

function _move_selected_task!(m::TodoBoardModel)
    m.selected_column > 3 && return
    col_tasks = _column_tasks(m, m.selected_column)
    (m.selected_task < 1 || m.selected_task > length(col_tasks)) && return

    task = col_tasks[m.selected_task]
    next_col = min(m.selected_column + 1, 3)
    next_status = COLUMNS[next_col]

    idx = findfirst(t -> t.id == task.id, m.tasks)
    idx === nothing && return
    old = m.tasks[idx]
    m.tasks[idx] =
        TaskItem(old.id, old.title, old.description, old.priority, next_status, old.tags)
    m.selected_column = next_col
    _clamp_task_selection!(m)
    push!(m.event_log, "Moved #$(task.id) → $next_status")
    _trim_log!(m)
end

function _trim_log!(m::TodoBoardModel)
    while length(m.event_log) > MAX_EVENT_LOG
        popfirst!(m.event_log)
    end
end

function _open_detail!(m::TodoBoardModel)
    col_tasks = _column_tasks(m, m.selected_column)
    (m.selected_task < 1 || m.selected_task > length(col_tasks)) && return
    m.show_detail = true
end

function _selected_task(m::TodoBoardModel)
    col_tasks = _column_tasks(m, m.selected_column)
    (m.selected_task < 1 || m.selected_task > length(col_tasks)) && return nothing
    return col_tasks[m.selected_task]
end

# ── View ──────────────────────────────────────────────────────────────────────

function Tachikoma.view(m::TodoBoardModel, f::Tachikoma.Frame)
    m.tick += 1
    buf = f.buffer
    area = f.area

    # Outer border
    theme_label = m.theme == colorful ? "●" : m.theme == minimal ? "—" : "▪"
    outer = Tachikoma.Block(
        title = " TodoBoard $theme_label ",
        border_style = Tachikoma.tstyle(:border),
    )
    content = Tachikoma.render(outer, area, buf)

    # Main layout: columns | event log (compact hides the log)
    log_h = m.theme == compact ? 0 : 8
    constraints =
        log_h > 0 ? [Tachikoma.Fill(1), Tachikoma.Fixed(log_h)] : [Tachikoma.Fill(1)]
    main_layout = Tachikoma.Layout(Tachikoma.Vertical, constraints)
    rects = Tachikoma.split_layout(main_layout, content)
    board_area = rects[1]
    log_area = length(rects) >= 2 ? rects[2] : nothing

    # 3 resizable columns — weights drive Fill proportions
    col_layout = Tachikoma.Layout(
        Tachikoma.Horizontal,
        [
            Tachikoma.Fill(m.col_weights[1]),
            Tachikoma.Fill(m.col_weights[2]),
            Tachikoma.Fill(m.col_weights[3]),
        ];
        spacing = 1,
    )
    col_rects = Tachikoma.split_layout(col_layout, board_area)
    resize!(m.col_rects, 3)
    m.col_rects .= col_rects

    # Cache divider x positions (the 1-char gap between columns) for drag hit-testing
    resize!(m.divider_xs, 2)
    for i = 1:2
        m.divider_xs[i] = Tachikoma.right(col_rects[i]) + 1
    end

    for (i, (col_rect, status, name)) in enumerate(zip(col_rects, COLUMNS, COLUMN_NAMES))
        is_selected = (i == m.selected_column)
        col_count = length(_column_tasks(m, i))
        if m.theme == minimal
            border_style =
                is_selected ? Tachikoma.Style(fg = Tachikoma.Color256(252)) :
                Tachikoma.Style(fg = Tachikoma.Color256(240))
            title = " $name ($col_count) "
        elseif m.theme == compact
            border_style =
                is_selected ? Tachikoma.Style(fg = Tachikoma.Color256(81), bold = true) :
                Tachikoma.Style(fg = Tachikoma.Color256(238))
            title = " $name [$col_count] "
        else  # colorful
            border_style =
                is_selected ? Tachikoma.tstyle(:border_focus, bold = true) :
                Tachikoma.tstyle(:border)
            title = " $name "
        end
        col_block = Tachikoma.Block(title = title, border_style = border_style)
        inner = Tachikoma.render(col_block, col_rect, buf)
        _render_column_tasks!(m, buf, inner, i)
    end

    # Event log panel (hidden in compact theme)
    if log_area !== nothing
        log_style =
            m.theme == minimal ? Tachikoma.Style(fg = Tachikoma.Color256(240)) :
            Tachikoma.tstyle(:border)
        log_block = Tachikoma.Block(title = " Events ", border_style = log_style)
        log_inner = Tachikoma.render(log_block, log_area, buf)
        m.log_rect = log_inner
        _render_event_log!(m, buf, log_inner)
    else
        m.log_rect = Tachikoma.Rect(0, 0, 0, 0)
    end

    # Detail modal overlay
    if m.show_detail
        _render_detail_modal!(m, buf, area)
    end
end

const TAG_COLORS = Dict{Symbol,Tachikoma.Color256}(
    :red => Tachikoma.Color256(196),
    :green => Tachikoma.Color256(71),
    :blue => Tachikoma.Color256(75),
    :yellow => Tachikoma.Color256(220),
    :orange => Tachikoma.Color256(208),
    :purple => Tachikoma.Color256(141),
    :cyan => Tachikoma.Color256(80),
    :gray => Tachikoma.Color256(245),
    :gold => Tachikoma.Color256(178),
)
const TAG_COLOR_DEFAULT = Tachikoma.Color256(250)

function _render_column_tasks!(
    m::TodoBoardModel,
    buf::Tachikoma.Buffer,
    area::Tachikoma.Rect,
    col_idx::Int,
)
    col_tasks = _column_tasks(m, col_idx)
    is_active_col = (col_idx == m.selected_column)

    for (i, task) in enumerate(col_tasks)
        y = area.y + i - 1
        y > Tachikoma.bottom(area) && break

        is_selected = is_active_col && i == m.selected_task
        max_w = Tachikoma.right(area) - area.x + 1
        max_x = area.x + max_w - 1

        if m.theme == minimal
            marker = is_selected ? "> " : "  "
            line = "$(marker)#$(task.id) $(task.title)"
            style =
                is_selected ? Tachikoma.Style(fg = Tachikoma.Color256(255), bold = true) :
                Tachikoma.Style(fg = Tachikoma.Color256(250))
        elseif m.theme == compact
            pchar =
                task.priority == critical ? '!' :
                task.priority == high ? '+' : task.priority == medium ? '-' : ' '
            cursor = is_selected ? ">" : " "
            line = "$(cursor)$(pchar)#$(task.id) $(task.title)"
            style = if is_selected
                Tachikoma.Style(fg = Tachikoma.Color256(81), bold = true)
            else
                Tachikoma.Style(fg = Tachikoma.Color256(252))
            end
        else  # colorful
            pchar =
                task.priority == critical ? '!' :
                task.priority == high ? '▲' : task.priority == medium ? '●' : '○'
            pcolor =
                task.priority == critical ? Tachikoma.Color256(196) :
                task.priority == high ? Tachikoma.Color256(208) :
                task.priority == medium ? Tachikoma.Color256(226) : Tachikoma.Color256(250)
            marker = is_selected ? "▸ " : "  "
            line = "$(marker)$(pchar) #$(task.id) $(task.title)"
            style =
                is_selected ? Tachikoma.Style(fg = Tachikoma.Color256(255), bold = true) :
                Tachikoma.Style(fg = pcolor)
        end

        display_line = length(line) > max_w ? line[1:max_w] : line
        Tachikoma.set_string!(buf, area.x, y, display_line, style)

        # Render tags after title with their own colors
        if !isempty(task.tags)
            x_pos = area.x + length(display_line) + 1
            for (ti, tag) in enumerate(task.tags)
                label = ti == 1 ? " $(tag.name)" : " $(tag.name)"
                x_pos + length(label) - 1 > max_x && break
                tag_fg = get(TAG_COLORS, tag.color, TAG_COLOR_DEFAULT)
                tag_style = if is_selected
                    Tachikoma.Style(fg = tag_fg, bold = true)
                elseif m.theme == minimal
                    Tachikoma.Style(fg = Tachikoma.Color256(245))
                else
                    Tachikoma.Style(fg = tag_fg)
                end
                Tachikoma.set_string!(buf, x_pos, y, label, tag_style; max_x = max_x)
                x_pos += length(label)
            end
        end
    end
end

function _render_event_log!(m::TodoBoardModel, buf::Tachikoma.Buffer, area::Tachikoma.Rect)
    visible = min(area.height, length(m.event_log))
    start = max(1, length(m.event_log) - visible + 1)
    style = Tachikoma.tstyle(:text_dim)

    for i = 0:(visible-1)
        idx = start + i
        y = area.y + i
        y > Tachikoma.bottom(area) && break
        msg = m.event_log[idx]
        max_w = Tachikoma.right(area) - area.x + 1
        display_msg = length(msg) > max_w ? msg[1:max_w] : msg
        Tachikoma.set_string!(buf, area.x, y, display_msg, style)
    end
end

function _render_detail_modal!(
    m::TodoBoardModel,
    buf::Tachikoma.Buffer,
    area::Tachikoma.Rect,
)
    task = _selected_task(m)
    task === nothing && return

    # Center a modal ~60% of screen, clamped
    mw = clamp(div(area.width * 3, 5), 30, area.width - 4)
    mh = clamp(div(area.height * 3, 5), 10, area.height - 2)
    mx = area.x + div(area.width - mw, 2)
    my = area.y + div(area.height - mh, 2)
    modal_area = Tachikoma.Rect(mx, my, mw, mh)

    # Clear the modal area
    blank_style = Tachikoma.Style()
    blank_row = ' '^mw
    for dy = 0:(mh-1)
        Tachikoma.set_string!(buf, mx, my + dy, blank_row, blank_style)
    end

    # Border
    border_style = Tachikoma.tstyle(:border_focus, bold = true)
    block = Tachikoma.Block(title = " Task #$(task.id) ", border_style = border_style)
    inner = Tachikoma.render(block, modal_area, buf)

    max_w = Tachikoma.right(inner) - inner.x + 1
    max_x = inner.x + max_w - 1
    row = inner.y

    label_style = Tachikoma.Style(fg = Tachikoma.Color256(242))
    value_style = Tachikoma.Style(fg = Tachikoma.Color256(255))
    dim_style = Tachikoma.Style(fg = Tachikoma.Color256(242), italic = true)

    # Title
    _modal_line!(
        buf,
        inner.x,
        row,
        max_x,
        "Title:    ",
        task.title,
        label_style,
        value_style,
    )
    row += 1

    # Priority with color
    pname = uppercase(string(task.priority))
    pcolor =
        task.priority == critical ? Tachikoma.Color256(196) :
        task.priority == high ? Tachikoma.Color256(208) :
        task.priority == medium ? Tachikoma.Color256(226) : Tachikoma.Color256(250)
    _modal_line!(
        buf,
        inner.x,
        row,
        max_x,
        "Priority: ",
        pname,
        label_style,
        Tachikoma.Style(fg = pcolor, bold = true),
    )
    row += 1

    # Status
    _modal_line!(
        buf,
        inner.x,
        row,
        max_x,
        "Status:   ",
        string(task.status),
        label_style,
        value_style,
    )
    row += 1

    # Blank separator
    row += 1

    # Description (word-wrapped)
    Tachikoma.set_string!(buf, inner.x, row, "Description:", label_style; max_x)
    row += 1
    desc = isempty(task.description) ? "(none)" : task.description
    desc_style = isempty(task.description) ? dim_style : value_style
    for line in _word_wrap(desc, max_w)
        row > Tachikoma.bottom(inner) && break
        Tachikoma.set_string!(buf, inner.x, row, line, desc_style; max_x)
        row += 1
    end

    # Blank separator
    row += 1

    # Tags
    if row <= Tachikoma.bottom(inner)
        if isempty(task.tags)
            _modal_line!(
                buf,
                inner.x,
                row,
                max_x,
                "Tags:     ",
                "(none)",
                label_style,
                dim_style,
            )
        else
            Tachikoma.set_string!(buf, inner.x, row, "Tags:", label_style; max_x)
            x_pos = inner.x + 6
            for tag in task.tags
                label = "[$(tag.name)]"
                x_pos + length(label) > max_x && break
                tag_fg = get(TAG_COLORS, tag.color, TAG_COLOR_DEFAULT)
                Tachikoma.set_string!(
                    buf,
                    x_pos,
                    row,
                    label,
                    Tachikoma.Style(fg = tag_fg, bold = true);
                    max_x,
                )
                x_pos += length(label) + 1
            end
        end
        row += 1
    end

    # Footer hint
    row = Tachikoma.bottom(inner)
    if row >= inner.y
        hint = " [d] close "
        hx = inner.x + div(max_w - length(hint), 2)
        Tachikoma.set_string!(
            buf,
            hx,
            row,
            hint,
            Tachikoma.Style(fg = Tachikoma.Color256(242));
            max_x,
        )
    end
end

function _modal_line!(buf, x, y, max_x, label, value, label_style, value_style)
    Tachikoma.set_string!(buf, x, y, label, label_style; max_x)
    Tachikoma.set_string!(buf, x + length(label), y, value, value_style; max_x)
end

function _word_wrap(text::String, width::Int)
    width < 1 && return String[]
    lines = String[]
    for paragraph in split(text, '\n')
        words = split(paragraph)
        isempty(words) && (push!(lines, ""); continue)
        current = string(words[1])
        for w in words[2:end]
            if length(current) + 1 + length(w) > width
                push!(lines, current)
                current = string(w)
            else
                current *= " " * string(w)
            end
        end
        push!(lines, current)
    end
    return lines
end

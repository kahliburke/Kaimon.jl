# ── Collection Manager Modal View ────────────────────────────────────────────

"""Render the Collection Manager modal overlay."""
function _view_search_manage(m::KaimonModel, area::Rect, buf::Buffer)
    _dim_area!(buf, area)

    entries = m.search_manage_entries
    n = length(entries)

    # Determine how many rows the bottom section needs
    bottom_h = if m.search_manage_adding
        m.search_manage_add_phase == 1 ? 6 : 14
    elseif m.search_manage_configuring
        12
    elseif m.search_manage_confirm != :none
        2
    else
        3
    end

    h = min(n + 6 + bottom_h, area.height - 2)
    w = min(round(Int, area.width * 0.85), area.width - 4)
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = if animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, m.tick; box = BOX_HEAVY, intensity = 0.12)
        title = "Collection Manager"
        if rect.width > length(title) + 4
            set_string!(buf, rect.x + 2, rect.y, title, tstyle(:accent, bold = true))
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = "Collection Manager",
                border_style = border_s,
                title_style = border_s,
                box = BOX_HEAVY,
            ),
            rect,
            buf,
        )
    end
    inner.width < 4 && return

    # Clear interior
    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style(bg=Tachikoma.theme().bg))
        end
    end

    # Use Layout to split inner area: table (Fill) | bottom (Fixed)
    regions = split_layout(Layout(Vertical, [Fill(), Fixed(bottom_h)]), inner)
    table_area = regions[1]
    bottom_area = regions[2]

    # ── Entries DataTable ──
    _sync_search_manage_table!(m)
    dt = m.search_manage_table
    if dt !== nothing && n > 0
        dt.tick = m.tick
        render(dt, table_area, buf)
    elseif n == 0
        set_string!(
            buf,
            table_area.x + 3,
            table_area.y + 1,
            "No sessions connected",
            tstyle(:text_dim),
        )
    end

    # ── Bottom section ──
    x = bottom_area.x + 1
    y = bottom_area.y
    max_y = bottom(bottom_area)
    max_w = bottom_area.width - 2

    if m.search_manage_adding
        _view_search_manage_add(m, x, y, max_y, max_w, buf)
        return
    end

    if m.search_manage_configuring
        _view_search_manage_configure(m, x, y, max_y, max_w, buf, entries, n)
        return
    end

    # Key hints
    if m.search_manage_confirm != :none && y <= max_y
        sel = clamp(m.search_manage_selected, 1, max(1, n))
        entry = n > 0 ? entries[sel] : nothing
        col_name = entry !== nothing ? entry.collection : ""
        op_label = m.search_manage_confirm == :delete ? "Delete" : "Reindex"
        _write_spans!(
            buf,
            x,
            y,
            [
                ("$op_label '$(col_name)'? ", tstyle(:warning, bold = true)),
                ("[y]", tstyle(:accent)),
                (" confirm  ", tstyle(:text_dim)),
                ("[n/Esc]", tstyle(:accent)),
                (" cancel", tstyle(:text_dim)),
            ],
        )
    else
        if y <= max_y
            _write_spans!(
                buf,
                x,
                y,
                [
                    ("↑↓", tstyle(:accent)),
                    (" navigate  ", tstyle(:text_dim)),
                    ("i", tstyle(:accent)),
                    (" index  ", tstyle(:text_dim)),
                    ("s", tstyle(:accent)),
                    (" sync  ", tstyle(:text_dim)),
                    ("R", tstyle(:accent)),
                    (" reindex  ", tstyle(:text_dim)),
                    ("x", tstyle(:accent)),
                    (" delete", tstyle(:text_dim)),
                ],
            )
            y += 1
        end
        if y <= max_y
            _write_spans!(
                buf,
                x,
                y,
                [
                    ("a", tstyle(:accent)),
                    (" add  ", tstyle(:text_dim)),
                    ("c", tstyle(:accent)),
                    (" configure  ", tstyle(:text_dim)),
                    ("r", tstyle(:accent)),
                    (" refresh  ", tstyle(:text_dim)),
                    ("Esc", tstyle(:accent)),
                    (" close", tstyle(:text_dim)),
                ],
            )
        end
    end
end

# ── DataTable sync for Collection Manager entries ──────────────────────────

"""Status icon character for an entry."""
function _manage_status_icon(status::Symbol)
    status == :connected ? "●" :
    status == :evaluating ? "◐" :
    status == :disconnected ? "○" :
    status == :pwd ? "◇" :
    status == :external ? "◆" : "○"
end

"""Build/rebuild the DataTable from search_manage_entries."""
function _sync_search_manage_table!(m::KaimonModel)
    entries = m.search_manage_entries
    n = length(entries)
    sel = m.search_manage_selected
    existing = Set(m.search_collections)

    needs_rebuild = m.search_manage_table === nothing ||
        m._search_manage_table_synced != n ||
        m._search_manage_table_sel != sel

    if !needs_rebuild && (
        !isempty(m.search_manage_col_info) ||
        !isempty(m.search_manage_op_status) ||
        !isempty(m.search_manage_stale) ||
        any(e -> e.status == :evaluating, entries)
    )
        needs_rebuild = true
    end

    needs_rebuild || return

    # Build column data
    labels = String[]
    collections = String[]
    vectors = String[]
    statuses = String[]

    for entry in entries
        # Session column: icon + label
        icon = _manage_status_icon(entry.status)
        label = entry.label
        if length(label) > 18
            label = first(label, 17) * "…"
        end
        push!(labels, "$icon $label")

        # Collection column
        col = entry.collection
        push!(collections, isempty(col) ? "—" : col)

        # Vectors column
        info = get(m.search_manage_col_info, col, Dict())
        if !isempty(info)
            vcount = get(info, "vectors_count", get(info, "points_count", nothing))
            push!(vectors, vcount !== nothing ? string(vcount) : "—")
        else
            push!(vectors, col ∈ existing ? "" : "—")
        end

        # Status column
        op_status = get(m.search_manage_op_status, col, "")
        if !isempty(op_status)
            push!(statuses, op_status)
        elseif col ∉ existing
            push!(statuses, "not indexed")
        else
            stale = get(m.search_manage_stale, col, -1)
            if stale == 0
                push!(statuses, "up to date")
            elseif stale > 0
                push!(statuses, "$stale stale")
            else
                push!(statuses, "—")
            end
        end
    end

    dt = DataTable(
        [
            DataColumn("Session", labels; width=22),
            DataColumn("Collection", collections; width=14),
            DataColumn("Vectors", vectors; width=8, align=col_right),
            DataColumn("Status", statuses),
        ];
        selected = clamp(sel, 0, n),
        tick = m.tick,
    )

    m.search_manage_table = dt
    m._search_manage_table_synced = n
    m._search_manage_table_sel = sel
end

# ── Add Project Sub-View ─────────────────────────────────────────────────────

"""Render the add-external-project sub-view inside the Collection Manager modal."""
function _view_search_manage_add(
    m::KaimonModel,
    x::Int,
    y::Int,
    max_y::Int,
    max_w::Int,
    buf::Buffer,
)
    if m.search_manage_add_phase == 1
        # Phase 1: path input
        if y <= max_y
            set_string!(buf, x, y, "Add External Project", tstyle(:accent, bold = true))
            y += 1
        end
        if y <= max_y
            set_string!(
                buf,
                x,
                y,
                "Enter project path (Tab to complete):",
                tstyle(:text_dim),
            )
            y += 1
        end
        if y <= max_y && m.search_manage_path_input !== nothing
            input_area = Rect(x, y, min(max_w, 56), 1)
            render(m.search_manage_path_input, input_area, buf)
            y += 2
        end
        # Hints
        if y <= max_y
            _write_spans!(
                buf,
                x,
                y,
                [
                    ("Enter", tstyle(:accent)),
                    (" detect project  ", tstyle(:text_dim)),
                    ("Tab", tstyle(:accent)),
                    (" complete  ", tstyle(:text_dim)),
                    ("Esc", tstyle(:accent)),
                    (" cancel", tstyle(:text_dim)),
                ],
            )
        end
    else
        # Phase 2: detected type + editable config
        detected = m.search_manage_detected
        if y <= max_y
            set_string!(buf, x, y, "Add Project", tstyle(:accent, bold = true))
            y += 1
        end
        if y <= max_y
            set_string!(buf, x, y, "Path: ", tstyle(:text_dim))
            path_display = _short_path(m.search_manage_config_path)
            set_string!(buf, x + 6, y, first(path_display, max_w - 8), tstyle(:text))
            y += 1
        end
        if y <= max_y
            set_string!(buf, x, y, "Type: ", tstyle(:text_dim))
            type_label = detected.type
            if detected.git_aware
                type_label *= " (git-aware)"
            end
            set_string!(buf, x + 6, y, type_label, tstyle(:accent))
            y += 1
        end
        y += 1
        # Editable fields
        _render_config_fields(m, x, y, max_y, max_w, buf)
    end
end

# ── Configure Project Sub-View ───────────────────────────────────────────────

"""Render the configure-project sub-view inside the Collection Manager modal."""
function _view_search_manage_configure(
    m::KaimonModel,
    x::Int,
    y::Int,
    max_y::Int,
    max_w::Int,
    buf::Buffer,
    entries,
    n::Int,
)
    sel = clamp(m.search_manage_selected, 1, max(1, n))
    entry = n > 0 ? entries[sel] : nothing
    entry === nothing && return

    if y <= max_y
        set_string!(buf, x, y, "Configure: ", tstyle(:accent, bold = true))
        set_string!(buf, x + 11, y, entry.label, tstyle(:text))
        y += 1
    end
    y += 1
    _render_config_fields(m, x, y, max_y, max_w, buf)
end

# ── Shared config field renderer ─────────────────────────────────────────────

"""Render the editable dirs/exts fields with Auto-detect/Save/Cancel buttons (shared by add phase 2 and configure)."""
function _render_config_fields(
    m::KaimonModel,
    x::Int,
    y::Int,
    max_y::Int,
    max_w::Int,
    buf::Buffer,
)
    field = m.search_manage_config_field

    # Helper to render a TextInput field row
    function _config_field!(field_idx, label, input)
        y > max_y && return
        active = field == field_idx
        cursor = active ? "▸ " : "  "
        label_style = active ? tstyle(:accent, bold = true) : tstyle(:text_dim)
        set_string!(buf, x, y, cursor, label_style; max_x=x+max_w)
        if input !== nothing
            input.tick = m.tick
            input.focused = active
            input_area = Rect(x + 2, y, max_w - 2, 1)
            if active
                render(input, input_area, buf)
            else
                set_string!(buf, x + 2, y, label, label_style; max_x=x+max_w)
                set_string!(buf, x + 2 + length(label), y,
                    Tachikoma.text(input), tstyle(:text); max_x=x+max_w)
            end
        end
        y += 1
    end

    # Dirs field
    _config_field!(1, "Dirs: ", m.search_manage_dirs_input)

    # Extensions field
    _config_field!(2, "Exts: ", m.search_manage_exts_input)

    # Exclude dirs field
    _config_field!(3, "Exclude: ", m.search_manage_exclude_input)

    if y <= max_y
        set_string!(buf, x + 2, y,
            "(comma-separated, relative to project root)",
            tstyle(:text_dim); max_x=x+max_w)
        y += 1
    end

    # Auto-detect button
    y += 1
    if y <= max_y
        detect_style = field == 4 ? tstyle(:accent, bold = true) : tstyle(:text_dim)
        detect_cursor = field == 4 ? "▸ " : "  "
        set_string!(buf, x, y, detect_cursor, detect_style)
        set_string!(buf, x + 2, y, "[ Auto-detect ]", detect_style)

        # Show detected type hint if available
        detected = m.search_manage_detected
        if !isempty(detected.type)
            hint = "Detected: $(detected.type)"
            if detected.git_aware
                hint *= " (git-aware)"
            end
            set_string!(buf, x + 20, y, hint, tstyle(:text_dim))
        end
        y += 1
    end

    # Save / Cancel buttons
    y += 1
    if y <= max_y
        save_style = field == 5 ? tstyle(:success, bold = true) : tstyle(:text_dim)
        save_cursor = field == 5 ? "▸ " : "  "
        cancel_style = field == 6 ? tstyle(:warning, bold = true) : tstyle(:text_dim)
        cancel_cursor = field == 6 ? "▸ " : "  "

        set_string!(buf, x, y, save_cursor, save_style)
        set_string!(buf, x + 2, y, "[ Save ]", save_style)
        set_string!(buf, x + 14, y, cancel_cursor, cancel_style)
        set_string!(buf, x + 16, y, "[ Cancel ]", cancel_style)
        y += 1
    end

    # Hints
    y += 1
    if y <= max_y
        _write_spans!(
            buf,
            x,
            y,
            [
                ("Tab/↑↓", tstyle(:accent)),
                (" navigate  ", tstyle(:text_dim)),
                ("Enter", tstyle(:accent)),
                (" confirm  ", tstyle(:text_dim)),
                ("Esc", tstyle(:accent)),
                (" cancel", tstyle(:text_dim)),
            ],
        )
    end
end

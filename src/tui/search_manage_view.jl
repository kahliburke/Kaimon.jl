# ── Collection Manager Modal View ────────────────────────────────────────────

"""Render the Collection Manager modal overlay."""
function _view_search_manage(m::KaimonModel, area::Rect, buf::Buffer)
    _dim_area!(buf, area)

    entries = m.search_manage_entries
    n = length(entries)

    # Layout sizing: header + separator + entries + blank + hints + confirm
    h = min(n + 9, area.height - 2)
    w = min(68, area.width - 4)
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = if animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, m.tick; box = BOX_HEAVY, intensity = 0.12)
        title = " Collection Manager "
        if rect.width > length(title) + 4
            set_string!(buf, rect.x + 2, rect.y, title, tstyle(:accent, bold = true))
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = " Collection Manager ",
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
            set_char!(buf, col, row, ' ', Style())
        end
    end

    y = inner.y
    x = inner.x + 1
    max_y = bottom(inner)
    max_w = inner.width - 2

    # Column headers
    _write_spans!(buf, x, y, [("  Session", tstyle(:text, bold = true))])
    # Right-aligned columns
    col_col_x = x + 24
    vec_col_x = x + 40
    stat_col_x = x + 49
    if col_col_x + 10 < x + max_w
        set_string!(buf, col_col_x, y, "Collection", tstyle(:text, bold = true))
    end
    if vec_col_x + 7 < x + max_w
        set_string!(buf, vec_col_x, y, "Vectors", tstyle(:text, bold = true))
    end
    if stat_col_x + 6 < x + max_w
        set_string!(buf, stat_col_x, y, "Status", tstyle(:text, bold = true))
    end
    y += 1

    # Separator
    sep = "─"^min(max_w, 64)
    y <= max_y && (set_string!(buf, x, y, sep, tstyle(:border)); y += 1)

    # Entries
    existing = Set(m.search_collections)
    for (i, entry) in enumerate(entries)
        y > max_y - 4 && break
        is_selected = i == m.search_manage_selected

        # Status icon
        icon, icon_style = if entry.status == :connected
            "● ", tstyle(:success)
        elseif entry.status == :disconnected
            "○ ", tstyle(:error)
        elseif entry.status == :pwd
            "◇ ", tstyle(:text_dim)
        elseif entry.status == :external
            "◆ ", tstyle(:text)
        else
            "○ ", tstyle(:text_dim)
        end

        cursor = is_selected ? "▸" : " "
        cursor_style = is_selected ? tstyle(:accent, bold = true) : tstyle(:text)

        # Session label (truncated)
        label = entry.label
        max_label = 20
        if length(label) > max_label
            label = first(label, max_label - 1) * "…"
        end
        label_style = is_selected ? tstyle(:accent, bold = true) : tstyle(:text)

        set_string!(buf, x, y, cursor, cursor_style)
        set_string!(buf, x + 1, y, icon, icon_style)
        set_string!(buf, x + 3, y, label, label_style)

        # Collection name
        col = entry.collection
        if !isempty(col) && col_col_x + length(col) < x + max_w
            col_display = length(col) > 14 ? first(col, 13) * "…" : col
            col_style = col in existing ? tstyle(:accent) : tstyle(:text_dim)
            set_string!(buf, col_col_x, y, col_display, col_style)
        end

        # Vector count
        info = get(m.search_manage_col_info, col, Dict())
        if !isempty(info) && vec_col_x + 7 < x + max_w
            vcount = get(info, "vectors_count", get(info, "points_count", nothing))
            vstr = vcount !== nothing ? string(vcount) : "—"
            set_string!(buf, vec_col_x, y, lpad(vstr, 7), tstyle(:text))
        elseif col ∉ existing && vec_col_x + 7 < x + max_w
            set_string!(buf, vec_col_x, y, "      —", tstyle(:text_dim))
        end

        # Status column
        if stat_col_x + 4 < x + max_w
            op_status = get(m.search_manage_op_status, col, "")
            if !isempty(op_status)
                # Show operation in progress
                set_string!(buf, stat_col_x, y, op_status, tstyle(:warning))
            elseif col ∉ existing
                set_string!(buf, stat_col_x, y, "not indexed", tstyle(:text_dim))
            else
                stale = get(m.search_manage_stale, col, -1)
                if stale == 0
                    set_string!(buf, stat_col_x, y, "up to date", tstyle(:success))
                elseif stale > 0
                    set_string!(buf, stat_col_x, y, "$stale stale", tstyle(:warning))
                elseif stale == -1 && !isempty(info)
                    set_string!(buf, stat_col_x, y, "—", tstyle(:text_dim))
                end
            end
        end

        y += 1
    end

    if n == 0
        y <= max_y &&
            (set_string!(buf, x + 2, y, "No sessions connected", tstyle(:text_dim)); y += 1)
    end

    y += 1

    # ── Sub-views: add project / configure ──
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
            set_string!(buf, x + 6, y, detected.type, tstyle(:accent))
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

"""Render the editable dirs/exts fields with Save/Cancel buttons (shared by add phase 2 and configure)."""
function _render_config_fields(
    m::KaimonModel,
    x::Int,
    y::Int,
    max_y::Int,
    max_w::Int,
    buf::Buffer,
)
    field = m.search_manage_config_field

    # Dirs field
    if y <= max_y
        cursor = field == 1 ? "▸ " : "  "
        label_style = field == 1 ? tstyle(:accent, bold = true) : tstyle(:text_dim)
        set_string!(buf, x, y, cursor, label_style)
        set_string!(buf, x + 2, y, "Dirs: ", label_style)
        val = m.search_manage_config_dirs
        val_style = field == 1 ? tstyle(:accent) : tstyle(:text)
        display_val = first(val, max_w - 10)
        set_string!(buf, x + 8, y, display_val, val_style)
        if field == 1
            cx = x + 8 + length(display_val)
            cx <= x + max_w && set_string!(buf, cx, y, "▏", tstyle(:accent))
        end
        y += 1
    end

    # Extensions field
    if y <= max_y
        cursor = field == 2 ? "▸ " : "  "
        label_style = field == 2 ? tstyle(:accent, bold = true) : tstyle(:text_dim)
        set_string!(buf, x, y, cursor, label_style)
        set_string!(buf, x + 2, y, "Exts: ", label_style)
        val = m.search_manage_config_exts
        val_style = field == 2 ? tstyle(:accent) : tstyle(:text)
        display_val = first(val, max_w - 10)
        set_string!(buf, x + 8, y, display_val, val_style)
        if field == 2
            cx = x + 8 + length(display_val)
            cx <= x + max_w && set_string!(buf, cx, y, "▏", tstyle(:accent))
        end
        y += 1
    end

    if y <= max_y
        set_string!(
            buf,
            x + 2,
            y,
            "(comma-separated, relative to project root)",
            tstyle(:text_dim),
        )
        y += 1
    end

    # Save / Cancel buttons
    y += 1
    if y <= max_y
        save_style = field == 3 ? tstyle(:success, bold = true) : tstyle(:text_dim)
        save_cursor = field == 3 ? "▸ " : "  "
        cancel_style = field == 4 ? tstyle(:warning, bold = true) : tstyle(:text_dim)
        cancel_cursor = field == 4 ? "▸ " : "  "

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

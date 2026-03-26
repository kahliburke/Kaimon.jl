"""Render the search config overlay panel."""
function _view_search_config(m::KaimonModel, area::Rect, buf::Buffer)
    _dim_area!(buf, area)

    n_models = length(m.search_config_models)
    h = min(n_models + 14, area.height - 2)
    w = min(round(Int, area.width * 0.8), area.width - 4)
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = if animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, m.tick; box = BOX_HEAVY, intensity = 0.12)
        title = "Search Config"
        if rect.width > length(title) + 4
            set_string!(buf, rect.x + 2, rect.y, title, tstyle(:accent, bold = true))
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = "Search Config",
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
            set_char!(buf, col, row, ' ', Style(bg = Tachikoma.theme().bg))
        end
    end

    # Determine how many lines the collection info section needs
    col_info = m.search_config_col_info
    has_col_info = !isempty(col_info) && !haskey(col_info, "error")
    col_info_h = has_col_info ? 4 : 1  # 4 lines with data, 1 for "loading..."
    confirm_h = m.search_config_confirm ? 2 : 0

    # Layout: header(1) + model list(Fill) + blank(1) + col_info + blank(1) + results(1) + blank(1) + hints(2) + confirm
    regions = split_layout(
        Layout(Vertical, [
            Fixed(1),                    # "Embedding Model" header
            Fill(1),                     # model list (scrollable)
            Fixed(1),                    # blank
            Fixed(col_info_h),           # collection info
            Fixed(1),                    # blank
            Fixed(1),                    # results per search
            Fixed(1),                    # blank
            Fixed(2),                    # key hints
            Fixed(confirm_h),            # reindex confirmation (0 if hidden)
        ]),
        inner,
    )

    x = inner.x + 1

    # ── Section 1: Header ──
    set_string!(buf, x, regions[1].y, "Embedding Model", tstyle(:text, bold = true))

    # ── Section 2: Model list ──
    model_area = regions[2]
    for (i, entry) in enumerate(m.search_config_models)
        row_y = model_area.y + (i - 1)
        row_y > bottom(model_area) && break

        is_selected = i == m.search_config_selected
        is_active = entry.name == m.search_embedding_model ||
            (entry.name == "Custom..." && !haskey(EMBEDDING_CONFIGS, m.search_embedding_model) && !isempty(m.search_embedding_model))

        marker = is_selected ? "▸ " : "  "
        name_style = is_selected ? tstyle(:accent, bold = true) : tstyle(:text)

        set_string!(buf, x, row_y, marker, name_style; max_x = right(inner))

        if entry.name == "Custom..."
            cx = x + length(marker)
            if m.search_config_custom_editing && is_selected
                m.search_config_custom_input.tick = m.tick
                m.search_config_custom_input.focused = true
                render(m.search_config_custom_input, Rect(cx, row_y, inner.width - cx + inner.x, 1), buf)
            else
                label = is_active ? "Custom: $(m.search_embedding_model)" : "Custom..."
                set_string!(buf, cx, row_y, label, name_style; max_x = right(inner))
                if is_active
                    set_string!(buf, cx + length(label) + 1, row_y, "  active", tstyle(:accent, bold = true); max_x = right(inner))
                end
            end
        else
            cx = x + length(marker)
            set_string!(buf, cx, row_y, entry.name, name_style; max_x = right(inner))
            cx += length(entry.name)
            dim_str = "  $(entry.dims)d"
            set_string!(buf, cx, row_y, dim_str, tstyle(:text_dim); max_x = right(inner))
            cx += length(dim_str)
            installed_indicator = entry.installed ? " ●" : " ○"
            installed_style = entry.installed ? tstyle(:success) : tstyle(:text_dim)
            set_string!(buf, cx, row_y, installed_indicator, installed_style; max_x = right(inner))
            cx += length(installed_indicator)
            if is_active
                set_string!(buf, cx, row_y, "  active", tstyle(:accent, bold = true); max_x = right(inner))
            end
        end
    end

    # ── Section 4: Collection info ──
    col_y = regions[4].y
    if has_col_info
        col_name = if !isempty(m.search_collections)
            sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
            m.search_collections[sel]
        else
            "—"
        end
        set_string!(buf, x, col_y, "Collection: ", tstyle(:text))
        set_string!(buf, x + 12, col_y, col_name, tstyle(:accent))

        vectors_count = get(col_info, "vectors_count", get(col_info, "points_count", "?"))
        indexed_count = get(col_info, "indexed_vectors_count", vectors_count)
        config = get(col_info, "config", Dict())
        params = get(config, "params", Dict())
        vectors_cfg = get(params, "vectors", Dict())
        dims = get(vectors_cfg, "size", "?")
        distance = get(vectors_cfg, "distance", "?")
        status = get(col_info, "status", "?")

        _write_spans!(buf, x, col_y + 1, [
            ("  Vectors: ", tstyle(:text)), ("$vectors_count", tstyle(:accent)),
            ("   Indexed: ", tstyle(:text)), ("$indexed_count", tstyle(:accent)),
        ])
        _write_spans!(buf, x, col_y + 2, [
            ("  Dimensions: ", tstyle(:text)), ("$dims", tstyle(:accent)),
            ("   Distance: ", tstyle(:text)), ("$distance", tstyle(:accent)),
        ])
        status_style = status == "green" ? tstyle(:success) : tstyle(:warning)
        _write_spans!(buf, x, col_y + 3, [("  Status: ", tstyle(:text)), ("$status", status_style)])
    else
        col_label = isempty(m.search_collections) ? "none" : "loading..."
        _write_spans!(buf, x, col_y, [("Collection: ", tstyle(:text)), (col_label, tstyle(:text_dim))])
    end

    # ── Section 6: Results count ──
    _write_spans!(buf, x, regions[6].y, [
        ("Results per search: ", tstyle(:text)),
        ("$(m.search_result_count)", tstyle(:accent)),
    ])

    # ── Section 8: Key hints ──
    hint_y = regions[8].y
    _write_spans!(buf, x, hint_y, [
        ("↑↓", tstyle(:accent)), (" navigate  ", tstyle(:text_dim)),
        ("Enter", tstyle(:accent)), (" select", tstyle(:text_dim)),
    ])
    _write_spans!(buf, x, hint_y + 1, [
        ("+/-", tstyle(:accent)), (" results  ", tstyle(:text_dim)),
        ("Esc", tstyle(:accent)), (" close", tstyle(:text_dim)),
    ])

    # ── Section 9: Reindex confirmation ──
    if m.search_config_confirm && confirm_h > 0
        confirm_y = regions[9].y + 1
        paths = m.search_config_reindex_paths
        n = length(paths)
        if n > 0
            names = join([p.second for p in paths], ", ")
            label = n == 1 ? "Reindex '$names'?" : "Reindex $n collections ($names)?"
            max_w = inner.width - 8
            if length(label) > max_w
                label = first(label, max_w - 1) * "…"
            end
            _write_spans!(buf, x, confirm_y, [
                (label * " ", tstyle(:warning, bold = true)),
                ("(y/n)", tstyle(:accent)),
            ])
        end
    end
end

"""Render the collection detail overlay panel."""
function _view_collection_detail(m::KaimonModel, area::Rect, buf::Buffer)
    _dim_area!(buf, area)

    col_name = if !isempty(m.search_collections)
        sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
        m.search_collections[sel]
    else
        return
    end

    h = min(18, area.height - 2)
    w = min(round(Int, area.width * 0.8), area.width - 4)
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    title = "Collection: $col_name"
    if length(title) > w - 2
        title = first(col_name, w - 6) * "…"
    end
    inner = if animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, m.tick; box = BOX_HEAVY, intensity = 0.12)
        if rect.width > length(title) + 4
            set_string!(buf, rect.x + 2, rect.y, title, tstyle(:accent, bold = true))
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = title,
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
            set_char!(buf, col, row, ' ', Style(bg = Tachikoma.theme().bg))
        end
    end

    # Layout: project(1) + qdrant info(Fill) + blank(1) + index state(Fill) + blank(1) + hint(1)
    info = m.search_detail_info
    has_info = !isempty(info) && !haskey(info, "error")
    qdrant_h = has_info ? 3 : 1

    idx = m.search_detail_index_state
    idx_cfg = get(idx, "config", Dict())
    idx_dirs = get(idx_cfg, "dirs", String[])
    idx_exts = get(idx_cfg, "extensions", String[])
    idx_files = get(idx, "files", Dict())
    # dirs header + dir lines + extensions + files tracked
    idx_h = if !isempty(idx)
        1 + length(idx_dirs) + (!isempty(idx_exts) ? 1 : 0) + 1
    else
        1
    end

    regions = split_layout(
        Layout(Vertical, [
            Fixed(1),        # project path
            Fixed(qdrant_h), # qdrant info
            Fixed(1),        # blank
            Fixed(idx_h),    # index state
            Fixed(1),        # blank
            Fixed(1),        # close hint
        ]),
        inner,
    )

    x = inner.x + 1
    max_w = inner.width - 2

    # ── Project path ──
    proj = isempty(m.search_detail_project_path) ? "unknown" : m.search_detail_project_path
    if length(proj) > max_w - 9
        proj = "…" * last(proj, max_w - 10)
    end
    _write_spans!(buf, x, regions[1].y, [("Project: ", tstyle(:text)), (proj, tstyle(:accent))])

    # ── Qdrant info ──
    qy = regions[2].y
    if has_info
        vectors_count = get(info, "vectors_count", get(info, "points_count", "?"))
        indexed_count = get(info, "indexed_vectors_count", vectors_count)
        config = get(info, "config", Dict())
        params = get(config, "params", Dict())
        vectors_cfg = get(params, "vectors", Dict())
        dims = get(vectors_cfg, "size", "?")
        distance = get(vectors_cfg, "distance", "?")
        status = get(info, "status", "?")

        _write_spans!(buf, x, qy, [
            ("Vectors: ", tstyle(:text)), ("$vectors_count", tstyle(:accent)),
            ("  Indexed: ", tstyle(:text)), ("$indexed_count", tstyle(:accent)),
        ])
        _write_spans!(buf, x, qy + 1, [
            ("Dimensions: ", tstyle(:text)), ("$dims", tstyle(:accent)),
            ("  Distance: ", tstyle(:text)), ("$distance", tstyle(:accent)),
        ])
        status_style = status == "green" ? tstyle(:success) : tstyle(:warning)
        _write_spans!(buf, x, qy + 2, [("Status: ", tstyle(:text)), ("$status", status_style)])
    else
        _write_spans!(buf, x, qy, [("Qdrant info: ", tstyle(:text)), ("loading...", tstyle(:text_dim))])
    end

    # ── Index state ──
    iy = regions[4].y
    if !isempty(idx)
        if !isempty(idx_dirs)
            set_string!(buf, x, iy, "Indexed dirs:", tstyle(:text, bold = true))
            iy += 1
            for dir in idx_dirs
                iy > bottom(regions[4]) && break
                display_dir = dir
                if length(display_dir) > max_w - 2
                    display_dir = "…" * last(display_dir, max_w - 3)
                end
                set_string!(buf, x + 1, iy, display_dir, tstyle(:text_dim))
                iy += 1
            end
        end
        if !isempty(idx_exts) && iy <= bottom(regions[4])
            _write_spans!(buf, x, iy, [
                ("Extensions: ", tstyle(:text)),
                (join(idx_exts, " "), tstyle(:accent)),
            ])
            iy += 1
        end
        if iy <= bottom(regions[4])
            _write_spans!(buf, x, iy, [
                ("Files tracked: ", tstyle(:text)),
                ("$(length(idx_files))", tstyle(:accent)),
            ])
        end
    elseif isempty(m.search_detail_project_path)
        set_string!(buf, x, iy, "No index state (project unknown)", tstyle(:text_dim))
    else
        set_string!(buf, x, iy, "Index state: loading...", tstyle(:text_dim))
    end

    # ── Close hint ──
    _write_spans!(buf, x, regions[6].y, [("Press any key to close", tstyle(:text_dim))])
end

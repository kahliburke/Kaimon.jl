"""Render the search config overlay panel."""
function _view_search_config(m::KaimonModel, area::Rect, buf::Buffer)
    _dim_area!(buf, area)

    n_models = length(m.search_config_models)
    # Layout: 2 border + 1 header + n_models + 1 blank + 4 col_info + 1 blank + 1 results + 1 blank + 2 hint + 1 confirm
    h = min(n_models + 15, area.height - 2)
    w = min(52, area.width - 4)
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = if animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, m.tick; box = BOX_HEAVY, intensity = 0.12)
        title = " Search Config "
        if rect.width > length(title) + 4
            set_string!(buf, rect.x + 2, rect.y, title, tstyle(:accent, bold = true))
        end
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = " Search Config ",
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

    # Section: Embedding Model
    set_string!(buf, x, y, "Embedding Model", tstyle(:text, bold = true))
    y += 1

    for (i, entry) in enumerate(m.search_config_models)
        y > max_y - 6 && break
        is_selected = i == m.search_config_selected
        is_active = entry.name == m.search_embedding_model

        marker = is_selected ? "▸ " : "  "
        name_style = is_selected ? tstyle(:accent, bold = true) : tstyle(:text)
        dim_str = "  $(entry.dims)d"
        installed_indicator = entry.installed ? " ●" : " ○"
        installed_style = entry.installed ? tstyle(:success) : tstyle(:text_dim)
        active_str = is_active ? "  active" : ""
        active_style = tstyle(:accent, bold = true)

        set_string!(buf, x, y, marker, name_style)
        cx = x + length(marker)
        set_string!(buf, cx, y, entry.name, name_style)
        cx += length(entry.name)
        set_string!(buf, cx, y, dim_str, tstyle(:text_dim))
        cx += length(dim_str)
        set_string!(buf, cx, y, installed_indicator, installed_style)
        cx += length(installed_indicator)
        if is_active
            set_string!(buf, cx, y, active_str, active_style)
        end
        y += 1
    end
    y += 1

    # Section: Collection info
    col_info = m.search_config_col_info
    if !isempty(col_info) && !haskey(col_info, "error")
        col_name = if !isempty(m.search_collections)
            sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
            m.search_collections[sel]
        else
            "—"
        end
        y <= max_y && (set_string!(buf, x, y, "Collection: ", tstyle(:text));
        set_string!(buf, x + 12, y, col_name, tstyle(:accent));
        y += 1)

        # Extract vectors_count and config from Qdrant response
        vectors_count = get(col_info, "vectors_count", get(col_info, "points_count", "?"))
        indexed_count = get(col_info, "indexed_vectors_count", vectors_count)
        config = get(col_info, "config", Dict())
        params = get(config, "params", Dict())
        vectors_cfg = get(params, "vectors", Dict())
        dims = get(vectors_cfg, "size", "?")
        distance = get(vectors_cfg, "distance", "?")
        status = get(col_info, "status", "?")

        if y <= max_y
            _write_spans!(
                buf,
                x,
                y,
                [
                    ("  Vectors: ", tstyle(:text)),
                    ("$vectors_count", tstyle(:accent)),
                    ("   Indexed: ", tstyle(:text)),
                    ("$indexed_count", tstyle(:accent)),
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
                    ("  Dimensions: ", tstyle(:text)),
                    ("$dims", tstyle(:accent)),
                    ("   Distance: ", tstyle(:text)),
                    ("$distance", tstyle(:accent)),
                ],
            )
            y += 1
        end
        if y <= max_y
            status_style = status == "green" ? tstyle(:success) : tstyle(:warning)
            _write_spans!(
                buf,
                x,
                y,
                [("  Status: ", tstyle(:text)), ("$status", status_style)],
            )
            y += 1
        end
    else
        col_label = isempty(m.search_collections) ? "none" : "loading..."
        _write_spans!(
            buf,
            x,
            y,
            [("Collection: ", tstyle(:text)), (col_label, tstyle(:text_dim))],
        )
        y += 1
    end
    y += 1

    # Results count
    if y <= max_y
        _write_spans!(
            buf,
            x,
            y,
            [
                ("Results per search: ", tstyle(:text)),
                ("$(m.search_result_count)", tstyle(:accent)),
            ],
        )
        y += 1
    end
    y += 1

    # Keybinding hints
    if y <= max_y
        _write_spans!(
            buf,
            x,
            y,
            [
                ("↑↓", tstyle(:accent)),
                (" navigate  ", tstyle(:text_dim)),
                ("Enter", tstyle(:accent)),
                (" select  ", tstyle(:text_dim)),
                ("p", tstyle(:accent)),
                (" pull", tstyle(:text_dim)),
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
                ("+/-", tstyle(:accent)),
                (" results  ", tstyle(:text_dim)),
                ("Esc", tstyle(:accent)),
                (" close", tstyle(:text_dim)),
            ],
        )
        y += 1
    end

    # Reindex confirmation
    if m.search_config_confirm && y <= max_y
        y += 1
        paths = m.search_config_reindex_paths
        n = length(paths)
        if n > 0 && y <= max_y
            names = join([p.second for p in paths], ", ")
            label = n == 1 ? "Reindex '$names'?" : "Reindex $n collections ($names)?"
            # Truncate if too wide
            max_w = inner.width - 8
            if length(label) > max_w
                label = first(label, max_w - 1) * "…"
            end
            _write_spans!(
                buf,
                x,
                y,
                [(label * " ", tstyle(:warning, bold = true)), ("(y/n)", tstyle(:accent))],
            )
        end
    end
end

"""Render the collection detail overlay panel."""
function _view_collection_detail(m::KaimonModel, area::Rect, buf::Buffer)
    _dim_area!(buf, area)

    # Determine collection name
    col_name = if !isempty(m.search_collections)
        sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
        m.search_collections[sel]
    else
        return
    end

    h = min(18, area.height - 2)
    w = min(60, area.width - 4)
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    title = " Collection: $col_name "
    if length(title) > w - 2
        title = " " * first(col_name, w - 6) * "… "
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
            set_char!(buf, col, row, ' ', Style())
        end
    end

    y = inner.y
    x = inner.x + 1
    max_y = bottom(inner)
    max_w = inner.width - 2

    # Project path
    proj = isempty(m.search_detail_project_path) ? "unknown" : m.search_detail_project_path
    if length(proj) > max_w - 9
        proj = "…" * last(proj, max_w - 10)
    end
    y <= max_y && (
        _write_spans!(buf, x, y, [("Project: ", tstyle(:text)), (proj, tstyle(:accent))]); y += 1
    )

    # Qdrant info
    info = m.search_detail_info
    if !isempty(info) && !haskey(info, "error")
        vectors_count = get(info, "vectors_count", get(info, "points_count", "?"))
        indexed_count = get(info, "indexed_vectors_count", vectors_count)
        config = get(info, "config", Dict())
        params = get(config, "params", Dict())
        vectors_cfg = get(params, "vectors", Dict())
        dims = get(vectors_cfg, "size", "?")
        distance = get(vectors_cfg, "distance", "?")
        status = get(info, "status", "?")

        y <= max_y && (
            _write_spans!(
                buf,
                x,
                y,
                [
                    ("Vectors: ", tstyle(:text)),
                    ("$vectors_count", tstyle(:accent)),
                    ("  Indexed: ", tstyle(:text)),
                    ("$indexed_count", tstyle(:accent)),
                ],
            );
            y += 1
        )
        y <= max_y && (
            _write_spans!(
                buf,
                x,
                y,
                [
                    ("Dimensions: ", tstyle(:text)),
                    ("$dims", tstyle(:accent)),
                    ("  Distance: ", tstyle(:text)),
                    ("$distance", tstyle(:accent)),
                ],
            );
            y += 1
        )
        status_style = status == "green" ? tstyle(:success) : tstyle(:warning)
        y <= max_y && (
            _write_spans!(
                buf,
                x,
                y,
                [("Status: ", tstyle(:text)), ("$status", status_style)],
            );
            y += 1
        )
    else
        y <= max_y && (
            _write_spans!(
                buf,
                x,
                y,
                [("Qdrant info: ", tstyle(:text)), ("loading...", tstyle(:text_dim))],
            );
            y += 1
        )
    end

    y += 1

    # Index state info
    idx = m.search_detail_index_state
    if !isempty(idx)
        cfg = get(idx, "config", Dict())
        dirs = get(cfg, "dirs", String[])
        extensions = get(cfg, "extensions", String[])
        files = get(idx, "files", Dict())

        if !isempty(dirs)
            y <= max_y &&
                (set_string!(buf, x, y, "Indexed dirs:", tstyle(:text, bold = true));
                y += 1)
            for dir in dirs
                y > max_y && break
                display_dir = dir
                if length(display_dir) > max_w - 2
                    display_dir = "…" * last(display_dir, max_w - 3)
                end
                set_string!(buf, x + 1, y, display_dir, tstyle(:text_dim))
                y += 1
            end
        end

        if !isempty(extensions)
            y <= max_y && (
                _write_spans!(
                    buf,
                    x,
                    y,
                    [
                        ("Extensions: ", tstyle(:text)),
                        (join(extensions, " "), tstyle(:accent)),
                    ],
                );
                y += 1
            )
        end

        y <= max_y && (
            _write_spans!(
                buf,
                x,
                y,
                [("Files tracked: ", tstyle(:text)), ("$(length(files))", tstyle(:accent))],
            );
            y += 1
        )
    elseif isempty(m.search_detail_project_path)
        y <= max_y && (
            set_string!(buf, x, y, "No index state (project unknown)", tstyle(:text_dim)); y += 1
        )
    else
        y <= max_y &&
            (set_string!(buf, x, y, "Index state: loading...", tstyle(:text_dim)); y += 1)
    end

    # Close hint
    y += 1
    y <= max_y &&
        (_write_spans!(buf, x, y, [("Press any key to close", tstyle(:text_dim))]))
end

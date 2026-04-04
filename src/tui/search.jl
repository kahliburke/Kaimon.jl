# ═══════════════════════════════════════════════════════════════════════════════
# Search tab (tab 4)
# ═══════════════════════════════════════════════════════════════════════════════

"""Render the Search tab: status + query + results panes."""
function view_search(m::KaimonModel, area::Rect, buf::Buffer)
    rows = split_layout(m.search_layout, area)
    length(rows) >= 3 || return

    _view_search_status(m, rows[1], buf)
    _view_search_query(m, rows[2], buf)
    _view_search_results(m, rows[3], buf)

    if m.search_collection_picker_open
        _view_collection_picker(m, area, buf)
    end
    if m.search_config_open
        _view_search_config(m, area, buf)
    end
    if m.search_detail_open
        try
            _view_collection_detail(m, area, buf)
        catch e
            m.search_detail_open = false
            _push_log!(:warn, "Detail view error: $(sprint(showerror, e))")
        end
    end
    if m.search_manage_open
        try
            _view_search_manage(m, area, buf)
        catch e
            m.search_manage_open = false
            _push_log!(:warn, "Collection Manager view error: $(sprint(showerror, e))")
        end
    end
end

"""Pane 1: Health status, collection selector, filter."""
function _view_search_status(m::KaimonModel, area::Rect, buf::Buffer)
    blk = Block(
        title = "Semantic Search",
        border_style = _pane_border(m, TAB_SEARCH, 1),
        title_style = _pane_title(m, TAB_SEARCH, 1),
    )
    inner = render(blk, area, buf)
    inner.height < 1 && return

    sep = " · "
    dim = tstyle(:text_dim)
    txt = tstyle(:text)
    y = inner.y
    x = inner.x

    # ── Row 1: Service health (condensed when both up) ──
    qdrant_up = m.search_qdrant_up
    ollama_ok = m.search_ollama_up && m.search_model_available
    if qdrant_up && ollama_ok
        _write_spans!(buf, x, y, [
            ("● ", tstyle(:success)), ("Qdrant", txt),
            (sep, dim),
            ("● ", tstyle(:success)), ("Ollama", txt),
            (" ", dim), (m.search_embedding_model, tstyle(:accent)),
        ])
        y += 1
    else
        if qdrant_up
            _write_spans!(buf, x, y, [("● ", tstyle(:success)), ("Qdrant", txt)])
        else
            _write_spans!(buf, x, y, [
                ("○ ", tstyle(:error)), ("Qdrant  ", txt),
                ("docker run -d -p 6333:6333 qdrant/qdrant", dim),
            ])
        end
        y += 1
        if ollama_ok
            _write_spans!(buf, x, y, [
                ("● ", tstyle(:success)), ("Ollama  ", txt),
                (m.search_embedding_model, tstyle(:accent)),
            ])
        elseif m.search_ollama_up
            _write_spans!(buf, x, y, [
                ("◐ ", tstyle(:warning)), ("Ollama  ", txt),
                ("model missing  ", txt),
                ("[p]", tstyle(:warning)),
                (" pull $(m.search_embedding_model)", dim),
            ])
        else
            _write_spans!(buf, x, y, [
                ("○ ", tstyle(:error)), ("Ollama  ", txt),
                ("https://ollama.com/download", dim),
            ])
        end
        y += 1
    end

    # ── Row 2: Collection selector (◀ ▶ arrows) + Filter ──
    if !isempty(m.search_collections)
        sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
        col_name = m.search_collections[sel]
        n_cols = length(m.search_collections)
        has_left = sel > 1
        has_right = sel < n_cols
        _write_spans!(buf, x, y, [
            (has_left ? "◀ " : "  ", has_left ? tstyle(:accent) : dim),
            (col_name, tstyle(:accent, bold=true)),
            (has_right ? " ▶" : "  ", has_right ? tstyle(:accent) : dim),
            (" $(sel)/$(n_cols)", tstyle(:border)),
            (sep, dim),
            ("Filter: ", txt),
            (_search_filter_label(m), tstyle(:accent)),
        ])
    else
        if qdrant_up
            _write_spans!(buf, x, y, [
                ("no collections — ", tstyle(:border)),
                ("[i]", tstyle(:warning)),
                (" index current project", dim),
            ])
        else
            _write_spans!(buf, x, y, [("no collections", tstyle(:border))])
        end
    end
    y += 1

    # ── Optional: warnings / status ──
    if m.search_dimension_mismatch
        _write_spans!(buf, x, y, [
            ("⚠ ", tstyle(:warning)),
            ("Model mismatch — ", tstyle(:warning)),
            ("[o]", tstyle(:accent)),
            (" to reindex", dim),
        ])
        y += 1
    end
    _status = _get_search_status()
    if !isempty(_status)
        _style = contains(_status, "Cannot") || contains(_status, "failed") ||
                 contains(_status, "Failed") || contains(_status, "No ") ?
                 tstyle(:warning) : tstyle(:accent)
        _write_spans!(buf, x, y, [("▸ ", _style), (_status, _style)])
        y += 1
    end

    # ── Hint bar (bottom of inner area) ──
    hint_y = inner.y + inner.height - 1
    if hint_y > y - 1
        _write_spans!(buf, x, hint_y, [
            ("[/]", tstyle(:accent)), (" search  ", dim),
            ("[c]", tstyle(:accent)), (" collection  ", dim),
            ("[m]", tstyle(:accent)), (" manage  ", dim),
            ("[o]", tstyle(:accent)), (" options  ", dim),
            ("[r]", tstyle(:accent)), (" refresh", dim),
        ])
    end
end

_search_filter_label(m) = m.search_chunk_type == "all" ? "all" :
    m.search_chunk_type == "definitions" ? "definitions" : "windows"

"""Pane 2: Query input."""
function _view_search_query(m::KaimonModel, area::Rect, buf::Buffer)
    blk = Block(
        title = "Query",
        border_style = _pane_border(m, TAB_SEARCH, 2),
        title_style = _pane_title(m, TAB_SEARCH, 2),
    )
    inner = render(blk, area, buf)
    inner.height < 1 && return

    if m.search_query_editing && m.search_query_input !== nothing
        m.search_query_input.tick = m.tick
        render(m.search_query_input, inner, buf)
    else
        text = m.search_query_input !== nothing ? Tachikoma.text(m.search_query_input) : ""
        if isempty(text)
            set_string!(
                buf,
                inner.x,
                inner.y,
                "Press / or Enter to search...",
                tstyle(:border),
            )
        else
            _write_spans!(
                buf,
                inner.x,
                inner.y,
                [("Query: ", tstyle(:text)), (text, tstyle(:accent))],
            )
        end
    end
end

"""Pane 3: Search results displayed in a ScrollPane."""
function _view_search_results(m::KaimonModel, area::Rect, buf::Buffer)
    n_results = length(m.search_results)

    # Ensure scroll pane exists
    if m.search_results_pane === nothing
        m.search_results_pane = ScrollPane(
            Vector{Span}[];
            following = false,
            reverse = false,
            block = nothing,
            show_scrollbar = true,
        )
        # Populate from current results
        _sync_search_results_pane!(m)
    end

    pane = m.search_results_pane::ScrollPane
    pane.block = Block(
        title = "Results ($(n_results))",
        border_style = _pane_border(m, TAB_SEARCH, 3),
        title_style = _pane_title(m, TAB_SEARCH, 3),
    )
    render(pane, area, buf)
end

"""Score → RGB color: red (low) → orange → yellow → green (high)."""
function _score_color(score::Float64)
    s = clamp(score, 0.0, 1.0)
    if s < 0.5
        # red → orange
        t = s / 0.5
        ColorRGB(UInt8(0xff), UInt8(round(Int, t * 0xa5)), UInt8(0x00))
    elseif s < 0.8
        # orange → yellow
        t = (s - 0.5) / 0.3
        ColorRGB(UInt8(0xff), UInt8(round(Int, 0xa5 + t * 0x5a)), UInt8(0x00))
    else
        # yellow → green
        t = (s - 0.8) / 0.2
        ColorRGB(
            UInt8(round(Int, 0xff * (1 - t * 0.5))),
            UInt8(0xdd),
            UInt8(round(Int, t * 0x40)),
        )
    end
end

"""Rebuild the search results scroll pane content from m.search_results."""
function _sync_search_results_pane!(m::KaimonModel)
    pane = m.search_results_pane
    pane === nothing && return

    if isempty(m.search_results)
        set_content!(pane, [[Span("  No results. Press / to search.", tstyle(:border))]])
        return
    end

    lines = Vector{Span}[]

    for (i, result) in enumerate(m.search_results)
        score = get(result, "score", 0.0)
        payload = get(result, "payload", Dict())

        abs_file = get(payload, "file", "")
        name = get(payload, "name", "")
        start_line = get(payload, "start_line", 0)
        end_line = get(payload, "end_line", 0)
        chunk_type = get(payload, "type", "")
        text = get(payload, "text", "")
        signature = get(payload, "signature", "")

        # Relative path for display, absolute for vscode:// link
        file = abs_file
        if !isempty(file) && startswith(file, pwd())
            file = relpath(file, pwd())
        end

        sc = _score_color(score)

        # ── Score gauge + index ──
        bar_width = 10
        filled = round(Int, clamp(score, 0, 1) * bar_width)
        bar = "█"^filled * "░"^(bar_width - filled)
        push!(
            lines,
            [
                Span(" $i ", Style(fg = ColorRGB(0x1a, 0x1a, 0x2e), bg = sc)),
                Span(" ", tstyle(:text)),
                Span(bar, Style(fg = sc)),
                Span(" $(round(score, digits=2))", tstyle(:text_dim)),
            ],
        )

        # ── Name / signature ──
        label = !isempty(signature) ? signature : name
        if !isempty(label)
            icon = chunk_type == "function" ? "ƒ " : chunk_type == "struct" ? "◆ " : "≡ "
            push!(
                lines,
                [
                    Span("   ", tstyle(:text)),
                    Span(icon, tstyle(:accent)),
                    Span(label, tstyle(:primary, bold = true)),
                ],
            )
        end

        # ── Location (clickable via OSC 8 → vscode://file/) ──
        loc = file
        if start_line > 0
            loc *= ":$start_line"
            start_line != end_line && (loc *= "-$end_line")
        end
        tag_label, tag_style = if chunk_type in ("function", "definitions")
            "def", :success
        elseif chunk_type == "struct"
            "type", :warning
        else
            "win", :border
        end
        loc_style = file_link_style(abs_file; line=start_line)
        push!(
            lines,
            [
                Span("   ", tstyle(:text)),
                Span("$tag_label ", tstyle(tag_style)),
                Span(loc, loc_style),
            ],
        )

        # ── Code preview (syntax highlighted via markdown renderer) ──
        preview = strip(string(text))
        if length(preview) > 20
            # Truncate to ~4 lines for preview
            code_lines = split(preview, '\n')
            shown = join(code_lines[1:min(4, length(code_lines))], '\n')
            md_snippet = "```julia\n$shown\n```"
            if markdown_extension_loaded()
                md_lines = Base.invokelatest(markdown_to_spans, md_snippet, 76)
                for ml in md_lines
                    line_spans = Span[Span("   │ ", tstyle(:border))]
                    for sp in ml
                        # Strip code block background — results have their own visual structure
                        s = sp.style
                        if s.bg isa Tachikoma.NoColor
                            push!(line_spans, sp)
                        else
                            push!(line_spans, Span(sp.content, Style(fg=s.fg, bold=s.bold, dim=s.dim, italic=s.italic, underline=s.underline)))
                        end
                    end
                    push!(lines, line_spans)
                end
            else
                for (j, cl) in enumerate(code_lines)
                    j > 4 && break
                    cl = rstrip(string(cl))
                    isempty(cl) && continue
                    length(cl) > 76 && (cl = first(cl, 76) * "…")
                    push!(lines, [Span("   │ ", tstyle(:border)), Span(cl, tstyle(:text))])
                end
            end
            if length(code_lines) > 4
                remaining = length(code_lines) - 4
                push!(
                    lines,
                    [
                        Span("   │ ", tstyle(:border)),
                        Span("… $remaining more lines", tstyle(:text_dim)),
                    ],
                )
            end
        end

        # ── Separator ──
        if i < length(m.search_results)
            push!(lines, [Span("   ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄", tstyle(:border))])
        end
    end

    set_content!(pane, lines)
end

"""Handle query text input while editing."""
function _handle_search_query_edit!(m::KaimonModel, evt::KeyEvent)
    @match evt.key begin
        :enter => begin
            m.search_query_editing = false
            _execute_search!(m)
        end
        :escape => begin
            m.search_query_editing = false
        end
        _ => begin
            m.search_query_input !== nothing && handle_key!(m.search_query_input, evt)
        end
    end
end

# ── Collection picker popup ──────────────────────────────────────────────────

"""Render a centered popup listing all collections for quick selection."""
function _view_collection_picker(m::KaimonModel, area::Rect, buf::Buffer)
    cols = m.search_collections
    isempty(cols) && (m.search_collection_picker_open = false; return)

    n = length(cols)
    sel = clamp(m.search_selected_collection, 1, n)
    modal_w = min(area.width - 6, max(48, maximum(length, cols) + 8))
    modal_h = min(area.height - 4, n + 3)  # +2 borders +1 hint row
    pos = center(area, modal_w, modal_h)

    # Clear background behind popup (explicit bg to override existing cells)
    bg = Style(fg=tstyle(:text).fg, bg=Tachikoma.theme().bg)
    for ry in pos.y:pos.y+pos.height-1
        for rx in pos.x:pos.x+pos.width-1
            set_char!(buf, rx, ry, ' ', bg)
        end
    end

    title = m.search_collection_delete_confirm ?
        "Delete '$(cols[sel])'? [y]es [n]o" :
        "Select Collection"
    title_style = m.search_collection_delete_confirm ?
        tstyle(:error, bold=true) : tstyle(:accent, bold=true)
    border_style = m.search_collection_delete_confirm ?
        tstyle(:error) : tstyle(:accent)

    blk = Block(
        title = title,
        border_style = border_style,
        title_style = title_style,
    )
    inner = render(blk, pos, buf)
    inner.height < 1 && return

    # Reserve bottom row for hints
    list_h = inner.height - 1
    list_h < 1 && return

    # Scroll offset to keep selection visible
    offset = max(0, sel - list_h)
    for vi in 1:list_h
        idx = offset + vi
        idx > n && break
        ry = inner.y + vi - 1
        is_sel = idx == sel
        style = if is_sel && m.search_collection_delete_confirm
            tstyle(:error, bold=true)
        elseif is_sel
            tstyle(:accent, bold=true)
        else
            tstyle(:text)
        end
        marker = is_sel ? (m.search_collection_delete_confirm ? '✗' : '▸') : ' '
        set_char!(buf, inner.x, ry, marker, style)
        set_string!(buf, inner.x + 2, ry, cols[idx], style; max_x=right(inner))
    end

    # Hint bar at bottom of inner area
    hint_y = inner.y + inner.height - 1
    dim = tstyle(:text_dim)
    if m.search_collection_delete_confirm
        _write_spans!(buf, inner.x, hint_y, [
            ("Press ", dim), ("y", tstyle(:error, bold=true)),
            (" to delete, ", dim), ("n", tstyle(:accent, bold=true)),
            (" to cancel", dim),
        ])
    else
        _write_spans!(buf, inner.x, hint_y, [
            ("[d]", tstyle(:error)), (" delete  ", dim),
            ("[Enter]", tstyle(:accent)), (" select  ", dim),
            ("[Esc]", tstyle(:accent)), (" close", dim),
        ])
    end
end

"""Handle key events when the collection picker popup is open."""
function _handle_collection_picker_key!(m::KaimonModel, evt::KeyEvent)
    n = length(m.search_collections)
    n == 0 && (m.search_collection_picker_open = false; return)
    sel = clamp(m.search_selected_collection, 1, n)

    # Delete confirmation sub-mode
    if m.search_collection_delete_confirm
        if evt.char == 'y' || evt.char == 'Y'
            m.search_collection_delete_confirm = false
            _delete_search_collection!(m)
            isempty(m.search_collections) && (m.search_collection_picker_open = false)
        else
            m.search_collection_delete_confirm = false
        end
        return
    end

    @match evt.key begin
        :up => (m.search_selected_collection = sel > 1 ? sel - 1 : n)
        :down => (m.search_selected_collection = sel < n ? sel + 1 : 1)
        :home => (m.search_selected_collection = 1)
        :end_key => (m.search_selected_collection = n)
        :pageup => (m.search_selected_collection = max(1, sel - 10))
        :pagedown => (m.search_selected_collection = min(n, sel + 10))
        :enter => (m.search_collection_picker_open = false)
        :escape => (m.search_collection_picker_open = false)
        _ => begin
            if evt.char == 'd' || evt.char == 'D'
                m.search_collection_delete_confirm = true
            end
        end
    end
end

# ── Search status feedback (module-level Ref, Revise-safe) ──
const _SEARCH_STATUS = Ref(("", 0.0))
_set_search_status!(msg::String) = (_SEARCH_STATUS[] = (msg, time()); nothing)
function _get_search_status()
    msg, t = _SEARCH_STATUS[]
    isempty(msg) && return ""
    time() - t > 10.0 && return ""  # auto-clear after 10 seconds
    msg
end


# ═══════════════════════════════════════════════════════════════════════════════
# Search tab (tab 7)
# ═══════════════════════════════════════════════════════════════════════════════

"""Render the Search tab: status + query + results panes."""
function view_search(m::KaimonModel, area::Rect, buf::Buffer)
    rows = split_layout(m.search_layout, area)
    length(rows) >= 3 || return

    _view_search_status(m, rows[1], buf)
    _view_search_query(m, rows[2], buf)
    _view_search_results(m, rows[3], buf)

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

"""Write a sequence of (text, style) pairs at (x, y), advancing x after each."""
function _write_spans!(buf::Buffer, x::Int, y::Int, parts)
    cx = x
    for (text, style) in parts
        set_string!(buf, cx, y, text, style)
        cx += length(text)
    end
end

"""Pane 1: Health status, collection selector, filter."""
function _view_search_status(m::KaimonModel, area::Rect, buf::Buffer)
    blk = Block(
        title = " Semantic Search ",
        border_style = _pane_border(m, 7, 1),
        title_style = _pane_title(m, 7, 1),
    )
    inner = render(blk, area, buf)
    inner.height < 1 && return

    y = inner.y
    x = inner.x

    # Qdrant status + setup hint
    if m.search_qdrant_up
        _write_spans!(buf, x, y, [("● ", tstyle(:success)), ("Qdrant", tstyle(:text))])
    else
        _write_spans!(
            buf,
            x,
            y,
            [
                ("○ ", tstyle(:error)),
                ("Qdrant  ", tstyle(:text)),
                ("docker run -d -p 6333:6333 qdrant/qdrant", tstyle(:text_dim)),
            ],
        )
    end
    y += 1

    # Ollama status + setup hints
    if m.search_ollama_up && m.search_model_available
        _write_spans!(
            buf,
            x,
            y,
            [
                ("● ", tstyle(:success)),
                ("Ollama  ", tstyle(:text)),
                (m.search_embedding_model, tstyle(:accent)),
            ],
        )
    elseif m.search_ollama_up
        _write_spans!(
            buf,
            x,
            y,
            [
                ("◐ ", tstyle(:warning)),
                ("Ollama  ", tstyle(:text)),
                ("model missing  ", tstyle(:text)),
                ("[p]", tstyle(:warning)),
                (" pull $(m.search_embedding_model)", tstyle(:text_dim)),
            ],
        )
    else
        _write_spans!(
            buf,
            x,
            y,
            [
                ("○ ", tstyle(:error)),
                ("Ollama  ", tstyle(:text)),
                ("https://ollama.com/download", tstyle(:text_dim)),
            ],
        )
    end
    y += 1

    # Collection selector
    if !isempty(m.search_collections)
        sel = clamp(m.search_selected_collection, 1, length(m.search_collections))
        col_name = m.search_collections[sel]
        _write_spans!(
            buf,
            x,
            y,
            [
                ("Collection: ", tstyle(:text)),
                (col_name, tstyle(:accent)),
                (" ($(sel)/$(length(m.search_collections)))", tstyle(:border)),
            ],
        )
    else
        if m.search_qdrant_up
            _write_spans!(
                buf,
                x,
                y,
                [
                    ("Collection: ", tstyle(:text)),
                    ("none — ", tstyle(:border)),
                    ("[i]", tstyle(:warning)),
                    (" index current project", tstyle(:text_dim)),
                ],
            )
        else
            _write_spans!(
                buf,
                x,
                y,
                [("Collection: ", tstyle(:text)), ("none", tstyle(:border))],
            )
        end
    end
    y += 1

    # Filter display
    filter_label =
        m.search_chunk_type == "all" ? "all" :
        m.search_chunk_type == "definitions" ? "definitions" : "windows"
    _write_spans!(buf, x, y, [("Filter: ", tstyle(:text)), (filter_label, tstyle(:accent))])
    y += 1

    # Dimension mismatch warning
    if m.search_dimension_mismatch
        _write_spans!(
            buf,
            x,
            y,
            [
                ("⚠ ", tstyle(:warning)),
                ("Model mismatch — ", tstyle(:warning)),
                ("[o]", tstyle(:accent)),
                (" to reindex", tstyle(:text_dim)),
            ],
        )
        y += 1
    end

    # Status message (async operation feedback)
    _status = _get_search_status()
    if !isempty(_status)
        _style =
            contains(_status, "Cannot") ||
            contains(_status, "failed") ||
            contains(_status, "Failed") ||
            contains(_status, "No ") ? tstyle(:warning) : tstyle(:accent)
        _write_spans!(buf, x, y, [("▸ ", _style), (_status, _style)])
        y += 1
    end

    # Hint bar
    _write_spans!(
        buf,
        x,
        y,
        [
            ("[/]", tstyle(:accent)),
            (" search  ", tstyle(:text_dim)),
            ("[Enter]", tstyle(:accent)),
            (" details  ", tstyle(:text_dim)),
            ("[m]", tstyle(:accent)),
            (" manage  ", tstyle(:text_dim)),
            ("[o]", tstyle(:accent)),
            (" options  ", tstyle(:text_dim)),
            ("[r]", tstyle(:accent)),
            (" refresh", tstyle(:text_dim)),
        ],
    )
end

"""Pane 2: Query input."""
function _view_search_query(m::KaimonModel, area::Rect, buf::Buffer)
    blk = Block(
        title = " Query ",
        border_style = _pane_border(m, 7, 2),
        title_style = _pane_title(m, 7, 2),
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
        title = " Results ($(n_results)) ",
        border_style = _pane_border(m, 7, 3),
        title_style = _pane_title(m, 7, 3),
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
        # Build vscode:// hyperlink for the file location
        vscode_url = ""
        if !isempty(abs_file)
            vscode_url = "vscode://file/$(abs_file)"
            if start_line > 0
                vscode_url *= ":$(start_line)"
            end
        end
        loc_style = if isempty(vscode_url)
            tstyle(:text_dim, italic = true)
        else
            tstyle(:accent, italic = true, underline = true, hyperlink = vscode_url)
        end
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
                    append!(line_spans, ml)
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

# ── Search status feedback (module-level Ref, Revise-safe) ──
const _SEARCH_STATUS = Ref(("", 0.0))
_set_search_status!(msg::String) = (_SEARCH_STATUS[] = (msg, time()); nothing)
function _get_search_status()
    msg, t = _SEARCH_STATUS[]
    isempty(msg) && return ""
    time() - t > 10.0 && return ""  # auto-clear after 10 seconds
    msg
end


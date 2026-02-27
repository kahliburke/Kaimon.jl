# ── Activity Tab ──────────────────────────────────────────────────────────────

"""Cycle activity filter: All → session1 → session2 → … → All."""
function _cycle_activity_filter!(m::KaimonModel)
    # Collect unique session keys from both in-flight and completed results
    seen_keys = String[]
    for ifc in m.inflight_calls
        if !isempty(ifc.session_key) && ifc.session_key ∉ seen_keys
            push!(seen_keys, ifc.session_key)
        end
    end
    for r in m.tool_results
        if !isempty(r.session_key) && r.session_key ∉ seen_keys
            push!(seen_keys, r.session_key)
        end
    end

    # Also pull session keys from active connections (even if no calls yet)
    mgr = m.conn_mgr
    if mgr !== nothing
        for conn in mgr.connections
            sk = short_key(conn)
            if !isempty(sk) && sk ∉ seen_keys
                push!(seen_keys, sk)
            end
        end
    end
    isempty(seen_keys) && return

    # Build cycle: "" (all) → key1 → key2 → … → "" (all)
    if isempty(m.activity_filter)
        m.activity_filter = seen_keys[1]
    else
        idx = findfirst(==(m.activity_filter), seen_keys)
        if idx === nothing || idx == length(seen_keys)
            m.activity_filter = ""  # back to all
        else
            m.activity_filter = seen_keys[idx+1]
        end
    end
    # Reset selection when filter changes
    m.selected_result = 0
    m.selected_inflight = 0
    m._detail_for_result = -1
end

"""Resolve a session_key to a short display name (e.g. "rEVAlation")."""
function _session_display_name(session_key::String)::String
    isempty(session_key) && return ""
    mgr = GATE_CONN_MGR[]
    mgr === nothing && return session_key
    conn = get_connection_by_key(mgr, session_key)
    conn === nothing && return session_key
    return isempty(conn.display_name) ? conn.name : conn.display_name
end

"""Refresh analytics data from the database (cached for 30s unless forced)."""
function _refresh_analytics!(m::KaimonModel; force::Bool = false)
    db = Database.DB[]
    db === nothing && return
    t = time()
    if !force && (t - m.analytics_last_refresh) < 30.0 && m.analytics_cache !== nothing
        return
    end
    try
        tool_summary = Database.get_tool_summary()
        error_hotspots = Database.get_error_hotspots()
        recent_execs = Database.get_tool_executions(; days = 1)
        m.analytics_cache = (
            tool_summary = tool_summary,
            error_hotspots = error_hotspots,
            recent_execs = recent_execs,
        )
        m.analytics_last_refresh = t
    catch e
        @debug "Analytics refresh failed" exception = (e, catch_backtrace())
    end
end

"""Render analytics dashboard view in the Activity tab."""
function _view_analytics(m::KaimonModel, area::Rect, buf::Buffer)
    _refresh_analytics!(m)

    cache = m.analytics_cache

    title_block = Block(
        title = " Analytics [d]ata [r]efresh ",
        border_style = tstyle(:accent),
        title_style = tstyle(:accent, bold = true),
    )
    inner = render(title_block, area, buf)

    if cache === nothing || Database.DB[] === nothing
        set_string!(
            buf,
            inner.x + 1,
            inner.y,
            "No analytics data yet (database not ready)",
            tstyle(:text_dim),
        )
        return
    end

    ts = cache.tool_summary
    eh = cache.error_hotspots

    # Allocate vertical space: sparkline at bottom (2 rows), error table above it,
    # tool usage table gets whatever remains.
    spark_h = 2
    err_rows = min(length(eh), 5)
    err_h = err_rows + 3   # border top + header + separator + rows + border bot
    err_h = max(err_h, 4)  # at least room for border + "no errors" line
    tool_h = max(inner.height - err_h - spark_h - 1, 4)

    y = inner.y

    # ── Tool Usage DataTable ──────────────────────────────────────────────────
    tool_area = Rect(inner.x, y, inner.width, tool_h)
    if isempty(ts)
        placeholder = Block(title = " Tool Usage Summary ", border_style = tstyle(:accent))
        pi = render(placeholder, tool_area, buf)
        set_string!(buf, pi.x + 1, pi.y, "No tool executions recorded", tstyle(:text_dim))
    else
        names = Any[get(r, "tool_name", "?") for r in ts]
        counts = Any[get(r, "total_executions", 0) for r in ts]
        avgs = Any[get(r, "avg_duration_ms", 0.0) for r in ts]
        errors = Any[get(r, "error_count", 0) for r in ts]
        pcts = Any[
            let t = get(r, "total_executions", 0)
                t > 0 ? 100.0 * get(r, "error_count", 0) / t : 0.0
            end for r in ts
        ]

        dt = DataTable(
            [
                DataColumn("Tool", names),
                DataColumn("Count", counts; align = col_right),
                DataColumn(
                    "Avg ms",
                    avgs;
                    align = col_right,
                    format = v -> @sprintf("%.0f", v),
                ),
                DataColumn("Errors", errors; align = col_right),
                DataColumn(
                    "Err%",
                    pcts;
                    align = col_right,
                    format = v -> @sprintf("%.0f%%", v),
                ),
            ];
            block = Block(title = " Tool Usage Summary ", border_style = tstyle(:accent)),
            show_scrollbar = true,
            selected = 0,
        )
        render(dt, tool_area, buf)
    end
    y += tool_h

    y > bottom(inner) && return

    # ── Error Hotspots DataTable ──────────────────────────────────────────────
    err_area = Rect(inner.x, y, inner.width, err_h)
    if isempty(eh)
        placeholder = Block(title = " Error Hotspots ", border_style = tstyle(:error))
        pi = render(placeholder, err_area, buf)
        set_string!(buf, pi.x + 1, pi.y, "No errors recorded", tstyle(:success))
    else
        rows = eh[1:err_rows]
        labels = Any[
            let cat = get(r, "error_category", ""), etype = get(r, "error_type", "")
                isempty(cat) ? etype : "$cat: $etype"
            end for r in rows
        ]
        tools = Any[get(r, "tool_name", "") for r in rows]
        counts = Any[get(r, "error_count", 0) for r in rows]

        dt = DataTable(
            [
                DataColumn("Error", labels),
                DataColumn("Tool", tools),
                DataColumn("Count", counts; align = col_right),
            ];
            block = Block(title = " Error Hotspots ", border_style = tstyle(:error)),
            show_scrollbar = false,
            selected = 0,
        )
        render(dt, err_area, buf)
    end
    y += err_h

    y > bottom(inner) && return

    # ── Calls/min Sparkline ───────────────────────────────────────────────────
    set_string!(
        buf,
        inner.x + 1,
        y,
        "── Calls/min (last hour) ──",
        tstyle(:secondary, bold = true),
    )
    y += 1
    y > bottom(inner) && return

    bins = zeros(60)
    now_t = now()
    for row in cache.recent_execs
        rt_str = get(row, "request_time", "")
        isempty(rt_str) && continue
        try
            rt = DateTime(rt_str, dateformat"yyyy-mm-dd HH:MM:SS")
            delta_min = Dates.value(now_t - rt) / 60000.0
            idx = clamp(60 - floor(Int, delta_min), 1, 60)
            bins[idx] += 1.0
        catch
        end
    end

    spark_w = min(inner.width - 2, 60)
    spark_data = bins[max(1, 61 - spark_w):60]
    if any(>(0), spark_data)
        render(
            Sparkline(spark_data; style = tstyle(:accent)),
            Rect(inner.x + 1, y, spark_w, 1),
            buf,
        )
    else
        set_string!(buf, inner.x + 1, y, "(no recent activity)", tstyle(:text_dim))
    end
end

function view_activity(m::KaimonModel, area::Rect, buf::Buffer)
    # Analytics mode: render DB-backed summary instead of live tool list
    if m.activity_mode == :analytics
        _view_analytics(m, area, buf)
        return
    end

    panes = split_layout(m.activity_layout, area)
    length(panes) < 2 && return
    m._activity_detail_area = panes[2]

    # ── Build filtered in-flight list ──
    filter_key = m.activity_filter
    filtered_inflight = Int[]  # indices into m.inflight_calls matching filter
    for i = 1:length(m.inflight_calls)
        if isempty(filter_key) || m.inflight_calls[i].session_key == filter_key
            push!(filtered_inflight, i)
        end
    end
    n_inflight = length(filtered_inflight)

    # ── Build filtered completed index list (indices into tool_results) ──
    filtered = Int[]  # indices into m.tool_results matching the filter
    for i = 1:length(m.tool_results)
        if isempty(filter_key) || m.tool_results[i].session_key == filter_key
            push!(filtered, i)
        end
    end
    nf = length(filtered)

    # Total items in the combined list
    total_items = n_inflight + nf

    # Track previous selection to detect changes and invalidate detail cache
    prev_sel_inflight = m.selected_inflight
    prev_sel_result = m.selected_result

    # If selected_inflight points to an index that no longer exists (call completed),
    # fall through to completed selection
    if m.selected_inflight > 0 && m.selected_inflight ∉ filtered_inflight
        m.selected_inflight = 0
        # Try to select the newest completed result instead
        if nf > 0
            m.selected_result = filtered[end]
        end
    end

    # Follow mode: always snap to the newest entry (in-flight preferred)
    if m.activity_follow
        if n_inflight > 0
            m.selected_inflight = filtered_inflight[end]
            m.selected_result = 0
        elseif nf > 0
            m.selected_inflight = 0
            m.selected_result = filtered[end]
        end
    end

    # Auto-select when nothing is selected (initial state or after filter change)
    if m.selected_inflight == 0 && m.selected_result == 0
        if n_inflight > 0
            m.selected_inflight = filtered_inflight[end]
        elseif nf > 0
            m.selected_result = filtered[end]
        end
    end
    # If selected_result is stale (no longer in filtered), fix it
    if m.selected_inflight == 0 && m.selected_result > 0 && m.selected_result ∉ filtered
        m.selected_result = nf > 0 ? filtered[end] : 0
    end

    # Invalidate detail cache when selection changed during fixup above
    if m.selected_inflight != prev_sel_inflight || m.selected_result != prev_sel_result
        m._detail_for_result = -1
        m.detail_paragraph = nothing
    end

    # ── Top pane: tool call list (in-flight at top, then completed newest-first) ──
    items = ListItem[]
    display_sel = 0
    item_idx = 0

    # In-flight calls (newest first = reversed)
    for ii in reverse(filtered_inflight)
        item_idx += 1
        ifc = m.inflight_calls[ii]
        elapsed = time() - ifc.timestamp
        elapsed_str =
            elapsed < 1.0 ? @sprintf("%.0fms", elapsed * 1000) : @sprintf("%.1fs", elapsed)
        ts = Dates.format(ifc.timestamp_dt, "HH:MM:SS")
        sess_name = _session_display_name(ifc.session_key)
        sess_tag = isempty(filter_key) && !isempty(sess_name) ? " [$sess_name]" : ""
        si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
        label = "$ts $(SPINNER_BRAILLE[si]) $(ifc.tool_name)$sess_tag ($elapsed_str)"
        push!(items, ListItem(label, tstyle(:warning)))
        if m.selected_inflight == ii
            display_sel = item_idx
        end
    end

    # Completed calls (newest first)
    for ri in Iterators.reverse(filtered)
        item_idx += 1
        r = m.tool_results[ri]
        ts = Dates.format(r.timestamp, "HH:MM:SS")
        marker = r.success ? "✓" : "✗"
        style = r.success ? tstyle(:success) : tstyle(:error)
        sess_name = _session_display_name(r.session_key)
        sess_tag = isempty(filter_key) && !isempty(sess_name) ? " [$sess_name]" : ""
        label = "$ts $marker $(r.tool_name)$sess_tag ($(r.duration_str))"
        push!(items, ListItem(label, style))
        if m.selected_inflight == 0 && ri == m.selected_result
            display_sel = item_idx
        end
    end

    if isempty(items)
        msg = isempty(filter_key) ? "No tool calls yet" : "No calls for this session"
        push!(items, ListItem("  $msg", tstyle(:text_dim)))
    end

    # Build title with filter indicator
    filter_label = if isempty(filter_key)
        "All"
    else
        name = _session_display_name(filter_key)
        isempty(name) ? filter_key : name
    end
    count_str = n_inflight > 0 ? "$(n_inflight) running, $nf done" : "$nf"
    follow_str = m.activity_follow ? "[F]ollow:on" : "[F]ollow:off"
    list_title =
        isempty(filter_key) ? " Tool Calls ($count_str) [f]ilter $follow_str [d]ata " :
        " Tool Calls ($count_str) [f] $filter_label $follow_str [d]ata "

    list_widget = SelectableList(
        items;
        selected = display_sel,
        offset = m._activity_list_offset,
        block = Block(
            title = list_title,
            border_style = _pane_border(m, 3, 1),
            title_style = _pane_title(m, 3, 1),
        ),
        highlight_style = tstyle(:accent, bold = true),
        tick = m.tick,
    )
    render(list_widget, panes[1], buf)

    # Cache widget for native mouse handling (click + scroll)
    m._activity_list_widget = list_widget
    m._activity_list_offset = list_widget.offset

    # ── Bottom pane: detail panel ──
    # Determine what's selected: in-flight or completed
    show_inflight =
        m.selected_inflight > 0 && m.selected_inflight <= length(m.inflight_calls)
    show_completed =
        !show_inflight &&
        m.selected_result > 0 &&
        m.selected_result <= length(m.tool_results)

    if !show_inflight && !show_completed
        empty_block = Block(
            title = " Details ",
            border_style = _pane_border(m, 3, 2),
            title_style = _pane_title(m, 3, 2),
        )
        ei = render(empty_block, panes[2], buf)
        if ei.width >= 4
            set_string!(
                buf,
                ei.x + 2,
                ei.y + 1,
                "Select a tool call to inspect",
                tstyle(:text_dim),
            )
        end
        render_resize_handles!(buf, m.activity_layout)
        return
    end

    if show_inflight
        # Build detail for in-flight call (rebuilt every frame for live elapsed)
        ifc = m.inflight_calls[m.selected_inflight]
        elapsed = time() - ifc.timestamp
        elapsed_str =
            elapsed < 1.0 ? @sprintf("%.0fms", elapsed * 1000) : @sprintf("%.1fs", elapsed)
        spans = Span[]
        si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
        _detail_span!(spans, "$(SPINNER_BRAILLE[si]) Running", :warning, "Status:   ")
        _detail_span!(spans, elapsed_str, :text, "Elapsed:  ")
        _detail_span!(
            spans,
            Dates.format(ifc.timestamp_dt, "HH:MM:SS"),
            :text,
            "Started:  ",
        )
        sess_name = _session_display_name(ifc.session_key)
        if !isempty(sess_name)
            _detail_span!(
                spans,
                "$sess_name ($(ifc.session_key))",
                :secondary,
                "Session:  ",
            )
        end
        _build_detail_spans!(spans, ifc.tool_name, ifc.args_json, nothing)
        if !isempty(ifc.progress_lines)
            push!(spans, Span("\n", tstyle(:text)))
            push!(spans, Span("── Progress ──\n", tstyle(:text_dim)))
            # Show last N progress lines to keep detail readable
            start_idx = max(1, length(ifc.progress_lines) - 50)
            for i = start_idx:length(ifc.progress_lines)
                push!(spans, Span("  " * ifc.progress_lines[i] * "\n", tstyle(:text)))
            end
        end
        wrap_mode = m.result_word_wrap ? word_wrap : no_wrap
        p = Paragraph(spans; wrap = wrap_mode)
        detail_title = " $(ifc.tool_name) (running) "
        p.block = Block(
            title = detail_title,
            border_style = _pane_border(m, 3, 2),
            title_style = _pane_title(m, 3, 2),
        )
        render(p, panes[2], buf)
        # Don't cache the paragraph — it changes every frame
        m.detail_paragraph = nothing
        m._detail_for_result = -1
    else
        r = m.tool_results[m.selected_result]

        # (Re)build the Paragraph when selection or wrap mode changes
        if m._detail_for_result != m.selected_result || m.detail_paragraph === nothing
            spans = Span[]
            _detail_span!(
                spans,
                r.success ? "✓ Success" : "✗ Failed",
                r.success ? :success : :error,
                "Status:   ",
            )
            _detail_span!(spans, r.duration_str, :text, "Duration: ")
            _detail_span!(spans, Dates.format(r.timestamp, "HH:MM:SS"), :text, "Time:     ")
            sess_name = _session_display_name(r.session_key)
            if !isempty(sess_name)
                _detail_span!(
                    spans,
                    "$sess_name ($(r.session_key))",
                    :secondary,
                    "Session:  ",
                )
            end
            _build_detail_spans!(spans, r.tool_name, r.args_json, r.result_text)
            wrap_mode = m.result_word_wrap ? word_wrap : no_wrap
            m.detail_paragraph = Paragraph(spans; wrap = wrap_mode)
            m._detail_for_result = m.selected_result
        end

        # Update wrap mode if toggled without selection change
        target_wrap = m.result_word_wrap ? word_wrap : no_wrap
        if m.detail_paragraph.wrap != target_wrap
            m.detail_paragraph.wrap = target_wrap
            m.detail_paragraph.scroll_offset = 0
        end

        # Compute scroll info for title
        pane_inner_h = panes[2].height - 2
        pane_inner_w = panes[2].width - 2
        # Check if scrollbar will be shown (reduces available text width by 1)
        total_lines = paragraph_line_count(m.detail_paragraph, pane_inner_w)
        has_scroll = total_lines > pane_inner_h
        if has_scroll && m.detail_paragraph.show_scrollbar && pane_inner_w > 1
            total_lines = paragraph_line_count(m.detail_paragraph, pane_inner_w - 1)
        end
        offset = m.detail_paragraph.scroll_offset

        wrap_hint = m.result_word_wrap ? "w:on" : "w:off"
        detail_title = if has_scroll
            top_line = offset + 1
            bot_line = min(offset + pane_inner_h, total_lines)
            " $(r.tool_name) [$top_line-$bot_line/$total_lines] $wrap_hint "
        else
            " $(r.tool_name) $wrap_hint "
        end

        m.detail_paragraph.block = Block(
            title = detail_title,
            border_style = _pane_border(m, 3, 2),
            title_style = _pane_title(m, 3, 2),
        )

        render(m.detail_paragraph, panes[2], buf)
    end

    # Render the draggable divider between panes
    render_resize_handles!(buf, m.activity_layout)
end

"""Build a labeled detail line as Spans: label in dim, value in given style."""
function _detail_span!(
    spans::Vector{Span},
    value::String,
    style_name::Symbol,
    label::String,
)
    push!(spans, Span(label, tstyle(:text_dim)))
    push!(spans, Span(value * "\n", tstyle(style_name)))
end

# Julia keywords for syntax highlighting
const _JULIA_KEYWORDS = Set([
    "function",
    "end",
    "if",
    "else",
    "elseif",
    "for",
    "while",
    "do",
    "begin",
    "let",
    "try",
    "catch",
    "finally",
    "return",
    "break",
    "continue",
    "struct",
    "mutable",
    "abstract",
    "primitive",
    "type",
    "module",
    "baremodule",
    "using",
    "import",
    "export",
    "const",
    "local",
    "global",
    "macro",
    "quote",
    "true",
    "false",
    "nothing",
    "where",
    "in",
    "isa",
    "new",
])

# Combined tokenizer regex for Julia syntax highlighting.
# Order matters: earlier alternatives take priority.
const _JULIA_TOKEN_RX = r"""
    (?:\"\"\"[\s\S]*?\"\"\")          |  # triple-quoted strings
    (?:\"(?:[^\"\\]|\\.)*\")          |  # double-quoted strings
    (?:\#[^\n]*)                       |  # line comments
    (?:@[A-Za-z_]\w*(?:\.\w+)*)       |  # macros
    (?:0x[0-9a-fA-F]+)                |  # hex numbers
    (?:\b\d+\.?\d*(?:[eE][+-]?\d+)?)  |  # decimal numbers
    (?::[A-Za-z_]\w*)                  |  # symbols
    (?:::|\.\.|->|=>|\|>|<:|>:|&&|\|\||[=+\-*/\\^%&|!<>~]=?) |  # operators
    (?:[A-Za-z_]\w*)                   |  # identifiers
    (?:\S)                                # single non-space chars
"""x

"""Regex-based syntax highlighting for Julia code. Returns Vector{Span}."""
function _highlight_julia(code::String)
    spans = Span[]
    for line in split(code, '\n')
        push!(spans, Span("  ", tstyle(:text)))
        pos = 1
        line_str = string(line)
        for m in eachmatch(_JULIA_TOKEN_RX, line_str)
            # Emit any skipped whitespace before this match
            if m.offset > pos
                push!(spans, Span(line_str[pos:prevind(line_str, m.offset)], tstyle(:text)))
            end
            tok = m.match
            style = if startswith(tok, '#')
                tstyle(:text_dim, italic = true)
            elseif startswith(tok, '"')
                Style(fg = Color256(113))  # green
            elseif startswith(tok, '@')
                tstyle(:warning)
            elseif startswith(tok, "0x") || (!isempty(tok) && isdigit(tok[1]))
                Style(fg = Color256(173))  # orange
            elseif startswith(tok, ':') && length(tok) > 1 && isletter(tok[2])
                Style(fg = Color256(139))  # purple
            elseif tok in _JULIA_KEYWORDS
                tstyle(:accent, bold = true)
            elseif !isempty(tok) &&
                   isuppercase(tok[1]) &&
                   length(tok) > 1 &&
                   occursin(r"^[A-Z][A-Za-z0-9]+$", tok)
                tstyle(:secondary)
            elseif occursin(
                r"^(?:::|\.\.|->|=>|\|>|<:|>:|&&|\|\||[=+\-*/\\^%&|!<>~]=?)$",
                tok,
            )
                tstyle(:text_dim)
            else
                tstyle(:text)
            end
            push!(spans, Span(tok, style))
            pos = m.offset + ncodeunits(tok)
        end
        # Trailing whitespace
        if pos <= ncodeunits(line_str)
            push!(spans, Span(line_str[pos:end], tstyle(:text)))
        end
        push!(spans, Span("\n", tstyle(:text)))
    end
    return spans
end

"""Light formatting for REPL output: errors red, stack traces dim, rest plain."""
function _highlight_repl_output(text::String)
    spans = Span[]
    for line in split(text, '\n')
        ln = string(line)
        if startswith(ln, "ERROR:") || startswith(ln, "ERROR ")
            push!(spans, Span("  ERROR", tstyle(:error, bold = true)))
            push!(spans, Span(ln[6:end] * "\n", tstyle(:error)))
        elseif occursin(r"^\s*@\s+\S+", ln) || occursin(r"^\s*\[\d+\]", ln)
            push!(spans, Span("  " * ln * "\n", tstyle(:text_dim)))
        elseif startswith(ln, "WARNING:") || startswith(ln, "⚠")
            push!(spans, Span("  " * ln * "\n", tstyle(:warning)))
        else
            push!(spans, Span("  " * ln * "\n", tstyle(:text)))
        end
    end
    return spans
end

# Default values for ex tool args (omitted from compact display)
const _EX_DEFAULTS = Dict("q" => true, "s" => false, "max_output" => 6000)

"""Build argument + result spans for the detail pane, with special handling for `ex` tool calls."""
function _build_detail_spans!(
    spans::Vector{Span},
    tool_name::String,
    args_json::String,
    result_text::Union{String,Nothing},
)
    push!(spans, Span("\n", tstyle(:text)))
    if tool_name == "ex"
        # ── ex tool: highlighted code block ──
        try
            args_dict = JSON.parse(args_json)
            code = get(args_dict, "e", nothing)
            if code !== nothing
                push!(spans, Span("── Code ──\n", tstyle(:text_dim)))
                append!(spans, _highlight_julia(string(code)))
            else
                push!(spans, Span("── Arguments ──\n", tstyle(:text_dim)))
                push!(spans, Span("  $(args_json)\n", tstyle(:text)))
            end
            # Show non-default args on a compact summary line
            extras = String[]
            for (k, v) in args_dict
                k == "e" && continue
                default_val = get(_EX_DEFAULTS, k, nothing)
                if default_val === nothing || v != default_val
                    push!(extras, "$k: $(JSON.json(v))")
                end
            end
            if !isempty(extras)
                push!(spans, Span("  " * join(extras, "  ") * "\n", tstyle(:text_dim)))
            end
        catch
            push!(spans, Span("── Arguments ──\n", tstyle(:text_dim)))
            push!(spans, Span("  $(args_json)\n", tstyle(:text)))
        end
    else
        # ── All other tools: key: value display ──
        push!(spans, Span("── Arguments ──\n", tstyle(:text_dim)))
        try
            args_dict = JSON.parse(args_json)
            for (k, v) in args_dict
                val_str = v isa AbstractString ? repr(v) : JSON.json(v)
                push!(spans, Span("  $k: $val_str\n", tstyle(:text)))
            end
        catch
            push!(spans, Span("  $(args_json)\n", tstyle(:text)))
        end
    end

    # ── Result section ──
    if result_text !== nothing
        push!(spans, Span("\n", tstyle(:text)))
        push!(spans, Span("── Result ──\n", tstyle(:text_dim)))
        if tool_name == "ex"
            append!(spans, _highlight_repl_output(result_text))
        else
            for ln in split(result_text, '\n')
                push!(spans, Span("  " * string(ln) * "\n", tstyle(:text)))
            end
        end
    end
end

# ── Tests Tab ─────────────────────────────────────────────────────────────────

function view_tests(m::KaimonModel, area::Rect, buf::Buffer)
    panes = split_layout(m.tests_layout, area)
    length(panes) < 2 && return

    # ── Left pane: test runs list ──
    _view_test_runs_list(m, panes[1], buf)

    # ── Right pane: results or raw output ──
    _view_test_detail(m, panes[2], buf)

    render_resize_handles!(buf, m.tests_layout)

    if m.test_session_picker_open
        _view_test_session_picker(m, area, buf)
    end
end

"""Render the list of test runs in the left pane (newest first)."""
function _view_test_runs_list(m::KaimonModel, area::Rect, buf::Buffer)
    runs = m.test_runs
    items = ListItem[]

    # Display newest first (reversed)
    for i in reverse(eachindex(runs))
        run = runs[i]
        project_name = basename(run.project_path)
        elapsed = if run.finished_at !== nothing
            dt = Dates.value(run.finished_at - run.started_at) / 1000.0
            "$(round(dt, digits=1))s"
        else
            dt = Dates.value(now() - run.started_at) / 1000.0
            "$(round(dt, digits=0))s..."
        end

        text, style = if run.status == RUN_RUNNING
            si = mod1(m.tick ÷ 3, length(SPINNER_BRAILLE))
            ("$(SPINNER_BRAILLE[si]) $project_name $elapsed", tstyle(:accent))
        elseif run.status == RUN_PASSED
            (". $project_name $(run.total_pass) pass $elapsed", tstyle(:success))
        elseif run.status == RUN_FAILED
            (
                "X $project_name $(run.total_pass) pass, $(run.total_fail) fail $elapsed",
                tstyle(:error),
            )
        elseif run.status == RUN_ERROR
            ("! $project_name error $elapsed", tstyle(:error))
        elseif run.status == RUN_CANCELLED
            ("- $project_name cancelled", tstyle(:text_dim))
        else
            ("  $project_name", tstyle(:text))
        end

        push!(items, ListItem(text, style))
    end

    if isempty(items)
        if !isempty(m.test_status_msg)
            push!(items, ListItem("  " * m.test_status_msg, tstyle(:error)))
        else
            push!(
                items,
                ListItem("  No test runs yet. Press [r] to run tests.", tstyle(:text_dim)),
            )
        end
    end

    # Map selected_test_run (1-based index into runs) to reversed display position
    n = length(runs)
    display_selected = if m.selected_test_run >= 1 && m.selected_test_run <= n
        n - m.selected_test_run + 1
    else
        0
    end

    follow_str = m.test_follow ? "[F]ollow:on" : "[F]ollow:off"
    render(
        SelectableList(
            items;
            selected = display_selected,
            block = Block(
                title = " Test Runs ($n) $follow_str ",
                border_style = _pane_border(m, 6, 1),
                title_style = _pane_title(m, 6, 1),
            ),
            highlight_style = tstyle(:accent, bold = true),
            tick = m.tick,
        ),
        area,
        buf,
    )
end

"""Render the test detail view (results table or raw output)."""
function _view_test_detail(m::KaimonModel, area::Rect, buf::Buffer)
    sel = m.selected_test_run
    if sel < 1 || sel > length(m.test_runs)
        render(
            Block(
                title = " Results ",
                border_style = _pane_border(m, 6, 2),
                title_style = _pane_title(m, 6, 2),
            ),
            area,
            buf,
        )
        return
    end

    run = m.test_runs[sel]
    mode_str = m.test_view_mode == :results ? "Results" : "Output"
    title = " $mode_str [o]toggle "

    if m.test_view_mode == :output
        # Raw output scroll pane
        _view_test_raw_output(m, run, area, buf, title)
    else
        # Structured results view
        _view_test_results(m, run, area, buf, title)
    end
end

"""Build a collapsible TreeNode from a TestRun's results.

Returns a root node with testset hierarchy. Collapsed by default,
except nodes containing errors are auto-expanded. Failures are shown
as leaf nodes under a "Failures" child of root."""
function _make_result_node(r::TestResult)::TreeNode
    has_errors = r.fail_count > 0 || r.error_count > 0
    node_style = has_errors ? tstyle(:error, bold = true) : tstyle(:success, bold = true)
    counts = "$(r.pass_count)p"
    r.fail_count > 0 && (counts *= " $(r.fail_count)f")
    r.error_count > 0 && (counts *= " $(r.error_count)e")
    label = "$(r.name)  $counts"
    TreeNode(label; expanded = false, style = node_style)
end

"""Pre-order: parents appear before children (from Test Summary tables)."""
function _build_tree_preorder!(root::TreeNode, results::Vector{TestResult})
    stack = TreeNode[root]
    for r in results
        node = _make_result_node(r)
        target_level = r.depth + 1
        while length(stack) > target_level
            pop!(stack)
        end
        parent = stack[end]
        push!(parent.children, node)
        push!(stack, node)
    end
end

"""Post-order: children appear before parents (from TESTSET_DONE lines).
Each testset finishes after its children, so children are emitted first."""
function _build_tree_postorder!(root::TreeNode, results::Vector{TestResult})
    # pending_children[depth] = nodes at that depth waiting for a parent
    pending = Dict{Int,Vector{TreeNode}}()
    for r in results
        node = _make_result_node(r)
        # Claim any pending children at depth+1 as our children
        child_depth = r.depth + 1
        if haskey(pending, child_depth)
            append!(node.children, pending[child_depth])
            delete!(pending, child_depth)
        end
        # Add this node to pending at its depth
        pv = get!(Vector{TreeNode}, pending, r.depth)
        push!(pv, node)
    end
    # Remaining nodes at depth 0 are top-level results → attach to root
    if haskey(pending, 0)
        append!(root.children, pending[0])
    end
    # Any orphan nodes at higher depths (shouldn't happen, but safety)
    for d in sort(collect(keys(pending)))
        d == 0 && continue
        append!(root.children, pending[d])
    end
end

function _build_test_tree(run::TestRun)::TreeNode
    # Root label: status summary
    status_str = uppercase(string(run.status))[5:end]  # strip "RUN_"
    root_style = if run.status == RUN_PASSED
        tstyle(:success, bold = true)
    elseif run.status in (RUN_FAILED, RUN_ERROR)
        tstyle(:error, bold = true)
    elseif run.status == RUN_RUNNING
        tstyle(:accent, bold = true)
    else
        tstyle(:text_dim)
    end
    counts_str =
        if run.status == RUN_RUNNING && run.total_pass == 0 && !isempty(run.results)
            "$(length(run.results)) testsets completed"
        else
            "Pass:$(run.total_pass) Fail:$(run.total_fail) Error:$(run.total_error)"
        end
    root = TreeNode("$status_str  $counts_str"; expanded = true, style = root_style)

    # Build testset hierarchy from results.
    # TESTSET_DONE arrives in post-order (children before parents), while
    # Test Summary tables arrive in pre-order (parents before children).
    # Detect: if the first result has higher depth than any later result's
    # minimum, it's post-order. Also, if depth-0 result is last, it's post-order.
    if !isempty(run.results)
        is_postorder = if length(run.results) >= 2
            # Post-order: first result depth > 0 (leaves first), or
            # first result depth >= second (not descending from root)
            run.results[1].depth > 0 || run.results[1].depth > run.results[2].depth
        else
            false  # single result, order doesn't matter
        end

        if is_postorder
            _build_tree_postorder!(root, run.results)
        else
            _build_tree_preorder!(root, run.results)
        end
    end

    # Add failure detail nodes under a "Failures" group
    if !isempty(run.failures)
        fail_group = TreeNode(
            "Failures ($(length(run.failures)))";
            expanded = true,
            style = tstyle(:error, bold = true),
        )
        for (i, f) in enumerate(run.failures)
            loc = "$(f.file):$(f.line)"
            detail = isempty(f.expression) ? loc : "$loc — $(f.expression)"
            push!(
                fail_group.children,
                TreeNode(
                    "$i) $detail";
                    expanded = false,
                    style = tstyle(:error, bold = true),
                ),
            )
        end
        push!(root.children, fail_group)
    end

    # If running and no results yet, add progress indicator
    if run.status == RUN_RUNNING && isempty(run.results)
        n_lines = length(run.raw_output)
        push!(
            root.children,
            TreeNode(
                "Running... ($n_lines lines of output)";
                expanded = false,
                style = tstyle(:accent),
            ),
        )
    end

    # Auto-expand nodes that contain errors (walk tree, expand ancestors of error nodes)
    _auto_expand_errors!(root)

    root
end

"""Recursively expand nodes that have error descendants."""
function _auto_expand_errors!(node::TreeNode)::Bool
    if isempty(node.children)
        # Leaf: check if it's an error node (style matches error)
        return node.style == tstyle(:error)
    end
    has_error_child = false
    for child in node.children
        if _auto_expand_errors!(child)
            has_error_child = true
        end
    end
    if has_error_child
        node.expanded = true
    end
    has_error_child || node.style == tstyle(:error)
end

"""Render structured test results as a collapsible TreeView."""
function _view_test_results(
    m::KaimonModel,
    run::TestRun,
    area::Rect,
    buf::Buffer,
    title::String,
)
    # Build/rebuild tree when output changes
    cur_len = length(run.raw_output) + length(run.results)
    if m.test_tree_view === nothing || m._test_tree_synced != cur_len
        root = _build_test_tree(run)
        m.test_tree_view = TreeView(
            root;
            selected = 1,
            block = Block(
                title = title,
                border_style = _pane_border(m, 6, 2),
                title_style = _pane_title(m, 6, 2),
            ),
            show_root = true,
        )
        m._test_tree_synced = cur_len
    else
        # Update block title (may change dynamically)
        m.test_tree_view.block = Block(
            title = title,
            border_style = _pane_border(m, 6, 2),
            title_style = _pane_title(m, 6, 2),
        )
    end

    render(m.test_tree_view, area, buf)
end

"""Render raw test output in a ScrollPane."""
function _view_test_raw_output(
    m::KaimonModel,
    run::TestRun,
    area::Rect,
    buf::Buffer,
    title::String,
)
    if m.test_output_pane === nothing || m._test_output_synced == 0
        lines = Vector{Span}[]
        for raw_line in run.raw_output
            line = raw_line
            style = if startswith(line, "TEST_RUNNER:")
                tstyle(:accent)
            elseif contains(line, "Error") ||
                   contains(line, "FAILED") ||
                   contains(line, "FAIL")
                tstyle(:error)
            elseif contains(line, "Pass") || contains(line, "PASSED")
                tstyle(:success)
            else
                tstyle(:text)
            end
            push!(lines, [Span(line, style)])
        end

        m.test_output_pane = ScrollPane(
            lines;
            following = run.status == RUN_RUNNING,
            reverse = false,
            block = Block(
                title = title,
                border_style = _pane_border(m, 6, 2),
                title_style = _pane_title(m, 6, 2),
            ),
            show_scrollbar = true,
        )
        m._test_output_synced = length(run.raw_output)
    else
        # New output — append to pane
        if length(run.raw_output) > m._test_output_synced
            pane = m.test_output_pane
            if pane !== nothing
                for i = (m._test_output_synced+1):length(run.raw_output)
                    line = run.raw_output[i]
                    style = if contains(line, "Error") || contains(line, "FAIL")
                        tstyle(:error)
                    elseif contains(line, "Pass")
                        tstyle(:success)
                    else
                        tstyle(:text)
                    end
                    push_line!(pane, [Span(line, style)])
                end
                m._test_output_synced = length(run.raw_output)
            end
        end
    end

    m.test_output_pane !== nothing && render(m.test_output_pane, area, buf)
end

"""Handle char keys on the Tests tab."""
function _handle_tests_key!(m::KaimonModel, evt::KeyEvent)
    @match evt.char begin
        'r' => _start_test_run_from_tui!(m)
        'o' => begin
            m.test_view_mode = m.test_view_mode == :results ? :output : :results
            _reset_test_panes!(m)
        end
        'F' => (m.test_follow = !m.test_follow)
        'x' => begin
            sel = m.selected_test_run
            if sel >= 1 && sel <= length(m.test_runs)
                run = m.test_runs[sel]
                run.status == RUN_RUNNING && cancel_test_run!(run)
            end
        end
        ' ' => begin
            # Space toggles expand/collapse in tree view
            fp = get(m.focused_pane, 6, 1)
            if fp == 2 && m.test_view_mode == :results && m.test_tree_view !== nothing
                handle_key!(m.test_tree_view, evt)
            end
        end
        _ => nothing
    end
end

"""Handle escape on the Tests tab — cancel running test."""
function _handle_tests_escape!(m::KaimonModel)
    sel = m.selected_test_run
    if sel >= 1 && sel <= length(m.test_runs)
        run = m.test_runs[sel]
        if run.status == RUN_RUNNING
            cancel_test_run!(run)
            return
        end
    end
    # If no running test, do nothing (don't quit)
end

"""Start a test run from the TUI. Shows a session picker if multiple testable sessions exist."""
function _start_test_run_from_tui!(m::KaimonModel)
    mgr = m.conn_mgr
    conns = mgr !== nothing ? connected_sessions(mgr) : REPLConnection[]

    if isempty(conns)
        m.test_status_msg = "No gate sessions connected — run Gate.serve() in a Julia REPL first"
        return
    end

    testable = filter(conns) do conn
        !isempty(conn.project_path) &&
            isfile(joinpath(conn.project_path, "test", "runtests.jl"))
    end

    if isempty(testable)
        names = join([isempty(c.display_name) ? c.name : c.display_name for c in conns], ", ")
        m.test_status_msg = "No test/runtests.jl found in connected sessions ($names)"
        return
    end

    if length(testable) == 1
        m.test_status_msg = ""
        _launch_test_run!(m, testable[1].project_path)
        return
    end

    # Multiple sessions with tests — open picker
    m.test_status_msg = ""
    m.test_session_picker_items = [
        (label = isempty(c.display_name) ? c.name : c.display_name, project_path = c.project_path)
        for c in testable
    ]
    m.test_session_picker_selected = 1
    m.test_session_picker_open = true
end

"""Launch a test run for the given project path."""
function _launch_test_run!(m::KaimonModel, project_path::String)
    run = spawn_test_run(project_path)
    push!(m.test_runs, run)
    m.selected_test_run = length(m.test_runs)
    _reset_test_panes!(m)
end

"""Handle key input inside the session picker dialog."""
function _handle_test_picker_key!(m::KaimonModel, evt::KeyEvent)
    n = length(m.test_session_picker_items)
    @match evt.key begin
        :escape => (m.test_session_picker_open = false)
        :up => begin
            m.test_session_picker_selected =
                m.test_session_picker_selected <= 1 ? n : m.test_session_picker_selected - 1
        end
        :down => begin
            m.test_session_picker_selected =
                m.test_session_picker_selected >= n ? 1 : m.test_session_picker_selected + 1
        end
        :enter => begin
            sel = clamp(m.test_session_picker_selected, 1, n)
            proj = m.test_session_picker_items[sel].project_path
            m.test_session_picker_open = false
            _launch_test_run!(m, proj)
        end
        _ => nothing
    end
end

"""Render the session picker dialog as a centered overlay."""
function _view_test_session_picker(m::KaimonModel, area::Rect, buf::Buffer)
    _dim_area!(buf, area)

    items = m.test_session_picker_items
    n = length(items)
    h = min(n + 6, area.height - 4)
    w = min(60, area.width - 4)
    rect = center(area, w, h)

    border_s = tstyle(:accent, bold = true)
    inner = if animations_enabled()
        border_shimmer!(buf, rect, border_s.fg, m.tick; box = BOX_HEAVY, intensity = 0.12)
        title = " Choose Session "
        rect.width > length(title) + 4 &&
            set_string!(buf, rect.x + 2, rect.y, title, border_s)
        Rect(rect.x + 1, rect.y + 1, max(0, rect.width - 2), max(0, rect.height - 2))
    else
        render(
            Block(
                title = " Choose Session ",
                border_style = border_s,
                title_style = border_s,
                box = BOX_HEAVY,
            ),
            rect,
            buf,
        )
    end
    inner.width < 4 && return

    for row = inner.y:bottom(inner)
        for col = inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style())
        end
    end

    y = inner.y
    x = inner.x + 1
    max_y = bottom(inner)
    max_w = inner.width - 2

    set_string!(buf, x, y, "Select a session to run tests for:", tstyle(:text_dim))
    y += 1
    y <= max_y && (set_string!(buf, x, y, "─"^min(max_w, 56), tstyle(:border)); y += 1)

    for (i, item) in enumerate(items)
        y > max_y - 2 && break
        is_sel = i == m.test_session_picker_selected
        prefix = is_sel ? "▶ " : "  "
        label = prefix * item.label
        proj = basename(item.project_path)
        style = is_sel ? tstyle(:accent, bold = true) : tstyle(:text)
        set_string!(buf, x, y, rpad(label, min(max_w - length(proj) - 2, max_w)), style)
        if length(label) + length(proj) + 2 <= max_w
            set_string!(buf, x + max_w - length(proj), y, proj, tstyle(:text_dim))
        end
        y += 1
    end

    y += 1
    y <= max_y && set_string!(
        buf,
        x,
        y,
        "↑↓ navigate   Enter confirm   Esc cancel",
        tstyle(:text_dim),
    )
end

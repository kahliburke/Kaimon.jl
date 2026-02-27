# ═══════════════════════════════════════════════════════════════════════════════
# GateTool handler functions for the TodoBoard
#
# Each handler is a normal Julia function with typed signatures. The gate
# infrastructure reflects on the signature to generate MCP schema and
# _dispatch_tool_call coerces incoming Dict values automatically.
# ═══════════════════════════════════════════════════════════════════════════════

using Kaimon.Gate: GateTool

"""
    create_tools(model::TodoBoardModel) -> Vector{GateTool}

Create all GateTools with handlers closed over `model`.
"""
function create_tools(model)

    # ── Board manipulation ─────────────────────────────────────────────────────

    """
        add_task(title, description, priority, tags) -> String

    Add a new task to the board. Returns the new task's ID.

    Exercises: enum coercion (Priority) + Vector{Tag} (nested struct array).
    """
    function add_task(
        title::String,
        description::String,
        priority::Priority,
        tags::Vector{Tag},
    )
        id = isempty(model.tasks) ? 1 : maximum(t.id for t in model.tasks) + 1
        push!(model.tasks, TaskItem(id, title, description, priority, todo, tags))
        push!(model.event_log, "Added task #$id: $title")
        return "Created task #$id"
    end

    """
        move_task(task_id, new_status) -> String

    Move a task to a new status column. Returns confirmation.

    Exercises: enum coercion (TodoStatus).
    """
    function move_task(task_id::Int, new_status::TodoStatus)
        idx = findfirst(t -> t.id == task_id, model.tasks)
        idx === nothing && return "Error: task #$task_id not found"
        old = model.tasks[idx]
        model.tasks[idx] =
            TaskItem(old.id, old.title, old.description, old.priority, new_status, old.tags)
        push!(model.event_log, "Moved task #$task_id → $new_status")
        return "Moved task #$task_id to $new_status"
    end

    """
        get_board() -> String

    Get the current board state as a formatted summary.

    Exercises: no-arg tool, returns complex state.
    """
    function get_board()
        lines = String[]
        for status in (todo, in_progress, done)
            col_tasks = filter(t -> t.status == status, model.tasks)
            push!(lines, "── $(uppercase(string(status))) ($(length(col_tasks))) ──")
            for t in col_tasks
                tags_str =
                    isempty(t.tags) ? "" : " [$(join((tg.name for tg in t.tags), ", "))]"
                push!(lines, "  #$(t.id) [$(t.priority)] $(t.title)$tags_str")
            end
        end
        push!(lines, "Theme: $(model.theme)")
        return join(lines, "\n")
    end

    """
        send_events(events) -> String

    Send a batch of input events to the TUI. Each event step can have a delay
    and either a key event or a mouse event.

    Exercises: deeply nested type — Vector{EventStep} containing optional union
    fields with enum + struct members.
    """
    function send_events(events::Vector{EventStep})
        count = 0
        for step in events
            step.delay_ms > 0 && sleep(step.delay_ms / 1000.0)
            if step.key_event !== nothing
                ke = step.key_event
                tev =
                    length(ke.key) == 1 ? Tachikoma.KeyEvent(ke.key[1]) :
                    Tachikoma.KeyEvent(Symbol(ke.key))
                Tachikoma.update!(model, tev)
                count += 1
            end
            if step.mouse_event !== nothing
                me = step.mouse_event
                btn = if me.button == btn_left
                    Tachikoma.mouse_left
                elseif me.button == btn_right
                    Tachikoma.mouse_right
                elseif me.button == btn_middle
                    Tachikoma.mouse_middle
                elseif me.button == btn_scroll_up
                    Tachikoma.mouse_scroll_up
                elseif me.button == btn_scroll_down
                    Tachikoma.mouse_scroll_down
                else
                    Tachikoma.mouse_left
                end
                Tachikoma.update!(
                    model,
                    Tachikoma.MouseEvent(
                        me.x,
                        me.y,
                        btn,
                        Tachikoma.mouse_press,
                        false,
                        false,
                        false,
                    ),
                )
                count += 1
            end
        end
        push!(
            model.event_log,
            "Dispatched $count events from batch of $(length(events)) steps",
        )
        return "Dispatched $count events"
    end

    """
        get_screen(x, y, width, height) -> String

    Capture a rectangular region of the screen as text.

    Exercises: simple primitives, returns screen capture.
    """
    function get_screen(x::Int, y::Int, width::Int, height::Int)
        return join(
            [
                "Screen capture ($x,$y) $(width)x$(height):",
                "Tasks: $(length(model.tasks))",
                "Selected: column=$(model.selected_column) task=$(model.selected_task)",
                "Theme: $(model.theme)",
            ],
            "\n",
        )
    end

    """
        set_theme(theme) -> String

    Change the board's visual theme.

    Exercises: simple enum coercion (BoardTheme).
    """
    function set_theme(theme::BoardTheme)
        model.theme = theme
        push!(model.event_log, "Theme changed to $theme")
        return "Theme set to $theme"
    end

    """
        view_task(task_id) -> String

    Open the detail modal for a specific task by ID.

    Exercises: programmatic modal control, selection cursor manipulation.
    """
    function view_task(task_id::Int)
        idx = findfirst(t -> t.id == task_id, model.tasks)
        idx === nothing && return "Error: task #$task_id not found"
        task = model.tasks[idx]
        col = findfirst(==(task.status), COLUMNS)
        col === nothing && return "Error: task #$task_id has unmapped status $(task.status)"
        col_tasks = filter(t -> t.status == task.status, model.tasks)
        model.selected_column = col
        model.selected_task = findfirst(t -> t.id == task_id, col_tasks)
        model.show_detail = true
        push!(model.event_log, "Opened detail for task #$task_id")
        return "Viewing task #$task_id"
    end

    # ── Long-running / noise tools ─────────────────────────────────────────────

    """
        run_test_suite() -> String

    Run an end-to-end test suite exercising all tools in the background.

    Exercises: orchestration, async execution, comprehensive tool coverage.
    """
    function run_test_suite()
        push!(model.event_log, "Test suite starting...")
        @async try
            _run_suite!(
                model,
                (; add_task, move_task, get_board, send_events, set_theme, view_task),
            )
        catch e
            push!(model.event_log, "Test suite FAILED: $e")
        end
        return "Test suite started"
    end

    """
        run_noise_test(duration_secs, interval_ms) -> String

    Spawn background tasks that write noisy output to stdout, stderr, and the
    logging system for the given duration. Verifies TUI IO capture.
    """
    function run_noise_test(duration_secs::Int, interval_ms::Int)
        push!(model.event_log, "Noise test: $(duration_secs)s @ $(interval_ms)ms interval")
        @async try
            deadline = time() + duration_secs
            i = 0
            while time() < deadline
                i += 1
                sleep(interval_ms / 1000.0)
                println("noise[$i] println: The quick brown fox jumps over the lazy dog")
                print("noise[$i] print-no-newline...")
                println(" continued")
                @info "noise[$i] @info message" iteration = i
                @warn "noise[$i] @warn something looks suspicious" value = rand()
                write(stdout, "noise[$i] raw write to stdout\n")
                write(stderr, "noise[$i] raw write to stderr\n")
                if i % 5 == 0
                    println("noise[$i] === Test Results ===")
                    println("noise[$i]   Pass: $(rand(10:50))")
                    println("noise[$i]   Fail: $(rand(0:3))")
                    println("noise[$i]   Skip: $(rand(0:5))")
                    println("noise[$i] ===================")
                end
            end
            push!(model.event_log, "Noise test finished: $i iterations")
        catch e
            push!(model.event_log, "Noise test error: $e")
        end
        return "Noise test started ($(duration_secs)s, $(interval_ms)ms interval)"
    end

    """
        slow_task(duration_secs) -> String

    Sleep for the given duration with no progress updates. Tests that the async
    transport does not time out on silent long-running handlers.
    """
    function slow_task(duration_secs::Int)
        push!(model.event_log, "Slow task starting ($(duration_secs)s)...")
        sleep(duration_secs)
        push!(model.event_log, "Slow task finished after $(duration_secs)s")
        return "Completed after $(duration_secs)s"
    end

    """
        run_timed_op(steps, delay_ms) -> String

    Run `steps` iterations with `delay_ms` milliseconds between each, emitting a
    progress update after every step.
    """
    function run_timed_op(steps::Int, delay_ms::Int)
        push!(model.event_log, "Timed op: $steps steps × $(delay_ms)ms")
        for i = 1:steps
            sleep(delay_ms / 1000.0)
            progress("step $i/$steps")
        end
        push!(model.event_log, "Timed op done (~$(steps * delay_ms)ms total)")
        return "Completed $steps steps in ~$(steps * delay_ms)ms"
    end

    """
        analyze_board(passes) -> String

    Simulate a multi-pass board analysis with ~300ms per pass, emitting live
    task statistics as progress after each pass.
    """
    function analyze_board(passes::Int)
        push!(model.event_log, "Board analysis: $passes passes")
        for pass = 1:passes
            sleep(0.3)
            n_tasks = length(model.tasks)
            n_done = count(t -> t.status == done, model.tasks)
            n_wip = count(t -> t.status == in_progress, model.tasks)
            n_hot = count(t -> t.priority in (high, critical), model.tasks)
            progress(
                "pass $pass/$passes — $n_tasks tasks: $n_wip in-progress, $n_done done, $n_hot high-priority",
            )
        end
        n_tasks = length(model.tasks)
        n_done = count(t -> t.status == done, model.tasks)
        n_todo = count(t -> t.status == todo, model.tasks)
        n_wip = count(t -> t.status == in_progress, model.tasks)
        summary = "$n_tasks total | $n_todo todo | $n_wip in-progress | $n_done done"
        push!(model.event_log, "Analysis done: $summary")
        return summary
    end

    # ── Registry ───────────────────────────────────────────────────────────────

    return GateTool[
        GateTool("add_task", add_task),
        GateTool("move_task", move_task),
        GateTool("get_board", get_board),
        GateTool("send_events", send_events),
        GateTool("get_screen", get_screen),
        GateTool("set_theme", set_theme),
        GateTool("view_task", view_task),
        GateTool("run_test_suite", run_test_suite),
        GateTool("run_noise_test", run_noise_test),
        GateTool("slow_task", slow_task),
        GateTool("run_timed_op", run_timed_op),
        GateTool("analyze_board", analyze_board),
    ]
end

# ── Test suite impl ────────────────────────────────────────────────────────────

function _run_suite!(model, h)
    delay() = sleep(0.35)

    push!(model.event_log, "▶ Phase 1: Data manipulation")
    delay()
    h.add_task(
        "Setup CI pipeline",
        "Configure GitHub Actions for automated testing",
        critical,
        [Tag("devops", :blue), Tag("infra", :purple)],
    )
    delay()
    h.add_task(
        "Fix login bug",
        "Users get 500 on expired sessions",
        high,
        [Tag("bug", :red)],
    )
    delay()
    h.add_task("Update README", "Add installation instructions", low, Tag[])
    delay()
    h.add_task(
        "Dark mode support",
        "Implement theme toggle in settings page",
        medium,
        [Tag("feature", :green), Tag("ui", :cyan)],
    )
    delay()
    result = h.get_board()
    push!(model.event_log, "Board state: $(count('\n', result)+1) lines")
    delay()
    h.move_task(1, in_progress)
    delay()
    h.move_task(2, in_progress)
    delay()
    h.move_task(1, done)
    delay()
    h.view_task(3)
    delay()
    sleep(0.5)
    model.show_detail = false
    delay()

    push!(model.event_log, "▶ Phase 2: Keyboard navigation")
    delay()
    _key = (k) -> [EventStep(0, InputEvent(k, mod_none, nothing), nothing)]
    for k in ["h", "h", "j", "j", "k", "l", "l"]
        h.send_events(_key(k))
        delay()
    end
    h.send_events(_key("h"))
    delay()
    h.send_events(_key("j"))
    delay()
    h.send_events([EventStep(0, InputEvent("enter", mod_none, nothing), nothing)])
    delay()

    push!(model.event_log, "▶ Phase 3: Mouse interaction")
    delay()
    _click = (x, y) -> [EventStep(0, nothing, MouseInput(x, y, btn_left))]
    _scroll = (x, y, dir) -> [EventStep(0, nothing, MouseInput(x, y, dir))]
    h.send_events(_click(5, 3))
    delay()
    h.send_events(_click(5, 3))
    delay()
    sleep(0.5)
    model.show_detail = false
    delay()
    h.send_events(_scroll(40, 20, btn_scroll_down))
    delay()
    h.send_events(_scroll(40, 20, btn_scroll_up))
    delay()

    push!(model.event_log, "▶ Phase 4: Theme cycling")
    delay()
    for t in (minimal, compact, colorful)
        h.set_theme(t)
        sleep(0.5)
    end

    push!(model.event_log, "▶ Phase 5: Detail modal")
    delay()
    h.view_task(1)
    sleep(0.6)
    model.show_detail = false
    delay()
    h.view_task(3)
    sleep(0.6)
    _key2 = (k) -> [EventStep(0, InputEvent(k, mod_none, nothing), nothing)]
    h.send_events(_key2("d"))
    delay()
    h.send_events(_key2("l"))
    delay()
    h.send_events(_key2("d"))
    sleep(0.6)
    h.send_events(_key2("d"))
    delay()

    push!(model.event_log, "✓ Test suite completed successfully")
end

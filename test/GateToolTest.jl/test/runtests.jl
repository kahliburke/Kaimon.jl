using Test
using GateToolTest
using GateToolTest:
    Tag,
    TaskItem,
    Priority,
    TodoStatus,
    BoardTheme,
    InputEvent,
    MouseInput,
    EventStep,
    KeyModifier,
    MouseButtonType,
    low,
    medium,
    high,
    critical,
    todo,
    in_progress,
    done,
    archived,
    minimal,
    colorful,
    compact,
    mod_none,
    mod_ctrl,
    btn_left,
    btn_right,
    btn_scroll_up,
    btn_scroll_down

# ═══════════════════════════════════════════════════════════════════════════════
# Intentional stdout/stderr noise — tests that the TUI capture handles this
# ═══════════════════════════════════════════════════════════════════════════════

println("NOISE: test suite starting — this should be captured, not corrupt the TUI")
println(stderr, "NOISE: stderr test line — should also be captured")
@info "NOISE: @info from test suite" pid = getpid()
@warn "NOISE: @warn from test suite" timestamp = time()

# ═══════════════════════════════════════════════════════════════════════════════
# Type construction tests
# ═══════════════════════════════════════════════════════════════════════════════

@testset "Types" begin
    @testset "Tag" begin
        t = Tag("bug", :red)
        @test t.name == "bug"
        @test t.color == :red
    end

    @testset "TaskItem" begin
        tags = [Tag("feature", :green), Tag("ui", :cyan)]
        task = TaskItem(1, "Add login", "OAuth2 flow", high, todo, tags)
        @test task.id == 1
        @test task.title == "Add login"
        @test task.priority == high
        @test task.status == todo
        @test length(task.tags) == 2
        @test task.tags[1].name == "feature"
    end

    @testset "InputEvent" begin
        ke = InputEvent("enter", mod_none, nothing)
        @test ke.key == "enter"
        @test ke.modifier == mod_none
        @test ke.text === nothing

        ke2 = InputEvent("a", mod_ctrl, "hello")
        @test ke2.text == "hello"
    end

    @testset "MouseInput" begin
        me = MouseInput(10, 5, btn_left)
        @test me.x == 10
        @test me.y == 5
        @test me.button == btn_left
    end

    @testset "EventStep" begin
        ke = InputEvent("j", mod_none, nothing)
        step = EventStep(100, ke, nothing)
        @test step.delay_ms == 100
        @test step.key_event !== nothing
        @test step.mouse_event === nothing

        me = MouseInput(1, 1, btn_scroll_up)
        step2 = EventStep(0, nothing, me)
        @test step2.key_event === nothing
        @test step2.mouse_event !== nothing
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Tool handler tests
# ═══════════════════════════════════════════════════════════════════════════════

println("NOISE: about to create model and tools")

@testset "Tool handlers" begin
    model = TodoBoardModel()
    tools = create_tools(model)

    # Extract handlers by name
    tool_map = Dict(t.name => t.handler for t in tools)

    add_task = tool_map["add_task"]
    move_task = tool_map["move_task"]
    get_board = tool_map["get_board"]
    set_theme = tool_map["set_theme"]
    view_task = tool_map["view_task"]
    get_screen = tool_map["get_screen"]

    @testset "add_task" begin
        println("NOISE: testing add_task")
        result = add_task("Fix bug", "Null pointer in auth", high, [Tag("bug", :red)])
        @test occursin("Created task #1", result)
        @test length(model.tasks) == 1
        @test model.tasks[1].title == "Fix bug"
        @test model.tasks[1].priority == high
        @test model.tasks[1].status == todo
        @test length(model.tasks[1].tags) == 1

        result2 = add_task("Add tests", "Unit tests for auth module", medium, Tag[])
        @test occursin("#2", result2)
        @test length(model.tasks) == 2

        # Task with multiple tags
        result3 = add_task(
            "Refactor DB",
            "Migrate to connection pool",
            critical,
            [Tag("backend", :blue), Tag("perf", :yellow), Tag("db", :purple)],
        )
        @test occursin("#3", result3)
        @test length(model.tasks[3].tags) == 3
    end

    @testset "move_task" begin
        println("NOISE: testing move_task")
        @info "NOISE: moving task 1 to in_progress"
        result = move_task(1, in_progress)
        @test occursin("Moved task #1", result)
        @test model.tasks[1].status == in_progress

        move_task(1, done)
        @test model.tasks[1].status == done

        # Move non-existent task
        result_err = move_task(999, todo)
        @test occursin("Error", result_err)
    end

    @testset "get_board" begin
        println("NOISE: testing get_board — dumping board state to stdout")
        result = get_board()
        @test occursin("TODO", result)
        @test occursin("IN_PROGRESS", result)
        @test occursin("DONE", result)
        @test occursin("Fix bug", result)
        # Print the board — intentional noise
        println(result)
    end

    @testset "set_theme" begin
        set_theme(minimal)
        @test model.theme == minimal
        set_theme(compact)
        @test model.theme == compact
        set_theme(colorful)
        @test model.theme == colorful
    end

    @testset "view_task" begin
        @warn "NOISE: about to view task details"
        result = view_task(1)
        @test occursin("Viewing task #1", result)
        @test model.show_detail == true
        model.show_detail = false

        result_err = view_task(999)
        @test occursin("Error", result_err)
    end

    @testset "get_screen" begin
        result = get_screen(1, 1, 80, 24)
        @test occursin("Screen capture", result)
        @test occursin("Tasks: 3", result)
    end

    @testset "event_log populated" begin
        @test length(model.event_log) > 0
        @test any(contains("Added task"), model.event_log)
        @test any(contains("Moved task"), model.event_log)
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Enum coverage
# ═══════════════════════════════════════════════════════════════════════════════

@testset "Enum values" begin
    @testset "Priority" begin
        @test Int(low) == 0
        @test Int(critical) == 3
        @test length(instances(Priority)) == 4
    end

    @testset "TodoStatus" begin
        @test length(instances(TodoStatus)) == 4
        @test todo != in_progress
    end

    @testset "BoardTheme" begin
        @test length(instances(BoardTheme)) == 3
    end

    @testset "KeyModifier" begin
        @test length(instances(KeyModifier)) == 4
    end

    @testset "MouseButtonType" begin
        @test length(instances(MouseButtonType)) == 5
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Bulk operations — more noise
# ═══════════════════════════════════════════════════════════════════════════════

@testset "Bulk task operations" begin
    model = TodoBoardModel()
    tools = create_tools(model)
    add = Dict(t.name => t.handler for t in tools)["add_task"]
    move = Dict(t.name => t.handler for t in tools)["move_task"]
    board = Dict(t.name => t.handler for t in tools)["get_board"]

    # Add 20 tasks with noisy output
    for i = 1:20
        println("NOISE: creating task $i/20")
        add("Task $i", "Description for task $i", instances(Priority)[mod1(i, 4)], Tag[])
    end
    @test length(model.tasks) == 20

    # Move half to in_progress
    for i = 1:10
        @info "NOISE: moving task $i to in_progress" task_id = i
        move(i, in_progress)
    end

    # Move some to done
    for i = 1:5
        move(i, done)
    end

    result = board()
    println("NOISE: final board state:")
    println(result)
    @test occursin("DONE (5)", result)
    @test occursin("IN_PROGRESS (5)", result)
    @test occursin("TODO (10)", result)
end

println("NOISE: all tests complete — if you can read this in the log, capture works!")
@info "NOISE: test suite finished" total_tests = Test.get_testset().n_passed

# ═══════════════════════════════════════════════════════════════════════════════
# Debug test scenarios — functions with @infiltrate breakpoints for testing
# the Debug TUI tab and Infiltrator integration.
#
# Usage from agent (after `using GateToolTest` in a separate eval):
#   GateToolTest.debug_fibonacci(10)     — simple locals (a, b, i, n)
#   GateToolTest.debug_data_pipeline()   — dicts, arrays, strings (7 locals)
#   GateToolTest.debug_matrix_solver(4)  — matrices, floats (7 locals)
#   GateToolTest.debug_large_values()    — stress test: 200×200 matrix, 3000-elem vector, etc.
#
# Agent debug workflow:
#   1. `using GateToolTest` — MUST be a separate eval from the debug call
#   2. `GateToolTest.debug_fibonacci(10)` — triggers @infiltrate, pauses execution
#   3. `debug_ctrl(action="status")` — see file, line, and all local variables
#   4. `debug_eval(expression="a + b")` — evaluate expressions in breakpoint scope
#   5. `debug_ctrl(action="continue")` — resume execution
#
# Other debug tools:
#   - debug_exfiltrate — redefine a function with @exfiltrate to capture locals
#   - debug_safehouse(action="inspect") — view/query captured @exfiltrate variables
#   - debug_safehouse(action="clear") — clear safehouse
#
# Notes:
#   - Assignments persist within a breakpoint session (e.g. `myVar = a + b`)
#   - @exfiltrate works from both agent eval and TUI infil> prompt
#   - If user is actively typing in TUI debug console, agent continue requests
#     require user approval; otherwise they auto-approve
#   - The eval module has `using Infiltrator` so @exfiltrate is available
#   - Results render with text/plain display (matrices show in Julia style)
# ═══════════════════════════════════════════════════════════════════════════════

"""
    debug_fibonacci(n) -> Int

Compute fibonacci with a breakpoint at each step so you can inspect
the accumulator state. Good for testing locals display + stepping through.
"""
function debug_fibonacci(n::Int)
    a, b = 0, 1
    for i in 1:n
        a, b = b, a + b
        if i == n ÷ 2
            # Pause halfway — inspect a, b, i, n
            @infiltrate
        end
    end
    return a
end

"""
    debug_data_pipeline() -> Dict

Simulate a data processing pipeline with multiple stages. Each stage
transforms the data and the breakpoint lets you inspect intermediate state.
"""
function debug_data_pipeline()
    # Stage 1: Generate raw data
    raw_data = [Dict("name" => n, "score" => rand(1:100), "active" => rand(Bool))
                for n in ["Alice", "Bob", "Carol", "Dave", "Eve", "Frank"]]

    # Stage 2: Filter active users
    active = filter(d -> d["active"], raw_data)
    n_filtered = length(raw_data) - length(active)

    # Stage 3: Compute stats
    scores = [d["score"] for d in active]
    mean_score = isempty(scores) ? 0.0 : sum(scores) / length(scores)
    max_score = isempty(scores) ? 0 : maximum(scores)
    top_performer = isempty(active) ? "nobody" : active[argmax(scores)]["name"]

    # Breakpoint — inspect the full pipeline state
    @infiltrate

    # Stage 4: Build summary
    result = Dict(
        "total_users" => length(raw_data),
        "active_users" => length(active),
        "filtered_out" => n_filtered,
        "mean_score" => round(mean_score; digits=1),
        "max_score" => max_score,
        "top_performer" => top_performer,
    )
    return result
end

"""
    debug_matrix_solver(n) -> Matrix{Float64}

Build and "solve" a random linear system. Breakpoints let you inspect
the matrix state at different stages — useful for testing large locals.
"""
function debug_matrix_solver(n::Int)
    # Build a random system Ax = b
    A = randn(n, n)
    b = randn(n)

    # Make it diagonally dominant (so it's well-conditioned)
    for i in 1:n
        A[i, i] = sum(abs.(A[i, :])) + 1.0
    end

    # Decompose
    det_A = det(A)
    cond_A = cond(A)
    x = A \ b
    residual = norm(A * x - b)

    # Breakpoint — inspect A, b, x, residual, det, condition number
    @infiltrate

    return x
end

"""
    debug_large_values()

Stress test for the Debug tab locals display — creates locals with very large
values: a 200×200 matrix, a 3000-element vector, a long string, a deeply
nested dict, and a large tuple. Good for testing scrolling, word wrap, and
truncation in the locals pane.
"""
function debug_large_values()
    big_matrix = randn(200, 200)
    big_vector = collect(1:3000) .* π
    long_string = join(["word$(i)" for i in 1:500], " — ")
    nested_dict = Dict(
        "users" => [
            Dict("name" => "Alice", "scores" => rand(1:100, 20), "meta" => Dict("level" => i, "tags" => ["tag$j" for j in 1:10]))
            for i in 1:15
        ],
        "config" => Dict("nested" => Dict("deep" => Dict("deeper" => Dict("value" => 42)))),
        "counts" => collect(1:100),
    )
    big_tuple = ntuple(i -> (i, i^2, sqrt(Float64(i))), 50)
    sparse_data = Dict(i => randn() for i in rand(1:10000, 200))

    @infiltrate

    return (matrix=big_matrix, vector=big_vector)
end

# Pull in LinearAlgebra for matrix operations
using LinearAlgebra: det, cond, norm

"""
    ZMQ Infrastructure Stress Test

Tests the gate ↔ kaimon streaming channel under load. Specifically exercises:

  - Channel(Inf) non-blocking puts (the 400% CPU / stuck TUI fix)
  - Per-request inbox isolation under concurrent evals
  - Drain cap correctness (no messages lost across multiple drain frames)
  - REQ socket reliability under rapid fire

Prerequisites:
  A Julia session with Gate.serve() active, e.g.:
      julia --project test/GateToolTest.jl/src/GateToolTest.jl -e 'using GateToolTest; GateToolTest.run()'
  OR any Julia REPL that called:
      using Kaimon; Gate.serve()

Usage (in any Julia REPL with Kaimon available):
  include("test/zmq_stress.jl")
  ZMQStress.run()                     # all scenarios
  ZMQStress.run(; verbose=true)       # with per-message progress
  ZMQStress.run(; scenarios=[2,3])    # specific scenarios
  ZMQStress.run(; session="a8e39bd9") # target a specific gate

Background on the bug being tested (Channel(32) → Channel(Inf)):
  drain_stream_messages! holds mgr.lock while routing ZMQ messages to
  per-request inbox channels. When an eval produces heavy stdout, each
  line is broadcast to ALL active inboxes. With Channel{Any}(32), after
  32 lines the inbox fills and put!() *blocks* (it does not throw).
  This stalls drain, holds mgr.lock, and freezes the TUI render loop.
  The fix: Channel{Any}(Inf) — put!() never blocks.
"""
module ZMQStress

import Kaimon

# Internal helpers — not exported from Kaimon but needed for direct stress testing
const _drain  = Kaimon.drain_stream_messages!
const _async  = Kaimon.eval_remote_async
const _sync   = Kaimon.eval_remote
const _taSync = Kaimon._call_session_tool_async  # requires session tools
const _tSync  = Kaimon._call_session_tool        # requires session tools

# ─────────────────────────────────────────────────────────────────────────────
# Result type
# ─────────────────────────────────────────────────────────────────────────────

struct ScenarioResult
    id::Int
    name::String
    passed::Bool
    elapsed_ms::Float64
    notes::String
end

_pass(id, name, t0, notes="") =
    ScenarioResult(id, name, true, (time_ns() - t0) / 1e6, notes)
_fail(id, name, t0, reason) =
    ScenarioResult(id, name, false, (time_ns() - t0) / 1e6, reason)

# ─────────────────────────────────────────────────────────────────────────────
# Connection setup
# ─────────────────────────────────────────────────────────────────────────────

"""
    _acquire(session) -> (mgr, conn, owned_mgr, owned_drain, stop_fn)

Find a ConnectionManager + REPLConnection.

If kaimon's TUI manager (GATE_CONN_MGR) has a live connection, use it directly
(owned_mgr=false, owned_drain=false — the TUI is already draining).

Otherwise, create a fresh ConnectionManager, wait for it to discover sessions,
and start a drain background task at ~60fps. Returns owned_mgr=true, owned_drain=true
so the caller can tear them down after the test.
"""
function _acquire(session)
    # Try the TUI's own manager first
    existing = Kaimon.GATE_CONN_MGR[]
    if existing !== nothing
        conns = Kaimon.connected_sessions(existing)
        conn = if session === nothing
            isempty(conns) ? nothing : conns[1]
        else
            idx = findfirst(
                c -> startswith(c.session_id, session) ||
                     c.name == session || c.display_name == session,
                conns,
            )
            idx !== nothing ? conns[idx] : nothing
        end
        if conn !== nothing
            return (existing, conn, false, false, () -> nothing)
        end
    end

    # No TUI manager — start our own
    sock_dir = joinpath(Kaimon.kaimon_cache_dir(), "sock")
    mgr = Kaimon.ConnectionManager(; sock_dir)
    Kaimon.start!(mgr)

    # Wait up to 4 seconds for the watcher to discover and connect
    deadline = time() + 4.0
    conn = nothing
    while time() < deadline
        conns = Kaimon.connected_sessions(mgr)
        if !isempty(conns)
            conn = (session === nothing) ? conns[1] :
                   let idx = findfirst(
                           c -> startswith(c.session_id, session) ||
                                c.name == session || c.display_name == session,
                           conns,
                       )
                       idx !== nothing ? conns[idx] : nothing
                   end
            conn !== nothing && break
        end
        sleep(0.3)
    end

    if conn === nothing
        Kaimon.stop!(mgr)
        error(
            "No connected gate session found in $(sock_dir). " *
            "Start a gate with Gate.serve() first.",
        )
    end

    # Start our own drain loop (~60fps) since there's no TUI render loop
    stop_flag = Ref(false)
    drain_task = Threads.@spawn begin
        while !stop_flag[]
            try
                _drain(mgr)
            catch
            end
            sleep(0.016)
        end
    end
    stop_fn = () -> begin
        stop_flag[] = true
        try
            wait(drain_task)
        catch
        end
        Kaimon.stop!(mgr)
    end

    return (mgr, conn, true, true, stop_fn)
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Check whether a session has a specific session tool available."""
function _has_tool(conn, tool_name)
    any(t -> get(t, "name", "") == tool_name, conn.session_tools)
end

function _eval_ok(result, expected=nothing)
    hasproperty(result, :exception) && result.exception !== nothing && return false
    expected === nothing && return true
    return contains(string(result.value_repr), expected)
end

const TIMEOUT_MS = 20_000

# ─────────────────────────────────────────────────────────────────────────────
# Scenarios
# ─────────────────────────────────────────────────────────────────────────────

"""
Scenario 1: Basic connectivity.
Simple synchronous eval to confirm the gate is alive before heavier tests.
"""
function _s1(conn)
    t0 = time_ns()
    name = "Basic connectivity (eval 1+1)"
    r = _sync(conn, "1 + 1")
    _eval_ok(r, "2") || return _fail(1, name, t0, "got: $(r.value_repr) exc=$(r.exception)")
    _pass(1, name, t0)
end

"""
Scenario 2: Burst stdout → eval_complete delivery.

The gate runs a tight println loop.  Each printed line is captured by
_eval_with_capture, serialized, and published on the ZMQ PUB socket.
These accumulate in the TUI's SUB buffer until drain_stream_messages!
runs and routes them to the per-request inbox Channel.

Pre-fix (Channel{Any}(32)): after 32 messages the inbox is full and
put!() *blocks*, holding mgr.lock and stalling the render loop.
eval_complete arrives in the ZMQ buffer behind thousands of stdout
lines; the drain is stuck and never routes it → 20-second timeout.

Post-fix (Channel{Any}(Inf)): put!() never blocks; all messages flow
through; eval_complete is delivered in a few seconds.

Pass criterion: completes in under 12 seconds (well inside TIMEOUT_MS).
"""
function _s2(conn; n=5_000)
    t0 = time_ns()
    name = "Burst stdout ($(n) lines) → eval_complete"
    code = """
    for i in 1:$n
        println("burst \$i/$n")
    end
    :burst_done
    """
    r = _async(conn, code; timeout_ms = TIMEOUT_MS)
    !_eval_ok(r, "burst_done") &&
        return _fail(2, name, t0, "exc=$(r.exception) val=$(r.value_repr)")
    ms = (time_ns() - t0) / 1e6
    ms > 12_000 &&
        return _fail(2, name, t0, "completed but suspiciously slow: $(round(ms, digits=0))ms")
    _pass(2, name, t0, "$(n) stdout lines + eval_complete in $(round(ms, digits=0))ms")
end

"""
Scenario 3: Cross-inbox broadcast under concurrent evals.

THE exact bug scenario: two eval_remote_async calls run back-to-back.
eval1 floods stdout; while it runs, eval2 is registered and WAITING.
Because conn.eval_state is EVAL_STREAMING, drain_stream_messages!
broadcasts every stdout line from eval1 to BOTH inboxes — including
eval2's inbox which has nothing to do with that eval.

With Channel{Any}(32): eval2's inbox fills with broadcast stdout →
put!() blocks → drain stalls → eval2_complete is never routed.

With Channel{Any}(Inf): eval2's inbox accepts all broadcast stdout
without blocking; eval2_complete is routed as soon as it arrives.

eval2 does a trivial computation so it completes almost immediately
after the gate finishes eval1.  We verify eval2 completes quickly
once both finish (not timing the gate's sequential eval execution,
which is serialised by GATE_LOCK — just the routing correctness).
"""
function _s3(conn; n=3_000)
    t0 = time_ns()
    name = "Cross-inbox broadcast ($(n)-line flood + concurrent quick eval)"

    # eval1: heavy stdout (gate serialises evals, so this runs first)
    task1 = Threads.@spawn _async(
        conn,
        """for i in 1:$n; println("cross \$i/$n"); end; :flood_done""";
        timeout_ms = TIMEOUT_MS,
    )

    # Brief yield so eval1's inbox is registered first and EVAL_STREAMING is set
    sleep(0.05)

    # eval2: trivial computation registered while eval1 is (or just was) STREAMING.
    # Its inbox now receives broadcast stdout from eval1.
    task2 = Threads.@spawn _async(conn, "21 * 2"; timeout_ms = TIMEOUT_MS)

    r1 = fetch(task1)
    r2 = fetch(task2)

    !_eval_ok(r1, "flood_done") &&
        return _fail(3, name, t0, "eval1 failed: exc=$(r1.exception) val=$(r1.value_repr)")
    !_eval_ok(r2, "42") &&
        return _fail(3, name, t0, "eval2 failed: exc=$(r2.exception) val=$(r2.value_repr)")

    _pass(3, name, t0, "both evals correct despite $(n)-line cross-broadcast")
end

"""
Scenario 4: Drain-cap correctness (no messages lost across multiple frames).

Sends a 1500-line eval.  With the 500-messages-per-drain cap, at least
3 drain cycles are needed to flush everything.  We verify the final
eval_complete is still delivered correctly — the cap must not skip it.

Also verifies eval_complete isn't mistakenly filtered as a "capped" message.
"""
function _s4(conn; n=1_500)
    t0 = time_ns()
    name = "Drain cap ($(n) lines across multiple drain frames)"
    code = """
    for i in 1:$n
        println("cap \$i/$n")
    end
    "cap_result:$n"
    """
    r = _async(conn, code; timeout_ms = TIMEOUT_MS)
    !_eval_ok(r, "cap_result:$n") &&
        return _fail(4, name, t0, "exc=$(r.exception) val=$(r.value_repr)")
    _pass(4, name, t0, "$(n) lines + eval_complete delivered across multiple drain cycles")
end

"""
Scenario 5: REQ socket reliability under rapid fire.

50 back-to-back synchronous eval_remote calls.  Each sends a request and
waits for a response on the REQ socket.  Verifies the socket doesn't
enter a broken state from accumulated use.
"""
function _s5(conn; n=50)
    t0 = time_ns()
    name = "Rapid fire sync evals ($(n)×)"
    failures = 0
    for i in 1:n
        r = _sync(conn, "$(i) * 2")
        _eval_ok(r, string(i * 2)) || (failures += 1)
    end
    failures > 0 && return _fail(5, name, t0, "$(failures)/$(n) evals returned wrong value")
    ms = (time_ns() - t0) / 1e6
    qps = round(Int, n / ms * 1000)
    _pass(5, name, t0, "$(n) evals, ~$(qps) calls/s")
end

"""
Scenario 6 (BONUS): Concurrent tool_call_async inbox isolation.

Requires GateToolTest tools (slow_task).  Fires N slow_task(3) calls
simultaneously; each uses a separate per-request inbox and must receive
exactly its own tool_complete message.  Verifies no cross-contamination.

Skipped automatically if the session doesn't have the slow_task tool.
"""
function _s6(conn; n=5, task_secs=3)
    name = "Concurrent tool_call_async isolation ($(n)× slow_task($(task_secs)s))"
    t0 = time_ns()

    _has_tool(conn, "slow_task") ||
        return ScenarioResult(6, name, true, 0.0, "SKIPPED (no slow_task tool — requires GateToolTest)")

    tasks = [
        Threads.@spawn _taSync(
            conn,
            "slow_task",
            Dict{String,Any}("duration_secs" => task_secs);
            timeout_ms = TIMEOUT_MS,
        ) for _ in 1:n
    ]
    results = [fetch(t) for t in tasks]

    expected = "Completed after $(task_secs)s"
    bad = [r for r in results if !contains(r, expected)]
    !isempty(bad) &&
        return _fail(6, name, t0, "$(length(bad))/$(n) wrong: $(first(bad, 80))")

    elapsed_s = (time_ns() - t0) / 1e9
    elapsed_s > task_secs * 2.5 + 2 &&
        return _fail(6, name, t0, "ran sequentially? $(round(elapsed_s; digits=1))s for $(n) tasks")

    _pass(6, name, t0, "$(n) concurrent inboxes, all correct in $(round(elapsed_s; digits=1))s")
end

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

const _SCENARIO_FNS = [_s1, _s2, _s3, _s4, _s5, _s6]
const _SCENARIO_NAMES = [
    "Basic connectivity",
    "Burst stdout (5k lines)",
    "Cross-inbox broadcast",
    "Drain-cap correctness",
    "Rapid fire sync evals",
    "Concurrent tool_call_async (BONUS)",
]

"""
    ZMQStress.run(; session=nothing, scenarios=1:6, verbose=false)

Run the ZMQ stress test suite.

- `session`:   8-char gate key, name, or `nothing` (auto-detect first connected gate)
- `scenarios`: which scenario IDs to run (default: all)
- `verbose`:   print scenario names before each one starts (default: false)
"""
function run(; session = nothing, scenarios = 1:6, verbose = false)
    println()
    println("╔══════════════════════════════════════════════════════════╗")
    println("║        Kaimon ZMQ Infrastructure Stress Test             ║")
    println("╚══════════════════════════════════════════════════════════╝")

    mgr, conn, owned_mgr, owned_drain, teardown = try
        _acquire(session)
    catch e
        println("\nERROR: ", sprint(showerror, e))
        println("\nStart a gate first:  julia --project -e 'using Kaimon; Gate.serve(force=true)'")
        return nothing
    end

    println(
        "\n  gate:     $(Kaimon.short_key(conn)) ($(conn.display_name))",
    )
    println("  tools:    $(length(conn.session_tools)) session tool(s) available")
    println("  drain:    $(owned_drain ? "standalone (own drain loop)" : "TUI (using render drain)")")
    println("  scenarios: $(collect(scenarios))")
    println()

    results = ScenarioResult[]

    try
        for id in scenarios
            (id < 1 || id > length(_SCENARIO_FNS)) && continue
            fn = _SCENARIO_FNS[id]
            if verbose
                print("  [$(id)/$(length(collect(scenarios)))] $(_SCENARIO_NAMES[id])... ")
                flush(stdout)
            else
                print("  Scenario $(id): ")
                flush(stdout)
            end

            r = try
                fn(conn)
            catch e
                ScenarioResult(id, _SCENARIO_NAMES[id], false, 0.0, sprint(showerror, e))
            end

            push!(results, r)

            if r.notes == "" || !startswith(r.notes, "SKIPPED")
                status = r.passed ? "\033[32m✓\033[0m" : "\033[31m✗ FAILED\033[0m"
                time_str =
                    r.elapsed_ms > 0 ? " ($(round(r.elapsed_ms; digits=0))ms)" : ""
                println("$(status)$(time_str)")
                !r.passed && println("     $(r.notes)")
                verbose && r.passed && !isempty(r.notes) && println("     $(r.notes)")
            else
                println("\033[33m⊘ SKIPPED\033[0m")
            end
        end
    finally
        teardown()
    end

    # Summary
    real = filter(r -> !startswith(r.notes, "SKIPPED"), results)
    n_pass = count(r -> r.passed, real)
    n_total = length(real)
    n_skip = length(results) - n_total

    println()
    println("─"^60)
    if n_pass == n_total
        println("  \033[32m✓ ALL PASSED\033[0m ($n_pass/$n_total$(n_skip > 0 ? ", $(n_skip) skipped" : ""))")
    else
        println("  \033[31m$(n_pass)/$(n_total) passed\033[0m$(n_skip > 0 ? ", $(n_skip) skipped" : "")")
        for r in real
            r.passed || println("    ✗ Scenario $(r.id): $(r.notes)")
        end
    end
    println("─"^60)

    return results
end

end # module ZMQStress

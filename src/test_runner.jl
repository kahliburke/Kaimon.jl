# ── Test Runner ───────────────────────────────────────────────────────────────
# Spawns an ephemeral Julia subprocess to run tests with the correct test
# environment, streams output, and parses it into structured TestRun results.
# Follows the stress_test.jl pattern: script-to-tempfile → spawn → read stdout.

using Dates

# ── Thread-safe TUI buffer for test updates ──────────────────────────────────

const _TUI_TEST_BUFFER = Tuple{Symbol,TestRun}[]  # (:update/:done, run)
const _TUI_TEST_LOCK = ReentrantLock()
const _TEST_RUN_COUNTER = Ref{Int}(0)

"""Push a test run update to the TUI buffer."""
function _push_test_update!(kind::Symbol, run::TestRun)
    lock(_TUI_TEST_LOCK) do
        push!(_TUI_TEST_BUFFER, (kind, run))
    end
end

"""Drain test updates into the model's test_runs vector."""
function _drain_test_updates!(test_runs::Vector{TestRun})
    lock(_TUI_TEST_LOCK) do
        for (kind, run) in _TUI_TEST_BUFFER
            # Find existing run by id
            idx = findfirst(r -> r.id == run.id, test_runs)
            if idx !== nothing
                test_runs[idx] = run
            else
                push!(test_runs, run)
            end
        end
        empty!(_TUI_TEST_BUFFER)
    end
end

# ── Embedded runner script ───────────────────────────────────────────────────
# This script runs in a fresh Julia subprocess. It:
# 1. Activates the test environment correctly
# 2. Runs runtests.jl
# 3. Prints structured status lines to stdout

const _TEST_RUNNER_TEMPLATE = abspath(joinpath(@__DIR__, "..", "templates", "test-runner.jl.tmpl"))

"""Write the test runner script to a temp file. Returns the path.
Reads from the template file each time so edits are picked up without restart."""
function _write_test_runner_script()::String
    path = joinpath(tempdir(), "kaimon_test_runner_$(getpid()).jl")
    write(path, read(_TEST_RUNNER_TEMPLATE, String))
    return path
end

# ── Live-run registry, duration estimation, backgrounding threshold ──────────
#
# A backgrounded run outlives the tool call that started it, so the agent gets a handle
# (the TestRun id) and comes back for the result. These are the process-local runs that a
# handle resolves against; completed runs also land in the analytics DB, but the in-memory
# copy is what still holds the formatted output and failure detail.

const _LIVE_TEST_RUNS = Dict{Int,TestRun}()
const _LIVE_TEST_RUNS_LOCK = ReentrantLock()
const _LIVE_TEST_RUNS_MAX = 32

"""Track a run so `check_tests` can find it by id. Evicts the oldest finished runs."""
function _register_live_run!(run::TestRun)
    lock(_LIVE_TEST_RUNS_LOCK) do
        _LIVE_TEST_RUNS[run.id] = run
        over = length(_LIVE_TEST_RUNS) - _LIVE_TEST_RUNS_MAX
        if over > 0
            finished = sort!([k for (k, r) in _LIVE_TEST_RUNS if r.status != RUN_RUNNING])
            for k in finished[1:min(over, length(finished))]
                delete!(_LIVE_TEST_RUNS, k)
            end
        end
    end
    return run
end

"""The tracked run with this id, or `nothing`."""
get_live_test_run(id::Integer) =
    lock(_LIVE_TEST_RUNS_LOCK) do
        get(_LIVE_TEST_RUNS, Int(id), nothing)
    end

"""Tracked runs still executing, oldest first."""
running_test_runs() =
    lock(_LIVE_TEST_RUNS_LOCK) do
        sort!([r for r in values(_LIVE_TEST_RUNS) if r.status == RUN_RUNNING]; by = r -> r.id)
    end

"""
    find_running_test_run(project_path, pattern, coverage) -> Union{TestRun,Nothing}

An in-flight run of this exact invocation, or `nothing`. Used to hand back an existing run
rather than spawning a duplicate that would just contend for the same cores.
"""
function find_running_test_run(
    project_path::String,
    pattern::String,
    coverage::Bool,
)::Union{TestRun,Nothing}
    for r in running_test_runs()
        r.project_path == project_path && r.pattern == pattern && r.coverage == coverage &&
            return r
    end
    return nothing
end

"""
    test_concurrency() -> Int

Concurrent test runs allowed per project. Env (`KAIMON_TEST_CONCURRENCY`) > persisted
preference > 1.
"""
function test_concurrency()::Int
    v = tryparse(Int, get(ENV, "KAIMON_TEST_CONCURRENCY", ""))
    v === nothing && (v = get_test_concurrency_preference())
    return max(1, v)
end

"""In-flight runs for a project, oldest first."""
project_test_runs(project_path::String) =
    filter(r -> r.project_path == project_path, running_test_runs())

"""
    test_promote_after() -> Float64

Seconds a test run may hold the foreground before it's backgrounded. Resolved as env
(`KAIMON_TEST_PROMOTE_AFTER`) > persisted preference > 30s default; `<= 0` disables
backgrounding entirely, mirroring `_promote_after` for evals.
"""
function test_promote_after()::Float64
    v = tryparse(Float64, get(ENV, "KAIMON_TEST_PROMOTE_AFTER", ""))
    v === nothing && (v = get_test_promote_after_preference())
    return v <= 0 ? Inf : v
end

"""
    estimate_test_duration(project_path, pattern, coverage) -> Union{Float64,Nothing}

Median duration in seconds of recent runs of this exact invocation, or `nothing` when
there's no history for it.

The match is deliberately exact. Falling back to project-wide history would estimate a fast
subset from full-suite runs and background it for no reason, so an unseen pattern counts as
unknown — the caller then runs it in the foreground and promotes on the clock, which records
a duration and makes the next run predictable.

Median rather than mean, so one pathological run (a hang, a cold cache) doesn't skew it.
"""
function estimate_test_duration(
    project_path::String,
    pattern::String,
    coverage::Bool,
)::Union{Float64,Nothing}
    # Estimation is an optimisation, so a DB problem must not fail the test run — but log
    # it rather than swallowing it silently, or a broken query looks like "no history".
    durations = try
        Database.get_test_run_durations(project_path, pattern, coverage)
    catch e
        @debug "Test duration lookup failed" exception = (e, catch_backtrace())
        Float64[]
    end
    isempty(durations) && return nothing
    return _median(durations) / 1000.0
end

"""Median of a non-empty vector (avoids a Statistics dependency for one call)."""
function _median(xs::Vector{Float64})
    s = sort(xs)
    n = length(s)
    return isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2
end

"""Lowercase name for a run status (`passed`, not `RUN_PASSED`) — used in the DB rows and
in anything an agent reads."""
test_status_label(status::TestRunStatus) =
    status == RUN_PASSED ? "passed" :
    status == RUN_FAILED ? "failed" :
    status == RUN_ERROR ? "error" :
    status == RUN_CANCELLED ? "cancelled" : "running"

"""Human-readable duration: `45s`, `2m30s`."""
function format_duration(secs::Real)
    s = max(0, round(Int, secs))
    s < 60 && return "$(s)s"
    m, r = divrem(s, 60)
    return r == 0 ? "$(m)m" : "$(m)m$(r)s"
end

"""
    spawn_test_run(project_path::String; pattern="", verbose=1) -> TestRun

Spawn a Julia subprocess to run tests for the given project.
Returns a TestRun immediately with status=RUN_RUNNING.
A background task reads stdout line-by-line and updates the TestRun.
"""
function spawn_test_run(
    project_path::String;
    pattern::String = "",
    verbose::Int = 1,
    coverage::Bool = false,
)::TestRun
    run_id = lock(_TUI_TEST_LOCK) do
        _TEST_RUN_COUNTER[] += 1
        _TEST_RUN_COUNTER[]
    end

    run = TestRun(;
        id = run_id,
        project_path = project_path,
        pattern = pattern,
        coverage = coverage,
    )
    _register_live_run!(run)

    script_path = _write_test_runner_script()

    # Clean subprocess: no --project (script manages its own env via Pkg.activate),
    # and clear JULIA_LOAD_PATH so the subprocess gets default LOAD_PATH
    # (the Kaimon process sets JULIA_LOAD_PATH which would override everything).
    # setenv replaces the full environment (addenv only merges, so inherited vars leak).
    julia_exe = joinpath(Sys.BINDIR, "julia")
    env = Dict(k => v for (k, v) in ENV)
    delete!(env, "JULIA_LOAD_PATH")
    delete!(env, "JULIA_PROJECT")
    # `--code-coverage=user` makes the subprocess emit <src>.jl.<pid>.cov files for user
    # code on exit (the suite runs in-process via include); _collect_coverage parses and
    # removes them afterward.
    cov_flag = coverage ? `--code-coverage=user` : ``
    cmd = pipeline(
        setenv(`$julia_exe --startup-file=no $cov_flag $script_path $project_path $pattern $verbose`, env);
        stderr = stdout,
    )

    try
        process = open(cmd, "r")
        run.process = process
        run.pid = getpid(process)

        # Background task to read stdout line-by-line
        Threads.@spawn begin
            try
                while !eof(process)
                    line = readline(process; keep = false)
                    isempty(line) && continue

                    parse_test_line!(run, line)

                    # Push to activity feed for real-time visibility
                    project_name = basename(run.project_path)
                    _push_activity!(:test_output, "run_tests", project_name, line)

                    # Push update to TUI buffer
                    _push_test_update!(:update, run)
                end

                # Wait for process to finish
                try
                    wait(process)
                catch
                end

                # If we never got a DONE line from the script, set status from exit code
                if run.status == RUN_RUNNING
                    exit_code = process.exitcode
                    if exit_code == 0
                        run.status = RUN_PASSED
                    else
                        run.status = RUN_FAILED
                    end
                    run.finished_at = now()
                end

                # Parse any remaining failure blocks and summary from raw output
                # (the Test Summary may have been printed but not caught by structured lines)
                _parse_raw_summary!(run)

                # When a run produced results but no headline totals (e.g. a pattern-filtered
                # run with only nested testsets and no depth-0 aggregate), derive totals from
                # the SHALLOWEST results — their counts are cumulative over their children, so
                # summing only those avoids double-counting parent + child.
                if run.total_pass == 0 && run.total_fail == 0 && run.total_error == 0 &&
                   !isempty(run.results)
                    mind = minimum(r.depth for r in run.results)
                    roots = filter(r -> r.depth == mind, run.results)
                    run.total_pass = sum(r.pass_count for r in roots)
                    run.total_fail = sum(r.fail_count for r in roots)
                    run.total_error = sum(r.error_count for r in roots)
                    run.total_tests = sum(r.total_count for r in roots)
                end

            catch e
                if !(e isa EOFError)
                    run.status = RUN_ERROR
                    run.finished_at = now()
                    push!(run.raw_output, "ERROR: $(sprint(showerror, e))")
                end
            finally
                run.reader_done = true
                _push_test_update!(:done, run)
                # Persist to database
                _persist_test_run!(run)
            end
        end

    catch e
        run.status = RUN_ERROR
        run.finished_at = now()
        push!(
            run.raw_output,
            "ERROR: Failed to spawn test process: $(sprint(showerror, e))",
        )
        run.reader_done = true
        _push_test_update!(:done, run)
    end

    return run
end

"""
Parse the raw output for Test Summary if we didn't get structured TESTSET_DONE lines.
This handles the case where tests used standard Test.jl without our instrumentation.
Never throws — failures are silently ignored.
"""
function _parse_raw_summary!(run::TestRun)
    try
        # If we already have structured results, skip
        !isempty(run.results) && return

        # Re-parse all raw output through the parser (idempotent for already-parsed lines)
        temp_run = TestRun(; id = -1, project_path = run.project_path)
        for line in run.raw_output
            parse_test_line!(temp_run, line)
        end

        # Copy parsed results if we found any
        if !isempty(temp_run.results)
            append!(run.results, temp_run.results)
            run.total_pass = max(run.total_pass, temp_run.total_pass)
            run.total_fail = max(run.total_fail, temp_run.total_fail)
            run.total_error = max(run.total_error, temp_run.total_error)
            run.total_tests = max(run.total_tests, temp_run.total_tests)
        end
        if !isempty(temp_run.failures)
            append!(run.failures, temp_run.failures)
        end

        # Clean up temp parser state
        delete!(_PARSER_STATES, -1)
    catch
        # Parsing failed — raw output is still available for display
        delete!(_PARSER_STATES, -1)
    end
end

"""
    _collect_coverage(project_path) -> String

Parse and summarize the `.cov` files produced by `--code-coverage=user`, then delete
them (they otherwise litter `src/`). Scans `src/` of the project under test. Coverage
is computed per source line: a line is *coverable* if its `.cov` field is a number
(`-` marks non-executable lines) and *covered* if any run executed it (count > 0).
Multiple `.cov` files for one source (e.g. TestItemRunner worker processes) are merged
per line by max count. Returns a focused summary (overall % + the least-covered files).
"""
function _collect_coverage(project_path::String)::String
    src_root = isdir(joinpath(project_path, "src")) ? joinpath(project_path, "src") : project_path
    cov_files = String[]
    for (root, _, files) in walkdir(src_root)
        for f in files
            endswith(f, ".cov") && push!(cov_files, joinpath(root, f))
        end
    end
    isempty(cov_files) &&
        return "Coverage: no .cov data was produced (no instrumented src/ code ran)."

    merged = Dict{String,Dict{Int,Int}}()   # source path => (line number => max count)
    for cf in cov_files
        src = replace(replace(cf, r"\.\d+\.cov$" => ""), r"\.cov$" => "")
        d = get!(merged, src, Dict{Int,Int}())
        try
            for (i, ln) in enumerate(eachline(cf))
                m = match(r"^\s*(\d+|-)\s", ln)
                m === nothing && continue
                m.captures[1] == "-" && continue
                n = parse(Int, m.captures[1])
                d[i] = max(get(d, i, 0), n)
            end
        catch
        end
        try; rm(cf); catch; end
    end

    rows = Tuple{String,Int,Int}[]   # (source, covered, coverable)
    total_covered = 0
    total_coverable = 0
    for (src, lines) in merged
        coverable = length(lines)
        covered = count(>(0), values(lines))
        coverable == 0 && continue
        total_covered += covered
        total_coverable += coverable
        push!(rows, (src, covered, coverable))
    end
    total_coverable == 0 && return "Coverage: no executable lines were tracked."

    pct(c, t) = t == 0 ? 0.0 : round(100 * c / t; digits = 1)
    io = IOBuffer()
    println(io, "Coverage: $total_covered/$total_coverable lines ($(pct(total_covered, total_coverable))%)  ",
        "[counts only instrumented lines; Julia may omit uncalled one-liner methods]")
    sort!(rows; by = r -> r[2] / max(1, r[3]))   # least-covered first
    for (src, cov, cab) in first(rows, 15)
        rel = try; relpath(src, project_path); catch; src; end
        println(io, "  $rel: $cov/$cab ($(pct(cov, cab))%)")
    end
    length(rows) > 15 && println(io, "  … ($(length(rows) - 15) more files)")
    return String(take!(io))
end

"""Cancel a running test by killing the subprocess."""
function cancel_test_run!(run::TestRun)
    if run.status == RUN_RUNNING && run.process !== nothing
        try
            kill(run.process)
        catch
        end
        run.status = RUN_CANCELLED
        run.finished_at = now()
        _push_test_update!(:done, run)
    end
end

"""Persist a completed test run to the database (delegates the atomic write to
`Database.record_test_run!`; this just maps the `TestRun` into plain row data)."""
function _persist_test_run!(run::TestRun)
    fmt(t) = Dates.format(t, dateformat"yyyy-mm-dd HH:MM:SS")
    duration_ms = run.finished_at !== nothing ?
        Float64(Dates.value(run.finished_at - run.started_at)) : 0.0
    status_str = test_status_label(run.status)
    summary = format_test_summary(run)
    summary_short = String(first(summary, 500))

    try
        Database.record_test_run!(
            (project_path = run.project_path,
             started_at = fmt(run.started_at),
             finished_at = run.finished_at !== nothing ? fmt(run.finished_at) : nothing,
             status = status_str, pattern = run.pattern,
             total_pass = run.total_pass, total_fail = run.total_fail,
             total_error = run.total_error, total_tests = run.total_tests,
             duration_ms = duration_ms, summary = summary_short, coverage = run.coverage),
            [(name = r.name, depth = r.depth, pass_count = r.pass_count, fail_count = r.fail_count,
              error_count = r.error_count, total_count = r.total_count) for r in run.results],
            [(file = f.file, line = f.line, expression = f.expression, evaluated = f.evaluated,
              testset = f.testset, backtrace = f.backtrace) for f in run.failures],
        )
    catch e
        @debug "Failed to persist test run" exception = (e, catch_backtrace())
    end
end

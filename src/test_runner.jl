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

    run = TestRun(; id = run_id, project_path = project_path, pattern = pattern)

    script_path = _write_test_runner_script()

    # Clean subprocess: no --project (script manages its own env via Pkg.activate),
    # and clear JULIA_LOAD_PATH so the subprocess gets default LOAD_PATH
    # (the Kaimon process sets JULIA_LOAD_PATH which would override everything).
    # setenv replaces the full environment (addenv only merges, so inherited vars leak).
    julia_exe = joinpath(Sys.BINDIR, "julia")
    env = Dict(k => v for (k, v) in ENV)
    delete!(env, "JULIA_LOAD_PATH")
    delete!(env, "JULIA_PROJECT")
    # `--code-coverage=user` makes the subprocess emit <src>.jl.<pid>.cov files for
    # user code on exit; _collect_coverage parses and removes them afterward.
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

                # When pattern-filtered runs produce only nested testsets (depth > 0),
                # the summary parser never populates total_pass. Derive from results.
                if run.total_pass == 0 && run.total_fail == 0 && !isempty(run.results)
                    run.total_pass = sum(r.pass_count for r in run.results)
                    run.total_fail = sum(r.fail_count for r in run.results)
                    run.total_error = sum(r.error_count for r in run.results)
                    run.total_tests = sum(r.total_count for r in run.results)
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
    status_str =
        run.status == RUN_PASSED ? "passed" :
        run.status == RUN_FAILED ? "failed" :
        run.status == RUN_ERROR ? "error" :
        run.status == RUN_CANCELLED ? "cancelled" : "running"
    summary = format_test_summary(run)
    summary_short = length(summary) > 500 ? summary[1:500] : summary

    try
        Database.record_test_run!(
            (project_path = run.project_path,
             started_at = fmt(run.started_at),
             finished_at = run.finished_at !== nothing ? fmt(run.finished_at) : nothing,
             status = status_str, pattern = run.pattern,
             total_pass = run.total_pass, total_fail = run.total_fail,
             total_error = run.total_error, total_tests = run.total_tests,
             duration_ms = duration_ms, summary = summary_short),
            [(name = r.name, depth = r.depth, pass_count = r.pass_count, fail_count = r.fail_count,
              error_count = r.error_count, total_count = r.total_count) for r in run.results],
            [(file = f.file, line = f.line, expression = f.expression, evaluated = f.evaluated,
              testset = f.testset, backtrace = f.backtrace) for f in run.failures],
        )
    catch e
        @debug "Failed to persist test run" exception = (e, catch_backtrace())
    end
end

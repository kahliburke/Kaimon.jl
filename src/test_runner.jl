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
    cmd = pipeline(
        setenv(`$julia_exe --startup-file=no $script_path $project_path $pattern $verbose`, env);
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

"""Persist a completed test run to the database."""
function _persist_test_run!(run::TestRun)
    db = Database.DB[]
    db === nothing && return
    try
        duration_ms = if run.finished_at !== nothing
            Float64(Dates.value(run.finished_at - run.started_at))
        else
            0.0
        end

        status_str = if run.status == RUN_PASSED
            "passed"
        elseif run.status == RUN_FAILED
            "failed"
        elseif run.status == RUN_ERROR
            "error"
        elseif run.status == RUN_CANCELLED
            "cancelled"
        else
            "running"
        end

        summary = format_test_summary(run)
        summary_short = length(summary) > 500 ? summary[1:500] : summary

        Database.DBInterface.execute(
            db,
            """
            INSERT INTO test_runs (
                project_path, started_at, finished_at, status,
                pattern, total_pass, total_fail, total_error,
                total_tests, duration_ms, summary
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                run.project_path,
                Dates.format(run.started_at, dateformat"yyyy-mm-dd HH:MM:SS"),
                run.finished_at !== nothing ?
                Dates.format(run.finished_at, dateformat"yyyy-mm-dd HH:MM:SS") : nothing,
                status_str,
                run.pattern,
                run.total_pass,
                run.total_fail,
                run.total_error,
                run.total_tests,
                duration_ms,
                summary_short,
            ),
        )

        # Get the auto-generated row ID
        result =
            Database.DBInterface.execute(db, "SELECT last_insert_rowid()") |>
            Database.DataFrame
        db_id = result[1, 1]

        # Persist individual test results
        for r in run.results
            Database.DBInterface.execute(
                db,
                """
                INSERT INTO test_results (run_id, testset_name, depth, pass_count, fail_count, error_count, total_count)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    db_id,
                    r.name,
                    r.depth,
                    r.pass_count,
                    r.fail_count,
                    r.error_count,
                    r.total_count,
                ),
            )
        end

        # Persist failures
        for f in run.failures
            Database.DBInterface.execute(
                db,
                """
                INSERT INTO test_failures (run_id, file, line, expression, evaluated, testset_name, backtrace)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (db_id, f.file, f.line, f.expression, f.evaluated, f.testset, f.backtrace),
            )
        end
    catch e
        @debug "Failed to persist test run" exception = (e, catch_backtrace())
    end
end

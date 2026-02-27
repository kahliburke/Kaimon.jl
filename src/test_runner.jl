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

_test_runner_script() = """
# Test runner subprocess script — prints structured output for parser
import Pkg
import TOML

project_path = ARGS[1]
pattern = length(ARGS) >= 2 ? ARGS[2] : ""
verbose_level = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 1

println("TEST_RUNNER: START project=\$(basename(project_path))")
flush(stdout)

# ── Activate test environment ─────────────────────────────────────────────
test_project = joinpath(project_path, "test", "Project.toml")

if isfile(test_project)
    # Test has its own Project.toml — activate the test env
    Pkg.activate(joinpath(project_path, "test"))
    try
        Pkg.instantiate(; io=devnull)
    catch e
        println("TEST_RUNNER: WARN instantiate_failed message=\$(first(sprint(showerror, e), 120))")
    end
    # Ensure the main project is importable from the test env
    try
        Pkg.develop(Pkg.PackageSpec(path=project_path); io=devnull)
    catch
    end
else
    # No test/Project.toml — build a temp environment with [extras] deps.
    # This replicates what Pkg.test() does, but lets us include() directly
    # so we get verbose output and full control.
    main_toml = TOML.parsefile(joinpath(project_path, "Project.toml"))
    extras = get(main_toml, "extras", Dict())
    targets = get(main_toml, "targets", Dict())
    test_deps = get(targets, "test", String[])

    # Create temp project with main deps + test extras
    tmp = mktempdir()
    Pkg.activate(tmp)
    try
        Pkg.develop(Pkg.PackageSpec(path=project_path); io=devnull)
    catch
    end
    # Add test-only deps from [extras]
    for dep_name in test_deps
        if haskey(extras, dep_name)
            try
                Pkg.add(Pkg.PackageSpec(name=dep_name, uuid=extras[dep_name]); io=devnull)
            catch
                try
                    Pkg.add(dep_name; io=devnull)
                catch e
                    println("TEST_RUNNER: WARN add_dep_failed dep=\$dep_name message=\$(first(sprint(showerror, e), 120))")
                end
            end
        end
    end
    try
        Pkg.instantiate(; io=devnull)
    catch
    end
end

# Stack the main project env on LOAD_PATH so all its deps (including dev'd
# packages like Tachikoma) are directly importable from tests.
if !(project_path in LOAD_PATH)
    push!(LOAD_PATH, project_path)
end

flush(stdout)

# ── Patch Test.jl for verbose output + structured result emission ─────────
# 1. Force verbose=true so the final summary table shows nested testsets
# 2. Emit TEST_RUNNER: TESTSET_DONE lines as each testset finishes, giving
#    the TUI real-time incremental results with hierarchy depth info.
# Use `import` (not `using`) to avoid exporting @testset into Main, which
# conflicts with ReTest's @testset in test files.
import Test

_testset_depth = Ref(0)

let _w = Base.get_world_counter()
    @eval function Test.push_testset(ts::Test.DefaultTestSet)
        ts.verbose = true
        \$_testset_depth[] += 1
        return Base.invoke_in_world(\$_w, Test.push_testset, ts)
    end
end

# Patch finish to emit structured TESTSET_DONE as each testset completes.
# Emitted BEFORE calling original finish (which may throw TestSetException).
let _w2 = Base.get_world_counter()
    @eval function Test.finish(ts::Test.DefaultTestSet; print_results::Bool=true)
        _depth = max(0, \$_testset_depth[] - 1)
        \$_testset_depth[] -= 1

        # Compute cumulative counts via get_test_counts.
        # Julia 1.12+ returns a TestCounts struct; older returns an 8-tuple.
        _tc = Test.get_test_counts(ts)
        _p = getproperty(_tc, :passes) + getproperty(_tc, :cumulative_passes)
        _f = getproperty(_tc, :fails) + getproperty(_tc, :cumulative_fails)
        _e = getproperty(_tc, :errors) + getproperty(_tc, :cumulative_errors)
        _total = _p + _f + _e

        # Emit structured line (name= last to allow spaces in testset names)
        _msg = string(
            "TEST_RUNNER: TESTSET_DONE pass=", _p,
            " fail=", _f, " error=", _e,
            " total=", _total, " depth=", _depth,
            " name=", ts.description)
        println(_msg)
        flush(stdout)

        return Base.invoke_in_world(\$_w2, Test.finish, ts; print_results=print_results)
    end
end

# ── Run the tests ─────────────────────────────────────────────────────────
runtests_path = joinpath(project_path, "test", "runtests.jl")
exit_code = 0

try
    cd(project_path)

    # Check for ReTest
    has_retest = false
    for toml_path in [test_project, joinpath(project_path, "Project.toml")]
        isfile(toml_path) || continue
        try
            toml = TOML.parsefile(toml_path)
            for key in ("deps", "extras")
                haskey(get(toml, key, Dict()), "ReTest") && (has_retest = true)
            end
        catch
        end
    end

    # Run standard tests
    include(runtests_path)

    # If project has ReTest, discover and run ReTest suites
    if has_retest
        @eval using ReTest

        retest_files = String[]
        test_dir = joinpath(project_path, "test")
        for f in readdir(test_dir)
            endswith(f, ".jl") || continue
            f == "runtests.jl" && continue
            fpath = joinpath(test_dir, f)
            try
                content = read(fpath, String)
                if occursin("using ReTest", content)
                    push!(retest_files, fpath)
                end
            catch
            end
        end

        if !isempty(retest_files)
            println("TEST_RUNNER: RETEST_SUITES found=\$(length(retest_files))")
            flush(stdout)
            for fpath in retest_files
                println("TEST_RUNNER: RETEST_INCLUDE file=\$(basename(fpath))")
                flush(stdout)
                include(fpath)
            end
            if !isempty(pattern)
                @eval retest(r"\$(pattern)", verbose=\$(verbose_level))
            else
                @eval retest(verbose=\$(verbose_level))
            end
        end
    end

    println("TEST_RUNNER: DONE status=passed")
catch e
    global exit_code = 1
    # Test failures throw TestSetException (possibly wrapped in LoadError from include).
    # These are expected — we already emitted TESTSET_DONE lines for each testset.
    _is_test_failure = e isa Test.TestSetException
    if e isa LoadError
        _is_test_failure = e.error isa Test.TestSetException
    end
    if !_is_test_failure
        println("TEST_RUNNER: ERROR \$(first(sprint(showerror, e), 500))")
        bt = catch_backtrace()
        println(stderr, sprint(showerror, e, bt))
    end
    println("TEST_RUNNER: DONE status=failed")
end

flush(stdout)
flush(stderr)
exit(exit_code)
"""

"""Write the test runner script to a temp file. Returns the path."""
function _write_test_runner_script()::String
    path = joinpath(tempdir(), "kaimon_test_runner_$(getpid()).jl")
    write(path, _test_runner_script())
    return path
end

"""
    spawn_test_run(project_path::String; pattern="", verbose=1, on_progress=nothing) -> TestRun

Spawn a Julia subprocess to run tests for the given project.
Returns a TestRun immediately with status=RUN_RUNNING.
A background task reads stdout line-by-line and updates the TestRun.

The `on_progress` callback receives `(message::String)` for inflight updates.
"""
function spawn_test_run(
    project_path::String;
    pattern::String = "",
    verbose::Int = 1,
    on_progress::Union{Function,Nothing} = nothing,
)::TestRun
    run_id = lock(_TUI_TEST_LOCK) do
        _TEST_RUN_COUNTER[] += 1
        _TEST_RUN_COUNTER[]
    end

    run = TestRun(; id = run_id, project_path = project_path, pattern = pattern)

    script_path = _write_test_runner_script()

    # Use --project for the main project (the script handles test env activation)
    # Merge stderr into stdout so error messages are captured by the line reader
    cmd = pipeline(
        `$(Base.julia_cmd()) --startup-file=no --project=$project_path $script_path $project_path $pattern $verbose`;
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

                    meaningful = parse_test_line!(run, line)

                    # Push to activity feed for real-time visibility
                    project_name = basename(run.project_path)
                    _push_activity!(:test_output, "run_tests", project_name, line)

                    # Push progress update
                    if on_progress !== nothing
                        if meaningful
                            on_progress(
                                "$(run.total_pass) passed, $(run.total_fail) failed ($(length(run.raw_output)) lines)",
                            )
                        end
                    end

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

            catch e
                if !(e isa EOFError)
                    run.status = RUN_ERROR
                    run.finished_at = now()
                    push!(run.raw_output, "ERROR: $(sprint(showerror, e))")
                end
            finally
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

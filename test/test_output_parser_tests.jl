using ReTest
using Kaimon:
    TestRun,
    TestResult,
    TestFailure,
    TestStatus,
    TestRunStatus,
    TEST_PASS,
    TEST_FAIL,
    TEST_ERROR,
    TEST_BROKEN,
    TEST_SKIP,
    RUN_RUNNING,
    RUN_PASSED,
    RUN_FAILED,
    RUN_ERROR,
    RUN_CANCELLED,
    parse_test_line!,
    format_test_summary,
    _PARSER_STATES

@testset "Test Output Parser" begin

    @testset "Basic failure detection" begin
        run = TestRun(; id = 100, project_path = "/tmp/test_project")

        # Simulate a Test.jl failure block
        parse_test_line!(run, "Test Failed at /tmp/test_project/test/runtests.jl:42")
        parse_test_line!(run, "  Expression: x == 2")
        parse_test_line!(run, "  Evaluated: 1 == 2")
        # Trigger flush by sending a non-failure line
        parse_test_line!(run, "")

        @test length(run.failures) == 1
        f = run.failures[1]
        @test f.file == "/tmp/test_project/test/runtests.jl"
        @test f.line == 42
        @test f.expression == "x == 2"
        @test f.evaluated == "1 == 2"

        # Clean up parser state
        delete!(_PARSER_STATES, 100)
    end

    @testset "Error during test surfaces the real exception" begin
        run = TestRun(; id = 101, project_path = "/tmp/test_project")

        # A real Test.jl "Error During Test" block: the actual exception type+message
        # sits between "Expression:" and "Stacktrace:" and must be captured — NOT replaced
        # with a generic "Error during test" placeholder.
        parse_test_line!(run, "Error During Test at /tmp/test_project/test/runtests.jl:55")
        parse_test_line!(run, "  Test threw exception")
        parse_test_line!(run, "  Expression: foo(x)")
        parse_test_line!(run, "  UndefVarError: `bar` not defined in `Main`")
        parse_test_line!(run, "  The binding may be too new.")
        parse_test_line!(run, "  Stacktrace:")
        parse_test_line!(run, "   [1] foo(x) @ Main ./file.jl:1")
        parse_test_line!(run, "")

        @test length(run.failures) == 1
        f = run.failures[1]
        @test f.file == "/tmp/test_project/test/runtests.jl"
        @test f.line == 55
        @test f.expression == "foo(x)"                 # the real Expression line, not a placeholder
        @test f.expression != "Error during test"      # the old generic message is gone
        @test occursin("UndefVarError: `bar` not defined", f.exception)
        @test occursin("binding may be too new", f.exception)  # continuation lines captured too
        @test !occursin("Stacktrace", f.exception)      # stops before the backtrace

        # format_test_summary must surface the captured exception.
        run.status = RUN_FAILED
        summary = format_test_summary(run)
        @test occursin("UndefVarError: `bar` not defined", summary)

        delete!(_PARSER_STATES, 101)
    end

    @testset "ReTest blank-middle column + multi-module totals (regression)" begin
        # ReTest omits ZERO columns anywhere — a row with Pass+Total but a blank Error
        # column used to be mis-read (the Pass count counted as Error → phantom errors).
        # And totals only summed depth-0 rows, but ReTest prints a depth-0 aggregate for
        # SOME modules and not others within one run, so an entire module (and its error)
        # was dropped → headline "Error: 0" on a genuinely erroring run. Right-edge column
        # mapping + per-block (per-module) shallowest-row totals fix both. Fixture verified
        # against the real KaimonSlate ReTest output.
        run = TestRun(; id = 112, project_path = "/tmp/test_project")
        for line in [
            "            Pass",                  # module A header (clean: Pass only)
            "Main.A:",
            "  a1      |    10",                 # depth 1
            "Main.A    |    10",                 # depth-0 aggregate present for A
            "            Pass   Error   Total",  # module B header (has Error column)
            "Main.B:",
            "  outer   |    20       1      21", # depth 1 — B's root (no depth-0 aggregate)
            "    blank |     5               5", # depth 2, BLANK Error column → must be 0, not 5
            "    errd  |     0       1       1", # depth 2, the one real error
        ]
            parse_test_line!(run, line)
        end

        # The blank-Error row is a pass, not a phantom error.
        ib = findfirst(r -> r.name == "blank", run.results)
        @test ib !== nothing
        @test run.results[ib].pass_count == 5
        @test run.results[ib].error_count == 0

        # Totals: A's depth-0 aggregate (10) + B's shallowest row "outer" (20 pass, 1 error,
        # cumulative over its children) — never double-counting parent + children.
        @test run.total_pass == 30
        @test run.total_error == 1
        @test run.total_fail == 0
        @test run.total_tests == 31

        delete!(_PARSER_STATES, 112)
    end

    @testset "Test Summary table parsing" begin
        run = TestRun(; id = 102, project_path = "/tmp/test_project")

        # Simulate a typical Test.jl summary (top-level has no indent)
        lines = [
            "Test Summary: | Pass  Fail  Error  Total",
            "My Tests      |   10     2      1     13",
            "  SubTest A   |    5     1      0      6",
            "  SubTest B   |    5     1      1      7",
            "",
        ]
        for line in lines
            parse_test_line!(run, line)
        end

        @test length(run.results) >= 1
        # Top-level result (no indent = depth 0)
        top = run.results[1]
        @test top.name == "My Tests"
        @test top.pass_count == 10
        @test top.fail_count == 2
        @test top.error_count == 1
        @test top.total_count == 13
        @test top.status == TEST_FAIL

        # Subtests at depth 1
        @test length(run.results) >= 2
        @test run.results[2].name == "SubTest A"
        @test run.results[2].depth == 1

        # Totals should be from depth=0
        @test run.total_pass == 10
        @test run.total_fail == 2

        delete!(_PARSER_STATES, 102)
    end

    @testset "Structured runner lines" begin
        run = TestRun(; id = 103, project_path = "/tmp/test_project")

        parse_test_line!(run, "TEST_RUNNER: START project=test_project")
        @test run.status == RUN_RUNNING

        parse_test_line!(
            run,
            "TEST_RUNNER: TESTSET_DONE pass=5 fail=0 error=0 total=5 depth=0 name=Core",
        )
        @test length(run.results) == 1
        @test run.results[1].name == "Core"
        @test run.results[1].pass_count == 5
        @test run.total_pass == 5

        parse_test_line!(
            run,
            "TEST_RUNNER: TESTSET_DONE pass=3 fail=1 error=0 total=4 depth=0 name=Utils",
        )
        @test length(run.results) == 2
        @test run.total_pass == 8
        @test run.total_fail == 1

        parse_test_line!(run, "TEST_RUNNER: DONE status=failed")
        @test run.status == RUN_FAILED
        @test run.finished_at !== nothing

        # Parser state should be cleaned up
        @test !haskey(_PARSER_STATES, 103)
    end

    @testset "format_test_summary" begin
        run = TestRun(; id = 104, project_path = "/tmp/my_project")
        run.status = RUN_FAILED
        run.finished_at = run.started_at + Dates.Millisecond(2500)
        run.total_pass = 10
        run.total_fail = 2
        run.total_error = 0
        run.total_tests = 12

        push!(run.results, TestResult("Core", TEST_PASS, 8, 0, 0, 8, 0))
        push!(run.results, TestResult("Utils", TEST_FAIL, 2, 2, 0, 4, 0))

        push!(
            run.failures,
            TestFailure("test/utils_test.jl", 42, "x == 2", "1 == 2", "Utils", ""),
        )

        summary = format_test_summary(run)
        @test contains(summary, "FAILED")
        @test contains(summary, "my_project")
        @test contains(summary, "Pass: 10")
        @test contains(summary, "Fail: 2")
        @test contains(summary, "utils_test.jl:42")
        @test contains(summary, "x == 2")

        delete!(_PARSER_STATES, 104)
    end

    @testset "Multiple failures" begin
        run = TestRun(; id = 105, project_path = "/tmp/test_project")

        # First failure
        parse_test_line!(run, "Test Failed at /tmp/a.jl:10")
        parse_test_line!(run, "  Expression: a == b")
        parse_test_line!(run, "  Evaluated: 1 == 2")

        # Second failure (flush first by starting a new one)
        parse_test_line!(run, "Test Failed at /tmp/b.jl:20")
        parse_test_line!(run, "  Expression: c == d")
        parse_test_line!(run, "  Evaluated: 3 == 4")

        # Flush second
        parse_test_line!(run, "")

        @test length(run.failures) == 2
        @test run.failures[1].file == "/tmp/a.jl"
        @test run.failures[1].line == 10
        @test run.failures[2].file == "/tmp/b.jl"
        @test run.failures[2].line == 20

        delete!(_PARSER_STATES, 105)
    end

    @testset "Raw output is always captured" begin
        run = TestRun(; id = 106, project_path = "/tmp/test_project")

        parse_test_line!(run, "some random output")
        parse_test_line!(run, "another line")
        parse_test_line!(run, "Test Failed at /tmp/x.jl:1")

        @test length(run.raw_output) == 3
        @test run.raw_output[1] == "some random output"

        delete!(_PARSER_STATES, 106)
    end

    @testset "Error recovery — parser never throws" begin
        run = TestRun(; id = 107, project_path = "/tmp/test_project")

        # Feed lines that might trip up parsing — none should throw
        weird_lines = [
            "",
            "  ",
            "|||||",
            "Test Summary: |",
            "| just pipes |",
            "Test Failed at",               # malformed — no :line
            "Test Failed at :notanumber",    # malformed line number
            "Error During Test at",          # malformed
            "TEST_RUNNER: GARBAGE garbage=",
            "\xff\xfe invalid utf-ish",
            "a"^10000,                     # very long line
        ]

        for line in weird_lines
            # Should never throw
            result = parse_test_line!(run, line)
            @test result isa Bool
        end

        # Raw output should still have everything
        @test length(run.raw_output) == length(weird_lines)

        delete!(_PARSER_STATES, 107)
    end

    @testset "format_test_summary falls back to raw output" begin
        run = TestRun(; id = 108, project_path = "/tmp/my_project")
        run.status = RUN_FAILED
        run.finished_at = run.started_at + Dates.Millisecond(1000)
        # No structured results or failures — just raw output
        push!(run.raw_output, "Loading project...")
        push!(run.raw_output, "ERROR: SomeError()")
        push!(run.raw_output, "Stacktrace:")
        push!(run.raw_output, "  [1] runtests.jl:42")

        summary = format_test_summary(run)
        @test contains(summary, "FAILED")
        @test contains(summary, "Output (last")
        @test contains(summary, "SomeError")

        delete!(_PARSER_STATES, 108)
    end

    @testset "ReTest multi-table failing summary (regression)" begin
        # Ground truth captured from a failing `retest(ARGS...)` run (see
        # /tmp/TestFrameworkLab lab). ReTest emits a bare column header that VARIES
        # per testset (just "Pass" for a clean block, "Pass Fail Total" once a block
        # fails) and prints the failure detail BETWEEN the per-testset rows and the
        # final "Main…|" grand-total row. The parser used to exit summary mode on the
        # second header and on the blank lines, dropping the failing rows and the
        # authoritative aggregate → headline "Fail: 0" on a genuinely failing run.
        run = TestRun(; id = 109, project_path = "/tmp/test_project")
        for line in [
            "            Pass  ",
            "Main:  ",
            "  alpha |      1  ",
            "            Pass    Fail   Total",
            "  beta  |              1       1",
            "",
            "beta: Test Failed at /tmp/test_project/test/runtests.jl:7",
            "  Expression: mul2(2, 3) == 999",
            "   Evaluated: 6 == 999",
            "",
            "",
            "Main    |      1       1       2",
        ]
            parse_test_line!(run, line)
        end

        # Totals come from the depth-0 "Main" aggregate, not the indented per-set rows.
        @test run.total_pass == 1
        @test run.total_fail == 1
        @test run.total_tests == 2
        # The interleaved failure block is still captured.
        @test length(run.failures) == 1
        @test run.failures[1].expression == "mul2(2, 3) == 999"
        @test run.failures[1].evaluated == "6 == 999"

        # The failing per-testset row has a BLANK Pass column (0 passes); numbers must
        # right-align so Fail isn't mis-read as Pass.
        beta = findfirst(r -> r.name == "beta", run.results)
        @test beta !== nothing
        @test run.results[beta].pass_count == 0
        @test run.results[beta].fail_count == 1

        delete!(_PARSER_STATES, 109)
    end

    @testset "ReTest pattern-filtered single testset with interrupting noise" begin
        # A pattern-filtered ReTest run shows only a nested testset (no depth-0
        # aggregate), and stdout from the test itself (e.g. a Pkg.activate) can break
        # the summary block. The indented row must still be parsed so the runner's
        # results-fallback can total it; previously it was dropped → "Pass: 0".
        run = TestRun(; id = 111, project_path = "/tmp/test_project")
        for line in [
            "                      Pass  ",
            "Main.MyTests:",
            "  Activating new project at `/tmp/whatever`",
            "  Filtered Set     |     13  ",
        ]
            parse_test_line!(run, line)
        end
        i = findfirst(r -> r.name == "Filtered Set", run.results)
        @test i !== nothing
        @test run.results[i].pass_count == 13

        delete!(_PARSER_STATES, 111)
    end

    @testset "ReTest passing summary still parses (no regression)" begin
        run = TestRun(; id = 110, project_path = "/tmp/test_project")
        for line in [
            "            Pass  ",
            "Main:  ",
            "  alpha |      2  ",
            "  beta  |      2  ",
            "Main    |      4  ",
        ]
            parse_test_line!(run, line)
        end
        @test run.total_pass == 4
        @test run.total_fail == 0
        @test run.total_tests == 4

        delete!(_PARSER_STATES, 110)
    end
end

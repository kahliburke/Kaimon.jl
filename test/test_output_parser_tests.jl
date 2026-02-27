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

    @testset "Error during test detection" begin
        run = TestRun(; id = 101, project_path = "/tmp/test_project")

        parse_test_line!(run, "Error During Test at /tmp/test_project/test/runtests.jl:55")
        parse_test_line!(run, "  some error details")
        parse_test_line!(run, "")

        @test length(run.failures) == 1
        f = run.failures[1]
        @test f.file == "/tmp/test_project/test/runtests.jl"
        @test f.line == 55
        @test f.expression == "Error during test"

        delete!(_PARSER_STATES, 101)
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
        @test contains(summary, "Raw output")
        @test contains(summary, "SomeError")

        delete!(_PARSER_STATES, 108)
    end
end

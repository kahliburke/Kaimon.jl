using ReTest
using Kaimon

@testset "Test Runner" begin
    @testset "pattern filters ReTest suites" begin
        # Skip in CI — this spawns a sub-subprocess that needs a fully resolved
        # Manifest and clean env. Inside Pkg.test() the nested spawn is unreliable.
        if get(ENV, "CI", "") == "true"
            @test_skip "spawn_test_run integration test (skipped in CI)"
        else
            project_path = pkgdir(Kaimon)
            run = Kaimon.spawn_test_run(project_path; pattern = "Version Info Tests", verbose = 1)

            deadline = time() + 90.0
            while (!run.reader_done || run.status == Kaimon.RUN_RUNNING) && time() < deadline
                sleep(0.25)
            end

            @test run.status == Kaimon.RUN_PASSED
            @test run.total_pass > 0
            @test run.total_fail == 0
            @test any(r -> r.name == "Version Info Tests", run.results)
        end
    end

    @testset "_pattern_likely_honored detects ARGS forwarding" begin
        # The pattern reaches tests via ARGS, so only a runtests.jl that reads ARGS
        # (ReTest's retest(ARGS...)) can honor it; otherwise run_tests warns.
        dir = mktempdir()
        mkpath(joinpath(dir, "test"))
        rt = joinpath(dir, "test", "runtests.jl")

        write(rt, "using Test\n@testset \"a\" begin; @test true; end\n")
        @test Kaimon._pattern_likely_honored(dir) == false          # plain Test.jl

        write(rt, "using ReTest\n@testset \"a\" begin; @test true; end\nretest(ARGS...)\n")
        @test Kaimon._pattern_likely_honored(dir) == true           # forwards ARGS

        write(rt, "using SafeTestsets\n@safetestset \"a\" begin; @test true; end\n")
        @test Kaimon._pattern_likely_honored(dir) == false          # SafeTestsets

        write(rt, "using TestItemRunner\n@run_package_tests\n")
        @test Kaimon._pattern_likely_honored(dir) == false          # TestItemRunner

        # No runtests.jl at all → not honored.
        @test Kaimon._pattern_likely_honored(mktempdir()) == false
    end

    @testset "_collect_coverage parses and summarizes .cov files" begin
        dir = mktempdir()
        src = joinpath(dir, "src")
        mkpath(src)
        # Synthetic .cov: '-' = non-executable, a number = coverable (covered if >0).
        write(joinpath(src, "Foo.jl.12345.cov"), """
                - module Foo
                5 foo() = 1
                0 bar() = 2
                - end
        """)
        summary = Kaimon._collect_coverage(dir)
        @test occursin("1/2 lines (50.0%)", summary)
        @test occursin("src/Foo.jl", summary)
        # .cov files are cleaned up after collection.
        @test isempty(filter(f -> endswith(f, ".cov"), readdir(src)))

        # No .cov data → clear message, no crash.
        @test occursin("no .cov data", Kaimon._collect_coverage(mktempdir()))
    end
end

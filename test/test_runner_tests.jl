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

    @testset "_launch_julia_exe resolves the binary sessions and test runs share" begin
        K = Kaimon
        # Unset → the Julia running Kaimon.
        @test K._launch_julia_exe(K.LaunchConfig()) == joinpath(Sys.BINDIR, "julia")
        # Configured → that binary (or a wrapper script forwarding its arguments).
        @test K._launch_julia_exe(K.LaunchConfig("", "", "", String[], "", "/opt/jl/run", false)) ==
              "/opt/jl/run"
        @test K._launch_julia_exe(K.LaunchConfig("", "", "", String[], "", "~/jl/run", false)) ==
              joinpath(homedir(), "jl", "run")
    end

    # These spawn a sub-subprocess, which is unreliable inside Pkg.test — same reason the
    # integration test above is CI-skipped.
    ci = get(ENV, "CI", "") == "true"

    # FixedPointNumbers is a small registered package with several releases, so a compat bound
    # can be moved off the version a manifest already recorded.
    _set_compat(dir, compat) = write(joinpath(dir, "test", "Project.toml"), """
    [deps]
    FixedPointNumbers = "53c48c17-4a7d-5ca2-90c5-79b7896eea93"
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

    [compat]
    FixedPointNumbers = "$compat"
    """)

    # A throwaway package with its own test/ env.
    function _dummy_project(; compat::String)
        dir = mktempdir()
        mkpath(joinpath(dir, "src"))
        mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "src", "Dummy.jl"), "module Dummy end\n")
        write(joinpath(dir, "Project.toml"), """
        name = "Dummy"
        uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        version = "0.1.0"
        """)
        write(joinpath(dir, "test", "runtests.jl"),
              "using Test\n@testset \"dummy\" begin\n    @test true\nend\n")
        _set_compat(dir, compat)
        return dir
    end

    function _run_to_completion(dir; timeout = 300.0)
        run = Kaimon.spawn_test_run(dir; verbose = 1)
        deadline = time() + timeout
        while (!run.reader_done || run.status == Kaimon.RUN_RUNNING) && time() < deadline
            sleep(0.25)
        end
        return run
    end

    @testset "each Julia version gets its own test manifest" begin
        if ci
            @test_skip "versioned manifest (spawns a sub-subprocess; skipped in CI)"
        else
            dir = _dummy_project(compat = "0.8")
            run = _run_to_completion(dir)
            @test run.status == Kaimon.RUN_PASSED

            # One shared Manifest.toml cannot serve two Julia versions, so the runner writes
            # the version-scoped name Julia already prefers.
            vname = "Manifest-v$(VERSION.major).$(VERSION.minor).toml"
            @test isfile(joinpath(dir, "test", vname))
            @test run.manifest_name == vname
            @test run.julia_version == string(VERSION)

            # A manifest left by another Julia is not adopted — it would pin versions this
            # Julia may be unable to precompile — and is not clobbered either.
            other = joinpath(dir, "test", "Manifest.toml")
            write(other, "julia_version = \"0.1.0\"\nmanifest_format = \"2.0\"\n")
            before = read(other, String)
            rm(joinpath(dir, "test", vname))
            run2 = _run_to_completion(dir)
            @test run2.status == Kaimon.RUN_PASSED
            @test isfile(joinpath(dir, "test", vname))
            @test read(other, String) == before
        end
    end

    @testset "a manifest the project has moved past is re-resolved, not reported as failure" begin
        if ci
            @test_skip "stale-manifest recovery (spawns a sub-subprocess; skipped in CI)"
        else
            # Resolve a manifest pinning an exact version...
            dir = _dummy_project(compat = "=0.8.4")
            @test _run_to_completion(dir).status == Kaimon.RUN_PASSED

            # ...then raise the bound past it, as a dependency bump does. `Pkg.resolve` holds
            # each manifest entry at its recorded version and so reports this unsatisfiable;
            # only a re-resolve with room to move recovers. Before the fallback existed this
            # surfaced as an unrelated downstream precompile error and zero tests.
            _set_compat(dir, "0.8.5")
            run = _run_to_completion(dir)
            @test run.status == Kaimon.RUN_PASSED
            @test run.total_pass == 1
            @test isempty(run.env_error)
            @test any(l -> occursin("re-resolving with Pkg.update", l), run.raw_output)
        end
    end

    @testset "an unresolvable environment is the run's own error" begin
        if ci
            @test_skip "env error reporting (spawns a sub-subprocess; skipped in CI)"
        else
            dir = _dummy_project(compat = "0.8")
            # No release satisfies this, so neither resolve nor the re-resolve can succeed.
            _set_compat(dir, "99999")
            run = _run_to_completion(dir)

            @test run.status == Kaimon.RUN_ERROR
            @test !isempty(run.env_error)
            # Reported as the environment failing, not as a test failure.
            @test run.total_fail == 0
            @test occursin("could not be resolved", Kaimon.format_test_summary(run))
        end
    end
end

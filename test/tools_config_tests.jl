using ReTest
using Kaimon
import Test
import Logging

# `.kaimon/tools.json` resolution. The sharp edge these guard: a file that only *subtracts*
# must not empty the whole surface — it reads as a denylist against the default set, while a
# file that names tools is an allowlist.
@testset "Tools Config" begin
    Kaimon.ALL_TOOLS[] = Kaimon.collect_tools()

    # Write `body` to <tmp>/.kaimon/tools.json and return the resolved tool ids.
    function resolve(body::String)
        dir = mktempdir()
        mkpath(joinpath(dir, ".kaimon"))
        write(joinpath(dir, ".kaimon", "tools.json"), body)
        return Kaimon.load_tools_config(".kaimon/tools.json", dir)
    end
    count_of(cfg) = length(Kaimon.filter_tools_by_config(cfg))

    default_ids = Set{Symbol}(
        t.id for t in Kaimon.ALL_TOOLS[] if !(t.id in Kaimon.DEFAULT_OFF_TOOLS)
    )
    n_default = length(default_ids)

    @testset "No config serves the default surface" begin
        @test Kaimon.load_tools_config(".kaimon/tools.json", mktempdir()) === nothing
        @test count_of(nothing) == n_default
        @test n_default > 0
        @test n_default < length(Kaimon.ALL_TOOLS[])   # DEFAULT_OFF_TOOLS withheld
    end

    @testset "Subtract-only files are denylists" begin
        # The reported bug: each of these used to resolve to zero tools.
        cfg = resolve("""{"disabled_tools": ["pkg_add", "pkg_rm"]}""")
        @test count_of(cfg) == n_default - 2
        @test !(:pkg_add in cfg)
        @test :ex in cfg

        lone = resolve("""{"individual_overrides": {"run_tests": false}}""")
        @test count_of(lone) == n_default - 1
        @test !(:run_tests in lone)
        @test :ex in lone
    end

    @testset "The documented wildcard form works" begin
        cfg = resolve("""{"disabled_tools": ["pkg_add"], "enabled_tools": ["*"]}""")
        @test count_of(cfg) == n_default - 1
        @test !(:pkg_add in cfg)
        @test :ex in cfg
    end

    @testset "Naming tools makes it an allowlist" begin
        cfg = resolve("""{"enabled_tools": ["ex", "grep_code"]}""")
        @test cfg == Set([:ex, :grep_code])
        @test count_of(cfg) == 2
    end

    @testset "Tool sets select, and overrides win" begin
        cfg = resolve("""
        {
          "tool_sets": {
            "search":  {"enabled": true,  "tools": ["search_code", "grep_code"]},
            "admin":   {"enabled": false, "tools": ["pkg_add"]}
          },
          "individual_overrides": {"run_tests": true, "grep_code": false, "_note": "ignored"}
        }
        """)
        @test cfg == Set([:search_code, :run_tests])
        @test !(:pkg_add in cfg)      # disabled set contributes nothing
        @test !(Symbol("_note") in cfg)
    end

    @testset "Default-off tools can be re-enabled by name" begin
        off = first(Kaimon.DEFAULT_OFF_TOOLS)
        @test !(off in default_ids)
        @test off in resolve("""{"enabled_tools": ["$(off)"]}""")
        @test off in resolve("""{"individual_overrides": {"$(off)": true}}""")
    end

    @testset "An empty resolution warns rather than passing silently" begin
        # `@test_logs` can't record into a ReTest testset, so capture explicitly.
        logger = Test.TestLogger()
        cfg = Logging.with_logger(logger) do
            resolve("""{"enabled_tools": ["no_such_tool"]}""")
        end
        @test any(
            r -> r.level == Logging.Warn && occursin("zero tools", r.message),
            logger.logs,
        )
        @test count_of(cfg) == 0
    end

    @testset "Malformed JSON falls back to the default surface" begin
        @test resolve("{ not json") === nothing
    end
end

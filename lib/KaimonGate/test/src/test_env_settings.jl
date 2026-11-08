# Settings documented as environment variables take effect in the process that sets them, not
# only in the one that precompiled the package.

using Test
using KaimonGate

const KG = KaimonGate
const GATE_DIR = dirname(dirname(pathof(KaimonGate)))

@testset "A setting is read from the environment when the package loads" begin
    r = KG._env_setting("KAIMON_TEST_ENV_SETTING", 3, Function[])
    @test r[] == 3
    registry = Function[]
    r = withenv("KAIMON_TEST_ENV_SETTING" => "7") do
        KG._env_setting("KAIMON_TEST_ENV_SETTING", 3, registry)
    end
    @test r[] == 7
    withenv("KAIMON_TEST_ENV_SETTING" => "not a number") do
        KG._load_env_settings!(registry)
    end
    @test r[] == 3
    withenv("KAIMON_TEST_ENV_SETTING" => "0.25") do
        f = KG._env_setting("KAIMON_TEST_ENV_SETTING", 0.5, registry)
        @test f[] == 0.25
    end
end

@testset "The precompiled package honours the environment of the loading process" begin
    env = copy(ENV)
    env["KAIMON_SERVICE_TCP_PORT"] = "12345"
    env["KAIMON_GATE_MAX_DEFERRED"] = "7"
    env["KAIMON_GATE_STREAM_SUBPOLL"] = "0.125"
    code = "using KaimonGate; print(KaimonGate._SERVICE_TCP_PORT[], ' ', " *
           "KaimonGate._GATE_MAX_DEFERRED[], ' ', KaimonGate._STREAM_SUBPOLL_INTERVAL[])"
    out = read(Cmd(`$(joinpath(Sys.BINDIR, "julia")) --project=$GATE_DIR --startup-file=no -e $code`; env), String)
    @test out == "12345 7 0.125"
end

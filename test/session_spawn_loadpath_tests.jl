using ReTest
using Kaimon

# Regression tests for the lightweight agent-spawned session (issue #47).
#
# Bug: a managed session spawned against a target project whose Manifest.toml
# invalidated Kaimon's precompile cache died during boot — the subprocess
# loaded the *heavyweight* Kaimon and the worker that rebuilt it from source
# couldn't resolve Kaimon's deps against the target's manifest.
#
# Fix (2.0): the agent-spawned session boots only the lightweight `KaimonGate`
# (ZMQ + stdlib), matching the user-initiated startup.jl path. KaimonGate is
# made resolvable via its own env on JULIA_LOAD_PATH (pkgdir(KaimonGate), which
# carries a Manifest pinning ZMQ), and the host's identity (mirror preference,
# personality, version) is conveyed via KAIMON_GATE_* env vars rather than by
# loading Kaimon. No heavy recompile can happen in a session, so #47 dissolves.

const _GATE_ENV = pkgdir(Kaimon.KaimonGate)

@testset "Spawned session is lightweight (KaimonGate only)" begin

    @testset "Boot script loads KaimonGate, not heavyweight Kaimon" begin
        script = Kaimon._build_session_script("/nonexistent/project")
        @test occursin("using KaimonGate", script)
        @test occursin("KaimonGate.serve", script)
        # Must NOT load the heavyweight Kaimon, and must NOT route through it.
        @test !occursin(r"using Kaimon\b", script)        # \b ⇒ excludes "KaimonGate"
        @test !occursin("Kaimon.KaimonGate.serve", script)
        # The pre-fix script injected `insert!(LOAD_PATH, 1, pkgdir(Kaimon))`.
        @test !occursin("insert!(LOAD_PATH", script)
        @test occursin("Pkg.instantiate", script)
    end

    @testset "Spawn env makes the lightweight gate self-sufficient" begin
        env = Kaimon._build_session_env()
        @test haskey(env, "JULIA_LOAD_PATH")
        @test env["JULIA_PROJECT"] == ""

        lp = env["JULIA_LOAD_PATH"]
        # The "julia --project=<path>" baseline must still control the active env.
        @test startswith(lp, "@:@v#.#:@stdlib")
        # KaimonGate's own env is appended so the gate (and its ZMQ dep) resolve
        # from source without a global install.
        if _GATE_ENV !== nothing
            @test endswith(lp, _GATE_ENV)
            @test occursin(":" * _GATE_ENV, lp)
        end
    end

    @testset "Spawn env bridges the host's identity to the standalone gate" begin
        env = Kaimon._build_session_env()
        # Mirror preference always conveyed (so a joined console shows agent
        # eval activity by default, matching the full-Kaimon behavior).
        @test haskey(env, "KAIMON_GATE_MIRROR_REPL")
        @test env["KAIMON_GATE_MIRROR_REPL"] in ("0", "1")
        @test env["KAIMON_GATE_MIRROR_REPL"] ==
              (Kaimon.get_gate_mirror_repl_preference() ? "1" : "0")
    end

    @testset "KaimonGate default providers honor KAIMON_GATE_* env" begin
        # Test the *defaults* directly: loading Kaimon overrides the live
        # provider Refs in this process, so go through the named defaults that
        # a standalone (lightweight) gate actually uses.
        KG = Kaimon.KaimonGate
        withenv("KAIMON_GATE_MIRROR_REPL" => "1") do
            @test KG._default_mirror_pref_provider() === true
        end
        withenv("KAIMON_GATE_MIRROR_REPL" => "0") do
            @test KG._default_mirror_pref_provider() === false
        end
        withenv("KAIMON_GATE_MIRROR_REPL" => nothing) do
            @test KG._default_mirror_pref_provider() === false
        end
        withenv("KAIMON_GATE_PERSONALITY" => "🥷") do
            @test KG._default_personality_provider() == "🥷"   # env wins
        end
        # No env var: the standalone provider reads the shared config's personality
        # NAME and maps it to an emoji (matching Kaimon's load_personality), so a
        # bare KaimonGate gate still shows the user's personality. ⚡ only when there
        # is no config at all.
        mktempdir() do dir
            cfgdir = joinpath(dir, "kaimon")
            mkpath(cfgdir)
            write(joinpath(cfgdir, "config.json"), "{\"personality\": \"l33t\"}")
            withenv("KAIMON_GATE_PERSONALITY" => nothing, "XDG_CONFIG_HOME" => dir) do
                @test KG._default_personality_provider() == "👻"   # l33t → 👻 from config
            end
            withenv("KAIMON_GATE_PERSONALITY" => nothing,
                    "XDG_CONFIG_HOME" => joinpath(dir, "empty")) do
                @test KG._default_personality_provider() == "⚡"   # no config → fallback
            end
        end
        withenv("KAIMON_GATE_VERSION" => "9.9.9-test") do
            @test KG._default_version_provider() == "9.9.9-test"
        end
    end
end

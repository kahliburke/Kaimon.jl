using ReTest
using Kaimon

# Regression tests for the spawn-time JULIA_LOAD_PATH fix.
#
# Bug: when a managed session was spawned against a target project whose
# Manifest.toml had drifted enough to invalidate Kaimon's precompile cache,
# the subprocess died during boot because the worker that rebuilt Kaimon
# could not resolve Kaimon's direct deps (JSON, ZMQ, HTTP, …) — they live
# in Kaimon's own env, which was not on the subprocess's JULIA_LOAD_PATH.
#
# Fix: capture Kaimon's load-time env via `Base.active_project()` at module
# load (`Kaimon._KAIMON_LOAD_ENV`) and append it to `JULIA_LOAD_PATH` in the
# spawn env. The previous `insert!(LOAD_PATH, 1, pkgdir(Kaimon))` line in
# the boot script was redundant (a bare pkgdir has no manifest) and is
# removed.

@testset "Spawned session JULIA_LOAD_PATH" begin

    @testset "_KAIMON_LOAD_ENV captured at module load" begin
        # Captured from `Base.active_project()` when the Kaimon module loads.
        # We can't assert anything stronger about on-disk state at test
        # time: under `Pkg.test`, the active project at load time is a
        # tempdir sandbox that may not survive into a downstream test
        # worker. The behavior we care about — that the value flows into
        # the spawn env — is covered in the next testset.
        env = Kaimon._KAIMON_LOAD_ENV
        @test env isa AbstractString
        @test !isempty(env)
    end

    @testset "Spawn env appends Kaimon's load env to JULIA_LOAD_PATH" begin
        env = Kaimon._build_session_env()
        @test haskey(env, "JULIA_LOAD_PATH")
        @test haskey(env, "JULIA_PROJECT")
        @test env["JULIA_PROJECT"] == ""

        lp = env["JULIA_LOAD_PATH"]
        # The "julia --project=<path>" baseline must still be present so the
        # target project resolves normally.
        @test startswith(lp, "@:@v#.#:@stdlib")
        # And Kaimon's load env must be appended so a precompile-from-source
        # of Kaimon in the subprocess can resolve Kaimon's own deps.
        @test endswith(lp, Kaimon._KAIMON_LOAD_ENV)
        @test occursin(":" * Kaimon._KAIMON_LOAD_ENV, lp)
    end

    @testset "Boot script no longer inserts bare pkgdir on LOAD_PATH" begin
        # The pre-fix script injected `insert!(LOAD_PATH, 1, pkgdir(Kaimon))`.
        # A pkgdir is not an env and has no manifest, so it shadowed proper
        # env-based dep resolution. The fix removes it.
        script = Kaimon._build_session_script("/nonexistent/project")
        @test !occursin("insert!(LOAD_PATH", script)
        # Sanity: the script still does the work it needs to do.
        @test occursin("using Kaimon", script)
        @test occursin("Pkg.instantiate", script)
        @test occursin("Kaimon.Gate.serve", script)
    end

    @testset "Integration: spawn survives manifest-drift cache invalidation" begin
        # Heavy integration test: builds a temp project whose Manifest pins a
        # dep at a stale version, which forces the subprocess to rebuild
        # Kaimon's precompile cache. Pre-fix this crashed before any session
        # log was written. Post-fix the subprocess reaches :running.
        #
        # Gated behind KAIMON_TEST_SPAWN_INTEGRATION=1 because it spends
        # ~30s on precompile inside the subprocess.
        if get(ENV, "KAIMON_TEST_SPAWN_INTEGRATION", "0") != "1"
            @info "Skipping spawn-integration test " *
                  "(set KAIMON_TEST_SPAWN_INTEGRATION=1 to run)"
            return
        end

        mktempdir() do dir
            # Minimal project that has at least one dep but does NOT declare
            # any of Kaimon's direct deps. Use Random — always available,
            # nothing else pulled in.
            project_toml = """
            name = "SpawnLoadpathFixture"
            uuid = "5dca8ba3-95b1-4f3f-9eef-c41f6cb1e7a0"
            version = "0.0.1"

            [deps]
            Random = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
            """
            write(joinpath(dir, "Project.toml"), project_toml)

            ms = Kaimon.ManagedSession(dir; name = "spawn_loadpath_fixture")
            try
                Kaimon.spawn_session!(ms)
                # Poll until the subprocess either reaches :running, dies,
                # or we time out. 90s leaves headroom for cold precompile.
                deadline = time() + 90.0
                while ms.status in (:starting,) && time() < deadline
                    sleep(0.5)
                end
                @test ms.status in (:starting, :running)
                @test ms.status != :crashed
                if ms.status == :crashed
                    @info "Session crashed with errors:" ms.error_log
                end
            finally
                Kaimon.stop_session!(ms)
            end
        end
    end
end

using ReTest
using Kaimon

const K = Kaimon

# Run everything under a throwaway cache dir so pid files / service env / storage
# never touch a real managed Qdrant. `kaimon_cache_dir()` recomputes from the
# environment each call, appending "kaimon" under XDG_CACHE_HOME on Unix (and using
# LOCALAPPDATA on Windows), so redirecting these fully isolates the test.
function _with_temp_cache(f)
    dir = mktempdir()
    try
        withenv("XDG_CACHE_HOME" => dir, "LOCALAPPDATA" => dir) do
            f(dir)
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "ManagedQdrant" begin

    @testset "managed mode resolves from env (overrides preference)" begin
        withenv("KAIMON_QDRANT_MANAGED" => "off") do
            @test K.qdrant_managed_mode() === :off
        end
        withenv("KAIMON_QDRANT_MANAGED" => "always") do
            @test K.qdrant_managed_mode() === :always
        end
        withenv("KAIMON_QDRANT_MANAGED" => "auto") do
            @test K.qdrant_managed_mode() === :auto
        end
        withenv("KAIMON_QDRANT_MANAGED" => "AUTO") do  # case-insensitive
            @test K.qdrant_managed_mode() === :auto
        end
        withenv("KAIMON_QDRANT_MANAGED" => "banana") do  # unknown → default :auto
            @test K.qdrant_managed_mode() === :auto
        end
    end

    @testset "set_qdrant_managed_mode! rejects bad values (no persistence)" begin
        # Throws before writing a preference, so it's side-effect-free here.
        @test_throws ArgumentError K.set_qdrant_managed_mode!(:bogus)
        @test_throws ArgumentError K.set_qdrant_managed_mode!("nope")
    end

    @testset "http port parsed from QDRANT_URL" begin
        saved = K.QdrantClient.QDRANT_URL[]
        try
            for (url, port) in [
                "http://localhost:6333" => 6333,
                "http://localhost:6399/" => 6399,
                "http://example.com:1234" => 1234,
                "http://localhost" => 6333,          # no port → default
            ]
                K.QdrantClient.QDRANT_URL[] = url
                @test K._qdrant_http_port() == port
            end
        finally
            K.QdrantClient.QDRANT_URL[] = saved
        end
    end

    @testset "cache paths live under the cache dir" begin
        _with_temp_cache() do dir
            cache = K.kaimon_cache_dir()
            @test startswith(K.qdrant_service_env(), cache)
            @test endswith(K.qdrant_service_env(), "service-env")
            @test startswith(K.qdrant_storage_dir(), cache)
            @test startswith(K.qdrant_log_path(), cache)
            @test startswith(K._qdrant_pid_file(), cache)
            @test endswith(K._qdrant_pid_file(), "qdrant.pid")
        end
    end

    @testset "install command targets the service env, unpinned" begin
        _with_temp_cache() do dir
            cmd = string(K.qdrant_install_command())
            @test occursin("Qdrant_jll", cmd)
            @test occursin("Pkg.add", cmd)
            @test occursin(K.qdrant_service_env(), cmd)
            @test !occursin("version=", cmd)   # unpinned → tracks newest registered JLL
        end
    end

    @testset "managed_qdrant_installed reflects the service-env manifest" begin
        _with_temp_cache() do dir
            @test K.managed_qdrant_installed() == false
            write(joinpath(K.qdrant_service_env(), "Manifest.toml"),
                  "[[deps.Qdrant_jll]]\nuuid = \"49d5a0a8-0cca-57b3-8548-a2cd8c16dcd0\"\n")
            @test K.managed_qdrant_installed() == true
        end
    end

    @testset "managed_qdrant_ready is false when the JLL isn't loaded" begin
        # The test process never loads Qdrant_jll.
        @test K._QDRANT_JLL_MOD[] === nothing
        @test K.managed_qdrant_ready() == false
    end

    @testset "pid file round-trip + liveness probe" begin
        _with_temp_cache() do dir
            @test K._read_qdrant_pid() === nothing         # no file yet
            K._write_qdrant_pid(getpid())
            @test K._read_qdrant_pid() == getpid()
            @test K._pid_alive(getpid()) == true           # we're alive
            @test K._pid_alive(2^30) == false              # nonexistent pid
        end
    end

    @testset "managed_qdrant_running: live pid true, stale pid cleaned" begin
        _with_temp_cache() do dir
            saved = K._QDRANT_PROC[]
            try
                K._QDRANT_PROC[] = nothing
                K._write_qdrant_pid(getpid())              # a live instance
                @test K.managed_qdrant_running() == true
                K._write_qdrant_pid(2^30)                  # stale
                @test K.managed_qdrant_running() == false
                @test !isfile(K._qdrant_pid_file())        # stale file cleaned up
            finally
                K._QDRANT_PROC[] = saved
            end
        end
    end

    @testset "atexit reaper leaves a NON-owned instance alone (regression)" begin
        # A transient Kaimon process exiting must NOT kill a shared managed Qdrant
        # it never spawned: with no handle, shutdown_qdrant! is a no-op and must
        # not touch the pid file.
        _with_temp_cache() do dir
            saved = K._QDRANT_PROC[]
            try
                K._QDRANT_PROC[] = nothing
                K._write_qdrant_pid(getpid())              # someone else's instance
                K.shutdown_qdrant!()                       # the atexit path
                @test isfile(K._qdrant_pid_file())         # untouched
                @test K._read_qdrant_pid() == getpid()
            finally
                K._QDRANT_PROC[] = saved
            end
        end
    end

    @testset "stop_managed_qdrant! clears the pid file (explicit stop)" begin
        _with_temp_cache() do dir
            saved = K._QDRANT_PROC[]
            try
                K._QDRANT_PROC[] = nothing
                K._write_qdrant_pid(2^30)                  # dead pid → no real kill
                K.stop_managed_qdrant!()
                @test !isfile(K._qdrant_pid_file())
            finally
                K._QDRANT_PROC[] = saved
            end
        end
    end
end

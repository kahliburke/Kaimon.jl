using ReTest
using Kaimon

const K = Kaimon

# Run everything under a throwaway cache dir so records / service env / storage
# never touch a real managed Qdrant. `kaimon_cache_dir()` recomputes from the
# environment each call and takes KAIMON_CACHE_DIR as the directory itself, on
# every platform, so setting it fully isolates the test.
function _with_temp_cache(f)
    dir = mktempdir()
    try
        withenv("KAIMON_CACHE_DIR" => dir) do
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

    @testset "storage, logs and record live under the storage root" begin
        _with_temp_cache() do dir
            cache = K.kaimon_cache_dir()
            @test startswith(K.qdrant_service_env(), cache)
            @test endswith(K.qdrant_service_env(), "service-env")
            withenv("KAIMON_QDRANT_STORAGE" => nothing) do
                @test K.qdrant_storage_root() == joinpath(cache, "qdrant")   # default
            end
            root = joinpath(dir, "project", "kaimon-qdrant")
            withenv("KAIMON_QDRANT_STORAGE" => root) do
                @test K.qdrant_storage_root() == root
                @test K.qdrant_storage_dir() == joinpath(root, "storage")
                @test startswith(K.qdrant_log_path(), root)
                @test occursin(gethostname(), K.qdrant_log_path())          # per machine
                @test K.qdrant_record_path() == joinpath(root, "server.json")
                Sys.isunix() && @test filemode(root) & 0o077 == 0           # private
                Sys.isunix() && @test filemode(K.qdrant_storage_dir()) & 0o077 == 0
            end
        end
    end

    @testset "managed Qdrant listens on loopback with the launch's key" begin
        _with_temp_cache() do dir
            env = withenv("QDRANT__SERVICE__GRPC_PORT" => "7002") do
                K._qdrant_env(; storage_path = joinpath(dir, "s"), http_port = 7001,
                              api_key = "k123")
            end
            @test env["QDRANT__SERVICE__HOST"] == "127.0.0.1"
            @test env["QDRANT__SERVICE__HTTP_PORT"] == "7001"
            @test !haskey(env, "QDRANT__SERVICE__GRPC_PORT")
            @test env["QDRANT__SERVICE__API_KEY"] == "k123"
            @test env["QDRANT__STORAGE__SNAPSHOTS_PATH"] == joinpath(dir, "snapshots")
        end
    end

    @testset "a failed start says why" begin
        @test occursin("exit code 3", K._qdrant_exit_problem(3))
        if Sys.iswindows()
            @test occursin("Visual C++ Redistributable", K._qdrant_exit_problem(0xC0000135))
        end
        _with_temp_cache() do dir
            taken = K.Sockets.listen(K.Sockets.localhost, 0)
            port = Int(K.Sockets.getsockname(taken)[2])
            try
                withenv("KAIMON_QDRANT_PORT" => string(port),
                        "KAIMON_QDRANT_FIXED_PORT" => "true") do
                    problem = K._start_and_await_qdrant(1.0, 1.0)
                    @test occursin("fixed to port $port", problem)
                end
            finally
                close(taken)
            end
        end
    end

    @testset "managed Qdrant's config file turns gRPC off" begin
        dir = mktempdir()
        path = K._write_qdrant_config(dir)
        @test dirname(path) == dir
        @test occursin(r"^service:\n  grpc_port: null$"m, read(path, String))
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

    rec(pid; host = gethostname(), port = 7001, key = "k", hb = time()) =
        K.write_service_record(K.qdrant_record_path(), K.ServiceRecord(host, pid, port, key, hb))

    @testset "record round-trip + liveness probe" begin
        _with_temp_cache() do dir
            @test K.read_service_record(K.qdrant_record_path()) === nothing   # none yet
            rec(getpid())
            r = K.read_service_record(K.qdrant_record_path())
            @test r.host == gethostname() && r.pid == getpid() && r.port == 7001 && r.key == "k"
            Sys.isunix() && @test filemode(K.qdrant_record_path()) & 0o077 == 0   # key stays private
            @test K.record_live_here(r)
            @test K._pid_alive(getpid()) == true            # we're alive
            @test K._pid_alive(2^30) == false               # nonexistent pid
            @test K.record_fresh(r)
            @test !K.record_fresh(r; now = time() + K.SERVICE_STALE_S + 1)
        end
    end

    @testset "managed_qdrant_running: live record true, dead record removed, other host false" begin
        _with_temp_cache() do dir
            saved = K._QDRANT_PROC[]
            try
                K._QDRANT_PROC[] = nothing
                rec(getpid())                               # a live instance here
                @test K.managed_qdrant_running() == true
                rec(2^30)                                   # its process is gone
                @test K.managed_qdrant_running() == false
                @test !isfile(K.qdrant_record_path())       # dead record cleaned up
                rec(getpid(); host = "another-node")        # someone else's machine
                @test K.managed_qdrant_running() == false
                @test isfile(K.qdrant_record_path())        # not ours to remove
            finally
                K._QDRANT_PROC[] = saved
            end
        end
    end

    @testset "atexit reaper survives an already-exited child (regression)" begin
        # `getpid` throws ESRCH once a child has exited and been reaped — which is the
        # normal state by the time the reaper's kill loop finishes. Reading it there threw
        # IOError straight out of atexit, so every clean shutdown ended in a stack trace.
        _with_temp_cache() do dir
            saved = K._QDRANT_PROC[]
            try
                proc = run(`sh -c "exit 0"`; wait = false)
                wait(proc)
                @test !Base.process_running(proc)
                @test K._proc_pid(proc) === nothing        # handle is gone

                K._QDRANT_PROC[] = proc
                rec(2^30)                                  # a pid that is not alive
                @test_nowarn K.shutdown_qdrant!()
                @test !isfile(K.qdrant_record_path())      # dead-pid record still cleaned
                @test K._QDRANT_PROC[] === nothing

                # ...but a record naming a LIVE process we can no longer identify as
                # ours is left alone rather than yanked from under its owner.
                proc2 = run(`sh -c "exit 0"`; wait = false)
                wait(proc2)
                K._QDRANT_PROC[] = proc2
                rec(getpid())                              # someone else's live instance
                K.shutdown_qdrant!()
                @test isfile(K.qdrant_record_path())
            finally
                K._QDRANT_PROC[] = saved
            end
        end
    end

    @testset "atexit reaper leaves a NON-owned instance alone (regression)" begin
        # A transient Kaimon process exiting must NOT kill a shared managed Qdrant
        # it never spawned: with no handle, shutdown_qdrant! is a no-op and must
        # not touch the record.
        _with_temp_cache() do dir
            saved = K._QDRANT_PROC[]
            try
                K._QDRANT_PROC[] = nothing
                rec(getpid())                              # someone else's instance
                K.shutdown_qdrant!()                       # the atexit path
                @test isfile(K.qdrant_record_path())       # untouched
                @test K.read_service_record(K.qdrant_record_path()).pid == getpid()
            finally
                K._QDRANT_PROC[] = saved
            end
        end
    end

    @testset "stop_managed_qdrant! clears this machine's record (explicit stop)" begin
        _with_temp_cache() do dir
            saved = K._QDRANT_PROC[]
            try
                K._QDRANT_PROC[] = nothing
                rec(2^30)                                  # dead pid → no real kill
                K.stop_managed_qdrant!()
                @test !isfile(K.qdrant_record_path())
                rec(2^30; host = "another-node")           # another machine's instance
                K.stop_managed_qdrant!()
                @test isfile(K.qdrant_record_path())       # not ours to stop or remove
            finally
                K._QDRANT_PROC[] = saved
            end
        end
    end

    @testset "delete_qdrant_storage! removes only what Kaimon put there" begin
        _with_temp_cache() do dir
            root = joinpath(dir, "chosen")
            withenv("KAIMON_QDRANT_STORAGE" => root) do
                mkpath(K.qdrant_storage_dir()); rec(2^30)
                write(joinpath(root, "notes.txt"), "the user's own file")
                K.delete_qdrant_storage!()
                @test !isdir(joinpath(root, "storage"))
                @test !isfile(K.qdrant_record_path())
                @test isfile(joinpath(root, "notes.txt"))
            end
        end
    end

    @testset "endpoint: configured server, then this machine's record, then the port" begin
        _with_temp_cache() do dir
            withenv("KAIMON_QDRANT_URL" => "http://qdrant.example:6333/", "KAIMON_QDRANT_API_KEY" => "uk") do
                @test K.qdrant_endpoint() == ("http://qdrant.example:6333", "uk")   # taken as given
            end
            withenv("KAIMON_QDRANT_URL" => nothing, "KAIMON_QDRANT_PORT" => "6399") do
                rec(getpid(); port = 7005, key = "rk")
                @test K.qdrant_endpoint() == ("http://127.0.0.1:7005", "rk")
                rec(getpid(); host = "another-node", port = 7005, key = "rk")
                url, key = K.qdrant_endpoint()                   # not reachable from here
                @test key == "" && url in ("http://127.0.0.1:6399", "http://127.0.0.1:0")
            end
        end
    end
end

@testset "Managed Qdrant startup wait" begin
    never = () -> false
    always = () -> true
    # Healthy on the first poll.
    @test K._await_qdrant_healthy(always, always, () -> 0; timeout = 1, max_wait = 5) === :healthy
    # The child exiting ends the wait at once.
    @test K._await_qdrant_healthy(never, never, () -> 0; timeout = 5, max_wait = 5) === :exited
    # No log growth for `timeout` seconds.
    @test K._await_qdrant_healthy(never, always, () -> 0;
        timeout = 0.2, max_wait = 5, interval = 0.02) === :stalled
    # A growing log keeps the wait going past `timeout` until it turns healthy.
    n = Ref(0)
    ping = () -> (n[] += 1; n[] > 30)
    @test K._await_qdrant_healthy(ping, always, () -> n[];
        timeout = 0.1, max_wait = 5, interval = 0.01) === :healthy
    # ...but never past `max_wait`.
    m = Ref(0)
    @test K._await_qdrant_healthy(never, always, () -> (m[] += 1);
        timeout = 0.1, max_wait = 0.3, interval = 0.01) === :max_wait
end

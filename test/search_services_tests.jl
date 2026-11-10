using ReTest
using Kaimon

const KS = Kaimon

# search.json is read through KAIMON_CONFIG_DIR, so a throwaway directory isolates these.
function _with_search_config(f, cfg::AbstractDict)
    dir = mktempdir()
    try
        withenv("KAIMON_CONFIG_DIR" => dir) do
            write(joinpath(KS.kaimon_config_dir(), "search.json"), KS.JSON.json(cfg))
            f()
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "Search services" begin
    @testset "settings: environment, then search.json, then default" begin
        _with_search_config(Dict("qdrant" => Dict("port" => 6400, "url" => ""),
                                 "embedding" => Dict("backend" => "llamacpp"))) do
            withenv("KAIMON_QDRANT_PORT" => nothing, "KAIMON_EMBEDDING_BACKEND" => nothing,
                    "KAIMON_QDRANT_URL" => nothing) do
                @test KS.qdrant_port_setting() == 6400               # from search.json
                @test KS.qdrant_url_setting() == ""                  # empty counts as unset
                @test KS.embedding_backend() === :llamacpp
                @test KS.qdrant_fixed_port() == false                # default
            end
            withenv("KAIMON_QDRANT_PORT" => "6500", "KAIMON_EMBEDDING_BACKEND" => "ollama",
                    "KAIMON_QDRANT_FIXED_PORT" => "true") do
                @test KS.qdrant_port_setting() == 6500               # environment wins
                @test KS.embedding_backend() === :ollama
                @test KS.qdrant_fixed_port() == true
            end
        end
        _with_search_config(Dict()) do
            withenv("KAIMON_QDRANT_PORT" => nothing, "KAIMON_EMBEDDING_BACKEND" => nothing) do
                @test KS.qdrant_port_setting() == 6333
                @test KS.embedding_backend() === :ollama
            end
        end
    end

    @testset "Ollama's address, read the way Ollama reads OLLAMA_HOST" begin
        _with_search_config(Dict()) do
            withenv("KAIMON_OLLAMA_URL" => nothing, "OLLAMA_HOST" => nothing) do
                @test KS.ollama_url() == "http://127.0.0.1:11434"
            end
            withenv("KAIMON_OLLAMA_URL" => nothing, "OLLAMA_HOST" => "127.0.0.1:11500") do
                @test KS.ollama_url() == "http://127.0.0.1:11500"
            end
            withenv("KAIMON_OLLAMA_URL" => nothing, "OLLAMA_HOST" => "gpu-node") do
                @test KS.ollama_url() == "http://gpu-node:11434"
            end
            withenv("KAIMON_OLLAMA_URL" => "https://ollama.example/", "OLLAMA_HOST" => "ignored") do
                @test KS.ollama_url() == "https://ollama.example:11434"
            end
        end
    end

    @testset "per-account fallback ports" begin
        c = KS.service_port_candidates(6333; user = "alice")
        @test first(c) == 6333
        @test length(c) == KS.SERVICE_PORT_TRIES && allunique(c)
        @test all(p -> p in KS.SERVICE_PORT_RANGE, c[2:end])
        @test KS.service_port_candidates(6333; user = "alice") == c         # the same every time
        @test KS.service_port_candidates(6333; user = "bob")[2:end] != c[2:end]
        # A taken preference moves to a fallback, unless the port is fixed.
        held = KS.Sockets.listen(KS.Sockets.localhost, 0)
        try
            p = Int(KS.Sockets.getsockname(held)[2])
            @test !KS.service_port_free(p)
            q = KS.service_free_port(p)
            @test q !== nothing && q != p
            @test KS.service_free_port(p; fixed = true) === nothing
        finally
            close(held)
        end
    end

    @testset "listener owner check" begin
        held = KS.Sockets.listen(KS.Sockets.localhost, 0)
        try
            p = Int(KS.Sockets.getsockname(held)[2])
            if Sys.islinux()
                @test KS.loopback_listener_uid(p) == Int(ccall(:getuid, Cuint, ()))
            else
                @test KS.loopback_listener_uid(p) === nothing
            end
            @test KS.loopback_listener_ok(p)                                # our own
        finally
            close(held)
        end
    end

    @testset "install and download subprocesses get Julia's default load path" begin
        # The kaimon launcher sets JULIA_LOAD_PATH to the Kaimon checkout alone; a child that
        # inherited it could load neither the env it activates nor the standard library.
        withenv("JULIA_LOAD_PATH" => "/only/the/kaimon/checkout") do
            for cmd in (KS.llamacpp_install_command(), KS.qdrant_install_command())
                lp = only(filter(startswith("JULIA_LOAD_PATH="), cmd.env))
                @test occursin("@stdlib", lp) && !occursin("/only/the/kaimon/checkout", lp)
            end
        end
    end

    @testset "service logs append, and rotate past their limit" begin
        d = mktempdir()
        try
            log = joinpath(d, "svc.log")
            io = KS.open_service_log(log); println(io, "first run"); close(io)
            io = KS.open_service_log(log); println(io, "second run"); close(io)
            @test readlines(log) == ["first run", "second run"]          # a restart keeps the earlier output
            @test KS.log_tail(log; n = 1) == "second run"
            write(log, "x"^(KS.SERVICE_LOG_ROTATE_BYTES + 1))
            close(KS.open_service_log(log))
            @test isfile(log * ".1") && filesize(log) == 0               # moved aside, fresh log
            @test KS.log_tail(joinpath(d, "missing.log")) == ""
        finally
            rm(d; recursive = true, force = true)
        end
    end

    @testset "cross-project search groups Kaimon's collections by model" begin
        models = Dict("a" => "m4b", "b" => "m4b", "c" => "m06b", "kaimon_all" => "m06b")
        g = KS._cross_project_groups(["a", "b", "c", "foreign", "kaimon_all"], models, nothing;
                                     legacy = "kaimon_all")
        @test sort(collect(keys(g))) == ["m06b", "m4b"]
        @test sort(g["m4b"]) == ["a", "b"] && g["m06b"] == ["c"]   # no foreign or merged collection
        # An explicit model only reaches collections built with it.
        @test KS._cross_project_groups(["a", "b", "c"], models, "m06b"; legacy = "kaimon_all") ==
              Dict("m06b" => ["c"])
    end

    @testset "service keys are random and long" begin
        a, b = KS.new_service_key(), KS.new_service_key()
        @test a != b && length(a) == 48 && all(isxdigit, a)
    end

    @testset "a process is identified by its pid and start time" begin
        me = KS.Utils.process_start_id(getpid())
        @test me isa String && !isempty(me)
        @test KS.Utils.process_start_id(getpid()) == me              # stable
        @test KS.Utils.same_process(getpid(), me)
        @test !KS.Utils.same_process(getpid(), me * "0")            # the pid, reused by another process
        @test !KS.Utils.same_process(getpid(), "")                  # nothing to compare with
        @test KS.Utils.process_start_id(2^30) === nothing            # no such process
        p = run(`$(Base.julia_cmd()) --startup-file=no -e "sleep(30)"`; wait = false)
        pid = getpid(p)
        try
            child = KS.Utils.process_start_id(pid)
            @test child isa String && child != me
        finally
            kill(p); wait(p)
        end
        @test KS.Utils.process_start_id(pid) === nothing
    end

    @testset "a record names its process only while the pid and start time both match" begin
        r = KS.ServiceRecord(7001, "k")                              # this process, start time read
        @test !isempty(r.started)
        @test KS.record_live_here(r)
        reused = KS.ServiceRecord(r.host, r.pid, r.port, r.key, r.heartbeat, r.started * "0")
        @test !KS.record_live_here(reused)
        @test KS.record_live_here(KS.ServiceRecord(r.host, r.pid, r.port, r.key, r.heartbeat))   # none recorded: the pid alone
        mktempdir() do d
            path = joinpath(d, "server.json")
            KS.write_service_record(path, r)
            @test KS.read_service_record(path).started == r.started
            write(path, KS.JSON.json(Dict("host" => r.host, "pid" => r.pid, "port" => 1, "key" => "k",
                                          "heartbeat" => time())))
            @test KS.read_service_record(path).started == ""         # a record written without one
        end
    end

    @testset "a JLL with no build for this platform is reported, not loaded" begin
        nobuild = Module(:FakeNoBuild_jll)
        Core.eval(nobuild, :(is_available() = false))
        withbuild = Module(:FakeBuild_jll)
        Core.eval(withbuild, :(is_available() = true))
        @test KS.jll_has_build(withbuild, "Fake") == true
        @test !("Fake" in KS.JLLS_WITHOUT_BUILD)
        @test (@test_logs (:warn, KS.no_build_message("Fake")) KS.jll_has_build(nobuild, "Fake")) == false
        @test "Fake" in KS.JLLS_WITHOUT_BUILD
        delete!(KS.JLLS_WITHOUT_BUILD, "Fake")
        @test occursin(KS.jll_platform(), KS.no_build_message("Qdrant"))
    end
end

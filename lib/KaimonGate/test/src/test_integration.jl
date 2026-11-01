using Test
using KaimonGate
using ZMQ
using Serialization

# ── Guard: skip all integration tests if a gate is already running ────────────

if KaimonGate._running()
    @warn "A gate is already running — skipping ZMQ integration tests to avoid conflicts."
    @testset "ZMQ integration (skipped — gate already running)" begin
        @test_skip true
    end
else

# ── Helpers ───────────────────────────────────────────────────────────────────

"""Send a serialized request to a ZMQ REQ socket and return the deserialized response."""
function zmq_req(sock, msg)
    buf = IOBuffer()
    Serialization.serialize(buf, msg)
    ZMQ.send(sock, ZMQ.Message(take!(buf)))
    raw = ZMQ.recv(sock)
    Serialization.deserialize(IOBuffer(raw))
end

# ── IPC gate lifecycle ─────────────────────────────────────────────────────────

@testset "IPC gate lifecycle" begin
    if Sys.iswindows()
        @test_skip true
    else
        session_id = "test-ipc-$(bytes2hex(rand(UInt8, 4)))"
    KaimonGate._serve(name="test", session_id=session_id, force=true)
    sleep(0.15)   # let sockets bind

    @test KaimonGate._running()

    sock_dir  = KaimonGate.sock_dir()
    rep_path  = joinpath(sock_dir, "$session_id.sock")

    ctx = ZMQ.Context()
    req = ZMQ.Socket(ctx, ZMQ.REQ)
    req.rcvtimeo = 5_000
    req.linger   = 0
    ZMQ.connect(req, "ipc://$rep_path")

    try
        resp = zmq_req(req, (type=:ping,))
        @test resp.type == :pong
        @test resp.pid == getpid()
        @test !isempty(resp.stream_endpoint)
    finally
        ZMQ.close(req)
        ZMQ.close(ctx)
        KaimonGate.stop()
        sleep(0.1)
    end

    @test !KaimonGate._running()
    end # if Sys.iswindows()
end

# ── Async tool progress + result ──────────────────────────────────────────────
# Adapted from Kaimon gate_async_tests "Gate async integration: progress + result"

@testset "Async tool progress + result" begin
    tool = KaimonGate.GateTool("counted_op", function(n::Int)
        for i in 1:n
            KaimonGate.progress("step $i of $n")
        end
        return "done:$n"
    end)

    session_id = "test-async-$(bytes2hex(rand(UInt8, 4)))"
    KaimonGate._serve(name="test", session_id=session_id, force=true, tools=[tool])
    sleep(0.15)

    ctx = ZMQ.Context()
    req = ZMQ.Socket(ctx, ZMQ.REQ)
    sub = ZMQ.Socket(ctx, ZMQ.SUB)
    
    if Sys.iswindows()
        sock = KaimonGate._gate_socket()
        rep_path = rstrip(ZMQ._get_last_endpoint(sock), '\0')
        pub_sock = KaimonGate._stream_socket()
        pub_path = rstrip(ZMQ._get_last_endpoint(pub_sock), '\0')
    else
        sock_dir = KaimonGate.sock_dir()
        rep_path = "ipc://" * joinpath(sock_dir, "$session_id.sock")
        pub_path = "ipc://" * joinpath(sock_dir, "$session_id-stream.sock")
    end
    req.rcvtimeo = 5_000
    sub.rcvtimeo = 5_000
    req.linger = 0
    sub.linger = 0
    ZMQ.connect(req, rep_path)
    ZMQ.connect(sub, pub_path)
    ZMQ.subscribe(sub, "")
    sleep(0.1)   # let SUB handshake before tool runs

    try
        rid = "int-$(bytes2hex(rand(UInt8, 4)))"
        ack = zmq_req(req, (
            type=:tool_call_async,
            name="counted_op",
            arguments=Dict{String,Any}("n" => 3),
            request_id=rid,
        ))
        @test ack.type == :accepted
        @test ack.request_id == rid

        progress_msgs = String[]
        result_str    = nothing

        for _ in 1:30
            raw = ZMQ.recv(sub)
            msg = Serialization.deserialize(IOBuffer(raw))
            get(msg, :request_id, "") == rid || continue
            ch   = string(get(msg, :channel, ""))
            data = string(get(msg, :data, ""))
            if ch == "tool_progress"
                push!(progress_msgs, data)
            elseif ch == "tool_complete"
                result_str = data
                break
            elseif ch == "tool_error"
                error("Unexpected tool_error: $data")
            end
        end

        @test progress_msgs == ["step 1 of 3", "step 2 of 3", "step 3 of 3"]
        @test result_str == "done:3"

    finally
        ZMQ.close(req)
        ZMQ.close(sub)
        ZMQ.close(ctx)
        KaimonGate.stop()
        sleep(0.1)
    end
end

# ── TCP ephemeral port + auth ─────────────────────────────────────────────────
# Adapted from Kaimon gate_async_tests "Gate TCP ephemeral port + auth"

@testset "TCP ephemeral port + auth" begin
    token = "test_token_$(bytes2hex(rand(UInt8, 8)))"
    session_id = "test-tcp-$(bytes2hex(rand(UInt8, 4)))"

    # The token is an INPUT to _serve, which resolves it from the environment (or the host
    # provider) into the session it builds. Presetting the old Ref no longer reaches it.
    withenv("KAIMON_GATE_TOKEN" => token) do
        KaimonGate._serve(
            name="test-tcp",
            session_id=session_id,
            force=true,
            mode=:tcp,
            host="127.0.0.1",
            port=0,
        )
    end
    sleep(0.2)

    @test KaimonGate._running()
    @test KaimonGate._mode() == :tcp
    @test KaimonGate._auth_token() == token
    sock = KaimonGate._gate_socket()
    @test sock !== nothing
    rep_endpoint = rstrip(ZMQ._get_last_endpoint(sock), '\0')
    @test startswith(rep_endpoint, "tcp://")
    @test !isempty(KaimonGate._stream_endpoint())
    @test startswith(KaimonGate._stream_endpoint(), "tcp://")

    ctx = ZMQ.Context()
    req = ZMQ.Socket(ctx, ZMQ.REQ)
    req.rcvtimeo = 3_000
    req.linger   = 0
    ZMQ.connect(req, rep_endpoint)

    try
        # No token → rejected
        resp = zmq_req(req, (type=:ping,))
        @test resp.type == :error

        # Fresh socket (REQ/REP state machine)
        ZMQ.close(req)
        req = ZMQ.Socket(ctx, ZMQ.REQ)
        req.rcvtimeo = 3_000
        req.linger   = 0
        ZMQ.connect(req, rep_endpoint)

        # Correct token → pong with stream_endpoint
        resp = zmq_req(req, (type=:ping, token=token))
        @test resp.type == :pong
        @test haskey(resp, :stream_endpoint)
        @test startswith(resp.stream_endpoint, "tcp://")

    finally
        ZMQ.close(req)
        ZMQ.close(ctx)
        KaimonGate.stop()
        sleep(0.1)
    end

    @test !KaimonGate._running()
    @test isempty(KaimonGate._auth_token())
end

# ── discoverable flag: serve without advertising in the discovery registry ─────
# `discoverable=false` serves a normal IPC gate but writes NO <session_id>.json metadata, so
# the TUI / MCP server won't list it (used by embedded/private gates like TachiRei atoms).

@testset "discoverable flag (metadata registration)" begin
    if Sys.iswindows()
        @test_skip true
    else
        sock_dir = KaimonGate.sock_dir()

        # discoverable=false → gate runs, but no metadata file is written
        sid_hidden  = "test-hidden-$(bytes2hex(rand(UInt8, 4)))"
        meta_hidden = joinpath(sock_dir, "$sid_hidden.json")
        rm(meta_hidden; force=true)
        KaimonGate._serve(name="test", session_id=sid_hidden, force=true, discoverable=false)
        sleep(0.15)
        try
            @test KaimonGate._running()
            @test !isfile(meta_hidden)            # not advertised
        finally
            KaimonGate.stop(); sleep(0.1)
            rm(meta_hidden; force=true)
        end

        # default (discoverable=true) → metadata file IS written
        sid_seen  = "test-seen-$(bytes2hex(rand(UInt8, 4)))"
        meta_seen = joinpath(sock_dir, "$sid_seen.json")
        rm(meta_seen; force=true)
        KaimonGate._serve(name="test", session_id=sid_seen, force=true)
        sleep(0.15)
        try
            @test isfile(meta_seen)               # advertised by default
        finally
            KaimonGate.stop(); sleep(0.1)
            rm(meta_seen; force=true)
        end
    end
end

# ── Request router ────────────────────────────────────────────────────────────

@testset "Request router routes requests" begin
    if Sys.iswindows()
        @test_skip true
    else
        tool = KaimonGate.GateTool("where_am_i", () -> string(Threads.threadpool()))
        session_id = "test-route-$(bytes2hex(rand(UInt8, 4)))"
        seen = Channel{Any}(Inf)
        KaimonGate.set_request_router!() do request
            put!(seen, (get(request, :type, nothing), get(request, :name, nothing)))
            run -> Threads.@spawn :interactive run()
        end
        KaimonGate._serve(name="test", session_id=session_id, force=true, tools=[tool])
        sleep(0.15)

        ctx = ZMQ.Context()
        req = ZMQ.Socket(ctx, ZMQ.REQ)
        req.rcvtimeo = 5_000
        req.linger   = 0
        ZMQ.connect(req, "ipc://" * joinpath(KaimonGate.sock_dir(), "$session_id.sock"))
        try
            @test zmq_req(req, (type=:ping,)).type == :pong
            resp = zmq_req(req, (type=:tool_call, name="where_am_i", arguments=Dict{String,Any}()))
            expected = Threads.nthreads(:interactive) > 0 ? "interactive" : "default"
            @test resp.value == expected
            @test take!(seen) == (:ping, nothing)
            @test take!(seen) == (:tool_call, "where_am_i")

            # A failing router or spawner falls back to the default lane instead of dropping the request.
            KaimonGate.set_request_router!(request -> error("router broke"))
            @test zmq_req(req, (type=:ping,)).type == :pong
            KaimonGate.set_request_router!(request -> (run -> error("spawner broke")))
            @test zmq_req(req, (type=:ping,)).type == :pong

            KaimonGate.set_request_router!(nothing)
            resp = zmq_req(req, (type=:tool_call, name="where_am_i", arguments=Dict{String,Any}()))
            @test resp.value == "default"
        finally
            KaimonGate.set_request_router!(nothing)
            ZMQ.close(req)
            ZMQ.close(ctx)
            KaimonGate.stop()
            sleep(0.1)
        end
    end
end

@testset "Routed requests are served while the default lane is at its cap" begin
    if Sys.iswindows()
        @test_skip true
    else
        gate = Base.Event()
        block = KaimonGate.GateTool("block", () -> (wait(gate); "released"))
        echo  = KaimonGate.GateTool("echo", () -> "echoed")
        session_id = "test-cap-$(bytes2hex(rand(UInt8, 4)))"
        saved_cap = KaimonGate._GATE_MAX_WORKERS[]
        KaimonGate._GATE_MAX_WORKERS[] = 1
        # Pings are routed off the default lane; tool calls stay on it.
        KaimonGate.set_request_router!(request -> request.type === :ping ? (run -> Threads.@spawn run()) : nothing)
        KaimonGate._serve(name="test", session_id=session_id, force=true, tools=[block, echo])
        sleep(0.15)

        ctx = ZMQ.Context()
        endpoint = "ipc://" * joinpath(KaimonGate.sock_dir(), "$session_id.sock")
        socks = map(1:3) do _
            s = ZMQ.Socket(ctx, ZMQ.REQ); s.rcvtimeo = 5_000; s.linger = 0; ZMQ.connect(s, endpoint); s
        end
        call(name) = (type=:tool_call, name=name, arguments=Dict{String,Any}())
        try
            # Occupy the only default-lane slot.
            blocked = Threads.@spawn zmq_req(socks[1], call("block"))
            sleep(0.2)
            @test KaimonGate._gate_default_inflight()[] == 1

            # A second default-lane request waits for the slot instead of being refused...
            waiting = Threads.@spawn zmq_req(socks[2], call("echo"))
            sleep(0.2)
            @test !istaskdone(waiting)

            # ...while a routed request is still read and answered.
            t0 = time()
            @test zmq_req(socks[3], (type=:ping,)).type == :pong
            @test time() - t0 < 1.0

            notify(gate)
            @test fetch(blocked).value == "released"
            @test fetch(waiting).value == "echoed"
            @test KaimonGate._gate_default_inflight()[] == 0
        finally
            notify(gate)
            KaimonGate._GATE_MAX_WORKERS[] = saved_cap
            KaimonGate.set_request_router!(nothing)
            foreach(ZMQ.close, socks)
            ZMQ.close(ctx)
            KaimonGate.stop()
            sleep(0.1)
        end
    end
end

end  # if !_running()

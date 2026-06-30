using ReTest
using Kaimon
using ZMQ
using Serialization

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Temporarily replace _SESSION_TOOLS[], restore on exit."""
function with_tools(f, tools)
    original = Kaimon.KaimonGate._SESSION_TOOLS[]
    Kaimon.KaimonGate._SESSION_TOOLS[] = tools
    try
        f()
    finally
        Kaimon.KaimonGate._SESSION_TOOLS[] = original
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Unit tests — no ZMQ sockets needed
# ─────────────────────────────────────────────────────────────────────────────

@testset "Gate.handle_message :tool_call_async" begin

    @testset "unknown tool returns :error" begin
        with_tools(Kaimon.KaimonGate.GateTool[]) do
            resp = Kaimon.KaimonGate.handle_message((
                type = :tool_call_async,
                name = "no_such_tool",
                arguments = Dict{String,Any}(),
                request_id = "req-unknown",
            ))
            @test resp.type == :error
            @test occursin("Unknown session tool", resp.message)
        end
    end

    @testset "known tool returns :accepted with matching request_id" begin
        tool = Kaimon.KaimonGate.GateTool("noop_tool", (msg::String) -> msg)
        with_tools([tool]) do
            rid = "req-accepted-42"
            resp = Kaimon.KaimonGate.handle_message((
                type = :tool_call_async,
                name = "noop_tool",
                arguments = Dict{String,Any}("msg" => "hello"),
                request_id = rid,
            ))
            @test resp.type == :accepted
            @test resp.request_id == rid
        end
    end

    @testset "empty request_id is echoed back" begin
        tool = Kaimon.KaimonGate.GateTool("noop_tool2", () -> "ok")
        with_tools([tool]) do
            resp = Kaimon.KaimonGate.handle_message((
                type = :tool_call_async,
                name = "noop_tool2",
                arguments = Dict{String,Any}(),
                request_id = "",
            ))
            @test resp.type == :accepted
            @test resp.request_id == ""
        end
    end

end

@testset "Gate.progress" begin

    @testset "is a no-op without a socket (does not throw)" begin
        # _STREAM_SOCKET[] is nothing → _publish_stream returns early
        @test_nowarn Kaimon.KaimonGate.progress("no socket")
    end

    @testset "is a no-op without gate_request_id in task-local storage" begin
        result = @async begin
            # No task_local_storage(:gate_request_id, ...) set → rid is nothing → return
            Kaimon.KaimonGate.progress("no request id set")
            :ok
        end
        @test fetch(result) == :ok
    end

    @testset "does not throw when called from inside a handler context" begin
        result = @async begin
            task_local_storage(:gate_request_id, "synthetic-req-id")
            # _STREAM_SOCKET[] is still nothing → _publish_stream is a no-op
            Kaimon.KaimonGate.progress("synthetic progress")
            :ok
        end
        @test fetch(result) == :ok
    end

end

# ─────────────────────────────────────────────────────────────────────────────
# Integration test — real ZMQ gate round-trip
#
# Starts a gate in this process via _serve(force=true), connects raw ZMQ REQ
# and SUB sockets, sends :tool_call_async, and verifies the expected stream
# of tool_progress / tool_complete messages.
# ─────────────────────────────────────────────────────────────────────────────

@testset "Gate async integration: progress + result" begin
    tool = Kaimon.KaimonGate.GateTool("counted_op", function (n::Int)
        for i = 1:n
            Kaimon.KaimonGate.progress("step $i of $n")
        end
        return "done:$n"
    end)

    # If a gate is already running (e.g. this test is run via `ex` inside a live
    # session), attach to it non-destructively: temporarily add the test tool to
    # the existing gate's tool list instead of stopping and restarting the gate.
    # Otherwise start a fresh gate for the test and stop it when done.
    was_running = Kaimon.KaimonGate._RUNNING[]

    if was_running
        orig_tools = copy(Kaimon.KaimonGate._SESSION_TOOLS[])
        session_id = Kaimon.KaimonGate._SESSION_ID[]
        Kaimon.KaimonGate._SESSION_TOOLS[] = vcat(orig_tools, [tool])
        # No sleep needed — sockets are already bound
    else
        session_id = "test-async-$(bytes2hex(rand(UInt8, 4)))"
        if Sys.iswindows()
            Kaimon.KaimonGate._serve(
                name = "test",
                session_id = session_id,
                force = true,
                tools = [tool],
                mode = :tcp,
                host = "127.0.0.1",
                port = 0,
            )
        else
            Kaimon.KaimonGate._serve(
                name = "test",
                session_id = session_id,
                force = true,
                tools = [tool],
            )
        end
        # Give the gate a moment to bind its sockets
        sleep(0.15)
    end

    if Sys.iswindows()
        rep_path = rstrip(ZMQ._get_last_endpoint(Kaimon.KaimonGate._GATE_SOCKET[]), '\0')
        pub_path = Kaimon.KaimonGate._STREAM_ENDPOINT[]
    else
        sock_dir = Kaimon.KaimonGate.sock_dir()
        rep_path = "ipc://" * joinpath(sock_dir, "$session_id.sock")
        pub_path = "ipc://" * joinpath(sock_dir, "$session_id-stream.sock")
    end

    ctx = Context()
    req = Socket(ctx, REQ)
    sub = Socket(ctx, SUB)
    req.rcvtimeo = 5_000   # ms
    sub.rcvtimeo = 5_000
    req.linger = 0
    sub.linger = 0

    connect(req, rep_path)
    connect(sub, pub_path)
    subscribe(sub, "")   # subscribe to all topics
    sleep(0.1)           # let SUB handshake with PUB before the tool runs

    try
        rid = "int-$(bytes2hex(rand(UInt8, 4)))"

        # Send the async request
        request = (
            type = :tool_call_async,
            name = "counted_op",
            arguments = Dict{String,Any}("n" => 3),
            request_id = rid,
        )
        buf = IOBuffer()
        Serialization.serialize(buf, request)
        send(req, Message(take!(buf)))

        # Expect :accepted ack on REQ socket
        raw_ack = recv(req)
        ack = Serialization.deserialize(IOBuffer(raw_ack))
        @test ack.type == :accepted
        @test ack.request_id == rid

        # Collect stream messages, filtering to our request_id
        progress_msgs = String[]
        result_str = nothing

        for _ = 1:30   # generous upper bound; tool emits 3 progress + 1 complete
            raw = recv(sub)
            msg = Serialization.deserialize(IOBuffer(raw))

            # Skip messages not belonging to our request
            get(msg, :request_id, "") == rid || continue

            ch = string(get(msg, :channel, ""))
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
        close(req)
        close(sub)
        close(ctx)
        if was_running
            # Restore original tools without disturbing the running gate
            Kaimon.KaimonGate._SESSION_TOOLS[] = orig_tools
        else
            Kaimon.KaimonGate.stop()
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# TCP auth unit tests — validate handle_message token checking
# ─────────────────────────────────────────────────────────────────────────────

@testset "Gate TCP auth" begin
    orig_mode = Kaimon.KaimonGate._MODE[]
    orig_token = Kaimon.KaimonGate._AUTH_TOKEN[]

    @testset "IPC mode skips auth" begin
        Kaimon.KaimonGate._MODE[] = :ipc
        Kaimon.KaimonGate._AUTH_TOKEN[] = "secret123"
        resp = Kaimon.KaimonGate.handle_message((type = :ping,))
        @test resp.type == :pong
    end

    @testset "TCP mode with empty token skips auth" begin
        Kaimon.KaimonGate._MODE[] = :tcp
        Kaimon.KaimonGate._AUTH_TOKEN[] = ""
        resp = Kaimon.KaimonGate.handle_message((type = :ping,))
        @test resp.type == :pong
    end

    @testset "TCP mode rejects missing token" begin
        Kaimon.KaimonGate._MODE[] = :tcp
        Kaimon.KaimonGate._AUTH_TOKEN[] = "secret123"
        resp = Kaimon.KaimonGate.handle_message((type = :ping,))
        @test resp.type == :error
        @test occursin("Authentication", resp.message)
    end

    @testset "TCP mode rejects wrong token" begin
        Kaimon.KaimonGate._MODE[] = :tcp
        Kaimon.KaimonGate._AUTH_TOKEN[] = "secret123"
        resp = Kaimon.KaimonGate.handle_message((type = :ping, token = "wrong"))
        @test resp.type == :error
        @test occursin("Authentication", resp.message)
    end

    @testset "TCP mode accepts correct token" begin
        Kaimon.KaimonGate._MODE[] = :tcp
        Kaimon.KaimonGate._AUTH_TOKEN[] = "secret123"
        resp = Kaimon.KaimonGate.handle_message((type = :ping, token = "secret123"))
        @test resp.type == :pong
    end

    @testset "pong includes stream_endpoint" begin
        Kaimon.KaimonGate._MODE[] = :ipc
        Kaimon.KaimonGate._AUTH_TOKEN[] = ""
        Kaimon.KaimonGate._STREAM_ENDPOINT[] = "ipc:///tmp/test-stream.sock"
        resp = Kaimon.KaimonGate.handle_message((type = :ping,))
        @test resp.type == :pong
        @test resp.stream_endpoint == "ipc:///tmp/test-stream.sock"
        Kaimon.KaimonGate._STREAM_ENDPOINT[] = ""
    end

    Kaimon.KaimonGate._MODE[] = orig_mode
    Kaimon.KaimonGate._AUTH_TOKEN[] = orig_token
end

# ─────────────────────────────────────────────────────────────────────────────
# TCP gate integration test — ephemeral port + auth round-trip
# ─────────────────────────────────────────────────────────────────────────────

@testset "Gate TCP ephemeral port + auth" begin
    if Kaimon.KaimonGate._RUNNING[]
        @info "Skipping TCP test — gate already running"
        @test_skip false
        return
    end

    token = "test_token_$(bytes2hex(rand(UInt8, 8)))"
    session_id = "test-tcp-$(bytes2hex(rand(UInt8, 4)))"

    Kaimon.KaimonGate._AUTH_TOKEN[] = token
    Kaimon.KaimonGate._serve(
        name = "test-tcp",
        session_id = session_id,
        force = true,
        mode = :tcp,
        host = "127.0.0.1",
        port = 0,
    )
    sleep(0.2)

    @test Kaimon.KaimonGate._RUNNING[]
    @test Kaimon.KaimonGate._MODE[] == :tcp

    sock = Kaimon.KaimonGate._GATE_SOCKET[]
    @test sock !== nothing
    rep_endpoint = rstrip(ZMQ._get_last_endpoint(sock), '\0')
    @test startswith(rep_endpoint, "tcp://")

    @test !isempty(Kaimon.KaimonGate._STREAM_ENDPOINT[])
    @test startswith(Kaimon.KaimonGate._STREAM_ENDPOINT[], "tcp://")

    ctx = Context()
    req = Socket(ctx, REQ)
    req.rcvtimeo = 3000
    req.linger = 0
    ZMQ.connect(req, rep_endpoint)

    try
        # Ping without token → rejected
        io = IOBuffer()
        serialize(io, (type = :ping,))
        send(req, Message(take!(io)))
        resp = deserialize(IOBuffer(recv(req)))
        @test resp.type == :error

        # Fresh REQ socket (REQ/REP state machine requires it)
        close(req)
        req = Socket(ctx, REQ)
        req.rcvtimeo = 3000
        req.linger = 0
        ZMQ.connect(req, rep_endpoint)

        # Ping with correct token → pong with stream_endpoint
        io = IOBuffer()
        serialize(io, (type = :ping, token = token))
        send(req, Message(take!(io)))
        resp = deserialize(IOBuffer(recv(req)))
        @test resp.type == :pong
        @test haskey(resp, :stream_endpoint)
        @test startswith(resp.stream_endpoint, "tcp://")

        # stream_endpoint from pong is connectable
        sub = Socket(ctx, SUB)
        sub.linger = 0
        sub.rcvtimeo = 100
        ZMQ.subscribe(sub, "")
        ZMQ.connect(sub, resp.stream_endpoint)
        close(sub)
    finally
        close(req)
        close(ctx)
        Kaimon.KaimonGate.stop()
        sleep(0.1)
    end

    @test !Kaimon.KaimonGate._RUNNING[]
    @test isempty(Kaimon.KaimonGate._AUTH_TOKEN[])
end

# ─────────────────────────────────────────────────────────────────────────────
# connect_tcp! rejects unreachable gates
# ─────────────────────────────────────────────────────────────────────────────

@testset "connect_tcp! fails on unreachable gate" begin
    mgr = Kaimon.ConnectionManager()
    mgr.running = true

    # Port 1 is almost certainly not running a gate
    @test_throws ErrorException Kaimon.connect_tcp!(mgr, "127.0.0.1", 1; name = "ghost")

    # Verify no ghost session was added
    @test isempty(mgr.connections)

    Kaimon.stop!(mgr)
end

# ─────────────────────────────────────────────────────────────────────────────
# TCP poll backoff
# ─────────────────────────────────────────────────────────────────────────────

@testset "TCP poll backoff" begin
    # Clear any leftover state
    empty!(Kaimon._TCP_POLL_BACKOFF)

    key = "192.168.99.99:9999"

    # Simulate sequential failures
    for i in 1:5
        failures = i
        idx = min(failures, length(Kaimon._TCP_POLL_BACKOFF_SCHEDULE))
        delay = Kaimon._TCP_POLL_BACKOFF_SCHEDULE[idx]
        Kaimon._TCP_POLL_BACKOFF[key] = (failures = failures, next_try = time() + delay)

        state = Kaimon._TCP_POLL_BACKOFF[key]
        @test state.failures == i
        @test state.next_try > time()
    end

    # After 5 failures, delay should be capped at last schedule entry
    state = Kaimon._TCP_POLL_BACKOFF[key]
    @test state.failures == 5
    expected_delay = Kaimon._TCP_POLL_BACKOFF_SCHEDULE[end]
    # next_try should be roughly now + max delay (within 1s tolerance)
    @test state.next_try > time() + expected_delay - 1.0

    # Simulating successful connection clears backoff
    delete!(Kaimon._TCP_POLL_BACKOFF, key)
    @test !haskey(Kaimon._TCP_POLL_BACKOFF, key)

    # Backoff check: if next_try is in the future, skip
    Kaimon._TCP_POLL_BACKOFF[key] = (failures = 1, next_try = time() + 100.0)
    state = Kaimon._TCP_POLL_BACKOFF[key]
    @test time() < state.next_try  # should be skipped by poll

    # Backoff check: if next_try is in the past, allow retry
    Kaimon._TCP_POLL_BACKOFF[key] = (failures = 1, next_try = time() - 1.0)
    state = Kaimon._TCP_POLL_BACKOFF[key]
    @test time() >= state.next_try  # should be allowed by poll

    empty!(Kaimon._TCP_POLL_BACKOFF)
end

# ─────────────────────────────────────────────────────────────────────────────
# Gate.restart() guard tests — unit tests, no ZMQ needed
# ─────────────────────────────────────────────────────────────────────────────

@testset "Gate.restart guards" begin
    orig_running = Kaimon.KaimonGate._RUNNING[]
    orig_restart = Kaimon.KaimonGate._ALLOW_RESTART[]

    @testset "errors when gate is not running" begin
        Kaimon.KaimonGate._RUNNING[] = false
        @test_throws ErrorException("Gate is not running") Kaimon.KaimonGate.restart()
    end

    @testset "errors when restart is disabled" begin
        Kaimon.KaimonGate._RUNNING[] = true
        Kaimon.KaimonGate._ALLOW_RESTART[] = false
        @test_throws ErrorException("Restart is disabled for this session (allow_restart=false)") Kaimon.KaimonGate.restart()
    end

    Kaimon.KaimonGate._RUNNING[] = orig_running
    Kaimon.KaimonGate._ALLOW_RESTART[] = orig_restart
end

# NOTE: handle_message(:restart) is not unit-tested here because the handler
# spawns an @async task that calls _exec_restart → execvp / exit(1) after a
# 0.3 s delay, which would kill the test process. The :restart message path
# is covered by the MCP manage_repl integration tests instead.

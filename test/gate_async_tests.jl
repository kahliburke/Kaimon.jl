using ReTest
using Kaimon
using ZMQ
using Serialization

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

"""Temporarily replace _SESSION_TOOLS[], restore on exit."""
function with_tools(f, tools)
    original = Kaimon.Gate._SESSION_TOOLS[]
    Kaimon.Gate._SESSION_TOOLS[] = tools
    try
        f()
    finally
        Kaimon.Gate._SESSION_TOOLS[] = original
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Unit tests — no ZMQ sockets needed
# ─────────────────────────────────────────────────────────────────────────────

@testset "Gate.handle_message :tool_call_async" begin

    @testset "unknown tool returns :error" begin
        with_tools(Kaimon.Gate.GateTool[]) do
            resp = Kaimon.Gate.handle_message((
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
        tool = Kaimon.Gate.GateTool("noop_tool", (msg::String) -> msg)
        with_tools([tool]) do
            rid = "req-accepted-42"
            resp = Kaimon.Gate.handle_message((
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
        tool = Kaimon.Gate.GateTool("noop_tool2", () -> "ok")
        with_tools([tool]) do
            resp = Kaimon.Gate.handle_message((
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
        @test_nowarn Kaimon.Gate.progress("no socket")
    end

    @testset "is a no-op without gate_request_id in task-local storage" begin
        result = @async begin
            # No task_local_storage(:gate_request_id, ...) set → rid is nothing → return
            Kaimon.Gate.progress("no request id set")
            :ok
        end
        @test fetch(result) == :ok
    end

    @testset "does not throw when called from inside a handler context" begin
        result = @async begin
            task_local_storage(:gate_request_id, "synthetic-req-id")
            # _STREAM_SOCKET[] is still nothing → _publish_stream is a no-op
            Kaimon.Gate.progress("synthetic progress")
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
    tool = Kaimon.Gate.GateTool("counted_op", function (n::Int)
        for i = 1:n
            Kaimon.Gate.progress("step $i of $n")
        end
        return "done:$n"
    end)

    # If a gate is already running (e.g. this test is run via `ex` inside a live
    # session), attach to it non-destructively: temporarily add the test tool to
    # the existing gate's tool list instead of stopping and restarting the gate.
    # Otherwise start a fresh gate for the test and stop it when done.
    was_running = Kaimon.Gate._RUNNING[]

    if was_running
        orig_tools = copy(Kaimon.Gate._SESSION_TOOLS[])
        session_id = Kaimon.Gate._SESSION_ID[]
        Kaimon.Gate._SESSION_TOOLS[] = vcat(orig_tools, [tool])
        # No sleep needed — sockets are already bound
    else
        session_id = "test-async-$(bytes2hex(rand(UInt8, 4)))"
        Kaimon.Gate._serve(name = "test", session_id = session_id, force = true, tools = [tool])
        # Give the gate a moment to bind its IPC sockets
        sleep(0.15)
    end

    sock_dir = Kaimon.Gate.SOCK_DIR
    rep_path = joinpath(sock_dir, "$session_id.sock")
    pub_path = joinpath(sock_dir, "$session_id-stream.sock")

    ctx = Context()
    req = Socket(ctx, REQ)
    sub = Socket(ctx, SUB)
    req.rcvtimeo = 5_000   # ms
    sub.rcvtimeo = 5_000

    connect(req, "ipc://$rep_path")
    connect(sub, "ipc://$pub_path")
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
            Kaimon.Gate._SESSION_TOOLS[] = orig_tools
        else
            Kaimon.Gate.stop()
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# TCP auth unit tests — validate handle_message token checking
# ─────────────────────────────────────────────────────────────────────────────

@testset "Gate TCP auth" begin
    orig_mode = Kaimon.Gate._MODE[]
    orig_token = Kaimon.Gate._AUTH_TOKEN[]

    @testset "IPC mode skips auth" begin
        Kaimon.Gate._MODE[] = :ipc
        Kaimon.Gate._AUTH_TOKEN[] = "secret123"
        resp = Kaimon.Gate.handle_message((type = :ping,))
        @test resp.type == :pong
    end

    @testset "TCP mode with empty token skips auth" begin
        Kaimon.Gate._MODE[] = :tcp
        Kaimon.Gate._AUTH_TOKEN[] = ""
        resp = Kaimon.Gate.handle_message((type = :ping,))
        @test resp.type == :pong
    end

    @testset "TCP mode rejects missing token" begin
        Kaimon.Gate._MODE[] = :tcp
        Kaimon.Gate._AUTH_TOKEN[] = "secret123"
        resp = Kaimon.Gate.handle_message((type = :ping,))
        @test resp.type == :error
        @test occursin("Authentication", resp.message)
    end

    @testset "TCP mode rejects wrong token" begin
        Kaimon.Gate._MODE[] = :tcp
        Kaimon.Gate._AUTH_TOKEN[] = "secret123"
        resp = Kaimon.Gate.handle_message((type = :ping, token = "wrong"))
        @test resp.type == :error
        @test occursin("Authentication", resp.message)
    end

    @testset "TCP mode accepts correct token" begin
        Kaimon.Gate._MODE[] = :tcp
        Kaimon.Gate._AUTH_TOKEN[] = "secret123"
        resp = Kaimon.Gate.handle_message((type = :ping, token = "secret123"))
        @test resp.type == :pong
    end

    @testset "pong includes stream_endpoint" begin
        Kaimon.Gate._MODE[] = :ipc
        Kaimon.Gate._AUTH_TOKEN[] = ""
        Kaimon.Gate._STREAM_ENDPOINT[] = "ipc:///tmp/test-stream.sock"
        resp = Kaimon.Gate.handle_message((type = :ping,))
        @test resp.type == :pong
        @test resp.stream_endpoint == "ipc:///tmp/test-stream.sock"
        Kaimon.Gate._STREAM_ENDPOINT[] = ""
    end

    Kaimon.Gate._MODE[] = orig_mode
    Kaimon.Gate._AUTH_TOKEN[] = orig_token
end

# ─────────────────────────────────────────────────────────────────────────────
# TCP gate integration test — ephemeral port + auth round-trip
# ─────────────────────────────────────────────────────────────────────────────

@testset "Gate TCP ephemeral port + auth" begin
    if Kaimon.Gate._RUNNING[]
        @info "Skipping TCP test — gate already running"
        @test_skip false
        return
    end

    token = "test_token_$(bytes2hex(rand(UInt8, 8)))"
    session_id = "test-tcp-$(bytes2hex(rand(UInt8, 4)))"

    Kaimon.Gate._AUTH_TOKEN[] = token
    Kaimon.Gate._serve(
        name = "test-tcp",
        session_id = session_id,
        force = true,
        mode = :tcp,
        host = "127.0.0.1",
        port = 0,
    )
    sleep(0.2)

    @test Kaimon.Gate._RUNNING[]
    @test Kaimon.Gate._MODE[] == :tcp

    sock = Kaimon.Gate._GATE_SOCKET[]
    @test sock !== nothing
    rep_endpoint = rstrip(ZMQ._get_last_endpoint(sock), '\0')
    @test startswith(rep_endpoint, "tcp://")

    @test !isempty(Kaimon.Gate._STREAM_ENDPOINT[])
    @test startswith(Kaimon.Gate._STREAM_ENDPOINT[], "tcp://")

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
        Kaimon.Gate.stop()
        sleep(0.1)
    end

    @test !Kaimon.Gate._RUNNING[]
    @test isempty(Kaimon.Gate._AUTH_TOKEN[])
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

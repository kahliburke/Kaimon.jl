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
    # Unique session so we don't collide with a real gate
    session_id = "test-async-$(bytes2hex(rand(UInt8, 4)))"

    tool = Kaimon.Gate.GateTool("counted_op", function (n::Int)
        for i = 1:n
            Kaimon.Gate.progress("step $i of $n")
        end
        return "done:$n"
    end)

    # Stop any existing gate before taking over the global state
    was_running = Kaimon.Gate._RUNNING[]
    if was_running
        Kaimon.Gate.stop()
        sleep(0.05)
    end

    Kaimon.Gate._serve(name = "test", session_id = session_id, force = true, tools = [tool])

    # Give the gate a moment to bind its IPC sockets
    sleep(0.15)

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
        Kaimon.Gate.stop()
    end
end

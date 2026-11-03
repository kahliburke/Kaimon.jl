# Waiting on a ZMQ socket without `rcvtimeo`: `_recv_within` and `_zmq_fd_watcher` (gate_state.jl).
# Loopback TCP, so the same file runs on Windows, where these replace paths that fail there.

using Test
using KaimonGate

const KG = KaimonGate
const ZMQ = KG.ZMQ

function _pair()
    ctx = ZMQ.Context()
    pull = ZMQ.Socket(ctx, ZMQ.PULL); pull.linger = 0
    ZMQ.bind(pull, "tcp://127.0.0.1:*")
    push = ZMQ.Socket(ctx, ZMQ.PUSH); push.linger = 0
    ZMQ.connect(push, rstrip(pull.last_endpoint, '\0'))
    return ctx, push, pull
end

_close(ctx, socks...) = (foreach(s -> try close(s) catch end, socks); try close(ctx) catch end)

@testset "_recv_within" begin
    ctx, push, pull = _pair()
    try
        @test pull.rcvtimeo == -1   # read without a socket timeout

        # Already queued: returned without waiting.
        ZMQ.send(push, "queued")
        @test String(KG._recv_within(pull, 2.0)) == "queued"

        # Nothing arrives: a TimeoutError after about the bound, not long after it.
        t0 = time()
        @test_throws ZMQ.TimeoutError KG._recv_within(pull, 0.2)
        @test 0.19 <= time() - t0 < 2.0

        # Arrives mid-wait: returned when it lands, not at the bound.
        @async (sleep(0.1); ZMQ.send(push, "late"))
        t0 = time()
        @test String(KG._recv_within(pull, 5.0)) == "late"
        @test time() - t0 < 2.0

        # Many short timeouts in a row (the owner loops' 5 ms busy cadence) leave the socket
        # working: a message sent afterwards is still received.
        timeouts = 0
        for _ in 1:200
            try
                KG._recv_within(pull, 0.005)
            catch e
                e isa ZMQ.TimeoutError && (timeouts += 1)
            end
        end
        @test timeouts == 200
        ZMQ.send(push, "after")
        @test String(KG._recv_within(pull, 2.0)) == "after"
    finally
        _close(ctx, push, pull)
    end
end

@testset "_zmq_fd_watcher fires on a readable socket" begin
    ctx, push, pull = _pair()
    try
        fdw = KG._zmq_fd_watcher(pull)
        try
            @test !KG._zmq_readable(pull)          # reading EVENTS also arms the edge
            woke = Threads.Atomic{Bool}(false)
            t = @async (wait(fdw); woke[] = true)
            ZMQ.send(push, "x")
            deadline = time() + 5.0
            while !woke[] && time() < deadline
                sleep(0.01)
            end
            @test woke[]
            @test KG._zmq_readable(pull)
            @test String(KG._zmq_recv(pull)) == "x"
        finally
            close(fdw)
        end
    finally
        _close(ctx, push, pull)
    end
end

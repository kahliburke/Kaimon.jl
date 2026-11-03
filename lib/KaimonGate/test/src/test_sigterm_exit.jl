# A gate exits promptly on SIGTERM, from both message-loop modes, idle or with a request still
# running. The exit runs the gate's `atexit` cleanup inside libuv's own loop, where nothing may
# wait on libuv; a regression there shows as a process that never exits.

using Test
using KaimonGate, Serialization, Sockets

const KG = KaimonGate
const ZMQ = KG.ZMQ
const GATE_DIR = dirname(dirname(pathof(KaimonGate)))

_free_port() = (s = Sockets.listen(Sockets.localhost, 0); p = Int(getsockname(s)[2]); close(s); p)

function _ping(d)
    io = IOBuffer(); serialize(io, (type = :ping,))
    ZMQ.send(d, UInt8[0x01]; more = true); ZMQ.send(d, take!(io))
    parts = [KG._recv_within(d, 5.0)]
    while d.rcvmore; push!(parts, KG._zmq_recv(d)); end
    return deserialize(IOBuffer(parts[end])).type === :pong
end

"Spawn a TCP gate, exercise it, SIGTERM it; return the seconds it took to exit, or `nothing`."
function _sigterm_exit_time(; owner_wake::Bool, inflight::Bool)
    port = _free_port()
    boot = """
    using KaimonGate
    KaimonGate.serve(mode = :tcp, host = "127.0.0.1", port = $port, stream_port = $(port + 1),
                     force = true, allow_mirror = false, spawned_by = "test")
    t = KaimonGate._gate_task(); t === nothing ? (while true; sleep(3600); end) : wait(t)
    """
    env = copy(ENV)
    env["KAIMON_GATE_MIRROR_REPL"] = "0"; env["JULIA_PROJECT"] = ""
    env["KAIMON_GATE_OWNER_WAKE"] = owner_wake ? "1" : "0"
    p = run(pipeline(Cmd(`$(joinpath(Sys.BINDIR, "julia")) --project=$GATE_DIR -t 2,1 --startup-file=no -e $boot`; env);
                     stdout = devnull, stderr = devnull); wait = false)
    ctx = ZMQ.Context()
    d = ZMQ.Socket(ctx, ZMQ.DEALER); d.linger = 0
    ZMQ.connect(d, "tcp://127.0.0.1:$port")
    try
        up = false
        deadline = time() + 120
        while !up && time() < deadline && !process_exited(p)
            up = try _ping(d) catch; false end
        end
        up || return nothing
        for _ in 1:20; _ping(d); end
        if inflight
            io = IOBuffer(); serialize(io, (type = :eval, code = "sleep(30); 1"))
            ZMQ.send(d, UInt8[0x02]; more = true); ZMQ.send(d, take!(io))
            sleep(1.0)
        end
        kill(p)
        t0 = time()
        while !process_exited(p) && time() - t0 < 10.0
            sleep(0.05)
        end
        return process_exited(p) ? time() - t0 : nothing
    finally
        process_exited(p) || kill(p, 9)
        close(d); close(ctx)
    end
end

@testset "gate exits on SIGTERM" begin
    if Sys.iswindows()
        @test_skip "SIGTERM is TerminateProcess on Windows; there is no atexit path to test"
    else
        for owner_wake in (false, true), inflight in (false, true)
            dt = _sigterm_exit_time(; owner_wake, inflight)
            @test dt !== nothing && dt < 10.0
        end
    end
end

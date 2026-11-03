# Control-plane supervision, the parts checkable without a live Kaimon: ZMQ error
# classification, worker-slot accounting, the supervisor's lifecycle gate, and
# _ensure_router! against a real socket. test_integration.jl covers the loop itself.

using Test
using KaimonGate
using Serialization

const KG = KaimonGate
const ZMQ = KG.ZMQ

# ── ZMQ.StateError classification ─────────────────────────────────────────────
# Messages are built the way ZMQ.jl builds them (libzmq's zmq_strerror).

@testset "ZMQ error disposition" begin
    eintr = ZMQ.StateError(KG._zmq_errno_msg(Base.Libc.EINTR))
    @test KG._zmq_error_disposition(eintr) === :retry
    @test KG._zmq_error_disposition(ZMQ.StateError("Interrupted system call")) === :retry

    eterm = ZMQ.StateError(KG._zmq_errno_msg(ZMQ.lib.ETERM))
    @test KG._zmq_error_disposition(eterm) === :restart
    enotsock = ZMQ.StateError(KG._zmq_errno_msg(Base.Libc.ENOTSOCK))
    @test KG._zmq_error_disposition(enotsock) === :restart
    # Unrecognised text goes to the supervisor too.
    @test KG._zmq_error_disposition(ZMQ.StateError("some new libzmq condition")) === :restart
end

# ── Worker-slot accounting ────────────────────────────────────────────────────

function _drain_outbox!()
    while isready(KG._gate_outbox())
        take!(KG._gate_outbox())
    end
end

@testset "_serve_request releases its slot and always replies" begin
    # A session, because handling a request bumps the per-session message and ping counters.
    saved = KG._SESSION[]
    KG._SESSION[] = KG.GateSession(; running = true)
    try
        _drain_outbox!()
        base = KG._gate_inflight()[]
        dbase = KG._gate_default_inflight()[]
        id, cid = UInt8[1, 2], UInt8[3, 4]
        take_slot!() = (Threads.atomic_add!(KG._gate_inflight(), 1); Threads.atomic_add!(KG._gate_default_inflight(), 1))
        released() = KG._gate_inflight()[] == base && KG._gate_default_inflight()[] == dbase

        # Normal path: a ping is handled, replied to, and the slot comes back.
        take_slot!()
        KG._serve_request(id, cid, (type = :ping,))
        @test released()
        (rid, rcid, bytes) = take!(KG._gate_outbox())
        @test rid == id && rcid == cid
        @test deserialize(IOBuffer(bytes)).type === :pong
        @test KG._ping_count() == 1        # counted against this session, not a global

        # handle_message cannot dispatch a non-NamedTuple: error reply, slot released.
        take_slot!()
        KG._serve_request(id, cid, Dict(:type => :ping))
        @test released()
        reply = deserialize(IOBuffer(take!(KG._gate_outbox())[3]))
        @test reply.type === :error

        # An unknown request type is still a reply, not a leaked slot.
        take_slot!()
        KG._serve_request(id, cid, (type = :no_such_message,))
        @test released()
        @test isready(KG._gate_outbox())
        _drain_outbox!()

        # A routed request holds only the overall count, never a default-lane slot.
        Threads.atomic_add!(KG._gate_inflight(), 1)
        KG._serve_request(id, cid, (type = :ping,), false)
        @test released()
        _drain_outbox!()
    finally
        KG._SESSION[] = saved
    end
end

# ── Supervisor lifecycle gate ─────────────────────────────────────────────────
# stop, restart, :shutdown and :restart each clear _running() and may raise
# `shutting_down` or `restarting` first; the supervisor must stand down on any of them.

@testset "_gate_should_run honours every lifecycle flag" begin
    saved = KG._SESSION[]     # all three flags live on the session, so this restores them all
    try
        # A session with no sockets is enough: the supervisor only reads flags.
        KG._SESSION[] = KG.GateSession(; running = true)
        @test KG._gate_should_run()
        KG._shutting_down!(true)
        @test !KG._gate_should_run()
        KG._shutting_down!(false); KG._restarting!(true)
        @test !KG._gate_should_run()
        KG._restarting!(false); KG._running!(false)
        @test !KG._gate_should_run()
        # Dropping the session is the other way to stop being runnable, and it is the one
        # _cleanup uses.
        KG._running!(true)
        KG._SESSION[] = nothing
        @test !KG._gate_should_run()
        # The fault-path backoff returns as soon as the gate is asked to stop.
        KG._SESSION[] = KG.GateSession(; running = true)
        t = @elapsed begin
            @async (sleep(0.1); KG._running!(false))
            KG._sleep_while_running(5.0)
        end
        @test t < 2.0
    finally
        KG._SESSION[] = saved
    end
end

# ── The supervisor's whole point: a fault is respawned, not fatal ─────────────
# This is the behaviour #86 was about — the owner loop exiting left the gate bound, RUNNING
# and deaf for the rest of the process — and it is the one thing the supervision work could
# not cover, because there was no way to build gate state without binding a real gate. A
# session makes it cheap: bind one ROUTER, run the supervisor over it, kill the socket
# underneath, and watch the gate answer again on the same endpoint.

@testset "a message-loop fault is respawned on a rebound socket" begin
    if KG._running() || Sys.iswindows()
        @test_skip true
    else
        saved = KG._SESSION[]
        ctx = ZMQ.Context()
        sid = "test-respawn-$(bytes2hex(rand(UInt8, 4)))"
        path = joinpath(KG.sock_dir(), "$sid.sock")
        sup = nothing
        try
            KG._SESSION[] = KG.GateSession(; running = true, mode = :ipc, id = sid,
                                           context = ctx)
            s = KG._zmq_socket(ctx, ZMQ.ROUTER)
            KG._configure_router_socket!(s; curve = false, allow_any = false,
                                         server_secret = "")
            ZMQ.bind(s, "ipc://$path")
            KG._gate_socket!(s)

            sup = Threads.@spawn KG._supervise_message_loop(s)
            sleep(0.3)                       # let the loop settle into its recv

            # Kill the socket under the loop. recv then fails with a disposition the loop
            # hands to the supervisor rather than swallowing — the path #87 added.
            close(s)

            # The supervisor rebinds and respawns, so the session ends up holding a
            # DIFFERENT, live socket. Before #87 it held the same dead one, forever.
            rebound = nothing
            for _ in 1:200
                s2 = KG._gate_socket()
                if s2 !== nothing && s2 !== s && isopen(s2)
                    rebound = s2; break
                end
                sleep(0.05)
            end
            @test rebound !== nothing
            @test !istaskdone(sup)           # the supervisor is still supervising

            # …and the respawned loop actually serves on the same endpoint: a DEALER sends
            # [corr_id, payload] and gets its correlation id back with a :pong.
            d = ZMQ.Socket(ctx, ZMQ.DEALER); d.linger = 0
            ZMQ.connect(d, "ipc://$path")
            corr = UInt8[0x11, 0x22]
            io = IOBuffer(); serialize(io, (type = :ping,))
            ZMQ.send(d, corr; more = true)
            ZMQ.send(d, take!(io))
            parts = KG._recv_multipart(d, 5.0)
            @test parts[1] == corr           # answered our request, not someone else's
            @test deserialize(IOBuffer(parts[end])).type === :pong
            close(d)
        finally
            KG._running!(false)              # stand the supervisor down
            sup === nothing || (try; wait(sup); catch; end)
            try; close(KG._gate_socket()); catch; end
            KG._SESSION[] = saved
            try; close(ctx); catch; end
            rm(path; force = true)
        end
    end
end

# ── Rebind helper against a real socket (no Kaimon involved) ──────────────────

@testset "_ensure_router! keeps a live socket and rebinds a dead one" begin
    if KG._running() || Sys.iswindows()
        @test_skip true
    else
        saved = KG._SESSION[]
        ctx = ZMQ.Context()
        sid = "test-rebind-$(bytes2hex(rand(UInt8, 4)))"
        path = joinpath(KG.sock_dir(), "$sid.sock")
        try
            # The context and socket are session fields, so they go in at construction:
            # _ensure_router! rebuilds the endpoint from the session's mode and id, and
            # takes the context from it too.
            KG._SESSION[] = KG.GateSession(; running = true, mode = :ipc, id = sid,
                                           context = ctx)
            s = KG._zmq_socket(ctx, ZMQ.ROUTER)
            KG._configure_router_socket!(s; curve = false, allow_any = false,
                                         server_secret = "")
            ZMQ.bind(s, "ipc://$path")
            KG._gate_socket!(s)

            # Live socket: returned untouched.
            @test KG._ensure_router!(s) === s
            @test KG._gate_socket() === s

            # Dead socket (the ENOTSOCK case): rebound on the same endpoint with
            # the same options.
            close(s)
            s2 = @test_logs (:warn, r"rebound") KG._ensure_router!(s)
            @test s2 !== s
            @test isopen(s2)
            @test KG._gate_socket() === s2
            @test ispath(path)
            @test s2.linger == 0

            # A client reaches the rebound endpoint.
            d = ZMQ.Socket(ctx, ZMQ.DEALER)
            d.linger = 0
            ZMQ.connect(d, "ipc://$path")
            ZMQ.send(d, "hello")
            parts = KG._recv_multipart(s2, 2.0)
            @test String(parts[end]) == "hello"
            close(d)
            close(s2)
        finally
            KG._SESSION[] = saved     # context and socket ride on the session
            try; close(ctx); catch; end
            rm(path; force = true)
        end
    end
end

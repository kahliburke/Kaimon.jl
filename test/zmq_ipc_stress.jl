# ZMQ IPC transport stress test
#
# Exercises ZMQ ipc:// transport under heavy load to validate the
# Gate communication patterns (PUB/SUB + REP/REQ) hold up under stress.
#
# Tests:
#   1. High-volume single producer over IPC
#   2. Multi-threaded concurrent producers
#   3. Simultaneous PUB flood + REP request handling
#   4. Two-process IPC (child hosts ZMQ server, parent connects)
#   5. IPC with heavy compilation + GC pressure
#   6. Rapid IPC start/stop cycles
#
# Run: julia --project -t4 test/zmq_ipc_stress.jl [scale]

using ZMQ
using Serialization
using FileWatching: poll_fd
using Test

const N_THREADS = Threads.nthreads()
const SCALE = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 1
const SOCK_DIR = mktempdir()

println("Julia threads: $N_THREADS, scale: $(SCALE)x")
println("Socket dir: $SOCK_DIR")
println()

# ── Helpers ───────────────────────────────────────────────────────────────

function ipc_endpoint(name)
    path = joinpath(SOCK_DIR, "$name.sock")
    isfile(path) && rm(path; force=true)
    return "ipc://$path"
end

function make_pub(ctx, endpoint)
    pub = Socket(ctx, PUB)
    pub.linger = 0
    pub.sndhwm = 0
    ZMQ.bind(pub, endpoint)
    return pub
end

function make_sub(ctx, endpoint; timeout_ms=3000)
    sub = Socket(ctx, SUB)
    sub.linger = 0
    sub.rcvhwm = 0
    sub.rcvtimeo = timeout_ms
    ZMQ.subscribe(sub, "")
    ZMQ.connect(sub, endpoint)
    return sub
end

function make_rep(ctx, endpoint)
    rep = Socket(ctx, REP)
    rep.linger = 0
    rep.rcvtimeo = 0
    ZMQ.bind(rep, endpoint)
    return rep
end

function make_req(ctx, endpoint; timeout_ms=5000)
    req = Socket(ctx, REQ)
    req.linger = 0
    req.rcvtimeo = timeout_ms
    ZMQ.connect(req, endpoint)
    return req
end

"""IO loop: drain outbox → PUB, poll REP for requests."""
function run_io_loop(
    pub::Socket, rep::Socket,
    outbox::Channel{Vector{UInt8}},
    rep_inbox::Channel,
)::Int
    rep_fd = RawFD(ZMQ._get_fd(rep))
    pub_sent = 0
    while true
        batch = 0
        while isready(outbox) && batch < 64
            packed = try; take!(outbox); catch; break; end
            try
                send(pub, packed)
                pub_sent += 1
            catch e
                (e isa StateError || e isa EOFError) || @warn "PUB send error" exception=e
            end
            batch += 1
        end
        !isopen(outbox) && !isready(outbox) && break
        has_data = ZMQ._get_events(rep) & ZMQ.POLLIN != 0
        if !has_data
            timeout = isready(outbox) ? 0.0 : 0.05
            result = poll_fd(rep_fd, timeout; readable=true, writable=false)
            has_data = result.readable || ZMQ._get_events(rep) & ZMQ.POLLIN != 0
        end
        if has_data
            try
                data = recv(rep)
                msg = deserialize(IOBuffer(data))
                put!(rep_inbox, msg)
                io = IOBuffer()
                serialize(io, (ack=true,))
                send(rep, Message(take!(io)))
            catch e
                (e isa StateError || e isa EOFError || e isa Base.IOError || e isa ZMQ.TimeoutError) || @warn "REP error" exception=e
            end
        end
    end
    return pub_sent
end

function drain_sub(sub::Socket, expected::Int)::Int
    received = 0
    while received < expected
        try
            data = recv(sub)
            msg = deserialize(IOBuffer(data))
            haskey(msg, :seq) && (received += 1)
        catch
            break
        end
    end
    return received
end

function pack(msg)
    io = IOBuffer()
    serialize(io, msg)
    take!(io)
end

# ── Test 1: High-volume IPC single producer ──────────────────────────────

@testset "IPC high-volume single producer" begin
    ctx = Context()
    pub_ep = ipc_endpoint("t1-pub")
    rep_ep = ipc_endpoint("t1-rep")
    pub = make_pub(ctx, pub_ep)
    rep = make_rep(ctx, rep_ep)
    sub = make_sub(ctx, pub_ep)
    sleep(0.1)  # IPC needs a moment for connection

    outbox = Channel{Vector{UInt8}}(4096)
    rep_inbox = Channel{Any}(64)
    io_task = Threads.@spawn :interactive run_io_loop(pub, rep, outbox, rep_inbox)

    n_msgs = 5_000 * SCALE
    for i in 1:n_msgs
        put!(outbox, pack((seq=i,)))
    end
    while isready(outbox); sleep(0.01); end
    sleep(0.2)

    received = drain_sub(sub, n_msgs)
    close(outbox)
    pub_sent = fetch(io_task)

    @test pub_sent == n_msgs
    @test received == n_msgs
    println("  IPC single producer: sent $pub_sent, received $received / $n_msgs")

    close(sub); close(pub); close(rep); close(ctx)
end

# ── Test 2: IPC multi-threaded concurrent producers ──────────────────────

@testset "IPC multi-threaded concurrent producers" begin
    ctx = Context()
    pub_ep = ipc_endpoint("t2-pub")
    rep_ep = ipc_endpoint("t2-rep")
    pub = make_pub(ctx, pub_ep)
    rep = make_rep(ctx, rep_ep)
    sub = make_sub(ctx, pub_ep; timeout_ms=5000)
    sleep(0.1)

    outbox = Channel{Vector{UInt8}}(4096)
    rep_inbox = Channel{Any}(64)
    io_task = Threads.@spawn :interactive run_io_loop(pub, rep, outbox, rep_inbox)

    msgs_per_thread = 1_000 * SCALE
    n_producers = max(min(N_THREADS - 1, 4), 2)
    total_expected = msgs_per_thread * n_producers

    tasks = [Threads.@spawn begin
        for i in 1:msgs_per_thread
            try; put!(outbox, pack((seq=i, t=t))); catch; break; end
        end
    end for t in 1:n_producers]
    foreach(wait, tasks)

    while isready(outbox); sleep(0.01); end
    sleep(0.2)

    received = 0
    while received < total_expected
        try
            data = recv(sub)
            msg = deserialize(IOBuffer(data))
            haskey(msg, :seq) && (received += 1)
        catch; break; end
    end

    close(outbox)
    pub_sent = fetch(io_task)

    @test pub_sent == total_expected
    @test received == total_expected
    println("  IPC $n_producers producers x $msgs_per_thread = $total_expected, received $received")

    close(sub); close(pub); close(rep); close(ctx)
end

# ── Test 3: IPC simultaneous PUB + REP ───────────────────────────────────

@testset "IPC simultaneous PUB flood + REP requests" begin
    ctx = Context()
    pub_ep = ipc_endpoint("t3-pub")
    rep_ep = ipc_endpoint("t3-rep")
    pub = make_pub(ctx, pub_ep)
    rep = make_rep(ctx, rep_ep)
    sub = make_sub(ctx, pub_ep; timeout_ms=5000)
    req = make_req(ctx, rep_ep; timeout_ms=10000)
    sleep(0.1)

    outbox = Channel{Vector{UInt8}}(4096)
    rep_inbox = Channel{Any}(1024)
    io_task = Threads.@spawn :interactive run_io_loop(pub, rep, outbox, rep_inbox)

    n_pub = 3_000 * SCALE
    n_req = 100 * SCALE

    handler = @async begin
        count = 0
        while true
            try; take!(rep_inbox); count += 1; catch; break; end
        end
        count
    end

    producer = Threads.@spawn begin
        for i in 1:n_pub
            try; put!(outbox, pack((seq=i,))); catch; break; end
        end
    end

    req_acks = 0
    for i in 1:n_req
        try
            io = IOBuffer(); serialize(io, (req_seq=i,))
            send(req, Message(take!(io)))
            reply = deserialize(IOBuffer(recv(req)))
            reply.ack == true && (req_acks += 1)
        catch e
            @warn "REQ failed at $i" exception=e
            break
        end
    end

    wait(producer)
    while isready(outbox); sleep(0.01); end
    sleep(0.2)

    pub_received = drain_sub(sub, n_pub)
    close(outbox)
    pub_sent = fetch(io_task)
    close(rep_inbox)
    rep_count = try; fetch(handler); catch; 0; end

    @test pub_sent == n_pub
    @test pub_received == n_pub
    @test req_acks == n_req
    println("  IPC PUB: $pub_sent/$n_pub, REQ: $req_acks/$n_req, REP handled: $rep_count")

    close(sub); close(req); close(pub); close(rep); close(ctx)
end

# ── Test 4: Two-process IPC (child hosts ZMQ, parent sends/recvs) ────────

@testset "Two-process IPC" begin
    rep_ep = ipc_endpoint("t4-rep")
    pub_ep = ipc_endpoint("t4-pub")
    n_roundtrips = 200 * SCALE
    n_pub = 1_000 * SCALE

    # Child script: runs ZMQ server (REP + PUB) in a separate process
    child_script = """
    using ZMQ, Serialization
    rep_ep = ARGS[1]
    pub_ep = ARGS[2]
    n_roundtrips = parse(Int, ARGS[3])
    n_pub = parse(Int, ARGS[4])

    ctx = Context()
    rep = Socket(ctx, REP)
    rep.linger = 0
    ZMQ.bind(rep, rep_ep)

    pub = Socket(ctx, PUB)
    pub.linger = 0
    pub.sndhwm = 0
    ZMQ.bind(pub, pub_ep)

    println("READY")
    flush(stdout)

    # Publish messages in background
    pub_task = @async begin
        for i in 1:n_pub
            io = IOBuffer(); serialize(io, (seq=i,))
            try; send(pub, Message(take!(io))); catch; break; end
            i % 100 == 0 && yield()
        end
    end

    # Handle REP requests
    for _ in 1:n_roundtrips
        try
            data = recv(rep)
            msg = deserialize(IOBuffer(data))
            io = IOBuffer()
            serialize(io, (ack=true, echo=msg.val))
            send(rep, Message(take!(io)))
        catch e
            println(stderr, "child REP error: \$e")
            break
        end
    end

    wait(pub_task)
    close(rep); close(pub); close(ctx)
    """

    child_file = joinpath(SOCK_DIR, "child_server.jl")
    write(child_file, child_script)

    kaimon_dir = dirname(@__DIR__)
    cmd = `$(Base.julia_cmd()) --project=$kaimon_dir --startup-file=no $child_file $rep_ep $pub_ep $n_roundtrips $n_pub`
    child_out = Pipe()
    proc = run(pipeline(cmd, stdout=child_out, stderr=stderr), wait=false)
    close(child_out.in)

    # Wait for READY
    line = readline(child_out.out)
    @test line == "READY"
    sleep(0.1)

    # Parent: connect as client
    ctx = Context()
    req = make_req(ctx, rep_ep; timeout_ms=10000)
    sub = make_sub(ctx, pub_ep; timeout_ms=5000)
    sleep(0.1)

    # Send REQ/REP roundtrips
    req_ok = 0
    for i in 1:n_roundtrips
        try
            io = IOBuffer(); serialize(io, (val=i,))
            send(req, Message(take!(io)))
            reply = deserialize(IOBuffer(recv(req)))
            reply.ack == true && reply.echo == i && (req_ok += 1)
        catch e
            @warn "parent REQ failed at $i" exception=e
            break
        end
    end

    # Drain PUB
    pub_received = drain_sub(sub, n_pub)

    @test req_ok == n_roundtrips
    @test pub_received == n_pub
    println("  Two-process IPC: $req_ok/$n_roundtrips roundtrips, $pub_received/$n_pub pub msgs")

    close(sub); close(req); close(ctx)
    wait(proc)
end

# ── Test 5: IPC + heavy compilation + GC pressure ────────────────────────
#
# Stress tests ZMQ IPC under conditions similar to real Kaimon usage:
#   - Separate process continuously pings IPC REP socket (like TUI health checker)
#   - Main process does heavy type-parameterized compilation + GC pressure
#   - ZMQ I/O thread active while JIT compiler and GC are under load

@testset "IPC + heavy compilation + GC stress" begin
    rep_ep = ipc_endpoint("t5-rep")
    pub_ep = ipc_endpoint("t5-pub")

    # Child process: continuously pings the REP socket (mimics TUI health checker)
    pinger_script = """
    using ZMQ, Serialization
    rep_ep = ARGS[1]
    pub_ep = ARGS[2]
    duration = parse(Float64, ARGS[3])

    ctx = Context()
    req = Socket(ctx, REQ)
    req.linger = 0
    req.rcvtimeo = 2000
    ZMQ.connect(req, rep_ep)

    sub = Socket(ctx, SUB)
    sub.linger = 0
    sub.rcvtimeo = 100
    ZMQ.subscribe(sub, "")
    ZMQ.connect(sub, pub_ep)

    println("PINGER_READY")
    flush(stdout)

    function make_req_sock(ctx, ep)
        req = Socket(ctx, REQ)
        req.linger = 0
        req.rcvtimeo = 500
        req.sndtimeo = 500
        ZMQ.connect(req, ep)
        return req
    end

    function run_pinger(ctx, rep_ep, sub, duration)
        pings = 0
        pongs = 0
        pub_recv = 0
        req = make_req_sock(ctx, rep_ep)
        t0 = time()
        while time() - t0 < duration
            ok = false
            try
                io = IOBuffer()
                serialize(io, (type=:ping, ts=time()))
                send(req, Message(take!(io)))
                reply = recv(req)
                msg = deserialize(IOBuffer(reply))
                pongs += 1
                ok = true
            catch
            end
            pings += 1
            # REQ socket is stuck after recv timeout — recreate it
            if !ok
                try; close(req); catch; end
                req = make_req_sock(ctx, rep_ep)
            end

            while true
                try
                    recv(sub)
                    pub_recv += 1
                catch
                    break
                end
            end

            sleep(0.05)
        end
        try; close(req); catch; end
        return pings, pongs, pub_recv
    end
    pings, pongs, pub_recv = run_pinger(ctx, rep_ep, sub, duration)
    println("PINGER_DONE pings=\$pings pongs=\$pongs pub=\$pub_recv")
    flush(stdout)
    close(sub); close(ctx)
    """

    pinger_file = joinpath(SOCK_DIR, "pinger.jl")
    write(pinger_file, pinger_script)

    # Server side: REP + PUB sockets in THIS process (ZMQ C threads here)
    # Create multiple ZMQ contexts to amplify the foreign C thread count.
    # Each Context() spawns a Reaper thread + I/O worker thread.
    # Eva + SMMonitoring + Kaimon = 3 contexts in practice.
    extra_contexts = [Context() for _ in 1:3]
    # Bind dummy sockets so the I/O threads have work registered
    extra_sockets = Socket[]
    for (i, ectx) in enumerate(extra_contexts)
        ep = ipc_endpoint("t5-extra-$i")
        s = Socket(ectx, PUB)
        s.linger = 0
        ZMQ.bind(s, ep)
        push!(extra_sockets, s)
    end

    ctx = Context()
    pub = make_pub(ctx, pub_ep)
    rep = make_rep(ctx, rep_ep)
    sleep(0.05)

    outbox = Channel{Vector{UInt8}}(4096)
    rep_inbox = Channel{Any}(256)
    io_task = Threads.@spawn :interactive run_io_loop(pub, rep, outbox, rep_inbox)

    # Handler drains rep_inbox and counts pings
    # Must be @spawn (not @async) — main thread is busy compiling and can't yield
    ping_count = Threads.Atomic{Int}(0)
    handler = Threads.@spawn begin
        while true
            try
                take!(rep_inbox)
                Threads.atomic_add!(ping_count, 1)
            catch
                break
            end
        end
    end

    # Start pinger child process
    compile_duration = 15.0 * SCALE
    kaimon_dir = dirname(@__DIR__)
    pinger_cmd = `$(Base.julia_cmd()) --project=$kaimon_dir --startup-file=no $pinger_file $rep_ep $pub_ep $compile_duration`
    pinger_out = Pipe()
    pinger_proc = run(pipeline(pinger_cmd, stdout=pinger_out, stderr=stderr), wait=false)
    close(pinger_out.in)

    ready_line = readline(pinger_out.out)
    @test ready_line == "PINGER_READY"
    sleep(0.2)

    # ── Heavy compilation + GC on the main thread ────────────────────────
    # Deeply nested parametric types, @generated functions with Cartesian
    # unrolling, fresh struct types, and heavy allocation/GC pressure —
    # all while ZMQ C threads are active.

    # Pre-define a @generated function that forces Cartesian unrolling
    # (like Eva's get_prefix_count with NTuple{H, Head})
    Core.eval(Main, quote
        @generated function _stress_unroll(::Val{N}, data::NTuple{N, Float64}) where {N}
            exprs = [:(s += data[$i] * $i) for i in 1:N]
            quote
                s = 0.0
                $(exprs...)
                return s
            end
        end
    end)

    compile_rounds = 0
    gc_collections = 0
    t0 = time()

    while time() - t0 < compile_duration
        # 1. Deeply nested parametric types (like StaticArrays in physics code)
        for N in 2:8
            T = NTuple{N, Float64}
            val = ntuple(Float64, N)
            arr = Vector{T}(undef, 100)
            fill!(arr, val)
            sort!(arr; by=x -> x[1])

            # Dict with parametric key/value
            d = Dict{NTuple{N,Int}, Vector{T}}()
            for j in 1:10
                key = ntuple(i -> i + j, N)
                d[key] = [ntuple(i -> Float64(i * j), N) for _ in 1:20]
            end

            # Serialize/deserialize (exercises type reconstruction in the compiler)
            buf = IOBuffer()
            serialize(buf, d)
            seekstart(buf)
            d2 = deserialize(buf)
        end

        # 2. Generate unique struct types + @generated specializations each round
        sym = Symbol("_StressType_$(compile_rounds)")
        Core.eval(Main, quote
            struct $sym{T, N}
                data::NTuple{N, T}
                meta::Dict{Symbol, Any}
            end
        end)
        ST = Core.eval(Main, sym)

        # Force method compilation on the new type
        for N in (2, 4, 6, 8, 16, 32)
            inst = Base.invokelatest(ST{Float64, N}, ntuple(Float64, N), Dict(:round => compile_rounds))
            buf = IOBuffer()
            Base.invokelatest(show, buf, inst)
            # Trigger @generated unrolling for each N (new specialization each time)
            Base.invokelatest(Core.eval(Main, :(_stress_unroll)), Val(N), ntuple(Float64, N))
        end

        # 3. Generate unique @generated functions to force fresh LLVM codegen
        if compile_rounds % 5 == 0
            gsym = Symbol("_stress_gen_$(compile_rounds)")
            Core.eval(Main, quote
                @generated function $gsym(x::NTuple{N, T}) where {N, T}
                    exprs = [:(acc += x[$i]^2 + sin(x[$i])) for i in 1:N]
                    quote
                        acc = zero($T)
                        $(exprs...)
                        return acc
                    end
                end
            end)
            gf = Core.eval(Main, gsym)
            for N in (4, 8, 16, 32, 64)
                Base.invokelatest(gf, ntuple(Float64, N))
            end
        end

        # 4. Allocate and drop lots of objects → GC pressure
        for _ in 1:50
            v = [rand(100, 100) for _ in 1:5]  # ~400KB per iteration
            sum(sum.(v))  # prevent optimization
        end

        # 5. Explicit GC to trigger stop-the-world
        if compile_rounds % 3 == 0
            GC.gc(false)  # minor collection
            gc_collections += 1
        end
        if compile_rounds % 10 == 0
            GC.gc(true)   # full collection
            gc_collections += 1
        end

        # 6. PUB some data while compiling (exercises I/O thread)
        for i in 1:10
            try; put!(outbox, pack((seq=compile_rounds * 10 + i,))); catch; break; end
        end

        compile_rounds += 1
    end

    # Wait for pinger to finish
    done_line = readline(pinger_out.out)
    wait(pinger_proc)
    close(outbox)
    fetch(io_task)
    close(rep_inbox)
    try; wait(handler); catch; end

    println("  Compilation rounds: $compile_rounds")
    println("  GC collections: $gc_collections")
    println("  Pings handled: $(ping_count[])")
    println("  Pinger: $done_line")
    @test compile_rounds > 0
    @test ping_count[] > 0
    println("  ZMQ IPC + heavy compilation + GC stress passed")

    close(pub); close(rep); close(ctx)
    for s in extra_sockets; try; close(s); catch; end; end
    for c in extra_contexts; try; close(c); catch; end; end
end

# ── Test 6: Rapid IPC start/stop cycles ──────────────────────────────────

@testset "Rapid IPC start/stop cycles" begin
    n_cycles = 20 * SCALE
    for cycle in 1:n_cycles
        ctx = Context()
        pub = make_pub(ctx, ipc_endpoint("t6-c$cycle-pub"))
        rep = make_rep(ctx, ipc_endpoint("t6-c$cycle-rep"))

        outbox = Channel{Vector{UInt8}}(64)
        rep_inbox = Channel{Any}(64)
        io_task = Threads.@spawn :interactive run_io_loop(pub, rep, outbox, rep_inbox)

        for i in 1:10
            put!(outbox, pack((cycle=cycle, i=i)))
        end
        close(outbox)
        fetch(io_task)

        close(pub); close(rep); close(ctx)
    end
    @test true
    println("  $n_cycles rapid IPC start/stop cycles completed")
end

# ── Cleanup ──────────────────────────────────────────────────────────────
rm(SOCK_DIR; recursive=true, force=true)
println("\n=== All IPC stress tests passed ===")

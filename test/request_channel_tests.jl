# Integration test for the protocol-v2 request path: a single persistent DEALER
# per connection (client) multiplexed by correlation id onto a ROUTER (gate),
# replacing the per-request ephemeral REQ that drove the `gc_sweep_pool` heap
# corruption.
#
# This runs a gate (KaimonGate.serve) and a client (ConnectionManager) together
# in a multithreaded subprocess against a throwaway cache dir, and asserts:
#   - request/reply round-trips (ping, sync eval),
#   - correlation under heavy concurrency (N distinct evals, each gets ITS answer
#     — no cross-talk between correlation ids),
#   - ctx.sockets stays bounded across many requests (the regression metric — the
#     bug was unbounded per-request socket growth),
#   - disconnect fails in-flight callers fast instead of hanging to timeout.
# A clean exit + the RC_OK marker means all assertions held.

using ReTest
using Kaimon

@testset "Request channel (protocol v2 DEALER/ROUTER)" begin
    proj = pkgdir(Kaimon)
    @test proj !== nothing

    script = raw"""
        using Kaimon
        const K = Kaimon
        const KG = Kaimon.KaimonGate

        # Short base dir: IPC socket paths must fit the ~104-char Unix sun_path
        # limit, so avoid macOS's long /var/folders default tempdir.
        shortbase = Sys.iswindows() ? tempdir() : "/tmp"
        mktempdir(shortbase) do dir
            ENV["XDG_CACHE_HOME"] = dir
            sid = KG.serve(force = true)
            @assert KG.PROTOCOL_VERSION == 2

            mgr = K.ConnectionManager(; sock_dir = KG.sock_dir())
            K.start!(mgr)

            conn = nothing
            t0 = time()
            while time() - t0 < 10
                cs = K.connected_sessions(mgr)
                isempty(cs) || (conn = cs[1]; break)
                sleep(0.2)
            end
            conn === nothing && error("client never connected to in-process gate")
            @assert conn.req_channel !== nothing "no request channel after connect"

            # 1. ping + sync eval round-trip
            @assert K.ping(conn) !== nothing "ping returned nothing"
            r = K.eval_remote(conn, "1 + 1")
            @assert contains(string(r.value_repr), "2") "eval 1+1: $(r.value_repr) / $(r.exception)"

            # 2. correlation under concurrency: N distinct evals at once, each must
            #    receive its own answer (proves no corr-id cross-talk).
            N = 64
            tasks = [Threads.@spawn K.eval_remote(conn, "$(i) * 7"; timeout_ms = 15000) for i in 1:N]
            res = [fetch(t) for t in tasks]
            bad = [(i, res[i].value_repr) for i in 1:N if !contains(string(res[i].value_repr), string(i * 7))]
            @assert isempty(bad) "correlation cross-talk/failures: $(first(bad, 5))"

            # 3. socket array stays bounded across many requests (THE regression).
            ctx = conn.zmq_context
            before = length(getfield(ctx, :sockets))
            for _ in 1:500; K.ping(conn); end
            GC.gc()
            after = length(getfield(ctx, :sockets))
            @assert after <= before + 2 "ctx.sockets grew per-request: $before -> $after"

            # 3b. no reply is lost while another caller is sending. A send() can take the
            #     DEALER fd's readability signal for a reply that has just arrived, so a
            #     reader parked on the fd alone leaves that reply unread until something
            #     else touches the socket. A fast echo ROUTER and a caller sending
            #     back-to-back make the collision frequent. Runs under a watchdog: a stranded
            #     reply can also leave the reader running, and then close(ctx) blocks for good.
            t3b = Threads.@spawn let ctx = K.ZMQ.Context(), ep = "ipc://" * joinpath(dir, "echo")
                router = K.ZMQ.Socket(ctx, K.ZMQ.ROUTER); router.linger = 0; router.rcvtimeo = 5
                K.ZMQ.bind(router, ep)
                serving = Ref(true)
                server = Threads.@spawn while serving[]
                    parts = try
                        p = [K.ZMQ.recv(router)]
                        while router.rcvmore; push!(p, K.ZMQ.recv(router)); end
                        p
                    catch e
                        e isa K.ZMQ.TimeoutError && continue
                        break
                    end
                    K.ZMQ.send(router, parts[1]; more = true); K.ZMQ.send(router, parts[2]; more = true)
                    K.ZMQ.send(router, UInt8[0x01])
                end
                rc = K.RequestChannel(ctx, ep)
                call() = begin
                    id = Threads.atomic_add!(rc.counter, UInt64(1)); inbox = Channel{Any}(1)
                    lock(rc.pending_lock) do; rc.pending[id] = inbox; end
                    put!(rc.send_q, (id, UInt8[0x02]))
                    r = K._await_inbox(inbox, time() + 5.0)
                    lock(rc.pending_lock) do; delete!(rc.pending, id); end
                    r !== nothing
                end
                sending = Ref(true)
                other = Threads.@spawn while sending[]; call(); end
                worst, lost = 0.0, 0
                for _ in 1:20000
                    t = time(); ok = call(); worst = max(worst, time() - t)
                    # A stranded reply can stall every later call for its full deadline: stop at the first.
                    ok || (lost += 1; break)
                end
                sending[] = false; wait(other)
                K._close_request_channel!(rc)
                serving[] = false; wait(server)
                close(router); close(ctx)
                @assert lost == 0 "replies lost under a concurrent sender: $lost"
                @assert worst < 1.0 "a reply waited $(round(worst; digits = 2))s under a concurrent sender"
                @assert istaskdone(rc.reader) "the reader did not exit on close"
            end
            if timedwait(() -> istaskdone(t3b), 120.0) !== :ok
                println("3b did not finish: a reply was stranded or the reader never exited"); flush(stdout)
                ccall(:_exit, Cvoid, (Cint,), 1)   # not exit(): atexit hooks would block on the same context
            end
            fetch(t3b)

            # 4. disconnect fails pending callers fast (no hang to timeout).
            slow = Threads.@spawn K.eval_remote(conn, "sleep(30); :done"; timeout_ms = 30000)
            sleep(0.3)
            td = @elapsed (K.disconnect!(conn); fetch(slow))
            @assert td < 5 "disconnect didn't fail pending fast ($(td)s)"

            println("RC_OK before=", before, " after=", after)
            try; K.stop!(mgr); catch; end
            try; KG.stop(); catch; end
        end
        # End without Julia's C exit hook, as Kaimon's own main does
        # (_finish_exit_without_runtime_hook): with ZMQ and HTTP threads still live it can deadlock.
        flush(stdout); flush(stderr)
        ccall(:_exit, Cvoid, (Cint,), 0)
    """
    path, io = mktemp()
    write(io, script)
    close(io)

    out = IOBuffer()
    # -t4 forces real concurrency for the correlation check.
    cmd = pipeline(`$(Base.julia_cmd()) --project=$proj -t4 $path`; stdout = out, stderr = out)
    proc = run(cmd; wait = false)
    # A hang anywhere in the subprocess would otherwise hold the suite until CI gives up, with
    # nothing to show where. The steps take well under a minute.
    finished = timedwait(() -> process_exited(proc), 300.0) === :ok
    finished || (kill(proc, Base.SIGKILL); wait(proc))
    output = String(take!(out))

    if !finished || !success(proc) || !occursin("RC_OK", output)
        @info "request channel subprocess output$(finished ? "" : " (killed after 300 s)")" output
    end
    @test finished
    @test success(proc)
    @test occursin("RC_OK", output)
    rm(path; force = true)
end

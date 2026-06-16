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

            # 4. disconnect fails pending callers fast (no hang to timeout).
            slow = Threads.@spawn K.eval_remote(conn, "sleep(30); :done"; timeout_ms = 30000)
            sleep(0.3)
            td = @elapsed (K.disconnect!(conn); fetch(slow))
            @assert td < 5 "disconnect didn't fail pending fast ($(td)s)"

            println("RC_OK before=", before, " after=", after)
            try; K.stop!(mgr); catch; end
            try; KG.stop(); catch; end
        end
    """
    path, io = mktemp()
    write(io, script)
    close(io)

    out = IOBuffer()
    # -t4 forces real concurrency for the correlation check.
    cmd = pipeline(`$(Base.julia_cmd()) --project=$proj -t4 $path`; stdout = out, stderr = out)
    proc = run(cmd; wait = false)
    wait(proc)
    output = String(take!(out))

    if !success(proc) || !occursin("RC_OK", output)
        @info "request channel subprocess output" output
    end
    @test success(proc)
    @test occursin("RC_OK", output)
    rm(path; force = true)
end

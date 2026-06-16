# Regression for the intermittent `gc_sweep_pool` heap-corruption crash
# ("BUG IN CLIENT OF LIBMALLOC: memory corruption of free block").
#
# Root cause: ZMQ.jl appends every new Socket to its Context's
# `sockets::Vector{WeakRef}` with an UNLOCKED `push!`. Kaimon creates ephemeral
# REQ sockets on the shared `mgr.zmq_context` from many threads at once
# (`_req_send_recv` workers, parallel health pings, per-conn SUBs, the event
# PUB). Those concurrent `push!`es race: a resize reallocates+frees the backing
# Memory while GC concurrently scans that WeakRef array → use-after-free in the
# collector. `Kaimon._zmq_socket` serializes construction under one lock.
#
# This hammers the REAL helper from a multithreaded subprocess. With the lock the
# subprocess exits cleanly; without it (regression) it throws
# ConcurrencyViolationError / EMFILE / segfaults → nonzero exit → this test fails.

using ReTest
using Kaimon

@testset "ZMQ socket-creation concurrency (heap-corruption regression)" begin
    proj = pkgdir(Kaimon)
    @test proj !== nothing

    script = """
        using Kaimon
        const ZMQ = Kaimon.ZMQ
        ctx = ZMQ.Context()
        N = max(Threads.nthreads(), 1)
        PER = 1500
        @sync for _t in 1:N
            Threads.@spawn for i in 1:PER
                s = Kaimon._zmq_socket(ctx, ZMQ.REQ)   # the serialized constructor
                s.linger = 0
                close(s)
                (i % 100 == 0) && GC.gc(false)         # release fds + clear weakrefs
            end
        end
        GC.gc()
        println("ZMQ_SOCKET_STRESS_OK total=", N * PER)
    """
    path, io = mktemp()
    write(io, script)
    close(io)

    out = IOBuffer()
    # -t 6 forces real concurrency in the child regardless of how the suite runs.
    cmd = pipeline(`$(Base.julia_cmd()) --project=$proj -t 6 $path`; stdout = out, stderr = out)
    proc = run(cmd; wait = false)
    wait(proc)
    output = String(take!(out))

    @test success(proc)                               # clean exit (no crash/throw)
    @test occursin("ZMQ_SOCKET_STRESS_OK", output)
    if !success(proc)
        @info "ZMQ socket concurrency subprocess output" output
    end
    rm(path; force = true)
end

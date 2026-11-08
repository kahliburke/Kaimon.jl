# `call_tool` reaches the Kaimon server's service endpoint, and fails promptly with a message
# saying so when nothing serves it, instead of waiting out the reply timeout.

using Test
using KaimonGate

const GATE_DIR = dirname(dirname(pathof(KaimonGate)))

@testset "call_tool answers, or reports an unreachable service endpoint promptly" begin
    script = raw"""
    using KaimonGate, Serialization
    const KG = KaimonGate
    const ZMQ = KG.ZMQ
    KG.serve(force = true, allow_mirror = false, spawned_by = "test")
    KG._SERVICE_CONNECT_TIMEOUT_S[] = 0.5
    path = joinpath(KG.sock_dir(), "kaimon-service.sock")

    # A socket file left behind by a server that is gone.
    touch(path)
    t = @elapsed msg = try
        KG.call_tool(:ping); "no error"
    catch e
        sprint(showerror, e)
    end
    println("ABSENT ", round(t; digits = 2), " ", occursin("No Kaimon service endpoint answers", msg))
    rm(path)

    ctx = ZMQ.Context()
    router = ZMQ.Socket(ctx, ZMQ.ROUTER); router.linger = 0
    ZMQ.bind(router, "ipc://" * path)
    server = Threads.@spawn begin
        parts = [KG._recv_within(router, 10.0)]
        while router.rcvmore; push!(parts, KG._zmq_recv(router)); end
        req = deserialize(IOBuffer(parts[end]))
        io = IOBuffer(); serialize(io, (status = :ok, value = (req.tool_name, 42)))
        ZMQ.send(router, parts[1]; more = true); ZMQ.send(router, UInt8[]; more = true)
        ZMQ.send(router, take!(io))
    end
    println("PRESENT ", KG.call_tool(:ping))
    wait(server)
    close(router)
    flush(stdout)
    ccall(:_exit, Cvoid, (Cint,), 0)
    """
    env = copy(ENV)
    env["XDG_CACHE_HOME"] = mktempdir(Sys.iswindows() ? tempdir() : "/tmp")
    cmd = Cmd(`$(joinpath(Sys.BINDIR, "julia")) --project=$GATE_DIR -t 2 --startup-file=no -e $script`; env)
    out = read(pipeline(cmd; stderr = devnull), String)
    absent = match(r"ABSENT ([\d.]+) (true|false)", out)
    @test absent !== nothing
    if absent !== nothing
        @test absent.captures[2] == "true"
        @test parse(Float64, absent.captures[1]) < 5
    end
    @test occursin("PRESENT (:ping, 42)", out)
end

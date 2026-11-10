# A `serve` that fails partway closes what it opened. A package whose precompile workload serves a
# CURVE gate on a port that is already taken must still finish precompiling: the image build waits
# on every open handle, and the ZAP handler started before the bind runs until its socket closes.

using Test
using KaimonGate

const GATE_DIR = dirname(dirname(pathof(KaimonGate)))

const PROBE = """
module FailedServeProbe
import KaimonGate, Sockets
if ccall(:jl_generating_output, Cint, ()) == 1
    taken = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(taken)[2])
    try
        redirect_stdout(devnull) do
            KaimonGate.serve(; mode = :tcp, host = "127.0.0.1", port = port, stream_port = 0,
                             force = true, allow_mirror = false, allow_restart = false,
                             spawned_by = "test", curve = true)
        end
        error("serve bound a port that was already taken")
    catch e
        occursin("Address already in use", sprint(showerror, e)) || rethrow()
    finally
        close(taken)
    end
end
end
"""

@testset "precompile finishes after a failed CURVE serve" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "pkgs", "FailedServeProbe", "src"))
        write(joinpath(dir, "pkgs", "FailedServeProbe", "src", "FailedServeProbe.jl"), PROBE)
        env = copy(ENV)
        env["JULIA_LOAD_PATH"] = join([joinpath(dir, "pkgs"), GATE_DIR, "@stdlib"], Sys.iswindows() ? ';' : ':')
        env["JULIA_DEPOT_PATH"] = join([joinpath(dir, "depot"); DEPOT_PATH], Sys.iswindows() ? ';' : ':')
        env["JULIA_PROJECT"] = ""
        env["KAIMON_CACHE_DIR"] = joinpath(dir, "cache")
        env["KAIMON_GATE_MIRROR_REPL"] = "0"
        log = joinpath(dir, "build.log")
        cmd = Cmd(`$(joinpath(Sys.BINDIR, "julia")) --startup-file=no -e "using FailedServeProbe"`; env)
        p = run(pipeline(cmd; stdout = log, stderr = log); wait = false)
        finished = timedwait(() -> process_exited(p), 180.0) === :ok
        finished || kill(p, 9)
        finished || print(read(log, String))
        @test finished
        @test finished && success(p)
    end
end

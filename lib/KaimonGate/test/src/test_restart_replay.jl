# Restart replay: which serve() kwargs a gate reconstructs when it restarts itself.
#
# The subtle case is Windows. There a requested :ipc gate is COERCED to a local TCP bind,
# so _MODE[] is :tcp — but on restart it must NOT pin mode=:tcp (that would make the
# restarted _serve treat it as an explicit remote gate, skip discovery metadata, and orphan
# the session). It must restart as a plain :ipc gate so it re-coerces and re-advertises.
# An EXPLICIT remote TCP gate, by contrast, must replay mode/host/port to rebind the same
# endpoint its client is connected to.

using KaimonGate

@testset "restart tcp-kwargs replay" begin
    KG = KaimonGate

    # Explicit remote TCP gate (not coerced) → replay the endpoint verbatim.
    ex = KG._restart_tcp_kwargs(:tcp, false, "0.0.0.0", 9876, 9877, false, false)
    @test occursin("mode=:tcp", ex)
    @test occursin("host=\"0.0.0.0\"", ex)
    @test occursin("port=9876", ex)
    @test occursin("stream_port=9877", ex)

    # CURVE flags replay for an encrypted explicit gate.
    exc = KG._restart_tcp_kwargs(:tcp, false, "127.0.0.1", 1, 2, true, true)
    @test occursin("curve=true", exc)
    @test occursin("allow_any=true", exc)
    exc2 = KG._restart_tcp_kwargs(:tcp, false, "127.0.0.1", 1, 2, true, false)
    @test occursin("curve=true", exc2)
    @test !occursin("allow_any", exc2)

    # Windows-coerced LOCAL gate → NO replay (restart as :ipc → re-coerce → re-advertise).
    @test KG._restart_tcp_kwargs(:tcp, true, "127.0.0.1", 5, 6, false, false) == ""

    # Plain IPC gate → nothing to replay.
    @test KG._restart_tcp_kwargs(:ipc, false, "", 0, 0, false, false) == ""
end

@testset "utf16 wide-string conversion (Windows argv capture)" begin
    KG = KaimonGate
    # _capture_original_argv on Windows reads argv as NUL-terminated UTF-16 wide strings
    # (GetCommandLineW/CommandLineToArgvW). The ccalls are Windows-only, but the wide→String
    # conversion is testable anywhere by synthesizing a NUL-terminated UTF-16 buffer.
    for s in ("julia", "C:\\Program Files\\Julia\\bin\\julia.exe", "café ☕", "")
        units = transcode(UInt16, s)
        push!(units, 0x0000)                       # NUL-terminate like a real wide string
        GC.@preserve units begin
            @test KG._utf16_ptr_to_string(pointer(units)) == s
        end
    end
    @test KG._utf16_ptr_to_string(Ptr{UInt16}(C_NULL)) == ""   # null pointer → empty
end

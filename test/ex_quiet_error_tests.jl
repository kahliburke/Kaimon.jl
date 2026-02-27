using ReTest
using Kaimon
using REPL

@testset "ex: quiet mode still returns errors" begin
    # Simulate an interactive REPL backend that signals errors via the (val, iserr) return
    # and prints the error to stderr (typical REPL behavior).

    had_active_repl = isdefined(Base, :active_repl)
    old_active_repl = had_active_repl ? Base.active_repl : nothing

    repl_channel = Channel{Any}(1)
    response_channel = Channel{Any}(1)
    backendref = REPL.REPLBackendRef(repl_channel, response_channel)

    # Provide a lightweight AbstractREPL so Base error hint machinery doesn't explode
    # when it tries to query `REPL.active_module(Base.active_repl)`.
    struct DummyREPL <: REPL.AbstractREPL
        backendref::REPL.REPLBackendRef
    end
    Base.active_module(::DummyREPL) = Main

    dummy_repl = DummyREPL(backendref)

    backend_task = @async begin
        # Wait for execute_repllike to submit work (call_on_backend sends (f, 2))
        msg = take!(repl_channel)
        f = msg[1]
        try
            ret = f()
            put!(response_channel, Pair{Any,Bool}(ret, false))
        catch
            put!(response_channel, Pair{Any,Bool}(current_exceptions(), true))
        end
    end

    try
        Base.active_repl = dummy_repl

        out = Kaimon.execute_repllike("undefined_var + 1"; silent = true, quiet = true)
        @test contains(out, "ERROR:")
    finally
        wait(backend_task)
        if had_active_repl
            Base.active_repl = old_active_repl
        else
            Base.active_repl = nothing
        end
    end
end

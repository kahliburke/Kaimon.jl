using Test
using KaimonGate

# Regression for #34: a breakpoint paused via _breakpoint_hook must be releasable
# locally (Ctrl-C in the user's REPL) instead of hanging forever until an agent
# resumes it. The hook blocks on `take!(resume_ch)`; an InterruptException thrown
# into the blocked task should resume execution and clear the paused state.
#
# Pure — no live gate: _publish_stream is a no-op when _STREAM_SOCKET[] is nothing,
# so the hook runs standalone.

@testset "breakpoint local release (#34)" begin
    KG = KaimonGate
    @test KG._STREAM_SOCKET[] === nothing      # precondition: not serving → publish no-ops
    @test KG._DEBUG_PAUSED[] === nothing        # clean start

    # Run the hook on its own task; it pauses on take!(resume_ch).
    t = Threads.@spawn KG._breakpoint_hook(Dict{Symbol,Any}(:x => 1); file = "t.jl", line = 1)

    # Wait until it has registered the pause (bounded so a regression fails fast).
    deadline = time() + 5
    while KG._DEBUG_PAUSED[] === nothing && time() < deadline
        sleep(0.02)
    end
    @test KG._DEBUG_PAUSED[] !== nothing         # it actually paused

    # _DEBUG_PAUSED is set just before the hook reaches take!(resume_ch); let the
    # trivial setup (channels, eval module) finish so the interrupt lands on the
    # blocking take! — inside the try — rather than on the uncaught setup.
    sleep(0.2)

    # Simulate the user pressing Ctrl-C: interrupt the blocked task.
    schedule(t, InterruptException(); error = true)

    # It must finish (release) rather than hang. wait() rethrows nothing because the
    # hook swallows the InterruptException and returns normally.
    reldeadline = time() + 5
    while !istaskdone(t) && time() < reldeadline
        sleep(0.02)
    end
    @test istaskdone(t)
    @test KG._DEBUG_PAUSED[] === nothing          # state cleared on local release
    @test KG._DEBUG_RESUME_CH[] === nothing
    @test KG._DEBUG_EVAL_CH[] === nothing
end

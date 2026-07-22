using Test
using KaimonGate

# ─────────────────────────────────────────────────────────────────────────────
# Host TUI stream-guard registration (Kaimon #67).
#
# When the capture mux is active, a raw-mode Tachikoma TUI would skip its terminal
# capture/restore cycle (its gate is `stdout isa Base.TTY`, now false) and wedge the
# host REPL on exit. KaimonGate registers `_with_uncaptured_streams` as Tachikoma's
# `with_terminal` stream guard so the TUI runs with the real streams restored.
#
# The registration logic is split into `_install_stream_guard!(T, guard)` (calls
# `T.set_stream_guard!`) and the `_register_tachikoma_stream_guard!()` policy, so we
# can test it against a mock module without depending on Tachikoma.
# ─────────────────────────────────────────────────────────────────────────────

# A mock host with the hook, recording what guard it was handed.
module _MockTachi
    const LAST = Ref{Any}(:unset)
    set_stream_guard!(f) = (LAST[] = f; nothing)
end

# A host too old to support the hook (no `set_stream_guard!`).
module _OldTachi end

@testset "stream-guard install" begin
    KG = KaimonGate
    @test KG._install_stream_guard!(nothing) == false          # nothing → no-op
    @test KG._install_stream_guard!(_OldTachi) == false         # old host, no hook
    @test KG._install_stream_guard!(_MockTachi) == true         # installs the guard
    @test _MockTachi.LAST[] === KG._with_uncaptured_streams     # …our stream-suspender
    @test KG._install_stream_guard!(_MockTachi, nothing) == true
    @test _MockTachi.LAST[] === nothing                         # clearing works
end

@testset "stream-guard registration policy" begin
    KG = KaimonGate
    o_optout = KG._WEDGE_GUARD_OPT_OUT[]
    o_reg = KG._WEDGE_GUARD_REGISTERED[]
    try
        # Tachikoma is not a dependency of this test env, so `_loaded_tachikoma()`
        # returns nothing and registration is a no-op (never flips the flag).
        KG._WEDGE_GUARD_OPT_OUT[] = false
        KG._WEDGE_GUARD_REGISTERED[] = false
        @test KG._loaded_tachikoma() === nothing
        KG._register_tachikoma_stream_guard!()
        @test KG._WEDGE_GUARD_REGISTERED[] == false

        # Opting out short-circuits registration.
        KG._WEDGE_GUARD_OPT_OUT[] = true
        KG._register_tachikoma_stream_guard!()
        @test KG._WEDGE_GUARD_REGISTERED[] == false

        # `disable_wedge_guard!` sets opt-out and clears the registered flag.
        KG._WEDGE_GUARD_OPT_OUT[] = false
        KG._WEDGE_GUARD_REGISTERED[] = true
        KG.disable_wedge_guard!()
        @test KG._WEDGE_GUARD_OPT_OUT[] == true
        @test KG._WEDGE_GUARD_REGISTERED[] == false
    finally
        KG._WEDGE_GUARD_OPT_OUT[] = o_optout
        KG._WEDGE_GUARD_REGISTERED[] = o_reg
    end
end

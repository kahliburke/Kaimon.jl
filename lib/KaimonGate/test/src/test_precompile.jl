using Test
using KaimonGate

# ── precompile directives ─────────────────────────────────────────────────────
#
# src/precompile.jl spells out the startup signature by hand so the default
# serve() path lands in the package image. Nothing enforces that by itself:
# `precompile` returns false rather than throwing when a signature stops
# matching, and `Core.kwcall` matches a generic fallback for ANY NamedTuple, so
# calling precompile here would report success even against invented kwargs.
# Compare against the method's declared keywords instead.
#
# This catches a kwarg added to, removed from or renamed on _serve. It does not
# catch a pure reordering of the forwarding call in serve(), which builds the
# NamedTuple in written order — the precompile would miss while the declaration
# still matches.

@testset "precompile directives" begin
    m = only(methods(KaimonGate._serve))
    names = collect(fieldnames(KaimonGate._SERVE_KWARGS_TYPE))

    @test names == Base.kwarg_decl(m)

    # An abstract slot means serve() no longer resolves that kwarg to one
    # concrete type, so a single precompiled signature stops covering startup.
    types = KaimonGate._SERVE_KWARGS_TYPE.parameters[2].parameters
    @test all(isconcretetype, types)

    @test precompile(KaimonGate.serve, ())
end

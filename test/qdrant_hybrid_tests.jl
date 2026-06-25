# Hybrid code-search fusion tests (no Qdrant/Ollama): the query-shape → lexical-weight
# classifier and the span-overlap dedup. Pure functions over in-memory values.

using ReTest
using Kaimon

@testset "Hybrid search fusion" begin
    @testset "_classify_lexical_weight" begin
        w = Kaimon._classify_lexical_weight

        # Hard NL: the OR-cap fired (capped > 0) ⇒ a sentence of keywords ⇒ lexical
        # becomes a whisper so it can't inject keyword-coincidence chunks.
        @test w("on bind change re-run downstream cells reactive dependency graph", 3) == 0.05

        # Explicit lexical intent ⇒ trust lexical fully.
        @test w("\"reciprocal rank fusion\"", 0) == 1.0      # quoted phrase
        @test w("parse AND method", 0) == 1.0               # boolean keyword
        @test w("foo || bar", 0) == 1.0                     # operator alias
        @test w("foo ! bar", 0) == 1.0                      # standalone NOT

        # Symbol hunts: few, code-shaped tokens ⇒ lexical stays high.
        @test w("_eval_with_capture", 0) == 0.8
        @test w("atStartOfTurn onApplyPower", 0) == 0.8

        # Few prose tokens ⇒ middling; a longer prose phrase ⇒ semantic-dominant.
        @test w("session routing", 0) == 0.5
        @test w("function that handles HTTP routing", 0) == 0.05

        # A 4+ bag that's mostly identifiers earns lexical a real (but bounded) vote,
        # strictly more than a pure-prose bag of the same length.
        codey = w("set_bind_value build_dependencies infer_bindings deps", 0)
        @test 0.05 < codey <= 0.6
        @test codey > w("how the value is applied to each cell", 0)

        @test w("", 0) == 1.0                               # empty ⇒ neutral
    end

    @testset "span-overlap dedup" begin
        H = Kaimon.HybridHit
        mk(file, sl, el; rrf = 1.0, src = :semantic, typ = "function") =
            H(nothing, file, "n", typ, sl, el, "t", Dict(), "", Set([src]), rrf)
        red = Kaimon._spans_redundant
        dedup = Kaimon._dedup_overlaps

        # Redundant: identical span (same file) or one span containing the other.
        @test red(mk("a.jl", 10, 20), mk("a.jl", 10, 20))
        @test red(mk("a.jl", 1, 33), mk("a.jl", 10, 20))
        @test red(mk("a.jl", 10, 20), mk("a.jl", 1, 33))
        # Not redundant: partial overlap, different file, or missing line info.
        @test !red(mk("a.jl", 1, 15), mk("a.jl", 10, 25))
        @test !red(mk("a.jl", 10, 20), mk("b.jl", 10, 20))
        @test !red(mk("a.jl", 0, 0), mk("a.jl", 0, 0))

        # Identical-span dupes collapse to one; sources union; rrf order preserved.
        out = dedup([mk("a.jl", 10, 20; rrf = 1.0, src = :semantic),
                     mk("a.jl", 10, 20; rrf = 0.5, src = :lexical)])
        @test length(out) == 1
        @test out[1].sources == Set([:semantic, :lexical])
        @test out[1].rrf == 1.0

        # A window enclosing two distinct methods: the window folds in, BOTH methods
        # survive — and this holds even when the window outranks the defs (the
        # definitions-first representative choice prevents the window from swallowing them).
        out2 = dedup([mk("a.jl", 1, 33; rrf = 1.0, typ = "window"),
                      mk("a.jl", 10, 26; rrf = 0.9),
                      mk("a.jl", 29, 32; rrf = 0.8)])
        spans = Set((h.start_line, h.end_line) for h in out2)
        @test spans == Set([(10, 26), (29, 32)])
    end
end

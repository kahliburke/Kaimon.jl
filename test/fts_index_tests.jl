# Lexical (FTS5) index + hybrid-fusion tests.
#
# Pure SQLite — no Qdrant or Ollama required, safe for CI. Proves the lexical half
# of hybrid search surfaces exact-identifier matches by *content* (the thing pure
# semantic search misses), that collection/type scoping works, that delete-by-file
# stays in sync, and that the RRF fusion + name-boost rank correctly.

using ReTest
using Kaimon

@testset "FTS lexical index" begin
    F = Kaimon.FtsIndex
    tmp = mktempdir()
    F.init!(joinpath(tmp, "code_fts.db"))
    try
        rows = [
            # name is `helper`, but the body contains the exact identifier a
            # semantic search keys off meaning, not tokens, would likely miss.
            Dict("point_id" => "p1", "collection" => "proj", "file" => "/a/gate.jl",
                 "name" => "helper", "type" => "function", "start_line" => 10, "end_line" => 20,
                 "text" => "function helper(x)\n    y = _eval_with_capture(x)\n    return y\nend"),
            Dict("point_id" => "p2", "collection" => "proj", "file" => "/a/util.jl",
                 "name" => "foo", "type" => "function", "start_line" => 1, "end_line" => 3,
                 "text" => "foo() = 42  # unrelated helper"),
            Dict("point_id" => "p3", "collection" => "other", "file" => "/b/x.jl",
                 "name" => "bar", "type" => "window", "start_line" => 1, "end_line" => 5,
                 "text" => "some other text mentioning embedding vectors"),
        ]
        @test F.add_chunks!(rows) == 3

        @testset "exact identifier found by content" begin
            r = F.search("_eval_with_capture"; collection = "proj")
            @test any(h -> h.point_id == "p1", r.word)
            # ...and the matched chunk carries a highlighted snippet.
            hit = first(filter(h -> h.point_id == "p1", r.word))
            @test occursin("eval", lowercase(hit.text))
        end

        @testset "trigram substring match" begin
            r = F.search("eval_with"; collection = "proj")
            @test any(h -> h.point_id == "p1", r.word) || any(h -> h.point_id == "p1", r.tri)
        end

        @testset "collection scoping" begin
            r = F.search("embedding"; collection = "other")
            @test any(h -> h.point_id == "p3", r.word)
            r2 = F.search("embedding"; collection = "proj")
            @test !any(h -> h.point_id == "p3", r2.word)
        end

        @testset "chunk_type filter" begin
            defs = F.search("embedding"; chunk_type = "definitions")
            @test !any(h -> h.point_id == "p3", defs.word)   # p3 is a window
            wins = F.search("embedding"; chunk_type = "windows")
            @test any(h -> h.point_id == "p3", wins.word)
        end

        @testset "malformed query doesn't throw" begin
            r = F.search("foo\"bar AND ("; collection = "proj")  # broken FTS syntax
            @test r.word isa Vector
        end

        @testset "coverage" begin
            cov = F.coverage()
            @test cov.total == 3
            @test ("proj" => 2) in [(c.collection => c.n) for c in cov.collections]
        end

        @testset "delete-by-file sync" begin
            F.delete_file!("proj", "/a/gate.jl")
            r = F.search("_eval_with_capture"; collection = "proj")
            @test isempty(r.word) && isempty(r.tri)
            @test F.coverage().total == 2
        end

        @testset "clear collection" begin
            F.clear_collection!("proj")
            @test F.coverage().total == 1   # only the "other" collection remains
        end
    finally
        F.close!()
    end
end

# Orphan reconciliation: the lexical file list is the source of truth for detecting
# index entries whose file was removed from disk. Pure SQLite + real temp files —
# no Qdrant (deep=false), so the side-effecting prune (Qdrant deletes) isn't exercised
# here, only the detection that drives it.
@testset "FTS orphan detection" begin
    F = Kaimon.FtsIndex
    dir = mktempdir()
    keep = joinpath(dir, "keep.jl")
    gone = joinpath(dir, "gone.jl")
    write(keep, "f() = 1")
    write(gone, "g() = 2")

    F.init!(joinpath(mktempdir(), "code_fts.db"))
    try
        rows = [
            Dict("point_id" => "k1", "collection" => "proj", "file" => keep,
                 "name" => "f", "type" => "function", "start_line" => 1, "end_line" => 1,
                 "text" => "f() = 1"),
            # two chunks for the same removed file — distinct_files must dedupe
            Dict("point_id" => "g1", "collection" => "proj", "file" => gone,
                 "name" => "g", "type" => "function", "start_line" => 1, "end_line" => 1,
                 "text" => "g() = 2"),
            Dict("point_id" => "g2", "collection" => "proj", "file" => gone,
                 "name" => "g_win", "type" => "window", "start_line" => 1, "end_line" => 1,
                 "text" => "g() = 2  # window"),
            # a different collection must not bleed in
            Dict("point_id" => "o1", "collection" => "other", "file" => gone,
                 "name" => "g", "type" => "function", "start_line" => 1, "end_line" => 1,
                 "text" => "g() = 2"),
        ]
        F.add_chunks!(rows)

        @testset "distinct_files dedupes and scopes by collection" begin
            df = sort(F.distinct_files("proj"))
            @test df == sort([keep, gone])
            @test F.distinct_files("other") == [gone]
        end

        @testset "_orphan_files returns only removed files" begin
            # both files still on disk → no orphans
            @test isempty(Kaimon._orphan_files("proj"))
            rm(gone)
            orphans = Kaimon._orphan_files("proj")
            @test orphans == [gone]          # gone is missing; keep is excluded
            @test keep ∉ orphans
        end

        @testset "distinct_files drops a file after delete_file!" begin
            F.delete_file!("proj", gone)
            @test F.distinct_files("proj") == [keep]
            # "other" collection's row for the same path is untouched
            @test F.distinct_files("other") == [gone]
        end
    finally
        F.close!()
    end
end

@testset "FTS query normalization" begin
    F = Kaimon.FtsIndex

    @testset "_fts_normalize rules" begin
        n = F._fts_normalize
        @test n("push!") == "\"push!\""                       # attached punct → quoted
        @test n("one! two") == "\"one!\" OR two"              # bare bag → OR
        @test n("one ! two") == "one NOT two"                # standalone ! → NOT
        @test n("a && b") == "a AND b"                        # && alias
        @test n("x || y") == "x OR y"                         # || alias
        @test n("commit AND floor") == "commit AND floor"    # full-word op kept
        @test n("token NOT renew") == "token NOT renew"
        @test n("agent_add_cell! guard_commit token") ==
              "\"agent_add_cell!\" OR guard_commit OR token"  # the real failing query
        @test n("\"exact phrase\"") == "\"exact phrase\""    # quoted phrase passes
        @test n("foo*") == "foo*"                            # clean prefix stays bare
        @test n("@view Base.foo") == "\"@view\" OR \"Base.foo\""
    end

    @testset "bang-bag query returns hits, no fallback" begin
        tmp = mktempdir()
        F.init!(joinpath(tmp, "code_fts.db"))
        try
            F.add_chunks!([
                Dict("point_id" => "q1", "collection" => "proj", "file" => "/a/cells.jl",
                     "name" => "agent_add_cell!", "type" => "function",
                     "start_line" => 1, "end_line" => 4,
                     "text" => "agent_add_cell!(s, c) = guard_commit(s) && push!(s.cells, c)"),
            ])
            r = F.search("agent_add_cell! guard_commit token renew"; collection = "proj")
            @test r.fellback == false                         # normalized, not fallback
            @test any(h -> h.point_id == "q1", r.word) || any(h -> h.point_id == "q1", r.tri)
        finally
            F.close!()
        end
    end
end

@testset "FTS query planning (cap / trigram gate / scope)" begin
    F = Kaimon.FtsIndex

    @testset "OR fan-out cap" begin
        cap = F._MAX_OR_TERMS
        small = join(["t$i" for i in 1:(cap - 1)], " ")
        big   = join(["t$i" for i in 1:(cap + 5)], " ")
        @test F._fts_or_dropped(small) == 0                  # within cap → nothing dropped
        @test F._fts_or_dropped(big) == 5                    # over cap → report the overflow
        @test F._fts_or_dropped("a AND b AND c") == 0        # explicit operator → never capped
        # the rendered expression keeps exactly `cap` OR-terms
        @test count(==("OR"), split(F._fts_normalize(big))) == cap - 1
        # distinctiveness keeps the identifier-shaped term over short common words
        kept = F._fts_normalize("a b c d e f g h onApplyPower"; max_terms = 1)
        @test kept == "onApplyPower"
    end

    @testset "trigram eligibility" begin
        @test F._tri_eligible("onApplyPower")                # single bounded token → yes
        @test F._tri_eligible("abc")                         # exactly the min length
        @test !F._tri_eligible("ab")                         # too short
        @test !F._tri_eligible("a b")                        # multi-word → never trigram
        @test !F._tri_eligible("atStartOfTurn onApplyPower actions parse")  # the slow shape
        @test !F._tri_eligible("x"^65)                       # too long
    end

    @testset "collection scope prunes a term shared across collections" begin
        F.init!(joinpath(mktempdir(), "code_fts.db"))
        try
            F.add_chunks!([
                Dict("point_id" => "a1", "collection" => "alpha_proj", "file" => "/a.jl",
                     "name" => "f", "type" => "function", "start_line" => 1, "end_line" => 1,
                     "text" => "render the widget"),
                Dict("point_id" => "b1", "collection" => "beta", "file" => "/b.jl",
                     "name" => "g", "type" => "function", "start_line" => 1, "end_line" => 1,
                     "text" => "render the other widget"),
            ])
            # `render` is in both collections; a scoped search must return only its own.
            ra = F.search("render"; collection = "alpha_proj")  # note the underscore (stripped in coltok)
            @test any(h -> h.point_id == "a1", ra.word)
            @test !any(h -> h.point_id == "b1", ra.word)
            # unscoped (cross-project) sees both
            rall = F.search("render")
            @test any(h -> h.point_id == "a1", rall.word) && any(h -> h.point_id == "b1", rall.word)
        finally
            F.close!()
        end
    end
end

@testset "Hybrid RRF fusion" begin
    mk(pid, src) = Kaimon.HybridHit(pid, "f.jl", "n", "function", 1, 2, "t",
                                    Dict(), src == :lexical ? "snip" : "", Set([src]), 0.0)

    @testset "doc in both lists ranks first, sources union" begin
        sem = [mk("a", :semantic), mk("b", :semantic), mk("c", :semantic)]
        lex = [mk("c", :lexical), mk("d", :lexical)]
        acc = Dict{String,Kaimon.HybridHit}()
        Kaimon._rrf_accumulate!(acc, sem; weight = 1.0)
        Kaimon._rrf_accumulate!(acc, lex; weight = 1.0)
        hits = collect(values(acc))
        sort!(hits; by = h -> -h.rrf)
        @test hits[1].point_id == "c"                        # rank 3 (sem) + rank 1 (lex)
        @test :semantic in hits[1].sources && :lexical in hits[1].sources
        @test length(hits) == 4                              # a,b,c,d deduped
    end

    @testset "exact-symbol + content boosts" begin
        # name appears verbatim in the query → name boost
        h = Kaimon.HybridHit("x", "f", "_eval_with_capture", "function", 1, 2, "fn body",
                             Dict(), "", Set([:lexical]), 0.01)
        Kaimon._apply_boosts!([h], "where is _eval_with_capture defined")
        @test h.rrf > 0.01

        # content boost: text contains every query token even though the name
        # doesn't match (the ast_transforms-in-a-window case)
        hc = Kaimon.HybridHit("c", "f", "kaimon_eval.jl:1-9", "window", 1, 9,
                              "apply REPL ast_transforms here", Dict(), "", Set([:lexical]), 0.01)
        Kaimon._apply_boosts!([hc], "ast transforms")
        @test hc.rrf == 0.01 + Kaimon._CONTENT_BOOST

        # a semantic look-alike lacking the tokens is NOT boosted
        hs = Kaimon.HybridHit("s", "f", "_rand_transition_duration", "function", 1, 2,
                              "rand(6:18)", Dict(), "", Set([:semantic]), 0.01)
        Kaimon._apply_boosts!([hs], "ast transforms")
        @test hs.rrf == 0.01

        # short / common names alone are not boosted
        h2 = Kaimon.HybridHit("y", "f", "f", "function", 1, 2, "t", Dict(), "", Set([:lexical]), 0.01)
        Kaimon._apply_boosts!([h2], "xx")
        @test h2.rrf == 0.01
    end
end

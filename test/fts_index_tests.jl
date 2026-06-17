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

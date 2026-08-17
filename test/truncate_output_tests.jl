using ReTest
using Kaimon

# Output truncation is character-based, not byte-based: a cut that lands inside a
# multi-byte codepoint must not throw, and the retained head/tail must actually be
# the head and tail of the string.
@testset "Output Truncation" begin
    # Multi-byte samples at 2, 3 and 4 UTF-8 bytes per character.
    SAMPLES = Dict(
        "box-drawing" => repeat("┌─┐│└┘", 400),   # 3 bytes/char
        "latin-1"     => repeat("äöüßé", 400),     # 2 bytes/char
        "cjk"         => repeat("日本語テスト", 400), # 3 bytes/char
        "emoji"       => repeat("🎉🚀✨", 400),     # 4 bytes/char
        "mixed"       => repeat("│ ok ✓ 日 🎉 x\n", 200),
    )

    @testset "No StringIndexError at any cut point" begin
        for (name, s) in SAMPLES
            # Sweep caps densely enough to straddle every codepoint boundary.
            for cap in 100:7:1000
                @test (Kaimon.truncate_output(s, cap, nothing); true)
            end
            # A non-throwing sweep is only meaningful if the input is genuinely
            # multi-byte and long enough to be truncated at every cap above.
            @test !isascii(s)
            @test length(s) > 1000
        end
    end

    @testset "Head and tail are preserved" begin
        s = "START" * repeat("┌─┐", 2000) * "END"
        r = Kaimon.truncate_output(s, 600, nothing)
        @test startswith(r, "START")
        @test endswith(r, "END")
        @test occursin("chars omitted", r)
    end

    @testset "Short output is returned unchanged" begin
        for (_, s) in SAMPLES
            short = first(s, 20)
            @test Kaimon.truncate_output(String(short), 1000, nothing) == short
        end
    end

    @testset "Result stays near the requested budget" begin
        # The omitted-chars marker adds a bounded amount; the retained text itself
        # must not overshoot the cap the way a char-count-as-byte-offset tail did.
        s = repeat("┌─┐", 3000)
        for cap in (500, 1000, 6000)
            r = Kaimon.truncate_output(s, cap, nothing)
            @test length(r) <= cap + 100
        end
    end

    @testset "Collection summary branch is also codepoint-safe" begin
        # `value` being a collection takes the summary path, which truncates
        # independently of the simple path.
        value = fill("┌─┐", 500)
        s = repeat("┌─┐", 3000)
        for cap in 400:11:1200
            @test (Kaimon.truncate_output(s, cap, value); true)
        end
    end

    @testset "ASCII behaviour is unchanged" begin
        s = repeat("abcdefghij", 500)
        r = Kaimon.truncate_output(s, 600, nothing)
        @test startswith(r, "abcdefghij")
        @test endswith(r, "abcdefghij")
        @test occursin("chars omitted", r)
    end
end

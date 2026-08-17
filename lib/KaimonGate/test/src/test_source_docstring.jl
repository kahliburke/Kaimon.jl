using Test
using KaimonGate

# `_source_docstring` reads a tool's docstring back out of its source file by
# stripping the `"""` delimiters. Those are ASCII, but the content next to them
# need not be — a character-counting strip keeps a multi-byte character adjacent
# to the closing delimiter from silently blanking the description.
@testset "Source docstring extraction" begin
    mktempdir() do dir
        path = joinpath(dir, "tools.jl")

        # Each function is preceded by a docstring in one of the three shapes the
        # extractor handles, with a multi-byte character hard against the closer.
        write(path, """
        \"\"\"Run the thing — fast\"\"\"
        one_line() = nothing

        \"\"\"
        Multi line, closing content ends in an em dash —\"\"\"
        content_before_close() = nothing

        \"\"\"
        Plain block with a — dash inside
        \"\"\"
        lone_delimiter() = nothing

        \"\"\"Plain ASCII single line\"\"\"
        ascii_one_line() = nothing
        """)

        mod = Module(:DocFixture)
        Base.include(mod, path)

        doc(name) = KaimonGate._source_docstring(getfield(mod, name))

        # The regression: each of these threw StringIndexError internally, and the
        # extractor's catch-all turned that into a silently empty description.
        @test doc(:one_line) == "Run the thing — fast"
        @test doc(:content_before_close) ==
              "Multi line, closing content ends in an em dash —"
        @test doc(:lone_delimiter) == "Plain block with a — dash inside"
        @test doc(:ascii_one_line) == "Plain ASCII single line"

        # None of them may come back blank — that was the failure mode.
        for name in (:one_line, :content_before_close, :lone_delimiter, :ascii_one_line)
            @test !isempty(doc(name))
        end
    end
end

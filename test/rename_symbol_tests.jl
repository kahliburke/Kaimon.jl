# rename_symbol tests: token-level identification, byte-exact splicing, and the guarded
# end-to-end run.
#
# The tests that matter most are the discrimination ones — comments, string literals and
# docstrings must survive a rename while an interpolated `$name` must not. That difference
# is the entire reason this tool exists next to edit_code, so it is pinned here explicitly.

using ReTest
using Kaimon

@testset "rename_symbol" begin
    @testset "_rename_ranges finds identifiers, not text" begin
        src = """
        foo(1)          # foo in a comment
        s = "plain foo here"
        foobar = foo + 2
        """
        rs = Kaimon._rename_ranges(src, "foo", false)
        # `foo(1)` and the bare `foo` in the last line — not the comment, not the string,
        # and not the `foo` inside `foobar`.
        @test length(rs) == 2
        for r in rs
            @test String(codeunits(src)[r]) == "foo"
        end
    end

    @testset "interpolation inside a string IS a reference" begin
        src = "x = \"interp \$foo here\"\ny = \"plain foo here\"\n"
        rs = Kaimon._rename_ranges(src, "foo", false)
        @test length(rs) == 1        # the interpolated one only
        out = Kaimon._rename_apply(src, rs, "baz")
        @test occursin("\$baz", out)
        @test occursin("plain foo here", out)   # the literal is untouched
    end

    @testset "docstrings are string literals, not code" begin
        src = "\"\"\"\ndocstring mentioning foo\n\"\"\"\nfoo(x) = x\n"
        rs = Kaimon._rename_ranges(src, "foo", false)
        @test length(rs) == 1
        out = Kaimon._rename_apply(src, rs, "baz")
        @test occursin("docstring mentioning foo", out)   # prose survives
        @test occursin("baz(x) = x", out)
    end

    @testset "macros only with macros=true" begin
        src = "@foo x\nfoo(1)\n"
        @test length(Kaimon._rename_ranges(src, "foo", false)) == 1
        @test length(Kaimon._rename_ranges(src, "foo", true)) == 2
        out = Kaimon._rename_apply(src, Kaimon._rename_ranges(src, "foo", true), "baz")
        @test occursin("@baz x", out)
    end

    @testset "quoted symbols and keyword names are identifiers" begin
        @test length(Kaimon._rename_ranges("Val{:foo}\n", "foo", false)) == 1
        @test length(Kaimon._rename_ranges("f(; foo = 1) = foo\n", "foo", false)) == 2
    end

    @testset "_rename_apply preserves everything else byte-for-byte" begin
        src = "# keep  this   spacing\nfoo   =  1  # trailing\n"
        rs = Kaimon._rename_ranges(src, "foo", false)
        out = Kaimon._rename_apply(src, rs, "baz")
        @test out == "# keep  this   spacing\nbaz   =  1  # trailing\n"
    end

    @testset "non-ASCII identifiers slice on byte boundaries" begin
        src = "αβγ = 1\nδ = αβγ + 1\n"
        rs = Kaimon._rename_ranges(src, "αβγ", false)
        @test length(rs) == 2
        @test Kaimon._rename_apply(src, rs, "abc") == "abc = 1\nδ = abc + 1\n"
    end

    @testset "no ranges leaves the source identical" begin
        src = "bar(1)\n"
        @test Kaimon._rename_apply(src, Kaimon._rename_ranges(src, "foo", false), "baz") == src
    end

    # ── end to end ────────────────────────────────────────────────────────────
    if Kaimon._rg_argv() !== nothing
        mkfixture() = begin
            d = mktempdir()
            write(joinpath(d, "a.jl"),
                  "# foo in a comment\nfoo(1)\nfoobar = 2\ns = \"plain foo\"\n")
            write(joinpath(d, "b.jl"), "y = foo(9)\n")
            d
        end

        @testset "renames code only, across files" begin
            d = mkfixture()
            out = Kaimon._rename_symbol(Dict(
                "old_name" => "foo", "new_name" => "baz", "path" => d))
            @test occursin("2 occurrence(s) in 2 file(s)", out)
            a = read(joinpath(d, "a.jl"), String)
            @test occursin("# foo in a comment", a)     # comment survives
            @test occursin("\"plain foo\"", a)          # string survives
            @test occursin("foobar = 2", a)             # substring identifier survives
            @test occursin("baz(1)", a)
            @test read(joinpath(d, "b.jl"), String) == "y = baz(9)\n"
        end

        @testset "rejects a new_name that isn't an identifier" begin
            d = mkfixture()
            out = Kaimon._rename_symbol(Dict(
                "old_name" => "foo", "new_name" => "not a name", "path" => d))
            @test occursin("is not a Julia identifier", out)
            @test occursin("foo(1)", read(joinpath(d, "a.jl"), String))
        end

        @testset "a file that already fails to parse is skipped, not blamed" begin
            d = mkfixture()
            write(joinpath(d, "broken.jl"), "function foo(\n")
            out = Kaimon._rename_symbol(Dict(
                "old_name" => "foo", "new_name" => "baz", "path" => d))
            @test occursin("Skipped", out)
            @test occursin("broken.jl", out)
            @test read(joinpath(d, "broken.jl"), String) == "function foo(\n"  # untouched
            @test occursin("baz(1)", read(joinpath(d, "a.jl"), String))        # others still done
        end

        @testset "dry_run writes nothing" begin
            d = mkfixture()
            out = Kaimon._rename_symbol(Dict(
                "old_name" => "foo", "new_name" => "baz", "path" => d, "dry_run" => true))
            @test occursin("Dry run", out)
            @test occursin("foo(1)", read(joinpath(d, "a.jl"), String))
        end

        @testset "no occurrences reports rather than writing" begin
            d = mkfixture()
            out = Kaimon._rename_symbol(Dict(
                "old_name" => "nosuchsym", "new_name" => "baz", "path" => d))
            @test occursin("No identifier", out)
        end

        @testset "only .jl files are considered" begin
            d = mkfixture()
            write(joinpath(d, "notes.md"), "foo is mentioned here\n")
            Kaimon._rename_symbol(Dict(
                "old_name" => "foo", "new_name" => "baz", "path" => d))
            @test read(joinpath(d, "notes.md"), String) == "foo is mentioned here\n"
        end
    end
end

# edit_code tests: matcher construction, line-wise vs multiline application, parse
# validation, unified-diff shape, and a guarded end-to-end run (only when `rg` exists).
#
# The property worth defending hardest is the abort: a batch containing one file that
# would not parse must leave EVERY file untouched, including the ones that were fine.

using ReTest
using Kaimon

@testset "edit_code" begin
    @testset "_edit_escape_re escapes regex metacharacters" begin
        @test Kaimon._edit_escape_re("a.b") == "a\\.b"
        @test Kaimon._edit_escape_re("f(x)") == "f\\(x\\)"
        @test Kaimon._edit_escape_re("a|b[c]") == "a\\|b\\[c\\]"
        @test Kaimon._edit_escape_re("plain") == "plain"
        # An escaped literal must match only itself.
        @test occursin(Regex(Kaimon._edit_escape_re("a.b")), "a.b")
        @test !occursin(Regex(Kaimon._edit_escape_re("a.b")), "axb")
    end

    @testset "_edit_regex honors fixed / word / ignore_case" begin
        @test Kaimon._edit_regex("foo", false, false, false) == r"foo"
        @test occursin(Kaimon._edit_regex("FOO", false, true, false), "foo")
        # word=true must not match inside a longer identifier
        rx = Kaimon._edit_regex("foo", false, false, true)
        @test occursin(rx, "a foo b")
        @test !occursin(rx, "foobar")
        # fixed=true means metacharacters are literal
        @test !occursin(Kaimon._edit_regex("a.b", true, false, false), "axb")
        # an invalid pattern comes back as an error string, not a throw
        @test Kaimon._edit_regex("(unclosed", false, false, false) isa String
    end

    @testset "_edit_apply — line-wise by default, trailing newline preserved" begin
        rx = r"foo"
        sub = Kaimon._edit_sub("baz", false)
        @test Kaimon._edit_apply("foo\nbar\nfoo\n", rx, sub, false) == ("baz\nbar\nbaz\n", 2)
        # No trailing newline in, none out.
        @test Kaimon._edit_apply("foo\nbar", rx, sub, false) == ("baz\nbar", 1)
        # Line-wise cannot match across a newline; multiline can.
        rx2 = r"foo\nbar"
        @test Kaimon._edit_apply("foo\nbar\n", rx2, sub, false) == ("foo\nbar\n", 0)
        @test Kaimon._edit_apply("foo\nbar\n", rx2, sub, true) == ("baz\n", 1)
    end

    @testset "counts follow the mode's anchoring, not whole-content matching" begin
        # `^` means line start line-wise, file start under multiline — the reported
        # count has to agree with whichever substitution actually ran.
        rx = Kaimon._edit_regex("^foo", false, false, false)
        sub = Kaimon._edit_sub("baz", false)
        @test Kaimon._edit_apply("foo\nfoo\n", rx, sub, false) == ("baz\nbaz\n", 2)
        @test Kaimon._edit_apply("foo\nfoo\n", rx, sub, true) == ("baz\nfoo\n", 1)
    end

    @testset "_edit_sub — backrefs unless fixed" begin
        rx = r"f(\d+)"
        @test replace("f12", rx => Kaimon._edit_sub("g\\1", false)) == "g12"
        # fixed inserts the replacement verbatim, backslashes and all
        @test replace("f12", rx => Kaimon._edit_sub("g\\1", true)) == "g\\1"
    end

    @testset "_edit_validate rejects only what would not read back" begin
        @test Kaimon._edit_validate("x.jl", "f(x) = x + 1\n") === nothing
        @test Kaimon._edit_validate("x.jl", "function f(\n") !== nothing   # incomplete
        @test Kaimon._edit_validate("x.jl", "f(x) = x +\nend\n") !== nothing  # error
        @test Kaimon._edit_validate("x.toml", "a = 1\n") === nothing
        @test Kaimon._edit_validate("x.toml", "a = = 1\n") !== nothing
        # Unknown extensions are not the tool's business.
        @test Kaimon._edit_validate("x.md", "# not (valid julia\n") === nothing
    end

    @testset "parse errors render readably, not as a constructor repr" begin
        err = Kaimon._edit_validate("x.jl", "f(x) = x +\nend\n")
        @test err isa String
        # showerror output, not `Base.Meta.ParseError("...")`
        @test !startswith(strip(err), "Base.Meta.ParseError(")
        @test occursin("Error", err)
    end

    @testset "_edit_diff groups removals before additions" begin
        d = Kaimon._edit_diff("f.jl", "foo\nfoo\nkeep\n", "baz\nbaz\nkeep\n", false)
        @test occursin("--- a/f.jl", d)
        @test occursin("+++ b/f.jl", d)
        lines = split(d, '\n')
        minus = findall(l -> startswith(l, "-") && !startswith(l, "---"), lines)
        plus = findall(l -> startswith(l, "+") && !startswith(l, "+++"), lines)
        # Both removals precede both additions.
        @test maximum(minus) < minimum(plus)
        @test length(minus) == 2 && length(plus) == 2
    end

    @testset "_edit_diff is empty when nothing changed" begin
        @test Kaimon._edit_diff("f.jl", "a\nb\n", "a\nb\n", false) == ""
    end

    # ── end to end ────────────────────────────────────────────────────────────
    if Kaimon._rg_argv() !== nothing
        mkfixture() = begin
            d = mktempdir()
            write(joinpath(d, "a.jl"), "foo(1)\nbar(2)\nfoo(3)\n")
            write(joinpath(d, "b.jl"), "foo(9)\n")
            d
        end
        orig_a = "foo(1)\nbar(2)\nfoo(3)\n"

        @testset "applies across files and reports the diff" begin
            d = mkfixture()
            out = Kaimon._edit_code(Dict(
                "pattern" => "foo", "replacement" => "baz", "path" => d, "word" => true))
            @test occursin("3 replacement(s) in 2 file(s)", out)
            @test occursin("-foo(1)", out) && occursin("+baz(1)", out)
            @test read(joinpath(d, "a.jl"), String) == "baz(1)\nbar(2)\nbaz(3)\n"
            @test read(joinpath(d, "b.jl"), String) == "baz(9)\n"
        end

        @testset "one unparseable file aborts the WHOLE batch" begin
            d = mkfixture()
            # Deleting every ')' breaks both files; nothing may be written.
            out = Kaimon._edit_code(Dict(
                "pattern" => "\\)", "replacement" => "", "path" => d))
            @test occursin("Aborted", out)
            @test read(joinpath(d, "a.jl"), String) == orig_a
            @test read(joinpath(d, "b.jl"), String) == "foo(9)\n"
        end

        @testset "a good file is not written when a sibling fails" begin
            d = mkfixture()
            write(joinpath(d, "bad.jl"), "ok(1)\n")
            # `1)` → `1` breaks bad.jl and a.jl, but b.jl (foo(9)) is untouched by it.
            out = Kaimon._edit_code(Dict(
                "pattern" => "1\\)", "replacement" => "1", "path" => d))
            @test occursin("Aborted", out)
            @test read(joinpath(d, "a.jl"), String) == orig_a
            @test read(joinpath(d, "bad.jl"), String) == "ok(1)\n"
        end

        @testset "dry_run writes nothing but still returns the diff" begin
            d = mkfixture()
            out = Kaimon._edit_code(Dict(
                "pattern" => "foo", "replacement" => "baz", "path" => d, "dry_run" => true))
            @test occursin("Dry run", out)
            @test occursin("+baz(1)", out)
            @test read(joinpath(d, "a.jl"), String) == orig_a
        end

        @testset "max_files refuses an over-wide batch without writing" begin
            d = mkfixture()
            out = Kaimon._edit_code(Dict(
                "pattern" => "foo", "replacement" => "baz", "path" => d, "max_files" => 1))
            @test occursin("Refusing to edit", out)
            @test read(joinpath(d, "a.jl"), String) == orig_a
        end

        @testset "no matches reports rather than writing" begin
            d = mkfixture()
            out = Kaimon._edit_code(Dict(
                "pattern" => "nosuchthing", "replacement" => "x", "path" => d))
            @test occursin("No matches", out)
            @test read(joinpath(d, "a.jl"), String) == orig_a
        end

        @testset "glob narrows the scope" begin
            d = mkfixture()
            out = Kaimon._edit_code(Dict(
                "pattern" => "foo", "replacement" => "baz", "path" => d,
                "glob" => ["b.jl"]))
            @test read(joinpath(d, "a.jl"), String) == orig_a       # untouched
            @test read(joinpath(d, "b.jl"), String) == "baz(9)\n"
        end

        @testset "binary files are skipped, not corrupted" begin
            d = mkfixture()
            binpath = joinpath(d, "blob.bin")
            write(binpath, UInt8[0x66, 0x6f, 0x6f, 0x00, 0x66, 0x6f, 0x6f])  # "foo\0foo"
            before = read(binpath)
            Kaimon._edit_code(Dict(
                "pattern" => "foo", "replacement" => "baz", "path" => d))
            @test read(binpath) == before
        end

        @testset "missing replacement is refused" begin
            d = mkfixture()
            out = Kaimon._edit_code(Dict("pattern" => "foo", "path" => d))
            @test occursin("replacement is required", out)
        end
    end
end

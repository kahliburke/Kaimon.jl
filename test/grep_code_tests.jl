# grep_code tests: ripgrep --json parsing, enclosing-symbol enrichment, highlighting,
# scope resolution, and a guarded end-to-end run (only when `rg` is available).

using ReTest
using Kaimon

@testset "grep_code" begin
    @testset "_grep_parse_rg" begin
        j = "{\"type\":\"begin\",\"data\":{\"path\":{\"text\":\"/a/foo.jl\"}}}\n" *
            "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"/a/foo.jl\"}," *
            "\"lines\":{\"text\":\"  bar()\\n\"},\"line_number\":3," *
            "\"submatches\":[{\"match\":{\"text\":\"bar\"},\"start\":2,\"end\":5}]}}\n" *
            "{\"type\":\"summary\",\"data\":{}}"
        hits, more = Kaimon._grep_parse_rg(j, 40)
        @test length(hits) == 1 && !more
        @test hits[1].file == "/a/foo.jl"
        @test hits[1].line == 3
        @test hits[1].text == "  bar()"          # trailing newline stripped
        @test hits[1].subs == ["bar"]
    end

    @testset "_grep_parse_rg caps and reports truncation" begin
        m(i) = "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"/a/f.jl\"}," *
               "\"lines\":{\"text\":\"x\\n\"},\"line_number\":$i,\"submatches\":[]}}"
        hits, more = Kaimon._grep_parse_rg(join([m(i) for i in 1:5], "\n"), 3)
        @test length(hits) == 3 && more
    end

    @testset "_grep_enclosing (smallest containing def, parsed fresh)" begin
        dir = mktempdir()
        f = joinpath(dir, "x.jl")
        write(f, "function outer(a)\n    a + 1\nend\n\nstruct Pt\n    x\nend\n")
        _, defs = Kaimon._grep_file_ctx(f, Dict{String,Any}())
        @test Kaimon._grep_enclosing(2, defs) == ("outer", "function")
        @test Kaimon._grep_enclosing(6, defs) == ("Pt", "struct")
        @test Kaimon._grep_enclosing(4, defs) === nothing   # blank line between defs
        rm(dir; recursive = true)
    end

    @testset "_grep_highlight" begin
        @test Kaimon._grep_highlight("foo bar baz", ["bar"]) == "foo **bar** baz"
        @test Kaimon._grep_highlight("  x  ", String[]) == "x"          # trims, no subs
        @test Kaimon._grep_highlight("a a", ["a"]) == "**a** **a**"     # all occurrences
    end

    @testset "_grep_resolve_root" begin
        dir = mktempdir()
        root, _, err = Kaimon._grep_resolve_root(Dict("path" => dir))
        @test err === nothing && root == dir
        root2, _, err2 = Kaimon._grep_resolve_root(Dict("path" => "/no/such/path/xyz123"))
        @test err2 !== nothing && root2 === nothing
        rm(dir; recursive = true)
    end

    @testset "_grep_code end-to-end (rg)" begin
        if Kaimon._rg_argv() === nothing
            @test_skip "ripgrep not available"
        else
            dir = mktempdir()
            write(joinpath(dir, "a.jl"), "function hello()\n    target_token = 1\nend\n")
            write(joinpath(dir, "b.jl"), "x = 1  # nothing here\n")
            out = Kaimon._grep_code(Dict("pattern" => "target_token", "path" => dir))
            @test occursin("target_token", out)
            @test occursin("hello", out)        # enclosing symbol enrichment
            @test occursin("L2", out)
            @test occursin("No matches", Kaimon._grep_code(Dict("pattern" => "zzz_absent_qqq", "path" => dir)))
            rm(dir; recursive = true)
        end
    end

    @testset "code-search nudge detection" begin
        cs = Kaimon._is_code_search
        # Real filesystem searches → a code search.
        @test cs("grep foo src")
        @test cs("cd x && grep foo .")
        @test cs("rg bar .")
        @test cs("ag TODO src")
        @test cs("find . -name '*.jl'")
        # grep-family downstream of a pipe = filtering a stream, NOT a code search.
        @test !cs("git status | grep -v '^??'")
        @test !cs("ps aux | grep julia")
        @test !cs("cat f | rg bar")
        # Non-search commands / non-code finds.
        @test !cs("ls -la")
        @test !cs("echo grep is a tool")
        @test !cs("find . -name '*.log'")
        # Quoted/heredoc DATA mentioning grep is not a command (commit messages, echo text).
        @test !cs("git commit -m \"refactor grep && rg path handling\"")
        @test !cs("echo 'run grep foo src to find it'")
        @test !cs("git commit -F - <<'EOF'\nfix: improve grep && rg detection\nEOF")
        # Payload: nudge JSON when matched, "" otherwise, fail-open on junk.
        yes = Kaimon._hook_nudge_payload("/hook/nudge?agent=claude",
            "{\"tool_input\":{\"command\":\"grep foo src\"}}")
        @test occursin("additionalContext", yes) && occursin("grep_code", yes)
        @test Kaimon._hook_nudge_payload("/hook/nudge", "{\"tool_input\":{\"command\":\"ls\"}}") == ""
        @test Kaimon._hook_nudge_payload("/hook/nudge", "not json") == ""
    end

    @testset "no_ignore covers ignored / non-code files" begin
        @test Kaimon._grep_is_code_file("foo.jl")
        @test Kaimon._grep_is_code_file("Bar.TS")          # case-insensitive
        @test !Kaimon._grep_is_code_file("app.log")
        @test !Kaimon._grep_is_code_file("data.csv")

        if Kaimon._rg_argv() === nothing
            @test_skip "ripgrep not available"
        else
            dir = mktempdir()
            write(joinpath(dir, ".ignore"), "*.log\n")              # rg always honors .ignore
            write(joinpath(dir, "app.log"), "a\nzz_tok_zz happened here\nb\n")
            write(joinpath(dir, "code.jl"), "function f()\n    zz_tok_zz = 1\nend\n")
            # default: the ignored .log is skipped; the .jl hit carries its enclosing symbol
            d = Kaimon._grep_code(Dict("pattern" => "zz_tok_zz", "path" => dir))
            @test occursin("code.jl", d) && occursin("f  ", d)      # "L2  f  zz_tok_zz = 1"
            @test !occursin("app.log", d)
            # no_ignore: the .log is searched too (file:line, no enclosing symbol)
            n = Kaimon._grep_code(Dict("pattern" => "zz_tok_zz", "path" => dir, "no_ignore" => true))
            @test occursin("app.log", n) && occursin("L2", n)
            rm(dir; recursive = true)
        end
    end
end

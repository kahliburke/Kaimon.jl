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
        @test err === nothing && root == realpath(dir)   # canonicalized (symlinks resolved)
        root2, _, err2 = Kaimon._grep_resolve_root(Dict("path" => "/no/such/path/xyz123"))
        @test err2 !== nothing && root2 === nothing
        rm(dir; recursive = true)
    end

    @testset "_grep_resolve_root refuses server-cwd fallback for an unbound agent" begin
        caller = "grep-guard-$(rand(UInt32))"
        task_local_storage(:mcp_caller, caller) do
            # Agent caller, no bound project, no explicit path → error, not server cwd.
            root, _, err = Kaimon._grep_resolve_root(Dict{String,Any}())
            @test root === nothing && err !== nothing && occursin("no project", err)
            # A relative path can't be anchored without a project → also refused.
            r2, _, e2 = Kaimon._grep_resolve_root(Dict{String,Any}("path" => "sub/dir"))
            @test r2 === nothing && e2 !== nothing
            # An explicit ABSOLUTE path resolves here — resolution doesn't guess a
            # project; confinement is enforced separately in _grep_enforce_scope.
            d = mktempdir()
            r3, _, e3 = Kaimon._grep_resolve_root(Dict{String,Any}("path" => d))
            @test e3 === nothing && r3 == realpath(d)
            rm(d; recursive = true)
        end
        # Caller-less (REPL/self) calls still fall back to cwd — no error.
        rootless, _, errless = Kaimon._grep_resolve_root(Dict{String,Any}())
        @test errless === nothing && rootless !== nothing
    end

    @testset "_grep_enforce_scope confines an agent to project + whitelist" begin
        mktempdir() do cache
            withenv(
                "XDG_CACHE_HOME" => cache,
                "XDG_CONFIG_HOME" => joinpath(cache, "config"),
            ) do
                mkpath(joinpath(cache, "kaimon"))
                proj = mktempdir()
                outside = mktempdir()
                caller = "grep-scope-$(rand(UInt32))"
                Kaimon.save_persisted_sessions(
                    Dict{String,Dict}(
                        caller => Dict(
                            "created_at" => "2026-07-04T10:00:00",
                            "last_seen" => "2026-07-04T10:00:00",
                            "project_path" => proj,
                        ),
                    ),
                )
                task_local_storage(:mcp_caller, caller) do
                    # Inside the bound project → allowed.
                    @test Kaimon._grep_enforce_scope(realpath(proj)) === nothing
                    # Outside, with no live session to elicit through → refused.
                    e = Kaimon._grep_enforce_scope(realpath(outside))
                    @test e !== nothing && occursin("scope", e)
                    # Whitelisting it (what an "always allow" consent persists) → allowed.
                    @test Kaimon.allow_grep_path!(outside)
                    @test !isempty(Kaimon.grep_allowed_paths())
                    @test Kaimon._grep_enforce_scope(realpath(outside)) === nothing
                    # Adding the same path again is a no-op.
                    @test Kaimon.allow_grep_path!(outside) == false
                end
                rm(proj; recursive = true)
                rm(outside; recursive = true)
            end
        end
        # Caller-less (REPL/self) is unconfined.
        @test Kaimon._grep_enforce_scope("/etc") === nothing
    end

    @testset "_grep_enforce_scope consent outcomes (once/always/decline/timeout)" begin
        mktempdir() do cache
            withenv(
                "XDG_CACHE_HOME" => cache,
                "XDG_CONFIG_HOME" => joinpath(cache, "config"),
            ) do
                mkpath(joinpath(cache, "kaimon"))
                proj = mktempdir()
                out1 = mktempdir()
                out2 = mktempdir()
                caller = "grep-consent-$(rand(UInt32))"
                Kaimon.save_persisted_sessions(
                    Dict{String,Dict}(
                        caller => Dict(
                            "created_at" => "2026-07-04T10:00:00",
                            "last_seen" => "2026-07-04T10:00:00",
                            "project_path" => proj,
                        ),
                    ),
                )
                task_local_storage(:mcp_caller, caller) do
                    # Decline → refused.
                    ed = Kaimon._grep_enforce_scope(realpath(out1); consent = _ -> :denied)
                    @test ed !== nothing && occursin("scope", ed)
                    # Timeout → distinct retry message, still refused.
                    et = Kaimon._grep_enforce_scope(realpath(out1); consent = _ -> :timeout)
                    @test et !== nothing && occursin("within", et)
                    # Approve once → allowed, and NOT persisted.
                    @test Kaimon._grep_enforce_scope(realpath(out1); consent = _ -> :once) ===
                          nothing
                    @test isempty(Kaimon.grep_allowed_paths())
                    # Approve always → allowed AND persisted to the whitelist.
                    @test Kaimon._grep_enforce_scope(realpath(out2); consent = _ -> :always) ===
                          nothing
                    @test Kaimon.normalize_path(realpath(out2)) in Kaimon.grep_allowed_paths()
                    # Now out2 is in scope — a declining consent isn't even consulted.
                    @test Kaimon._grep_enforce_scope(realpath(out2); consent = _ -> :denied) ===
                          nothing
                    # ...but out1 (approved only once) still refuses.
                    @test Kaimon._grep_enforce_scope(realpath(out1); consent = _ -> :denied) !==
                          nothing
                end
                rm(proj; recursive = true)
                rm(out1; recursive = true)
                rm(out2; recursive = true)
            end
        end
    end

    @testset "a symlink inside the project can't escape scope" begin
        mktempdir() do cache
            withenv(
                "XDG_CACHE_HOME" => cache,
                "XDG_CONFIG_HOME" => joinpath(cache, "config"),
            ) do
                mkpath(joinpath(cache, "kaimon"))
                proj = mktempdir()
                outside = mktempdir()
                symlink(outside, joinpath(proj, "escape"))
                caller = "grep-symlink-$(rand(UInt32))"
                Kaimon.save_persisted_sessions(
                    Dict{String,Dict}(
                        caller => Dict(
                            "created_at" => "2026-07-04T10:00:00",
                            "last_seen" => "2026-07-04T10:00:00",
                            "project_path" => proj,
                        ),
                    ),
                )
                task_local_storage(:mcp_caller, caller) do
                    # `proj/escape` looks in-project by name, but realpath follows the
                    # symlink out, so resolution returns the real (outside) path...
                    root, _, err = Kaimon._grep_resolve_root(
                        Dict{String,Any}("path" => joinpath(proj, "escape")),
                    )
                    @test err === nothing && root == realpath(outside)
                    # ...and confinement refuses it (no consent available).
                    e = Kaimon._grep_enforce_scope(root; consent = _ -> :unsupported)
                    @test e !== nothing && occursin("scope", e)
                end
                rm(joinpath(proj, "escape"))
                rm(proj; recursive = true)
                rm(outside; recursive = true)
            end
        end
    end

    @testset "grep is allowed within a broader declared workspace root" begin
        mktempdir() do cache
            withenv(
                "XDG_CACHE_HOME" => cache,
                "XDG_CONFIG_HOME" => joinpath(cache, "config"),
            ) do
                mkpath(joinpath(cache, "kaimon"))
                parent = mktempdir()
                sibling = joinpath(parent, "other")
                mkpath(sibling)
                caller = "grep-ws-$(rand(UInt32))"
                # The caller's declared MCP workspace root is the parent directory.
                Kaimon.save_persisted_sessions(
                    Dict{String,Dict}(
                        caller => Dict(
                            "created_at" => "2026-07-04T10:00:00",
                            "last_seen" => "2026-07-04T10:00:00",
                            "workspace_root" => parent,
                        ),
                    ),
                )
                task_local_storage(:mcp_caller, caller) do
                    # A sibling under the workspace root is in scope without a prompt.
                    @test Kaimon._grep_enforce_scope(
                        realpath(sibling);
                        consent = _ -> :denied,
                    ) === nothing
                end
                rm(parent; recursive = true)
            end
        end
    end

    @testset "allow_grep_path! preserves other config keys" begin
        mktempdir() do cache
            withenv("XDG_CONFIG_HOME" => joinpath(cache, "config")) do
                cfgdir = joinpath(cache, "config", "kaimon")
                mkpath(cfgdir)
                write(
                    joinpath(cfgdir, "projects.json"),
                    """{"allow_any_project":true,"projects":[{"project_path":"/x","enabled":true}]}""",
                )
                @test Kaimon.allow_grep_path!("/some/dir")
                # The new key is added...
                @test Kaimon.normalize_path("/some/dir") in Kaimon.grep_allowed_paths()
                # ...without dropping pre-existing top-level keys.
                @test Kaimon.projects_allow_any() == true
                @test length(Kaimon.load_projects_config()) == 1
            end
        end
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

    @testset "slash-anchored globs match regardless of process cwd" begin
        # Regression: ripgrep anchors slash-containing globs (`sub/*.jl`) to the PROCESS
        # CWD, not the search-path argument. The long-lived server runs with a cwd that is
        # not the searched repo, so before the cwd-pin fix every `-g dir/…` glob silently
        # matched nothing. Reproduce by searching from a foreign cwd.
        if Kaimon._rg_argv() === nothing
            @test_skip "ripgrep not available"
        else
            dir = mktempdir()
            mkpath(joinpath(dir, "sub"))
            write(joinpath(dir, "sub", "deep.jl"), "function g()\n    tok_glob_zz = 1\nend\n")
            write(joinpath(dir, "top.jl"), "tok_glob_zz = 2\n")
            foreign = mktempdir()
            orig = pwd()
            try
                cd(foreign)   # cwd ≠ searched root — the server's condition
                star = Kaimon._grep_code(Dict("pattern" => "tok_glob_zz", "path" => dir, "glob" => ["sub/*.jl"]))
                @test occursin("deep.jl", star)      # slash glob now matches
                @test !occursin("top.jl", star)      # and correctly excludes the top-level file
                globstar = Kaimon._grep_code(Dict("pattern" => "tok_glob_zz", "path" => dir, "glob" => ["sub/**/*.jl"]))
                @test occursin("deep.jl", globstar)
            finally
                cd(orig)
            end
            rm(dir; recursive = true)
            rm(foreign; recursive = true)
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

# grep_code tests: ripgrep --json parsing, enclosing-symbol enrichment, highlighting,
# scope resolution, and a guarded end-to-end run (only when `rg` is available).

using ReTest
using Kaimon

@testset "grep_code" begin
    @testset "_grep_parse_rg — per-file counts, totals, verbatim lines" begin
        # foo.jl: 2 matches, bar.jl: 1. `end` messages carry exact per-file counts; the
        # `summary` carries the grand total + files scanned.
        j = join([
            "{\"type\":\"begin\",\"data\":{\"path\":{\"text\":\"/a/foo.jl\"}}}",
            "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"/a/foo.jl\"},\"lines\":{\"text\":\"  bar()\\n\"},\"line_number\":3,\"submatches\":[{\"match\":{\"text\":\"bar\"}}]}}",
            "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"/a/foo.jl\"},\"lines\":{\"text\":\"  baz()\\n\"},\"line_number\":7,\"submatches\":[]}}",
            "{\"type\":\"end\",\"data\":{\"path\":{\"text\":\"/a/foo.jl\"},\"stats\":{\"matches\":2}}}",
            "{\"type\":\"begin\",\"data\":{\"path\":{\"text\":\"/a/bar.jl\"}}}",
            "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"/a/bar.jl\"},\"lines\":{\"text\":\"q\\n\"},\"line_number\":1,\"submatches\":[]}}",
            "{\"type\":\"end\",\"data\":{\"path\":{\"text\":\"/a/bar.jl\"},\"stats\":{\"matches\":1}}}",
            "{\"type\":\"summary\",\"data\":{\"stats\":{\"matches\":3,\"searches\":2}}}",
        ], "\n")
        files, total, scanned = Kaimon._grep_parse_rg(j, 40)
        @test total == 3 && scanned == 2
        @test length(files) == 2
        @test files[1].path == "/a/foo.jl" && files[1].count == 2
        @test [h.line for h in files[1].hits] == [3, 7]
        @test files[1].hits[1].text == "  bar()"        # verbatim, trailing newline stripped
        @test !hasproperty(files[1].hits[1], :subs)     # submatches deliberately not extracted
        @test files[2].path == "/a/bar.jl" && files[2].count == 1
    end

    @testset "_grep_parse_rg retains ≤`retain` lines per file but counts all" begin
        m(i) = "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"/a/f.jl\"}," *
               "\"lines\":{\"text\":\"x\\n\"},\"line_number\":$i,\"submatches\":[]}}"
        e = "{\"type\":\"end\",\"data\":{\"path\":{\"text\":\"/a/f.jl\"},\"stats\":{\"matches\":5}}}"
        files, total, _ = Kaimon._grep_parse_rg(join([[m(i) for i in 1:5]; e], "\n"), 3)
        @test length(files) == 1
        @test files[1].count == 5           # exact count from `end`
        @test length(files[1].hits) == 3    # retained only up to `retain`
        @test total == 5                    # no summary → fallback to sum of `end` counts
    end

    @testset "_grep_waterfill — max-min fair share" begin
        @test Kaimon._grep_waterfill([40, 18], 40) == [22, 18]   # small file whole; big absorbs slack
        @test Kaimon._grep_waterfill([5, 5], 4) == [2, 2]        # even split
        @test Kaimon._grep_waterfill([10, 1, 1], 4) == [2, 1, 1] # tiny files satisfied, remainder → big
        @test Kaimon._grep_waterfill([3, 3], 10) == [3, 3]       # budget ≥ total → everyone full
        @test sum(Kaimon._grep_waterfill([7, 2, 9], 6)) == 6     # never over-allocates
        @test Kaimon._grep_waterfill([5, 5, 5], 2) == [1, 1, 0]  # budget < files → 1 each, in order
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

    @testset "_grep_trunc — verbatim line, trim + width-cap, no markers" begin
        # Lines come back VERBATIM: no inline match markers of any kind (no `**`, no ANSI).
        @test Kaimon._grep_trunc("foo bar baz") == "foo bar baz"        # unchanged
        @test Kaimon._grep_trunc("  x  ") == "x"                        # trims surrounding ws
        # A literal `**` (e.g. a glob pattern in source) survives untouched — the exact case
        # inline markers used to make undecipherable.
        @test Kaimon._grep_trunc("include(\"src/**/*.jl\")") == "include(\"src/**/*.jl\")"
        long = "a"^250
        capped = Kaimon._grep_trunc(long)
        @test endswith(capped, "…") && length(capped) == 201            # 200 chars + ellipsis
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

    @testset "enclosing-symbol column suppressed on the definition line" begin
        if Kaimon._rg_argv() === nothing
            @test_skip "ripgrep not available"
        else
            dir = mktempdir()
            # `NEEDLE_TOK` appears on the const's OWN line (def line) and again in a function body.
            write(joinpath(dir, "a.jl"),
                "const NEEDLE_TOK = 1\n\nfunction wrap()\n    y = NEEDLE_TOK + 1\nend\n")
            out = Kaimon._grep_code(Dict("pattern" => "NEEDLE_TOK", "path" => dir))
            # Def-line hit: no `const NEEDLE_TOK` label duplicating the line text.
            @test occursin("L1  const NEEDLE_TOK = 1", out)
            @test !occursin("const NEEDLE_TOK  const NEEDLE_TOK", out)
            # Body hit still gets its enclosing-symbol column.
            @test occursin("wrap", out)
            rm(dir; recursive = true)
        end
    end

    @testset "fair-share truncation keeps every file visible (honesty headers)" begin
        if Kaimon._rg_argv() === nothing
            @test_skip "ripgrep not available"
        else
            dir = mktempdir()
            # big.jl: 10 matches, small.jl: 2. With budget 6, waterfill gives big 4 and small
            # its full 2 — the small file must NOT be dropped by depth-first truncation.
            write(joinpath(dir, "big.jl"), join(["z$i = 1  # NEEDLE" for i in 1:10], "\n") * "\n")
            write(joinpath(dir, "small.jl"), "a = 1 # NEEDLE\nb = 2 # NEEDLE\n")
            out = Kaimon._grep_code(Dict("pattern" => "NEEDLE", "path" => dir, "limit" => 6))
            @test occursin("12 matches in 2 files, showing 6", out)   # global honesty header
            @test occursin("small.jl", out)                            # small file survives fair-share
            @test occursin("(showing 4 of 10)", out)                   # big.jl clipped: 6 − 2 = 4
            rm(dir; recursive = true)
        end
    end

    @testset "empty result reports files in scope (self-evidencing)" begin
        if Kaimon._rg_argv() === nothing
            @test_skip "ripgrep not available"
        else
            dir = mktempdir()
            write(joinpath(dir, "a.jl"), "hello\n")
            write(joinpath(dir, "b.jl"), "world\n")
            # True negative over real files → "N files in scope", not a bare "No matches".
            out = Kaimon._grep_code(Dict("pattern" => "zzz_absent_qqq", "path" => dir))
            @test occursin("No matches", out) && occursin("2 files in scope", out)
            # A glob matching nothing → 0 files in scope, flagged as a scoping issue, and the
            # glob is echoed back so the caller sees what was actually searched.
            out2 = Kaimon._grep_code(Dict("pattern" => "hello", "path" => dir, "glob" => ["*.nomatch"]))
            @test occursin("0 files in scope", out2) && occursin("glob=", out2)
            rm(dir; recursive = true)
        end
    end

    @testset "slash-anchored globs match regardless of process cwd (out-of-project root)" begin
        # Regression: ripgrep matches slash-containing globs (`sub/*.jl`) against a path
        # relative to rg's PROCESS CWD, not the positional search argument. The long-lived
        # server runs with a cwd that is not the searched repo, so without pinning rg's cwd
        # a `-g dir/…` glob silently matched nothing. Here the search root is OUTSIDE the
        # bound project (path=dir, but base=foreign cwd), so grep anchors globs at the
        # search root itself — `sub/*.jl` is relative to `dir`.
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
                cd(foreign)   # cwd ≠ searched root, and `dir` is outside it → root-anchored
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

    @testset "slash globs are project-root-relative (path + glob don't double-anchor)" begin
        # A `glob` is written the same way as `path=`/`file=`: relative to the PROJECT ROOT.
        # So `path:"src"` + `glob:["src/**/*.jl"]` must NOT double-anchor to `src/src/…` —
        # the exact footgun that made a KaimonSlate worker search return nothing. When the
        # bound project IS the searched tree (cwd == base), globs anchor at that root.
        if Kaimon._rg_argv() === nothing
            @test_skip "ripgrep not available"
        else
            dir = mktempdir()
            mkpath(joinpath(dir, "src"))
            write(joinpath(dir, "src", "worker.jl"), "function g()\n    memo_tok_zz = 1\nend\n")
            write(joinpath(dir, "top.jl"), "memo_tok_zz = 2\n")
            orig = pwd()
            try
                cd(dir)   # bound project == searched tree → base == this dir
                # path narrows to src/, glob is written project-relative (repeats `src/`).
                anchored = Kaimon._grep_code(Dict("pattern" => "memo_tok_zz",
                    "path" => "src", "glob" => ["src/**/*.jl"]))
                @test occursin("worker.jl", anchored)   # no `src/src/…` double-anchor
                # Same glob without a redundant `path` — still project-relative.
                nopath = Kaimon._grep_code(Dict("pattern" => "memo_tok_zz",
                    "glob" => ["src/**/*.jl"]))
                @test occursin("worker.jl", nopath)
                @test !occursin("top.jl", nopath)        # top-level file excluded by glob
                # Basename glob (no `/`) still matches at any depth.
                base = Kaimon._grep_code(Dict("pattern" => "memo_tok_zz", "glob" => ["worker.jl"]))
                @test occursin("worker.jl", base)
            finally
                cd(orig)
            end
            rm(dir; recursive = true)
        end
    end

    @testset "foreign absolute path anchors globs at ITS repo root" begin
        # Grepping a repo OTHER than the bound project via an absolute `path=`: the glob
        # should still be repo-root-relative — anchored at the foreign path's own git repo
        # root, not at the search dir — so `path=<repo>/src` + `glob=["src/worker.jl"]`
        # matches (same feel as grepping your own repo) instead of double-anchoring.
        if Kaimon._rg_argv() === nothing
            @test_skip "ripgrep not available"
        else
            repo = mktempdir()
            mkpath(joinpath(repo, ".git"))            # marks the repo root for _grep_repo_root
            mkpath(joinpath(repo, "src"))
            write(joinpath(repo, "src", "worker.jl"), "function g()\n    memo_tok_zz = 1\nend\n")
            elsewhere = mktempdir()                    # bound cwd, a different (non-repo) tree
            orig = pwd()
            try
                cd(elsewhere)
                src = joinpath(repo, "src")
                # Repo-root-relative slash glob now matches across the repo boundary.
                anchored = Kaimon._grep_code(Dict("pattern" => "memo_tok_zz",
                    "path" => src, "glob" => ["src/worker.jl"]))
                @test occursin("worker.jl", anchored)
                # Basename glob works regardless.
                basen = Kaimon._grep_code(Dict("pattern" => "memo_tok_zz",
                    "path" => src, "glob" => ["worker.jl"]))
                @test occursin("worker.jl", basen)
            finally
                cd(orig)
            end
            rm(repo; recursive = true)
            rm(elsewhere; recursive = true)
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

    @testset "_grep_enclosing_span + collapse grouping" begin
        dir = mktempdir()
        f = joinpath(dir, "x.jl")
        write(f, "function outer(a)\n    a + 1\n    a + 2\nend\n\nstruct Pt\n    x\nend\n")
        _, defs = Kaimon._grep_file_ctx(f, Dict{String,Any}())
        @test Kaimon._grep_enclosing_span(2, defs) == (1, 4)     # inside `outer`
        @test Kaimon._grep_enclosing_span(5, defs) === nothing   # blank line between defs
        # Two hits sharing an enclosing def collapse into one group (rep + rest); a hit in
        # a different def is its own group; encounter order preserved.
        hits = Any[(file = f, line = 2, text = "a + 1"),
                   (file = f, line = 3, text = "a + 2"),
                   (file = f, line = 6, text = "x")]
        groups = Kaimon._grep_group_by_enclosing(hits, defs)
        @test length(groups) == 2
        @test groups[1][1].line == 2 && [h.line for h in groups[1][2]] == [3]   # outer: rep L2 (+L3)
        @test groups[2][1].line == 6 && isempty(groups[2][2])                    # Pt: standalone
        # Empty defs (what a forced context= request passes) → no collapsing.
        solo = Kaimon._grep_group_by_enclosing(hits, Tuple{Int,Int,String,String}[])
        @test length(solo) == 3 && all(isempty(g[2]) for g in solo)
        rm(dir; recursive = true)
    end

    @testset "_grep_code collapses repeats in one function" begin
        if Kaimon._rg_argv() === nothing
            @test_skip "ripgrep not available"
        else
            dir = mktempdir()
            write(joinpath(dir, "a.jl"), "function many()\n    z = 1\n    z = 2\n    z = 3\nend\n")
            out = Kaimon._grep_code(Dict("pattern" => "z =", "path" => dir))
            @test occursin("many", out)          # enclosing symbol shown once
            @test occursin("(+2 more", out)       # 3 hits in one fn → rep + "(+2 more: L3, L4)"
            # A forced context= renders every hit instead of collapsing.
            ctxout = Kaimon._grep_code(Dict("pattern" => "z =", "path" => dir, "context" => 1))
            @test !occursin("(+2 more", ctxout) && occursin("L4", ctxout)
            rm(dir; recursive = true)
        end
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

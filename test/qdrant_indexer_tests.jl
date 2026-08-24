# Code Chunking Tests (no external dependencies - safe for CI)
#
# These tests verify the Julia AST parsing and code chunking logic.
# They don't require Qdrant or Ollama to be running.

using ReTest
using Kaimon

@testset "Code Chunking Tests" begin
    @testset "get_project_collection_name" begin
        @test Kaimon.get_project_collection_name("/Users/test/MyProject") == "myproject"
        @test Kaimon.get_project_collection_name("/Users/test/my-project") == "my_project"
        @test Kaimon.get_project_collection_name("/Users/test/Kaimon.jl") == "kaimon"
        @test Kaimon.get_project_collection_name("/path/to/My Project!") == "my_project"
        @test Kaimon.get_project_collection_name("/path/to/test--dir") == "test_dir"
    end

    @testset "extract_definitions - functions" begin
        code = """
        function hello(name)
            println("Hello, \$name!")
        end
        """
        chunks = Kaimon.extract_definitions(code, "test.jl")
        @test length(chunks) >= 1
        func_chunks = filter(c -> c["type"] == "function", chunks)
        @test length(func_chunks) == 1
        @test func_chunks[1]["name"] == "hello"
        @test func_chunks[1]["start_line"] == 1
        @test func_chunks[1]["end_line"] == 3
    end

    @testset "extract_definitions - short functions" begin
        code = """
        add(x, y) = x + y
        multiply(a, b) = a * b
        """
        chunks = Kaimon.extract_definitions(code, "test.jl")
        func_chunks = filter(c -> c["type"] == "function", chunks)
        @test length(func_chunks) == 2
        names = [c["name"] for c in func_chunks]
        @test "add" in names
        @test "multiply" in names
    end

    @testset "extract_definitions - structs" begin
        code = """
        struct Point
            x::Float64
            y::Float64
        end

        mutable struct Counter
            value::Int
        end
        """
        chunks = Kaimon.extract_definitions(code, "test.jl")
        struct_chunks = filter(c -> c["type"] == "struct", chunks)
        @test length(struct_chunks) >= 1
        names = [c["name"] for c in struct_chunks]
        @test "Point" in names
    end

    @testset "extract_definitions - with docstrings" begin
        # Note: Docstring handling with heredocs is complex due to whitespace
        # This tests that functions with docstrings are still extracted
        code = "\"\"\"Docs\"\"\"\nfunction greet(name)\n    println(\"Hi\")\nend"
        chunks = Kaimon.extract_definitions(code, "test.jl")
        func_chunks = filter(c -> c["type"] == "function", chunks)
        @test length(func_chunks) >= 1
        if !isempty(func_chunks)
            @test func_chunks[1]["name"] == "greet"
        end
    end

    @testset "extract_definitions - nested in module" begin
        code = """
        module MyMod
            function inner_func(x)
                x * 2
            end
        end
        """
        chunks = Kaimon.extract_definitions(code, "test.jl")
        func_chunks = filter(c -> c["type"] == "function", chunks)
        @test length(func_chunks) >= 1
        @test any(c -> c["name"] == "inner_func", func_chunks)
    end

    @testset "extract_definitions - docstring'd module (regression)" begin
        # A file-leading docstring makes the WHOLE file `@doc "..." module X ...`.
        # The old @doc handler only descended into function/struct/=, so it
        # skipped the module and found ZERO symbols — which is exactly why
        # document_symbols came back empty on idiomatic package files.
        code = "\"\"\"\nMyMod docs.\n\"\"\"\nmodule MyMod\n    struct Widget\n        x::Int\n    end\n    function inner_func(x)\n        x * 2\n    end\n    const K = 42\nend"
        chunks = Kaimon.extract_definitions(code, "test.jl")
        @test any(c -> c["name"] == "inner_func", chunks)
        @test any(c -> c["name"] == "Widget", chunks)
        @test any(c -> c["name"] == "K", chunks)
    end

    @testset "extract_definitions - overloaded methods anchor distinctly (regression)" begin
        # Two methods of one function must each get THEIR OWN span + body. The old
        # get_expr_lines regex-scanned from the top of the file for `function <name>`,
        # so every method resolved to the FIRST signature's lines — producing duplicate
        # chunks (identical span + text, differing only in the signature metadata). The
        # AST LineNumberNode hint now anchors each method on its own occurrence.
        code = "function g(a)\n    a\nend\n\nfunction g(a, b)\n    a + b\nend\n"
        chunks = Kaimon.extract_definitions(code, "test.jl")
        gs = filter(c -> c["name"] == "g", chunks)
        @test length(gs) == 2
        spans = Set((c["start_line"], c["end_line"]) for c in gs)
        @test length(spans) == 2                      # NOT collapsed onto one span
        @test (1, 3) in spans && (5, 7) in spans
        # Each chunk carries its OWN body (the 2-arg method must not show the 1-arg text).
        m2 = only(filter(c -> (c["start_line"], c["end_line"]) == (5, 7), gs))
        @test occursin("g(a, b)", m2["text"]) && occursin("a + b", m2["text"])
        @test !occursin("a + b", only(filter(c -> c["start_line"] == 1, gs))["text"])

        # Same, but with a docstring on the first method (the bind.jl shape that surfaced
        # this): the docstring must not drag the second method onto the first's span.
        doc = "\"\"\"doc\"\"\"\nfunction h(x::Int)\n    x\nend\n\nfunction h(x::String)\n    x\nend\n"
        hs = filter(c -> c["name"] == "h", Kaimon.extract_definitions(doc, "test.jl"))
        @test length(hs) == 2
        @test length(Set((c["start_line"], c["end_line"]) for c in hs)) == 2
        @test any(c -> occursin("x::String", c["text"]), hs)
    end

    @testset "extract_definitions - mid-line block openers don't truncate the span (regression)" begin
        # `x = let … end` and `… do … end` put an `end` on a later line with no opener
        # visible at line start; the old keyword depth-counter underflowed and cut the
        # function off at the first inner `end`. The indent-matched end finder spans full.
        code = join([
            "function big(x)",          # 1
            "    y = let a = x",         # 2
            "        a + 1",             # 3
            "    end",                   # 4  (inner end — must NOT terminate `big`)
            "    z = map(1:3) do i",     # 5
            "        i * y",             # 6
            "    end",                   # 7  (inner end — must NOT terminate `big`)
            "    return z",              # 8
            "end",                       # 9  (the real end)
            "const AFTER = 1",           # 10
        ], "\n")
        big = only(filter(c -> c["name"] == "big", Kaimon.extract_definitions(code, "test.jl")))
        @test (big["start_line"], big["end_line"]) == (1, 9)
        @test occursin("return z", big["text"])
    end

    @testset "create_window_chunks" begin
        code = "line1\nline2\nline3\nline4\nline5"
        chunks = Kaimon.create_window_chunks(code, "small.jl")
        @test length(chunks) >= 1
        @test chunks[1]["type"] == "window"
        @test chunks[1]["file"] == "small.jl"

        large_code = join(["line $i" for i = 1:200], "\n")
        large_chunks = Kaimon.create_window_chunks(large_code, "large.jl")
        @test length(large_chunks) > 1
        if length(large_chunks) >= 2
            @test large_chunks[2]["start_line"] < large_chunks[1]["end_line"]
        end
    end

    @testset "chunk_code - combined" begin
        code = """
        module Utils
        function helper(x)
            x + 1
        end
        const VERSION = "1.0"
        end
        """
        chunks = Kaimon.chunk_code(code, "utils.jl")
        @test length(chunks) >= 1
        types = Set([c["type"] for c in chunks])
        @test "function" in types || "window" in types
    end

    @testset "get_definition_name" begin
        expr = Meta.parse("function foo(x) x end")
        @test Kaimon.get_definition_name(expr) == "foo"

        expr = Meta.parse("bar(x) = x * 2")
        @test Kaimon.get_definition_name(expr) == "bar"
    end

    @testset "get_expr_lines" begin
        lines = split(
            """
# Comment
function test_func(x)
    return x + 1
end
# More code
""",
            '\n',
        )

        expr = Meta.parse("function test_func(x) x + 1 end")
        start_line, end_line = Kaimon.get_expr_lines(expr, lines)
        @test start_line == 2
        @test end_line == 4
    end

    @testset "get_expr_lines - line_hint disambiguates same-named methods" begin
        lines = split("function dup(x)\n  x\nend\nfunction dup(x, y)\n  x + y\nend\n", '\n')
        expr2 = Meta.parse("function dup(x, y) x + y end")
        # With the AST hint at the 2nd method's line, it anchors there (4-6)…
        @test Kaimon.get_expr_lines(expr2, lines, 4) == (4, 6)
        # …and a stale/out-of-range hint falls back to a whole-file scan (never lost).
        @test Kaimon.get_expr_lines(expr2, lines, 999) == (1, 3)
        # Hint 0 (unknown) preserves the legacy first-match behavior.
        @test Kaimon.get_expr_lines(expr2, lines) == (1, 3)
    end
end

@testset "qdrant point ID coercion" begin
    cp = Kaimon.QdrantClient._coerce_point_id
    # Numeric IDs (and numeric strings) normalize to integers so they match
    # points stored with integer IDs — regression for delete_points stringifying
    # numeric IDs (which never matched, silently deleting nothing).
    @test cp(1) === 1
    @test cp("1") === 1
    @test cp("42") === 42
    @test cp(2.0) === 2          # JSON numbers may arrive as Float64
    # UUID / non-numeric strings pass through unchanged
    @test cp("a1b2-uuid") == "a1b2-uuid"
    @test cp("abc") == "abc"
end

# Size-based chunk splitting, decoupled from embedding (no Ollama). Underpins the
# FTS-first / embed-second two-pass index.
@testset "split_to_fit" begin
    mk(text; sl=1, el=9, name="w") = Dict("file"=>"/a/x.jl", "start_line"=>sl, "end_line"=>el,
                                          "type"=>"window", "name"=>name, "text"=>text)
    @testset "in-size chunk returned unchanged" begin
        c = mk("short")
        parts = Kaimon.split_to_fit(c, 1000)
        @test length(parts) == 1
        @test parts[1]["text"] == "short"
    end
    @testset "oversized chunk splits into fitting pieces" begin
        c = mk(join(["line $i" for i in 1:9], "\n"))
        parts = Kaimon.split_to_fit(c, 20)
        @test length(parts) > 1
        @test all(p -> length(p["text"]) <= 20, parts)
        # spans stay within the original; names get "(part N)" suffixes
        @test all(p -> p["start_line"] >= 1 && p["end_line"] <= 9, parts)
        @test any(p -> occursin("part", p["name"]), parts)
    end
    @testset "unsplittable single line is truncated, not dropped" begin
        c = mk("x"^100)  # one line, no newlines
        parts = Kaimon.split_to_fit(c, 10)
        @test length(parts) == 1
        @test length(parts[1]["text"]) == 10
    end
end

# Deterministic point IDs (C): same content+location → same ID (idempotent reindex),
# any change → new ID. Pure uuid5, no Qdrant/Ollama.
@testset "deterministic point IDs" begin
    base = Dict("file"=>"/a/x.jl", "start_line"=>1, "end_line"=>5,
                "type"=>"function", "name"=>"f", "text"=>"f() = 1")
    pid = Kaimon._chunk_point_id
    id = pid("proj", base)
    @test id == pid("proj", copy(base))                                   # deterministic
    @test id != pid("proj", merge(base, Dict("text"=>"f() = 2")))         # content-sensitive
    @test id != pid("proj", merge(base, Dict("start_line"=>2)))           # span-sensitive
    @test id != pid("proj", merge(base, Dict("file"=>"/a/y.jl")))         # file-sensitive
    @test id != pid("other", base)                                        # collection-scoped
    @test id isa String && length(id) == 36                              # well-formed UUID string

    # Regression: chunk text with regex/backslash escapes must not throw. Julia's
    # uuid5 runs unescape_string on its name, which errors on `\d`/`\w`; the ID must
    # be SHA-hashed first so regex-heavy code indexes cleanly.
    rgx = merge(base, Dict("text"=>"m = match(r\"\\b(\\d+)\\w*\\\$\", s)"))
    @test (pid("proj", rgx); true)                                        # no throw
    @test pid("proj", rgx) == pid("proj", copy(rgx))                      # still deterministic
    @test pid("proj", rgx) != id                                          # distinct from plain text
end

# Coalescing guard (A): many triggers fire sync_index for one project concurrently;
# only one runs at a time and rapid triggers collapse to a single pending re-run.
@testset "_run_coalesced sync guard" begin
    K = Kaimon
    @testset "concurrent triggers coalesce" begin
        key = "/tmp/kaimon-coalesce-" * string(rand(UInt32))
        ran = Threads.Atomic{Int}(0)
        f = () -> (Threads.atomic_add!(ran, 1); sleep(0.2); :done)
        tasks = [Threads.@spawn K._run_coalesced(key, f) for _ in 1:6]
        results = fetch.(tasks)
        @test ran[] <= 2                                       # initial + at most one coalesced re-run
        @test any(r -> r === :done, results)                   # the runner returned the value
        @test any(r -> r === nothing, results)                 # others coalesced
        @test !(key in K._SYNC_RUNNING) && !(key in K._SYNC_PENDING)   # state cleaned up
    end
    @testset "different keys run independently" begin
        @test K._run_coalesced("/tmp/kaimon-key-" * string(rand(UInt32)), () -> 42) == 42
    end
    @testset "sync_index wrapper passes (key, thunk) in the right order" begin
        # Exercises the real sync_index → _run_coalesced call path (the unit tests above
        # call _run_coalesced directly, so they'd miss a `do`-block arg-order bug in the
        # wrapper). An empty temp project needs no Qdrant/Ollama.
        tmp = mktempdir()
        r = K.sync_index(tmp; verbose=false, silent=true)
        @test r.reindexed == 0 && r.deleted == 0 && r.chunks == 0
        rm(tmp; recursive=true)
    end
    @testset "exception clears the key" begin
        key = "/tmp/kaimon-coalesce-err-" * string(rand(UInt32))
        @test_throws ErrorException K._run_coalesced(key, () -> error("boom"))
        @test !(key in K._SYNC_RUNNING) && !(key in K._SYNC_PENDING)
    end
end

# Transient-error retry (B) for Qdrant upserts (stale keepalive / reset).
@testset "Qdrant upsert retry" begin
    Q = Kaimon.QdrantClient
    @testset "transient classification" begin
        @test Q._is_transient_http(EOFError())
        @test Q._is_transient_http(Base.IOError("connection reset", -54))
        @test !Q._is_transient_http(ArgumentError("not a connection error"))
    end
    @testset "retries transient then succeeds" begin
        n = Ref(0)
        r = Q._with_http_retry(tries=4) do
            n[] += 1
            n[] < 3 && throw(EOFError())   # fail twice, succeed on the third
            :ok
        end
        @test r === :ok
        @test n[] == 3
    end
    @testset "rethrows a non-transient error without retrying" begin
        n = Ref(0)
        @test_throws ArgumentError Q._with_http_retry(tries=4) do
            n[] += 1
            throw(ArgumentError("fatal"))
        end
        @test n[] == 1
    end
end

# Index target resolution (#80). These build throwaway projects that are never
# registered, so resolution always takes the auto-detection path.
@testset "index target resolution" begin
    K = Kaimon
    _git = Sys.which("git") !== nothing
    _init_repo(p) = (run(`git -C $p init -q`); run(`git -C $p add -A`); nothing)
    _rel(files, p) = sort(relpath.(files, p))

    @testset "root-level sources are indexed when there is no src/" begin
        # The reported bug: a project whose code sits in the root. The stale count
        # scanned the whole tree while indexing visited nothing.
        p = mktempdir()
        write(joinpath(p, "Project.toml"), "name = \"RootScripts\"\n")
        write(joinpath(p, "analysis.jl"), "f(x) = x^2\n")
        write(joinpath(p, "README.md"), "# hi\n")
        mkpath(joinpath(p, "docs"))
        write(joinpath(p, "docs", "guide.md"), "# guide\n")
        _git && _init_repo(p)

        files = _rel(K.project_index_files(p), p)
        @test "analysis.jl" in files
        @test "docs/guide.md" in files
    end

    @testset "root-level sources survive alongside subdirectories" begin
        # Auto-detection used to drop root files whenever any subdir had sources.
        p = mktempdir()
        write(joinpath(p, "Project.toml"), "name = \"Both\"\n")
        write(joinpath(p, "toplevel.jl"), "t() = 1\n")
        mkpath(joinpath(p, "src"))
        write(joinpath(p, "src", "inner.jl"), "i() = 2\n")
        _git && _init_repo(p)

        files = _rel(K.project_index_files(p), p)
        @test "toplevel.jl" in files
        @test "src/inner.jl" in files
    end

    @testset "the stale count is the set indexing will visit" begin
        # The invariant behind #80: the Collection Manager's number and the indexer's
        # work must come from one enumeration. Nothing is indexed yet, so every
        # enumerated file is stale.
        p = mktempdir()
        write(joinpath(p, "Project.toml"), "name = \"Sync\"\n")
        write(joinpath(p, "root.jl"), "r() = 1\n")
        mkpath(joinpath(p, "lib"))
        write(joinpath(p, "lib", "helper.jl"), "h() = 2\n")
        _git && _init_repo(p)

        @test Set(K.get_stale_files(p)) == Set(K.project_index_files(p))
        @test length(K.get_stale_files(p)) >= 2
    end

    @testset "sources are found across languages" begin
        p = mktempdir()
        write(joinpath(p, "Project.toml"), "name = \"Poly\"\n")
        mkpath(joinpath(p, "src")); write(joinpath(p, "src", "s.jl"), "s() = 1\n")
        mkpath(joinpath(p, "api")); write(joinpath(p, "api", "h.py"), "def h(): pass\n")
        mkpath(joinpath(p, "core")); write(joinpath(p, "core", "e.rs"), "fn main() {}\n")
        mkpath(joinpath(p, "web")); write(joinpath(p, "web", "A.tsx"), "export const A = 1\n")
        _git && _init_repo(p)

        files = _rel(K.project_index_files(p), p)
        @test "src/s.jl" in files
        @test "api/h.py" in files
        @test "core/e.rs" in files
        @test "web/A.tsx" in files
    end

    @testset "committed build output is excluded" begin
        p = mktempdir()
        write(joinpath(p, "package.json"), "{}\n")
        mkpath(joinpath(p, "src")); write(joinpath(p, "src", "app.ts"), "export const a = 1\n")
        mkpath(joinpath(p, "dist"))
        write(joinpath(p, "dist", "b.min.js"), "var a=1;"^2000)
        write(joinpath(p, "dist", "b.ts"), "export const b = 2\n")
        mkpath(joinpath(p, "types")); write(joinpath(p, "types", "api.d.ts"), "export type A = 1\n")
        _git && run(`git -C $p init -q`)
        _git && run(`git -C $p add -A -f`)   # -f: force past any global gitignore

        files = _rel(K.project_index_files(p), p)
        @test "src/app.ts" in files
        @test !any(f -> startswith(f, "dist/"), files)   # build directory
        @test !("types/api.d.ts" in files)               # generated typings
    end

    @testset "a minified file outside a build directory is rejected" begin
        p = mktempdir()
        mkpath(joinpath(p, "src"))
        write(joinpath(p, "src", "real.ts"), "export const r = 1\n")
        # One line, well past the ceiling — the shape of generated output.
        write(joinpath(p, "src", "blob.ts"), "export const B = \"" * "x"^(K.MAX_INDEX_LINE_BYTES + 500) * "\"")
        _git && _init_repo(p)

        files = _rel(K.project_index_files(p), p)
        @test "src/real.ts" in files
        @test !("src/blob.ts" in files)
    end

    @testset ".gitignore is honoured" begin
        if _git
            p = mktempdir()
            write(joinpath(p, "Project.toml"), "name = \"Ign\"\n")
            mkpath(joinpath(p, "src")); write(joinpath(p, "src", "a.jl"), "a() = 1\n")
            # A build directory whose name is not in IGNORED_DIRS — only .gitignore
            # can exclude it.
            mkpath(joinpath(p, "generated_output"))
            write(joinpath(p, "generated_output", "big.jl"), "z() = 1\n")
            write(joinpath(p, ".gitignore"), "generated_output/\n")
            _init_repo(p)

            files = _rel(K.project_index_files(p), p)
            @test "src/a.jl" in files
            @test !any(f -> startswith(f, "generated_output/"), files)
        end
    end

    @testset "non-git projects fall back to a directory walk" begin
        p = mktempdir()
        write(joinpath(p, "main.py"), "def m(): pass\n")
        mkpath(joinpath(p, "node_modules", "pkg"))
        write(joinpath(p, "node_modules", "pkg", "i.ts"), "export const i = 1\n")
        mkpath(joinpath(p, "dist")); write(joinpath(p, "dist", "o.ts"), "export const o = 1\n")

        files = _rel(K.project_index_files(p), p)
        @test "main.py" in files
        @test !any(f -> startswith(f, "node_modules/"), files)
        @test !any(f -> startswith(f, "dist/"), files)
    end

    @testset "overlapping directories enumerate each file once" begin
        p = mktempdir()
        mkpath(joinpath(p, "src")); write(joinpath(p, "src", "a.jl"), "a() = 1\n")
        _git && _init_repo(p)

        @test K._collapse_subsumed_dirs([joinpath(p, "src"), p]) == [abspath(p)]
        files = K.collect_index_files(p; dirs=[p, joinpath(p, "src")], extensions=[".jl"])
        @test length(files) == length(unique(files))
        @test length(files) == 1
    end

    @testset "an explicit extension list narrows the scan" begin
        p = mktempdir()
        mkpath(joinpath(p, "src"))
        write(joinpath(p, "src", "a.jl"), "a() = 1\n")
        write(joinpath(p, "src", "b.py"), "def b(): pass\n")
        _git && _init_repo(p)

        files = _rel(K.project_index_files(p; extensions=[".jl"]), p)
        @test files == ["src/a.jl"]
    end

    @testset "Julia's deps/ is source, not build output" begin
        # `deps/build.jl` is real source in a Julia package; it must not be swept up
        # with the generic build-output directory names.
        @test !("deps" in K.IGNORED_DIRS)
        p = mktempdir()
        write(joinpath(p, "Project.toml"), "name = \"WithDeps\"\n")
        mkpath(joinpath(p, "src")); write(joinpath(p, "src", "a.jl"), "a() = 1\n")
        mkpath(joinpath(p, "deps")); write(joinpath(p, "deps", "build.jl"), "b() = 1\n")
        _git && _init_repo(p)

        @test "deps/build.jl" in _rel(K.project_index_files(p), p)
    end

    @testset "the root is a non-recursive target, not a catch-all" begin
        # Root-level sources must be indexed without the root swallowing the whole
        # tree — the detected subdirectories stay listed in their own right.
        if _git
            p = mktempdir()
            write(joinpath(p, "Project.toml"), "name = \"Collapse\"\n")
            write(joinpath(p, "README.md"), "# readme\n")
            mkpath(joinpath(p, "src")); write(joinpath(p, "src", "a.jl"), "a() = 1\n")
            mkpath(joinpath(p, "docs")); write(joinpath(p, "docs", "d.md"), "# d\n")
            _init_repo(p)

            dirs = K.auto_detect_project_config(p).dirs
            parsed = map(K._parse_target, dirs)
            root = first(t for t in parsed if t[1] == abspath(p))
            @test root[2] == false                                   # root does not recurse
            @test abspath(joinpath(p, "src")) in [t[1] for t in parsed]
            @test abspath(joinpath(p, "docs")) in [t[1] for t in parsed]
        end
    end

    @testset "a new top-level directory is not silently absorbed" begin
        if _git
            p = mktempdir()
            write(joinpath(p, "Project.toml"), "name = \"Bounded\"\n")
            mkpath(joinpath(p, "src")); write(joinpath(p, "src", "a.jl"), "a() = 1\n")
            _init_repo(p)
            dirs = K.auto_detect_project_config(p).dirs

            # A directory that appears after the scope was resolved stays out of it.
            mkpath(joinpath(p, "scratch"))
            write(joinpath(p, "scratch", "junk.jl"), "j() = 1\n")
            run(`git -C $p add -A`)

            files = _rel(K.collect_index_files(p; dirs=dirs, extensions=[".jl", ".toml"]), p)
            @test "src/a.jl" in files
            @test !("scratch/junk.jl" in files)
        end
    end

    @testset "a non-recursive target yields only its own files" begin
        p = mktempdir()
        write(joinpath(p, "top.jl"), "t() = 1\n")
        mkpath(joinpath(p, "sub")); write(joinpath(p, "sub", "deep.jl"), "d() = 1\n")
        _git && _init_repo(p)

        files = _rel(K.collect_index_files(p; dirs=[K._nonrecursive(p)], extensions=[".jl"]), p)
        @test files == ["top.jl"]

        # And the marker survives a round trip through the collapse step.
        @test K._parse_target(K._nonrecursive(p)) == (abspath(p), false)
        kept = K._collapse_subsumed_dirs([K._nonrecursive(p), joinpath(p, "sub")])
        @test length(kept) == 2   # non-recursive root does not subsume the subdirectory
    end

    @testset "a missing directory is reported, not silently dropped" begin
        p = mktempdir()
        mkpath(joinpath(p, "src")); write(joinpath(p, "src", "a.jl"), "a() = 1\n")
        cfg = K.resolve_index_config(p; extra_dirs=["does_not_exist"])
        @test any(d -> endswith(d, "does_not_exist"), cfg.missing_dirs)
        @test !any(d -> endswith(d, "does_not_exist"), cfg.dirs)
    end

    @testset "auto-detection ignores build output when choosing extensions" begin
        # A committed bundle directory must not make `.js` look like the project's
        # dominant source language.
        p = mktempdir()
        mkpath(joinpath(p, "src")); write(joinpath(p, "src", "a.jl"), "a() = 1\n")
        mkpath(joinpath(p, "dist"))
        for i in 1:20
            write(joinpath(p, "dist", "chunk$i.js"), "var x = $i;\n")
        end
        if _git
            run(`git -C $p init -q`); run(`git -C $p add -A -f`)
            detected = K.auto_detect_project_config(p)
            @test ".jl" in detected.extensions
            @test !(".js" in detected.extensions)
        end
    end
end

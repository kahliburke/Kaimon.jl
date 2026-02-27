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
end

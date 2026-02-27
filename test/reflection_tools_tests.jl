using ReTest
using Kaimon
using Kaimon:
    MCPTool, extract_symbol_at_position, extract_definitions, grep_project_for_definition

@testset "Reflection Tools Tests" begin

    @testset "Tool Creation" begin
        tools = Kaimon.create_reflection_tools()
        @test length(tools) == 3

        tool_names = [tool.name for tool in tools]
        @test "goto_definition" in tool_names
        @test "document_symbols" in tool_names
        @test "workspace_symbols" in tool_names

        for tool in tools
            @test tool isa MCPTool
            @test haskey(tool.parameters, "type")
            @test haskey(tool.parameters, "properties")
            @test haskey(tool.parameters, "required")
            @test !isempty(tool.description)
        end
    end

    @testset "Tool Parameter Schemas" begin
        tools = Kaimon.create_reflection_tools()

        # goto_definition
        goto_def = filter(t -> t.id == :goto_definition, tools)[1]
        @test haskey(goto_def.parameters["properties"], "file_path")
        @test haskey(goto_def.parameters["properties"], "line")
        @test haskey(goto_def.parameters["properties"], "column")
        @test haskey(goto_def.parameters["properties"], "session")
        @test "file_path" in goto_def.parameters["required"]
        @test "line" in goto_def.parameters["required"]
        @test "column" in goto_def.parameters["required"]

        # document_symbols
        doc_syms = filter(t -> t.id == :document_symbols, tools)[1]
        @test haskey(doc_syms.parameters["properties"], "file_path")
        @test "file_path" in doc_syms.parameters["required"]

        # workspace_symbols
        ws_syms = filter(t -> t.id == :workspace_symbols, tools)[1]
        @test haskey(ws_syms.parameters["properties"], "query")
        @test haskey(ws_syms.parameters["properties"], "session")
        @test "query" in ws_syms.parameters["required"]
    end

    @testset "extract_symbol_at_position" begin
        # Create a temporary file with known content
        tmp = tempname() * ".jl"
        write(
            tmp,
            """function hello_world(x)
    return x + 1
end
Base.sort([3,1,2])
""",
        )

        try
            # "hello_world" starts at col 10, ends at col 20 on line 1
            @test extract_symbol_at_position(tmp, 1, 10) == "hello_world"
            @test extract_symbol_at_position(tmp, 1, 15) == "hello_world"

            # "function" keyword at col 1
            @test extract_symbol_at_position(tmp, 1, 1) == "function"

            # "x" parameter at col 21
            @test extract_symbol_at_position(tmp, 1, 22) == "x"

            # Dotted name: "Base.sort" on line 4
            @test extract_symbol_at_position(tmp, 4, 1) == "Base.sort"
            @test extract_symbol_at_position(tmp, 4, 6) == "Base.sort"

            # Out-of-bounds cases
            @test extract_symbol_at_position(tmp, 100, 1) == ""
            @test extract_symbol_at_position(tmp, 1, 100) == ""

            # Non-existent file
            @test extract_symbol_at_position("/nonexistent/file.jl", 1, 1) == ""
        finally
            rm(tmp; force = true)
        end
    end

    @testset "document_symbols on real file" begin
        tools = Kaimon.create_reflection_tools()
        doc_syms = filter(t -> t.id == :document_symbols, tools)[1]

        # Run against the project's own tool_definitions.jl
        file_path = joinpath(dirname(@__DIR__), "src", "tool_definitions.jl")
        if isfile(file_path)
            result = doc_syms.handler(Dict("file_path" => file_path))
            @test contains(result, "symbol(s)")
            @test contains(result, "Function") || contains(result, "Tool")
        end
    end

    @testset "document_symbols on temp file" begin
        tools = Kaimon.create_reflection_tools()
        doc_syms = filter(t -> t.id == :document_symbols, tools)[1]

        tmp = tempname() * ".jl"
        write(
            tmp,
            """
struct MyType
    x::Int
end

function my_func(a, b)
    return a + b
end

const MY_CONST = 42

macro my_macro(ex)
    esc(ex)
end
""",
        )
        try
            result = doc_syms.handler(Dict("file_path" => tmp))
            @test contains(result, "MyType")
            @test contains(result, "my_func")
            @test contains(result, "my_macro")
            @test contains(result, "Type") || contains(result, "struct")
            @test contains(result, "Function")
        finally
            rm(tmp; force = true)
        end
    end

    @testset "Error Handling" begin
        tools = Kaimon.create_reflection_tools()

        # goto_definition: empty file_path
        goto_def = filter(t -> t.id == :goto_definition, tools)[1]
        result = goto_def.handler(Dict("file_path" => "", "line" => 1, "column" => 1))
        @test contains(result, "Error")

        # goto_definition: non-existent file
        result2 = goto_def.handler(
            Dict("file_path" => "/nonexistent/file.jl", "line" => 1, "column" => 1),
        )
        @test contains(result2, "Error") || contains(result2, "not found")

        # document_symbols: empty file_path
        doc_syms = filter(t -> t.id == :document_symbols, tools)[1]
        result3 = doc_syms.handler(Dict("file_path" => ""))
        @test contains(result3, "Error")

        # document_symbols: non-existent file
        result4 = doc_syms.handler(Dict("file_path" => "/nonexistent/file.jl"))
        @test contains(result4, "Error") || contains(result4, "not found")

        # workspace_symbols: empty query
        ws_syms = filter(t -> t.id == :workspace_symbols, tools)[1]
        result5 = ws_syms.handler(Dict("query" => ""))
        @test contains(result5, "Error") || contains(result5, "required")
    end

    @testset "grep_project_for_definition" begin
        # Create a temporary project structure
        tmp_dir = mktempdir()
        src_dir = joinpath(tmp_dir, "src")
        mkpath(src_dir)
        write(
            joinpath(src_dir, "test_file.jl"),
            """
function my_test_func(x)
    return x
end

struct MyTestStruct
    field::Int
end

const MY_TEST_CONST = 42
""",
        )
        try
            withenv("MCPREPL_PROJECT_DIR" => tmp_dir) do
                results = grep_project_for_definition("my_test_func")
                @test length(results) >= 1
                @test any(r -> contains(r, "test_file.jl"), results)

                results2 = grep_project_for_definition("MyTestStruct")
                @test length(results2) >= 1

                results3 = grep_project_for_definition("MY_TEST_CONST")
                @test length(results3) >= 1

                # Non-existent symbol
                results4 = grep_project_for_definition("nonexistent_xyz_abc")
                @test isempty(results4)

                # Empty symbol
                results5 = grep_project_for_definition("")
                @test isempty(results5)
            end
        finally
            rm(tmp_dir; recursive = true, force = true)
        end
    end
end

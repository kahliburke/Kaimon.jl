using Test
using KaimonGate

# ── Local test types and handlers ─────────────────────────────────────────────

@enum _DispatchPriority low medium high critical
@enum _DispatchStatus todo in_progress done

struct _DispatchTag
    name::String
    color::Symbol
end

"""A simple greeter for dispatch tests."""
function _greet(name::String, count::Int; loud::Bool=false, prefix::String="Hi")
    msg = "$prefix $name (×$count)"
    loud ? uppercase(msg) : msg
end

"""Handler that accepts a raw Dict."""
function _dict_handler(args::Dict{String,Any})
    return "raw:$(args["key"])"
end

"""Handler with enum and struct args."""
function _task_handler(
    title::String,
    priority::_DispatchPriority,
    tags::Vector{_DispatchTag};
    status::_DispatchStatus=todo,
)
    tag_names = join([t.name for t in tags], ",")
    "title=$title priority=$(priority) tags=[$tag_names] status=$status"
end

# ── _reflect_tool ─────────────────────────────────────────────────────────────

@testset "_reflect_tool" begin
    tool = KaimonGate.GateTool("greet", _greet)
    schema = KaimonGate._reflect_tool(tool)

    @test schema["name"] == "greet"
    @test !isempty(schema["description"])
    @test occursin("greeter", schema["description"])

    args = schema["arguments"]
    arg_names = [a["name"] for a in args]
    @test "name" in arg_names
    @test "count" in arg_names

    name_arg = args[findfirst(a -> a["name"] == "name", args)]
    @test name_arg["type_meta"]["kind"] == "string"
    count_arg = args[findfirst(a -> a["name"] == "count", args)]
    @test count_arg["type_meta"]["kind"] == "integer"
end

# ── _dispatch_tool_call: positional args from strings ────────────────────────
# (Adapted from GateToolTest "positional Int + Enum")

@testset "_dispatch_tool_call positional" begin
    dispatch = KaimonGate._dispatch_tool_call

    result = dispatch(_greet, Dict{String,Any}("name" => "Alice", "count" => "3"))
    @test result == "Hi Alice (×3)"

    # Enum positional
    result2 = dispatch(
        _task_handler,
        Dict{String,Any}(
            "title" => "Fix bug",
            "priority" => "high",
            "tags" => [],
        ),
    )
    @test occursin("title=Fix bug", result2)
    @test occursin("priority=high", result2)
end

# ── _dispatch_tool_call: kwargs from strings ──────────────────────────────────
# (Adapted from GateToolTest "all scalar types positional + kwargs")

@testset "_dispatch_tool_call kwargs" begin
    dispatch = KaimonGate._dispatch_tool_call

    # With kwargs provided as strings
    result = dispatch(
        _greet,
        Dict{String,Any}(
            "name" => "Bob",
            "count" => "2",
            "loud" => "true",
            "prefix" => "Hello",
        ),
    )
    @test result == "HELLO BOB (×2)"

    # kwargs defaults used when omitted
    result2 = dispatch(
        _greet,
        Dict{String,Any}("name" => "Carol", "count" => "1"),
    )
    @test result2 == "Hi Carol (×1)"   # loud=false, prefix="Hi" defaults
end

# ── _dispatch_tool_call: Dict fast path ───────────────────────────────────────

@testset "_dispatch_tool_call Dict handler" begin
    dispatch = KaimonGate._dispatch_tool_call
    result = dispatch(_dict_handler, Dict{String,Any}("key" => "treasure"))
    @test result == "raw:treasure"
end

# ── _kwarg_types ──────────────────────────────────────────────────────────────

@testset "_kwarg_types" begin
    kt = KaimonGate._kwarg_types

    # Named top-level function
    types = kt(_greet)
    @test haskey(types, :loud)
    @test haskey(types, :prefix)
    @test types[:loud] === Bool
    @test types[:prefix] === String

    # No-kwarg function returns empty dict
    function _no_kwargs(x::Int)
        x
    end
    @test isempty(kt(_no_kwargs))
end

# ── GateTool struct basics ────────────────────────────────────────────────────

@testset "GateTool basics" begin
    t = KaimonGate.GateTool("my_tool", _greet)
    @test t.name == "my_tool"
    @test t.handler === _greet
end

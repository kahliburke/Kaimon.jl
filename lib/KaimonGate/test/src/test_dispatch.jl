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

"""Handler with an UNTYPED first positional + kwargs, taking a structured value.

Mirrors a real worker tool like `__slate_eval_batch(cells; run_id, npool)`: `cells`
is untyped (`::Any`) so a Dict satisfies it. This must NOT trigger the Dict fast
path — doing so would bind the whole args Dict to `batch` and drop the kwargs.
"""
function _batch_handler(batch; run_id::String="", npool::Int=0)
    return (batch=batch, run_id=run_id, npool=npool)
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

    # Only an EXPLICIT Dict-typed first positional is a Dict handler; an untyped
    # (::Any) first positional is not, even though hasmethod(.., Tuple{Dict}) is true.
    @test KaimonGate._is_dict_handler(_dict_handler)
    @test !KaimonGate._is_dict_handler(_batch_handler)
    @test !KaimonGate._is_dict_handler(_greet)
end

# ── _dispatch_tool_call: structured args through an untyped positional ─────────
# Regression: an untyped first positional (`batch`) must reflect, not fast-path.
# Previously hasmethod(handler, Tuple{Dict}) was true for ::Any, so the whole
# args Dict was bound to `batch` and run_id/npool silently reverted to defaults.

@testset "_dispatch_tool_call structured untyped positional" begin
    dispatch = KaimonGate._dispatch_tool_call

    cells = [Dict("id" => "a"), Dict("id" => "b")]
    result = dispatch(
        _batch_handler,
        Dict{String,Any}("batch" => cells, "run_id" => "7", "npool" => 0),
    )
    @test result.batch == cells          # the Vector{Dict}, NOT the whole args Dict
    @test result.batch isa Vector
    @test length(result.batch) == 2
    @test result.run_id == "7"           # kwarg delivered, not its "" default
    @test result.npool == 0
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

# ── _dispatch_tool_call: tailored argument-error messages ─────────────────────

@testset "_dispatch_tool_call argument errors" begin
    dispatch = KaimonGate._dispatch_tool_call

    # Reflection the messages build on.
    pos, nreq, kw = KaimonGate._tool_param_names(_greet)
    @test string.(pos) == ["name", "count"]
    @test nreq == 2
    @test Set(string.(kw)) == Set(["loud", "prefix"])

    # Wrong positional name (the reported case): `path` where `name` was expected.
    err = try
        dispatch(_greet, Dict{String,Any}("path" => "x", "count" => "3"); tool_name = "greet")
        nothing
    catch e
        e
    end
    @test err isa KaimonGate.ToolArgumentError
    m = err.msg
    @test occursin("greet", m)
    @test occursin("missing required", lowercase(m))
    @test occursin("name", m)
    @test occursin("path", m)                                   # flags the unrecognized param
    @test occursin("Did you mean 'name' instead of 'path'", m)
    @test occursin("Expected:", m)
    @test !occursin("MethodError", m) && !occursin("Stacktrace", m)   # concise, no raw dump

    # Missing required with no unknowns → still a clear message.
    err2 = try; dispatch(_greet, Dict{String,Any}("count" => "3")); nothing; catch e; e end
    @test err2 isa KaimonGate.ToolArgumentError && occursin("name", err2.msg)

    # Extra/unknown param but every required one present → call SUCCEEDS (extra ignored).
    @test dispatch(_greet, Dict{String,Any}("name" => "Al", "count" => "1", "bogus" => "z")) ==
          "Hi Al (×1)"

    # A genuine error INSIDE the handler must surface as-is, never masked as a usage error.
    _boom(x::Int) = error("kaboom-$x")
    err3 = try; dispatch(_boom, Dict{String,Any}("x" => "5")); nothing; catch e; e end
    @test err3 isa ErrorException && occursin("kaboom", err3.msg)
    @test !(err3 isa KaimonGate.ToolArgumentError)
end

# ── GateTool struct basics ────────────────────────────────────────────────────

@testset "GateTool basics" begin
    t = KaimonGate.GateTool("my_tool", _greet)
    @test t.name == "my_tool"
    @test t.handler === _greet
end

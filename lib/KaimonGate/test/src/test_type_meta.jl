using Test
using KaimonGate

# ── _clean_docstring ──────────────────────────────────────────────────────────

@testset "_clean_docstring" begin
    f = KaimonGate._clean_docstring

    @test f("") == ""
    @test f("No documentation found for this.") == ""
    @test f("No documentation found.\nMore text.") == ""
    @test f("Some real docstring.") == "Some real docstring."
    @test f("  leading and trailing spaces  ") == "leading and trailing spaces"
end

# ── _type_to_meta: primitives ─────────────────────────────────────────────────

@testset "_type_to_meta primitives" begin
    f = KaimonGate._type_to_meta

    m = f(String)
    @test m["kind"] == "string"
    @test m["julia_type"] == "String"

    m = f(Bool)
    @test m["kind"] == "boolean"

    m = f(Int64)
    @test m["kind"] == "integer"

    m = f(Int)
    @test m["kind"] == "integer"

    m = f(Float64)
    @test m["kind"] == "number"

    m = f(Float32)
    @test m["kind"] == "number"

    m = f(Symbol)
    @test m["kind"] == "string"
    @test m["julia_type"] == "Symbol"

    m = f(Any)
    @test m["kind"] == "any"
    @test m["julia_type"] == "Any"
end

# ── _type_to_meta: enums ──────────────────────────────────────────────────────

@enum _TestColor red green blue

@testset "_type_to_meta enums" begin
    m = KaimonGate._type_to_meta(_TestColor)
    @test m["kind"] == "enum"
    @test endswith(m["julia_type"], "_TestColor")  # SafeTestsets wraps in anon module
    @test "red" in m["enum_values"]
    @test "green" in m["enum_values"]
    @test "blue" in m["enum_values"]
    @test length(m["enum_values"]) == 3
end

# ── _type_to_meta: structs ────────────────────────────────────────────────────

struct _TestPoint
    x::Float64
    y::Float64
end

@testset "_type_to_meta structs" begin
    m = KaimonGate._type_to_meta(_TestPoint)
    @test m["kind"] == "struct"
    @test endswith(m["julia_type"], "_TestPoint")  # SafeTestsets wraps in anon module
    fields = m["fields"]
    @test length(fields) == 2
    names = [f["name"] for f in fields]
    @test "x" in names
    @test "y" in names
    x_field = fields[findfirst(f -> f["name"] == "x", fields)]
    @test x_field["type_meta"]["kind"] == "number"
end

# ── _type_to_meta: arrays ─────────────────────────────────────────────────────

@testset "_type_to_meta arrays" begin
    m = KaimonGate._type_to_meta(Vector{Int})
    @test m["kind"] == "array"
    @test m["element_type"]["kind"] == "integer"

    m2 = KaimonGate._type_to_meta(Vector{String})
    @test m2["kind"] == "array"
    @test m2["element_type"]["kind"] == "string"
end

# ── _type_to_meta: Union{T, Nothing} ─────────────────────────────────────────

@testset "_type_to_meta Union{T,Nothing}" begin
    m = KaimonGate._type_to_meta(Union{Int, Nothing})
    # Should unwrap to Int metadata
    @test m["kind"] == "integer"

    m2 = KaimonGate._type_to_meta(Union{String, Nothing})
    @test m2["kind"] == "string"
end

# ── _type_to_meta: depth limit ────────────────────────────────────────────────

# Build a deeply nested struct chain
struct _D5; end
struct _D4; v::_D5; end
struct _D3; v::_D4; end
struct _D2; v::_D3; end
struct _D1; v::_D2; end

@testset "_type_to_meta depth limit" begin
    # With max_depth=1, _D1 (depth=0) is a struct but its field _D2 (depth=1)
    # hits the limit and falls back to "any".
    m = KaimonGate._type_to_meta(_D1; max_depth=1)
    @test m["kind"] == "struct"
    inner = m["fields"][1]["type_meta"]  # _D2 at depth=1, which equals max_depth → "any"
    @test inner["kind"] == "any"
end

# ── _is_optional_type ────────────────────────────────────────────────────────

@testset "_is_optional_type" begin
    @test KaimonGate._is_optional_type(Union{Int, Nothing}) == true
    @test KaimonGate._is_optional_type(Union{String, Nothing}) == true
    @test KaimonGate._is_optional_type(Int) == false
    @test KaimonGate._is_optional_type(String) == false
    @test KaimonGate._is_optional_type(Any) == false
end

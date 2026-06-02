using Test
using KaimonGate

# Test-local types — defined at module scope so coerce_value can reflect on them.
@enum _CoerceStatus todo in_progress done

struct _CoerceTag
    name::String
    color::Symbol
end

# ── Int coercion ──────────────────────────────────────────────────────────────

@testset "Int coercion" begin
    c = KaimonGate._coerce_value
    @test c("42", Int) === 42
    @test c("0", Int) === 0
    @test c("-7", Int) === -7
    @test c(42, Int) === 42          # already correct → passthrough
    @test c(3.0, Int) === 3          # number → Int
end

# ── Float64 coercion ──────────────────────────────────────────────────────────

@testset "Float64 coercion" begin
    c = KaimonGate._coerce_value
    @test c("3.14", Float64) ≈ 3.14
    @test c("0.0", Float64) === 0.0
    @test c(2, Float64) === 2.0      # integer number → Float64
    @test c(3.14, Float64) === 3.14  # already correct
end

# ── Bool coercion ─────────────────────────────────────────────────────────────

@testset "Bool coercion" begin
    c = KaimonGate._coerce_value
    @test c("true", Bool) === true
    @test c("false", Bool) === false
    @test c("1", Bool) === true
    @test c("yes", Bool) === true
    @test c("no", Bool) === false
    @test c(true, Bool) === true     # already correct
    @test c(false, Bool) === false
end

# ── Symbol coercion ───────────────────────────────────────────────────────────

@testset "Symbol coercion" begin
    c = KaimonGate._coerce_value
    @test c("foo", Symbol) === :foo
    @test c("my_key", Symbol) === :my_key
    @test c(:bar, Symbol) === :bar   # already correct
end

# ── Enum coercion ─────────────────────────────────────────────────────────────

@testset "Enum coercion" begin
    c = KaimonGate._coerce_value
    @test c("todo", _CoerceStatus) === todo
    @test c("in_progress", _CoerceStatus) === in_progress
    @test c("done", _CoerceStatus) === done
    @test c(todo, _CoerceStatus) === todo           # already correct
    @test_throws ErrorException c("invalid_val", _CoerceStatus)
end

# ── Struct from Dict ──────────────────────────────────────────────────────────

@testset "Struct from Dict" begin
    c = KaimonGate._coerce_value
    d = Dict{String,Any}("name" => "bug", "color" => "red")
    result = c(d, _CoerceTag)
    @test result isa _CoerceTag
    @test result.name == "bug"
    @test result.color === :red
end

# ── Vector coercion ───────────────────────────────────────────────────────────

@testset "Vector coercion" begin
    c = KaimonGate._coerce_value
    @test c(["1", "2", "3"], Vector{Int}) == [1, 2, 3]
    @test c(["a", "b"], Vector{String}) == ["a", "b"]
    @test c([], Vector{Int}) == Int[]
end

# ── Union{T,Nothing} ──────────────────────────────────────────────────────────

@testset "Union{T,Nothing}" begin
    c = KaimonGate._coerce_value
    @test c(nothing, Union{Int, Nothing}) === nothing
    @test c("42", Union{Int, Nothing}) === 42
    @test c("hello", Union{String, Nothing}) == "hello"
end

# ── Passthrough (already correct type) ───────────────────────────────────────

@testset "Passthrough" begin
    c = KaimonGate._coerce_value
    @test c("hello", String) == "hello"
    @test c(3.14, Float64) === 3.14
    @test c(true, Bool) === true
    @test c(:sym, Symbol) === :sym
end

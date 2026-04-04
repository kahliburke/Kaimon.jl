using ReTest
using Kaimon

@testset "AST Stripping Tests" begin
    @testset "Print Statement Removal" begin
        # Test println removal
        expr = Meta.parse("println(\"test\"); x = 42")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")

        # Test print removal
        expr = Meta.parse("print(\"test\"); y = 100")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "print")

        # Test printstyled removal
        expr = Meta.parse("printstyled(\"test\", color=:red); z = 200")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "printstyled")

        # Test qualified println removal (Base.println)
        expr = Meta.parse("Base.println(\"test\"); w = 300")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")
    end

    @testset "@show Removal" begin
        # Test @show removal
        expr = Meta.parse("@show 42; x = 100")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "@show")
    end

    @testset "Logging Macro Removal - Top Level Only" begin
        # Test @info removal at top level
        expr = Meta.parse("@info \"test\"; x = 42")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "@info")

        # Test @error removal at top level
        expr = Meta.parse("@error \"test\"; y = 100")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "@error")

        # Test @warn removal at top level
        expr = Meta.parse("@warn \"test\"; z = 200")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "@warn")

        # Test @debug removal at top level
        expr = Meta.parse("@debug \"test\"; w = 300")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "@debug")
    end

    @testset "Logging Macros Preserved in Functions" begin
        # Test @info preserved inside function
        expr = Meta.parse("function test() @info \"inside\"; return 42 end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "@info")

        # Test @error preserved inside function
        expr = Meta.parse("function test() @error \"inside\"; return 42 end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "@error")

        # Test @warn preserved inside function
        expr = Meta.parse("function test() @warn \"inside\"; return 42 end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "@warn")
    end

    @testset "Print Statements Removed at All Levels" begin
        # Test println removed inside function
        expr = Meta.parse("function test() println(\"inside\"); return 42 end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")

        # Test print removed in nested blocks
        expr = Meta.parse("let x = 10; print(\"nested\"); x + 1 end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "print")
    end

    @testset "Code Logic Preserved" begin
        # Test that actual code remains intact
        expr = Meta.parse("println(\"remove me\"); x = 42; y = x + 1")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "x = 42")
        @test contains(string(cleaned), "y = x + 1")

        # Test function definition preserved
        expr = Meta.parse("@info \"remove me\"; function foo(x) return x^2 end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "function foo")
        @test contains(string(cleaned), "x") && contains(string(cleaned), "2")
    end

    @testset "Multiple Statements" begin
        # Test multiple print statements removed
        expr = Meta.parse("println(\"a\"); print(\"b\"); @show 42; x = 100")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")
        @test !contains(string(cleaned), "print")
        @test !contains(string(cleaned), "@show")
        @test contains(string(cleaned), "x = 100")

        # Test multiple logging macros at top level
        expr = Meta.parse("@info \"a\"; @error \"b\"; @warn \"c\"; y = 200")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "@info")
        @test !contains(string(cleaned), "@error")
        @test !contains(string(cleaned), "@warn")
        @test contains(string(cleaned), "y = 200")
    end

    @testset "IO-Targeted Print Calls Preserved" begin
        # println(io, ...) should be preserved (not stdout)
        expr = Meta.parse("io = IOBuffer(); println(io, \"hello\")")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "println")

        # print(io, ...) should be preserved
        expr = Meta.parse("io = IOBuffer(); print(io, \"hello\")")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "print(io")

        # println(stdout, ...) should still be stripped
        expr = Meta.parse("println(stdout, \"test\"); x = 42")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")
        @test contains(string(cleaned), "x = 42")

        # Multi-arg with IO first arg preserved inside function
        expr = Meta.parse("function f(io) println(io, \"data\"); return nothing end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "println")
    end

    @testset "Print Stripped in Agent-Written Nested Code" begin
        # Agent writes a function with println — stripped because it's agent code
        expr = Meta.parse("function f(x) println(\"debug: \", x); return x^2 end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")
        @test contains(string(cleaned), "x ^ 2") || contains(string(cleaned), "x^2")

        # Agent writes a let block with print — stripped
        expr = Meta.parse("let x = 10; print(\"x is \"); println(x); x + 1 end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "print(")
        @test !contains(string(cleaned), "println")

        # Agent writes a do block with println — stripped
        expr = Meta.parse("map([1,2,3]) do x; println(x); x^2 end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")

        # Agent writes a closure with println — stripped
        expr = Meta.parse("f = x -> (println(x); x^2)")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")

        # Agent writes try/catch with println — stripped
        expr = Meta.parse("try println(\"trying\"); 1/0 catch e println(e) end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")
    end

    @testset "IO-Targeted Prints Preserved in Nested Code" begin
        # IO-targeted print inside agent function — kept (writing to a buffer)
        expr = Meta.parse("function f(io) println(io, \"data\"); print(io, \"more\") end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "println(io")
        @test contains(string(cleaned), "print(io")

        # IO-targeted in let block — kept
        expr = Meta.parse("let buf = IOBuffer(); print(buf, \"hello\"); String(take!(buf)) end")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "print(buf")
    end

    @testset "@show Behavior with strip_show Flag" begin
        # @show stripped when strip_show=true (default, quiet mode)
        expr = Meta.parse("@show x = 42")
        cleaned = Kaimon.remove_println_calls(expr, true, true)
        @test !contains(string(cleaned), "@show")

        # @show preserved when strip_show=false (verbose mode, q=false)
        expr = Meta.parse("@show x = 42")
        cleaned = Kaimon.remove_println_calls(expr, true, false)
        @test contains(string(cleaned), "@show") || cleaned !== nothing

        # @show inside function — stripped when strip_show=true
        expr = Meta.parse("function f(x) @show x; x^2 end")
        cleaned = Kaimon.remove_println_calls(expr, true, true)
        @test !contains(string(cleaned), "@show")
    end

    @testset "was_stripped Flag" begin
        # Tracks whether anything was stripped
        was = Ref(false)
        expr = Meta.parse("x = 42")
        Kaimon.remove_println_calls(expr, true, true, was)
        @test !was[]

        was = Ref(false)
        expr = Meta.parse("println(\"hi\"); x = 42")
        Kaimon.remove_println_calls(expr, true, true, was)
        @test was[]

        was = Ref(false)
        expr = Meta.parse("function f() println(\"hi\") end")
        Kaimon.remove_println_calls(expr, true, true, was)
        @test was[]
    end

    @testset "Distinction: AST Stripping vs Runtime Stdout Capture" begin
        # The key distinction for issue #14:
        # - remove_println_calls strips prints from the SUBMITTED CODE AST
        # - It does NOT affect prints inside functions that are CALLED by the code
        # - Runtime stdout from called functions is captured by gate_eval
        #   and returned in the response (visible with q=false)

        # Example: agent writes `include("script.jl")` — include() is kept,
        # and any println inside script.jl executes normally (captured at runtime)
        expr = Meta.parse("include(\"script.jl\")")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "include")

        # Agent calls an existing function that prints — the call is kept
        expr = Meta.parse("my_function_that_prints(42)")
        cleaned = Kaimon.remove_println_calls(expr)
        @test contains(string(cleaned), "my_function_that_prints")

        # Agent writes println + calls function — println stripped, call kept
        expr = Meta.parse("println(\"starting\"); result = compute(data); result")
        cleaned = Kaimon.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")
        @test contains(string(cleaned), "compute(data)")
        @test contains(string(cleaned), "result")
    end

    @testset "Edge Cases" begin
        # Test empty expression (parses to nothing)
        expr = Meta.parse("")
        cleaned = Kaimon.remove_println_calls(expr)
        @test cleaned === nothing  # Empty string parses to nothing

        # Test expression with only println (should return nothing when removed)
        expr = Meta.parse("println(\"only this\")")
        cleaned = Kaimon.remove_println_calls(expr)
        @test cleaned === nothing

        # Test nested logging in try/catch (try/catch is a nested scope, so @error preserved)
        expr = Meta.parse("try @error \"in try\"; x = 1 catch; @error \"in catch\" end")
        cleaned = Kaimon.remove_println_calls(expr)
        # @error should be preserved inside try/catch (nested scope)
        @test contains(string(cleaned), "@error")
    end
end

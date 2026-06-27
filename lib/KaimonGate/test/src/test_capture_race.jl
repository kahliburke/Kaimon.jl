using Test
using KaimonGate

# ─────────────────────────────────────────────────────────────────────────────
# Stdout-capture completeness for KaimonGate._eval_with_capture
#
# The drain tasks that read redirected stdout/stderr must flush the final —
# possibly unterminated — line into `stdout_content` before `join(stdout_content)`
# builds the returned result. The old finalizer closed + drained in an @async
# block followed by a single `yield()`; under some timings the reader had not yet
# pushed the buffered line, so the eval's stdout was dropped from the returned
# result even though it was printed (and live-mirrored to the REPL). The fix
# closes the write ends synchronously and waits (bounded) for the drain tasks.
#
# These probes report how often each case drops output. `miss == 0` is the
# property we want; on the buggy finalizer one or more cases go > 0 (the
# no-trailing-newline case was deterministically 300/300).
# ─────────────────────────────────────────────────────────────────────────────

_capture(code::AbstractString) =
    KaimonGate._eval_with_capture(Base.parse_input_line(code))

@testset "KaimonGate._eval_with_capture stdout completeness" begin
    # Never mirror to the test process's real stdout.
    orig_mirror = KaimonGate._MIRROR_REPL[]
    KaimonGate._MIRROR_REPL[] = false
    try
        N = 300

        @testset "println (trailing newline)" begin
            miss = 0
            for i in 1:N
                _capture("println(\"MARK$i\")").stdout == "MARK$i\n" || (miss += 1)
            end
            @test miss == 0
        end

        @testset "print (no trailing newline)" begin
            miss = 0
            for i in 1:N
                _capture("print(\"MARK$i\")").stdout == "MARK$i" || (miss += 1)
            end
            @test miss == 0
        end

        @testset "multi-line output" begin
            miss = 0
            for i in 1:N
                _capture("for j in 1:5; println(\"L\", j); end").stdout ==
                "L1\nL2\nL3\nL4\nL5\n" || (miss += 1)
            end
            @test miss == 0
        end

        @testset "print under async run-queue pressure" begin
            miss = 0
            for i in 1:N
                done = Ref(false)
                spinners = [@async (while !done[]; yield(); end) for _ in 1:8]
                s = _capture("print(\"C$i\")").stdout
                done[] = true
                foreach(wait, spinners)
                s == "C$i" || (miss += 1)
            end
            @test miss == 0
        end
    finally
        KaimonGate._MIRROR_REPL[] = orig_mirror
        KaimonGate._restore_capture!()   # don't leave Base.stdout rebound for later test files
    end
end

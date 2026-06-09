using ReTest
using Kaimon

# ─────────────────────────────────────────────────────────────────────────────
# Stdout-capture completeness for Gate._eval_with_capture
#
# The drain tasks that read redirected stdout/stderr are finalized in an @async
# block followed by a single `yield()` (see gate.jl). Under some timings the
# reader task has not pushed the buffered line into `stdout_content` before
# `join(stdout_content)` is read — so the eval's stdout is dropped from the
# returned result even though it was printed (and live-mirrored to the REPL).
#
# These probes report how often each case drops output. `mismatches == 0` is the
# property we want; on buggy code one or more cases will be > 0.
# ─────────────────────────────────────────────────────────────────────────────

_capture(code::AbstractString) =
    Kaimon.Gate._eval_with_capture(Base.parse_input_line(code))

@testset "Gate._eval_with_capture stdout completeness" begin
    # Never mirror to the test process's real stdout.
    orig_mirror = Kaimon.Gate._MIRROR_REPL[]
    Kaimon.Gate._MIRROR_REPL[] = false
    try
        N = 300

        @testset "println (trailing newline)" begin
            miss = 0
            for i in 1:N
                _capture("println(\"MARK$i\")").stdout == "MARK$i\n" || (miss += 1)
            end
            @info "println drops" miss = miss of = N
            @test miss == 0
        end

        @testset "print (no trailing newline)" begin
            miss = 0
            for i in 1:N
                _capture("print(\"MARK$i\")").stdout == "MARK$i" || (miss += 1)
            end
            @info "print(no-newline) drops" miss = miss of = N
            @test miss == 0
        end

        @testset "multi-line output" begin
            miss = 0
            for i in 1:N
                _capture("for j in 1:5; println(\"L\", j); end").stdout ==
                "L1\nL2\nL3\nL4\nL5\n" || (miss += 1)
            end
            @info "multi-line drops" miss = miss of = N
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
            @info "print+pressure drops" miss = miss of = N
            @test miss == 0
        end
    finally
        Kaimon.Gate._MIRROR_REPL[] = orig_mirror
    end
end

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

# ─────────────────────────────────────────────────────────────────────────────
# _CaptureIO must be TOTAL — it's installed as the process-wide Base.stdout/stderr,
# so the Julia runtime writes its own diagnostics through it. In particular,
# errormonitor (base/task.jl) prints a failed background task's notice by building
# it into an IOContext over a PipeBuffer and then doing `write(stderr, errio)`. If
# any _CaptureIO method throws (e.g. its captured `orig` stream is in a bad state),
# errormonitor's primary AND fallback prints both fail and Julia emits the opaque
# "caught exception … while trying to print a failed Task notice; giving up",
# swallowing the real error. Regression guard: every method stays total even when
# `orig` throws on every operation.
# ─────────────────────────────────────────────────────────────────────────────

struct _ThrowIO <: IO end
Base.write(::_ThrowIO, ::UInt8) = error("boom-write")
Base.unsafe_write(::_ThrowIO, ::Ptr{UInt8}, ::UInt) = error("boom-unsafe-write")
Base.flush(::_ThrowIO) = error("boom-flush")
Base.displaysize(::_ThrowIO) = error("boom-displaysize")
Base.get(::_ThrowIO, ::Symbol, default) = error("boom-get")

@testset "_CaptureIO is total when orig throws" begin
    prev_sink = get(task_local_storage(), :gate_eval_sink, nothing)
    task_local_storage(:gate_eval_sink, nothing)   # no active sink → passthrough path
    try
        cio = KaimonGate._CaptureIO(:stderr, _ThrowIO())

        # Each IO method the notice printer touches must swallow orig failures.
        @test write(cio, UInt8('x')) == 1
        @test (print(cio, "multi\nbyte\noutput"); true)   # exercises unsafe_write
        @test (flush(cio); true)
        @test Base.displaysize(cio) == (24, 80)            # fallback, not a throw
        @test Base.get(cio, :color, false) == false        # fallback to default

        # The EXACT operation errormonitor performs (task.jl:761-764): build the
        # notice into an IOContext over a PipeBuffer, then write it to stderr.
        errio = IOContext(PipeBuffer(), cio)
        print(errio, "Unhandled Task ERROR: regression\nStacktrace: …\n")
        @test (write(cio, errio); true)                    # must not throw → no "giving up"
    finally
        task_local_storage(:gate_eval_sink, prev_sink)
    end
end

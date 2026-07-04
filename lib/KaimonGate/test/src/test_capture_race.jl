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

# ─────────────────────────────────────────────────────────────────────────────
# Package loading gets byte-safe streams.
#
# `using`/`import` triggers Pkg precompilation, which writes its progress bar and
# the runtime's failed-task notice as raw BYTES through the process-wide
# Base.stdout/stderr at a PINNED (loading-time) world age — one below the world in
# which _CaptureIO's byte methods became active. So the dispatch can't see them and
# falls to Base's `write(::IO,::UInt8) = error("… does not support byte I/O")`,
# which then kills the notice printer too ("… giving up"). _with_uncaptured_streams
# restores the real fd-backed streams (byte-safe at any world) for the load, and
# _eval_with_capture wraps a `using`/`import` eval in it.
# ─────────────────────────────────────────────────────────────────────────────

@testset "package-loading evals get byte-safe streams" begin
    P = Base.parse_input_line
    @test KaimonGate._expr_uses_packages(P("using Foo"))
    @test KaimonGate._expr_uses_packages(P("import Foo.Bar as B"))
    @test KaimonGate._expr_uses_packages(P("begin; x = 1; using Foo; end"))
    @test !KaimonGate._expr_uses_packages(P("1 + 1"))
    @test !KaimonGate._expr_uses_packages(P("f(x) = x + 1"))

    # Stand in for the installed capture with buffers as the "real" streams, so the
    # test asserts on them without perturbing the test process's own stdout.
    real_out = IOBuffer()
    real_err = IOBuffer()
    prev_installed = KaimonGate._CAPTURE_INSTALLED[]
    prev_out = getglobal(Base, :stdout)
    prev_err = getglobal(Base, :stderr)
    prev_oorig = KaimonGate._CAPTURE_ORIG_OUT[]
    prev_eorig = KaimonGate._CAPTURE_ORIG_ERR[]
    try
        KaimonGate._CAPTURE_ORIG_OUT[] = real_out
        KaimonGate._CAPTURE_ORIG_ERR[] = real_err
        cio_out = KaimonGate._CaptureIO(:stdout, real_out)
        setglobal!(Base, :stdout, cio_out)
        setglobal!(Base, :stderr, KaimonGate._CaptureIO(:stderr, real_err))
        KaimonGate._CAPTURE_INSTALLED[] = true

        # A world just below where _CaptureIO's byte method activated — what the
        # loading machinery dispatches at.
        m = which(write, Tuple{typeof(cio_out), UInt8})
        oldw = m.primary_world > 1 ? UInt(m.primary_world) - UInt(1) : UInt(1)

        # Baseline: the capture can't serve a byte write at that world → the exact
        # error precompilation hits.
        err = nothing
        try
            Base.invoke_in_world(oldw, write, getglobal(Base, :stdout), UInt8('A'))
        catch e
            err = e
        end
        @test err !== nothing
        @test occursin("does not support byte I/O", sprint(showerror, err))

        # Fixed: inside the helper the real fd stream is restored, so the same
        # old-world byte write succeeds and lands in the real buffer.
        ok = KaimonGate._with_uncaptured_streams() do
            Base.invoke_in_world(oldw, write, getglobal(Base, :stdout), UInt8('A'))
            true
        end
        @test ok === true
        @test getglobal(Base, :stdout) === cio_out           # capture restored after
        @test String(take!(real_out)) == "A"                 # byte reached real stream

        # Nesting keeps streams restored until the OUTERMOST exit (else an inner
        # load re-installs the capture while an outer load is still precompiling).
        KaimonGate._with_uncaptured_streams() do
            @test getglobal(Base, :stdout) === real_out
            KaimonGate._with_uncaptured_streams() do
                @test getglobal(Base, :stdout) === real_out
            end
            @test getglobal(Base, :stdout) === real_out       # inner exit didn't re-capture
        end
        @test getglobal(Base, :stdout) === cio_out
    finally
        setglobal!(Base, :stdout, prev_out)
        setglobal!(Base, :stderr, prev_err)
        KaimonGate._CAPTURE_ORIG_OUT[] = prev_oorig
        KaimonGate._CAPTURE_ORIG_ERR[] = prev_eorig
        KaimonGate._CAPTURE_INSTALLED[] = prev_installed
        KaimonGate._UNCAPTURE_DEPTH[] = 0
    end
end

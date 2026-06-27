using Test
using KaimonGate
using Base.Threads

# ─────────────────────────────────────────────────────────────────────────────
# Bounded concurrent eval. Two independent properties make it safe:
#   1. CAPTURE ISOLATION — concurrent `_eval_with_capture` calls each route output
#      to their OWN task-local sink, so every captured line belongs to the eval
#      that produced it (no cross-talk, no loss) — across multi-line, no-newline,
#      and single-line code.
#   2. THE CAP HOLDS — `_eval_semaphore()` (from KAIMON_GATE_EVAL_CONCURRENCY)
#      never lets more than N run at once, while still actually overlapping.
# Both are exercised without a running gate (mirror off; stream socket absent).
# ─────────────────────────────────────────────────────────────────────────────

_cap(code::AbstractString) =
    KaimonGate._eval_with_capture(Base.parse_input_line(code))

@testset "concurrent capture isolation" begin
    orig_mirror = KaimonGate._MIRROR_REPL[]
    KaimonGate._MIRROR_REPL[] = false   # never echo to the test process's stdout
    try
        N = 200
        results = Vector{Any}(undef, N)
        @sync for i in 1:N
            Threads.@spawn begin
                kind = i % 3   # 0=multi-line, 1=no-newline, 2=single-line
                code = kind == 0 ? "for _ in 1:8; println(\"MK[$i]\"); end; $i" :
                       kind == 1 ? "print(\"MK[$i]\"); $i" :
                                   "println(\"MK[$i]\"); $i"
                iso = false
                valok = false
                try
                    r = _cap(code)
                    lines = filter(!isempty, split(r.stdout, '\n'))
                    iso = !isempty(lines) && all(==("MK[$i]"), lines)
                    valok = strip(r.value_repr) == string(i)
                catch
                end
                results[i] = (iso = iso, valok = valok)
            end
        end
        @test count(x -> !x.iso, results) == 0    # no cross-talk / loss
        @test count(x -> !x.valok, results) == 0  # correct per-eval values
    finally
        KaimonGate._MIRROR_REPL[] = orig_mirror
        KaimonGate._restore_capture!()   # don't leave Base.stdout rebound for later test files
    end
end

@testset "eval semaphore caps concurrency" begin
    cap = 3
    withenv("KAIMON_GATE_EVAL_CONCURRENCY" => string(cap)) do
        KaimonGate._EVAL_SEM[] = nothing            # rebuild from env
        @test KaimonGate._eval_concurrency() == cap
        sem = KaimonGate._eval_semaphore()
        live = Threads.Atomic{Int}(0)
        peak = Ref(0)
        lk = ReentrantLock()
        @sync for _ in 1:60
            Threads.@spawn begin
                Base.acquire(sem)
                n = Threads.atomic_add!(live, 1) + 1
                lock(lk) do
                    n > peak[] && (peak[] = n)
                end
                sleep(0.01)
                Threads.atomic_sub!(live, 1)
                Base.release(sem)
            end
        end
        @test peak[] <= cap   # cap never exceeded
        @test peak[] >= 2     # concurrency actually happened
    end
    KaimonGate._EVAL_SEM[] = nothing   # reset so later code rebuilds at default
end

# Headless drain stress — floods the per-connection SUB reader (_sub_reader) and,
# in EXTENDED mode, hammers the ZMQ-socket-churn + GC-pressure paths that have
# historically led to gc_sweep_pool / heap-corruption crashes (per-request socket
# growth, concurrent socket create/close under GC). The gate AND the client run in
# THIS process, so GC pressure here exercises the same process where those crashes
# occurred.
#
# In headless mode every eval result (eval_complete) + stdout arrives on the gate
# SUB stream, routed by drain_stream_messages! driven by the event-driven
# per-connection _sub_reader. We assert every eval gets ITS OWN correct answer —
# no drops / cross-talk / hangs / corruption under load.
#
# Run:
#   julia --project -t8 test/headless_drain_stress.jl [scale]
#   julia --project -t8 test/headless_drain_stress.jl [scale] extended

using Kaimon
const K = Kaimon
const KG = Kaimon.KaimonGate

const SCALE = (length(ARGS) >= 1 && tryparse(Int, ARGS[1]) !== nothing) ? parse(Int, ARGS[1]) : 1
const EXTENDED = ("extended" in ARGS) || get(ENV, "KAIMON_STRESS_EXTENDED", "") == "1"
# SATURATE: barrier-free MESSAGE-FABRIC saturation. The target is the ZMQ fabric
# itself — request round-trips (DEALER↔ROUTER) and stream frames (XPUB→SUB→
# drain_stream_messages!→_sub_reader) — NOT eval compute. A single gate serializes
# its evals through GATE_LOCK (global stdout capture), so saturation comes from (a)
# high stream-frame volume per eval, (b) a concurrent pure-ping request flood that
# never touches GATE_LOCK, and (c) NGATES real gates multiplying both across the
# client's per-connection multiplex. CPU spin is deliberately OFF (it would only
# throttle the serial evaluator and lower message rate).
const SATURATE = ("saturate" in ARGS) || get(ENV, "KAIMON_STRESS_SATURATE", "") == "1"
const ROUNDS = something(tryparse(Int, get(ENV, "KAIMON_STRESS_ROUNDS", "")),
                         (EXTENDED ? 40 : 50) * SCALE)
const CONC = EXTENDED ? 100 : 100
# Stream frames per eval. Cranked high in SATURATE so each eval floods the PUB/SUB
# drain path — this is the dominant fabric load (TOTAL × LINES stream frames).
const LINES = something(tryparse(Int, get(ENV, "KAIMON_STRESS_LINES", "")),
                        SATURATE ? 200 : (EXTENDED ? 30 : 50))
const TOTAL = ROUNDS * CONC

# In-flight bound on the client side: how many eval_remote calls may be live at
# once. Sized well above the gate worker cap so the gate pool never starves
# waiting for the client to enqueue. (The old code fetched a full round before
# starting the next → concurrency hit zero on every tail, idling cores.)
const INFLIGHT_CAP = something(tryparse(Int, get(ENV, "KAIMON_STRESS_INFLIGHT", "")),
                               SATURATE ? 8 * Threads.nthreads() : CONC)
# Optional per-eval CPU spin in the gate worker. Default 0 — the fabric, not the
# compute, is the target. Kept as a knob for the separate "does the gate process
# saturate" question, but irrelevant to fabric throughput.
const CPU_ITERS = something(tryparse(Int, get(ENV, "KAIMON_STRESS_CPU_ITERS", "")), 0)
# Concurrent pure-ping flood: background tasks that hammer K.ping round-trips
# (DEALER→ROUTER→reply) for the duration of the eval flood. Zero eval / GATE_LOCK
# involvement, so it isolates request-fabric throughput. Counted into fabric msgs.
const PINGERS = something(tryparse(Int, get(ENV, "KAIMON_STRESS_PINGERS", "")),
                          SATURATE ? 4 * Threads.nthreads() : 0)

# MULTI-GATE: a single gate serializes its evals through GATE_LOCK (it guards the
# process-global stdout/stderr redirect in _eval_with_capture), so one gate is a
# serial evaluator — concurrent evals to it can't pass ~1 core. To actually
# saturate the box (and stress the message path the way production runs — many
# project sessions at once) we spawn N REAL subprocess gates. Each is its own
# process with its own GATE_LOCK, all registering in the shared sock_dir, so the
# single client ConnectionManager discovers all of them and the flood fans across
# them → up to N evals run truly concurrently. SATURATE defaults this to the core
# count; otherwise 0 (in-process gate only).
const NGATES = something(tryparse(Int, get(ENV, "KAIMON_STRESS_GATES", "")),
                         SATURATE ? 4 : 0)
# Threads per spawned gate. With serial evals, 1 default thread per gate is plenty
# (each gate's evals serialize through its own GATE_LOCK anyway); keeps the box from
# oversubscribing when several gates run at once.
const GATE_THREADS = get(ENV, "KAIMON_STRESS_GATE_THREADS", "1,1")
# Hard self-destruct backstop (seconds): every spawned gate exits after this even
# if it's somehow orphaned, so a SIGKILL'd parent can never leave strays.
const GATE_MAX_LIFE = something(tryparse(Int, get(ENV, "KAIMON_STRESS_GATE_MAX_LIFE", "")), 600)

"""Spawn `n` real subprocess gates sharing `cache_dir` (XDG_CACHE_HOME) so they
register in the same sock_dir as the in-process gate. Returns the process handles.
Each loads Kaimon (already precompiled) and serves a gate, then blocks on the gate
task to stay alive."""
function spawn_subprocess_gates(n::Int, cache_dir::String)
    n <= 0 && return Base.Process[]
    julia = joinpath(Sys.BINDIR, "julia")
    # Boot the LIGHTWEIGHT gate (ZMQ + stdlib), NOT heavyweight Kaimon — same as a
    # real spawned session. --project=<KaimonGate> activates its own env (Manifest
    # pins ZMQ), so N parallel gate boots stay cheap.
    gatedir = joinpath(dirname(@__DIR__), "lib", "KaimonGate")
    # Orphan-proofing: a parent-death watchdog (exit the instant we're reparented
    # to PID 1 — i.e. the test process died, even via SIGKILL) plus a hard
    # max-lifetime backstop. Either way no gate can outlive the test run.
    boot = """
    # Watchdogs FIRST — before any load — so a gate orphaned mid-boot (parent died
    # while we were still instantiating/compiling) still self-terminates. ccall
    # needs no packages; Pkg.instantiate/using yield on I/O so these stay scheduled.
    let ppid0 = ccall(:getppid, Cint, ())
        @async while true
            sleep(2)
            (ccall(:getppid, Cint, ()) != ppid0) && exit(0)   # parent gone → orphaned
        end
    end
    @async (sleep($GATE_MAX_LIFE); exit(0))                    # hard backstop
    import Pkg; Pkg.instantiate(io = devnull)
    using KaimonGate
    KaimonGate.serve(force = true, spawned_by = "stress")
    t = KaimonGate._GATE_TASK[]
    t === nothing ? (while true; sleep(3600); end) : wait(t)
    """
    env = copy(ENV)
    env["XDG_CACHE_HOME"] = cache_dir
    env["KAIMON_GATE_MIRROR_REPL"] = "0"   # no terminal mirror noise from stress gates
    env["JULIA_PROJECT"] = ""              # --project is the sole authority
    procs = Base.Process[]
    for _ in 1:n
        cmd = Cmd(`$julia --project=$gatedir -t $GATE_THREADS --startup-file=no -e $boot`;
                  env = env)
        push!(procs, run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false))
    end
    return procs
end

"""Poll `connected_sessions` until at least `n` gates are connected or the deadline
passes; return the connection vector (whatever connected)."""
function wait_for_conns(mgr, n::Int; deadline::Float64)
    cs = K.connected_sessions(mgr)
    while length(cs) < n && time() < deadline
        sleep(0.1)
        cs = K.connected_sessions(mgr)
    end
    return cs
end

# Client-side GC pusher: keep the process's allocator + GC busy while the SUB
# reader and drain run, to surface any heap-corruption (gc_sweep_pool) race.
# Allocation volume (N arrays of SZ bytes per iter) is tunable so the pusher can be
# made light enough to run under libgmalloc/Guard Malloc — which gives every
# allocation its own page and would OOM at the default 256×4KB/iter. SZ>2032 keeps
# the churn on the SYSTEM-malloc (big-object) heap, which is where the corruption
# manifests. The GC.gc() cadence (the actual trigger) is preserved regardless.
const PUSHER_N  = something(tryparse(Int, get(ENV, "KAIMON_STRESS_PUSHER_N", "")), 256)
const PUSHER_SZ = something(tryparse(Int, get(ENV, "KAIMON_STRESS_PUSHER_SZ", "")), 4096)
const PUSHER_FULL_EVERY = something(tryparse(Int, get(ENV, "KAIMON_STRESS_PUSHER_FULL_EVERY", "")), 25)
# Number of concurrent gc_pusher tasks — more = more GC pressure overlapping the
# messaging path (the trigger for the gc_sweep_pool corruption).
const PUSHER_THREADS = something(tryparse(Int, get(ENV, "KAIMON_STRESS_PUSHER_THREADS", "")), EXTENDED ? 1 : 0)
function gc_pusher(stop::Ref{Bool})
    n = 0
    while !stop[]
        junk = [rand(UInt8, PUSHER_SZ) for _ in 1:PUSHER_N]   # short-lived big-object churn
        @inbounds for x in junk; x[1] = 0x00; end
        n += 1
        GC.gc(n % PUSHER_FULL_EVERY == 0)   # mostly incremental, periodic full sweep
        sleep(0.01)
    end
end

verify(res, v) = contains(string(res.value_repr), string(v * 7))

mktempdir(Sys.iswindows() ? tempdir() : "/tmp") do dir
    ENV["XDG_CACHE_HOME"] = dir
    KG.serve(force = true, allow_mirror = false)  # no stdout mirror — evals stream huge volume
    mgr = K.ConnectionManager(; sock_dir = KG.sock_dir())  # no task_queue ⇒ headless ⇒ _sub_reader
    K.start!(mgr)

    conn = nothing
    t0 = time()
    while time() - t0 < 10
        cs = K.connected_sessions(mgr)
        isempty(cs) || (conn = cs[1]; break)
        sleep(0.2)
    end
    conn === nothing && error("client never connected to in-process gate")
    @assert K.ping(conn) !== nothing "ping failed"

    # Raise the gate worker cap so each gate runs many evals in parallel across its
    # default pool (default 16). Note this is the IN-PROCESS gate's Ref; subprocess
    # gates read KAIMON_GATE_MAX_WORKERS from their inherited env at load.
    KG._GATE_MAX_WORKERS[] = something(tryparse(Int, get(ENV, "KAIMON_GATE_MAX_WORKERS", "")),
                                       max(KG._GATE_MAX_WORKERS[], 4 * Threads.nthreads()))

    # Spawn N real subprocess gates (own processes, own GATE_LOCKs) into the shared
    # sock_dir so the single client discovers them all. The flood then fans across
    # every connection → the message fabric is driven by N gates at once.
    gate_procs = spawn_subprocess_gates(NGATES, dir)
    conns = wait_for_conns(mgr, 1 + NGATES; deadline = time() + 60)
    NGATES > 0 && println("connected gates: $(length(conns)) / $(1 + NGATES) expected")
    conn = conns[1]   # in-process gate, used by the EXTENDED churn phase

    println("mode=", SATURATE ? "SATURATE (message-fabric, barrier-free)" :
                     (EXTENDED ? "EXTENDED (GC + socket churn)" : "normal"),
            "  total=$TOTAL gates=$(length(conns)) inflight_cap=$INFLIGHT_CAP",
            " gate_workers=$(KG._GATE_MAX_WORKERS[]) nthreads=$(Threads.nthreads())",
            " lines=$LINES pingers=$PINGERS cpu_iters=$CPU_ITERS")

    stop = Ref(false)
    pushers = [Threads.@spawn(gc_pusher(stop)) for _ in 1:PUSHER_THREADS]

    # Pure-ping request flood: background tasks hammering DEALER↔ROUTER round-trips
    # across all gates for the duration of the eval flood. Isolates request-fabric
    # throughput (no eval / GATE_LOCK). Tally is atomic; tasks stop on `ping_stop`.
    ping_stop = Ref(false)
    ping_count = Threads.Atomic{Int}(0)
    pinger_tasks = [Threads.@spawn begin
        c = conns[mod1(p, length(conns))]
        while !ping_stop[]
            K.ping(c) === nothing || Threads.atomic_add!(ping_count, 1)
        end
    end for p in 1:PINGERS]

    total = 0
    # In extended mode each eval ALSO allocates in the gate (pressures ITS GC)
    # before streaming stdout — so both processes' GC churn while sockets are hot.
    galloc = EXTENDED ? "let s=0.0; for k in 1:40; a=rand(2048); s+=sum(a); end; s end; " : ""
    # Optional CPU spin (default off — fabric is the target, not compute).
    cpu = CPU_ITERS > 0 ? "let s=0.0; for k in 1:$(CPU_ITERS); s+=sin(k*1.0)*cos(k*1.0); end; s end; " : ""

    # Barrier-free flood: spawn ALL evals up front, each gated by a Semaphore that
    # bounds in-flight calls to INFLIGHT_CAP. No per-round fetch barrier, so the
    # fabric stays saturated end-to-end instead of draining to zero on every round
    # tail. Each eval emits LINES stream frames and one reply — fanned round-robin
    # across all gate connections. Failures tallied atomically across worker tasks.
    sem = Base.Semaphore(INFLIGHT_CAP)
    fails = Threads.Atomic{Int}(0)
    done = Threads.Atomic{Int}(0)   # completed evals — drives the progress heartbeat
    t_start = time()
    # Progress heartbeat: prints completed/total + live eval+ping rate every 2s so a
    # long run is visibly alive (and surfaces a stall immediately instead of looking
    # hung). Exits once the flood is done.
    progress_stop = Ref(false)
    progress = Threads.@spawn begin
        last = 0; last_t = time()
        while !progress_stop[]
            sleep(2)
            n = done[]
            now = time()
            rate = (n - last) / max(now - last_t, 1e-6)
            println("  progress: $n/$TOTAL evals  (", round(rate; digits=0), " evals/s, ",
                    ping_count[], " pings)")
            flush(stdout)
            last = n; last_t = now
        end
    end
    tasks = Vector{Task}(undef, TOTAL)
    for v in 1:TOTAL
        tasks[v] = Threads.@spawn begin
            Base.acquire(sem)
            try
                c = conns[mod1(v, length(conns))]
                res = K.eval_remote(c,
                    "$(galloc)$(cpu)for j in 1:$(LINES); println(\"line \", j); end; $(v) * 7";
                    timeout_ms = 120000)
                if !verify(res, v)
                    Threads.atomic_add!(fails, 1)
                    @warn "wrong/failed result" v expected=v*7 got=res.value_repr exception=res.exception
                end
            finally
                Threads.atomic_add!(done, 1)
                Base.release(sem)
            end
        end
    end
    foreach(wait, tasks)
    flood_dt = time() - t_start
    progress_stop[] = true
    try; wait(progress); catch; end
    ping_stop[] = true
    foreach(t -> (try; wait(t); catch; end), pinger_tasks)
    total += TOTAL
    failures = fails[]

    # Subprocess gates have done their job — tear them down NOW (before any churn or
    # asserts that could throw), so a failed assertion can never leave strays. Use
    # SIGKILL (9): KaimonGate traps SIGTERM for graceful shutdown, so plain kill(p)
    # leaves the gate alive and a later wait(p) blocks forever (the "idle for
    # minutes" hang). SIGKILL can't be trapped → guaranteed reap.
    for p in gate_procs
        try; kill(p, 9); catch; end
    end

    # Fabric accounting: every eval = 1 request + 1 reply + LINES stream frames;
    # every ping = 1 request + 1 reply. (Frame-level, both directions.)
    eval_msgs = TOTAL * (2 + LINES)
    ping_msgs = ping_count[] * 2
    fabric_msgs = eval_msgs + ping_msgs

    # EXTENDED: socket-churn phase — disconnect/reconnect cycles under GC pressure.
    # This recreates the DEALER + SUB sockets repeatedly (the create/close-under-GC
    # path), exercising _sub_reader's watcher rebuild and bounding ctx.sockets.
    churn_cycles = 0
    sock_before = 0
    sock_after = 0
    if EXTENDED
        sock_before = length(getfield(conn.zmq_context, :sockets))
        for c in 1:(25 * SCALE)
            K.disconnect!(conn)
            tt = time(); newc = nothing
            while time() - tt < 15
                cs = K.connected_sessions(mgr)
                isempty(cs) || (newc = cs[1]; break)
                sleep(0.05)
            end
            newc === nothing && error("reconnect cycle $c never reconnected")
            conn = newc
            churn_cycles += 1
            # exercise the freshly-rebuilt DEALER + SUB sockets
            for i in 1:30
                v = 5_000_000 + c * 1000 + i
                res = K.eval_remote(conn, "for j in 1:8; println(j); end; $(v) * 7"; timeout_ms = 30000)
                total += 1
                verify(res, v) || (failures += 1; @warn "churn eval wrong" v got=res.value_repr)
            end
            GC.gc()
        end
        sock_after = length(getfield(conn.zmq_context, :sockets))
    end

    stop[] = true
    foreach(p -> (try; wait(p); catch; end), pushers)

    println("FLOOD: $TOTAL evals across $(length(conns)) gate(s), $failures failures, ",
            round(TOTAL / flood_dt; digits=1), " evals/s over ",
            round(flood_dt; digits=1), "s  (total incl. churn: $total)")
    println("FABRIC: ", fabric_msgs, " msgs (",
            eval_msgs, " eval[req+reply+stream] + ", ping_msgs, " ping[req+reply]) = ",
            round(fabric_msgs / flood_dt / 1000; digits=1), "k msgs/s; ",
            ping_count[], " pings @ ", round(ping_count[] / flood_dt; digits=0), "/s")
    if EXTENDED
        println("CHURN: $churn_cycles reconnect cycles; ctx.sockets $sock_before -> $sock_after")
        @assert sock_after <= sock_before + 4 "ctx.sockets grew across reconnects: $sock_before -> $sock_after"
    end
    @assert failures == 0 "had $failures failed/incorrect results — drain lost messages or corrupted"

    try; K.stop!(mgr); catch; end
    try; KG.stop(); catch; end
    # Backstop: gates were already SIGKILL'd after the flood; re-kill (idempotent)
    # and reap so no zombies linger. SIGKILL means wait(p) returns promptly.
    for p in gate_procs
        try; kill(p, 9); catch; end
        try; wait(p); catch; end
    end
    println("HEADLESS_DRAIN_STRESS_OK")
end

# (KaimonGate gate server — split into gate_*.jl files; this one loads FIRST)
# ═══════════════════════════════════════════════════════════════════════════════
# Gate — Thin eval gate for the user's REPL
#
# Runs inside the user's Julia session. Binds a ZMQ REP socket on an IPC
# endpoint so the persistent TUI server can send eval requests without living
# inside this process. Dependencies: ZMQ.jl + Serialization (stdlib).
#
# This file is `include`d into the `KaimonGate` module (see KaimonGate.jl),
# which provides the `using` imports and the host-integration hooks
# (`_VERSION_PROVIDER`, `_MIRROR_PREF_PROVIDER`, `_PERSONALITY_PROVIDER`,
# `_TACHIKOMA`). When KaimonGate runs standalone the hooks return safe
# defaults; when Kaimon loads KaimonGate it installs richer providers.
# ═══════════════════════════════════════════════════════════════════════════════

# ── Thread-safe ZMQ recv ──────────────────────────────────────────────────────
# ZMQ Message objects have finalizers that call zmq_msg_close, which is NOT
# thread-safe. If a Message escapes to GC and gets finalized on a worker
# thread during parallel computation (e.g. @threads kNN), it segfaults.
#
# Fix: use recv(sock, Vector{UInt8}) which internally uses ZMQ._Message
# (a stack-allocated struct with NO finalizer), copies bytes out, and closes
# immediately. No Message object is ever created, so nothing escapes to GC.

"""Receive from a ZMQ socket, returning raw bytes (no finalizer-bearing objects)."""
function _zmq_recv(sock::ZMQ.Socket)::Vector{UInt8}
    return recv(sock, Vector{UInt8})
end

# Thread-safe socket *construction*. ZMQ.jl appends every new Socket to its
# Context's `sockets::Vector{WeakRef}` with an UNLOCKED `push!`. The gate creates
# an ephemeral REQ per `_service_request`, so concurrent extension tool calls
# race that push! → a resize frees the backing Memory under a concurrent GC scan
# of the WeakRef array → intermittent heap corruption in `gc_sweep_pool`. One
# lock around construction closes the window (the I/O afterward is unaffected).
const _ZMQ_SOCKET_LOCK = ReentrantLock()

# ZMQ.jl never removes a socket's WeakRef from `ctx.sockets` on close, so the
# array grows unbounded under churn (it's only consulted by close(ctx) before
# zmq_ctx_term). While holding the construction lock — which serializes every
# push! onto this context — drop the already-dead (GC-collected) entries so it
# stays ~live-socket-sized. Only `value === nothing` weakrefs are removed, never
# a live one. Guarded: reaches one ZMQ.jl internal (`getfield(ctx, :sockets)`).
function _prune_dead_ctx_sockets!(ctx::ZMQ.Context)
    sk = try
        getfield(ctx, :sockets)
    catch
        return nothing
    end
    sk isa AbstractVector || return nothing
    length(sk) < 64 && return nothing
    filter!(w -> (w isa WeakRef ? w.value !== nothing : true), sk)
    return nothing
end

_zmq_socket(ctx::ZMQ.Context, typ) = lock(_ZMQ_SOCKET_LOCK) do
    _prune_dead_ctx_sockets!(ctx)
    ZMQ.Socket(ctx, typ)
end

# ── Constants ─────────────────────────────────────────────────────────────────

# Cache + socket directories MUST be resolved at runtime (functions), not as
# top-level consts. A const is evaluated at precompile time, baking in whatever
# XDG_CACHE_HOME was set then — which breaks per-instance isolation (e.g. a
# second kaimon server, or a gate meant to register in an alternate cache dir).
# Mirrors the server-side Kaimon.kaimon_cache_dir().
function _gate_cache_dir()
    # Append "kaimon" under XDG_CACHE_HOME rather than using it verbatim, so the
    # gate's sockets + session metadata land in the SAME directory the Kaimon
    # server scans for discovery (Kaimon.kaimon_cache_dir also appends "kaimon").
    # Using XDG_CACHE_HOME verbatim here put gate sockets in $XDG/sock while the
    # server's ConnectionManager looked in $XDG/kaimon/sock, silently breaking IPC
    # gate auto-discovery whenever XDG_CACHE_HOME is set. Mirrors the #42 server
    # fix (1cf20a5) on the gate side — the half PR #45 patched in gate.jl that the
    # KaimonGate split didn't carry over. (#42, #45)
    # When XDG_CACHE_HOME is set (including in tests on Windows), honor it on all
    # platforms; otherwise fall back to the OS-native default location.
    xdg = get(ENV, "XDG_CACHE_HOME", "")
    d = if !isempty(xdg)
        joinpath(xdg, "kaimon")
    elseif Sys.iswindows()
        joinpath(
            get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local")),
            "Kaimon",
        )
    else
        joinpath(joinpath(homedir(), ".cache"), "kaimon")
    end
    mkpath(d)
    return d
end

"""Directory holding the gate's IPC sockets and session metadata. Honors
`XDG_CACHE_HOME` at runtime (see `_gate_cache_dir`)."""
function sock_dir()
    d = joinpath(_gate_cache_dir(), "sock")
    mkpath(d)
    return d
end

"""Whether `host` is a loopback bind address (localhost TCP gates may be file-discovered)."""
function _is_local_bind_host(host::AbstractString)
    h = lowercase(strip(host))
    return h in ("127.0.0.1", "::1", "localhost", "0.0.0.0", "") ||
           startswith(h, "127.")
end

"""
    _install_peek_report_override(session_id::String)

Override `Profile.peek_report[]` so that SIGINFO/SIGUSR1 writes the profile
report to `sock_dir()/<session_id>-backtrace.txt` instead of stderr. This avoids
deadlocking PTY-backed sessions where the kernel buffer is small.
"""
function _install_peek_report_override(session_id::String)
    try
        Profile = Base.require(Base.PkgId(Base.UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"), "Profile"))
        bt_path = joinpath(sock_dir(),"$(session_id)-backtrace.txt")
        Profile.peek_report[] = function ()
            try
                open(bt_path, "w") do io
                    Base.invokelatest(Profile.print, io; groupby = [:thread, :task])
                    if position(io) == 0
                        # Profile.print produced no output — write a diagnostic
                        println(io, "(no profiling samples collected)")
                    end
                end
            catch e
                try
                    open(bt_path, "w") do io
                        println(io, "peek_report error: $(sprint(showerror, e))")
                    end
                catch
                end
            end
        end
    catch
        # Profile not available — skip
    end
end
const GATE_LOCK = ReentrantLock()

# ── Bounded concurrent eval ──────────────────────────────────────────────────
# Evals no longer serialize on a single lock. Up to N run at once, gated by a
# semaphore; each captures output to its OWN task-local sink (see gate_stream.jl),
# so concurrent evals don't clobber each other. mt=true/GLMakie evals still route
# through the single REPL backend and are effectively serial there.
#   _EVAL_INFLIGHT — evals currently executing (after acquiring a slot)
#   _EVAL_QUEUED   — evals blocked waiting for a slot (cap exceeded)
# Both feed the "ran alongside N concurrent eval(s) (M queued)" note on results.
const _EVAL_INFLIGHT = Threads.Atomic{Int}(0)
const _EVAL_QUEUED   = Threads.Atomic{Int}(0)
_eval_concurrency() = max(1, something(tryparse(Int, get(ENV, "KAIMON_GATE_EVAL_CONCURRENCY", "")), 4))
const _EVAL_SEM = Ref{Union{Base.Semaphore,Nothing}}(nothing)
const _EVAL_SEM_LOCK = ReentrantLock()
"""The eval-concurrency semaphore, built lazily from `KAIMON_GATE_EVAL_CONCURRENCY` (default 4)."""
function _eval_semaphore()
    s = _EVAL_SEM[]
    s === nothing || return s
    lock(_EVAL_SEM_LOCK) do
        _EVAL_SEM[] === nothing && (_EVAL_SEM[] = Base.Semaphore(_eval_concurrency()))
        return _EVAL_SEM[]
    end
end

# Single mirror-owner: only ONE eval at a time echoes to the user's terminal (the
# "primary", with the `agent>` header). Concurrent evals run HEADLESS — still
# captured, returned to the agent, and published to the Activity-tab stream, but
# NOT written to stdout — so concurrent output never garbles the live terminal.
const _MIRROR_BUSY = Threads.Atomic{Bool}(false)
"""Claim the terminal-mirror slot. Returns true if this eval won it (is primary)."""
_claim_mirror!()   = Threads.atomic_cas!(_MIRROR_BUSY, false, true) == false
_release_mirror!() = Threads.atomic_xchg!(_MIRROR_BUSY, false)

# Global state for the running gate
const _GATE_TASK = Ref{Union{Task,Nothing}}(nothing)
const _GATE_CONTEXT = Ref{Union{ZMQ.Context,Nothing}}(nothing)
const _GATE_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)
const _STREAM_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)  # PUB for streaming output
const _STREAM_ENDPOINT = Ref{String}("")                       # resolved PUB endpoint
const _SESSION_ID = Ref{String}("")
const _RUNNING = Ref{Bool}(false)
const _START_TIME = Ref{Float64}(0.0)
const _MIRROR_REPL = Ref{Bool}(false)
const _ALLOW_MIRROR = Ref{Bool}(true)
const _REVISE_WATCHER_TASK = Ref{Union{Task,Nothing}}(nothing)
const _SESSION_NAMESPACE = Ref{String}("")
const _ALLOW_RESTART = Ref{Bool}(true)
const _ORIGINAL_ARGV = Ref{Vector{String}}(String[])
const _MODE = Ref{Symbol}(:ipc)
const _TCP_HOST = Ref{String}("127.0.0.1")
const _TCP_PORT = Ref{Int}(0)          # actual bound port (resolved from ephemeral)
const _TCP_STREAM_PORT = Ref{Int}(0)   # actual bound PUB port
const _AUTH_TOKEN = Ref{String}("")  # non-empty = require token on TCP requests
const _PING_COUNT = Ref{Int}(0)
const _MSG_COUNT = Ref{Int}(0)       # total messages handled (pings + evals + tool calls + ...)
const _LAST_PING_TIME = Ref{Float64}(0.0)
const _GATE_TTY_PATH = Ref{Union{String,Nothing}}(nothing)
const _GATE_TTY_SIZE =
    Ref{Union{Nothing,NamedTuple{(:rows, :cols),Tuple{Int,Int}}}}(nothing)
const _GATE_TTY_ECHO_DISABLED = Ref{Bool}(false)
const _GATE_TTY_PARKED_PGRP = Ref{Union{Int32,Nothing}}(nothing)
# Set to true between the :restart reply and the actual execvp call.
# Prevents the message-loop task's `finally` from closing sockets prematurely
# and defeating the 0.3 s grace period for the ZMQ reply to flush.
const _RESTARTING = Ref{Bool}(false)
# Set by :shutdown handler so the message loop's `finally` block knows
# to call _cleanup() after the reply has been sent and the loop exits.
const _SHUTTING_DOWN = Ref{Bool}(false)
const _ON_SHUTDOWN = Ref{Any}(nothing)

# ── ROUTER request channel (protocol v2) ─────────────────────────────────────
# The gate's request socket is a ROUTER. A single owner task (the message loop)
# is the ONLY thing that touches it — it interleaves recv (new requests) with
# draining replies that worker tasks hand back via _GATE_OUTBOX, routed to the
# right client by ROUTER identity. Workers never touch the socket, so a slow
# handler (a multi-second sync eval, or a blocked debug_eval) can't stall intake.
# Each outbox entry is (identity, corr_id, reply-bytes); the corr_id is echoed
# back so the client DEALER can demultiplex concurrent in-flight requests.
const _GATE_OUTBOX =
    Channel{Tuple{Vector{UInt8},Vector{UInt8},Vector{UInt8}}}(Inf)
# Backstop on concurrent worker tasks so a request storm can't spawn unbounded
# tasks. At the cap the owner stops accepting new requests; pending requests
# stay queued in the ROUTER (client DEALER blocks in its own recv) until a slot
# frees. Env-overridable.
const _GATE_INFLIGHT = Threads.Atomic{Int}(0)
const _GATE_MAX_WORKERS = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_GATE_MAX_WORKERS", "")), 16))

# Adaptive owner-loop recv timeout (ms). The owner blocks in recv, so worker
# replies queued in _GATE_OUTBOX only flush when the recv returns. A flat 200ms
# meant every reply waited up to a full timeout before going out — ~5 req/s,
# which capped all input (key/click/drag/resize each round-trips a tool call)
# and was the drag-lag root cause. Instead the loop polls fast (BUSY) while a
# reply may be pending — a worker is in-flight or one is already queued — and
# waits long (IDLE) when there's nothing outstanding, so an idle gate stays
# cheap. Intake latency is unaffected either way (recv returns as soon as a
# request arrives); only reply latency is bounded, now to ~BUSY ms. Env-overridable.
const _GATE_RCVTIMEO_BUSY = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_GATE_RCVTIMEO_BUSY", "")), 5))
const _GATE_RCVTIMEO_IDLE = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_GATE_RCVTIMEO_IDLE", "")), 200))

# ── Stream broadcaster (XPUB) + subscriber presence ──────────────────────────
# The stream socket is an XPUB (drop-in for SUB clients) owned by ONE task: the
# broadcaster. It interleaves draining _STREAM_OUTBOX (publish work, the hot
# stdout path) with recv'ing XPUB subscription frames — so the same task that
# sends also reads subscription events, satisfying ZMQ's single-owner rule (no
# more _PUB_LOCK multi-writer send). Publishers just enqueue frames.
#
# XPUB_VERBOSER delivers every sub/unsub; we tally per topic in _STREAM_SUBS and
# fire callbacks on 0->1 / 1->0 transitions. TCP keepalive (set on the socket)
# makes libzmq emit a dead viewer's unsubscribe so counts self-correct.
const _STREAM_OUTBOX = Channel{Vector{Vector{UInt8}}}(Inf)  # each entry = one msg's frames
const _STREAM_TASK = Ref{Union{Task,Nothing}}(nothing)
const _STREAM_SUBS = Dict{String,Int}()                     # topic => live subscriber count
const _STREAM_SUBS_LOCK = ReentrantLock()                   # guards _STREAM_SUBS + callbacks
const _ON_STREAM_SUBSCRIBE = Any[]                          # f(topic::String) on 0->1
const _ON_STREAM_UNSUBSCRIBE = Any[]                        # f(topic::String) on 1->0
const _STREAM_RECONCILE_EVERY = 5.0                         # seconds between hygiene passes

# Empty-frames sentinel: enqueued into _STREAM_OUTBOX purely to WAKE the
# broadcaster (which blocks on `take!`). `_stream_send` on zero frames is a no-op,
# so it carries no wire traffic. Used by the sub-poll tick and the shutdown nudge.
const _STREAM_WAKE = Vector{UInt8}[]

# Sub-event poll interval (seconds). The broadcaster is fully event-driven for the
# hot path — it BLOCKS on the outbox and a publish wakes it instantly. But XPUB
# sub/unsub notifications arrive on the socket, not the channel, so during total
# idle (no publishes) a slow timer nudges the broadcaster to service them. This is
# a liveness pulse, NOT a busy poll: at 2Hz it's ~100x cheaper than the old 5ms
# (200Hz) spin, which — with a subscriber attached — cost a getsockopt→poll()
# syscall per tick and woke the whole thread pool (~10% CPU per idle gate).
# Env-overridable; bounds worst-case presence-event latency.
const _STREAM_SUBPOLL_INTERVAL = Ref{Float64}(
    something(tryparse(Float64, get(ENV, "KAIMON_GATE_STREAM_SUBPOLL", "")), 0.5))

# libzmq socket-option ids (stable ZMTP ABI; see gate_curve.jl for the pattern).
const _ZMQ_TCP_KEEPALIVE       = 34
const _ZMQ_TCP_KEEPALIVE_CNT   = 35
const _ZMQ_TCP_KEEPALIVE_IDLE  = 36
const _ZMQ_TCP_KEEPALIVE_INTVL = 37
const _ZMQ_XPUB_VERBOSER       = 78


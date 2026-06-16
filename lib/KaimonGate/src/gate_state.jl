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
_zmq_socket(ctx::ZMQ.Context, typ) = lock(_ZMQ_SOCKET_LOCK) do
    ZMQ.Socket(ctx, typ)
end

# ── Constants ─────────────────────────────────────────────────────────────────

# Cache + socket directories MUST be resolved at runtime (functions), not as
# top-level consts. A const is evaluated at precompile time, baking in whatever
# XDG_CACHE_HOME was set then — which breaks per-instance isolation (e.g. a
# second kaimon server, or a gate meant to register in an alternate cache dir).
# Mirrors the server-side Kaimon.kaimon_cache_dir().
function _gate_cache_dir()
    d = get(ENV, "XDG_CACHE_HOME") do
        Sys.iswindows() ?
        joinpath(
            get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local")),
            "Kaimon",
        ) : joinpath(homedir(), ".cache", "kaimon")
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

# libzmq socket-option ids (stable ZMTP ABI; see gate_curve.jl for the pattern).
const _ZMQ_TCP_KEEPALIVE       = 34
const _ZMQ_TCP_KEEPALIVE_CNT   = 35
const _ZMQ_TCP_KEEPALIVE_IDLE  = 36
const _ZMQ_TCP_KEEPALIVE_INTVL = 37
const _ZMQ_XPUB_VERBOSER       = 78


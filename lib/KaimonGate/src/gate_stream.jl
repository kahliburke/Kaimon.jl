# ─────────────────────────────────────────────────────────────────────────────
# KaimonGate · XPUB stream broadcaster · subscriber presence · publishing  (split from gate.jl; part of the KaimonGate module)
# ─────────────────────────────────────────────────────────────────────────────

# ── Stream broadcaster: the XPUB's single owning task ────────────────────────

# Apply a 0->1 / 1->0 transition for a topic and fire the right callbacks.
# Parses one XPUB subscription frame: first byte 0x01=subscribe / 0x00=
# unsubscribe, remaining bytes = the subscription topic (e.g. "tui:bounce", or
# "" for a subscribe-all client like the Kaimon TUI).
function _handle_subscription_frame(frame::Vector{UInt8})
    isempty(frame) && return nothing
    is_sub = frame[1] == 0x01
    topic = String(@view frame[2:end])
    transition = lock(_STREAM_SUBS_LOCK) do
        n = get(_STREAM_SUBS, topic, 0)
        if is_sub
            _STREAM_SUBS[topic] = n + 1
            return n == 0 ? :join : :none
        else
            m = max(n - 1, 0)
            m == 0 ? delete!(_STREAM_SUBS, topic) : (_STREAM_SUBS[topic] = m)
            return (n > 0 && m == 0) ? :leave : :none
        end
    end
    transition === :join && _fire_stream_callbacks(_ON_STREAM_SUBSCRIBE, topic)
    transition === :leave && _fire_stream_callbacks(_ON_STREAM_UNSUBSCRIBE, topic)
    return nothing
end

# Invoke presence callbacks on the broadcaster's owning thread. Snapshot under
# the lock, call outside it. Keep callbacks cheap (or hand off to a channel).
function _fire_stream_callbacks(cbs::Vector{Any}, topic::String)
    fns = lock(_STREAM_SUBS_LOCK) do
        copy(cbs)
    end
    for f in fns
        try
            Base.invokelatest(f, topic)
        catch e
            @debug "stream presence callback error" topic = topic exception = e
        end
    end
    return nothing
end

# Hygiene pass: prune non-positive topics. XPUB can't re-derive the live set, so
# correctness of leaves rests on clean closes + TCP keepalive; this is just
# cleanup + a place to surface anomalies.
function _reconcile_stream_subs()
    lock(_STREAM_SUBS_LOCK) do
        for (t, n) in collect(_STREAM_SUBS)
            n <= 0 && delete!(_STREAM_SUBS, t)
        end
    end
    return nothing
end

# Send one message's frames as a multipart on the owner-only socket.
function _stream_send(sock::ZMQ.Socket, frames::Vector{Vector{UInt8}})
    n = length(frames)
    for (i, f) in enumerate(frames)
        send(sock, f; more = (i < n))
    end
    return nothing
end

# Owner-only send wrapper: swallow transient send errors (a dropped subscriber
# mid-send must not kill the broadcaster).
function _safe_stream_send(sock::ZMQ.Socket, frames::Vector{Vector{UInt8}})
    isempty(frames) && return  # _STREAM_WAKE sentinel — nothing to send
    try
        _stream_send(sock, frames)
    catch e
        @debug "stream publish failed" exception = e
    end
    return
end

# Drain all pending XPUB sub/unsub events in one pass (owner-only recv). Checks
# `events & POLLIN` before each recv to avoid the costly throw path when empty.
function _drain_xpub_events(sock::ZMQ.Socket)
    while (try (sock.events & ZMQ.POLLIN) != 0 catch; false end)
        frame = try
            _zmq_recv(sock)
        catch e
            e isa ZMQ.StateError && !_RUNNING[] && return
            UInt8[]
        end
        isempty(frame) && return
        _handle_subscription_frame(frame)
    end
    return
end

# The XPUB's single owner — fully event-driven. BLOCKS on `take!(_STREAM_OUTBOX)`
# (zero idle CPU): a publish wakes it instantly. The only periodic wake is a slow
# liveness `tick` that nudges it to service the rare XPUB sub/unsub event during
# total idle (those arrive on the socket, not the channel, so they can't ride the
# `take!` wait). This replaces the old 5ms (200Hz) spin — which, with a subscriber
# attached, cost a getsockopt→poll() syscall per tick and woke the whole thread
# pool ~200×/s (measured ~10% CPU per idle gate). Shutdown: a caller sets _RUNNING
# false and _cleanup nudges the outbox, so the parked `take!` returns promptly.
function _stream_broadcaster(sock::ZMQ.Socket)
    last_reconcile = time()
    tick = Timer(_STREAM_SUBPOLL_INTERVAL[]; interval = _STREAM_SUBPOLL_INTERVAL[]) do _
        try; put!(_STREAM_OUTBOX, _STREAM_WAKE); catch; end
    end
    try
        while _RUNNING[]
            # Block until woken by a publish, the sub-poll tick, or the shutdown
            # nudge. _STREAM_WAKE (empty frames) carries no data — just a wake.
            frames = try
                take!(_STREAM_OUTBOX)
            catch
                break  # outbox closed → exit
            end
            _RUNNING[] || break
            _safe_stream_send(sock, frames)
            # Coalesce any further-queued publishes (owner-only send).
            while isready(_STREAM_OUTBOX)
                f = try; take!(_STREAM_OUTBOX); catch; break; end
                _safe_stream_send(sock, f)
            end
            # Service all pending XPUB sub/unsub events on every wake.
            _drain_xpub_events(sock)
            # Periodic hygiene.
            if time() - last_reconcile >= _STREAM_RECONCILE_EVERY
                _reconcile_stream_subs()
                last_reconcile = time()
            end
        end
    finally
        close(tick)
    end
    # Final bounded drain so late lifecycle messages (eval_complete) flush.
    deadline = time() + 1.0
    while isready(_STREAM_OUTBOX) && time() < deadline
        f = try; take!(_STREAM_OUTBOX); catch; break; end
        _safe_stream_send(sock, f)
    end
    return nothing
end

# ── Stream presence API (for out-of-band consumers, e.g. TachiRei) ───────────

"""
    on_stream_subscribe(f) -> nothing

Register `f(topic::String)` to be called when a topic gains its FIRST subscriber
(0->1). Invoked on the broadcaster's owning thread, so keep `f` cheap (or hand
off to a channel). Use to e.g. publish a keyframe the moment a viewer attaches.
"""
on_stream_subscribe(f) = (lock(_STREAM_SUBS_LOCK) do; push!(_ON_STREAM_SUBSCRIBE, f); end; nothing)

"""
    on_stream_unsubscribe(f) -> nothing

Register `f(topic::String)` to be called when a topic loses its LAST subscriber
(1->0). Invoked on the broadcaster's owning thread; keep `f` cheap.
"""
on_stream_unsubscribe(f) = (lock(_STREAM_SUBS_LOCK) do; push!(_ON_STREAM_UNSUBSCRIBE, f); end; nothing)

"""    stream_subscribed(topic) -> Bool

True if at least one subscriber is currently attached to `topic`."""
stream_subscribed(topic::AbstractString) =
    lock(_STREAM_SUBS_LOCK) do; get(_STREAM_SUBS, String(topic), 0) > 0 end

"""    stream_subscriber_count(topic) -> Int

Current subscriber count for `topic` (via XPUB_VERBOSER). Reliable on clean
closes/IPC; on hard TCP-viewer disconnects the count self-corrects once libzmq's
keepalive detects the dead peer."""
stream_subscriber_count(topic::AbstractString) =
    lock(_STREAM_SUBS_LOCK) do; get(_STREAM_SUBS, String(topic), 0) end

"""    stream_topics() -> Vector{String}

All topics with at least one subscriber, sorted."""
stream_topics() = lock(_STREAM_SUBS_LOCK) do; sort!(collect(keys(_STREAM_SUBS))) end

# ── Publishing (enqueue-only; the broadcaster owns the socket) ───────────────

function _publish_stream(channel::String, data; request_id::String = "")
    _STREAM_SOCKET[] === nothing && return
    io = IOBuffer()
    msg =
        isempty(request_id) ? (channel = channel, data = data) :
        (channel = channel, data = data, request_id = request_id)
    serialize(io, msg)
    try
        put!(_STREAM_OUTBOX, Vector{UInt8}[take!(io)])
    catch e
        # The caller hangs if eval-lifecycle messages are lost.
        if channel in ("eval_complete", "eval_error", "tool_complete", "tool_error")
            @error "Failed to enqueue $channel (request_id=$request_id)" exception = e
        end
    end
    return
end

# Wire marker for a RAW binary stream frame (see `_publish_stream_raw`). Byte ≥0x80 so it can never
# collide with an observe-broadcast topic (ASCII) on frame 1, and the receiver only consults it on the
# MULTIPART path — a single-frame serialized message is never mistaken for one. MUST stay in lockstep
# with the copy in Kaimon's `gate_client_debug.jl` (a cross-PROCESS wire constant, not a shared symbol).
const _STREAM_BIN_MAGIC = 0xb1

"""
    _publish_stream_raw(channel, payload::Vector{UInt8}) -> nothing

Publish a high-rate BINARY numeric frame WITHOUT the Serialization envelope that `_publish_stream`
imposes. Enqueues a 2-frame multipart `[ [MAGIC|u8 chanLen|chan] , payload ]`: a tiny header frame plus
the payload sent BY REFERENCE (the broadcaster copies it once at the wire, the only unavoidable pass).
The receiver (`drain_stream_messages!`) recognizes MAGIC on the multipart path and routes the payload as
bytes with NO `deserialize` — so a numeric buffer avoids BOTH the serialize (here) and deserialize
(there) memcpy passes the string path costs, roughly doubling hub→browser numeric throughput. Use for
already-framed binary blobs (e.g. Slate's `slate_emit_bin`); the string `_publish_stream` still handles
everything else.
"""
function _publish_stream_raw(channel::AbstractString, payload::Vector{UInt8})
    _STREAM_SOCKET[] === nothing && return
    cb = codeunits(String(channel))
    length(cb) <= 255 || throw(ArgumentError("_publish_stream_raw: channel name too long ($(length(cb)) > 255)"))
    header = Vector{UInt8}(undef, 2 + length(cb))
    @inbounds begin
        header[1] = _STREAM_BIN_MAGIC
        header[2] = length(cb) % UInt8
        for i in eachindex(cb); header[2 + i] = cb[i]; end
    end
    try
        put!(_STREAM_OUTBOX, Vector{UInt8}[header, payload])
    catch e
        @debug "raw stream publish failed" channel = channel exception = e
    end
    return
end

"""
    publish(topic, payload) -> nothing

Broadcast `payload` on the gate's stream socket under `topic` as a **2-frame
multipart** message `[topic, serialize(payload)]`, so subscribers can prefix-
filter server-side (e.g. `KaimonGate.subscribe(endpoint; topic="tui:")`). For
out-of-band consumers such as TachiRei's `tui:<session>` observe stream. No-op if
the gate isn't serving.

Enqueues to the broadcaster (the XPUB's single owner); the actual send happens on
that task. This is distinct from the internal single-blob `_publish_stream`
(stdout/stderr/eval lifecycle) that the Kaimon client consumes — the multipart
framing lets that client recognize and skip observe broadcasts (it checks
`rcvmore`). Subscribe with [`subscribe`](@ref); observe presence with
[`stream_subscribed`](@ref) / [`on_stream_subscribe`](@ref).
"""
function publish(topic::AbstractString, payload)
    _STREAM_SOCKET[] === nothing && return nothing
    io = IOBuffer()
    serialize(io, payload)
    frames = Vector{UInt8}[Vector{UInt8}(codeunits(String(topic))), take!(io)]
    try
        put!(_STREAM_OUTBOX, frames)
    catch e
        @debug "publish enqueue failed" topic = topic exception = e
    end
    return nothing
end

function _start_revise_watcher()
    isdefined(Main, :Revise) || return
    isdefined(Main.Revise, :revision_event) || return
    _REVISE_WATCHER_TASK[] = @async begin
        try
            while _RUNNING[]
                wait(Main.Revise.revision_event)
                _RUNNING[] || break
                Base.reset(Main.Revise.revision_event)
                project_path = dirname(Base.active_project())
                _publish_stream("files_changed", project_path)
            end
        catch e
            e isa InterruptException && return
            @debug "Revise watcher exited" exception = e
        end
    end
end

# Proactive auto-import: a freshly connected session's `Main` is empty, so the very
# common `Pkg.foo(...)` first call fails with `UndefVarError: Pkg not defined`. Before
# evaluating, casually scan the top-level AST for the *base* of qualified references
# and `import` any that (a) aren't already defined in Main and (b) resolve as real
# packages in the active environment. Proactive (not catch-and-retry) so the eval runs
# exactly once — no double side effects. `isdefined(Main, …)` is the in-scope check and
# resets on REPL restart, so no registry to track. Experimental; toggle with _AUTO_IMPORT.
const _AUTO_IMPORT = Ref{Bool}(true)

"""True if `s` names a package loadable from the active environment (dep or stdlib)."""
function _is_loadable_package(s::Symbol)
    try
        return Base.identify_package(String(s)) !== nothing
    catch
        return false
    end
end

"""Collect the leftmost symbols of qualified references (`X.y` → `X`) in `expr`,
skipping modules the code already `using`/`import`s itself."""
function _qualified_ref_bases(expr)
    bases = Set{Symbol}()
    skip = Set{Symbol}()   # roots the code imports itself — don't double-import
    walk(x) = begin
        x isa Expr || return
        if x.head in (:using, :import)
            for a in x.args
                a isa Expr && a.head === :. && !isempty(a.args) && a.args[1] isa Symbol &&
                    push!(skip, a.args[1])
            end
            return
        end
        x.head === :. && !isempty(x.args) && x.args[1] isa Symbol && push!(bases, x.args[1])
        for a in x.args
            walk(a)
        end
    end
    walk(expr)
    return setdiff(bases, skip)
end

"""Import any top-level qualified package refs in `expr` that aren't yet in `Main`.
Returns the symbols actually imported (for a one-line note to the agent)."""
function _autoimport!(expr)::Vector{Symbol}
    _AUTO_IMPORT[] || return Symbol[]
    imported = Symbol[]
    for s in _qualified_ref_bases(expr)
        isdefined(Main, s) && continue
        _is_loadable_package(s) || continue
        try
            # Loading an uncached package here triggers precompilation, whose raw
            # byte-writes would crash the `_CaptureIO` mux (see the note on
            # _with_uncaptured_streams). Restore the real fd streams for the import
            # so it's byte-safe: cached packages import silently; an uncached one
            # shows its precompile progress on the terminal rather than aborting the
            # eval with "does not support byte I/O".
            _with_uncaptured_streams() do
                Core.eval(Main, :(import $s))
            end
            push!(imported, s)
        catch
        end
    end
    return imported
end

# ── Per-eval output capture (concurrent-safe) ────────────────────────────────
# Each running eval owns a task-local `_EvalSink`; a single persistent `_CaptureIO`
# mux (installed once as stdout/stderr) routes writes to the CURRENT task's sink,
# so N concurrent evals capture independently. Writes with no active sink (the
# user's own REPL) pass through to the real terminal. This replaces the old
# per-call global `redirect_stdout()` pipe, which forced evals to serialize.
#
# Tradeoff (documented): capture is Julia-IO-level. Raw OS-fd writes from C
# libraries aren't per-eval-captured (fd bytes carry no task tag) — they reach
# the terminal instead. Virtually all agent output (println/print/@info/show/
# error text) is Julia-level and IS captured, including the trailing no-newline
# case the old drain-race guard protected (here it's deterministic — no pipe/EOF).
mutable struct _EvalSink
    out::IOBuffer
    err::IOBuffer
    out_line::IOBuffer   # pending partial stdout line (for mirror/publish on \n)
    err_line::IOBuffer
    request_id::String
    mirror::Bool
end
_EvalSink(; request_id::String = "", mirror::Bool = false) =
    _EvalSink(IOBuffer(), IOBuffer(), IOBuffer(), IOBuffer(), request_id, mirror)

struct _CaptureIO <: IO
    kind::Symbol   # :stdout | :stderr
    orig::IO       # the real stream — passthrough + mirror target
end

@inline _current_sink() = get(task_local_storage(), :gate_eval_sink, nothing)

const _CAPTURE_INSTALLED = Ref{Bool}(false)
const _CAPTURE_ORIG_OUT  = Ref{IO}(devnull)
const _CAPTURE_ORIG_ERR  = Ref{IO}(devnull)

"""Install the persistent capture mux as stdout/stderr (idempotent, gate-lifetime)."""
function _ensure_capture_installed!()
    if !_CAPTURE_INSTALLED[]
        lock(_EVAL_SEM_LOCK) do
            _CAPTURE_INSTALLED[] && return
            out0 = stdout
            err0 = stderr
            _CAPTURE_ORIG_OUT[] = out0
            _CAPTURE_ORIG_ERR[] = err0
            # `redirect_stdout()` only accepts fd-backed streams (pipe/TTY/file), so it
            # can't install a custom routing IO. Set the `Base.stdout`/`stderr` bindings
            # directly instead — they're non-const, and print/println read them
            # dynamically, so writes route through the mux per task. fd-level writes
            # bypass this (documented tradeoff). The interactive REPL uses its own
            # terminal handle (not this binding) for line-editing, so it's unaffected.
            setglobal!(Base, :stdout, _CaptureIO(:stdout, out0))
            setglobal!(Base, :stderr, _CaptureIO(:stderr, err0))
            _CAPTURE_INSTALLED[] = true
        end
    end
    # With the mux active, a raw-mode Tachikoma TUI would skip its terminal
    # capture/restore cycle (its gate is `stdout isa Base.TTY`, now false) and wedge
    # the host REPL on exit. Register our stream-suspender as Tachikoma's guard so
    # such a TUI runs with the real streams restored. Runs on every eval so a
    # Tachikoma loaded *after* the mux is still covered; cheap once registered.
    _register_tachikoma_stream_guard!()
    return nothing
end

"""Uninstall the capture mux, restoring the original stdout/stderr (idempotent).
Called on gate cleanup so a stopped gate leaves the process's streams as it found
them; also used by tests to avoid leaving Base.stdout rebound across test files."""
function _restore_capture!()
    _CAPTURE_INSTALLED[] || return nothing
    lock(_EVAL_SEM_LOCK) do
        _CAPTURE_INSTALLED[] || return nothing
        try; setglobal!(Base, :stdout, _CAPTURE_ORIG_OUT[]); catch; end
        try; setglobal!(Base, :stderr, _CAPTURE_ORIG_ERR[]); catch; end
        _CAPTURE_INSTALLED[] = false
    end
    return nothing
end

# ── Byte-safe streams for package loading / precompilation ───────────────────
# Package loading (`using`/`import`, and `Pkg` precompilation triggered by it)
# prints its progress bar and — critically — the runtime's *failed-task notice*
# as raw BYTES through the process-wide Base.stdout/stderr. That machinery runs
# at a pinned (loading-time) world age BELOW the world in which `_CaptureIO`'s
# `write(::UInt8)`/`unsafe_write` methods became active, so the dispatch can't see
# them and falls to Base's `write(::IO,::UInt8) = error("… does not support byte
# I/O")`. That throw then kills the notice printer too, yielding the opaque
# "caught exception … while trying to print a failed Task notice; giving up" that
# swallows the real error. (Passing `io=devnull` to Pkg only diverts the progress
# bar — the notice still targets Base.stderr, which is why it leaks around pkg ops.)
#
# The original fd-backed streams handle bytes at ANY world (their methods live in
# the sysimage), so we temporarily restore them for the duration of a load. A
# depth counter under a lock keeps them restored until the LAST concurrent load
# finishes — otherwise an inner load could re-install the capture while an outer
# load (blocked on Base's require lock) is still about to precompile. Tradeoff:
# while streams are restored, any *concurrent* non-loading eval's output goes to
# the terminal uncaptured; loads are infrequent and brief, so this is acceptable
# versus crashing the eval and losing the true error.
const _UNCAPTURE_LOCK      = ReentrantLock()
const _UNCAPTURE_DEPTH     = Ref{Int}(0)
const _UNCAPTURE_SAVED_OUT = Ref{IO}(devnull)
const _UNCAPTURE_SAVED_ERR = Ref{IO}(devnull)

"""Run `f()` with Base.stdout/stderr temporarily pointed at the real fd-backed
streams instead of the `_CaptureIO` mux, so precompilation byte-writes are safe.
No-op (just calls `f`) when the capture isn't installed. Depth-counted + locked so
overlapping loads keep the streams restored until all have finished."""
function _with_uncaptured_streams(f)
    _CAPTURE_INSTALLED[] || return f()
    lock(_UNCAPTURE_LOCK) do
        if _UNCAPTURE_DEPTH[] == 0
            _UNCAPTURE_SAVED_OUT[] = getglobal(Base, :stdout)
            _UNCAPTURE_SAVED_ERR[] = getglobal(Base, :stderr)
            try; setglobal!(Base, :stdout, _CAPTURE_ORIG_OUT[]); catch; end
            try; setglobal!(Base, :stderr, _CAPTURE_ORIG_ERR[]); catch; end
        end
        _UNCAPTURE_DEPTH[] += 1
    end
    try
        return f()
    finally
        lock(_UNCAPTURE_LOCK) do
            _UNCAPTURE_DEPTH[] -= 1
            if _UNCAPTURE_DEPTH[] == 0
                try; setglobal!(Base, :stdout, _UNCAPTURE_SAVED_OUT[]); catch; end
                try; setglobal!(Base, :stderr, _UNCAPTURE_SAVED_ERR[]); catch; end
            end
        end
    end
end

# ── Host TUI stream-guard (Kaimon #67) ───────────────────────────────────────
# A raw-mode Tachikoma TUI (`with_terminal`/`app`) run from a gate REPL wedges the
# host REPL's stdin on exit: the capture mux makes `stdout isa Base.TTY` false, so
# Tachikoma skips its terminal capture/restore cycle. Fix: hand Tachikoma our
# `_with_uncaptured_streams` as its stream guard, so it runs the TUI with the real
# fd streams restored (mux suspended) and restores cleanly. Requires a Tachikoma
# new enough to define `set_stream_guard!`; older versions are a silent no-op.
const _TACHIKOMA_UUID          = Base.UUID("468859d6-42d8-48b7-8ad9-1d312e0e3b0a")
const _WEDGE_GUARD_OPT_OUT     = Ref{Bool}(false)
const _WEDGE_GUARD_REGISTERED  = Ref{Bool}(false)

_loaded_tachikoma() =
    get(Base.loaded_modules, Base.PkgId(_TACHIKOMA_UUID, "Tachikoma"), nothing)

"""Install `guard` as module `T`'s `with_terminal` stream guard via its
`set_stream_guard!`. Returns true on success, false if `T` is nothing or too old
to define the hook (or the call throws). Split out from the registration policy so
it's unit-testable against a mock module."""
function _install_stream_guard!(T, guard = _with_uncaptured_streams)
    (T === nothing || !isdefined(T, :set_stream_guard!)) && return false
    try
        Base.invokelatest(getfield(T, :set_stream_guard!), guard)
        return true
    catch
        return false
    end
end

"""Register `_with_uncaptured_streams` as Tachikoma's `with_terminal` stream guard,
once, if Tachikoma is loaded and supports the hook and this process hasn't opted
out. Idempotent and cheap after the first success; safe to call on every eval."""
function _register_tachikoma_stream_guard!()
    (_WEDGE_GUARD_OPT_OUT[] || _WEDGE_GUARD_REGISTERED[]) && return nothing
    _install_stream_guard!(_loaded_tachikoma()) && (_WEDGE_GUARD_REGISTERED[] = true)
    return nothing
end

"""
    disable_wedge_guard!()

Opt this process out of the #67 TUI stream-guard and clear it if already installed.
For a host that runs its OWN persistent full-screen TUI in the same process as an
active capture mux (e.g. the Kaimon coordinator): there, wrapping the top-level app
in the guard would suspend the mux for the app's entire lifetime and disable eval
capture. Gate SESSIONS and standalone KaimonGate keep the guard.
"""
function disable_wedge_guard!()
    _WEDGE_GUARD_OPT_OUT[] = true
    _install_stream_guard!(_loaded_tachikoma(), nothing)  # clear it if registered
    _WEDGE_GUARD_REGISTERED[] = false
    return nothing
end

# `using`/`import` (which trigger precompilation) can only appear at top level, so
# their presence anywhere in the eval's AST means this eval may load a package.
_expr_uses_packages(@nospecialize(x)) =
    x isa Expr && (x.head === :using || x.head === :import ||
                   any(_expr_uses_packages, x.args))

# Mirror one completed line to the terminal (if enabled) + publish it, tagged
# with the eval's request_id so the client can attribute concurrent streams.
function _sink_emit_line!(sink::_EvalSink, kind::Symbol, line::String, orig::IO)
    if sink.mirror
        try
            write(orig, line)
            flush(orig)
        catch e
            e isa Base.IOError && (_MIRROR_REPL[] = false)
        end
    end
    _publish_stream(kind === :stderr ? "stderr" : "stdout", line; request_id = sink.request_id)
    return nothing
end

function _sink_consume!(sink::_EvalSink, kind::Symbol, bytes::AbstractVector{UInt8}, orig::IO)
    full  = kind === :stderr ? sink.err : sink.out
    lineb = kind === :stderr ? sink.err_line : sink.out_line
    write(full, bytes)
    for b in bytes
        write(lineb, b)
        b == UInt8('\n') && _sink_emit_line!(sink, kind, String(take!(lineb)), orig)
    end
    return nothing
end

"""Flush a trailing partial (no-newline) line at eval end."""
function _sink_finish!(sink::_EvalSink, orig_out::IO, orig_err::IO)
    position(sink.out_line) > 0 && _sink_emit_line!(sink, :stdout, String(take!(sink.out_line)), orig_out)
    position(sink.err_line) > 0 && _sink_emit_line!(sink, :stderr, String(take!(sink.err_line)), orig_err)
    return nothing
end

# ── IO interface for the mux ─────────────────────────────────────────────────
# IMPORTANT: this IO is installed as the process-wide Base.stdout/stderr, so the
# Julia runtime writes its OWN diagnostics through it — notably errormonitor's
# failed-task notice printer (base/task.jl). If any method here throws, that
# printer's primary AND fallback attempts fail and Julia emits the opaque
# "caught exception … while trying to print a failed Task notice; giving up",
# swallowing the real error. So every method below must be total — never throw,
# always fall back. (The old per-call fd `redirect_stdout` never exposed the
# runtime to this code; the persistent custom binding does.)
Base.isopen(::_CaptureIO) = true
Base.iswritable(::_CaptureIO) = true
Base.displaysize(io::_CaptureIO) = try; displaysize(io.orig); catch; (24, 80); end
function Base.get(io::_CaptureIO, key::Symbol, default)
    # Captured output must be PLAIN (the old pipe wasn't color-capable). Only
    # passthrough (no active sink → real terminal) keeps the terminal's color.
    key === :color && _current_sink() !== nothing && return false
    return try; get(io.orig, key, default); catch; default; end
end
function Base.flush(io::_CaptureIO)
    _current_sink() === nothing && try; flush(io.orig); catch; end
    return nothing
end
function Base.write(io::_CaptureIO, b::UInt8)
    sink = _current_sink()
    if sink === nothing
        try; return write(io.orig, b); catch; return 1; end
    end
    try
        full  = io.kind === :stderr ? sink.err : sink.out
        lineb = io.kind === :stderr ? sink.err_line : sink.out_line
        write(full, b)
        write(lineb, b)
        b == UInt8('\n') && _sink_emit_line!(sink, io.kind, String(take!(lineb)), io.orig)
    catch
    end
    return 1
end
function Base.unsafe_write(io::_CaptureIO, p::Ptr{UInt8}, n::UInt)
    sink = _current_sink()
    if sink === nothing
        try; return unsafe_write(io.orig, p, n); catch; return Int(n); end
    end
    try
        bytes = Vector{UInt8}(undef, Int(n))
        GC.@preserve bytes unsafe_copyto!(pointer(bytes), p, n)
        _sink_consume!(sink, io.kind, bytes, io.orig)
    catch
    end
    return Int(n)
end

function _eval_with_capture(expr; mirror::Bool = false)
    _ensure_capture_installed!()
    sink = _EvalSink(;
        request_id = get(task_local_storage(), :gate_request_id, ""),
        mirror = mirror,
    )
    prev_sink = _current_sink()
    task_local_storage(:gate_eval_sink, sink)

    value = nothing
    caught = nothing
    bt = nothing
    autoimported = Symbol[]
    try
        # Apply REPL ast_transforms (Revise, softscope, etc.). Guard on the field:
        # a genuine REPL.REPLBackend carries `ast_transforms`, but some hosts (e.g.
        # the Antigravity IDE) expose `active_repl_backend` as a bare REPLBackendRef
        # that lacks it — accessing the field there throws FieldError and aborts the
        # eval. When absent we simply skip the transforms (no softscope/auto-Revise on
        # that backend, which couldn't install its hook there anyway) and eval as-is.
        if isdefined(Base, :active_repl_backend) &&
           Base.active_repl_backend !== nothing &&
           hasproperty(Base.active_repl_backend, :ast_transforms)
            for xf in Base.active_repl_backend.ast_transforms
                expr = Base.invokelatest(xf, expr)
            end
        end
        # Blank-session convenience: import qualified package refs before evaluating.
        autoimported = _autoimport!(expr)
        # A top-level `using`/`import` triggers precompilation, whose progress bar and
        # failed-task notices are written as raw bytes through Base.stdout/stderr and
        # would crash the `_CaptureIO` mux (see _with_uncaptured_streams). Run those
        # evals with the real fd-backed streams restored so loading is byte-safe.
        value = if _expr_uses_packages(expr)
            _with_uncaptured_streams() do
                Core.eval(Main, expr)
            end
        else
            Core.eval(Main, expr)
        end
    catch e
        caught = e
        bt = catch_backtrace()
    finally
        # Flush any trailing partial (no-newline) line, then detach this eval's
        # sink (restoring the previous one — nesting-safe). The persistent mux
        # stays installed; nothing global is restored per-eval, so concurrent
        # evals are unaffected.
        _sink_finish!(sink, _CAPTURE_ORIG_OUT[], _CAPTURE_ORIG_ERR[])
        task_local_storage(:gate_eval_sink, prev_sink)
    end

    # Format value representation.
    # Use invokelatest so that methods defined during this eval (e.g. by
    # `using SomePackage`) are visible — without it, show/repr can fail with
    # "method too new to be called from this world context" when run on the
    # REPL backend thread.
    value_repr = ""
    if value !== nothing
        io = IOBuffer()
        try
            Base.invokelatest(show, io, MIME("text/plain"), value)
            value_repr = String(take!(io))
        catch
            value_repr = Base.invokelatest(repr, value)
        end
    end

    exception_str = if caught !== nothing
        io = IOBuffer()
        try
            Base.invokelatest(showerror, io, caught, bt)
        catch
            Base.invokelatest(showerror, io, caught)
        end
        String(take!(io))
    else
        nothing
    end

    stderr_extra = ""
    if !isempty(autoimported)
        pkgs = join(string.(autoimported), ", ")
        stderr_extra = "[kaimon] auto-imported $pkgs — a freshly connected session's Main starts " *
            "empty; `using`/`import` once at session start (idempotent) to make this explicit.\n"
    end

    return (
        stdout = String(take!(sink.out)),
        stderr = String(take!(sink.err)) * stderr_extra,
        value_repr = value_repr,
        exception = exception_str,
        backtrace = nothing,
    )
end


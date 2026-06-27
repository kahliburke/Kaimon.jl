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
    real_sink = _current_sink()
    for s in _qualified_ref_bases(expr)
        isdefined(Main, s) && continue
        _is_loadable_package(s) || continue
        try
            # Load quietly — precompile/info chatter must not leak into the eval's
            # captured output or the mirrored terminal. Route THIS task's output to a
            # throwaway sink (task-local; no global redirect, so concurrent evals are
            # unaffected). Julia-level chatter is swallowed; rare raw-fd precompile
            # output from an uncached package may still reach the terminal.
            task_local_storage(:gate_eval_sink, _EvalSink())
            try
                Core.eval(Main, :(import $s))
            finally
                task_local_storage(:gate_eval_sink, real_sink)
            end
            push!(imported, s)
        catch
            task_local_storage(:gate_eval_sink, real_sink)
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
    _CAPTURE_INSTALLED[] && return nothing
    lock(_EVAL_SEM_LOCK) do
        _CAPTURE_INSTALLED[] && return nothing
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
Base.isopen(::_CaptureIO) = true
Base.iswritable(::_CaptureIO) = true
Base.displaysize(io::_CaptureIO) = displaysize(io.orig)
function Base.get(io::_CaptureIO, key::Symbol, default)
    # Captured output must be PLAIN (the old pipe wasn't color-capable). Only
    # passthrough (no active sink → real terminal) keeps the terminal's color.
    key === :color && _current_sink() !== nothing && return false
    return get(io.orig, key, default)
end
function Base.flush(io::_CaptureIO)
    _current_sink() === nothing && flush(io.orig)
    return nothing
end
function Base.write(io::_CaptureIO, b::UInt8)
    sink = _current_sink()
    sink === nothing && return write(io.orig, b)
    full  = io.kind === :stderr ? sink.err : sink.out
    lineb = io.kind === :stderr ? sink.err_line : sink.out_line
    write(full, b)
    write(lineb, b)
    b == UInt8('\n') && _sink_emit_line!(sink, io.kind, String(take!(lineb)), io.orig)
    return 1
end
function Base.unsafe_write(io::_CaptureIO, p::Ptr{UInt8}, n::UInt)
    sink = _current_sink()
    sink === nothing && return unsafe_write(io.orig, p, n)
    bytes = Vector{UInt8}(undef, Int(n))
    GC.@preserve bytes unsafe_copyto!(pointer(bytes), p, n)
    _sink_consume!(sink, io.kind, bytes, io.orig)
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
        # Apply REPL ast_transforms (Revise, softscope, etc.)
        if isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing
            for xf in Base.active_repl_backend.ast_transforms
                expr = Base.invokelatest(xf, expr)
            end
        end
        # Blank-session convenience: import qualified package refs before evaluating.
        autoimported = _autoimport!(expr)
        value = Core.eval(Main, expr)
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


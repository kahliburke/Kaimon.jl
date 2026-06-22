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

# The XPUB's single owner. Interleaves draining publish work (the hot stdout
# path — prioritized) with polling for subscription events. Polls `events &
# POLLIN` before recv to avoid the costly throw path when idle (mirrors the
# client SUB drain).
function _stream_broadcaster(sock::ZMQ.Socket)
    last_reconcile = time()
    while _RUNNING[]
        work = false
        # 1. drain all queued publishes first (owner-only send).
        while isready(_STREAM_OUTBOX)
            frames = take!(_STREAM_OUTBOX)
            try
                _stream_send(sock, frames)
            catch e
                @debug "stream publish failed" exception = e
            end
            work = true
        end
        # 2. poll one subscription event (non-blocking; rcvtimeo=0 as a backstop).
        if (try (sock.events & ZMQ.POLLIN) != 0 catch; false end)
            frame = try
                _zmq_recv(sock)
            catch e
                e isa ZMQ.StateError && !_RUNNING[] && break
                UInt8[]
            end
            if !isempty(frame)
                _handle_subscription_frame(frame)
                work = true
            end
        end
        # 3. periodic hygiene.
        if time() - last_reconcile >= _STREAM_RECONCILE_EVERY
            _reconcile_stream_subs()
            last_reconcile = time()
        end
        work || sleep(0.005)   # idle backoff; keeps event latency ~<=5ms
    end
    # Final bounded drain so late lifecycle messages (eval_complete) flush.
    deadline = time() + 1.0
    while isready(_STREAM_OUTBOX) && time() < deadline
        try
            _stream_send(sock, take!(_STREAM_OUTBOX))
        catch
            break
        end
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
    for s in _qualified_ref_bases(expr)
        isdefined(Main, s) && continue
        _is_loadable_package(s) || continue
        try
            # Load quietly — precompile/info chatter from the import must not leak to
            # the user's mirrored terminal or the captured output. devnull temporarily,
            # then the surrounding redirect is restored.
            redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    Core.eval(Main, :(import $s))
                end
            end
            push!(imported, s)
        catch
        end
    end
    return imported
end

function _eval_with_capture(expr)
    orig_stdout = stdout
    orig_stderr = stderr

    stdout_read, stdout_write = redirect_stdout()
    stderr_read, stderr_write = redirect_stderr()

    stdout_content = String[]
    stderr_content = String[]

    stdout_task = @async begin
        try
            while !eof(stdout_read)
                line = readline(stdout_read; keep = true)
                push!(stdout_content, line)
                if _MIRROR_REPL[]
                    try
                        write(orig_stdout, line)
                        flush(orig_stdout)
                    catch e
                        e isa Base.IOError && (_MIRROR_REPL[] = false)
                    end
                end
                _publish_stream("stdout", line)
            end
        catch e
            e isa EOFError || @debug "stdout read error" exception = e
        end
    end

    stderr_task = @async begin
        try
            while !eof(stderr_read)
                line = readline(stderr_read; keep = true)
                push!(stderr_content, line)
                if _MIRROR_REPL[]
                    try
                        write(orig_stderr, line)
                        flush(orig_stderr)
                    catch e
                        e isa Base.IOError && (_MIRROR_REPL[] = false)
                    end
                end
                _publish_stream("stderr", line)
            end
        catch e
            e isa EOFError || @debug "stderr read error" exception = e
        end
    end

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
        # Restore original streams. If orig_stdout/orig_stderr is a broken pipe
        # (e.g. Tachikoma pixel renderer closed its terminal pipe), fall back to
        # devnull rather than leaving stdout in an unusable state.
        try
            redirect_stdout(orig_stdout)
        catch
            redirect_stdout(devnull)
        end
        try
            redirect_stderr(orig_stderr)
        catch
            redirect_stderr(devnull)
        end
        # Close the write ends so the drain tasks hit EOF, then wait (bounded)
        # for them to flush the final — possibly unterminated — line into
        # stdout_content/stderr_content before join() reads them below.
        #
        # The previous version closed + drained in an @async block followed by a
        # single yield(). That dropped any output not ending in a newline:
        # `readline` blocks until EOF, EOF only arrived after the @async close
        # ran, and join() executed first. timedwait polls via the scheduler (so
        # the @async drain tasks get to run through EOF) but caps the wait, so a
        # genuinely stuck stream still can't hang the eval response.
        try; close(stdout_write); catch; end
        try; close(stderr_write); catch; end
        timedwait(
            () -> istaskdone(stdout_task) && istaskdone(stderr_task),
            2.0;
            pollint = 0.001,
        )
        try; close(stdout_read); catch; end
        try; close(stderr_read); catch; end
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

    if !isempty(autoimported)
        pkgs = join(string.(autoimported), ", ")
        push!(stderr_content,
            "[kaimon] auto-imported $pkgs — a freshly connected session's Main starts " *
            "empty; `using`/`import` once at session start (idempotent) to make this explicit.\n")
    end

    return (
        stdout = join(stdout_content),
        stderr = join(stderr_content),
        value_repr = value_repr,
        exception = exception_str,
        backtrace = nothing,
    )
end


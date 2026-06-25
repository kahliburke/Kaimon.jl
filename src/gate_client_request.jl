# ─────────────────────────────────────────────────────────────────────────────
# Kaimon gate client · deferred context termination · _req_send_recv · eval/communication  (split from gate_client.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── Deferred ZMQ context termination ─────────────────────────────────────────
# A TCP/CURVE session owns a dedicated ZMQ context (an OS I/O thread). It can't
# be terminated the instant the session disconnects: terminating a context with
# live sockets corrupts memory. disconnect! now closes the DEALER (its reader
# task closes the socket within ~rcvtimeo) and the SUB before parking, but park
# the context for a grace window anyway so a slow reader can't race
# zmq_ctx_term (#51). Defense-in-depth, no longer load-bearing.
const _CONTEXT_REAP_GRACE = 35.0  # seconds; generous margin over the reader's exit
const _PENDING_CONTEXTS = Tuple{ZMQ.Context,Float64}[]   # (context, parked_at_seconds)
const _PENDING_CONTEXTS_LOCK = ReentrantLock()

"""Park a dead session's dedicated ZMQ context for deferred termination (#51)."""
function _park_context!(ctx::ZMQ.Context)
    lock(_PENDING_CONTEXTS_LOCK) do
        push!(_PENDING_CONTEXTS, (ctx, time()))
    end
    return nothing
end

"""Terminate parked contexts whose grace has elapsed (no live sockets remain)."""
function _reap_parked_contexts!()
    lock(_PENDING_CONTEXTS_LOCK) do
        isempty(_PENDING_CONTEXTS) && return
        now_t = time()
        keep = Tuple{ZMQ.Context,Float64}[]
        for (ctx, parked) in _PENDING_CONTEXTS
            if now_t - parked >= _CONTEXT_REAP_GRACE
                try; close(ctx); catch; end   # close ≡ zmq_ctx_term; safe now
            else
                push!(keep, (ctx, parked))
            end
        end
        empty!(_PENDING_CONTEXTS)
        append!(_PENDING_CONTEXTS, keep)
    end
    return nothing
end

function disconnect!(conn::REPLConnection)
    # Detach the request channel under the lock, then tear it down outside it so
    # the bounded reader-join wait doesn't hold req_lock.
    rc = lock(conn.req_lock) do
        rc = conn.req_channel
        conn.req_channel = nothing
        if conn.sub_socket !== nothing
            _zmq_close!(conn.sub_socket)   # close + drop its ctx.sockets weakref
            conn.sub_socket = nothing
        end
        conn.status = :disconnected
        return rc
    end
    rc === nothing || _close_request_channel!(rc)  # fails all pending callers fast

    # Wake any pending eval callers so they fail immediately instead of
    # blocking until the hard timeout.  Closing a Channel causes `take!`
    # and `isready` to throw, which the polling loop handles gracefully.
    lock(conn._eval_inboxes_lock) do
        for (_, inbox) in conn._eval_inboxes
            try
                close(inbox)
            catch
            end
        end
    end

    # TCP sessions own a dedicated context (see connect!) — reclaim it so we don't
    # leak an I/O thread per attach/detach. But ephemeral REQ workers may still
    # hold live sockets on it, so DON'T terminate now: park it and let the health
    # loop terminate it after the grace window (#51). IPC sessions share
    # mgr.zmq_context and must NOT touch it here.
    if _is_tcp(conn) && conn.zmq_context !== nothing
        _park_context!(conn.zmq_context)
        conn.zmq_context = nothing
    end
end

# ── Request Send/Recv ─────────────────────────────────────────────────────────
# Requests multiplex over the connection's single persistent DEALER
# (RequestChannel). Each call mints a correlation id, registers a one-shot inbox,
# enqueues the framed request, and waits for the gate's reply (routed back by the
# reader task). A stalled/timed-out request can't starve others — they're
# independent inboxes — and no socket is created per request (the heap-corruption
# fix). The calling task never touches ZMQ directly.

"""
    _req_send_recv(conn, request; caller_timeout=10.0) -> NamedTuple

Send a request to the gate over its persistent DEALER and wait up to
`caller_timeout` seconds for the correlated response. Returns
`(ok=true, response=...)` on success, or `(ok=false, error="...")` on
failure/timeout. Multiple concurrent calls are fully independent.
"""
function _req_send_recv(conn::REPLConnection, request; caller_timeout::Float64 = 10.0)
    rc = conn.req_channel
    if rc === nothing || !rc.alive[] || conn.status ∉ (:connected, :evaluating, :stalled)
        return (ok = false, error = "Gate not connected (status=$(conn.status))")
    end

    # Inject auth token for TCP connections
    if !isempty(conn.auth_token) && request isa NamedTuple
        request = merge(request, (token = conn.auth_token,))
    end
    io = IOBuffer()
    serialize(io, request)
    request_bytes = take!(io)

    corr_id = Threads.atomic_add!(rc.counter, UInt64(1))  # returns prior value; unique
    inbox = Channel{Any}(1)
    lock(rc.pending_lock) do
        rc.pending[corr_id] = inbox
    end

    try
        try
            put!(rc.send_q, (corr_id, request_bytes))
        catch
            return (ok = false, error = "Request channel closed")
        end

        # Block for the correlated reply (event-driven; the reader put!s it, and a
        # disconnect close(inbox) or the deadline wakes us — no 200Hz poll).
        raw = _await_inbox(inbox, time() + caller_timeout)
        if raw === nothing
            return rc.alive[] ?
                   (ok = false, error = "Caller timeout after $(caller_timeout)s") :
                   (ok = false, error = "Gate disconnected")
        end
        isempty(raw) && return (ok = false, error = "Gate request failed (send error)")
        response = try
            _safe_deserialize(raw; label = "gate_reply")
        catch e
            return (ok = false, error = "Malformed response: $(sprint(showerror, e))")
        end
        conn.last_seen = now()
        return (ok = true, response = response)
    finally
        # Always unregister so the pending map can't grow without bound and a late
        # reply is dropped by the reader.
        lock(rc.pending_lock) do
            delete!(rc.pending, corr_id)
        end
        try
            close(inbox)
        catch
        end
    end
end

# ── Eval / Communication ─────────────────────────────────────────────────────

function eval_remote(
    conn::REPLConnection,
    code::String;
    timeout_ms::Int = 30000,
    display_code::String = code,
)
    _no_conn = (
        stdout = "",
        stderr = "",
        value_repr = "",
        exception = "Gate not connected (session=$(conn.session_id), status=$(conn.status))",
        backtrace = nothing,
    )
    if conn.status ∉ (:connected, :evaluating) || conn.req_channel === nothing
        return _no_conn
    end

    request = (type = :eval, code = code, display_code = display_code)
    result = _req_send_recv(conn, request; caller_timeout = timeout_ms / 1000.0)

    if result.ok
        conn.tool_call_count += 1
        return result.response
    else
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = result.error,
            backtrace = nothing,
        )
    end
end

"""
    eval_remote_async(conn, code; timeout_ms=120000, display_code=code, on_output=nothing)

Asynchronous eval: sends `:eval_async` via REQ, gets `:accepted` ack immediately,
then polls SUB socket for stdout/stderr/eval_complete/eval_error messages.

This avoids blocking the REQ socket during long-running evals, allowing health
pings and other operations to proceed.

`on_output` callback, if provided, is called as `on_output(channel::String, data::String)`
for each stdout/stderr chunk received during streaming.

Returns the same NamedTuple format as `eval_remote`.
"""
function eval_remote_async(
    conn::REPLConnection,
    code::String;
    timeout_ms::Int = 600000,  # 10 min hard timeout (keepalive messages sent meanwhile)
    display_code::String = code,
    on_output::Union{Function,Nothing} = nothing,
    request_id::String = "",  # caller-supplied ID (used for eval tracking)
    main_thread::Bool = false,  # route through REPL backend (thread 1) for GLMakie/GLFW
)
    if conn.status ∉ (:connected, :evaluating) || conn.req_channel === nothing
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Gate not connected (session=$(conn.session_id), status=$(conn.status))",
            backtrace = nothing,
        )
    end

    # Generate a unique request ID to correlate response with this caller
    if isempty(request_id)
        request_id = bytes2hex(rand(UInt8, 8))
    end

    # Register the per-request inbox BEFORE sending the request.
    # Fast evals can complete and publish eval_complete on PUB before the
    # REQ/REP round-trip finishes, so the drain loop must already have an
    # inbox to route the message into.
    my_inbox = Channel{Any}(Inf)
    lock(conn._eval_inboxes_lock) do
        conn._eval_inboxes[request_id] = my_inbox
    end

    # Phase 1: Send eval_async request via REQ worker (non-blocking)
    conn.eval_state[] = EVAL_SENDING
    request = (
        type = :eval_async,
        code = code,
        display_code = display_code,
        request_id = request_id,
        main_thread = main_thread,
    )
    result = _req_send_recv(conn, request; caller_timeout = 10.0)

    ack = if result.ok
        result.response
    else
        (type = :error, message = result.error)
    end

    # Check handshake result
    ack_type = get(ack, :type, :error)
    if ack_type == :error
        conn.eval_state[] = EVAL_IDLE
        lock(conn._eval_inboxes_lock) do
            delete!(conn._eval_inboxes, request_id)
        end
        close(my_inbox)
        msg = get(ack, :message, "Unknown handshake error")
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = string(msg),
            backtrace = nothing,
        )
    end
    if ack_type != :accepted
        conn.eval_state[] = EVAL_IDLE
        lock(conn._eval_inboxes_lock) do
            delete!(conn._eval_inboxes, request_id)
        end
        close(my_inbox)
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Unexpected ack type: $ack_type",
            backtrace = nothing,
        )
    end

    # Phase 2: Wait for eval_complete/eval_error on the inbox.
    conn.eval_state[] = EVAL_STREAMING

    start_time = time()
    last_activity = start_time  # tracks last message of any kind (stdout, stash, etc.)
    silence_threshold = 60.0    # send keepalive after this much silence
    keepalive_interval = 30.0   # seconds between repeated keepalives
    last_keepalive = 0.0
    inactivity_timeout = timeout_ms / 1000.0  # fail only after this much silence

    try
        while (time() - last_activity) < inactivity_timeout
            silence = time() - last_activity

            # If no output for a while, send periodic keepalive progress
            # messages so the agent knows the session is still running.
            if on_output !== nothing && silence >= silence_threshold &&
               (time() - last_keepalive) >= keepalive_interval
                elapsed = time() - start_time
                mins = round(Int, elapsed ÷ 60)
                secs = round(Int, elapsed % 60)
                elapsed_str = mins > 0 ? "$(mins)m $(secs)s" : "$(secs)s"
                on_output("stderr",
                    "⏳ Evaluation running ($elapsed_str elapsed, no output for $(round(Int, silence))s). " *
                    "Session may be compiling, performing a long computation, or stuck.\n")
                last_keepalive = time()
            end

            # Bail immediately if the session disconnected while we were waiting
            if !isopen(my_inbox) || conn.status == :disconnected
                return (
                    stdout = "",
                    stderr = "",
                    value_repr = "",
                    exception = "Session disconnected during evaluation. The process may have exited or been restarted.",
                    backtrace = nothing,
                )
            end

            # Block for the next message (event-driven; a real message returns
            # immediately, keeping stream latency low), but wake no later than the
            # next keepalive / inactivity checkpoint so the periodic logic above
            # still runs. Disconnect closes my_inbox → wakes us → loop guard catches.
            wake = last_activity + inactivity_timeout
            if on_output !== nothing
                wake = min(wake, max(last_activity + silence_threshold,
                                     last_keepalive + keepalive_interval))
            end
            msg = _await_inbox(my_inbox, wake)

            msg === nothing && continue

            ch = string(get(msg, :channel, ""))
            data = get(msg, :data, "")

            # Any message counts as activity — keeps the hard timeout at bay
            last_activity = time()

            if ch == "stdout" || ch == "stderr"
                on_output !== nothing && on_output(ch, string(data))
            elseif ch == "breakpoint_hit"
                # The eval triggered an @infiltrate breakpoint. Parse the
                # breakpoint info and return it as a special non-exception
                # result so the MCP tool can inform the agent.
                bp_info = try
                    _safe_deserialize(data; label = "breakpoint_hit")
                catch
                    (file = "unknown", line = 0, locals = Dict(), locals_types = Dict())
                end
                bp_file = get(bp_info, :file, "unknown")
                bp_line = get(bp_info, :line, 0)
                n_locals = length(get(bp_info, :locals, Dict()))
                conn.tool_call_count += 1
                return (
                    stdout = "",
                    stderr = "",
                    value_repr = "⏸ Execution paused at breakpoint ($bp_file:$bp_line) — $n_locals local variables captured.\nUse debug_ctrl to inspect locals, debug_eval to evaluate expressions, and debug_ctrl(action=\"continue\") to resume.",
                    exception = nothing,
                    backtrace = nothing,
                )
            elseif ch == "eval_complete"
                result = try
                    _safe_deserialize(data; label = "eval_complete")
                catch
                    (
                        stdout = "",
                        stderr = "",
                        value_repr = string(data),
                        exception = nothing,
                        backtrace = nothing,
                    )
                end
                conn.tool_call_count += 1
                return result
            elseif ch == "eval_error"
                result = try
                    _safe_deserialize(data; label = "eval_error")
                catch
                    (
                        stdout = "",
                        stderr = "",
                        value_repr = "",
                        exception = string(data),
                        backtrace = nothing,
                    )
                end
                conn.tool_call_count += 1
                return result
            end
        end

        # Inactivity timeout — no messages received for too long
        total_mins = round(Int, (time() - start_time) ÷ 60)
        silent_mins = round(Int, (time() - last_activity) ÷ 60)
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Gate eval timed out after $(total_mins) minutes (no activity for $(silent_mins)m). The session process may be stuck. You can use manage_repl to restart it.",
            backtrace = nothing,
        )
    catch e
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = "Error during async eval streaming: $(sprint(showerror, e))",
            backtrace = nothing,
        )
    finally
        # Always clean up: deregister inbox and update state
        lock(conn._eval_inboxes_lock) do
            delete!(conn._eval_inboxes, request_id)
        end
        # Only go IDLE if no other evals are pending
        if isempty(conn._eval_inboxes)
            conn.eval_state[] = EVAL_IDLE
        end
    end
end

function get_remote_options(conn::REPLConnection)
    if conn.status ∉ (:connected, :evaluating) || conn.req_channel === nothing
        return nothing
    end
    result = _req_send_recv(conn, (type = :get_options,); caller_timeout = 10.0)
    return result.ok ? result.response : nothing
end

function set_mirror_repl!(conn::REPLConnection, enabled::Bool)
    if conn.status ∉ (:connected, :evaluating) || conn.req_channel === nothing
        return false
    end
    result = _req_send_recv(conn, (type = :set_option, key = "mirror_repl", value = enabled); caller_timeout = 10.0)
    return result.ok && get(result.response, :type, :error) == :ok
end

"""
    set_tty!(conn, path) -> Bool

Send a `:set_tty` request to `conn`, detecting the terminal size, pausing the
remote shell via SIGSTOP, and disabling echo. Returns `true` on success.
Call `restore_tty!()` after the TUI exits to resume the shell and restore echo.
"""
function set_tty!(conn::REPLConnection, path::String)
    conn.status in (:connected, :evaluating) && conn.req_channel !== nothing || return false
    result = _req_send_recv(conn, (type = :set_tty, path = path); caller_timeout = 10.0)
    return result.ok && get(result.response, :type, :error) == :ok
end

function ping(conn::REPLConnection)
    if conn.status ∉ (:connected, :stalled) || conn.req_channel === nothing
        return nothing
    end

    # Short timeout — ping should be fast. If the worker is busy processing
    # a long eval handshake, the request queues behind it but we don't wait
    # forever. Return :busy equivalent (nothing) on timeout so the health
    # checker can fall back to PID liveness.
    result = _req_send_recv(conn, (type = :ping,); caller_timeout = 8.0)
    if result.ok
        conn.last_ping = now()
        return result.response
    else
        return nothing
    end
end


"""
    send_restart!(conn::REPLConnection) -> Bool

Send a `:restart` command to the gate. Returns `true` if the gate acknowledged.
The gate will exec a fresh Julia process after replying.
"""
function send_restart!(conn::REPLConnection)
    (conn.status ∉ (:connected, :evaluating) || conn.req_channel === nothing) && return false
    result = _req_send_recv(conn, (type = :restart, name = conn.name); caller_timeout = 10.0)
    return result.ok && get(result.response, :type, :error) == :ok
end

"""
    send_shutdown!(conn::REPLConnection) -> Bool

Send a `:shutdown` command to the gate. Returns `true` if the gate acknowledged.
The gate will stop its event loop and the Julia process will exit.
"""
function send_shutdown!(conn::REPLConnection)
    (conn.status ∉ (:connected, :evaluating, :stalled) || conn.req_channel === nothing) && return false
    result = _req_send_recv(conn, (type = :shutdown, name = conn.name); caller_timeout = 10.0)
    return result.ok && get(result.response, :type, :error) == :ok
end


# ─────────────────────────────────────────────────────────────────────────────
# Kaimon gate client · debug protocol  (split from gate_client.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── Debug Protocol ──────────────────────────────────────────────────────────

"""
    _gate_send_recv(conn::REPLConnection, request::NamedTuple) -> NamedTuple

Send a request to the gate and wait for a response. Lightweight wrapper for
non-eval protocol messages (debug_status, debug_eval, debug_continue).
"""
function _gate_send_recv(conn::REPLConnection, request::NamedTuple)
    if conn.status ∉ (:connected, :evaluating) || conn.req_channel === nothing
        return (type = :error, message = "Gate not connected (status=$(conn.status))")
    end
    result = _req_send_recv(conn, request; caller_timeout = 10.0)
    if result.ok
        return result.response
    else
        return (type = :error, message = result.error)
    end
end

"""
    drain_stream_messages!(mgr::ConnectionManager) -> Vector{NamedTuple}

Non-blocking drain of all pending streaming messages from connected gates.
Returns a vector of `(channel, data, session_name)` tuples.
"""
function drain_stream_messages!(mgr::ConnectionManager)
    messages = NamedTuple{(:channel, :data, :session_name),Tuple{String,String,String}}[]
    pub_events = Tuple{String,String,String}[]  # (channel, data, session_name) for global PUB re-broadcast
    lock(mgr.lock) do
        for conn in mgr.connections
            conn.sub_socket === nothing && continue
            # Drain pending messages (non-blocking, capped per call).
            # The cap prevents holding mgr.lock too long when the gate produces
            # a burst of stdout — any remainder is picked up on the next render frame.
            n_drained = 0
            while n_drained < 500
                n_drained += 1
                # SUB socket ops run under conn.req_lock so the health task can't
                # close/recreate this socket mid-recv — ZMQ sockets aren't
                # thread-safe and a concurrent close+recv corrupts the heap (#51).
                # Scope the lock to the socket only; message processing below is
                # lock-free, so req_lock never nests with the eval/history locks.
                # Returns: nothing ⇒ no more data, :skip ⇒ observe multipart frame.
                raw = lock(conn.req_lock) do
                    conn.sub_socket === nothing && return nothing
                    # Check for pending data before recv to avoid the costly
                    # throw→backtrace path when no messages are available.
                    try
                        (conn.sub_socket.events & ZMQ.POLLIN) == 0 && return nothing
                    catch
                        return nothing  # socket error — skip this connection
                    end
                    r = try
                        _zmq_recv(conn.sub_socket)
                    catch
                        return nothing  # recv error — no more messages
                    end
                    # Observe-channel broadcasts (KaimonGate.publish) are 2-frame
                    # multipart [topic, payload]; the internal stream messages are a
                    # single blob. Detect the extra frame, drain it, and skip — the
                    # Kaimon TUI doesn't consume out-of-band observe streams.
                    if (try; conn.sub_socket.rcvmore; catch; false; end)
                        while (try; conn.sub_socket.rcvmore; catch; false; end)
                            try; _zmq_recv(conn.sub_socket); catch; break; end
                        end
                        return :skip
                    end
                    return r
                end
                raw === nothing && break
                raw === :skip && continue
                msg = try
                    _safe_deserialize(raw; label = "debug_stream")
                catch
                    continue
                end
                ch = string(get(msg, :channel, "stdout"))

                # Panel push: buffer raw data (before stringification) and skip
                if ch == "panel_push"
                    raw_data = get(msg, :data, nothing)
                    skey = short_key(conn)
                    if raw_data isa NamedTuple && hasfield(typeof(raw_data), :key)
                        _buffer_panel_push!(skey, string(raw_data.key), raw_data.value)
                        _push_log!(:info, "panel_push received: key=$(raw_data.key) session=$skey")
                    else
                        _push_log!(:warn, "panel_push malformed: session=$skey data=$(repr(raw_data))")
                    end
                    continue
                end

                data = string(get(msg, :data, ""))
                msg_request_id = string(get(msg, :request_id, ""))

                # Route eval and tool lifecycle messages to the correct per-request inbox
                # so concurrent eval_remote_async / _call_session_tool_async callers
                # each get their own results.
                routed = false
                if ch in (
                    "eval_complete",
                    "eval_error",
                    "tool_complete",
                    "tool_error",
                    "tool_progress",
                ) && !isempty(msg_request_id)
                    inbox = lock(conn._eval_inboxes_lock) do
                        get(conn._eval_inboxes, msg_request_id, nothing)
                    end
                    if inbox !== nothing
                        try
                            put!(inbox, (channel = ch, data = data))
                            routed = true
                        catch
                            # Channel full or closed
                        end
                    end
                end

                # Track debug paused state on the connection for fast checks
                if ch == "breakpoint_hit"
                    conn.debug_paused = true
                elseif ch == "breakpoint_resumed"
                    conn.debug_paused = false
                end

                # Collect job stash updates into the eval record + update inflight
                if ch == "job_stash" && !isempty(msg_request_id)
                    eq_idx = findfirst('=', data)
                    if eq_idx !== nothing
                        skey = data[1:eq_idx-1]
                        sval = data[eq_idx+1:end]
                        lock(mgr.eval_history_lock) do
                            for r in mgr.eval_history
                                if r.eval_id == msg_request_id
                                    r.stash[skey] = sval
                                    r.last_update = time()
                                    break
                                end
                            end
                        end
                    end
                    # Update inflight display with latest stash summary
                    lock(mgr.eval_history_lock) do
                        for r in mgr.eval_history
                            if r.eval_id == msg_request_id && !isempty(r.stash)
                                summary = join(["$k=$v" for (k,v) in sort(collect(r.stash); by=first)], " ")
                                if length(summary) > 80
                                    summary = first(summary, 80) * "…"
                                end
                                _push_job_progress!(msg_request_id, summary)
                                break
                            end
                        end
                    end
                    routed = true
                end

                # Collect for deferred global PUB re-broadcast (outside mgr.lock)
                dname_for_pub = isempty(conn.display_name) ? conn.name : conn.display_name
                push!(pub_events, (ch, data, dname_for_pub))

                if !routed
                    dname = isempty(conn.display_name) ? conn.name : conn.display_name
                    push!(messages, (channel = ch, data = data, session_name = dname))
                end

                # Forward stdout/stderr/breakpoint_hit to all active inboxes during
                # streaming so on_output callbacks (SSE progress) can see them.
                # These aren't tagged with request_id (they come from the REPL's
                # shared stdout/stderr, or from _breakpoint_hook which doesn't
                # know which eval triggered it), so broadcast to all.
                if ch in ("stdout", "stderr", "breakpoint_hit") && conn.eval_state[] == EVAL_STREAMING
                    lock(conn._eval_inboxes_lock) do
                        for (_, inbox) in conn._eval_inboxes
                            try
                                put!(inbox, (channel = ch, data = data))
                            catch
                            end
                        end
                    end
                end
            end
        end
    end
    # Re-broadcast events on the global PUB (outside mgr.lock to avoid deadlock)
    for (ch, data, sname) in pub_events
        _republish_event!(mgr, ch, data, sname)
    end
    return messages
end


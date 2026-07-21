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

# Wire marker for a RAW binary stream frame — MUST match `KaimonGate._STREAM_BIN_MAGIC` (a cross-process
# wire constant). A frame-1 byte of this value on the MULTIPART path means "binary numeric frame: the
# next frame is the payload, route it as bytes without deserialize"; see `_publish_stream_raw`.
const _STREAM_BIN_MAGIC = 0xb1

"""
    drain_stream_messages!(mgr::ConnectionManager) -> Vector{NamedTuple}

Non-blocking drain of all pending streaming messages from connected gates.
Returns a vector of `(channel, data, session_name, conn_name)` tuples. `session_name` is the
human DISPLAY label (`display_name`, falling back to `name`) — it can be re-derived/deduped over
a connection's life, so it is NOT a stable key. `conn_name` is the connection's STABLE connect-time
`name`; route on it (a consumer keying a per-session map, e.g. KaimonSlate's reactive refresh
routing, must use `conn_name` — keying on the mutable `session_name` silently drops events once a
label diverges from the name).
"""
function drain_stream_messages!(mgr::ConnectionManager)
    # `data` is normally a String, but a BINARY stream frame (a raw numeric buffer published as
    # `Vector{UInt8}`) is preserved as bytes — see the decode below; downstream routes it un-stringified.
    messages = NamedTuple{(:channel, :data, :session_name, :conn_name),Tuple{String,Union{String,Vector{UInt8}},String,String}}[]
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
                    # Multipart. Two kinds arrive here: a RAW binary numeric frame
                    # (`_publish_stream_raw`: [MAGIC|chanLen|chan] + [payload]) which we KEEP —
                    # its payload routes as bytes with no deserialize — and observe-channel
                    # broadcasts (`KaimonGate.publish`: [topic, payload]) which the Kaimon client
                    # doesn't consume, so we drain + skip. Internal stream messages are single-blob.
                    if (try; conn.sub_socket.rcvmore; catch; false; end)
                        if !isempty(r) && @inbounds(r[1]) == _STREAM_BIN_MAGIC
                            payload = try; _zmq_recv(conn.sub_socket); catch; UInt8[]; end
                            while (try; conn.sub_socket.rcvmore; catch; false; end)
                                try; _zmq_recv(conn.sub_socket); catch; break; end   # keep the socket frame-aligned
                            end
                            return (:binframe, r, payload)
                        end
                        while (try; conn.sub_socket.rcvmore; catch; false; end)
                            try; _zmq_recv(conn.sub_socket); catch; break; end
                        end
                        return :skip
                    end
                    return r
                end
                raw === nothing && break
                raw === :skip && continue
                # Raw binary numeric frame — bypass deserialize + all the String-typed routing below
                # (panel_push / eval-inbox / job_stash / pub_events). Header = [MAGIC|u8 chanLen|chan];
                # the payload rides straight through as bytes (zero-copy — passed by reference).
                if raw isa Tuple && @inbounds(raw[1]) === :binframe
                    hdr = raw[2]::Vector{UInt8}; payload = raw[3]::Vector{UInt8}
                    clen = length(hdr) >= 2 ? Int(hdr[2]) : 0
                    ch = length(hdr) >= 2 + clen ? String(@view hdr[3:2+clen]) : "stdout"
                    dname = isempty(conn.display_name) ? conn.name : conn.display_name
                    push!(messages, (channel = ch, data = payload, session_name = dname, conn_name = conn.name))
                    continue
                end
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

                # Preserve a raw binary frame (a numeric stream buffer) as bytes; everything else stringifies.
                _rawd = get(msg, :data, "")
                data = _rawd isa Vector{UInt8} ? _rawd : string(_rawd)
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

                # Collect for deferred global PUB re-broadcast (outside mgr.lock). BINARY frames are
                # skipped — pub_events + its downstream consumers (the TUI observe stream) are String-typed,
                # and a raw numeric buffer has no place in a text re-broadcast. It still reaches its own
                # subscriber via `messages` below.
                dname_for_pub = isempty(conn.display_name) ? conn.name : conn.display_name
                data isa Vector{UInt8} || push!(pub_events, (ch, data, dname_for_pub))

                if !routed
                    dname = isempty(conn.display_name) ? conn.name : conn.display_name
                    push!(messages, (channel = ch, data = data, session_name = dname, conn_name = conn.name))
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

"""
    wait_stream_messages!(mgr::ConnectionManager; idle_timeout=0.25) -> Vector{NamedTuple}

Event-driven sibling of [`drain_stream_messages!`](@ref): drain whatever is pending right
now and, if nothing is, PARK on every connection's SUB socket fd (a transient `FDWatcher`
each — near-zero idle CPU, same discipline as [`_sub_reader`](@ref)) until one becomes readable
or `idle_timeout` seconds elapse, then drain once more and return. Same return shape and the
same per-request routing side-effects as `drain_stream_messages!` — only the *trigger* differs.

A caller that OWNS the drain for `mgr` (no competing `_sub_reader` supervisor on these same
connections — two libuv poll handles on one fd collide) can loop on this instead of the
`drain + sleep` poll: it trades the fixed poll-cadence latency floor for wake-on-arrival, so a
streaming producer's frame is forwarded the moment it lands rather than up to a poll interval
later. Drain-first means a busy stream never parks (we spin at drain speed); only an idle `mgr`
blocks, at ~no CPU. The `idle_timeout` ceiling self-heals a park left stale by a SUB socket the
health task recreated under us (new fd ⇒ the old watcher never fires).
"""
function wait_stream_messages!(mgr::ConnectionManager; idle_timeout::Real = 0.25)
    msgs = drain_stream_messages!(mgr)         # drain-first: a busy stream returns without parking
    isempty(msgs) || return msgs
    # Nothing pending — arm one watcher per live SUB fd, then block until the first is readable.
    # Draining above already re-read each socket's EVENTS, re-arming the edge-triggered ZMQ_FD, so
    # a frame that lands after the drain still asserts the fd and wakes the watcher (no lost wakeup).
    conns = lock(mgr.lock) do; copy(mgr.connections) end
    watchers = FileWatching.FDWatcher[]
    for conn in conns
        sub = conn.sub_socket
        sub === nothing && continue
        fd = try; Cint(sub.fd); catch; Cint(-1); end
        fd < 0 && continue
        w = try; FileWatching.FDWatcher(RawFD(fd), true, false); catch; nothing; end
        w === nothing || push!(watchers, w)
    end
    if isempty(watchers)                       # all SUBs mid-recreation — fall back to a plain sleep
        sleep(idle_timeout)
        return drain_stream_messages!(mgr)
    end
    ready = Base.Event()                        # level: first waker sets it; late notifies are no-ops
    timer = Timer(_ -> notify(ready), Float64(idle_timeout))
    for w in watchers
        Threads.@spawn begin
            try; wait(w); catch; end            # a close() below unblocks a still-parked wait → throws → exits
            notify(ready)
        end
    end
    try
        wait(ready)
    finally
        try; close(timer); catch; end
        for w in watchers
            try; close(w); catch; end
        end
    end
    return drain_stream_messages!(mgr)          # readable (or timed out) — pull whatever arrived
end

"""
    _sub_reader(mgr::ConnectionManager, conn::REPLConnection)

Per-connection SUB stream reader — the event-driven, persistent-`FDWatcher`
counterpart to a poll loop, symmetric with the DEALER reader (`_rc_reader`).
Blocks on ONE persistent watcher over the connection's SUB socket fd (zero idle
CPU) and, on each readable wake, calls [`drain_stream_messages!`](@ref) to route
the pending messages. Only the *trigger* changes — the recv still happens inside
`drain_stream_messages!` under `conn.req_lock`, so socket ownership is unchanged
(#51-safe).

Used by the HEADLESS drain supervisor; the TUI instead drives
`drain_stream_messages!` from its render loop. Exits when the connection
disconnects or the manager stops. A recreated SUB socket (new fd, closed old fd)
makes the parked `wait` throw, and the loop rebuilds the watcher on the new fd.
"""
function _sub_reader(mgr::ConnectionManager, conn::REPLConnection)
    fdw = nothing
    watched_fd = Cint(-1)
    try
        while mgr.running && conn.status !== :disconnected
            sub = conn.sub_socket
            fd = sub === nothing ? Cint(-1) : (try Cint(sub.fd) catch; Cint(-1) end)
            if fd < 0
                # SUB not connected yet / mid-recreation — brief settle, retry.
                fdw === nothing || (try; close(fdw); catch; end)
                fdw = nothing
                sleep(0.1)
                continue
            end
            if fdw === nothing || watched_fd != fd
                fdw === nothing || (try; close(fdw); catch; end)
                fdw = try FileWatching.FDWatcher(RawFD(fd), true, false) catch; nothing end
                watched_fd = fd
                fdw === nothing && (sleep(0.1); continue)
                # Buffered data may already be present — drain before parking
                # (also re-arms the ZMQ_FD edge so the watcher fires on the next).
                drain_stream_messages!(mgr)
            end
            # Block until the SUB is readable (zero idle CPU). A closed fd — socket
            # recreated or disconnected — makes `wait` throw → rebuild/exit.
            woke = try
                wait(fdw)
                true
            catch
                fdw = nothing
                false
            end
            woke && drain_stream_messages!(mgr)
        end
    finally
        fdw === nothing || (try; close(fdw); catch; end)
    end
    return nothing
end



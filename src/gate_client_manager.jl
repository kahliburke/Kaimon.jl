# ─────────────────────────────────────────────────────────────────────────────
# Kaimon gate client · ConnectionManager · panel push buffer · global event PUB · eval history  (split from gate_client.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── Connection Manager ────────────────────────────────────────────────────────

mutable struct ConnectionManager
    connections::Vector{REPLConnection}
    zmq_context::ZMQ.Context
    sock_dir::String
    running::Bool
    watcher_task::Union{Task,Nothing}
    health_task::Union{Task,Nothing}
    lock::ReentrantLock
    on_sessions_changed::Union{Function,Nothing}  # called when session list changes
    eval_history::Vector{EvalRecord}       # ring buffer, capped at 64 entries
    eval_history_lock::ReentrantLock
    event_pub_socket::Union{ZMQ.Socket,Nothing}  # global PUB for extension events
    event_pub_lock::ReentrantLock                # serializes ALL event_pub_socket access — ZMQ sockets are not thread-safe and the TUI thread + agent relay tasks all publish (#51)
    task_queue::Any  # Tachikoma.TaskQueue (or nothing if headless)
end

function ConnectionManager(; sock_dir::String = joinpath(kaimon_cache_dir(), "sock"),
                             task_queue = nothing)
    ConnectionManager(
        REPLConnection[],
        Context(),
        sock_dir,
        false,
        nothing,
        nothing,
        ReentrantLock(),
        nothing,
        EvalRecord[],
        ReentrantLock(),
        nothing,
        ReentrantLock(),
        task_queue,
    )
end

# ── Panel Push Buffer ────────────────────────────────────────────────────────
# Accumulates push_panel() messages from gate sessions so the TUI ext_panel
# can read them on the next frame without polling.

const _PANEL_PUSH_BUFFER = Dict{String, Dict{String, Any}}()  # session_key -> key -> value
const _PANEL_PUSH_LOCK = ReentrantLock()

function _buffer_panel_push!(session_key::String, key::String, value)
    lock(_PANEL_PUSH_LOCK) do
        buf = get!(() -> Dict{String, Any}(), _PANEL_PUSH_BUFFER, session_key)
        buf[key] = value
    end
end

"""
    drain_panel_pushes!(session_key::String) -> Dict{String, Any}

Drain all pending panel push messages for a session. Returns empty Dict if none.
Called by ext_panel update loop on the TUI thread.
"""
function drain_panel_pushes!(session_key::String)
    lock(_PANEL_PUSH_LOCK) do
        buf = get(_PANEL_PUSH_BUFFER, session_key, nothing)
        buf === nothing && return Dict{String, Any}()
        result = copy(buf)
        empty!(buf)
        return result
    end
end

# ── Global Event PUB ─────────────────────────────────────────────────────────
# Re-broadcasts gate stream events on a single PUB socket so extensions can
# SUB to one well-known endpoint with topic filtering.

"""Start the global event PUB socket. Extensions SUB to this."""
function _start_event_pub!(mgr::ConnectionManager)
    sock_path = joinpath(mgr.sock_dir, "kaimon-events.sock")
    ispath(sock_path) && rm(sock_path)
    pub = _zmq_socket(mgr.zmq_context, PUB)
    pub.sndhwm = 10000  # drop events if extensions can't keep up
    pub.linger = 0
    bind(pub, "ipc://$sock_path")
    mgr.event_pub_socket = pub
end

"""Stop the global event PUB socket."""
function _stop_event_pub!(mgr::ConnectionManager)
    # Close under the same lock _republish_event! uses, so a concurrent publish
    # can't send on a socket we're closing/freeing (#51).
    lock(mgr.event_pub_lock) do
        pub = mgr.event_pub_socket
        if pub !== nothing
            try; close(pub); catch; end
            mgr.event_pub_socket = nothing
        end
    end
    sock_path = joinpath(mgr.sock_dir, "kaimon-events.sock")
    ispath(sock_path) && try; rm(sock_path); catch; end
end

"""Re-publish a gate event on the global PUB socket (2-frame: topic + payload)."""
function _republish_event!(mgr::ConnectionManager, channel::String, data::String, session_name::String)
    mgr.event_pub_socket === nothing && return
    io = IOBuffer()
    Serialization.serialize(io, (channel=channel, data=data, session_name=session_name))
    payload = take!(io)
    # ZMQ sockets are NOT thread-safe. The TUI render thread (drain_stream_messages!)
    # and every agent relay task (agent_session.jl) both publish here, so concurrent
    # sends on the shared PUB corrupt its internal state — surfacing as an
    # intermittent SIGSEGV in the GC (gc_sweep_pool_page) hours later (#51). Serialize
    # both frames under one lock so neither the socket nor the framing interleaves.
    lock(mgr.event_pub_lock) do
        pub = mgr.event_pub_socket
        pub === nothing && return
        try
            send(pub, channel, more=true)    # frame 1: topic for ZMQ filtering
            send(pub, payload)               # frame 2: serialized payload
        catch
        end
    end
end

"""Emit a TaskEvent via the task queue (if available). The task immediately returns `value`."""
function _emit_event!(mgr::ConnectionManager, id::Symbol, value)
    tq = mgr.task_queue
    tq === nothing && return
    try
        spawn_task!(tq, id) do
            value
        end
    catch
    end
end

"""Fire the sessions-changed callback (if registered). Swallows errors."""
function _fire_sessions_changed(mgr::ConnectionManager)
    cb = mgr.on_sessions_changed
    cb !== nothing && try
        cb()
    catch
    end
end

# ── Eval History Helpers ─────────────────────────────────────────────────────

const _EVAL_HISTORY_MAX = 64

"""Record the start of an eval in the history ring buffer."""
function _record_eval_start!(mgr::ConnectionManager, eval_id::String, session_key::String, code::String)
    record = EvalRecord(
        eval_id,
        session_key,
        first(code, 500),
        time(),
        0.0,
        time(),   # last_update
        :running,
        "",
        "",
        false,
        Dict{String,String}(),
    )
    lock(mgr.eval_history_lock) do
        push!(mgr.eval_history, record)
        # Trim to max size
        while length(mgr.eval_history) > _EVAL_HISTORY_MAX
            popfirst!(mgr.eval_history)
        end
    end
    return nothing
end

"""Record the completion of an eval in the history ring buffer."""
function _record_eval_done!(mgr::ConnectionManager, eval_id::String, status::Symbol, result_preview::String;
                            full_result::String = "")
    lock(mgr.eval_history_lock) do
        for r in mgr.eval_history
            if r.eval_id == eval_id
                r.finished_at = time()
                r.status = status
                r.result_preview = first(result_preview, 500)
                if !isempty(full_result)
                    r.full_result = full_result
                end
                return
            end
        end
    end
    return nothing
end


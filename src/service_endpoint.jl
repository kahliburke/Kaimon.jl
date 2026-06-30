# ═══════════════════════════════════════════════════════════════════════════════
# Service Endpoint — Reverse channel for gate → Kaimon tool calls
#
# The existing gate socket (Kaimon REQ → Gate REP) only allows Kaimon to send
# requests to the gate. This endpoint enables the reverse: gate sessions can
# call any registered Kaimon MCP tool by name, using the same handler functions
# that MCP clients use.
#
# Architecture (concurrent — see CONCURRENT_SERVICE_AND_RATE_GOVERNOR_SPEC.md):
#   N gate clients (per-call REQ) ──ipc──► ROUTER
#       owner task: ONLY toucher of the socket — interleaves recv (new requests)
#                   with draining the outbox (worker replies, routed by identity)
#       workers:    one @async per request → [admission gate] → handler → outbox
#   Only the owner task touches the socket (ZMQ sockets aren't thread-safe), so a
#   slow handler (a multi-second agent_run) never stalls intake. Agent-turn calls
#   pass through RateGovernor.with_admission (concurrency cap + rate + budget).
# ═══════════════════════════════════════════════════════════════════════════════

const _SERVICE_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)
const _SERVICE_CONTEXT = Ref{Union{ZMQ.Context,Nothing}}(nothing)
const _SERVICE_TASK = Ref{Union{Task,Nothing}}(nothing)
const _SERVICE_RUNNING = Ref{Bool}(false)
const _SERVICE_ENDPOINT = Ref{String}("")
# Worker replies, routed back to their client by ROUTER identity: (identity, reply-bytes).
const _OUTBOX = Channel{Tuple{Vector{UInt8},Vector{UInt8}}}(Inf)

# Live worker tasks. The owner stops accepting new requests once this hits the
# cap (clients then block on their recv — backpressure), bounding the number of
# concurrent tasks so the scheduler doesn't thrash. This is a backstop above the
# governor's agent-turn cap; it also bounds non-agent calls. Env-overridable.
const _INFLIGHT = Threads.Atomic{Int}(0)
const _MAX_WORKERS = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_SERVICE_MAX_WORKERS", "")), 16))

# Adaptive owner-loop recv timeout (ms) — same rationale as KaimonGate's gate
# message loop: the owner blocks in recv, so a worker reply queued in _OUTBOX
# only flushes when the recv returns. A flat 200ms made every reverse tool call
# (extensions / agent turns / qdrant / embeddings) wait up to a full timeout for
# its reply. Poll fast (BUSY) while a reply may be pending, wait long (IDLE) when
# there's nothing outstanding. Intake is unaffected (recv returns on a new
# request); only reply latency is bounded, now to ~BUSY ms. Env-overridable.
const _RCVTIMEO_BUSY = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_SERVICE_RCVTIMEO_BUSY", "")), 5))
const _RCVTIMEO_IDLE = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_SERVICE_RCVTIMEO_IDLE", "")), 200))

# ── Multipart framing (ZMQ.jl 1.5 has no multipart helper) ────────────────────
# A REQ→ROUTER message arrives as [identity, empty-delimiter, payload]; the reply
# must be sent with the same envelope. recv the first frame (bounded by rcvtimeo),
# then the rest atomically while `rcvmore`.
function _recv_multipart(sock::ZMQ.Socket)
    parts = Vector{UInt8}[KaimonGate._zmq_recv(sock)]   # may throw ZMQ.TimeoutError
    while sock.rcvmore
        push!(parts, KaimonGate._zmq_recv(sock))
    end
    return parts
end

function _send_multipart(sock::ZMQ.Socket, parts::Vector{Vector{UInt8}})
    n = length(parts)
    for (i, p) in enumerate(parts)
        send(sock, p; more = (i < n))
    end
end

# Only agent *turns* are gated by the governor: agent_run blocks for the turn's
# duration, so it naturally holds a concurrency slot. Other tool calls (qdrant,
# embeddings, …) and the fire-and-forget agent_send run ungated.
_is_agent_turn(request) =
    get(request, :type, nothing) === :tool_call &&
    string(get(request, :tool_name, "")) == "agent_run"

# Run one request to completion on its own task and hand the reply to the outbox.
# Never touches the socket. Admission blocks here (backpressure) for agent turns.
function _serve_one(identity::Vector{UInt8}, request)
    reply = try
        if _is_agent_turn(request)
            RateGovernor.with_admission() do
                Base.invokelatest(_dispatch_service, request)
            end
        else
            Base.invokelatest(_dispatch_service, request)
        end
    catch e
        (status = :error, message = sprint(showerror, e))
    end
    io = IOBuffer()
    Serialization.serialize(io, reply)
    put!(_OUTBOX, (identity, take!(io)))
    Threads.atomic_sub!(_INFLIGHT, 1)
    nothing
end

"""
    start_service_endpoint!() -> NamedTuple

Bind a ZMQ ROUTER socket for tool-call requests from gate sessions and start the
owner task. Gate code calls `KaimonGate.call_tool(name, args)` (a per-call REQ)
which routes here; the dispatcher looks up the tool in Kaimon's MCP registry and
calls its handler on a worker task.

Returns `(endpoint, socket, context)` on success.
"""
function start_service_endpoint!()
    # Unix: ipc:// socket file. Windows: fixed TCP loopback port (no ipc:// transport),
    # matching the port the gate's `_service_request` connects to. (#41)
    if Sys.iswindows()
        endpoint = "tcp://127.0.0.1:$(KaimonGate._SERVICE_TCP_PORT[])"
    else
        endpoint = "ipc://$(KaimonGate.sock_dir())/kaimon-service.sock"
        sock_path = replace(endpoint, "ipc://" => "")
        # Clean up stale socket file. A leftover here means a prior endpoint wasn't
        # stopped cleanly (crash/kill) — log it so an unclean prior shutdown is visible.
        if ispath(sock_path)
            @warn "Removing stale service-endpoint socket before bind" sock_path
            rm(sock_path)
        end
    end

    RateGovernor.init!()   # admission control for agent turns

    ctx = ZMQ.Context()
    sock = _zmq_socket(ctx, ROUTER)
    sock.rcvtimeo = _RCVTIMEO_IDLE[]   # initial; the owner loop adapts it per iteration
    sock.sndtimeo = 5000
    sock.linger = 0
    bind(sock, endpoint)

    _SERVICE_SOCKET[] = sock
    _SERVICE_CONTEXT[] = ctx
    _SERVICE_ENDPOINT[] = endpoint
    _SERVICE_RUNNING[] = true

    _SERVICE_TASK[] = @async begin
        cur_rcvtimeo = -1   # tracked so setsockopt only fires on a transition
        while _SERVICE_RUNNING[]
            # 1. drain any ready worker replies (non-blocking) — owner-only socket access
            while isready(_OUTBOX)
                (identity, reply) = take!(_OUTBOX)
                try
                    _send_multipart(sock, Vector{UInt8}[identity, UInt8[], reply])
                catch e
                    _SERVICE_RUNNING[] || break
                    # ROUTER drops replies to vanished peers (timed-out clients) — expected.
                end
            end
            # 2. backpressure: at the worker cap, don't accept new work — let the
            #    outbox drain (next iteration) free a slot. Pending client requests
            #    stay queued in ROUTER; their REQ recv blocks until we catch up.
            if _INFLIGHT[] >= _MAX_WORKERS[]
                sleep(0.005)
                continue
            end
            # 2b. adaptive recv timeout: poll fast while a reply may be in flight (a
            #     worker running, or one already queued) so it flushes within a few
            #     ms; wait long when idle. Owner-only socket access → setsockopt safe.
            want_rcvtimeo = (_INFLIGHT[] > 0 || isready(_OUTBOX)) ?
                            _RCVTIMEO_BUSY[] : _RCVTIMEO_IDLE[]
            if want_rcvtimeo != cur_rcvtimeo
                sock.rcvtimeo = want_rcvtimeo
                cur_rcvtimeo = want_rcvtimeo
            end
            # 3. try to receive one request (bounded by rcvtimeo)
            parts = try
                _recv_multipart(sock)
            catch e
                e isa ZMQ.TimeoutError && continue
                _SERVICE_RUNNING[] || break
                (e isa ZMQ.StateError || e isa EOFError) && break
                continue
            end
            length(parts) >= 3 || continue          # expect [identity, empty, payload]
            identity = parts[1]
            payload = parts[end]
            request = try
                _safe_deserialize(payload; label = "service_request")
            catch
                io = IOBuffer()
                Serialization.serialize(io, (status = :error, message = "malformed service request"))
                put!(_OUTBOX, (identity, take!(io)))
                continue
            end
            # 4. hand off to a worker — DO NOT run inline (a slow turn must not stall
            #    intake). _serve_one decrements _INFLIGHT when it finishes.
            Threads.atomic_add!(_INFLIGHT, 1)
            @async _serve_one(identity, request)
        end
    end

    @info "Service endpoint bound (ROUTER)" endpoint = endpoint
    return (endpoint = endpoint, context = ctx, socket = sock)
end

"""
    stop_service_endpoint!()

Stop the service endpoint and clean up resources.
"""
function stop_service_endpoint!()
    # Log every teardown WITH its caller. A stop here removes kaimon-service.sock and
    # leaves the gate's reverse channel dead ("service endpoint not available") until
    # the next bind — previously silent, so a disappearing socket while the TUI kept
    # running was very hard to correlate with anything. The caller frame distinguishes
    # TUI cleanup from a _stop_gate_services!/restart path.
    caller = try
        fr = stacktrace()
        length(fr) >= 2 ? string(fr[2]) : "?"
    catch
        "?"
    end
    @info "Service endpoint stopping" endpoint = _SERVICE_ENDPOINT[] running = _SERVICE_RUNNING[] caller

    _SERVICE_RUNNING[] = false

    task = _SERVICE_TASK[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end
    _SERVICE_TASK[] = nothing

    # Drain any undelivered worker replies so a restart starts clean.
    while isready(_OUTBOX)
        try; take!(_OUTBOX); catch; break; end
    end
    Threads.atomic_xchg!(_INFLIGHT, 0)

    # Clean up socket file (ipc:// only — Windows uses TCP, nothing to remove)
    if !Sys.iswindows()
        endpoint = _SERVICE_ENDPOINT[]
        if !isempty(endpoint)
            sock_path = replace(endpoint, "ipc://" => "")
            if ispath(sock_path)
                rm(sock_path; force = true)
                @info "Service endpoint socket removed" sock_path
            end
        end
    end

    # Null refs — let GC handle ZMQ cleanup (same pattern as KaimonGate._cleanup)
    _SERVICE_SOCKET[] = nothing
    _SERVICE_CONTEXT[] = nothing
    _SERVICE_ENDPOINT[] = ""
end

"""
    _dispatch_service(request) -> NamedTuple

Dispatch a service request. Supports two request types:

- `(type = :tool_call, tool_name = :some_tool, args = Dict(...))` — call an MCP tool
- `(type = :list_tools)` — return the tool catalog for discovery

Returns `(status = :ok, value = result)` on success or
`(status = :error, message = "...")` on failure.
"""
function _dispatch_service(request)
    req_type = get(request, :type, :unknown)

    if req_type == :list_tools
        return _dispatch_list_tools()
    elseif req_type == :tool_call
        return _dispatch_tool_call(request)
    else
        return (status = :error, message = "Unknown request type: $req_type")
    end
end

function _dispatch_list_tools()
    server = SERVER[]
    if server === nothing
        return (status = :error, message = "MCP server not running")
    end

    tools = [(
        name = Symbol(tool.name),
        description = tool.description,
        parameters = tool.parameters,
    ) for (_, tool) in server.tools]

    return (status = :ok, value = tools)
end

function _dispatch_tool_call(request)
    tool_name = if hasproperty(request, :tool_name)
        string(request.tool_name)
    else
        return (status = :error, message = "Missing tool_name in request")
    end

    raw_args = if hasproperty(request, :args)
        request.args
    else
        Dict{String,Any}()
    end
    # Normalize to Dict{String,Any}
    args = if raw_args isa Dict{String,Any}
        raw_args
    elseif raw_args isa Dict
        Dict{String,Any}(string(k) => v for (k, v) in raw_args)
    else
        Dict{String,Any}(string(k) => v for (k, v) in pairs(raw_args))
    end

    server = SERVER[]
    if server === nothing
        return (status = :error, message = "MCP server not running")
    end

    # Resolve against the FULL tool registry (ALL_TOOLS[]), not the agent-advertised
    # surface. Trusted extensions (e.g. KaimonSlate's doc pipeline) reach this via the
    # service endpoint and must be able to call infra/building-block tools that are
    # gated off the agent tool-list (DEFAULT_OFF_TOOLS). The agent path (MCP tools/call)
    # still uses the filtered server.name_to_id and is unaffected.
    tool = nothing
    registry = ALL_TOOLS[]
    if registry !== nothing
        for t in registry
            if t.name == tool_name
                tool = t
                break
            end
        end
    end
    if tool === nothing
        # Fallback to the server's advertised registry (pre-populate window / safety).
        tid = get(server.name_to_id, tool_name, nothing)
        tid !== nothing && (tool = get(server.tools, tid, nothing))
    end
    if tool === nothing
        return (status = :error, message = "Unknown tool: $tool_name")
    end

    result = try
        Base.invokelatest(tool.handler, args)
    catch e
        return (status = :error, message = sprint(showerror, e))
    end

    return (status = :ok, value = result)
end

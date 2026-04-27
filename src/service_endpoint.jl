# ═══════════════════════════════════════════════════════════════════════════════
# Service Endpoint — Reverse channel for gate → Kaimon tool calls
#
# The existing gate socket (Kaimon REQ → Gate REP) only allows Kaimon to send
# requests to the gate. This endpoint enables the reverse: gate sessions can
# call any registered Kaimon MCP tool by name, using the same handler functions
# that MCP clients use.
#
# Architecture:
#   Gate (REQ) ──→ Service Endpoint (REP) ──→ SERVER[].tools[id].handler(args)
# ═══════════════════════════════════════════════════════════════════════════════

const _SERVICE_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)
const _SERVICE_CONTEXT = Ref{Union{ZMQ.Context,Nothing}}(nothing)
const _SERVICE_TASK = Ref{Union{Task,Nothing}}(nothing)
const _SERVICE_RUNNING = Ref{Bool}(false)
const _SERVICE_ENDPOINT = Ref{String}("")

"""
    start_service_endpoint!() -> NamedTuple

Bind a ZMQ REP socket for tool call requests from gate sessions.
Gate code calls `Gate.call_tool(name, args)` which sends requests to this
endpoint. The dispatcher looks up the tool in Kaimon's MCP tool registry
and calls its handler.

Returns `(endpoint, socket, context)` on success.
"""
function start_service_endpoint!()
    if Sys.iswindows()
        endpoint = "tcp://127.0.0.1:$(Gate._SERVICE_TCP_PORT[])"
    else
        endpoint = "ipc://$(Gate.SOCK_DIR)/kaimon-service.sock"
        sock_path = replace(endpoint, "ipc://" => "")
        # Clean up stale socket file
        ispath(sock_path) && rm(sock_path)
    end

    ctx = ZMQ.Context()
    sock = Socket(ctx, REP)
    sock.rcvtimeo = 1000   # 1s timeout so loop can check _SERVICE_RUNNING
    sock.linger = 0
    bind(sock, endpoint)

    _SERVICE_SOCKET[] = sock
    _SERVICE_CONTEXT[] = ctx
    _SERVICE_ENDPOINT[] = endpoint
    _SERVICE_RUNNING[] = true

    _SERVICE_TASK[] = @async begin
        while _SERVICE_RUNNING[]
            try
                raw = Gate._zmq_recv(sock)
                request = Serialization.deserialize(IOBuffer(raw))
                response = Base.invokelatest(_dispatch_service, request)
                io = IOBuffer()
                Serialization.serialize(io, response)
                send(sock, take!(io))
            catch e
                if !_SERVICE_RUNNING[]
                    break
                end
                if e isa ZMQ.TimeoutError
                    continue
                end
                if e isa ZMQ.StateError || e isa EOFError
                    break
                end
                # Try to send error response
                try
                    io = IOBuffer()
                    Serialization.serialize(io, (status = :error, message = sprint(showerror, e)))
                    send(sock, take!(io))
                catch
                end
            end
        end
    end

    @info "Service endpoint bound" endpoint = endpoint
    return (endpoint = endpoint, context = ctx, socket = sock)
end

"""
    stop_service_endpoint!()

Stop the service endpoint and clean up resources.
"""
function stop_service_endpoint!()
    _SERVICE_RUNNING[] = false

    task = _SERVICE_TASK[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end
    _SERVICE_TASK[] = nothing

    # Clean up socket file (IPC only — Windows uses TCP, nothing to clean)
    if !Sys.iswindows()
        endpoint = _SERVICE_ENDPOINT[]
        if !isempty(endpoint)
            sock_path = replace(endpoint, "ipc://" => "")
            ispath(sock_path) && rm(sock_path; force = true)
        end
    end

    # Null refs — let GC handle ZMQ cleanup (same pattern as Gate._cleanup)
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

    tool_id = get(server.name_to_id, tool_name, nothing)
    if tool_id === nothing
        return (status = :error, message = "Unknown tool: $tool_name")
    end

    tool = get(server.tools, tool_id, nothing)
    if tool === nothing
        return (status = :error, message = "Tool not found: $tool_name")
    end

    result = try
        Base.invokelatest(tool.handler, args)
    catch e
        return (status = :error, message = sprint(showerror, e))
    end

    return (status = :ok, value = result)
end

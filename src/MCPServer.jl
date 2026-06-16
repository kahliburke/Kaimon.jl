using HTTP
using JSON
using Logging
using UUIDs
using Dates

# Import Session module
include("session.jl")
using .Session

"""
    is_trusted_origin(origin::AbstractString) -> Bool

Return true only for exact localhost origins. This parses the Origin header as a
URI instead of using prefix checks so values like `http://localhost.evil.test`
or `http://localhost@evil.test` are rejected.
"""
function is_trusted_origin(origin::AbstractString)
    try
        uri = HTTP.URI(origin)
        host = lowercase(String(uri.host))
        scheme = lowercase(String(uri.scheme))
        return !isempty(scheme) &&
               scheme in ("http", "https") &&
               (host == "localhost" || host == "127.0.0.1" || host == "::1")
    catch
        return false
    end
end

# ============================================================================
# Multi-Session Support (In-Memory)
# ============================================================================

# Global session registry for standalone mode
const STANDALONE_SESSIONS = Dict{String,MCPSession}()
const STANDALONE_SESSIONS_LOCK = ReentrantLock()

# ============================================================================
# Session Persistence (Standalone Mode)
# ============================================================================

"""
    get_sessions_file_path() -> String

Get the path to the sessions persistence file (.kaimon/sessions.json).
"""
function get_sessions_file_path()
    return joinpath(kaimon_cache_dir(), "sessions.json")
end

"""
    load_persisted_sessions() -> Dict{String, Dict}

Load persisted session data from .kaimon/sessions.json.
Returns a dict mapping session_id => {created_at, last_seen}.
Filters out sessions older than 1 month.
"""
function load_persisted_sessions()
    sessions_file = get_sessions_file_path()

    if !isfile(sessions_file)
        return Dict{String,Dict}()
    end

    try
        data = JSON.parsefile(sessions_file)
        sessions = get(data, "sessions", Dict())

        # Filter out expired sessions (older than 1 month)
        cutoff = now() - Month(1)
        valid_sessions = Dict{String,Dict}()

        for (session_id, session_data) in sessions
            created_at_str = get(session_data, "created_at", nothing)
            if created_at_str !== nothing
                try
                    created_at = DateTime(created_at_str, dateformat"yyyy-mm-dd\THH:MM:SS")
                    if created_at >= cutoff
                        valid_sessions[session_id] = session_data
                    else
                        @debug "Expired session filtered out" session_id = session_id age =
                            (now() - created_at)
                    end
                catch e
                    @warn "Invalid date format for session" session_id = session_id error =
                        e
                end
            end
        end

        return valid_sessions
    catch e
        @warn "Failed to load persisted sessions" error = e path = sessions_file
        return Dict{String,Dict}()
    end
end

"""
    save_persisted_sessions(sessions::Dict{String, Dict})

Save session data to .kaimon/sessions.json.
"""
function save_persisted_sessions(sessions::Dict{String,Dict})
    sessions_file = get_sessions_file_path()

    try
        data = Dict("sessions" => sessions)
        open(sessions_file, "w") do f
            JSON.print(f, data, 2)
        end
        @debug "Saved persisted sessions" count = length(sessions) path = sessions_file
    catch e
        @warn "Failed to save persisted sessions" error = e path = sessions_file
    end
end

"""
    register_persisted_session(session_id::String)

Register a session in the persistence file with the current timestamp.
"""
function register_persisted_session(session_id::String)
    sessions = load_persisted_sessions()
    now_str = Dates.format(now(), "yyyy-mm-dd\\THH:MM:SS")

    # If session exists, only update last_seen; otherwise create new entry
    if haskey(sessions, session_id)
        sessions[session_id]["last_seen"] = now_str
    else
        sessions[session_id] = Dict("created_at" => now_str, "last_seen" => now_str)
    end

    save_persisted_sessions(sessions)
end

"""
    get_or_create_session(session_id::Union{String,Nothing}, is_initialize::Bool) -> (MCPSession, Bool)

Get existing session by ID or create a new one for initialize requests.
Checks persisted sessions file to allow reconnection after REPL restart.
Returns (session, is_new) tuple.
"""
function get_or_create_session(session_id::Union{String,Nothing}, is_initialize::Bool)
    lock(STANDALONE_SESSIONS_LOCK) do
        if is_initialize
            # Check if client provided an existing session ID
            if session_id !== nothing
                # Try to restore from persisted sessions (allows reconnection after restart).
                # We intentionally don't check STANDALONE_SESSIONS here: the restored
                # MCPSession must be in UNINITIALIZED state for initialize_session!() to work.
                persisted_sessions = load_persisted_sessions()
                if haskey(persisted_sessions, session_id)
                    # Valid persisted session found - restore it
                    session = MCPSession()
                    session.id = session_id  # Use the existing session ID
                    STANDALONE_SESSIONS[session.id] = session
                    register_persisted_session(session.id)  # Update last_seen
                    @info "Restored persisted MCP session" session_id = session.id
                    return (session, false)
                else
                    @debug "Session ID provided but not found in persisted sessions" session_id =
                        session_id
                end
            end

            # Create a new session (either no ID provided or ID not found in persisted sessions)
            session = MCPSession()
            STANDALONE_SESSIONS[session.id] = session
            register_persisted_session(session.id)  # Save to persistence file
            @info "Created new MCP session" session_id = session.id
            return (session, true)
        elseif session_id !== nothing
            # Non-initialize request - check memory first
            if haskey(STANDALONE_SESSIONS, session_id)
                # Session exists in memory
                register_persisted_session(session_id)  # Update last_seen
                return (STANDALONE_SESSIONS[session_id], false)
            else
                # Not in memory - check persisted sessions
                persisted_sessions = load_persisted_sessions()
                if haskey(persisted_sessions, session_id)
                    # Restore from persistence
                    session = MCPSession()
                    session.id = session_id
                    session.state = Session.INITIALIZED  # Auto-initialize so tool calls work immediately
                    session.initialized_at = now()
                    STANDALONE_SESSIONS[session.id] = session
                    register_persisted_session(session.id)  # Update last_seen
                    @info "Restored session from persistence file" session_id = session.id
                    return (session, false)
                else
                    # Session ID not in persistence file — create it on the fly.
                    # Some MCP clients (e.g. Claude Code) don't re-initialize after a
                    # 404; they just mark the server as down. Be lenient: accept the
                    # session ID and let the request proceed.
                    session = MCPSession()
                    session.id = session_id
                    session.state = Session.INITIALIZED
                    session.initialized_at = now()
                    STANDALONE_SESSIONS[session.id] = session
                    register_persisted_session(session.id)
                    @warn "Accepted unknown session ID (client did not re-initialize)" session_id =
                        session.id
                    return (session, false)
                end
            end
        else
            # No session ID provided for non-initialize request — create an anonymous session.
            # This handles clients that skip the initialize handshake entirely.
            session = MCPSession()
            session.state = Session.INITIALIZED
            session.initialized_at = now()
            STANDALONE_SESSIONS[session.id] = session
            register_persisted_session(session.id)
            @warn "Created anonymous session for request without session ID"
            return (session, true)
        end
    end
end

"""
    extract_session_id(req::HTTP.Request) -> Union{String,Nothing}

Extract Mcp-Session-Id header from request.
"""
function extract_mcp_session_id(req)
    for (name, value) in req.headers
        if lowercase(name) == "mcp-session-id"
            return String(value)
        end
    end
    return nothing
end

# Import Prompts module
include("prompts.jl")
using .Prompts

# ============================================================================
# Resource Change Notification Queue
# ============================================================================

"""Pending JSON-RPC notifications to flush on the next SSE response.

Both GET SSE streams and POST response flushes drain this independently —
each takes a snapshot and delivers it, so both paths see every notification.
Notifications are deduplicated by method name within each flush.
"""
const _PENDING_NOTIFICATIONS = Dict{String,Dict{String,Any}}()  # method => notification
const _PENDING_NOTIFICATIONS_LOCK = ReentrantLock()

function _queue_notification!(notif::Dict{String,Any})
    lock(_PENDING_NOTIFICATIONS_LOCK) do
        _PENDING_NOTIFICATIONS[notif["method"]] = notif
    end
end

function _take_notifications!()::Vector{Dict{String,Any}}
    lock(_PENDING_NOTIFICATIONS_LOCK) do
        isempty(_PENDING_NOTIFICATIONS) && return Dict{String,Any}[]
        result = collect(values(_PENDING_NOTIFICATIONS))
        empty!(_PENDING_NOTIFICATIONS)
        return result
    end
end


"""Drop all pending notifications. Called on server start/stop so the queue is
bound to a server's lifecycle — a freshly-started server must not flush
notifications queued before it existed (e.g. by a previous server instance),
which would otherwise upgrade its first POST response to SSE unexpectedly."""
function _clear_notifications!()
    lock(_PENDING_NOTIFICATIONS_LOCK) do
        empty!(_PENDING_NOTIFICATIONS)
    end
end

"""
    register_sessions_changed_callback!(mgr::ConnectionManager)

Wire up `mgr.on_sessions_changed` so it enqueues a
`notifications/resources/list_changed` notification for the next SSE flush.
"""
function register_sessions_changed_callback!(mgr)
    mgr.on_sessions_changed =
        () -> _queue_notification!(Dict{String,Any}(
            "jsonrpc" => "2.0",
            "method" => "notifications/resources/list_changed",
        ))
end

# ============================================================================
# REPL Resource Helpers (for MCP resources/list and resources/read)
# ============================================================================

function _list_repl_resources()
    mgr = GATE_CONN_MGR[]
    mgr === nothing && return Dict{String,Any}[]
    resources = Dict{String,Any}[]
    for conn in connected_sessions(mgr)
        key = short_key(conn)
        dname = isempty(conn.display_name) ? conn.name : conn.display_name
        proj = isempty(conn.project_path) ? "unknown" : basename(conn.project_path)
        push!(
            resources,
            Dict{String,Any}(
                "uri" => "repl://$(key)",
                "name" => key,
                "title" => "$(dname) — $proj",
                "description" => "Julia $(conn.julia_version) (PID $(conn.pid)) | Project: $(conn.project_path) | Session: $(key)",
                "mimeType" => "application/json",
            ),
        )
    end
    return resources
end

function _read_repl_resource(uri::String)
    key = replace(uri, "repl://" => "")
    mgr = GATE_CONN_MGR[]
    mgr === nothing && return JSON.json(Dict("error" => "No connection manager"))
    conn = get_connection_by_key(mgr, key)
    conn === nothing && return JSON.json(Dict("error" => "Session not found: $key"))
    dname = isempty(conn.display_name) ? conn.name : conn.display_name
    return JSON.json(
        Dict(
            "key" => short_key(conn),
            "name" => dname,
            "session_id" => conn.session_id,
            "status" => string(conn.status),
            "project_path" => conn.project_path,
            "julia_version" => conn.julia_version,
            "pid" => conn.pid,
            "connected_at" => string(conn.connected_at),
            "last_seen" => string(conn.last_seen),
            "tool_call_count" => conn.tool_call_count,
        ),
    )
end

# Import types and functions from parent module
import ..Kaimon:
    SecurityConfig, extract_api_key, validate_api_key, get_client_ip, validate_ip

# Server with tool registry and session management
mutable struct MCPServer
    uuid::String                          # Unique identifier for this session (persists across reconnections)
    port::Int
    server::HTTP.Server
    tools::Dict{Symbol,MCPTool}           # Symbol-keyed registry
    name_to_id::Dict{String,Symbol}       # String→Symbol lookup for JSON-RPC
    session::Union{MCPSession,Nothing}    # MCP session (one per server)
end

# Create request handler with access to tools and session
function create_handler(
    tools::Dict{Symbol,MCPTool},
    name_to_id::Dict{String,Symbol},
    port::Int,
    security_config::Union{SecurityConfig,Nothing} = nothing,
    session::Union{MCPSession,Nothing} = nothing,
)
    return function handle_request(req::HTTP.Request)
        # Origin validation — MCP 2025-11-25 Streamable HTTP spec requirement.
        let origin = HTTP.header(req, "Origin", "")
            if !isempty(origin)
                if !is_trusted_origin(origin)
                    return HTTP.Response(
                        403,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict("error" => "Forbidden: untrusted Origin")),
                    )
                end
            end
        end

        # Security check - apply to ALL endpoints including vscode-response
        nonce_validated = false  # Track if nonce auth succeeded

        if security_config !== nothing
            # Special handling for vscode-response endpoint with nonce auth
            if req.target == "/vscode-response" && req.method == "POST"
                # Extract the nonce (Bearer token) from Authorization header
                nonce = extract_api_key(req)

                # Parse request body to get request_id
                body = String(req.body)
                request_id = nothing
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)
                catch e
                    # Will fail validation below if can't parse
                end

                # Validate and consume nonce
                if nonce !== nothing && request_id !== nothing
                    if Kaimon.validate_and_consume_nonce(string(request_id), String(nonce))
                        # Nonce is valid and consumed
                        # Skip all other security checks - nonce auth is sufficient
                        nonce_validated = true
                    else
                        return HTTP.Response(
                            401,
                            ["Content-Type" => "application/json"],
                            JSON.json(
                                Dict("error" => "Unauthorized: Invalid or expired nonce"),
                            ),
                        )
                    end
                elseif security_config.mode != :lax
                    # No valid nonce, fall back to API key validation for vscode-response
                    if nonce === nothing
                        return HTTP.Response(
                            401,
                            ["Content-Type" => "application/json"],
                            JSON.json(
                                Dict(
                                    "error" => "Unauthorized: Missing nonce or API key in Authorization header",
                                ),
                            ),
                        )
                    end

                    if !validate_api_key(String(nonce), security_config)
                        return HTTP.Response(
                            401,
                            ["Content-Type" => "application/json"],
                            JSON.json(Dict("error" => "Unauthorized: Invalid API key")),
                        )
                    end

                    # If using API key (not nonce), still need to validate IP
                    client_ip = get_client_ip(req)
                    if !validate_ip(client_ip, security_config)
                        return HTTP.Response(
                            403,
                            ["Content-Type" => "application/json"],
                            JSON.json(
                                Dict(
                                    "error" => "Forbidden: IP address $client_ip not allowed",
                                ),
                            ),
                        )
                    end
                end
            elseif !nonce_validated
                # For non-vscode-response endpoints, use standard API key validation
                # Extract and validate API key
                api_key = extract_api_key(req)
                if api_key === nothing && security_config.mode != :lax
                    return HTTP.Response(
                        401,
                        ["Content-Type" => "application/json"],
                        JSON.json(
                            Dict(
                                "error" => "Unauthorized: Missing API key in Authorization header",
                            ),
                        ),
                    )
                end

                if !validate_api_key(String(something(api_key, "")), security_config)
                    return HTTP.Response(
                        403,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict("error" => "Forbidden: Invalid API key")),
                    )
                end

                # Validate IP address
                client_ip = get_client_ip(req)
                if !validate_ip(client_ip, security_config)
                    return HTTP.Response(
                        403,
                        ["Content-Type" => "application/json"],
                        JSON.json(
                            Dict("error" => "Forbidden: IP address $client_ip not allowed"),
                        ),
                    )
                end
            end
        end

        # Parse JSON-RPC request
        body = String(req.body)

        try
            # Handle VS Code response endpoint (for bidirectional communication)
            if req.target == "/vscode-response" && req.method == "POST"
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)

                    if request_id === nothing
                        return HTTP.Response(
                            400,
                            ["Content-Type" => "application/json"],
                            JSON.json(Dict("error" => "Missing request_id")),
                        )
                    end

                    result = get(response_data, "result", nothing)
                    error = get(response_data, "error", nothing)

                    # Store the response using Kaimon function
                    Kaimon.store_vscode_response(string(request_id), result, error)

                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict("status" => "ok")),
                    )
                catch e
                    return HTTP.Response(
                        500,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict("error" => "Failed to process response: $e")),
                    )
                end
            end

            # Handle AGENTS.md well-known documentation (before JSON parsing)
            # Serve AGENTS.md from project root if it exists
            if req.target == "/.well-known/agents.md" ||
               req.target == "/agents.md" ||
               req.target == "/.well-known/AGENTS.md" ||
               req.target == "/AGENTS.md"
                agents_path = joinpath(pwd(), "AGENTS.md")
                if isfile(agents_path)
                    agents_content = read(agents_path, String)
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "text/markdown; charset=utf-8"],
                        agents_content,
                    )
                else
                    return HTTP.Response(
                        404,
                        ["Content-Type" => "text/plain"],
                        "AGENTS.md not found in project root",
                    )
                end
            end

            # Handle MCP JSON-RPC endpoint at /mcp path
            if req.target == "/mcp" && req.method == "POST"
                # Fall through to the JSON-RPC handling below
            end

            # Handle OAuth well-known metadata requests first (before JSON parsing)
            # Only advertise OAuth if security is configured (not in lax mode)
            if req.target == "/.well-known/oauth-authorization-server"
                if security_config !== nothing && security_config.mode != :lax
                    return _oauth_metadata_response(port)
                else
                    # No OAuth in lax mode - return 404
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle dynamic client registration
            # Only support OAuth if security is configured (not in lax mode)
            if req.target == "/oauth/register" && req.method == "POST"
                if security_config !== nothing && security_config.mode != :lax
                    return _oauth_register_response()
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle authorization endpoint
            if startswith(req.target, "/oauth/authorize")
                if security_config !== nothing && security_config.mode != :lax
                    return _oauth_authorize_response(req)
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle token endpoint
            if req.target == "/oauth/token" && req.method == "POST"
                if security_config !== nothing && security_config.mode != :lax
                    return _oauth_token_response()
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle GET requests — return empty SSE stream per 2025-11-25 spec.
            if req.method == "GET"
                return HTTP.Response(
                    200,
                    ["Content-Type" => "text/event-stream", "Cache-Control" => "no-cache"],
                    ": keepalive\n\n",
                )
            end

            # Handle DELETE requests - return 405 per Streamable HTTP spec
            if req.method == "DELETE"
                return HTTP.Response(
                    405,
                    ["Content-Type" => "application/json", "Allow" => "GET, POST"],
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => nothing,
                            "error" => Dict(
                                "code" => -32600,
                                "message" => "Method Not Allowed - session termination via DELETE not supported",
                            ),
                        ),
                    ),
                )
            end

            # MCP-Protocol-Version header validation — 2025-11-25 spec requirement.
            let ver = HTTP.header(req, "MCP-Protocol-Version", "")
                if !isempty(ver) && ver ∉ ("2025-06-18", "2025-03-26", "2025-11-25", "2025-11-05", "2024-11-05")
                    return HTTP.Response(
                        400,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict(
                            "jsonrpc" => "2.0",
                            "id" => nothing,
                            "error" => Dict(
                                "code" => -32600,
                                "message" => "Unsupported MCP-Protocol-Version: $ver",
                            ),
                        )),
                    )
                end
            end

            # Handle empty body for POST requests
            # Note: Static file endpoints (AGENTS.md, OAuth metadata) already handled above
            if isempty(body)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 0,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - empty body",
                    ),
                )
                return HTTP.Response(
                    400,
                    ["Content-Type" => "application/json"],
                    JSON.json(error_response),
                )
            end

            # Support both root "/" and "/mcp" endpoints for HTTP JSON-RPC
            # This allows MCP clients to use either endpoint
            request = JSON.parse(body; dicttype = Dict{String,Any})

            # Check if method field exists
            if !haskey(request, "method")
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", 0),
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - missing method field",
                    ),
                )
                return HTTP.Response(
                    400,
                    ["Content-Type" => "application/json"],
                    JSON.json(error_response),
                )
            end

            # JSON-RPC method dispatch. Each handler lives in mcp_rpc_methods.jl
            # and returns an HTTP.Response; they run inside this try so a thrown
            # error still becomes the -32603/500 response below. request["method"]
            # is guaranteed present (checked above).
            method = request["method"]
            method == "initialize" && return _rpc_initialize(request, session)
            method == "notifications/initialized" &&
                return _rpc_notifications_initialized(request, session)
            method == "logging/setLevel" && return _rpc_logging_setlevel(request)
            method == "session/info" && return _rpc_session_info(request, session)
            method == "tools/list" && return _rpc_tools_list(request, tools)
            method == "resources/list" && return _rpc_resources_list(request)
            method == "resources/read" && return _rpc_resources_read(request)
            method == "resources/templates/list" &&
                return _rpc_resources_templates_list(request)
            method == "prompts/list" && return _rpc_prompts_list(request)
            method == "prompts/get" && return _rpc_prompts_get(request)
            method == "tools/call" && return _rpc_tools_call(request, tools, name_to_id)

            # Method not found
            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", 0),
                "error" => Dict("code" => -32601, "message" => "Method not found"),
            )
            return HTTP.Response(
                404,
                ["Content-Type" => "application/json"],
                JSON.json(error_response),
            )

        catch e
            # Internal error - log and return to client
            if GATE_MODE[]
                @error "MCP Server error: $e"
            else
                printstyled("\nMCP Server error: $e\n", color = :red)
            end

            # Try to get the original request ID for proper JSON-RPC error response
            request_id = 0  # Default to 0 instead of nothing to satisfy JSON-RPC schema
            try
                if !isempty(body)
                    parsed_request = JSON.parse(body; dicttype = Dict{String,Any})
                    # Only use the request ID if it's a valid JSON-RPC ID (string or number)
                    raw_id = get(parsed_request, :id, 0)
                    if raw_id isa Union{String,Number}
                        request_id = raw_id
                    end
                end
            catch
                # If we can't parse the request, use default ID
                request_id = 0
            end

            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "error" => Dict("code" => -32603, "message" => "Internal error: $e"),
            )
            return HTTP.Response(
                500,
                ["Content-Type" => "application/json"],
                JSON.json(error_response),
            )
        end
    end
end


"""
Handle a gate-mode tool call with SSE progress notifications.

Sends `Content-Type: text/event-stream` and streams:
1. `notifications/progress` events with stdout/stderr chunks as they arrive
2. A heartbeat every 5 seconds of silence to keep the connection alive
3. The final JSON-RPC result as the last SSE event
"""
function _handle_gate_tool_sse(
    http::HTTP.Stream,
    request::Dict{String,Any},
    tools_dict::Dict{Symbol,MCPTool},
    name_to_id::Dict{String,Symbol},
    session,
)
    request_id = get(request, "id", 0)
    tool_name_str = request["params"]["name"]
    tool_id = get(name_to_id, tool_name_str, nothing)
    args = get(request["params"], "arguments", Dict())

    if tool_id === nothing || !haskey(tools_dict, tool_id)
        HTTP.setstatus(http, 404)
        HTTP.setheader(http, "Content-Type" => "application/json")
        HTTP.startwrite(http)
        write(
            http,
            JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => request_id,
                    "error" => Dict(
                        "code" => -32602,
                        "message" => "Tool not found: $tool_name_str",
                    ),
                ),
            ),
        )
        return nothing
    end

    tool = tools_dict[tool_id]

    # Start SSE response
    HTTP.setstatus(http, 200)
    HTTP.setheader(http, "Content-Type" => "text/event-stream")
    HTTP.setheader(http, "Cache-Control" => "no-cache")
    HTTP.setheader(http, "Connection" => "keep-alive")
    HTTP.startwrite(http)

    progress_token = "tool-$(tool_name_str)-$(round(Int, time()))"

    # ── Flush pending notifications (e.g., resource list changes) ─────────
    for notif in _take_notifications!()
        try
            notif_json = JSON.json(notif)
            write(http, "data: $(notif_json)\n\n")
            flush(http)
        catch
        end
    end
    step_counter = Ref(0)
    last_event_time = Ref(time())

    # Write an SSE event (JSON-RPC notification)
    function send_sse_event(data::Dict)
        try
            event_json = JSON.json(data)
            write(http, "data: $(event_json)\n\n")
            flush(http)
            last_event_time[] = time()
        catch
            # Connection may have closed
        end
    end

    # Send progress notification
    # Note: inflight_id is captured from the enclosing scope after it's assigned below
    _sse_inflight_id = Ref{Int}(0)
    _sse_eval_id = Ref{String}("")
    function send_progress(message::String)
        step_counter[] += 1

        # Detect structured eval_id tag → emit as proper JSON field, not message text
        eval_id_match = match(r"^\[eval_id:([0-9a-f]+)\]$", message)
        params = if eval_id_match !== nothing
            eid = String(eval_id_match.captures[1])
            _sse_eval_id[] = eid
            Dict(
                "progressToken" => progress_token,
                "progress" => step_counter[],
                "eval_id" => eid,
            )
        else
            Dict(
                "progressToken" => progress_token,
                "progress" => step_counter[],
                "message" =>
                    length(message) > 200 ? first(message, 200) * "..." : message,
            )
        end

        send_sse_event(
            Dict(
                "jsonrpc" => "2.0",
                "method" => "notifications/progress",
                "params" => params,
            ),
        )
        # Push progress to in-flight tracker for TUI display
        if _sse_inflight_id[] > 0
            _push_inflight_progress!(
                _sse_inflight_id[],
                length(message) > 200 ? first(message, 200) * "..." : message,
            )
        end
    end

    # Start heartbeat task
    heartbeat_done = Ref(false)
    heartbeat_task = @async begin
        while !heartbeat_done[]
            sleep(1.0)
            heartbeat_done[] && break
            if time() - last_event_time[] >= 5.0
                send_progress("Still executing...")
            end
        end
    end

    # Push activity events in TUI mode
    _push_activity!(:tool_start, tool.name, "", "")
    sk = string(get(args, "ses", get(args, "session", "")))
    args_json = JSON.json(args)
    inflight_id = _push_inflight_start!(tool.name, args_json, sk)
    _sse_inflight_id[] = inflight_id
    db_request_id = _persist_tool_start!(tool.name, args_json, sk)
    start_time = time()
    tool_ok = true

    result_text = try
        # Call tool handler with progress callback piped through
        # The tool handler calls execute_via_gate_streaming which accepts on_progress
        # We inject on_progress into the args dict as a special key that execute_via_gate_streaming
        # will pick up. However, tool handlers don't pass on_progress directly.
        # Instead, we'll call the tool handler normally — the progress comes from
        # execute_via_gate_streaming being called within the tool handler.
        # For the `ex` tool specifically, we can call execute_via_gate_streaming directly.
        if tool_name_str == "ex"
            # Direct streaming path for the ex tool
            code = get(args, "e", "")
            quiet = get(args, "q", true)
            silent = get(args, "s", false)
            max_output = min(get(args, "max_output", 6000), 25000)
            ses = get(args, "ses", "")
            main_thread = get(args, "mt", false)
            execute_via_gate_streaming(
                code;
                quiet = quiet,
                silent = silent,
                max_output = max_output,
                session = ses,
                main_thread = main_thread,
                on_progress = send_progress,
            )
        else
            # All other tools (including session tools): inject progress callback
            args["_on_progress"] = send_progress
            Base.invokelatest(tool.handler, args)
        end
    catch e
        tool_ok = false
        "ERROR: $(sprint(showerror, e))"
    finally
        heartbeat_done[] = true
        elapsed = time() - start_time
        time_str =
            elapsed < 1.0 ? @sprintf("%.0fms", elapsed * 1000) : @sprintf("%.1fs", elapsed)
        _push_activity!(:tool_done, tool.name, "", time_str; success = tool_ok)
        _push_inflight_done!(inflight_id)
    end

    # Push tool result for TUI Activity inspection + update DB record
    try
        elapsed = time() - start_time
        time_str =
            elapsed < 1.0 ? @sprintf("%.0fms", elapsed * 1000) : @sprintf("%.1fs", elapsed)
        rt = _tool_result_log_text(string(result_text))
        ok = tool_ok && !startswith(rt, "ERROR:")
        sk = string(get(args, "ses", get(args, "session", "")))
        tcr = ToolCallResult(now(), tool.name, args_json, rt, time_str, ok, sk, _sse_eval_id[])
        _push_tool_result!(tcr)
        _persist_tool_complete!(db_request_id, tcr)
    catch e
        _push_log!(:warn, "Failed to push tool result for TUI: $(sprint(showerror, e))")
    end

    # Send final JSON-RPC result as last SSE event
    content_blocks, is_err = _build_tool_content(string(result_text))
    result_dict = Dict{String,Any}("content" => content_blocks)
    is_err && (result_dict["isError"] = true)
    if !isempty(_sse_eval_id[])
        result_dict["eval_id"] = _sse_eval_id[]
    end
    send_sse_event(
        Dict(
            "jsonrpc" => "2.0",
            "id" => request_id,
            "result" => result_dict,
        ),
    )

    return nothing
end

function start_mcp_server(
    tools::Vector{MCPTool},
    port::Int = 3000;
    verbose::Bool = true,
    security_config::Union{SecurityConfig,Nothing} = nothing,
    session_uuid::Union{String,Nothing} = nothing,
)
    # Use provided UUID or generate a new one (persists across reconnections)
    session_uuid = session_uuid !== nothing ? session_uuid : string(UUIDs.uuid4())

    # Start with a clean notification queue: any notifications queued before
    # this server existed belong to no client of ours and must not trigger an
    # SSE upgrade on our first response.
    _clear_notifications!()

    # Build symbol-keyed registry
    tools_dict = Dict{Symbol,MCPTool}(tool.id => tool for tool in tools)
    # Build string→symbol mapping for JSON-RPC
    name_to_id = Dict{String,Symbol}(tool.name => tool.id for tool in tools)

    # Multi-session support: sessions are created/retrieved per Mcp-Session-Id header

    # Create a hybrid handler that supports both regular and streaming responses
    function hybrid_handler(http::HTTP.Stream)
        # Use Base.invokelatest to allow Revise to hot-reload the handler logic
        return Base.invokelatest(
            _hybrid_handler_impl,
            http,
            tools_dict,
            name_to_id,
            security_config,
            port,
        )
    end

    function _hybrid_handler_impl(
        http::HTTP.Stream,
        tools_dict,
        name_to_id,
        security_config,
        port,
    )
        req = HTTP.startread(http)

        # Read the full request body before writing any response (must be fully
        # consumed or HTTP.jl RSTs the connection). On an HTTP 2.0 server Stream
        # the body read is `read(stream, String)`; `readavailable` is client-only.
        # IOError on early client disconnect is swallowed to avoid spurious logs.
        body = try
            read(http, String)
        catch e
            e isa Base.IOError && return nothing   # client disconnected before sending body
            rethrow()
        end

        # Origin validation — MCP 2025-11-25 Streamable HTTP spec requirement.
        # If an Origin header is present it must be a trusted local origin.
        # Absent Origin is allowed (non-browser clients don't send it).
        let origin = HTTP.header(req, "Origin", "")
            if !isempty(origin)
                if !is_trusted_origin(origin)
                    HTTP.setstatus(http, 403)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("error" => "Forbidden: untrusted Origin")))
                    return nothing
                end
            end
        end

        # Security check - apply to ALL endpoints including vscode-response
        nonce_validated = false  # Track if nonce auth succeeded

        if security_config !== nothing
            # Special handling for vscode-response endpoint with nonce auth
            if req.target == "/vscode-response" && req.method == "POST"
                # Extract the nonce (Bearer token) from Authorization header
                nonce = extract_api_key(req)

                # Parse request body to get request_id
                request_id = nothing
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)
                catch e
                    # Will fail validation below if can't parse
                end

                # Validate and consume nonce
                if nonce !== nothing && request_id !== nothing
                    if Kaimon.validate_and_consume_nonce(string(request_id), String(nonce))
                        # Nonce is valid and consumed - skip all other security checks
                        nonce_validated = true
                    else
                        # Nonce validation failed
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(
                                Dict("error" => "Unauthorized: Invalid or expired nonce"),
                            ),
                        )
                        return nothing
                    end
                elseif security_config.mode != :lax
                    # No valid nonce, fall back to API key validation for vscode-response
                    if nonce === nothing
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(
                                Dict(
                                    "error" => "Unauthorized: Missing nonce or API key in Authorization header",
                                ),
                            ),
                        )
                        return nothing
                    end

                    if !validate_api_key(String(nonce), security_config)
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(Dict("error" => "Unauthorized: Invalid API key")),
                        )
                        return nothing
                    end

                    # If using API key (not nonce), still need to validate IP
                    client_ip = get_client_ip(req)
                    if !validate_ip(client_ip, security_config)
                        HTTP.setstatus(http, 403)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(
                                Dict(
                                    "error" => "Forbidden: IP address $client_ip not allowed",
                                ),
                            ),
                        )
                        return nothing
                    end
                end
            elseif !nonce_validated
                # For non-vscode-response endpoints, use standard API key validation
                api_key = extract_api_key(req)
                if api_key === nothing && security_config.mode != :lax
                    HTTP.setstatus(http, 401)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "error" => "Unauthorized: Missing API key in Authorization header",
                            ),
                        ),
                    )
                    return nothing
                end

                if !validate_api_key(String(something(api_key, "")), security_config)
                    HTTP.setstatus(http, 403)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("error" => "Forbidden: Invalid API key")))
                    return nothing
                end

                # Validate IP address
                client_ip = get_client_ip(req)
                if !validate_ip(client_ip, security_config)
                    HTTP.setstatus(http, 403)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict("error" => "Forbidden: IP address $client_ip not allowed"),
                        ),
                    )
                    return nothing
                end
            end
        end

        try
            # Handle AGENTS.md endpoint (can have empty body for GET requests)
            if req.target == "/.well-known/agents.md" ||
               req.target == "/agents.md" ||
               req.target == "/.well-known/AGENTS.md" ||
               req.target == "/AGENTS.md"
                agents_path = joinpath(pwd(), "AGENTS.md")
                if isfile(agents_path)
                    agents_content = read(agents_path, String)
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "text/markdown; charset=utf-8")
                    HTTP.startwrite(http)
                    isempty(agents_content) || write(http, agents_content)  # avoid empty chunked write
                    return nothing
                else
                    HTTP.setstatus(http, 404)
                    HTTP.setheader(http, "Content-Type" => "text/plain")
                    HTTP.startwrite(http)
                    write(http, "AGENTS.md not found in project root")
                    return nothing
                end
            end

            # Handle VS Code response endpoint FIRST (before any JSON parsing)
            if req.target == "/vscode-response" && req.method == "POST"
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)

                    if request_id === nothing
                        HTTP.setstatus(http, 400)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(http, JSON.json(Dict("error" => "Missing request_id")))
                        return nothing
                    end

                    result = get(response_data, "result", nothing)
                    error = get(response_data, "error", nothing)

                    # Store the response
                    Kaimon.store_vscode_response(string(request_id), result, error)

                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("status" => "ok")))
                    return nothing
                catch e
                    HTTP.setstatus(http, 500)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(Dict("error" => "Failed to process response: $e")),
                    )
                    return nothing
                end
            end

            # ── REST API: /api/connect_tcp ─────────────────────────────────
            # REST endpoint for programmatic TCP gate connections. Auth is
            # handled by the standard API key check above — no special
            # CORS or origin bypass needed.
            if req.target == "/api/connect_tcp" && req.method == "POST"
                try
                    data = JSON.parse(body; dicttype = Dict{String,Any})
                    host = get(data, "host", nothing)
                    port = get(data, "port", nothing)
                    name = get(data, "name", "remote")
                    server_key = string(get(data, "server_key", ""))

                    if host === nothing || port === nothing
                        HTTP.setstatus(http, 400)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(http, JSON.json(Dict("error" => "host and port are required")))
                        return nothing
                    end

                    port_int = Int(port)
                    if port_int < 1 || port_int > 65535
                        HTTP.setstatus(http, 400)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(http, JSON.json(Dict("error" => "port must be between 1 and 65535")))
                        return nothing
                    end

                    conn = Kaimon.connect_tcp_to_active_manager(string(host), port_int; name=string(name), server_key=server_key)

                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict(
                        "status" => "connected",
                        "session_id" => conn !== nothing ? conn.session_id : nothing,
                    )))
                    return nothing
                catch e
                    HTTP.setstatus(http, 500)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("error" => sprint(showerror, e))))
                    return nothing
                end
            end

            # Handle GET requests on MCP endpoint — open SSE stream per 2025-11-25 spec.
            # This stream delivers server-initiated notifications (e.g. tools/list_changed
            # when extensions register new tools) and keepalive comments.
            if req.method == "GET" && (
                req.target == "/mcp" ||
                req.target == "/" ||
                startswith(req.target, "/mcp?")
            )
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "text/event-stream")
                HTTP.setheader(http, "Cache-Control" => "no-cache")
                HTTP.setheader(http, "Connection" => "keep-alive")
                HTTP.startwrite(http)
                try
                    # Track which notifications this stream has already delivered
                    # so we don't re-send every second but also don't consume them
                    # (POST flush is the primary delivery path).
                    sent = Set{String}()
                    while isopen(http)
                        notifs = lock(_PENDING_NOTIFICATIONS_LOCK) do
                            collect(values(_PENDING_NOTIFICATIONS))
                        end
                        for notif in notifs
                            method = get(notif, "method", "")
                            method in sent && continue
                            push!(sent, method)
                            notif_json = JSON.json(notif)
                            write(http, "data: $(notif_json)\n\n")
                        end
                        flush(http)
                        sleep(1)
                    end
                catch
                end
                return nothing
            end

            # Handle DELETE requests - return 405 per Streamable HTTP spec
            if req.method == "DELETE"
                HTTP.setstatus(http, 405)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.setheader(http, "Allow" => "GET, POST")
                HTTP.startwrite(http)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => nothing,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Method Not Allowed - session termination via DELETE not supported",
                    ),
                )
                write(http, JSON.json(error_response))
                return nothing
            end

            # MCP-Protocol-Version header validation — 2025-11-25 spec requirement.
            # If the header is present it must name a supported protocol version.
            let ver = HTTP.header(req, "MCP-Protocol-Version", "")
                if !isempty(ver) && ver ∉ ("2025-06-18", "2025-03-26", "2025-11-25", "2025-11-05", "2024-11-05")
                    HTTP.setstatus(http, 400)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict(
                        "jsonrpc" => "2.0",
                        "id" => nothing,
                        "error" => Dict(
                            "code" => -32600,
                            "message" => "Unsupported MCP-Protocol-Version: $ver",
                        ),
                    )))
                    return nothing
                end
            end

            if isempty(body)
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 0,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - empty body",
                    ),
                )
                write(http, JSON.json(error_response))
                return nothing
            end

            # Session lookup/creation for multi-session support
            session_id = extract_mcp_session_id(req)

            # Parse request to check if it's an initialize
            parsed_request = try
                JSON.parse(body; dicttype = Dict{String,Any})
            catch
                nothing
            end

            is_initialize =
                parsed_request !== nothing &&
                get(parsed_request, "method", "") == "initialize"

            # Get or create session
            session, is_new_session = get_or_create_session(session_id, is_initialize)

            # Update activity timestamp so the reaper doesn't kill active sessions
            if session !== nothing
                Session.update_activity!(session)
            end

            # For non-initialize requests without a valid session, return 404 per
            # MCP Streamable HTTP spec — signals the client to re-initialize.
            if !is_initialize && session === nothing
                HTTP.setstatus(http, 404)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" =>
                        parsed_request !== nothing ? get(parsed_request, "id", 0) : 0,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Session not found. Send initialize request to start a new session.",
                    ),
                )
                write(http, JSON.json(error_response))
                return nothing
            end

            # ── SSE Progress for gate-mode tool calls ───────────────────
            # When running in gate mode (TUI server), long-running tool calls
            # that execute code via the gate can stream progress notifications
            # back to the MCP client as SSE events, preventing HTTP timeouts.
            if GATE_MODE[] &&
               parsed_request !== nothing &&
               get(parsed_request, "method", "") == "tools/call"

                tool_name_str = get(get(parsed_request, "params", Dict()), "name", "")
                # Tools that execute via gate and may run long
                gate_exec_tools =
                    Set(["ex", "run_tests", "profile_code", "lint_package", "stress_test"])

                # Session tools (namespaced: "prefix.toolname") also use SSE streaming
                is_session_tool = occursin('.', tool_name_str)

                if tool_name_str in gate_exec_tools || is_session_tool
                    return _handle_gate_tool_sse(
                        http,
                        parsed_request,
                        tools_dict,
                        name_to_id,
                        session,
                    )
                end
            end

            # All other requests go to create_handler
            req_with_body = HTTP.Request(req.method, req.target, req.headers, body)
            handler = create_handler(tools_dict, name_to_id, port, security_config, session)
            response = handler(req_with_body)

            # Check for pending notifications (e.g. tools/list_changed from extensions).
            # If any are queued, upgrade this response to SSE so we can send both
            # the notifications and the JSON-RPC result as separate events.
            pending = _take_notifications!()

            if !isempty(pending)
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "text/event-stream")
                HTTP.setheader(http, "Cache-Control" => "no-cache")
                HTTP.setheader(http, "Mcp-Session-Id" => session !== nothing ? session.id : "")
                HTTP.startwrite(http)
                for notif in pending
                    notif_json = JSON.json(notif)
                    method = get(notif, "method", "")
                    _push_log!(:info, "SSE notification flush: $method")
                    write(http, "data: $(notif_json)\n\n")
                end
                # Send the actual response as the final event
                response_json = String(response.body)
                write(http, "data: $(response_json)\n\n")
                flush(http)
            else
                HTTP.setstatus(http, response.status)
                for (name, value) in response.headers
                    HTTP.setheader(http, name => value)
                end
                HTTP.startwrite(http)
                # HTTP 2.0 Response.body is a BytesBody, not a Vector{UInt8} — the
                # Stream `write` needs a String. Skip empty bodies: a zero-length
                # chunked write emits a premature terminator, corrupting the next
                # response on a kept-alive connection (e.g. 202 notification acks).
                let body_str = String(response.body)
                    isempty(body_str) || write(http, body_str)
                end
            end
            return nothing

        catch e
            # Client disconnected — no response possible, no need to log
            e isa Base.IOError && return nothing

            _push_log!(:error, "MCP handler error: $(sprint(showerror, e))")

            # Attempt a 500 JSON-RPC error response.  Wrap in its own try/catch
            # because startwrite throws if the response was already started
            # (e.g. after SSE headers were sent) or if the socket closed.
            try
                HTTP.setstatus(http, 500)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)

                request_id = try
                    parsed = JSON.parse(body; dicttype = Dict{String,Any})
                    get(parsed, :id, 0)
                catch
                    0
                end

                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request_id,
                    "error" => Dict("code" => -32603, "message" => "Internal error: $e"),
                )
                write(http, JSON.json(error_response))
            catch
                # Response already started or connection closed — nothing to do
            end
            return nothing
        end
    end

    # HTTP 2.0 drives the Stream handler via `listen!` (`serve!` is now the
    # buffered Request->Response path). Binds to 127.0.0.1 (localhost-only).
    # Suppress background HTTP.jl info logging during startup; in TUI mode keep
    # the TUILogger so we don't write to raw stderr and corrupt the terminal.
    old_logger = global_logger()
    if !GATE_MODE[]
        global_logger(ConsoleLogger(stderr, Logging.Warn))
    end

    # port == 0 binds an OS-assigned ephemeral port (used by tests to avoid
    # fixed-port collisions); HTTP.port() reports the actual bound port.
    server = HTTP.listen!(hybrid_handler, port; listenany = (port == 0))
    if !GATE_MODE[]
        global_logger(old_logger)
    end
    bound_port = HTTP.port(server)

    # Server started successfully (session is now managed per-request via STANDALONE_SESSIONS)
    return MCPServer(session_uuid, bound_port, server, tools_dict, name_to_id, nothing)
end

function stop_mcp_server(server::MCPServer)
    # Close all sessions in the registry
    lock(STANDALONE_SESSIONS_LOCK) do
        for (sid, session) in STANDALONE_SESSIONS
            try
                close_session!(session)
            catch e
                @warn "Error closing session" session_id = sid exception = e
            end
        end
        empty!(STANDALONE_SESSIONS)
    end

    # Discard any notifications queued for this server's (now-gone) clients.
    _clear_notifications!()

    HTTP.forceclose(server.server)
end

# JSON-RPC method handlers + OAuth response builders, extracted verbatim from
# create_handler's dispatch ladder. Included last (functions resolve their
# module-level references at call time, so load position is immaterial).
include("mcp_rpc_methods.jl")

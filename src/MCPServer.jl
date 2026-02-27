using HTTP
using JSON
using Logging
using UUIDs
using Dates

# Import Session module
include("session.jl")
using .Session

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

"""Pending JSON-RPC notifications to flush on the next SSE response."""
const _PENDING_NOTIFICATIONS = Channel{Dict{String,Any}}(32)

"""
    register_sessions_changed_callback!(mgr::ConnectionManager)

Wire up `mgr.on_sessions_changed` so it enqueues a
`notifications/resources/list_changed` notification for the next SSE flush.
"""
function register_sessions_changed_callback!(mgr)
    mgr.on_sessions_changed =
        () -> begin
            try
                push!(
                    _PENDING_NOTIFICATIONS,
                    Dict{String,Any}(
                        "jsonrpc" => "2.0",
                        "method" => "notifications/resources/list_changed",
                    ),
                )
            catch
            end
        end
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
                    oauth_metadata = Dict(
                        "issuer" => "http://localhost:$port",
                        "authorization_endpoint" => "http://localhost:$port/oauth/authorize",
                        "token_endpoint" => "http://localhost:$port/oauth/token",
                        "registration_endpoint" => "http://localhost:$port/oauth/register",
                        "grant_types_supported" =>
                            ["authorization_code", "client_credentials"],
                        "response_types_supported" => ["code"],
                        "scopes_supported" => ["read", "write"],
                        "client_registration_types_supported" => ["dynamic"],
                        "code_challenge_methods_supported" => ["S256"],
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(oauth_metadata),
                    )
                else
                    # No OAuth in lax mode - return 404
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle dynamic client registration
            # Only support OAuth if security is configured (not in lax mode)
            if req.target == "/oauth/register" && req.method == "POST"
                if security_config !== nothing && security_config.mode != :lax
                    client_id = "claude-code-" * string(rand(UInt64), base = 16)
                    client_secret = string(rand(UInt128), base = 16)

                    registration_response = Dict(
                        "client_id" => client_id,
                        "client_secret" => client_secret,
                        "client_id_issued_at" => Int(floor(time())),
                        "grant_types" => ["authorization_code", "client_credentials"],
                        "response_types" => ["code"],
                        "redirect_uris" => [
                            "http://localhost:8080/callback",
                            "http://127.0.0.1:8080/callback",
                        ],
                        "token_endpoint_auth_method" => "client_secret_basic",
                        "scope" => "read write",
                    )
                    return HTTP.Response(
                        201,
                        ["Content-Type" => "application/json"],
                        JSON.json(registration_response),
                    )
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle authorization endpoint
            if startswith(req.target, "/oauth/authorize")
                if security_config !== nothing && security_config.mode != :lax
                    # For local development, auto-approve all requests
                    uri = HTTP.URI(req.target)
                    query_params = HTTP.queryparams(uri)
                    redirect_uri = get(query_params, "redirect_uri", "")
                    state = get(query_params, "state", "")

                    auth_code = "auth_" * string(rand(UInt64), base = 16)
                    redirect_url = "$redirect_uri?code=$auth_code&state=$state"

                    return HTTP.Response(302, ["Location" => redirect_url], "")
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle token endpoint
            if req.target == "/oauth/token" && req.method == "POST"
                if security_config !== nothing && security_config.mode != :lax
                    access_token = "access_" * string(rand(UInt128), base = 16)

                    token_response = Dict(
                        "access_token" => access_token,
                        "token_type" => "Bearer",
                        "expires_in" => 3600,
                        "scope" => "read write",
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(token_response),
                    )
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle GET requests - return 405 per Streamable HTTP spec (we don't support SSE streaming)
            if req.method == "GET"
                return HTTP.Response(
                    405,
                    ["Content-Type" => "application/json", "Allow" => "POST"],
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => nothing,
                            "error" => Dict(
                                "code" => -32600,
                                "message" => "Method Not Allowed - server does not support SSE streaming via GET",
                            ),
                        ),
                    ),
                )
            end

            # Handle DELETE requests - return 405 per Streamable HTTP spec
            if req.method == "DELETE"
                return HTTP.Response(
                    405,
                    ["Content-Type" => "application/json", "Allow" => "POST"],
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

            # Handle initialization
            if request["method"] == "initialize"
                params = get(request, "params", Dict{String,Any}())

                try
                    # Use session management if available
                    if session !== nothing
                        init_result = initialize_session!(session, params)
                    else
                        # Fallback without session management
                        init_result = Dict(
                            "protocolVersion" => "2025-11-25",
                            "capabilities" => Dict(
                                "tools" => Dict(),
                                "prompts" => Dict(),
                                "resources" => Dict(),
                                "logging" => Dict(),
                            ),
                            "serverInfo" =>
                                Dict("name" => "Kaimon", "version" => "0.4.0"),
                        )
                    end

                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "result" => init_result,
                    )

                    # Include Mcp-Session-Id header per Streamable HTTP transport spec
                    session_id = session !== nothing ? session.id : string(UUIDs.uuid4())
                    return HTTP.Response(
                        200,
                        [
                            "Content-Type" => "application/json",
                            "Mcp-Session-Id" => session_id,
                        ],
                        JSON.json(response),
                    )
                catch e
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32603,
                            "message" => "Initialize error: $(sprint(showerror, e))",
                        ),
                    )
                    return HTTP.Response(
                        500,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
            end

            # Handle initialized notification
            if request["method"] == "notifications/initialized"
                # This is a notification - return 202 Accepted with no body per Streamable HTTP spec
                # Mark session as fully initialized if it's in INITIALIZED state
                if session !== nothing && session.state == Session.INITIALIZED
                    @info "Session initialized" session_id = session.id
                end
                return HTTP.Response(202, [], "")
            end

            # Handle logging/setLevel request
            if request["method"] == "logging/setLevel"
                params = get(request, "params", Dict())
                level = get(params, "level", nothing)

                # Validate log level according to RFC 5424
                valid_levels = [
                    "debug",
                    "info",
                    "notice",
                    "warning",
                    "error",
                    "critical",
                    "alert",
                    "emergency",
                ]

                if level === nothing || !(level in valid_levels)
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Invalid params: level must be one of $(join(valid_levels, ", "))",
                        ),
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end

                # Map MCP log levels to Julia Logging levels
                level_map = Dict(
                    "debug" => Logging.Debug,
                    "info" => Logging.Info,
                    "notice" => Logging.Info,
                    "warning" => Logging.Warn,
                    "error" => Logging.Error,
                    "critical" => Logging.Error,
                    "alert" => Logging.Error,
                    "emergency" => Logging.Error,
                )

                julia_level = level_map[level]

                # Set the global log level
                try
                    global_logger(ConsoleLogger(stderr, julia_level))
                    @info "Log level set" level = level julia_level = julia_level

                    response =
                        Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => Dict())
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                catch e
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32603,
                            "message" => "Internal error: $(string(e))",
                        ),
                    )
                    return HTTP.Response(
                        500,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
            end

            # Handle session info request (custom extension)
            if request["method"] == "session/info"
                if session !== nothing
                    session_info = get_session_info(session)
                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "result" => session_info,
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                else
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" =>
                            Dict("code" => -32603, "message" => "No session available"),
                    )
                    return HTTP.Response(
                        500,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
            end

            # Handle tool listing
            if request["method"] == "tools/list"
                tool_list = [
                    Dict(
                        "name" => tool.name,
                        "description" => tool.description,
                        "inputSchema" => tool.parameters,
                    ) for tool in values(tools)
                ]

                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict("tools" => tool_list),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle resources/list request
            if request["method"] == "resources/list"
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict("resources" => _list_repl_resources()),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle resources/read request
            if request["method"] == "resources/read"
                uri = get(get(request, "params", Dict()), "uri", "")
                if isempty(uri)
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Missing required parameter: uri",
                        ),
                    )
                    return HTTP.Response(
                        400,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
                content_text = _read_repl_resource(uri)
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict(
                        "contents" => [
                            Dict(
                                "uri" => uri,
                                "mimeType" => "application/json",
                                "text" => content_text,
                            ),
                        ],
                    ),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle resources/templates/list request
            if request["method"] == "resources/templates/list"
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict("resourceTemplates" => []),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle prompts/list request
            if request["method"] == "prompts/list"
                prompts = get_prompts()
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict("prompts" => prompts),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle prompts/get request
            if request["method"] == "prompts/get"
                prompt_name = get(request["params"], "name", nothing)

                if prompt_name === nothing
                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Missing required parameter: name",
                        ),
                    )
                    return HTTP.Response(
                        400,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                end

                prompt_content = get_prompt(String(prompt_name))

                if prompt_content === nothing
                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Prompt not found: $prompt_name",
                        ),
                    )
                    return HTTP.Response(
                        404,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                end

                # Get prompt arguments if provided
                prompt_args = get(request["params"], "arguments", Dict())

                # Return the prompt with messages
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict(
                        "description" => "Learn how to use Kaimon effectively",
                        "messages" => [
                            Dict(
                                "role" => "user",
                                "content" => Dict(
                                    "type" => "text",
                                    "text" => prompt_content,
                                ),
                            ),
                        ],
                    ),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle tool calls
            if request["method"] == "tools/call"
                params = get(request, "params", nothing)
                if params === nothing || !haskey(params, "name")
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", 0),
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Invalid params: missing 'name' in tools/call request",
                        ),
                    )
                    return HTTP.Response(
                        400,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
                tool_name_str = params["name"]
                tool_id = get(name_to_id, tool_name_str, nothing)

                if tool_id !== nothing && haskey(tools, tool_id)
                    tool = tools[tool_id]
                    args = get(request["params"], "arguments", Dict())

                    # Validate parameters - collect all errors first
                    error_messages = String[]

                    # Check for unknown parameters first
                    if haskey(tool.parameters, "properties")
                        allowed_params = keys(tool.parameters["properties"])
                        unknown_params = String[]
                        for param in keys(args)
                            if !(param in allowed_params)
                                push!(unknown_params, param)
                            end
                        end

                        if !isempty(unknown_params)
                            allowed_list = join(sort(collect(allowed_params)), ", ")
                            push!(
                                error_messages,
                                "Unknown parameter(s): $(join(unknown_params, ", ")). Valid parameters are: $allowed_list",
                            )
                        end
                    end

                    # Check for missing required parameters
                    if haskey(tool.parameters, "required")
                        required_params = tool.parameters["required"]
                        missing_params = String[]
                        for param in required_params
                            if !haskey(args, param)
                                push!(missing_params, param)
                            end
                        end

                        if !isempty(missing_params)
                            push!(
                                error_messages,
                                "Missing required parameter(s): $(join(missing_params, ", "))",
                            )
                        end
                    end

                    # If there are any validation errors, return them all
                    if !isempty(error_messages)
                        error_response = Dict(
                            "jsonrpc" => "2.0",
                            "id" => request["id"],
                            "error" => Dict(
                                "code" => -32602,
                                "message" => join(error_messages, ". "),
                            ),
                        )
                        return HTTP.Response(
                            400,
                            ["Content-Type" => "application/json"],
                            JSON.json(error_response),
                        )
                    end

                    # Track timing for tools (except for those that show agent> prompts)
                    excluded_tools = [
                        "ex",
                        "search_methods",
                        "macro_expand",
                        "code_lowered",
                        "code_typed",
                    ]
                    show_timing = !(tool.name in excluded_tools)
                    # In gate/TUI mode, never print to stdout — log instead
                    tui_mode = GATE_MODE[]

                    # Show tool start indicator (stays on same line)
                    if show_timing && !tui_mode
                        print("🔧 ")
                        printstyled(tool.name, color = :light_blue)
                        flush(stdout)
                    end

                    # Always push activity events in TUI mode (including ex, etc.)
                    inflight_id = 0
                    if tui_mode
                        _push_activity!(:tool_start, tool.name, "", "")
                        sk = string(get(args, "ses", get(args, "session", "")))
                        inflight_id = _push_inflight_start!(tool.name, JSON.json(args), sk)
                    end

                    start_time = time()
                    tool_ok = true
                    time_str = ""

                    # Non-streaming mode (streaming handled in hybrid_handler)
                    # Use invokelatest to pick up Revise changes to tool handlers
                    result_text = try
                        Base.invokelatest(tool.handler, args)
                    catch
                        tool_ok = false
                        rethrow()
                    finally
                        elapsed = time() - start_time
                        # Format time nicely
                        time_str = if elapsed < 1.0
                            @sprintf("%.0fms", elapsed * 1000)
                        else
                            @sprintf("%.1fs", elapsed)
                        end
                        if tui_mode
                            # Always push activity events in TUI mode
                            _push_activity!(
                                :tool_done,
                                tool.name,
                                "",
                                time_str;
                                success = tool_ok,
                            )
                            _push_inflight_done!(inflight_id)
                            if show_timing
                                marker = tool_ok ? "✓" : "✗"
                                @info "$(tool.name) $marker ($time_str)"
                            end
                        elseif show_timing
                            print("\r\033[K🔧 ")
                            printstyled(tool.name, color = :light_blue)
                            if tool_ok
                                printstyled(" ✓ ", color = :green)
                            else
                                printstyled(" ✗ ", color = :red)
                            end
                            printstyled("($time_str)\n", color = :light_black)
                            flush(stdout)
                        end
                    end

                    # Push full tool result for TUI Activity inspection
                    if tui_mode
                        rt = string(result_text)
                        # Detect error strings returned without throwing
                        ok = tool_ok && !startswith(rt, "ERROR:")
                        # Extract session key from tool args (ses for ex, session for others)
                        sk = string(get(args, "ses", get(args, "session", "")))
                        _push_tool_result!(
                            ToolCallResult(
                                now(),
                                tool.name,
                                JSON.json(args),
                                rt,
                                time_str,
                                ok,
                                sk,
                            ),
                        )
                    end

                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "result" => Dict(
                            "content" =>
                                [Dict("type" => "text", "text" => result_text)],
                        ),
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                else
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Tool not found: $tool_name_str",
                        ),
                    )
                    return HTTP.Response(
                        404,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
            end

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
    # Write an SSE event helper (defined below) is not available yet, so
    # inline the flush here before the main send_sse_event closure.
    while isready(_PENDING_NOTIFICATIONS)
        notif = try
            take!(_PENDING_NOTIFICATIONS)
        catch
            break
        end
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
    function send_progress(message::String)
        step_counter[] += 1
        send_sse_event(
            Dict(
                "jsonrpc" => "2.0",
                "method" => "notifications/progress",
                "params" => Dict(
                    "progressToken" => progress_token,
                    "progress" => step_counter[],
                    "message" =>
                        length(message) > 200 ? first(message, 200) * "..." : message,
                ),
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
    inflight_id = _push_inflight_start!(tool.name, JSON.json(args), sk)
    _sse_inflight_id[] = inflight_id
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
            max_output = get(args, "max_output", 6000)
            ses = get(args, "ses", "")
            execute_via_gate_streaming(
                code;
                quiet = quiet,
                silent = silent,
                max_output = max_output,
                session = ses,
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

    # Push tool result for TUI Activity inspection
    elapsed = time() - start_time
    time_str =
        elapsed < 1.0 ? @sprintf("%.0fms", elapsed * 1000) : @sprintf("%.1fs", elapsed)
    rt = string(result_text)
    ok = tool_ok && !startswith(rt, "ERROR:")
    sk = string(get(args, "ses", get(args, "session", "")))
    _push_tool_result!(
        ToolCallResult(now(), tool.name, JSON.json(args), rt, time_str, ok, sk),
    )

    # Send final JSON-RPC result as last SSE event
    send_sse_event(
        Dict(
            "jsonrpc" => "2.0",
            "id" => request_id,
            "result" => Dict("content" => [Dict("type" => "text", "text" => result_text)]),
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
        req = http.message

        # CRITICAL: Read the request body FIRST before any response
        # HTTP.jl requires reading the full request before writing responses
        body = String(read(http))

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
                    write(http, agents_content)
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

            # Handle GET requests on MCP endpoint - return 405 per Streamable HTTP spec
            if req.method == "GET" && (
                req.target == "/mcp" ||
                req.target == "/" ||
                startswith(req.target, "/mcp?")
            )
                HTTP.setstatus(http, 405)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.setheader(http, "Allow" => "POST")
                HTTP.startwrite(http)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => nothing,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Method Not Allowed - server does not support SSE streaming via GET",
                    ),
                )
                write(http, JSON.json(error_response))
                return nothing
            end

            # Handle DELETE requests - return 405 per Streamable HTTP spec
            if req.method == "DELETE"
                HTTP.setstatus(http, 405)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.setheader(http, "Allow" => "POST")
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

            HTTP.setstatus(http, response.status)
            for (name, value) in response.headers
                HTTP.setheader(http, name => value)
            end
            HTTP.startwrite(http)
            write(http, response.body)
            return nothing

        catch e
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
            return nothing
        end
    end

    # Start server with stream=true to enable streaming responses
    # Temporarily suppress HTTP.jl's "Listening on" info message
    # In TUI mode, keep the TUILogger active (don't swap to ConsoleLogger
    # which would write to raw stderr and corrupt the terminal)
    old_logger = global_logger()
    if !GATE_MODE[]
        global_logger(ConsoleLogger(stderr, Logging.Warn))
    end

    server = HTTP.serve!(hybrid_handler, port; verbose = false, stream = true)
    if !GATE_MODE[]
        global_logger(old_logger)
    end

    # Server started successfully (session is now managed per-request via STANDALONE_SESSIONS)
    return MCPServer(session_uuid, port, server, tools_dict, name_to_id, nothing)
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

    HTTP.forceclose(server.server)
end

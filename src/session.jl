# ============================================================================
# Session Management Module
# ============================================================================
# 
# Implements MCP session lifecycle management according to the specification:
# - Session initialization with protocol version negotiation
# - Capability negotiation
# - Session state management (uninitialized, initializing, initialized, closed)
# - Proper cleanup on session end

module Session

using JSON
using Dates
using UUIDs

export MCPSession,
    SessionState,
    initialize_session!,
    close_session!,
    get_session_info,
    update_activity!,
    session_from_db

# Session states
@enum SessionState begin
    UNINITIALIZED  # Session created but not initialized
    INITIALIZING   # Initialize request received, processing
    INITIALIZED    # Successfully initialized and ready
    CLOSED         # Session has been closed
end

"""
    MCPSession

Represents an MCP protocol session with a client.

# Fields
- `id::String`: Unique session identifier (UUID)
- `state::SessionState`: Current session state
- `protocol_version::String`: Negotiated protocol version
- `client_info::Dict{String,Any}`: Client information from initialize
- `server_capabilities::Dict{String,Any}`: Server capabilities advertised to client
- `client_capabilities::Dict{String,Any}`: Client capabilities received during init
- `created_at::DateTime`: Session creation timestamp
- `initialized_at::Union{DateTime,Nothing}`: Session initialization timestamp
- `closed_at::Union{DateTime,Nothing}`: Session close timestamp
- `target_julia_session_id::Union{String,Nothing}`: Target Julia session ID for proxy routing (proxy only)
- `last_activity::DateTime`: Last time this session was active
"""
mutable struct MCPSession
    id::String
    state::SessionState
    protocol_version::String
    client_info::Dict{String,Any}
    server_capabilities::Dict{String,Any}
    client_capabilities::Dict{String,Any}
    created_at::DateTime
    initialized_at::Union{DateTime,Nothing}
    closed_at::Union{DateTime,Nothing}
    target_julia_session_id::Union{String,Nothing}
    last_activity::DateTime
end

"""
    MCPSession(; target_julia_session_id::Union{String,Nothing}=nothing) -> MCPSession

Create a new uninitialized MCP session.

# Arguments
- `target_julia_session_id::Union{String,Nothing}=nothing`: Optional target Julia session ID for proxy routing
"""
function MCPSession(; target_julia_session_id::Union{String,Nothing} = nothing)
    now_time = now()
    return MCPSession(
        string(uuid4()),                    # id
        UNINITIALIZED,                      # state
        "",                                 # protocol_version
        Dict{String,Any}(),                 # client_info
        get_server_capabilities(),          # server_capabilities
        Dict{String,Any}(),                 # client_capabilities
        now_time,                           # created_at
        nothing,                            # initialized_at
        nothing,                            # closed_at
        target_julia_session_id,            # target_julia_session_id
        now_time,                           # last_activity
    )
end

# Define JSON serialization for MCPSession (struct → JSON)
# This hook is used by JSON.json() to convert MCPSession to a Dict
# Timestamps are serialized in ISO 8601 format (yyyy-mm-ddTHH:MM:SS)
JSON.lower(session::MCPSession) = Dict(
    "id" => session.id,
    "state" => string(session.state),
    "protocol_version" => session.protocol_version,
    "client_info" => session.client_info,
    "server_capabilities" => session.server_capabilities,
    "client_capabilities" => session.client_capabilities,
    "created_at" => Dates.format(session.created_at, "yyyy-mm-dd\\THH:MM:SS"),
    "initialized_at" =>
        session.initialized_at === nothing ? nothing :
        Dates.format(session.initialized_at, "yyyy-mm-dd\\THH:MM:SS"),
    "closed_at" =>
        session.closed_at === nothing ? nothing :
        Dates.format(session.closed_at, "yyyy-mm-dd\\THH:MM:SS"),
    "target_julia_session_id" => session.target_julia_session_id,
    "last_activity" => Dates.format(session.last_activity, "yyyy-mm-dd\\THH:MM:SS"),
)

"""
    session_from_db(db_row::NamedTuple) -> MCPSession

Reconstruct an MCPSession from a database row.
The database row should have: id, state, session_data (JSON), start_time, last_activity, target_julia_session_id.
"""
function session_from_db(db_row)
    # Parse the session_data JSON blob
    session_data =
        ismissing(db_row.session_data) ? Dict{String,Any}() :
        JSON.parse(db_row.session_data)

    # Parse state enum
    state_str = ismissing(db_row.state) ? "UNINITIALIZED" : String(db_row.state)
    state = if state_str == "UNINITIALIZED"
        UNINITIALIZED
    elseif state_str == "INITIALIZING"
        INITIALIZING
    elseif state_str == "INITIALIZED"
        INITIALIZED
    elseif state_str == "CLOSED"
        CLOSED
    else
        UNINITIALIZED
    end

    # Parse timestamps - database format is "yyyy-mm-dd HH:MM:SS.sss"
    db_format = Dates.DateFormat("yyyy-mm-dd HH:MM:SS.sss")
    created_at = Dates.DateTime(db_row.start_time, db_format)
    last_activity = Dates.DateTime(db_row.last_activity, db_format)

    # JSON serialized timestamps use ISO format
    iso_format = Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS")
    initialized_at =
        haskey(session_data, "initialized_at") &&
        session_data["initialized_at"] !== nothing ?
        Dates.DateTime(session_data["initialized_at"], iso_format) : nothing
    closed_at =
        haskey(session_data, "closed_at") && session_data["closed_at"] !== nothing ?
        Dates.DateTime(session_data["closed_at"], iso_format) : nothing

    # Extract target
    target_julia_session_id =
        ismissing(db_row.target_julia_session_id) ? nothing : db_row.target_julia_session_id

    # Reconstruct the session
    return MCPSession(
        String(db_row.id),
        state,
        get(session_data, "protocol_version", ""),
        get(session_data, "client_info", Dict{String,Any}()),
        get(session_data, "server_capabilities", get_server_capabilities()),
        get(session_data, "client_capabilities", Dict{String,Any}()),
        created_at,
        initialized_at,
        closed_at,
        target_julia_session_id,
        last_activity,
    )
end

"""
    get_server_capabilities() -> Dict{String,Any}

Return the server's capabilities to advertise to clients.
"""
function get_server_capabilities()
    return Dict{String,Any}(
        "tools" => Dict{String,Any}(
            "listChanged" => true,  # We support tools/list_changed notifications
        ),
        "prompts" => Dict{String,Any}(),  # We support prompts
        "resources" => Dict{String,Any}("listChanged" => true),  # We support resources
        "logging" => Dict{String,Any}(),  # We support logging
    )
end

"""
    initialize_session!(session::MCPSession, params::Dict) -> Dict{String,Any}

Initialize a session with protocol version and capability negotiation.

# Arguments
- `session::MCPSession`: The session to initialize
- `params::Dict`: Initialize request parameters containing:
  - `protocolVersion`: Required protocol version
  - `capabilities`: Client capabilities
  - `clientInfo`: Client information (name, version)

# Returns
Dictionary containing initialization response with:
- `protocolVersion`: Server's protocol version
- `capabilities`: Server capabilities
- `serverInfo`: Server information

# Throws
- `ErrorException`: If session is not in UNINITIALIZED state
- `ErrorException`: If protocol version is not supported
"""
function initialize_session!(session::MCPSession, params::Dict)
    # Validate session state
    if session.state != UNINITIALIZED
        error("Session already initialized or closed")
    end

    session.state = INITIALIZING

    # Extract and validate protocol version
    protocol_version = get(params, "protocolVersion", nothing)
    if protocol_version === nothing
        session.state = UNINITIALIZED
        error("Missing required parameter: protocolVersion")
    end

    # Validate protocol version (supported and future-friendly)
    supported_versions = ["2024-11-05", "2025-06-18", "2025-11-25"]
    fmt = Dates.DateFormat("yyyy-mm-dd")

    # Helper to parse date strings safely
    date_or_nothing(s) =
        try
            Dates.Date(s, fmt)
        catch
            nothing
        end

    parsed_supported = filter(!isnothing, date_or_nothing.(supported_versions))
    max_supported_date = maximum(parsed_supported)

    parsed_requested = date_or_nothing(String(protocol_version))

    if protocol_version in supported_versions
        supported_version = protocol_version
    elseif parsed_requested !== nothing && parsed_requested > max_supported_date
        # Optimistically accept newer client versions but reply with our latest supported
        supported_version = Dates.format(max_supported_date, fmt)
        @warn "Client requested newer protocol version; using latest supported" requested =
            protocol_version supported = supported_version
    else
        session.state = UNINITIALIZED
        error(
            "Unsupported protocol version: $protocol_version. Server supports: $(join(supported_versions, ", "))",
        )
    end

    # Store client capabilities
    session.client_capabilities = get(params, "capabilities", Dict{String,Any}())

    # Store client info
    session.client_info = get(params, "clientInfo", Dict{String,Any}())

    # Mark session as initialized
    session.protocol_version = protocol_version
    session.state = INITIALIZED
    session.initialized_at = now()

    # Return initialization response
    return Dict{String,Any}(
        "protocolVersion" => supported_version,
        "capabilities" => session.server_capabilities,
        "serverInfo" => Dict{String,Any}(
            "name" => "Kaimon",
            "version" => get_version(),
            "description" => "Julia REPL with powerful code discovery tools: 🔍 Semantic search (find code by meaning, not keywords), 🔬 Deep type introspection (inspect types/fields/hierarchy), 🎯 Method search (find function implementations), 📚 Symbol discovery (list available names/exports). Use these instead of grep/shell commands for Julia code exploration.",
        ),
    )
end

"""
    close_session!(session::MCPSession)

Close a session and clean up resources.
"""
function close_session!(session::MCPSession)
    if session.state == CLOSED
        @warn "Session already closed" session_id = session.id
        return
    end

    session.state = CLOSED
    session.closed_at = now()
    @info "Session closed" session_id = session.id duration =
        session.closed_at - session.created_at
end

"""
    get_session_info(session::MCPSession) -> Dict{String,Any}

Get information about the current session.
"""
function get_session_info(session::MCPSession)
    return Dict{String,Any}(
        "id" => session.id,
        "state" => string(session.state),
        "protocol_version" => session.protocol_version,
        "client_info" => session.client_info,
        "created_at" => session.created_at,
        "initialized_at" => session.initialized_at,
        "closed_at" => session.closed_at,
        "uptime" =>
            session.initialized_at === nothing ? nothing :
            (
                session.closed_at === nothing ? now() - session.initialized_at :
                session.closed_at - session.initialized_at
            ),
    )
end

"""
    update_activity!(session::MCPSession)

Update the last activity timestamp for a session.
"""
function update_activity!(session::MCPSession)
    session.last_activity = now()
end

"""
    get_version() -> String

Get the Kaimon version string.
"""
function get_version()
    # Try to get version from parent module if available
    if isdefined(Main, :Kaimon) && isdefined(Main.Kaimon, :version_info)
        return Main.Kaimon.version_info()
    end
    return "0.4.0"
end

end # module Session

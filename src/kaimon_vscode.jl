# ─────────────────────────────────────────────────────────────────────────────
# Kaimon · VS Code response bridge, nonces, editor URIs  (relocated from Kaimon.jl; part of the Kaimon module)
# ─────────────────────────────────────────────────────────────────────────────


# ============================================================================
# VS Code Response Storage for Bidirectional Communication
# ============================================================================

# Global dictionary to store VS Code command responses
# Key: request_id (String), Value: (result, error, timestamp)
const VSCODE_RESPONSES = Dict{String,Tuple{Any,Union{Nothing,String},Float64}}()

# Lock for thread-safe access to response dictionary
const VSCODE_RESPONSE_LOCK = ReentrantLock()

# Global dictionary to store single-use nonces for VS Code callbacks
# Key: request_id (String), Value: (nonce, timestamp)
const VSCODE_NONCES = Dict{String,Tuple{String,Float64}}()

# Lock for thread-safe access to nonces dictionary
const VSCODE_NONCE_LOCK = ReentrantLock()

# Lock for serializing REPL-like execution.
# `execute_repllike` currently uses stdout/stderr redirection which is process-global;
# concurrent calls can collide and leave the session in a bad state.
const EXEC_REPLLIKE_LOCK = ReentrantLock()


"""
    store_vscode_response(request_id::String, result, error::Union{Nothing,String})

Store a response from VS Code for later retrieval.
Thread-safe storage using VSCODE_RESPONSE_LOCK.
"""
function store_vscode_response(request_id::String, result, error::Union{Nothing,String})
    lock(VSCODE_RESPONSE_LOCK) do
        VSCODE_RESPONSES[request_id] = (result, error, time())
    end
end

"""
    retrieve_vscode_response(request_id::String; timeout::Float64=5.0, poll_interval::Float64=0.1)

Retrieve a stored VS Code response, waiting up to `timeout` seconds.
Returns (result, error) tuple or throws TimeoutError.
Automatically cleans up the stored response after retrieval.
"""
function retrieve_vscode_response(
    request_id::String;
    timeout::Float64 = 5.0,
    poll_interval::Float64 = 0.1,
)
    start_time = time()

    while (time() - start_time) < timeout
        response = lock(VSCODE_RESPONSE_LOCK) do
            get(VSCODE_RESPONSES, request_id, nothing)
        end

        if response !== nothing
            # Clean up the stored response
            lock(VSCODE_RESPONSE_LOCK) do
                delete!(VSCODE_RESPONSES, request_id)
            end
            return (response[1], response[2])  # (result, error)
        end

        sleep(poll_interval)
    end

    error("Timeout waiting for VS Code response (request_id: $request_id)")
end

"""
    cleanup_old_vscode_responses(max_age::Float64=60.0)

Remove responses older than `max_age` seconds to prevent memory leaks.
Should be called periodically.
"""
function cleanup_old_vscode_responses(max_age::Float64 = 60.0)
    current_time = time()
    lock(VSCODE_RESPONSE_LOCK) do
        for (request_id, (_, _, timestamp)) in collect(VSCODE_RESPONSES)
            if (current_time - timestamp) > max_age
                delete!(VSCODE_RESPONSES, request_id)
            end
        end
    end
end

# ============================================================================
# Nonce Management for VS Code Authentication
# ============================================================================

"""
    generate_nonce()

Generate a cryptographically secure random nonce for single-use authentication.
Returns a 32-character hex string.
"""
function generate_nonce()
    return bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
end

"""
    store_nonce(request_id::String, nonce::String)

Store a nonce for a specific request ID. Thread-safe.
"""
function store_nonce(request_id::String, nonce::String)
    lock(VSCODE_NONCE_LOCK) do
        VSCODE_NONCES[request_id] = (nonce, time())
    end
end

"""
    validate_and_consume_nonce(request_id::String, nonce::String)::Bool

Validate that a nonce matches the stored nonce for a request ID, then consume it (delete it).
Returns true if valid, false otherwise. Thread-safe.
"""
function validate_and_consume_nonce(request_id::String, nonce::String)::Bool
    lock(VSCODE_NONCE_LOCK) do
        stored = get(VSCODE_NONCES, request_id, nothing)
        if stored === nothing
            return false
        end

        stored_nonce, _ = stored
        # Delete immediately to prevent reuse
        delete!(VSCODE_NONCES, request_id)

        return stored_nonce == nonce
    end
end

"""
    cleanup_old_nonces(max_age::Float64=60.0)

Remove nonces older than `max_age` seconds to prevent memory leaks.
Should be called periodically.
"""
function cleanup_old_nonces(max_age::Float64 = 60.0)
    current_time = time()
    lock(VSCODE_NONCE_LOCK) do
        for (request_id, (_, timestamp)) in collect(VSCODE_NONCES)
            if (current_time - timestamp) > max_age
                delete!(VSCODE_NONCES, request_id)
            end
        end
    end
end

# ============================================================================
# VS Code URI Helpers
# ============================================================================

# Supported editors for file:line clickable links
const EDITOR_OPTIONS = ["vscode", "cursor", "zed", "windsurf"]

"""
    editor_file_url(path::String; line::Int=0, col::Int=0) -> String

Build a clickable URI for the configured editor. Returns `""` if path is empty.
Reads the editor setting from the global config (`~/.config/kaimon/config.json`).

Supported editors: vscode, cursor, zed, windsurf — all use `<scheme>://file/path:line:col`.
"""
function editor_file_url(path::String; line::Int=0, col::Int=0)::String
    isempty(path) && return ""
    cfg = load_global_config()
    editor = cfg !== nothing ? cfg.editor : "vscode"
    uri = "$editor://file$path"
    if line > 0
        uri *= ":$line"
        col > 0 && (uri *= ":$col")
    end
    return uri
end

# Helper function to trigger editor commands via URI
function trigger_vscode_uri(uri::String)
    if Sys.isapple()
        run(`open $uri`)
    elseif Sys.islinux()
        run(`xdg-open $uri`)
    elseif Sys.iswindows()
        run(`cmd /c start $uri`)
    else
        error("Unsupported operating system")
    end
end

# Helper function to build VS Code command URI
function build_vscode_uri(
    command::String;
    args::Union{Nothing,String} = nothing,
    request_id::Union{Nothing,String} = nothing,
    mcp_port::Int = 3000,
    nonce::Union{Nothing,String} = nothing,
    publisher::String = "Kaimon",
    name::String = "vscode-remote-control",
)
    uri = "vscode://$(publisher).$(name)?cmd=$(command)"
    if args !== nothing
        uri *= "&args=$(args)"
    end
    if request_id !== nothing
        uri *= "&request_id=$(request_id)"
    end
    if mcp_port != 3000
        uri *= "&mcp_port=$(mcp_port)"
    end
    if nonce !== nothing
        uri *= "&nonce=$(HTTP.URIs.escapeuri(nonce))"
    end
    return uri
end


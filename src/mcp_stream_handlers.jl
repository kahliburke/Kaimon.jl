# ============================================================================
# Streaming (HTTP.Stream) request helpers for _hybrid_handler_impl
#
# Extracted from _hybrid_handler_impl's origin/security preamble and its
# static-endpoint branches. Each helper writes its response directly to the
# `http` stream and returns `true` when it handled the request (the caller then
# `return nothing`), or `false` to fall through to the next stage. Logic is
# byte-identical to the original branches — only each branch's terminal
# `return nothing` became `return true`, with a trailing `return false` for the
# "not handled / not matched" fall-through. Module-level references
# (is_trusted_origin, extract_api_key, validate_api_key, get_client_ip,
# validate_ip, Kaimon.*, _PENDING_NOTIFICATIONS*) resolve at call time.
# ============================================================================

function _stream_security_gate(http, req, body, security_config)
        # Origin validation — MCP 2025-11-25 Streamable HTTP spec requirement.
        # If an Origin header is present it must be a trusted local origin.
        # Absent Origin is allowed (non-browser clients don't send it).
        let origin = HTTP.header(req, "Origin", "")
            if !isempty(origin)
                if !is_trusted_origin(origin)
                    @warn "Auth denied: untrusted Origin (403)" origin target = req.target
                    record_auth_refusal!(403, "untrusted Origin", get_client_ip(req))
                    HTTP.setstatus(http, 403)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("error" => "Forbidden: untrusted Origin")))
                    return true
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
                        record_auth_refusal!(401, "invalid or expired VS Code nonce", get_client_ip(req))
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(
                                Dict("error" => "Unauthorized: Invalid or expired nonce"),
                            ),
                        )
                        return true
                    end
                elseif security_config.mode != :lax
                    # No valid nonce, fall back to API key validation for vscode-response
                    if nonce === nothing
                        record_auth_refusal!(401, "missing API key", get_client_ip(req))
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
                        return true
                    end

                    if !validate_api_key(String(nonce), security_config)
                        record_auth_refusal!(401, "invalid API key", get_client_ip(req))
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(Dict("error" => "Unauthorized: Invalid API key")),
                        )
                        return true
                    end

                    # If using API key (not nonce), still need to validate IP
                    client_ip = get_client_ip(req)
                    if !validate_ip(client_ip, security_config)
                        record_auth_refusal!(403, "IP not allowed", get_client_ip(req))
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
                        return true
                    end
                end
            elseif !nonce_validated
                # For non-vscode-response endpoints, use standard API key validation
                api_key = extract_api_key(req)
                if api_key === nothing && security_config.mode != :lax
                    @warn "Auth denied: missing API key (401)" client_ip =
                        get_client_ip(req) method = req.method target = req.target
                    # RFC 6750 challenge: a bare Bearer scheme (we run no OAuth
                    # server, so no resource_metadata pointer — the credential is
                    # the API key), and a string-typed `error` a strict OAuth
                    # client can parse instead of a JSON-RPC error object.
                    record_auth_refusal!(401, "missing API key", get_client_ip(req))
                    HTTP.setstatus(http, 401)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.setheader(http, "WWW-Authenticate" => "Bearer realm=\"kaimon\"")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "error" => "invalid_token",
                                "error_description" => "Missing API key in Authorization header",
                            ),
                        ),
                    )
                    return true
                end

                # Only a configured API key is accepted, or the token of a live Kaimon-owned agent
                # (minted at spawn, never handed to anything else). No self-provisioned tokens:
                # those would bypass strict/relaxed mode.
                is_agent = api_key !== nothing && !isempty(agent_for_token(api_key))
                if !is_agent && !validate_api_key(String(something(api_key, "")), security_config)
                    @warn "Auth denied: invalid API key (401)" client_ip =
                        get_client_ip(req) method = req.method target = req.target
                    record_auth_refusal!(401, "invalid API key or agent token", get_client_ip(req))
                    HTTP.setstatus(http, 401)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.setheader(http, "WWW-Authenticate" => "Bearer realm=\"kaimon\"")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict(
                        "error" => "invalid_token",
                        "error_description" => "Invalid API key",
                    )))
                    return true
                end

                # Validate IP address
                client_ip = get_client_ip(req)
                if !validate_ip(client_ip, security_config)
                    @warn "Auth denied: IP not allowed (403)" client_ip method =
                        req.method target = req.target
                    record_auth_refusal!(403, "IP not allowed", get_client_ip(req))
                    HTTP.setstatus(http, 403)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict("error" => "Forbidden: IP address $client_ip not allowed"),
                        ),
                    )
                    return true
                end
            end
        end
    return false
end

function _stream_agents_md(http, req)
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
                    return true
                else
                    HTTP.setstatus(http, 404)
                    HTTP.setheader(http, "Content-Type" => "text/plain")
                    HTTP.startwrite(http)
                    write(http, "AGENTS.md not found in project root")
                    return true
                end
            end
    return false
end

# Soft anti-shell-grep nudge endpoint. Agents' PreToolUse(Bash) hooks POST their tool-call
# JSON here (one-line curl, no per-machine script); we return a decision that ALLOWS the
# command but injects guidance toward grep_code/search_code when it's a code-search, else an
# empty 200. Pure nudge — never blocks. Handled before the security gate so the hook curl
# needs no credentials (localhost, canned response, no side effects). Logic lives in
# Kaimon `_hook_nudge_payload` (hot-reloadable, one source of truth, per-agent via ?agent=).
function _stream_hook_nudge(http, req, body)
    if req.method == "POST" && startswith(req.target, "/hook/nudge")
        payload = try
            parentmodule(@__MODULE__)._hook_nudge_payload(req.target, body)
        catch
            ""
        end
        HTTP.setstatus(http, 200)
        HTTP.setheader(http, "Content-Type" => "application/json")
        HTTP.startwrite(http)
        isempty(payload) || write(http, payload)
        return true
    end
    return false
end

# Tool-policy questions from an ACP agent's bridge plugin. Runs before the security
# gate because the plugin holds no API key; its credential is instead the per-agent
# bridge token minted at spawn, which also makes every decision attributable. An
# unrecognised or missing token is refused rather than ignored — this endpoint says
# yes or no to tool execution, so failing open would hand policy to anything that
# can reach the port.
function _stream_agent_bridge(http, req, body)
    (req.method == "POST" && startswith(req.target, "/agent/permission")) || return false
    K = parentmodule(@__MODULE__)
    verdict = try
        aid = HTTP.header(req, "X-Kaimon-Agent-Id", "")
        tok = HTTP.header(req, "X-Kaimon-Bridge-Token", "")
        if isempty(aid) || isempty(tok) || !K.secrets_equal(tok, K.agent_token(aid))
            Dict("allow" => false, "why" => "bad bridge credential")
        else
            payload = JSON.parse(body)
            K.acp_bridge_decide(aid, String(get(payload, "tool", "")), get(payload, "args", nothing))
        end
    catch
        Dict("allow" => false, "why" => "bridge error")
    end
    HTTP.setstatus(http, 200)
    HTTP.setheader(http, "Content-Type" => "application/json")
    HTTP.startwrite(http)
    write(http, JSON.json(verdict))
    return true
end

# We intentionally run NO OAuth authorization server (see mcp_rpc_methods.jl — an
# anonymous localhost auto-mint would bypass strict/relaxed mode). Serve a clean
# 404 for OAuth discovery/endpoint paths BEFORE the security gate, so a client
# probing for OAuth gets the RFC 8414 "no metadata" signal and falls back to the
# API-key bearer it was configured with — rather than being 401'd on discovery or
# crashing on a malformed response. The credential is the API key (security gate).
function _stream_oauth(http, req)
    _is_public_oauth_path(req.target) || return false
    # Body is JSON shaped like an OAuth error (string `error`), NOT plain text:
    # some clients (Claude Code) parse the discovery/endpoint response body as
    # JSON even on a 404, so a "Not Found" string makes them throw a JSON parse
    # error when a user manually triggers "Authenticate". Valid JSON with a
    # string `error` lets that OAuth attempt fail cleanly instead of crashing.
    HTTP.setstatus(http, 404)
    HTTP.setheader(http, "Content-Type" => "application/json")
    HTTP.startwrite(http)
    write(http, JSON.json(Dict(
        "error" => "oauth_not_supported",
        "error_description" => "This server does not provide OAuth; authenticate with a configured API key.",
    )))
    return true
end

function _stream_vscode_response(http, req, body)
            if req.target == "/vscode-response" && req.method == "POST"
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)

                    if request_id === nothing
                        HTTP.setstatus(http, 400)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(http, JSON.json(Dict("error" => "Missing request_id")))
                        return true
                    end

                    result = get(response_data, "result", nothing)
                    error = get(response_data, "error", nothing)

                    # Store the response
                    Kaimon.store_vscode_response(string(request_id), result, error)

                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("status" => "ok")))
                    return true
                catch e
                    HTTP.setstatus(http, 500)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(Dict("error" => "Failed to process response: $e")),
                    )
                    return true
                end
            end
    return false
end

function _stream_connect_tcp(http, req, body)
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
                        return true
                    end

                    port_int = Int(port)
                    if port_int < 1 || port_int > 65535
                        HTTP.setstatus(http, 400)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(http, JSON.json(Dict("error" => "port must be between 1 and 65535")))
                        return true
                    end

                    conn = Kaimon.connect_tcp_to_active_manager(string(host), port_int; name=string(name), server_key=server_key)

                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict(
                        "status" => "connected",
                        "session_id" => conn !== nothing ? conn.session_id : nothing,
                    )))
                    return true
                catch e
                    HTTP.setstatus(http, 500)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("error" => sprint(showerror, e))))
                    return true
                end
            end
    return false
end

# Seconds of silence after which the GET stream writes an SSE comment. HTTP.jl's
# server-side `isopen(stream)` stays true after the peer disconnects, so a write is
# the only way to notice a client that has gone; without one the loop — and its
# socket — lives for the rest of the server's lifetime.
const _SSE_KEEPALIVE_SECS = Ref(15.0)

function _stream_get_sse(http, req)
            if req.method == "GET" && (
                req.target == "/mcp" ||
                req.target == "/" ||
                startswith(req.target, "/mcp?")
            )
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "text/event-stream")
                HTTP.setheader(http, "Cache-Control" => "no-cache")
                HTTP.setheader(http, "Connection" => "keep-alive")
                # This GET stream is the client's standalone receive channel. Bind it
                # to the session so we can target it for server→client requests
                # (roots/list), and proactively capture the agent's workspace roots to
                # auto-bind it to its gate session.
                sid = try; something(extract_mcp_session_id(req), ""); catch; ""; end
                HTTP.startwrite(http)
                outbox = isempty(sid) ? nothing : _register_session_stream!(sid)
                if !isempty(sid)
                    @async try; _capture_roots!(sid); catch; end
                end
                try
                    last_write = time()
                    while isopen(http)
                        # A newer GET stream for this session closed our outbox when it
                        # registered its own; this one has been replaced, so end it.
                        outbox === nothing || isopen(outbox) || break
                        wrote = false
                        # Targeted server→client messages (e.g. roots/list) first.
                        if outbox !== nothing
                            while isready(outbox)
                                write(http, "data: $(JSON.json(take!(outbox)))\n\n")
                                wrote = true
                            end
                        end
                        # Notifications newer than this stream's cursor. The cursor
                        # advances past what we deliver, so a re-queued notification
                        # (tools/list_changed on every extension restart) comes through
                        # as a fresh, higher seq instead of being suppressed for the
                        # stream's whole life. It is this stream's OWN cursor, not the
                        # POST channel's: a write landing here does not mean the client
                        # read it, so it must not stop the next POST from carrying it.
                        for notif in _flush_notifications_for_session!(sid; channel = :stream)
                            _push_log!(:info, "SSE notification flush (GET stream): $(get(notif, "method", ""))")
                            write(http, "data: $(JSON.json(notif))\n\n")
                            wrote = true
                        end
                        if !wrote && time() - last_write >= _SSE_KEEPALIVE_SECS[]
                            write(http, ": keepalive\n\n")
                            wrote = true
                        end
                        if wrote
                            flush(http)
                            last_write = time()
                        end
                        sleep(1)
                    end
                catch e
                    # The client going away ends the stream too; say which it was, since a
                    # write that failed took notifications with it.
                    _push_log!(:info, "GET receive stream ended: $(sprint(showerror, e))")
                finally
                    outbox === nothing || _unregister_session_stream!(sid, outbox)
                end
                return true
            end
    return false
end

function _stream_delete(http, req)
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
                return true
            end
    return false
end

# The protocol versions this server speaks. All of them start with an `initialize` handshake.
const _SUPPORTED_PROTOCOL_VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2025-11-05", "2024-11-05")

# `400` with a plain JSON-RPC Invalid Request error. It is deliberately not one of the errors MCP
# 2026-07-28 defines (-32020 to -32022), so a client that speaks both eras reads it as an older server
# and falls back to `initialize`.
function _write_unsupported_protocol!(http, id, message::AbstractString)
    HTTP.setstatus(http, 400)
    HTTP.setheader(http, "Content-Type" => "application/json")
    HTTP.startwrite(http)
    write(http, JSON.json(Dict(
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => Dict("code" => -32600, "message" => message),
    )))
    return nothing
end

function _stream_protocol_version(http, req)
            # MCP-Protocol-Version header validation — 2025-11-25 spec requirement.
            # If the header is present it must name a supported protocol version.
            let ver = HTTP.header(req, "MCP-Protocol-Version", "")
                if !isempty(ver) && ver ∉ _SUPPORTED_PROTOCOL_VERSIONS
                    _write_unsupported_protocol!(http, nothing, "Unsupported MCP-Protocol-Version: $ver")
                    return true
                end
            end
    return false
end

"""
    _stream_modern_request(http, parsed) -> Bool

Answer a request in MCP 2026-07-28's form the way that revision expects of a server that only speaks the
`initialize`-based versions: `400` with an error that is not one of its own, so a client that speaks both
falls back to `initialize`. Such a request is `server/discover`, which 2026-07-28 added, or one whose
`params._meta` names a protocol version this server does not speak. Otherwise it would be served on an
anonymous session as though the client had initialized.
"""
function _stream_modern_request(http, parsed)
    parsed isa AbstractDict || return false
    params = get(parsed, "params", nothing)
    meta = params isa AbstractDict ? get(params, "_meta", nothing) : nothing
    ver = meta isa AbstractDict ? get(meta, "io.modelcontextprotocol/protocolVersion", nothing) : nothing
    discover = get(parsed, "method", "") == "server/discover"
    unsupported = ver isa AbstractString && ver ∉ _SUPPORTED_PROTOCOL_VERSIONS
    (discover || unsupported) || return false
    _write_unsupported_protocol!(http, get(parsed, "id", nothing),
        "This server speaks MCP $(first(_SUPPORTED_PROTOCOL_VERSIONS)) and earlier: send `initialize` first" *
        (unsupported ? " (requested $ver)" : ""))
    return true
end

function _stream_empty_body(http, body)
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
                return true
            end
    return false
end


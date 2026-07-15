# ============================================================================
# JSON-RPC method handlers + OAuth response builders
#
# Extracted verbatim from create_handler's dispatch ladder (the
# `if request["method"] == "…"` branches) and oauth/static preamble, so each
# JSON-RPC method and OAuth endpoint is a small, named, testable function.
# create_handler keeps its security/origin preamble and outer try/catch and
# now dispatches to these. Behavior is identical: every reference here is to
# `request`/`tools`/`name_to_id`/`session`/`port` or a module-level symbol,
# resolved at call time (this file is `include`d into the Kaimon module).
# ============================================================================

# ── JSON-RPC methods ────────────────────────────────────────────────────────

function _rpc_initialize(request, session)
    params = get(request, "params", Dict{String,Any}())

    try
        # Use session management if available
        if session !== nothing
            init_result = initialize_session!(session, params)
            # Persist the negotiated capabilities so a later reconnect that doesn't
            # re-initialize (e.g. Claude Code) still sees them (issue: elicitation
            # consent fell back to the static error on restored sessions).
            _persist_session_caps!(session)
        else
            # Fallback without session management
            init_result = Dict(
                "protocolVersion" => "2025-11-25",
                # Mirror the session path's advertised capabilities (incl. tools.listChanged
                # and resources.listChanged) so the no-session fallback can't silently
                # under-declare them — keep this in lockstep with get_server_capabilities().
                "capabilities" => Session.get_server_capabilities(),
                "instructions" => Session.get_server_instructions(),
                "serverInfo" =>
                    Dict("name" => "Kaimon", "title" => "Kaimon MCP Server", "version" => PACKAGE_VERSION),
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

function _rpc_notifications_initialized(request, session)
    # This is a notification - return 202 Accepted with no body per Streamable HTTP spec
    # Mark session as fully initialized if it's in INITIALIZED state
    if session !== nothing && session.state == Session.INITIALIZED
        @info "Session initialized" session_id = session.id
    end
    return HTTP.Response(202, [], "")
end

function _rpc_logging_setlevel(request)
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

function _rpc_session_info(request, session)
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

function _rpc_tools_list(request, tools)
    # Internal worker tools (relayed to by intermediary sessions) are hidden by
    # default; a client can pass params.include_hidden=true to see them.
    include_hidden = get(get(request, "params", Dict()), "include_hidden", false) === true
    tool_list = [
        Dict(
            "name" => tool.name,
            "title" => tool.title,
            "description" => tool.description,
            "inputSchema" => tool.parameters,
        ) for tool in values(tools) if include_hidden || !tool.hidden
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

function _rpc_resources_list(request)
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

function _rpc_resources_read(request)
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
            200,
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

function _rpc_resources_templates_list(request)
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

function _rpc_prompts_list(request)
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

function _rpc_prompts_get(request)
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
            200,
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
            200,
            ["Content-Type" => "application/json"],
            JSON.json(response),
        )
    end

    # Get prompt arguments if provided
    prompt_args = get(request["params"], "arguments", Dict())

    # Return the prompt with messages
    prompt_def = findfirst(p -> p["name"] == prompt_name, Prompts.PROMPT_DEFINITIONS)
    prompt_description = prompt_def !== nothing ?
        Prompts.PROMPT_DEFINITIONS[prompt_def]["description"] : prompt_name
    response = Dict(
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => Dict(
            "description" => prompt_description,
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

# ── OAuth: intentionally NOT implemented ─────────────────────────────────────
# This server is localhost-bound and its credential is an API key presented as a
# bearer token (validated by the security gate). We deliberately do NOT run an
# OAuth authorization server: a localhost auto-approve flow can only "mint a
# token for anyone who can reach the port", which would silently bypass
# strict/relaxed mode — a security hole, not a feature. `_stream_oauth` therefore
# returns a clean 404 for these paths (before the security gate) so a client's
# OAuth discovery concludes "no OAuth here" — the RFC 8414 "no metadata" signal —
# and falls back to the configured API-key bearer, instead of being 401'd or
# crashing on a malformed response.
#
# If a non-localhost/remote gate ever needs browser-based auth, implement a real
# authorization-code + PKCE flow WITH human consent (an approval step that
# verifies the PKCE code_verifier and binds the token to the approval) — never an
# anonymous auto-mint.

# The OAuth/OIDC discovery + endpoint paths a client probes when it thinks the
# server might speak OAuth. We short-circuit ALL of them to a clean 404 (before
# the security gate) so the probe concludes "no OAuth here" rather than getting a
# 401 on a discovery endpoint (technically wrong, and it clutters the auth log).
# `.well-known/*` uses startswith so RFC 8414 path-suffixed variants
# (…/oauth-authorization-server/mcp) are covered too. Query string ignored.
function _is_public_oauth_path(target)
    p = first(split(String(target), '?'))
    return startswith(p, "/.well-known/oauth-authorization-server") ||
           startswith(p, "/.well-known/oauth-protected-resource") ||
           startswith(p, "/.well-known/openid-configuration") ||
           p == "/register" ||
           p == "/authorize" ||
           p == "/token" ||
           p == "/oauth/register" ||
           p == "/oauth/authorize" ||
           p == "/oauth/token"
end

# ── tools/call (body extracted byte-exact from the original branch) ──────────

function _rpc_tools_call(request, tools, name_to_id, session = nothing)
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
                        200,
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
                            200,
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
                    args_json_ns = JSON.json(args)
                    sk_ns = string(get(args, "ses", get(args, "session", "")))
                    db_request_id_ns = ""
                    if tui_mode
                        _push_activity!(:tool_start, tool.name, "", "")
                        inflight_id = _push_inflight_start!(tool.name, args_json_ns, sk_ns)
                        db_request_id_ns = _persist_tool_start!(tool.name, args_json_ns, sk_ns)
                    end

                    start_time = time()
                    tool_ok = true
                    time_str = ""

                    # Caller identity: expose the invoking agent's Mcp-Session-Id
                    # to the tool handler via a task-local, scoped to this dispatch.
                    # Session-tool handlers (gate_client_tools.jl) read :mcp_caller
                    # and forward it over the wire as the request's :caller field.
                    caller = session === nothing ? "" : session.id
                    agent_id = _session_agent_id(caller)   # "" unless a Kaimon-owned agent

                    # Non-streaming mode (streaming handled in hybrid_handler)
                    # Use invokelatest to pick up Revise changes to tool handlers
                    result_text = try
                        task_local_storage(:mcp_caller, caller) do
                            task_local_storage(:mcp_agent_id, agent_id) do
                                Base.invokelatest(tool.handler, args)
                            end
                        end
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

                    # Push full tool result for TUI Activity inspection + update DB
                    if tui_mode
                        rt = _tool_result_log_text(string(result_text))
                        ok = tool_ok && !startswith(rt, "ERROR:")
                        tcr = ToolCallResult(now(), tool.name, args_json_ns, rt, time_str, ok, sk_ns)
                        _push_tool_result!(tcr)
                        _persist_tool_complete!(db_request_id_ns, tcr)
                    end

                    content_blocks, is_err = _build_tool_content(string(result_text))
                    result_obj = Dict{String,Any}("content" => content_blocks)
                    is_err && (result_obj["isError"] = true)
                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "result" => result_obj,
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
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
end

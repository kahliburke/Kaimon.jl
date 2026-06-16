# ─────────────────────────────────────────────────────────────────────────────
# Kaimon MCP tools · navigation + debug protocol tools  (split from tool_definitions.jl)
# ─────────────────────────────────────────────────────────────────────────────

# Navigation tools
navigate_to_file_tool = @mcp_tool(
    :navigate_to_file,
    """Navigate to a specific file and location in VS Code.

Opens a file at a specific line and column position without requiring LSP context.
Useful for guided code tours, navigating to specific locations from search results,
or when LSP goto_definition doesn't work.

# Arguments
- `file_path`: Absolute path to the file to open
- `line`: Line number to navigate to (1-indexed, optional, defaults to 1)
- `column`: Column number to navigate to (1-indexed, optional, defaults to 1)

# Examples
- Navigate to line 100: `{"file_path": "/path/to/file.jl", "line": 100}`
- Navigate to specific position: `{"file_path": "/path/to/file.jl", "line": 582, "column": 10}`
- Just open file: `{"file_path": "/path/to/file.jl"}`
""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "file_path" => Dict(
                "type" => "string",
                "description" => "Absolute path to the file",
            ),
            "line" => Dict(
                "type" => "integer",
                "description" => "Line number to navigate to (1-indexed, optional, defaults to 1)",
            ),
            "column" => Dict(
                "type" => "integer",
                "description" => "Column number to navigate to (1-indexed, optional, defaults to 1)",
            ),
        ),
        "required" => ["file_path"],
    ),
    function (args)
        try
            file_path = get(args, "file_path", "")
            line = get(args, "line", 1)
            column = get(args, "column", 1)

            if isempty(file_path)
                return "Error: file_path is required"
            end

            # Make sure it's an absolute path
            abs_path = isabspath(file_path) ? file_path : joinpath(pwd(), file_path)

            if !isfile(abs_path)
                return "Error: File does not exist: $abs_path"
            end

            # Use configured editor URI with line and column position
            uri = editor_file_url(abs_path; line=line, col=column)
            trigger_vscode_uri(uri)

            return "Navigated to $abs_path:$line:$column"
        catch e
            return "Error: $e"
        end
    end
)

# ============================================================================
# Agent-Assisted Debugging Tools (Infiltrator.jl + Breakpoint Hooks)
# ============================================================================

debug_exfiltrate_tool = @mcp_tool(
    :debug_exfiltrate,
    """Evaluate code containing @exfiltrate on a gate session to capture local variables.

Infiltrator.jl is loaded automatically on the gate if available. The code should
typically be a function redefinition with @exfiltrate inserted at the point of interest.

Workflow:
1. Read the function you want to debug
2. Add @exfiltrate at the point of interest
3. Call this tool with the modified function definition
4. Trigger the code path (call the function)
5. Use debug_inspect_safehouse to see captured variables""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "code" => Dict(
                "type" => "string",
                "description" => "Julia code containing @exfiltrate calls",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["code"],
    ),
    function (args)
        session = get(args, "session", "")
        code = get(args, "code", "")
        isempty(code) && return "Error: code is required"
        full_code = """
        try
            using Infiltrator
        catch e
            error("Infiltrator.jl not found. Run `]add Infiltrator` in your project environment.")
        end
        $(code)
        """
        execute_repllike(full_code; quiet = false, session = session)
    end
)

debug_inspect_safehouse_tool = @mcp_tool(
    :debug_inspect_safehouse,
    """Inspect variables captured by @exfiltrate in Infiltrator's safehouse.

With no expression: lists all captured variables with types and values.
With an expression: evaluates it using safehouse variables via Infiltrator.@withstore.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "expression" => Dict(
                "type" => "string",
                "description" => "Optional expression to evaluate using safehouse variables (e.g., 'typeof(x)' or 'length(data)')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Required when multiple sessions are connected.",
            ),
        ),
        "required" => [],
    ),
    function (args)
        session = get(args, "session", "")
        expr = get(args, "expression", "")
        if isempty(expr)
            code = """
            using Infiltrator
            let names_list = propertynames(Infiltrator.safehouse)
                if isempty(names_list)
                    "Safehouse is empty. No variables captured yet."
                else
                    lines = String[]
                    for n in names_list
                        v = getproperty(Infiltrator.safehouse, n)
                        push!(lines, "\$n::\$(typeof(v)) = \$(repr(v; context=:limit=>true))")
                    end
                    join(lines, "\\n")
                end
            end
            """
            execute_repllike(code; quiet = false, session = session)
        else
            code = """
            using Infiltrator
            Infiltrator.@withstore $(expr)
            """
            execute_repllike(code; quiet = false, session = session)
        end
    end
)

debug_clear_safehouse_tool = @mcp_tool(
    :debug_clear_safehouse,
    "Clear all variables from Infiltrator's safehouse.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Required when multiple sessions are connected.",
            ),
        ),
        "required" => [],
    ),
    function (args)
        session = get(args, "session", "")
        execute_repllike(
            "using Infiltrator; Infiltrator.clear_store!(); \"Safehouse cleared.\"";
            quiet = false,
            session = session,
        )
    end
)

debug_ctrl_tool = @mcp_tool(
    :debug_ctrl,
    """Control a debug session paused at an @infiltrate breakpoint.

Actions:
- 'status': Check if paused, see file/line and local variables
- 'continue': Resume normal execution from the breakpoint""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "action" => Dict(
                "type" => "string",
                "enum" => ["status", "continue"],
                "description" => "Action to take: status or continue",
                "default" => "status",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Required when multiple sessions are connected.",
            ),
        ),
        "required" => [],
    ),
    function (args)
        session = get(args, "session", "")
        action = get(args, "action", "status")
        conn, err = _resolve_gate_conn(session)
        err !== nothing && return err
        try
            if action == "status"
                resp = _gate_send_recv(conn, (type = :debug_status,))
                if get(resp, :is_paused, false)
                    lines = String["Paused at breakpoint:"]
                    push!(lines, "  File: $(get(resp, :file, "unknown"))")
                    push!(lines, "  Line: $(get(resp, :line, 0))")
                    locals = get(resp, :locals, Dict())
                    types = get(resp, :locals_types, Dict())
                    if !isempty(locals)
                        push!(lines, "  Locals:")
                        for (name, val) in sort(collect(locals); by=first)
                            t = get(types, name, "Any")
                            push!(lines, "    $name::$t = $val")
                        end
                    end
                    push!(lines, "\nUse debug_eval to evaluate expressions in this context.")
                    push!(lines, "Use debug_ctrl with action='continue' to resume.")
                    join(lines, "\n")
                else
                    "Not paused at a breakpoint."
                end
            elseif action == "continue"
                # Request consent through the TUI before resuming.
                # The TUI polls _DEBUG_CONTINUE_REQUEST on tick and shows
                # a consent prompt; the response comes back on a Channel.
                response_ch = Channel{Symbol}(1)
                session_key = short_key(conn)
                _DEBUG_CONTINUE_REQUEST[] = (session_key = session_key, action = :continue)
                _DEBUG_CONTINUE_RESPONSE[] = response_ch
                # Wait for user approval (timeout after 30s)
                result = timedwait(30.0) do
                    isready(response_ch)
                end
                _DEBUG_CONTINUE_REQUEST[] = nothing
                _DEBUG_CONTINUE_RESPONSE[] = nothing
                if result == :timed_out
                    return "Timed out waiting for user approval in Debug tab."
                end
                decision = take!(response_ch)
                if decision == :denied
                    return "User denied the continue request."
                end
                resp = _gate_send_recv(conn, (type = :debug_continue, action = :continue))
                return get(resp, :message, "Resumed execution")
            else
                return "Error: unknown action '$action'. Use 'status' or 'continue'."
            end
        catch e
            "Error: $e"
        end
    end
)

debug_eval_tool = @mcp_tool(
    :debug_eval,
    """Evaluate an expression in the context of a paused breakpoint.

Requires an active debug session (execution paused at @infiltrate).
The expression has access to all local variables at the breakpoint.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "expression" => Dict(
                "type" => "string",
                "description" => "Julia expression to evaluate in breakpoint context (e.g., 'typeof(x)' or 'length(data)')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["expression"],
    ),
    function (args)
        session = get(args, "session", "")
        expression = get(args, "expression", "")
        isempty(expression) && return "Error: expression is required"
        conn, err = _resolve_gate_conn(session)
        err !== nothing && return err
        try
            resp = _gate_send_recv(conn, (type = :debug_eval, code = expression))
            result = get(resp, :result, nothing)
            error_msg = get(resp, :error, nothing)
            if error_msg !== nothing
                return "Error: $error_msg"
            end
            return something(result, "nothing")
        catch e
            "Error: $e"
        end
    end
)


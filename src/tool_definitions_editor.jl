# ─────────────────────────────────────────────────────────────────────────────
# Kaimon MCP tools · tty + VSCode integration + tool_help  (split from tool_definitions.jl)
# ─────────────────────────────────────────────────────────────────────────────

set_tty_tool = @mcp_tool(
    :set_tty,
    """Configure an external TTY for a gate session to render its TUI into.

macOS/Linux only. Requires a Unix TTY device path (e.g. /dev/ttys042).

Detects the terminal size and stores the path so the app can call
`Tachikoma.app(model; tty_out = KaimonGate.tty_path(), tty_size = KaimonGate.tty_size())` to render there.

Automatically pauses the shell in the remote terminal (via SIGSTOP) and disables echo, so the display is clean. Both are restored when the TUI exits via `restore_tty!`.

Terminal resize is supported — the TUI polls the remote terminal's size once per second and reflows automatically.

Workflow:
1. Open a new terminal window and resize it as desired
2. Run `tty` in that window to get the device path (e.g. /dev/ttys042)
3. Call this tool with that path and the gate session key
4. Start the app — it will render in the second terminal; resize the window any time""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "path" => Dict(
                "type" => "string",
                "description" => "TTY device path from running `tty` in the target terminal (e.g. /dev/ttys042)",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["path"],
    ),
    (args) -> begin
        path = get(args, "path", "")
        session = get(args, "session", "")
        isempty(path) && return "Error: path is required"

        conn, err = _resolve_gate_conn(session)
        err !== nothing && return err
        key = short_key(conn)

        ok = set_tty!(conn, path)
        ok ? "TTY configured for session $key: $path." :
        "Error: Failed to configure TTY for session $key."
    end
)

vscode_command_tool = @mcp_tool(
    :execute_vscode_command,
    """Execute a VS Code command via the Remote Control extension.

Set wait_for_response=true to get return values (default timeout: 5s).
Use list_vscode_commands to see available commands.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "command" => Dict(
                "type" => "string",
                "description" => "The VS Code command ID to execute (e.g., 'workbench.action.files.saveAll')",
            ),
            "args" => Dict(
                "type" => "array",
                "description" => "Optional array of arguments to pass to the command (JSON-encoded)",
                "items" => Dict("type" => "string"),
            ),
            "wait_for_response" => Dict(
                "type" => "boolean",
                "description" => "Wait for command result (default: false). Enable for commands that return values.",
                "default" => false,
            ),
            "timeout" => Dict(
                "type" => "number",
                "description" => "Timeout in seconds when wait_for_response=true (default: 5.0)",
                "default" => 5.0,
            ),
        ),
        "required" => ["command"],
    ),
    args -> begin
        try
            cmd = get(args, "command", "")
            if isempty(cmd)
                return "Error: command parameter is required"
            end

            wait_for_response = get(args, "wait_for_response", false)
            timeout = get(args, "timeout", 5.0)

            # Generate unique request ID if waiting for response
            request_id = wait_for_response ? string(rand(UInt128), base = 16) : nothing

            # Build URI with command and optional args
            args_param = nothing
            if haskey(args, "args") && !isempty(args["args"])
                args_json = JSON.json(args["args"])
                args_param = HTTP.URIs.escapeuri(args_json)
            end

            uri = build_vscode_uri(cmd; args = args_param, request_id = request_id)
            trigger_vscode_uri(uri)

            # If waiting for response, poll for it
            if wait_for_response
                try
                    result, error = retrieve_vscode_response(request_id; timeout = timeout)

                    if error !== nothing
                        return "VS Code command '$(cmd)' failed: $error"
                    end

                    # Format result for display
                    if result === nothing
                        return "VS Code command '$(cmd)' executed successfully (no return value)"
                    else
                        # Pretty-print the result
                        result_str = try
                            JSON.json(result)
                        catch
                            string(result)
                        end
                        return "VS Code command '$(cmd)' result:\n$result_str"
                    end
                catch e
                    return "Error waiting for VS Code response: $e"
                end
            else
                return "VS Code command '$(cmd)' executed successfully."
            end
        catch e
            return "Error executing VS Code command: $e. Make sure the VS Code Remote Control extension is installed via Kaimon.setup()"
        end
    end
)

list_vscode_commands_tool = @mcp_tool(
    :list_vscode_commands,
    """List all VS Code commands that are allowed for execution.

Checks workspace .vscode/settings.json, then VS Code user settings, then extension defaults.
Use this to discover which commands are available for the `execute_vscode_command` tool.""",
    Dict("type" => "object", "properties" => Dict(), "required" => []),
    args -> begin
        try
            settings = Base.invokelatest(read_vscode_settings)
            allowed_commands =
                get(settings, "vscode-remote-control.allowedCommands", nothing)

            source = if allowed_commands !== nothing && !isempty(allowed_commands)
                "settings"
            else
                # Fall back to extension defaults
                allowed_commands = [
                    "workbench.action.files.save",
                    "workbench.action.files.saveAll",
                    "workbench.action.files.openFile",
                    "workbench.action.terminal.new",
                    "workbench.action.terminal.sendSequence",
                    "workbench.action.terminal.focus",
                    "workbench.action.quickOpen",
                    "workbench.action.gotoLine",
                    "workbench.action.showAllSymbols",
                    "workbench.action.reloadWindow",
                    "workbench.action.findInFiles",
                    "vscode.open",
                ]
                "extension defaults"
            end

            result = "Allowed VS Code Commands ($(length(allowed_commands)), from $source)\n\n"
            for cmd in sort(allowed_commands)
                result *= "  - $cmd\n"
            end
            return result
        catch e
            return "Error reading VS Code settings: $e"
        end
    end
)

tool_help_tool = @mcp_tool(
    :tool_help,
    "Get detailed help and examples for any MCP tool. Use extended=true for additional documentation.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "tool_name" => Dict(
                "type" => "string",
                "description" => "Name of the tool to get help for",
            ),
            "extended" => Dict(
                "type" => "boolean",
                "description" => "If true, return extended documentation with additional examples (default: false)",
            ),
        ),
        "required" => ["tool_name"],
    ),
    args -> begin
        try
            tool_name = get(args, "tool_name", "")
            if isempty(tool_name)
                return "Error: tool_name parameter is required"
            end

            extended = get(args, "extended", false)
            tool_id = Symbol(tool_name)

            if SERVER[] === nothing
                return "Error: MCP server is not running"
            end

            server = SERVER[]
            # Resolve against the FULL registry (ALL_TOOLS[]), not just the agent-
            # advertised surface, so hidden/gated tools (off the default tool-list but
            # callable by extensions via the service endpoint) are still documentable.
            tool = nothing
            registry = ALL_TOOLS[]
            if registry !== nothing
                for t in registry
                    if t.id == tool_id
                        tool = t
                        break
                    end
                end
            end
            tool === nothing && haskey(server.tools, tool_id) && (tool = server.tools[tool_id])
            if tool === nothing
                return "Error: Tool ':$tool_id' not found. Use list_tools() to see available tools."
            end

            result = "📖 Help for MCP Tool: $tool_name\n"
            result *= "="^70 * "\n\n"
            result *= tool.description * "\n"

            # Try to load extended documentation if requested
            if extended
                extended_help_path = joinpath(
                    dirname(dirname(@__FILE__)),
                    "extended-help",
                    "$tool_name.md",
                )

                if isfile(extended_help_path)
                    result *= "\n\n---\n\n## Extended Documentation\n\n"
                    result *= read(extended_help_path, String)
                else
                    result *= "\n\n(No extended documentation available for this tool)"
                end
            end

            return result
        catch e
            return "Error getting tool help: $e"
        end
    end
)


# ============================================================================
# Helper Functions for Deduplication
# ============================================================================

"""
    vscode_debug_command(command::String, success_message::String; args=nothing) -> String

Helper function to execute VS Code debug commands via URI.
Reduces duplication across debug step tools (step_over, step_into, step_out, continue, stop).

# Arguments
- `command`: VS Code command ID (e.g., "workbench.action.debug.stepOver")
- `success_message`: Message to return on success
- `args`: Optional arguments dict (can check for wait_for_response)

# Returns
Success or error message string
"""
function vscode_debug_command(
    command::String,
    success_message::String;
    args = nothing,
    session::String = "",
)
    try
        # Check if caller wants to wait for response (only step_over supports this)
        if args !== nothing && get(args, "wait_for_response", false)
            result = execute_repllike(
                """execute_vscode_command("$command", wait_for_response=true, timeout=10.0)""";
                silent = false,
                quiet = false,
                session = session,
            )
            return result
        else
            trigger_vscode_uri(build_vscode_uri(command))
            return success_message
        end
    catch e
        return "Error executing $command: $e"
    end
end

"""
    pkg_operation_tool(operation::String, verb::String, args) -> String

Helper function for package management operations (add/remove).
Reduces duplication between pkg_add_tool and pkg_rm_tool.

# Arguments
- `operation`: Pkg function name ("add" or "rm")
- `verb`: Past tense verb for success message ("Added" or "Removed")
- `args`: Tool arguments containing packages array

# Returns
Success message with result or error string
"""
function pkg_operation_tool(operation::String, verb::String, args; session::String = "")
    try
        packages = get(args, "packages", String[])
        if isempty(packages)
            return "Error: packages array is required and cannot be empty"
        end

        # Use Pkg operation with io=devnull to disable interactivity
        # Also set JULIA_PKG_PRECOMPILE_AUTO=0 to avoid long precompilation waits
        pkg_names = join(["\"$p\"" for p in packages], ", ")
        code = """
        using Pkg
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            Pkg.$operation([$pkg_names]; io=devnull)
        end
        """

        execute_repllike(code; silent = false, quiet = false, session = session)

        return """$verb packages: $(join(packages, ", "))

Note: Packages installed but not precompiled. They will precompile on first use."""
    catch e
        action = lowercase(verb) * "ing"
        return "Error $action packages: $e"
    end
end

"""
    code_introspection_tool(macro_name::String, description_prefix::String, args) -> String

Helper function for code introspection tools (@code_lowered, @code_typed, etc.).
Reduces duplication between code_lowered_tool and code_typed_tool.

# Arguments
- `macro_name`: Name of the macro (e.g., "code_lowered", "code_typed")
- `description_prefix`: Prefix for description message
- `args`: Tool arguments containing function_expr and types

# Returns
Result of code introspection or error string
"""
function code_introspection_tool(
    macro_name::String,
    description_prefix::String,
    args;
    session::String = "",
)
    try
        func_expr = get(args, "function_expr", "")
        types_expr = get(args, "types", "")

        if isempty(func_expr) || isempty(types_expr)
            return "Error: function_expr and types parameters are required"
        end

        code = """
        using InteractiveUtils
        @$macro_name $func_expr($types_expr...)
        """
        execute_repllike(
            code;
            description = "[$description_prefix: $func_expr with types $types_expr]",
            quiet = false,
            session = session,
        )
    catch e
        return "Error getting $macro_name: $e"
    end
end

# ============================================================================
# Tool Definitions
# ============================================================================

ping_tool = @mcp_tool(
    :ping,
    "Check if the MCP server is responsive and return Revise.jl status.",
    Dict("type" => "object", "properties" => Dict(), "required" => []),
    args -> begin
        status = "✓ MCP Server is healthy and responsive\n"

        # Check Revise status
        if isdefined(Main, :Revise)
            revise_errors = Main.Revise.errors()
            if revise_errors === nothing
                status *= "Revise: active (no errors)"
            else
                status *= "Revise: active (has errors - call Revise.errors() for details)"
            end
        else
            status *= "Revise: not loaded"
        end

        # Connected Julia sessions
        mgr = GATE_CONN_MGR[]
        if mgr !== nothing
            conns = connected_sessions(mgr)
            all_conns = lock(mgr.lock) do
                copy(mgr.connections)
            end
            status *= "\n\nSessions: $(length(conns)) connected / $(length(all_conns)) total"
            for conn in all_conns
                key = short_key(conn)
                dname = isempty(conn.display_name) ? conn.name : conn.display_name
                icon =
                    conn.status == :connected ? "●" :
                    conn.status == :connecting ? "◐" : "○"
                ntools = length(conn.session_tools)
                tools_info = ntools > 0 ? ", $(ntools) tools" : ""
                status *= "\n  $icon $key $dname ($(conn.status), Julia $(conn.julia_version), PID $(conn.pid)$tools_info)"
                status *= "\n    project: $(conn.project_path)"
            end
        end

        return status
    end
)

usage_instructions_tool =
    @mcp_tool :usage_instructions "Get Julia REPL usage instructions and best practices for AI agents." Dict(
        "type" => "object",
        "properties" => Dict(),
        "required" => [],
    ) (
        args -> begin
            try
                workflow_path = joinpath(
                    dirname(dirname(@__FILE__)),
                    "prompts",
                    "julia_repl_workflow.md",
                )

                if !isfile(workflow_path)
                    return "Error: julia_repl_workflow.md not found at $workflow_path"
                end

                return read(workflow_path, String)
            catch e
                return "Error reading usage instructions: $e"
            end
        end
    )

usage_quiz_tool = @mcp_tool(
    :usage_quiz,
    """Self-graded quiz on Kaimon usage patterns.

Default: returns quiz questions. With show_sols=true: returns solutions and grading rubric.
Tests understanding of shared REPL model, q=true/false usage, multi-session routing, and tool selection.
If score < 75, review usage_instructions and retake.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "show_sols" => Dict(
                "type" => "boolean",
                "description" => "If true, return solutions and grading instructions. If false/omitted, return quiz questions.",
                "default" => false,
            ),
        ),
        "required" => [],
    ),
    args -> begin
        try
            show_solutions = get(args, "show_sols", false)

            filename = if show_solutions
                "usage_quiz_solutions.md"
            else
                "usage_quiz_questions.md"
            end

            quiz_path = joinpath(dirname(dirname(@__FILE__)), "prompts", filename)

            if !isfile(quiz_path)
                return "Error: $filename not found at $quiz_path"
            end

            return read(quiz_path, String)
        catch e
            return "Error reading quiz file: $e"
        end
    end
)

repl_tool = @mcp_tool(
    :ex,
    """Execute Julia code in a persistent REPL. User sees code in real-time.

Default q=true: suppresses return values (token-efficient). Use q=false only when you need the result.
println/print to stdout are stripped from agent code. Use q=false with a final expression to see values.
s=true (rare): suppresses agent> prompt and REPL echo for large outputs.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "e" => Dict(
                "type" => "string",
                "description" => "Julia expression to evaluate (e.g., '2 + 3 * 4' or 'using Pkg; Pkg.status()')",
            ),
            "q" => Dict(
                "type" => "boolean",
                "description" => "Quiet mode: suppresses return value to save tokens (default: true). Set to false to see the computed result.",
            ),
            "s" => Dict(
                "type" => "boolean",
                "description" => "Silent mode: suppresses 'agent>' prompt and real-time REPL echo (default: false). Use s=true only rarely to avoid spamming huge output.",
            ),
            "max_output" => Dict(
                "type" => "integer",
                "description" => "Maximum output length in characters (default: 6000, max: 25000). Only increase if you legitimately need more output. Hitting this limit usually means you should use a different approach (check size first, sample data, filter, etc).",
                "default" => 6000,
            ),
            "ses" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["e"],
    ),
    (args) -> begin
        try
            silent = get(args, "s", false)
            quiet = get(args, "q", true)
            expr_str = get(args, "e", "")
            max_output = get(args, "max_output", 6000)
            ses = get(args, "ses", "")

            # Enforce hard limit
            max_output = min(max_output, 25000)

            # Format long one-liners for readability (if JuliaFormatter available)
            if length(expr_str) > 80 && isdefined(Main, :JuliaFormatter)
                try
                    formatted = Main.JuliaFormatter.format_text(expr_str)
                    # Only use formatted version if it's actually multiline
                    if count('\n', formatted) > 0
                        expr_str = formatted
                    end
                catch
                    # If formatting fails, use original
                end
            end

            # Route through gate if in TUI server mode
            if GATE_MODE[]
                Base.invokelatest(
                    execute_via_gate,
                    expr_str;
                    quiet = quiet,
                    silent = silent,
                    max_output = max_output,
                    session = ses,
                )
            else
                Base.invokelatest(
                    execute_repllike,
                    expr_str;
                    silent = silent,
                    quiet = quiet,
                    max_output = max_output,
                    session = ses,
                )
            end
        catch e
            @error "Error during execute_repllike" exception = e
            "Apparently there was an **internal** error to the MCP server: $e"
        end
    end
)

manage_repl_tool = @mcp_tool(
    :manage_repl,
    """Manage the Julia REPL (restart or shutdown).

Commands:
- restart: Fresh Julia state. Use when Revise fails to pick up changes. Session key is preserved.
- shutdown: Stop the session permanently.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "command" => Dict(
                "type" => "string",
                "enum" => ["restart", "shutdown"],
                "description" => "Command to execute: 'restart' or 'shutdown'",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["command"],
    ),
    (args) -> begin
        command = get(args, "command", "")
        session = get(args, "session", "")
        isempty(command) && return "Error: command is required"

        conn, err = _resolve_gate_conn(session)
        err !== nothing && return err
        mgr = GATE_CONN_MGR[]
        mgr === nothing && return "Error: No ConnectionManager available"
        key = short_key(conn)

        if command == "restart"
            # Check if the session has opted out of remote restarts
            if !conn.allow_restart
                return "Warning: Session $key has disabled remote restart (allow_restart=false). Restart the process manually, or use Revise to hot-reload changes."
            end
            # Can't restart the TUI's own session — execvp would kill the
            # coordinator process with nothing left to manage the reconnect.
            if conn.pid == getpid()
                return "Error: Cannot restart the Kaimon server's own session. Restart the kaimon process manually, or use Revise to hot-reload changes."
            end

            ok = send_restart!(conn)
            if !ok
                return "Error: Failed to send restart to session $key"
            end

            # Suppress resource notifications during restart — session key stays
            # stable so the agent doesn't need to re-discover resources.
            old_cb = mgr.on_sessions_changed
            mgr.on_sessions_changed = nothing

            # Remove old connection from manager so the health checker doesn't
            # race with the new gate by cleaning up files for this session_id.
            # The gate handles its own file cleanup before exec.
            lock(mgr.lock) do
                idx = findfirst(c -> c === conn, mgr.connections)
                if idx !== nothing
                    disconnect!(conn)
                    deleteat!(mgr.connections, idx)
                end
            end

            # Wait for new session to appear (gate does exec, reconnects with same session_id).
            # The watcher will discover the new metadata JSON and create a fresh connection.
            deadline = time() + 60.0
            while time() < deadline
                sleep(3.0)
                new_conn = get_connection_by_key(mgr, key)
                if new_conn !== nothing && new_conn.status == :connected
                    mgr.on_sessions_changed = old_cb
                    return "Session $key restarted. Fresh Julia state. Revise active."
                end
            end
            mgr.on_sessions_changed = old_cb
            return "Restart sent to $key but timed out waiting for reconnection (60s). The session may still be starting — try again shortly."
        elseif command == "shutdown"
            ok = send_restart!(conn)  # reuse restart to stop the gate loop
            disconnect!(conn)
            return ok ? "Session $key shut down." : "Error: Failed to reach session $key."
        else
            return "Error: Invalid command '$command'"
        end
    end
)

set_tty_tool = @mcp_tool(
    :set_tty,
    """Configure an external TTY for a gate session to render its TUI into.

macOS/Linux only. Requires a Unix TTY device path (e.g. /dev/ttys042).

Detects the terminal size and stores the path so the app can call
`Tachikoma.app(model; tty_out = Gate.tty_path(), tty_size = Gate.tty_size())` to render there.

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

Returns the list of commands configured in `.vscode/settings.json` under `vscode-remote-control.allowedCommands`.
Use this to discover which commands are available for the `execute_vscode_command` tool.""",
    Dict("type" => "object", "properties" => Dict(), "required" => []),
    args -> begin
        try
            settings = read_vscode_settings()
            allowed_commands =
                get(settings, "vscode-remote-control.allowedCommands", nothing)

            if allowed_commands === nothing || isempty(allowed_commands)
                return "No VS Code commands configured. Run Kaimon.setup() to configure the Remote Control extension."
            end

            result = "📋 Allowed VS Code Commands ($(length(allowed_commands)))\n\n"
            for cmd in sort(allowed_commands)
                result *= "  • $cmd\n"
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
            if !haskey(server.tools, tool_id)
                return "Error: Tool ':$tool_id' not found. Use list_tools() to see available tools."
            end

            tool = server.tools[tool_id]

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

investigate_tool = @mcp_tool(
    :investigate_environment,
    "Get current Julia environment info: pwd, active project, packages, dev packages, and Revise status.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => [],
    ),
    args -> begin
        try
            ses = get(args, "session", "")
            code = raw"""
            begin
                import Pkg
                import TOML

                io = IOBuffer()

                # Project info
                active_proj = Base.active_project()
                if active_proj !== nothing
                    try
                        pd = TOML.parsefile(active_proj)
                        name = get(pd, "name", basename(dirname(active_proj)))
                        ver = get(pd, "version", "")
                        print(io, "Project: $name")
                        !isempty(ver) && print(io, " v$ver")
                        println(io)
                    catch
                        println(io, "Project: $(basename(dirname(active_proj)))")
                    end
                    println(io, "Path: $(dirname(active_proj))")
                else
                    println(io, "Project: (none)")
                end
                println(io, "pwd: $(pwd())")

                # Dev packages only (the ones that matter for development)
                try
                    deps = Pkg.dependencies()
                    dev_pkgs = [(info.name, info.version, info.source)
                                for (_, info) in deps
                                if info.is_direct_dep && info.is_tracking_path]
                    sort!(dev_pkgs; by = first)
                    if !isempty(dev_pkgs)
                        println(io, "Dev packages:")
                        for (name, ver, src) in dev_pkgs
                            println(io, "  $name v$ver => $src")
                        end
                    end
                catch; end

                # Revise status (one line)
                revise = isdefined(Main, :Revise)
                println(io, "Revise: $(revise ? "active" : "not loaded")")

                String(take!(io))
            end
            """
            execute_repllike(
                code;
                description = "[Investigating environment]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error investigating environment: $e"
        end
    end
)

search_methods_tool = @mcp_tool(
    :search_methods,
    "Search for all methods of a function or methods matching a type signature.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "query" => Dict(
                "type" => "string",
                "description" => "Function name or type to search (e.g., 'println', 'String', 'Base.sort')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["query"],
    ),
    args -> begin
        try
            query = get(args, "query", "")
            ses = get(args, "session", "")
            if isempty(query)
                return "Error: query parameter is required"
            end
            code = """
            using InteractiveUtils
            target = $query
            if isa(target, Type)
                println("Methods with argument type \$target:")
                println("=" ^ 60)
                methodswith(target)
            else
                println("Methods for \$target:")
                println("=" ^ 60)
                methods(target)
            end
            """
            execute_repllike(
                code;
                description = "[Searching methods for: $query]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error searching methods: $e"
        end
    end
)

macro_expand_tool = @mcp_tool(
    :macro_expand,
    "Expand a macro to see the generated code.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "expression" => Dict(
                "type" => "string",
                "description" => "Macro expression to expand (e.g., '@time sleep(1)')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["expression"],
    ),
    args -> begin
        try
            expr = get(args, "expression", "")
            ses = get(args, "session", "")
            if isempty(expr)
                return "Error: expression parameter is required"
            end

            code = """
            using InteractiveUtils
            @macroexpand $expr
            """
            execute_repllike(
                code;
                description = "[Expanding macro: $expr]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error expanding macro: \$e"
        end
    end
)

type_info_tool = @mcp_tool(
    :type_info,
    "Get type information: hierarchy, fields, parameters, and properties.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "type_expr" => Dict(
                "type" => "string",
                "description" => "Type expression to inspect (e.g., 'String', 'Vector{Int}', 'AbstractArray')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["type_expr"],
    ),
    args -> begin
        try
            type_expr = get(args, "type_expr", "")
            ses = get(args, "session", "")
            if isempty(type_expr)
                return "Error: type_expr parameter is required"
            end

            code = """
            using InteractiveUtils
            T = $type_expr
            _buf = IOBuffer()
            print(_buf, "Type Information for: \$T\\n")
            print(_buf, "=" ^ 60, "\\n\\n")
            print(_buf, "Abstract: ", isabstracttype(T), "\\n")
            print(_buf, "Primitive: ", isprimitivetype(T), "\\n")
            print(_buf, "Mutable: ", ismutabletype(T), "\\n\\n")
            print(_buf, "Supertype: ", supertype(T), "\\n")
            if !isabstracttype(T)
                print(_buf, "\\nFields:\\n")
                if fieldcount(T) > 0
                    for (i, fname) in enumerate(fieldnames(T))
                        ftype = fieldtype(T, i)
                        print(_buf, "  \$i. \$fname :: \$ftype\\n")
                    end
                else
                    print(_buf, "  (no fields)\\n")
                end
            end
            print(_buf, "\\nDirect subtypes:\\n")
            subs = subtypes(T)
            if isempty(subs)
                print(_buf, "  (no direct subtypes)\\n")
            else
                for sub in subs
                    print(_buf, "  - \$sub\\n")
                end
            end
            String(take!(_buf))
            """
            execute_repllike(
                code;
                description = "[Getting type info for: $type_expr]",
                quiet = false,
                show_prompt = false,
                session = ses,
            )
        catch e
            "Error getting type info: $e"
        end
    end
)

profile_tool = @mcp_tool(
    :profile_code,
    "Profile Julia code to identify performance bottlenecks.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "code" =>
                Dict("type" => "string", "description" => "Julia code to profile"),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["code"],
    ),
    args -> begin
        try
            code_to_profile = get(args, "code", "")
            ses = get(args, "session", "")
            if isempty(code_to_profile)
                return "Error: code parameter is required"
            end

            wrapper = """
            using Profile
            Profile.clear()
            @profile begin
                $code_to_profile
            end
            Profile.print(format=:flat, sortedby=:count)
            """
            execute_repllike(
                wrapper;
                description = "[Profiling code]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error profiling code: \$e"
        end
    end
)

list_names_tool = @mcp_tool(
    :list_names,
    "List all exported names in a module or package.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "module_name" => Dict(
                "type" => "string",
                "description" => "Module name (e.g., 'Base', 'Core', 'Main')",
            ),
            "all" => Dict(
                "type" => "boolean",
                "description" => "Include non-exported names (default: false)",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["module_name"],
    ),
    args -> begin
        try
            module_name = get(args, "module_name", "")
            show_all = get(args, "all", false)
            ses = get(args, "session", "")

            if isempty(module_name)
                return "Error: module_name parameter is required"
            end

            code = """
            mod = $module_name
            _buf = IOBuffer()
            print(_buf, "Names in \$mod" * (($show_all) ? " (all=true)" : " (exported only)") * ":\\n")
            print(_buf, "=" ^ 60, "\\n")
            name_list = names(mod, all=$show_all)
            for name in sort(name_list)
                print(_buf, "  ", name, "\\n")
            end
            print(_buf, "\\nTotal: ", length(name_list), " names\\n")
            String(take!(_buf))
            """
            execute_repllike(
                code;
                description = "[Listing names in: $module_name]",
                quiet = false,
                show_prompt = false,
                session = ses,
            )
        catch e
            "Error listing names: \$e"
        end
    end
)

code_lowered_tool = @mcp_tool(
    :code_lowered,
    "Show lowered (desugared) IR for a function.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "function_expr" => Dict(
                "type" => "string",
                "description" => "Function to inspect (e.g., 'sin', 'Base.sort')",
            ),
            "types" => Dict(
                "type" => "string",
                "description" => "Argument types as tuple (e.g., '(Float64,)', '(Int, Int)')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["function_expr", "types"],
    ),
    args -> code_introspection_tool(
        "code_lowered",
        "Getting lowered code for",
        args;
        session = get(args, "session", ""),
    )
)

code_typed_tool = @mcp_tool(
    :code_typed,
    "Show type-inferred code for a function (for debugging type stability).",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "function_expr" => Dict(
                "type" => "string",
                "description" => "Function to inspect (e.g., 'sin', 'Base.sort')",
            ),
            "types" => Dict(
                "type" => "string",
                "description" => "Argument types as tuple (e.g., '(Float64,)', '(Int, Int)')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["function_expr", "types"],
    ),
    args -> code_introspection_tool(
        "code_typed",
        "Getting typed code for",
        args;
        session = get(args, "session", ""),
    )
)

# Optional formatting tool (requires JuliaFormatter.jl)
format_tool = @mcp_tool(
    :format_code,
    "Format Julia code using JuliaFormatter.jl.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "path" => Dict(
                "type" => "string",
                "description" => "File or directory path to format",
            ),
            "overwrite" => Dict(
                "type" => "boolean",
                "description" => "Overwrite files in place",
                "default" => true,
            ),
            "verbose" => Dict(
                "type" => "boolean",
                "description" => "Show formatting progress",
                "default" => true,
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["path"],
    ),
    function (args)
        try
            # Check if JuliaFormatter is available
            if !isdefined(Main, :JuliaFormatter)
                try
                    @eval Main using JuliaFormatter
                catch
                    return "Error: JuliaFormatter.jl is not installed. Install it with: using Pkg; Pkg.add(\"JuliaFormatter\")"
                end
            end

            path = get(args, "path", "")
            overwrite = get(args, "overwrite", true)
            verbose = get(args, "verbose", true)
            ses = get(args, "session", "")

            if isempty(path)
                return "Error: path parameter is required"
            end

            # Make path absolute
            abs_path = isabspath(path) ? path : joinpath(pwd(), path)

            if !ispath(abs_path)
                return "Error: Path does not exist: $abs_path"
            end

            code = """
            using JuliaFormatter

            # Read the file before formatting to detect changes
            before_content = read("$abs_path", String)

            # Format the file
            format_result = format("$abs_path"; overwrite=$overwrite, verbose=$verbose)

            # Read after to see if changes were made
            after_content = read("$abs_path", String)
            changes_made = before_content != after_content

            if changes_made
                println("✅ File was reformatted: $abs_path")
            elseif format_result
                println("ℹ️  File was already properly formatted: $abs_path")
            else
                println("⚠️  Formatting completed but check for errors: $abs_path")
            end

            changes_made || format_result
            """

            execute_repllike(
                code;
                description = "[Formatting code at: $abs_path]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error formatting code: $e"
        end
    end
)

# Optional linting tool (requires Aqua.jl)
lint_tool = @mcp_tool(
    :lint_package,
    "Run Aqua.jl quality assurance tests on a package.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "package_name" => Dict(
                "type" => "string",
                "description" => "Package name to test (defaults to current project)",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => [],
    ),
    function (args)
        try
            # Check if Aqua is available
            if !isdefined(Main, :Aqua)
                try
                    @eval Main using Aqua
                catch
                    return "Error: Aqua.jl is not installed. Install it with: using Pkg; Pkg.add(\"Aqua\")"
                end
            end

            pkg_name = get(args, "package_name", nothing)
            ses = get(args, "session", "")

            if pkg_name === nothing
                # Use current project
                code = """
                using Aqua
                # Get current project name
                project_file = Base.active_project()
                if project_file === nothing
                    println("❌ No active project found")
                else
                    using Pkg
                    proj = Pkg.TOML.parsefile(project_file)
                    pkg_name = get(proj, "name", nothing)
                    if pkg_name === nothing
                        println("❌ No package name found in Project.toml")
                    else
                        println("Running Aqua tests for package: \$pkg_name")
                        # Load the package
                        @eval using \$(Symbol(pkg_name))
                        # Run Aqua tests
                        Aqua.test_all(\$(Symbol(pkg_name)))
                        println("✅ All Aqua tests passed for \$pkg_name")
                    end
                end
                """
            else
                # Construct code with package name - interpolate at this level
                pkg_symbol = Symbol(pkg_name)
                code = """
                using Aqua
                @eval using $pkg_symbol
                println("Running Aqua tests for package: $pkg_name")
                Aqua.test_all($pkg_symbol)
                println("✅ All Aqua tests passed for $pkg_name")
                """
            end

            execute_repllike(
                code;
                description = "[Running Aqua quality tests]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error running Aqua tests: $e"
        end
    end
)

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

            # Use VS Code URI with line and column position
            # Format: vscode://file/path/to/file:line:column
            vscode_uri = "vscode://file$(abs_path):$(line):$(column)"
            trigger_vscode_uri(vscode_uri)

            return "Navigated to $abs_path:$line:$column"
        catch e
            return "Error: $e"
        end
    end
)

# High-level debugging workflow tools
open_and_breakpoint_tool = @mcp_tool(
    :open_file_and_set_breakpoint,
    "Open a file in VS Code and set a breakpoint at a specific line. Requires VS Code.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "file_path" => Dict(
                "type" => "string",
                "description" => "Absolute path to the file",
            ),
            "line" => Dict(
                "type" => "integer",
                "description" => "Line number for breakpoint (optional)",
            ),
        ),
        "required" => ["file_path"],
    ),
    function (args)
        try
            file_path = get(args, "file_path", "")
            line = get(args, "line", nothing)

            if isempty(file_path)
                return "Error: file_path is required"
            end

            # Make sure it's an absolute path
            abs_path = isabspath(file_path) ? file_path : joinpath(pwd(), file_path)

            if !isfile(abs_path)
                return "Error: File does not exist: $abs_path"
            end

            # Open the file using vscode.open command
            uri = "file://$abs_path"
            args_json = JSON.json([uri])
            args_encoded = HTTP.URIs.escapeuri(args_json)
            open_uri = build_vscode_uri("vscode.open"; args = args_encoded)
            trigger_vscode_uri(open_uri)

            sleep(0.5)  # Give VS Code time to open the file

            # Navigate to line if specified
            if line !== nothing
                goto_uri = build_vscode_uri("workbench.action.gotoLine")
                trigger_vscode_uri(goto_uri)
                sleep(0.3)
            end

            # Set breakpoint
            bp_uri = build_vscode_uri("editor.debug.action.toggleBreakpoint")
            trigger_vscode_uri(bp_uri)

            result = "Opened $abs_path"
            if line !== nothing
                result *= " and navigated to line $line"
            end
            result *= ", breakpoint set"

            return result
        catch e
            return "Error: $e"
        end
    end
)

start_debug_session_tool = @mcp_tool(
    :start_debug_session,
    "Start a debugging session in VS Code. Opens debug view and begins debugging. Requires VS Code.",
    Dict("type" => "object", "properties" => Dict(), "required" => []),
    function (args)
        try
            # Open debug view
            view_uri = build_vscode_uri("workbench.view.debug")
            trigger_vscode_uri(view_uri)

            sleep(0.3)

            # Start debugging
            start_uri = build_vscode_uri("workbench.action.debug.start")
            trigger_vscode_uri(start_uri)

            return "Debug session started. Use stepping commands to navigate through code."
        catch e
            return "Error starting debug session: $e"
        end
    end
)

add_watch_expression_tool = @mcp_tool(
    :add_watch_expression,
    "Add a watch expression to monitor during debugging. Requires VS Code with active debug session.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "expression" =>
                Dict("type" => "string", "description" => "Expression to watch"),
        ),
        "required" => ["expression"],
    ),
    function (args)
        try
            expression = get(args, "expression", "")

            if isempty(expression)
                return "Error: expression is required"
            end

            # Focus watch view first
            watch_uri = build_vscode_uri("workbench.debug.action.focusWatchView")
            trigger_vscode_uri(watch_uri)

            sleep(0.2)

            # Add watch expression
            add_uri = build_vscode_uri("workbench.action.debug.addWatch")
            trigger_vscode_uri(add_uri)

            return "Watch expression dialog opened for: $expression (user will need to enter it)"
        catch e
            return "Error adding watch expression: $e"
        end
    end
)

copy_debug_value_tool = @mcp_tool(
    :copy_debug_value,
    "Copy a debug variable value to clipboard. Read with pbpaste (macOS), wl-paste (Wayland), or xclip (X11). Requires VS Code with active debug session.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "view" => Dict(
                "type" => "string",
                "description" => "Debug view to focus: 'variables' or 'watch'",
                "enum" => ["variables", "watch"],
                "default" => "variables",
            ),
        ),
        "required" => [],
    ),
    function (args)
        try
            view = get(args, "view", "variables")

            # Focus the appropriate debug view
            if view == "watch"
                focus_uri = build_vscode_uri("workbench.debug.action.focusWatchView")
            else
                focus_uri = build_vscode_uri("workbench.debug.action.focusVariablesView")
            end
            trigger_vscode_uri(focus_uri)

            sleep(0.2)

            # Copy the selected value
            copy_uri = build_vscode_uri("workbench.action.debug.copyValue")
            trigger_vscode_uri(copy_uri)

            clipboard_cmd = if Sys.isapple()
                "pbpaste"
            elseif Sys.islinux()
                if haskey(ENV, "WAYLAND_DISPLAY")
                    "wl-paste"
                else
                    "xclip -selection clipboard -o (or xsel --clipboard --output)"
                end
            elseif Sys.iswindows()
                "powershell Get-Clipboard"
            else
                "appropriate clipboard command for your OS"
            end

            return """Value copied to clipboard from $(view) view.
To read the value, run in terminal: $clipboard_cmd
Note: Make sure a variable is selected/focused in the debug view before copying."""
        catch e
            return "Error copying debug value: $e"
        end
    end
)

# Enhanced debugging tools using bidirectional communication
debug_step_over_tool = @mcp_tool(
    :debug_step_over,
    "Step over the current line in the debugger. Requires VS Code with active debug session.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "wait_for_response" => Dict(
                "type" => "boolean",
                "description" => "Wait for command completion (default: false)",
                "default" => false,
            ),
        ),
        "required" => [],
    ),
    args -> vscode_debug_command(
        "workbench.action.debug.stepOver",
        "Stepped over current line";
        args = args,
    )
)

debug_step_into_tool = @mcp_tool(
    :debug_step_into,
    "Step into a function call in the debugger. Requires VS Code with active debug session.",
    Dict("type" => "object", "properties" => Dict(), "required" => []),
    args -> vscode_debug_command(
        "workbench.action.debug.stepInto",
        "Stepped into function",
    )
)

debug_step_out_tool = @mcp_tool(
    :debug_step_out,
    "Step out of the current function in the debugger. Requires VS Code with active debug session.",
    Dict("type" => "object", "properties" => Dict(), "required" => []),
    args -> vscode_debug_command(
        "workbench.action.debug.stepOut",
        "Stepped out of current function",
    )
)

debug_continue_tool = @mcp_tool(
    :debug_continue,
    "Continue execution until next breakpoint or completion. Requires VS Code with active debug session.",
    Dict("type" => "object", "properties" => Dict(), "required" => []),
    args ->
        vscode_debug_command("workbench.action.debug.continue", "Continued execution")
)

debug_stop_tool = @mcp_tool(
    :debug_stop,
    "Stop the current debug session. Requires VS Code.",
    Dict("type" => "object", "properties" => Dict(), "required" => []),
    args ->
        vscode_debug_command("workbench.action.debug.stop", "Debug session stopped")
)

# Package management tools
pkg_add_tool = @mcp_tool(
    :pkg_add,
    "Add Julia packages to the current environment (modifies Project.toml).",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "packages" => Dict(
                "type" => "array",
                "description" => "Array of package names to add",
                "items" => Dict("type" => "string"),
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["packages"],
    ),
    args ->
        pkg_operation_tool("add", "Added", args; session = get(args, "session", ""))
)

pkg_rm_tool = @mcp_tool(
    :pkg_rm,
    "Remove Julia packages from the current environment.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "packages" => Dict(
                "type" => "array",
                "description" => "Array of package names to remove",
                "items" => Dict("type" => "string"),
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["packages"],
    ),
    args ->
        pkg_operation_tool("rm", "Removed", args; session = get(args, "session", ""))
)

"""
    _project_has_retest(project_path::String) -> Bool

Check whether a project has ReTest as a dependency by reading its TOML files.
Checks both `test/Project.toml` (test-specific deps) and `Project.toml` (extras).
"""
function _project_has_retest(project_path::String)::Bool
    for toml_path in [
        joinpath(project_path, "test", "Project.toml"),
        joinpath(project_path, "Project.toml"),
    ]
        isfile(toml_path) || continue
        try
            toml = TOML.parsefile(toml_path)
            for key in ("deps", "extras")
                haskey(get(toml, key, Dict()), "ReTest") && return true
            end
        catch
        end
    end
    return false
end

run_tests_tool = @mcp_tool(
    :run_tests,
    """Run tests and optionally generate coverage reports.

Spawns a subprocess with correct test environment. Streams results in real-time.
Pattern uses ReTest regex syntax to filter tests.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "pattern" => Dict(
                "type" => "string",
                "description" => "Optional test regex to filter tests (ReTest pattern syntax, e.g., 'security' or 'generate'). Leave empty to run all tests.",
            ),
            "coverage" => Dict(
                "type" => "boolean",
                "description" => "Enable coverage collection and reporting (default: false)",
                "default" => false,
            ),
            "verbose" => Dict(
                "type" => "integer",
                "description" => "Enable verbose test output (default: false)",
                "default" => 1,
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Required when multiple sessions are connected.",
            ),
        ),
        "required" => [],
    ),
    function (args)
        pattern = get(args, "pattern", "")
        coverage_enabled = get(args, "coverage", false)
        verbose_arg = get(args, "verbose", 1)
        verbose = verbose_arg isa Int ? verbose_arg : parse(Int, verbose_arg)
        session = get(args, "session", "")
        on_progress = get(args, "_on_progress", nothing)

        # Normalize pattern
        if pattern == ".*"
            pattern = ""
        end

        if !GATE_MODE[]
            return "Error: run_tests requires gate mode. Start a gate REPL with Gate.serve()."
        end

        conn, err = _resolve_gate_conn(session)
        err !== nothing && return err

        # Derive project root — conn.project_path may point to a subdirectory
        # (e.g. test/) if the user activated a different env on the session.
        project_path = conn.project_path
        runtests_path = joinpath(project_path, "test", "runtests.jl")
        if !isfile(runtests_path)
            # Try parent directory (common when project_path is test/ subdir)
            parent = dirname(project_path)
            parent_runtests = joinpath(parent, "test", "runtests.jl")
            if isfile(parent_runtests)
                project_path = parent
                runtests_path = parent_runtests
            else
                return "Error: No test/runtests.jl found in $project_path. Create a test file first."
            end
        end

        on_progress !== nothing &&
            on_progress("Spawning test subprocess for $(basename(project_path))...")

        # Spawn ephemeral test subprocess
        run = spawn_test_run(
            project_path;
            pattern = pattern,
            verbose = verbose,
            on_progress = on_progress,
        )

        # Push to TUI buffer so the Tests tab picks it up
        _push_test_update!(:update, run)

        # Poll for completion with inflight progress
        while run.status == RUN_RUNNING
            sleep(0.5)
            if on_progress !== nothing
                n_lines = length(run.raw_output)
                on_progress(
                    "Running tests... $(run.total_pass) passed, $(run.total_fail) failed ($n_lines lines)",
                )
            end
        end

        # Return focused summary (not raw output dump)
        return format_test_summary(run)
    end
)

stress_test_tool = @mcp_tool(
    :stress_test,
    """Run a stress test by spawning concurrent simulated MCP agents.

Launches N agents that each execute the given Julia code via `ex`. Returns per-agent results, timing stats, and success/failure counts.

# Examples

```julia
{"num_agents": 3, "code": "sleep(1); 42"}
{"num_agents": 10, "code": "sum(1:1000)", "stagger": 0.1}
{"num_agents": 5, "code": "sleep(rand())", "timeout": 60}
```
""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "code" => Dict(
                "type" => "string",
                "description" => "Julia code each agent executes (default: \"sleep(1); 42\")",
            ),
            "num_agents" => Dict(
                "type" => "integer",
                "description" => "Number of concurrent agents to spawn, 1-100 (default: 5)",
            ),
            "stagger" => Dict(
                "type" => "number",
                "description" => "Delay in seconds between agent launches (default: 0.0)",
            ),
            "timeout" => Dict(
                "type" => "integer",
                "description" => "Per-agent timeout in seconds (default: 30)",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Target session key (auto-detects if one session connected)",
            ),
        ),
        "required" => [],
    ),
    function (args)
        code = get(args, "code", "sleep(1); 42")
        num_agents = get(args, "num_agents", 5)
        num_agents isa AbstractString && (num_agents = parse(Int, num_agents))
        stagger = get(args, "stagger", 0.0)
        stagger isa AbstractString && (stagger = parse(Float64, stagger))
        timeout = get(args, "timeout", 30)
        timeout isa AbstractString && (timeout = parse(Int, timeout))
        session = get(args, "session", "")

        on_progress = get(args, "_on_progress", nothing)

        # Validate
        num_agents = clamp(num_agents, 1, 100)
        stagger = max(0.0, stagger)
        timeout = clamp(timeout, 1, 600)

        # Resolve session
        mgr = GATE_CONN_MGR[]
        if mgr === nothing
            return "ERROR: No ConnectionManager available. Is the TUI running with gate mode enabled?"
        end

        sess_key = if isempty(session)
            conns = connected_sessions(mgr)
            if length(conns) == 0
                return "ERROR: No REPL sessions connected. Start a gate in your Julia REPL:\n  Gate.serve()"
            elseif length(conns) == 1
                short_key(conns[1])
            else
                available = join(["$(short_key(c)) ($(c.name))" for c in conns], ", ")
                return "ERROR: Multiple sessions connected. Specify `session` parameter. Available: $available"
            end
        else
            # Verify the session exists
            conn = get_connection_by_key(mgr, session)
            if conn === nothing
                conns = connected_sessions(mgr)
                available = join(["$(short_key(c)) ($(c.name))" for c in conns], ", ")
                return "ERROR: No session matched '$(session)'. Available: $available"
            end
            short_key(conn)
        end

        port = GATE_PORT[]

        on_progress !== nothing && on_progress(
            "Launching stress test: $num_agents agents, code=$(repr(code))",
        )

        # Write script and spawn subprocess
        script_path = _write_stress_script()
        project_dir = pkgdir(@__MODULE__)
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project_dir $script_path $port $sess_key $code $num_agents $stagger $timeout`

        output_lines = String[]
        t_start = time()

        try
            process = open(cmd, "r")
            while !eof(process)
                line = readline(process; keep = false)
                isempty(line) && continue
                push!(output_lines, line)
                # Stream progress for each meaningful line
                if on_progress !== nothing
                    on_progress(line)
                end
            end
            try
                wait(process)
            catch
            end
        catch e
            push!(output_lines, "ERROR agent=0 elapsed=0.0 message=$(sprint(showerror, e))")
        end

        total_wall_time = time() - t_start

        # Write results file
        result_file = _write_stress_results_to_file(
            output_lines,
            code,
            sess_key,
            num_agents,
            stagger,
            timeout,
        )

        # Parse and format summary
        agents = _parse_stress_results(output_lines)
        return _format_stress_summary(
            agents,
            code,
            sess_key,
            num_agents,
            Float64(stagger),
            timeout,
            total_wall_time,
            result_file,
        )
    end
)

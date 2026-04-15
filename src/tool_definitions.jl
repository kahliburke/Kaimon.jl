# ============================================================================
# Helper Functions for Deduplication
# ============================================================================

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
    "Check if the MCP server is responsive and list connected Julia sessions.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "extended" => Dict(
                "type" => "boolean",
                "description" => "If true, return comprehensive server health stats: uptime, tool execution counts, error summary, memory usage.",
            ),
        ),
        "required" => [],
    ),
    args -> begin
        extended = let v = get(args, "extended", false)
            v === true || v == "true" || v == "1"
        end
        status = "✓ MCP Server is healthy and responsive\n"

        # Connected Julia sessions
        mgr = GATE_CONN_MGR[]
        if mgr !== nothing
            all_conns = lock(mgr.lock) do
                copy(mgr.connections)
            end
            # Separate extension sessions from regular sessions
            ext_conns = filter(c -> c.spawned_by == "extension", all_conns)
            user_conns = filter(c -> c.spawned_by != "extension", all_conns)
            connected_count = count(c -> c.status == :connected, user_conns)
            # Sort by connected_at descending (newest first)
            sort!(user_conns; by=c -> c.connected_at, rev=true)
            status *= "\n\nSessions: $(connected_count) connected / $(length(user_conns)) total"
            for conn in user_conns
                key = short_key(conn)
                dname = isempty(conn.display_name) ? conn.name : conn.display_name
                icon =
                    conn.status == :connected ? "●" :
                    conn.status == :evaluating ? "◐" :
                    conn.status == :stalled ? "◑" :
                    conn.status == :connecting ? "◐" : "○"
                ntools = length(conn.session_tools)
                tools_info = ntools > 0 ? ", $(ntools) tools" : ""
                # Uptime from connected_at
                uptime_secs = round(Int, Dates.value(now() - conn.connected_at) / 1000)
                uptime_str = if uptime_secs < 60
                    "$(uptime_secs)s"
                elseif uptime_secs < 3600
                    "$(uptime_secs ÷ 60)m"
                else
                    "$(uptime_secs ÷ 3600)h $(uptime_secs % 3600 ÷ 60)m"
                end
                extra = if conn.status == :stalled
                    ago = round(Int, Dates.value(now() - conn.last_seen) / 1000)
                    diag = conn.diagnostics
                    if diag !== nothing
                        ", last seen $(ago)s ago, $(round(diag.rss_mb; digits=0))MB/$(round(diag.cpu_pct; digits=0))% CPU"
                    else
                        ", last seen $(ago)s ago"
                    end
                elseif conn.status == :evaluating || conn.eval_state[] != EVAL_IDLE
                    ", busy"
                elseif conn.spawned_by == "agent"
                    ", agent-spawned"
                else
                    ", free"
                end
                status *= "\n  $icon $key $dname ($(conn.status), up $(uptime_str), PID $(conn.pid)$tools_info$extra)"
            end
            # Extension session summary (internal only, not addressable via tools)
            if !isempty(ext_conns)
                active_ext = filter(c -> c.status == :connected || c.status == :evaluating, ext_conns)
                names = [isempty(c.namespace) ? c.display_name : c.namespace for c in active_ext]
                status *= "\nExtensions (internal, not for agent use): $(length(active_ext)) active ($(join(names, ", ")))"
            end
        end

        if extended
            # Server uptime
            uptime_ms = Dates.value(Dates.now() - _SERVER_START_TIME)
            uptime_str = let h = uptime_ms ÷ 3_600_000,
                m = (uptime_ms % 3_600_000) ÷ 60_000,
                s = (uptime_ms % 60_000) ÷ 1000

                h > 0 ? "$(h)h $(m)m $(s)s" : m > 0 ? "$(m)m $(s)s" : "$(s)s"
            end
            status *= "\n\nServer uptime: $uptime_str"
            status *= "\nStarted: $(Dates.format(_SERVER_START_TIME, "yyyy-mm-dd HH:MM:SS"))"
            status *= "\nJulia v$(VERSION)  PID: $(getpid())  Threads: $(Threads.nthreads())"

            # Memory
            used_gb = round((Sys.total_memory() - Sys.free_memory()) / 1024^3, digits = 1)
            total_gb = round(Sys.total_memory() / 1024^3, digits = 1)
            status *= "\nMemory: $(used_gb) GB used / $(total_gb) GB total"

            # Tool execution stats (from in-memory ring buffer, TUI mode only)
            if GATE_MODE[]
                results = lock(_TUI_TOOL_RESULTS_LOCK) do
                    copy(_TUI_TOOL_RESULTS_BUFFER)
                end
                total = length(results)
                if total > 0
                    n_ok = count(r -> r.success, results)
                    n_err = total - n_ok
                    err_rate = round(n_err / total * 100, digits = 1)
                    status *= "\n\nTool executions (last $total in buffer):"
                    status *= "\n  Success: $n_ok  Error: $n_err  Error rate: $(err_rate)%"
                    t_ok = _LAST_TOOL_SUCCESS[]
                    t_err = _LAST_TOOL_ERROR[]
                    t_ok > 0 && (status *= "  Last success: $(round(Int, time() - t_ok))s ago")
                    if n_err > 0 && t_err > 0
                        status *= "\n  Last error: $(round(Int, time() - t_err))s ago"
                    end

                    # Top 5 tools by call count
                    counts = Dict{String,Int}()
                    for r in results
                        counts[r.tool_name] = get(counts, r.tool_name, 0) + 1
                    end
                    top = first(sort(collect(counts), by = last, rev = true), 5)
                    status *= "\n  Top tools: " * join(["$(t) ($(c))" for (t, c) in top], ", ")
                end

                # Recent server errors from log buffer
                errs = lock(_TUI_LOG_LOCK) do
                    filter(e -> e.level == :error, _TUI_LOG_BUFFER)
                end
                if !isempty(errs)
                    status *= "\n\nServer errors in log buffer: $(length(errs))"
                    last_e = errs[end]
                    ts = Dates.format(last_e.timestamp, "HH:MM:SS")
                    status *= "\n  Last: [$ts] $(first(last_e.message, 100))"
                end
            end
        end

        return status
    end
)

server_log_tool = @mcp_tool(
    :server_log,
    "Retrieve Kaimon server log entries from the in-memory ring buffer (TUI mode) or log file.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "lines" => Dict(
                "type" => "integer",
                "description" => "Number of recent log lines to return (default: 50, max: 500)",
            ),
            "level" => Dict(
                "type" => "string",
                "description" => "Filter by log level: 'all' (default), 'warn', 'error'",
            ),
            "since" => Dict(
                "type" => "string",
                "description" => "Return only entries at or after this timestamp (ISO 8601, e.g. '2025-03-01T12:00:00' or '2025-03-01 12:00:00')",
            ),
        ),
        "required" => [],
    ),
    args -> begin
        limit = let v = get(args, "lines", 50)
            clamp(something(tryparse(Int, string(v)), 50), 1, 500)
        end
        level_filter = lowercase(strip(string(get(args, "level", "all"))))
        since_str = strip(string(get(args, "since", "")))

        since_dt = if isempty(since_str)
            nothing
        else
            ts = nothing
            for fmt in ("yyyy-mm-ddTHH:MM:SS", "yyyy-mm-dd HH:MM:SS", "yyyy-mm-dd")
                try
                    ts = DateTime(since_str, fmt)
                    break
                catch
                end
            end
            ts
        end

        _apply_level_filter(entries, lf) = if lf in ("warn", "warning")
            filter(e -> e.level in (:warn, :error), entries)
        elseif lf == "error"
            filter(e -> e.level == :error, entries)
        else
            entries
        end

        _format_entry(e::ServerLogEntry) =
            "$(Dates.format(e.timestamp, "yyyy-mm-dd HH:MM:SS")) [$(rpad(uppercase(string(e.level)),5))] $(e.message)"

        log_path = _TUI_LOG_PATH
        isfile(log_path) || return "No log file found at $log_path"

        all_lines = try
            readlines(log_path)
        catch e
            return "Failed to read log file: $e"
        end

        # Filter by since (log line format: "YYYY-MM-DD HH:MM:SS [LEVEL] msg")
        if since_dt !== nothing
            filter!(all_lines) do line
                length(line) < 19 && return true
                try
                    DateTime(line[1:19], "yyyy-mm-dd HH:MM:SS") >= since_dt
                catch
                    true
                end
            end
        end

        # Filter by level
        if level_filter in ("warn", "warning")
            filter!(l -> contains(l, "[WARN ") || contains(l, "[ERROR"), all_lines)
        elseif level_filter == "error"
            filter!(l -> contains(l, "[ERROR"), all_lines)
        end

        length(all_lines) > limit && (all_lines = all_lines[end-limit+1:end])
        isempty(all_lines) && return "No log entries found matching the specified criteria."
        return join(all_lines, "\n")
    end
)

tui_screenshot_tool = @mcp_tool(
    :tui_screenshot,
    "Capture a text screenshot of the Kaimon TUI. Returns the current rendered view as plain text, including borders, status indicators, and layout. Updated every ~1 second. Useful for analyzing whitespace usage, widget layout, and visual appearance.",
    Dict(
        "type" => "object",
        "properties" => Dict(),
        "required" => [],
    ),
    args -> begin
        text = TUI_LAST_FRAME[]
        isempty(text) && return "No TUI frame captured yet (TUI may not be running)"
        return text
    end,
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
s=true (rare): suppresses agent> prompt and REPL echo for large outputs.
mt=true: routes eval through the REPL backend (thread 1). ALWAYS use mt=true for GLMakie, GLFW, or any GPU/OpenGL code — including `using GLMakie`, `display(fig)`, and plot creation. Without it, these will fail with ThreadAssertionError.""",
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
            "mt" => Dict(
                "type" => "boolean",
                "description" => "Main-thread mode: routes eval through the REPL backend (thread 1). Required for GLMakie/GLFW and other libraries that need the main thread. Default: false.",
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
            main_thread = get(args, "mt", false)

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
                on_progress = get(args, "_on_progress", nothing)
                Base.invokelatest(
                    execute_via_gate_streaming,
                    expr_str;
                    quiet = quiet,
                    silent = silent,
                    max_output = max_output,
                    session = ses,
                    main_thread = main_thread,
                    on_progress = on_progress,
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
                if new_conn !== nothing && new_conn.status in (:connected, :evaluating)
                    mgr.on_sessions_changed = old_cb
                    return "Session $key restarted. Fresh Julia state. Revise active."
                end
            end
            mgr.on_sessions_changed = old_cb
            return "Restart sent to $key but timed out waiting for reconnection (60s). The session may still be starting — try again shortly."
        elseif command == "shutdown"
            ok = send_shutdown!(conn)
            disconnect!(conn)
            return ok ? "Session $key shut down." : "Error: Failed to reach session $key."
        else
            return "Error: Invalid command '$command'"
        end
    end
)

connect_tcp_tool = @mcp_tool(
    :connect_tcp,
    """Connect to a remote Julia gate session over TCP.

Use this to connect to a gate started with `Gate.serve(mode=:tcp, port=9876)` on
a remote (or local) machine. The PUB stream endpoint is resolved from the gate's handshake.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "host" => Dict(
                "type" => "string",
                "description" => "Hostname or IP address of the remote gate",
            ),
            "port" => Dict(
                "type" => "integer",
                "description" => "Port number (default 9876)",
                "default" => 9876,
            ),
            "name" => Dict(
                "type" => "string",
                "description" => "Optional display name for the session",
            ),
            "token" => Dict(
                "type" => "string",
                "description" => "Auth token for the remote gate (falls back to KAIMON_GATE_TOKEN env var or security config)",
            ),
            "stream_port" => Dict(
                "type" => "integer",
                "description" => "Local port for the PUB stream socket (for SSH tunnels where the PUB port differs locally). 0 = auto-discover from pong.",
            ),
        ),
        "required" => ["host"],
    ),
    (args) -> begin
        host = get(args, "host", "")
        isempty(host) && return "Error: host is required"
        port = get(args, "port", 9876)
        port = port isa Number ? Int(port) : tryparse(Int, string(port))
        port === nothing && return "Error: invalid port"
        name = get(args, "name", "")
        token = get(args, "token", "")
        stream_port = Int(get(args, "stream_port", 0))

        mgr = GATE_CONN_MGR[]
        mgr === nothing && return "Error: No ConnectionManager available"

        conn = try
            connect_tcp!(mgr, host, port; name, token, stream_port)
        catch e
            return "Error: $(sprint(showerror, e))"
        end

        key = short_key(conn)
        "Connected to TCP gate at $host:$port (session key: $key)"
    end
)

start_session_tool = @mcp_tool(
    :start_session,
    """Spawn a new Julia session for a project.

Starts a background Julia process that activates the given project, runs
Pkg.instantiate, and connects back as a gate session. The project must be
in the allowed-projects list (configured in the TUI Config tab or
~/.config/kaimon/projects.json).

Returns the 8-character session key on success, which can be used with
other tools (ex, run_tests, etc.) via the `session` parameter.

Call with no `project_path` to list allowed projects and their status.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "project_path" => Dict(
                "type" => "string",
                "description" => "Absolute path to the Julia project directory (must contain Project.toml). Omit to list allowed projects.",
            ),
            "name" => Dict(
                "type" => "string",
                "description" => "Optional display name for the session (defaults to project directory name)",
            ),
        ),
        "required" => [],
    ),
    (args) -> begin
        raw_path = get(args, "project_path", "")
        name = get(args, "name", "")

        # No path → list allowed projects
        if isempty(raw_path)
            entries = load_projects_config()
            isempty(entries) && return "No allowed projects configured. Add projects via the TUI Config tab [p] or manually to ~/.config/kaimon/projects.json"
            managed = get_managed_sessions()
            lines = String["Allowed projects:"]
            for entry in entries
                status = if !entry.enabled
                    "disabled"
                else
                    ms = find_managed_session(entry.project_path)
                    if ms !== nothing && ms.status == :running && !isempty(ms.session_key)
                        "running (session: $(ms.session_key))"
                    else
                        "ready"
                    end
                end
                push!(lines, "  $(entry.project_path)  [$status]")
            end
            return join(lines, "\n")
        end

        # Normalize path
        path = normalize_path(raw_path)

        # Validate directory and Project.toml
        isdir(path) || return "Error: Directory does not exist: $path"
        isfile(joinpath(path, "Project.toml")) ||
            return "Error: No Project.toml found in $path"

        # Check allowed list
        if !is_project_allowed(path)
            return "Error: Project not in allowed list. Add it via the TUI Config tab [p] or manually to ~/.config/kaimon/projects.json"
        end

        # Check for existing running session for the same project
        existing = find_managed_session(path)
        if existing !== nothing && existing.status == :running && !isempty(existing.session_key)
            return "Session already running for this project. Session key: $(existing.session_key)"
        end

        # If there's a crashed/stopped session for this path, remove it
        if existing !== nothing
            lock(MANAGED_SESSIONS_LOCK) do
                filter!(ms -> ms !== existing, MANAGED_SESSIONS)
            end
        end

        # Create and spawn
        ms = ManagedSession(path; name = isempty(name) ? "" : name)
        lock(MANAGED_SESSIONS_LOCK) do
            push!(MANAGED_SESSIONS, ms)
        end
        spawn_session!(ms)

        # Poll for connection (Pkg.instantiate can be slow)
        mgr = GATE_CONN_MGR[]
        timeout = 120.0
        start = time()
        while time() - start < timeout
            sleep(2.0)
            if mgr !== nothing
                _monitor_managed_sessions!(mgr)
            end
            if ms.status == :running && !isempty(ms.session_key)
                return "Session started. Session key: $(ms.session_key)"
            end
            if ms.status == :crashed
                err_msg = isempty(ms.error_log) ? "unknown error" : last(ms.error_log)
                return "Error: Session failed to start — $err_msg\nCheck log: $(ms.log_file)"
            end
        end

        return "Error: Timed out waiting for session to connect ($(Int(timeout))s). The process may still be starting — check log: $(ms.log_file)"
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
Pattern uses ReTest regex syntax to filter tests.

Provide either `project_path` (absolute path to the project) or `session`
(gate session key) to identify the project. If neither is given and only
one session is connected, that session's project is used.""",
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
            "project_path" => Dict(
                "type" => "string",
                "description" => "Absolute path to the project directory (must contain Project.toml and test/runtests.jl). Use this instead of session if no gate session is running for the project.",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Used to resolve project path from a connected gate session.",
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
        explicit_path = get(args, "project_path", "")
        on_progress = get(args, "_on_progress", nothing)

        # Normalize pattern
        if pattern == ".*"
            pattern = ""
        end

        # Resolve project path: explicit path > session > single connected session
        project_path = if !isempty(explicit_path)
            isdir(explicit_path) || return "Error: project_path not found: $explicit_path"
            explicit_path
        else
            if !GATE_MODE[]
                return "Error: Provide project_path or start a gate session."
            end
            conn, err = _resolve_gate_conn(session)
            err !== nothing && return err
            conn.project_path
        end
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
        run = spawn_test_run(project_path; pattern = pattern, verbose = verbose)

        # Push to TUI buffer so the Tests tab picks it up
        _push_test_update!(:update, run)

        # Poll for completion — timeout after 10 min to prevent hanging MCP calls
        deadline = time() + 600.0
        while run.status == RUN_RUNNING
            sleep(0.5)
            if on_progress !== nothing
                # total_pass/total_fail are only set when the top-level testset
                # finishes; during the run, accumulate from individual results.
                p = run.total_pass > 0 ? run.total_pass : sum((r.pass_count for r in run.results), init=0)
                f = run.total_fail > 0 ? run.total_fail : sum((r.fail_count for r in run.results), init=0)
                n_sets = length(run.results)
                on_progress(
                    "$p passed, $f failed ($n_sets testsets done)",
                )
            end
            if time() > deadline
                cancel_test_run!(run)
                return "Test run timed out after 10 minutes.\n\n$(format_test_summary(run))"
            end
        end

        # The runner marks status on TEST_RUNNER:DONE before the reader task
        # necessarily finishes parsing the final summary block.
        reader_deadline = time() + 5.0
        while !run.reader_done && time() < reader_deadline
            sleep(0.05)
        end

        # If the process has exited but only summary-table output was emitted,
        # parse the buffered raw output one last time before formatting.
        if run.process !== nothing
            try
                wait(run.process)
            catch
            end
        end
        _parse_raw_summary!(run)

        # Return focused summary (not raw output dump)
        return format_test_summary(run)
    end
)

extension_info_tool = @mcp_tool(
    :extension_info,
    """Get information about loaded Kaimon extensions and their tools.

No arguments: list all extensions with status and tool names.
With name: detailed view of one extension including per-tool documentation and parameter schemas.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "name" => Dict(
                "type" => "string",
                "description" => "Extension namespace to get details for. Omit to list all extensions.",
            ),
        ),
        "required" => [],
    ),
    args -> begin
        extensions = get_managed_extensions()
        conn_mgr = GATE_CONN_MGR[]
        name = get(args, "name", nothing)

        if name === nothing
            # List all extensions
            if isempty(extensions)
                return "No extensions configured."
            end

            lines = String[]
            for ext in extensions
                ns = ext.config.manifest.namespace
                desc = ext.config.manifest.description
                status_icon = ext.status == :running ? "●" :
                              ext.status == :crashed ? "●" :
                              "○"

                # Get tool names if connected
                tool_names = String[]
                if conn_mgr !== nothing
                    conn = _find_ext_connection(ext, conn_mgr)
                    if conn !== nothing && !isempty(conn.session_tools)
                        for tool in conn.session_tools
                            push!(tool_names, get(tool, "name", "?"))
                        end
                    end
                end

                line = "$status_icon $ns ($(ext.status))"
                !isempty(desc) && (line *= " — $desc")
                push!(lines, line)
                if !isempty(tool_names)
                    push!(lines, "  Tools: $(join(tool_names, ", "))")
                end
            end
            return join(lines, "\n")
        else
            # Detail view for a specific extension
            idx = findfirst(e -> e.config.manifest.namespace == name, extensions)
            if idx === nothing
                available = join([e.config.manifest.namespace for e in extensions], ", ")
                return "Error: No extension '$(name)' found. Available: $available"
            end

            ext = extensions[idx]
            manifest = ext.config.manifest
            entry = ext.config.entry

            # Status info
            status_icon = ext.status == :running ? "●" :
                          ext.status == :crashed ? "●" :
                          "○"
            pid_str = if ext.process !== nothing && Base.process_running(ext.process)
                string(getpid(ext.process))
            else
                "—"
            end
            uptime_str = ext.status == :running ? format_uptime(time() - ext.started_at) : "—"

            lines = String[]
            push!(lines, "$(manifest.namespace) — $(manifest.module_name)")
            push!(lines, "Status: $status_icon $(ext.status) (PID $pid_str, uptime $uptime_str)")
            !isempty(manifest.description) && push!(lines, "Description: $(manifest.description)")
            push!(lines, "Project: $(entry.project_path)")

            # Tool documentation
            conn = conn_mgr !== nothing ? _find_ext_connection(ext, conn_mgr) : nothing
            if conn !== nothing && !isempty(conn.session_tools)
                tools = conn.session_tools
                push!(lines, "")
                push!(lines, "Tools ($(length(tools))):")

                for tool in tools
                    tname = get(tool, "name", "unknown")
                    tdesc = get(tool, "description", "")
                    targs = get(tool, "arguments", Dict{String,Any}[])

                    # Build signature
                    param_names = String[]
                    for arg in targs
                        push!(param_names, get(arg, "name", "?"))
                    end
                    sig = isempty(param_names) ? "" : "($(join(param_names, ", ")))"

                    push!(lines, "")
                    push!(lines, "  $(manifest.namespace).$tname$sig")

                    # Description (first paragraph only for readability)
                    if !isempty(tdesc)
                        first_para = first(split(tdesc, "\n\n"))
                        push!(lines, "    $first_para")
                    end

                    # Parameters
                    if !isempty(targs)
                        push!(lines, "    Parameters:")
                        for arg in targs
                            arg_name = get(arg, "name", "?")
                            type_meta = get(arg, "type_meta", nothing)
                            arg_type = if type_meta isa Dict
                                get(type_meta, "julia_type", "Any")
                            elseif type_meta isa String
                                type_meta
                            else
                                "Any"
                            end
                            required = get(arg, "required", false)
                            req = required ? " (required)" : ""
                            push!(lines, "      $arg_name: $arg_type$req")
                        end
                    end
                end
            elseif conn !== nothing
                push!(lines, "\nTools: (none registered)")
            else
                push!(lines, "\nTools: waiting for gate connection...")
            end

            return join(lines, "\n")
        end
    end
)

stress_test_tool = @mcp_tool(
    :stress_test,
    """Run a stress test by spawning concurrent simulated MCP agents.

Launches N agents that each execute the given Julia code via `ex`, or call an arbitrary
MCP gate tool. Returns per-agent results, timing stats, and success/failure counts.

Use the `scenario` parameter to select a pre-defined test pattern, or specify `tool`
and `tool_args` directly for a custom gate tool call.

# Examples

```julia
{"num_agents": 3, "code": "sleep(1); 42"}
{"num_agents": 10, "code": "sum(1:1000)", "stagger": 0.1}
{"num_agents": 5, "tool": "gatetooltest_jl.run_timed_op", "tool_args": {"steps": 5, "delay_ms": 200}}
{"num_agents": 5, "scenario": "timed_op (5 steps)", "session": "9b2d4532"}
```
""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "code" => Dict(
                "type" => "string",
                "description" => "Julia code each agent executes via ex (default: \"sleep(1); 42\"). Ignored when `tool` is set.",
            ),
            "tool" => Dict(
                "type" => "string",
                "description" => "MCP tool name to call instead of ex (e.g. \"gatetooltest_jl.run_timed_op\"). Omit to use eval path.",
            ),
            "tool_args" => Dict(
                "type" => "object",
                "description" => "Arguments passed to the gate tool. Used when `tool` is set.",
            ),
            "scenario" => Dict(
                "type" => "string",
                "description" => "Pre-defined scenario name. Sets `tool` and `tool_args` automatically. Run with no args to list available scenarios.",
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
                "description" => "Target session key for eval path (auto-detects if one session connected). Gate tools route via namespace, not session key.",
            ),
        ),
        "required" => [],
    ),
    function (args)
        code = get(args, "code", "sleep(1); 42")
        tool_name = get(args, "tool", "")
        tool_args_val = get(args, "tool_args", nothing)
        tool_args_json = tool_args_val !== nothing ? JSON.json(tool_args_val) : "{}"
        scenario = get(args, "scenario", "")

        num_agents = get(args, "num_agents", 5)
        num_agents isa AbstractString && (num_agents = parse(Int, num_agents))
        stagger = get(args, "stagger", 0.0)
        stagger isa AbstractString && (stagger = parse(Float64, stagger))
        timeout = get(args, "timeout", 30)
        timeout isa AbstractString && (timeout = parse(Int, timeout))
        session = get(args, "session", "")

        on_progress = get(args, "_on_progress", nothing)

        # Resolve scenario preset
        if !isempty(scenario)
            idx = findfirst(s -> s.name == scenario, STRESS_SCENARIOS)
            if idx === nothing
                names = join([s.name for s in STRESS_SCENARIOS], "\n  ")
                return "ERROR: Unknown scenario '$(scenario)'. Available:\n  $names"
            end
            sc = STRESS_SCENARIOS[idx]
            tool_name = sc.tool
            tool_args_json = sc.args_json
            isempty(sc.code) || (code = sc.code)
        end

        # Default tool
        isempty(tool_name) && (tool_name = "ex")

        # Validate
        num_agents = clamp(num_agents, 1, 100)
        stagger = max(0.0, stagger)
        timeout = clamp(timeout, 1, 600)

        # Resolve session (used for ex eval path and for SUMMARY label)
        mgr = GATE_CONN_MGR[]
        if mgr === nothing
            return "ERROR: No ConnectionManager available. Is the TUI running with gate mode enabled?"
        end

        resolved_conn = nothing
        sess_key = if isempty(session)
            conns = connected_sessions(mgr)
            if length(conns) == 0
                return "ERROR: No REPL sessions connected. Start a gate in your Julia REPL:\n  Gate.serve()"
            elseif length(conns) == 1
                resolved_conn = conns[1]
                short_key(conns[1])
            else
                # For gate tools (non-ex), session is not required — just use first
                if tool_name != "ex"
                    resolved_conn = conns[1]
                    short_key(conns[1])
                else
                    available = join(["$(short_key(c)) ($(c.name))" for c in conns], ", ")
                    return "ERROR: Multiple sessions connected. Specify `session` parameter. Available: $available"
                end
            end
        else
            conn = get_connection_by_key(mgr, session)
            if conn === nothing
                conns = connected_sessions(mgr)
                available = join(["$(short_key(c)) ($(c.name))" for c in conns], ", ")
                return "ERROR: No session matched '$(session)'. Available: $available"
            end
            resolved_conn = conn
            short_key(conn)
        end

        # Auto-prepend namespace for scenario/short tool names that lack a '.' prefix
        if tool_name != "ex" && !occursin('.', tool_name) && resolved_conn !== nothing
            ns = resolved_conn.namespace
            isempty(ns) || (tool_name = "$(ns).$(tool_name)")
        end

        port = GATE_PORT[]

        if on_progress !== nothing
            if tool_name == "ex"
                on_progress("Launching stress test: $num_agents agents, code=$(repr(code))")
            else
                on_progress("Launching stress test: $num_agents agents, tool=$tool_name")
            end
        end

        # Write script and spawn subprocess
        script_path = _write_stress_script()
        project_dir = pkgdir(@__MODULE__)
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project_dir $script_path $port $sess_key $code $num_agents $stagger $timeout $tool_name $tool_args_json`

        output_lines = String[]
        t_start = time()

        try
            process = open(cmd, "r")
            while !eof(process)
                line = readline(process; keep = false)
                isempty(line) && continue
                push!(output_lines, line)
                on_progress !== nothing && on_progress(line)
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
            tool_name == "ex" ? code : tool_name,
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
            result_file;
            tool_name = tool_name,
            tool_args_json = tool_args_json,
        )
    end
)

# ── Eval Tracking ────────────────────────────────────────────────────────────

function _fmt_elapsed(secs::Float64)
    secs < 1.0 ? "$(round(Int, secs * 1000))ms" :
    secs < 60.0 ? "$(round(secs; digits=1))s" :
    "$(round(Int, secs ÷ 60))m $(round(Int, secs % 60))s"
end

check_eval_tool = @mcp_tool(
    :check_eval,
    """Check the status of a background job by eval ID.

IMPORTANT: Do NOT poll this rapidly. Wait at least 30 seconds between calls,
or longer for computations you expect to take minutes. The job will not
complete faster if you check more often — you are just wasting tokens.
A good pattern: check once after 30s, then every 60s after that.

Returns status (running/completed/failed), elapsed time, stashed values,
and the result if completed.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "eval_id" => Dict(
                "type" => "string",
                "description" => "The 8-character eval ID from a previous ex() call",
            ),
        ),
        "required" => ["eval_id"],
    ),
    args -> begin
        eval_id = get(args, "eval_id", "")
        isempty(eval_id) && return "Error: eval_id is required."

        mgr = GATE_CONN_MGR[]
        mgr === nothing && return "No connection manager."

        record = lock(mgr.eval_history_lock) do
            for r in reverse(mgr.eval_history)
                startswith(r.eval_id, eval_id) && return r
            end
            nothing
        end

        # Fall back to database for jobs from previous sessions
        if record === nothing
            db_job = Database.get_job(eval_id)
            if db_job !== nothing
                status = get(db_job, "status", "unknown")
                code = get(db_job, "code", "")
                result = get(db_job, "result", "")
                result_preview = get(db_job, "result_preview", "")
                started = get(db_job, "started_at", 0.0)
                finished = get(db_job, "finished_at", 0.0)
                elapsed_str = _fmt_elapsed(finished > 0 ? finished - started : time() - started)
                out = "$eval_id $status $(elapsed_str)\n$(first(code, 80))"
                !isempty(result) && (out *= "\n\n$result")
                !isempty(result) || !isempty(result_preview) && (out *= "\n\n$result_preview")
                return out
            end
        end

        record === nothing && return "No eval matching '$eval_id'."

        elapsed = record.finished_at > 0 ? record.finished_at - record.started_at : time() - record.started_at
        display_status = record.status == :promoted ? :running : record.status
        code_preview = first(record.code, 80) * (length(record.code) > 80 ? "..." : "")

        status_line = "$(display_status), $(_fmt_elapsed(elapsed))"
        # Show last activity age for running jobs
        if display_status == :running && record.last_update > record.started_at
            ago = round(Int, time() - record.last_update)
            status_line *= ", last activity $(ago)s ago"
        end
        parts = ["$(record.eval_id) on $(record.session_key)", status_line]

        # Stash summary (compact: key=value pairs on one line)
        if !isempty(record.stash)
            stash_parts = ["$(k)=$(v)" for (k, v) in sort(collect(record.stash); by=first)]
            push!(parts, join(stash_parts, ", "))
        end

        # Result — only for completed/failed jobs
        if record.promoted && record.status in (:completed, :failed) && !isempty(record.full_result)
            push!(parts, record.full_result)
        elseif !isempty(record.result_preview)
            push!(parts, record.result_preview)
        end

        join(parts, "\n")
    end
)

cancel_eval_tool = @mcp_tool(
    :cancel_eval,
    """Cancel a running background job by eval ID.

Sends a cancellation signal to the gate session and marks the job in the database.
Running code that calls `Gate.is_cancelled()` in its loop will stop cooperatively.
Julia doesn't support forced thread interruption, so cancellation is cooperative —
the running code must check `Gate.is_cancelled()` periodically.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "eval_id" => Dict(
                "type" => "string",
                "description" => "The eval ID of the background job to cancel",
            ),
        ),
        "required" => ["eval_id"],
    ),
    args -> begin
        eval_id = get(args, "eval_id", "")
        isempty(eval_id) && return "Error: eval_id is required."

        # Find the session key and notify the gate process
        session_key = ""
        mgr = GATE_CONN_MGR[]
        if mgr !== nothing
            lock(mgr.eval_history_lock) do
                for r in mgr.eval_history
                    if startswith(r.eval_id, eval_id) && r.status in (:running, :promoted)
                        r.status = :cancelled
                        r.finished_at = time()
                        session_key = r.session_key
                    end
                end
            end

            # Send cancel to the gate session so Gate.is_cancelled() returns true
            if !isempty(session_key)
                conn = get_connection_by_key(mgr, session_key)
                if conn !== nothing
                    try
                        _req_send_recv(conn,
                            (type = :cancel_job, eval_id = eval_id);
                            caller_timeout = 5.0)
                    catch
                    end
                end
            end
        end

        # Update database
        Database.update_job!(eval_id; status="cancelled", cancelled=true, finished_at=time())

        "Job $eval_id marked as cancelled. Running code can check Gate.is_cancelled() to stop cooperatively."
    end
)

list_jobs_tool = @mcp_tool(
    :list_jobs,
    """List background jobs with optional status filter.

Shows promoted computations that exceeded the time threshold. Use status filter
to see only running, completed, failed, or cancelled jobs.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "status" => Dict(
                "type" => "string",
                "description" => "Filter by status: 'running', 'completed', 'failed', 'cancelled', or empty for all",
            ),
            "limit" => Dict(
                "type" => "integer",
                "description" => "Max number of jobs to return (default: 20)",
            ),
            "stats" => Dict(
                "type" => "boolean",
                "description" => "Include aggregate statistics (default: false)",
            ),
        ),
        "required" => [],
    ),
    args -> begin
        status = get(args, "status", "")
        limit = Int(get(args, "limit", 20))
        show_stats = let v = get(args, "stats", false)
            v isa Bool ? v : v == "true" || v == true
        end

        jobs = Database.list_jobs(; status, limit)

        if isempty(jobs)
            return isempty(status) ? "No background jobs found." : "No $status jobs found."
        end

        lines = String[]
        push!(lines, "Background Jobs ($(length(jobs))$(isempty(status) ? "" : ", status=$status")):\n")

        for job in jobs
            jid = get(job, "eval_id", "?")
            jstatus = get(job, "status", "?")
            code = get(job, "code", "")
            started = get(job, "started_at", 0.0)
            finished = get(job, "finished_at", 0.0)
            session = get(job, "session_key", "")

            elapsed = if finished > 0.0
                finished - started
            else
                time() - started
            end
            elapsed_str = elapsed < 60.0 ? "$(round(elapsed; digits=1))s" : "$(round(Int, elapsed ÷ 60))m $(round(Int, elapsed % 60))s"

            icon = jstatus == "completed" ? "✓" : jstatus == "running" ? "⏳" : jstatus == "failed" ? "✗" : "⊘"
            code_preview = length(code) > 60 ? first(code, 60) * "..." : code

            push!(lines, "$icon $jid [$jstatus] $(elapsed_str) — $code_preview")
        end

        if show_stats
            stats = Database.get_job_stats()
            if !isempty(stats)
                push!(lines, "\nStatistics:")
                push!(lines, "  Total: $(get(stats, "total", 0))")
                push!(lines, "  Running: $(get(stats, "running", 0))")
                push!(lines, "  Completed: $(get(stats, "completed", 0))")
                push!(lines, "  Failed: $(get(stats, "failed", 0))")
                push!(lines, "  Cancelled: $(get(stats, "cancelled", 0))")
                avg = get(stats, "avg_duration", nothing)
                avg !== nothing && avg !== missing && push!(lines, "  Avg duration: $(round(avg; digits=1))s")
                maxd = get(stats, "max_duration", nothing)
                maxd !== nothing && maxd !== missing && push!(lines, "  Max duration: $(round(maxd; digits=1))s")
            end
        end

        join(lines, "\n")
    end
)

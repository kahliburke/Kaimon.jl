# (Kaimon MCP tool definitions — split into tool_definitions_*.jl; this one loads FIRST)
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

        # io=devnull keeps Pkg non-interactive (no terminal/fancyprint) AND routes
        # any precompilation away from the gate's captured streams. We deliberately
        # let precompilation run HERE rather than deferring it to the first `using`:
        # a `using`-triggered auto-precompile writes to stderr (the gate's capture
        # mux) and, on Julia 1.12, trips the failed-task notice printer
        # ("…giving up"). Doing it here with io=devnull sidesteps that entirely.
        #
        # Precomp was originally dropped here because it could time the tool out —
        # so route through the streaming path (like `ex`), which auto-promotes a
        # long precompile to a background job (poll check_eval) instead of blocking.
        pkg_names = join(["\"$p\"" for p in packages], ", ")
        code = """
        using Pkg
        Pkg.$operation([$pkg_names]; io=devnull)
        $(repr("$verb packages: " * join(packages, ", ")))
        """

        return if GATE_MODE[]
            Base.invokelatest(
                execute_via_gate_streaming, code;
                quiet = false, silent = false, session = session,
            )
        else
            Base.invokelatest(
                execute_repllike, code; silent = false, quiet = false, session = session,
            )
        end
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
            # The gate this agent is bound to (its default for unscoped tools/search),
            # set from its `ses=` or auto-matched from its MCP workspace root. Promote
            # it to the top and mark it so the agent knows its default at a glance.
            bound_key = let caller = _current_mcp_caller()
                isempty(caller) ? "" : lock(STANDALONE_SESSIONS_LOCK) do
                    s = get(STANDALONE_SESSIONS, caller, nothing)
                    s === nothing ? "" : something(s.target_julia_session_id, "")
                end
            end
            if !isempty(bound_key)
                bi = findfirst(c -> short_key(c) == bound_key, user_conns)
                if bi !== nothing
                    pushfirst!(user_conns, popat!(user_conns, bi))
                end
            end
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
                mine = (!isempty(bound_key) && key == bound_key) ?
                    "  ← your session (default for unscoped tools/search; override with ses=)" : ""
                status *= "\n  $icon $key $dname ($(conn.status), up $(uptime_str), PID $(conn.pid)$tools_info$extra)$mine"
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
            uptime_ms = Dates.value(Dates.now() - _SERVER_START_TIME[])
            uptime_str = let h = uptime_ms ÷ 3_600_000,
                m = (uptime_ms % 3_600_000) ÷ 60_000,
                s = (uptime_ms % 60_000) ÷ 1000

                h > 0 ? "$(h)h $(m)m $(s)s" : m > 0 ? "$(m)m $(s)s" : "$(s)s"
            end
            status *= "\n\nServer uptime: $uptime_str"
            status *= "\nStarted: $(Dates.format(_SERVER_START_TIME[], "yyyy-mm-dd HH:MM:SS"))"
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
                    filter(e -> e.level == :error, _TUI_LOG_RING)
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

        # Read from persistent ring buffer (thread-safe, last 500 entries)
        entries = lock(_TUI_LOG_LOCK) do
            copy(_TUI_LOG_RING)
        end

        # Filter by since
        if since_dt !== nothing
            filter!(e -> e.timestamp >= since_dt, entries)
        end

        # Filter by level
        entries = _apply_level_filter(entries, level_filter)

        # Take the last N entries
        length(entries) > limit && (entries = entries[end-limit+1:end])
        isempty(entries) && return "No log entries found matching the specified criteria."
        return join([_format_entry(e) for e in entries], "\n")
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

                # Compose: the always-injected server instructions are the canonical
                # quick reference (the most important messages); this tool returns
                # them plus the extended guide below. One source for the essentials,
                # so the two can't drift.
                extended = read(workflow_path, String)
                return string(Session.get_server_instructions(), "\n\n---\n\n", extended)
            catch e
                return "Error reading usage instructions: $e"
            end
        end
    )

usage_quiz_tool = @mcp_tool(
    :usage_quiz,
    """Self-graded quiz on Kaimon usage patterns — a primer for working effectively.

Default: returns quiz questions. With show_sols=true: returns solutions and grading rubric.
Covers the shared REPL model, q-flag usage, sessions/routing, picking purpose-built tools
(search/introspection/testing/debugging), eval tracking + background jobs, the search tools
(search_code/grep_code), and environment discipline. Scored out of 100; if < 75, review
usage_instructions and retake.""",
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

        # allow_stalled so a stalled/dead session can still be restarted or
        # force-evicted — otherwise _resolve_gate_conn rejects it and there's no
        # way to clear it from the registry.
        conn, err = _resolve_gate_conn(session; allow_stalled = true)
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
            was_stalled = conn.status == :stalled
            # Best-effort graceful shutdown; a stalled/dead gate may not answer.
            ok = send_shutdown!(conn)
            disconnect!(conn)
            # Force-evict from the registry and clean up its files, so a stalled
            # session (e.g. a localhost TCP worker whose process already died) can
            # always be cleared without round-tripping to the dead gate.
            lock(mgr.lock) do
                idx = findfirst(c -> c === conn, mgr.connections)
                if idx !== nothing
                    _unregister_session_tools!(conn)
                    deleteat!(mgr.connections, idx)
                end
            end
            _remove_session_files(mgr.sock_dir, conn.session_id)
            _fire_sessions_changed(mgr)
            if ok
                return "Session $key shut down."
            elseif was_stalled
                return "Session $key was stalled/unreachable — force-removed from the registry and cleaned up."
            else
                return "Session $key removed from the registry (gate did not acknowledge shutdown)."
            end
        else
            return "Error: Invalid command '$command'"
        end
    end
)

connect_tcp_tool = @mcp_tool(
    :connect_tcp,
    """Connect to a remote Julia gate session over TCP.

Use this to connect to a gate started with `KaimonGate.serve(mode=:tcp, port=9876)` on
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
            "server_key" => Dict(
                "type" => "string",
                "description" => "CURVE server public key (Z85) for an encrypted gate (serve(curve=true)). Falls back to KAIMON_GATE_CURVE_SERVERKEY or a previously pinned key. Required on first connect to a CURVE gate.",
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
        server_key = get(args, "server_key", "")

        mgr = GATE_CONN_MGR[]
        mgr === nothing && return "Error: No ConnectionManager available"

        conn = try
            connect_tcp!(mgr, host, port; name, token, stream_port, server_key)
        catch e
            return "Error: $(sprint(showerror, e))"
        end

        key = short_key(conn)
        "Connected to TCP gate at $host:$port (session key: $key)"
    end
)

"""Ask the user, via MCP elicitation, whether to allow starting a Julia session
for `path`. Returns one of `:once`, `:always`, `:denied`, or `:unsupported`
(client didn't advertise elicitation / no open receive stream / timeout). The
caller maps `:unsupported` back to the static allow-list guidance."""
function _elicit_session_consent(path::AbstractString)
    caller = _current_mcp_caller()
    isempty(caller) && return :unsupported
    session = lock(STANDALONE_SESSIONS_LOCK) do
        get(STANDALONE_SESSIONS, caller, nothing)
    end
    session === nothing && return :unsupported
    caps = session.client_capabilities
    (caps isa AbstractDict && haskey(caps, "elicitation")) || return :unsupported

    # Accept/Decline (the elicitation action) IS the allow/deny decision; a single
    # boolean checkbox handles once-vs-always. (A 3-way enum field doesn't render
    # reliably across clients — they surface only the accept/decline buttons.)
    schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "remember" => Dict{String,Any}(
                "type" => "boolean",
                "title" => "Always allow this project (add to the allow-list)",
                "default" => false,
            ),
        ),
    )
    msg = "Claude wants to start a Julia session for the project:\n$path\n\n" *
          "Accept to allow. Check \"Always allow\" to add it to your allowed-projects " *
          "list and skip this prompt next time."
    # Cap the wait under the client's tool-call timeout (~60s) so we always return
    # a result over the wire rather than have the client give up mid-prompt — which
    # would orphan-spawn the session and break the result pipe. On no answer we
    # return :timeout (distinct from :unsupported) so the caller tells the agent to
    # retry instead of falling back to the can't-elicit guidance.
    res = request_elicitation(caller, msg, schema; timeout = 50.0)
    res isa AbstractDict || return :timeout
    get(res, "action", "") == "accept" || return :denied
    content = get(res, "content", nothing)
    remember = content isa AbstractDict && get(content, "remember", false) === true
    return remember ? :always : :once
end

start_session_tool = @mcp_tool(
    :start_session,
    """Spawn a new Julia session for a project.

Reach for this the moment you need a REPL for a project that has no connected
session — `ping` shows none for it, or a tool returned "No session matched". You
can create one immediately; don't wait for the user to start it.

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

        # Converge with any gate already connected for this project — whether
        # started manually via Gate.serve() or by a previous start_session —
        # instead of spawning a duplicate. This is the authoritative, live check
        # (the MANAGED_SESSIONS registry below tracks only agent-spawned sessions
        # and can go stale). No spawn happens here, so no allow-list consent is
        # needed: the session already exists, we're just handing back its key.
        let mgr = GATE_CONN_MGR[]
            if mgr !== nothing
                for conn in connected_sessions(mgr)
                    isempty(conn.project_path) && continue
                    if normalize_path(conn.project_path) == path
                        return "Session already running for this project (session key: $(short_key(conn)))."
                    end
                end
            end
        end

        # Check allowed list. Not yet allowed → ask the user in-band via MCP
        # elicitation (the prompt renders in the agent's own client). "Allow
        # always" remembers the consent; clients without elicitation fall back to
        # the static guidance.
        if !is_project_allowed(path)
            decision = _elicit_session_consent(path)
            if decision == :always
                allow_project!(path)
            elseif decision == :once
                # proceed for this spawn only, without persisting
            elseif decision == :denied
                return "Session not started — you declined to allow a Julia session for $path."
            elseif decision == :timeout
                return "No response to the approval prompt within 50s, so no session was started. Call start_session again when you're ready, and approve the prompt in your client."
            else  # :unsupported
                return "Error: Project not in allowed list. Add it via the TUI Config tab [p] or manually to ~/.config/kaimon/projects.json, or set \"allow_any_project\": true there to disable the allow-list (intended for isolated container/VM environments)."
            end
        end

        # Any MANAGED_SESSIONS entry for this path is stale at this point — a live
        # gate would have been caught by the connection-manager check above — so
        # drop it and respawn fresh. This closes the phantom "already running" gap
        # where a dead managed entry's key was handed back (issue #55).
        existing = find_managed_session(path)
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


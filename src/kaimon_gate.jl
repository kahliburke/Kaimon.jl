# ─────────────────────────────────────────────────────────────────────────────
# Kaimon · dynamic tool registry, gate-mode globals, execute_via_gate  (relocated from Kaimon.jl; part of the Kaimon module)
# ─────────────────────────────────────────────────────────────────────────────

const TOOL_REGISTRY_LOCK = ReentrantLock()

"""
    _register_dynamic_tools!(tools::Vector{MCPTool})

Register tools into the global registry at runtime. Updates both `ALL_TOOLS[]`
and `SERVER[].tools`. Sends `tools/list_changed` notification.
Thread-safe.
"""
function _register_dynamic_tools!(tools::Vector{MCPTool})
    lock(TOOL_REGISTRY_LOCK) do
        for tool in tools
            if ALL_TOOLS[] !== nothing
                push!(ALL_TOOLS[], tool)
            end
            server = SERVER[]
            if server !== nothing
                server.tools[tool.id] = tool
                server.name_to_id[tool.name] = tool.id
            end
        end
    end
    _notify_tools_changed()
end

"""
    _unregister_dynamic_tools!(prefix::String)

Remove all tools whose name starts with `prefix` from the global registry.
Sends `tools/list_changed` notification. Thread-safe.
"""
function _unregister_dynamic_tools!(prefix::String)
    removed = false
    lock(TOOL_REGISTRY_LOCK) do
        if ALL_TOOLS[] !== nothing
            before = length(ALL_TOOLS[])
            filter!(t -> !startswith(t.name, prefix), ALL_TOOLS[])
            removed = length(ALL_TOOLS[]) < before
        end
        server = SERVER[]
        if server !== nothing
            for (id, tool) in collect(server.tools)
                if startswith(tool.name, prefix)
                    delete!(server.tools, id)
                    delete!(server.name_to_id, tool.name)
                    removed = true
                end
            end
        end
    end
    removed && _notify_tools_changed()
end

"""
    _notify_tools_changed()

Push a `notifications/tools/list_changed` notification to the pending queue
so MCP clients re-fetch the tool list on the next SSE response.
"""
function _notify_tools_changed()
    _queue_notification!(Dict{String,Any}(
        "jsonrpc" => "2.0",
        "method" => "notifications/tools/list_changed",
    ))
end

# ── Gate mode globals ──────────────────────────────────────────────────────
# When running in TUI server mode, tool calls route through the gate client
# instead of executing in-process.

const GATE_MODE = Ref{Bool}(false)
const GATE_CONN_MGR = Ref{Union{Nothing,ConnectionManager}}(nothing)
const _LAST_SESSION_KEY = Ref{String}("")  # last session used by ex/tools — for default collection resolution

"""Get the project path of the last session the agent interacted with."""
function _last_session_project_path()
    key = _LAST_SESSION_KEY[]
    isempty(key) && return ""
    mgr = GATE_CONN_MGR[]
    mgr === nothing && return ""
    conn = get_connection_by_key(mgr, key)
    conn === nothing && return ""
    return conn.project_path
end
const TUI_MODEL = Ref{Any}(nothing)
const TUI_LAST_FRAME = Ref{String}("")

# ── Debug consent coordination ────────────────────────────────────────────
# MCP tool writes a request, TUI reads it and shows consent prompt.
# Response channel carries :approved or :denied back to the MCP tool.

const _DEBUG_CONTINUE_REQUEST = Ref{Any}(nothing)   # (session_key::String, action::Symbol)
const _DEBUG_CONTINUE_RESPONSE = Ref{Any}(nothing)   # Channel{Symbol} — :approved or :denied

"""
    _resolve_gate_conn(session) -> (conn, error_string)

Resolve a gate connection from the session key. Returns (conn, nothing) on success,
or (nothing, error_message) on failure.
"""
function _resolve_gate_conn(session::String; allow_stalled::Bool = false)
    mgr = GATE_CONN_MGR[]
    if mgr === nothing
        return (nothing, "ERROR: Gate mode active but no ConnectionManager configured")
    end

    conn = if isempty(session)
        conns = connected_sessions(mgr)
        if length(conns) == 1
            conns[1]
        else
            nothing
        end
    else
        get_connection_by_key(mgr, session)
    end
    if conn === nothing
        available =
            join(["$(short_key(c)) ($(c.name))" for c in connected_sessions(mgr)], ", ")
        if isempty(available)
            return (
                nothing,
                "ERROR: No REPL sessions connected. Start a gate in your Julia REPL:\n" *
                "  using KaimonGate; KaimonGate.serve()   # or, in a full Kaimon session: Gate.serve()",
            )
        end
        return (nothing, "ERROR: No session matched '$(session)'. Available: $available")
    end

    # Track last used session for default collection resolution
    _LAST_SESSION_KEY[] = short_key(conn)

    # Stalled sessions: return a status message instead of letting tools timeout.
    # Callers managing the session lifecycle (manage_repl) pass allow_stalled=true
    # so they can restart or force-evict a stalled/dead session.
    if conn.status == :stalled && !allow_stalled
        ago = round(Int, Dates.value(now() - conn.last_seen) / 1000)
        dname = isempty(conn.display_name) ? conn.name : conn.display_name
        diag_str = if conn.diagnostics !== nothing
            d = conn.diagnostics
            activity = _diagnose_activity(d)
            "\nProcess stats: $(round(d.rss_mb; digits=1)) MB RSS, $(round(d.cpu_pct; digits=1))% CPU — $activity."
        else
            ""
        end
        return (
            nothing,
            "Session '$dname' ($(short_key(conn))) is stalled — last seen $(ago)s ago.$diag_str\n" *
            "A backtrace was sent to the session's terminal. " *
            "Try again shortly or use manage_repl to restart it.",
        )
    end

    return (conn, nothing)
end

"""
    connect_tcp_to_active_manager(host, port; name="remote") -> REPLConnection

Connect to a TCP gate at `host:port` using the active ConnectionManager.
Used by the REST API endpoint to allow browser-driven gate connections.
Throws if no ConnectionManager is available or connection fails.
"""
function connect_tcp_to_active_manager(host::String, port::Int; name::String = "remote",
                                       server_key::String = "")
    mgr = GATE_CONN_MGR[]
    if mgr === nothing
        error("No ConnectionManager available — gate services not running")
    end
    return connect_tcp!(mgr, host, port; name = name, server_key = server_key)
end

"""
    _prepare_gate_code(code, quiet) -> (cleaned_code, show_return_value, was_stripped)

Apply println stripping and quiet-mode semicolons to code before sending to gate.
"""
function _prepare_gate_code(code::String, quiet::Bool)
    was_stripped = Ref(false)
    expr = Base.parse_input_line(code)
    expr = remove_println_calls(expr, true, quiet, was_stripped)
    cleaned_code = if expr === nothing
        ""
    elseif was_stripped[]
        _serialize_expr(expr)
    else
        code
    end

    show_return_value = !quiet && !REPL.ends_with_semicolon(code)
    if quiet && !REPL.ends_with_semicolon(cleaned_code)
        cleaned_code = cleaned_code * ";"
    end

    return (cleaned_code, show_return_value, was_stripped)
end

"""
    _reconcile_stale_jobs!(conn_mgr)

Check the database for background jobs stuck in 'running' status and try to
retrieve their results from the gate session's result cache. Called once on
TUI startup after sessions have had time to connect.
"""
function _reconcile_stale_jobs!(conn_mgr)
    conn_mgr === nothing && return
    running_jobs = Database.list_jobs(; status="running", limit=50)
    isempty(running_jobs) && return
    _push_log!(:info, "Reconciling $(length(running_jobs)) stale background job(s)")

    for job in running_jobs
        eval_id = get(job, "eval_id", "")
        session_key = get(job, "session_key", "")
        isempty(eval_id) || isempty(session_key) && continue

        conn = get_connection_by_key(conn_mgr, session_key)
        if conn === nothing
            # Session not connected — mark as lost if old enough
            started = get(job, "started_at", 0.0)
            if started > 0 && time() - started > 3600  # 1 hour
                Database.update_job!(eval_id; status="lost", finished_at=time())
                _push_log!(:warn, "Job $eval_id marked as lost (session gone)")
            end
            continue
        end

        # Try to retrieve cached result from the gate
        try
            result = _req_send_recv(conn,
                (type = :get_job_result, eval_id = eval_id);
                caller_timeout = 5.0)
            if result.ok && get(result.response, :type, :error) == :job_result
                data = get(result.response, :data, "")
                if !isempty(data)
                    # Deserialize and format the result
                    response = try
                        _safe_deserialize(data; label = "job_result")
                    catch
                        (stdout="", stderr="", value_repr=data, exception=nothing, backtrace=nothing)
                    end
                    formatted = _format_gate_response(response, true, false, Ref(false), 6000)
                    preview = hasproperty(response, :value_repr) ? string(response.value_repr) : ""
                    status = hasproperty(response, :exception) && response.exception !== nothing ? "failed" : "completed"
                    Database.update_job!(eval_id;
                        status=status, result=formatted,
                        result_preview=first(preview, 500), finished_at=time())
                    _push_log!(:info, "Job $eval_id reconciled: $status")
                end
            end
        catch e
            @debug "Failed to reconcile job $eval_id" exception=e
        end
    end
end

"""Format a gate eval response into the final result string."""
function _format_gate_response(
    response,
    show_return_value::Bool,
    quiet::Bool,
    was_stripped::Ref{Bool},
    max_output::Int,
)
    captured = ""
    if hasproperty(response, :stdout) && hasproperty(response, :stderr)
        captured = string(response.stdout) * string(response.stderr)
    end

    result_str = ""
    if hasproperty(response, :exception) && response.exception !== nothing
        result_str = "ERROR: " * string(response.exception)
    elseif show_return_value && hasproperty(response, :value_repr)
        result_str = string(response.value_repr)
    end

    has_error = hasproperty(response, :exception) && response.exception !== nothing
    result = if quiet && !has_error
        ""
    else
        captured * result_str
    end

    if was_stripped[]
        result *= "\n\n⚠️  Note: println/print/logging calls were removed. Use q=false with a final expression to see values."
    end

    if length(result) > max_output
        original_length = length(result)
        result = truncate_output(result, max_output, nothing)
        result *= "\n\n⚠️  Output truncated ($max_output of $original_length chars shown)."
    end

    return result
end

"""
    execute_via_gate_streaming(code; quiet=true, silent=false, max_output=6000, session="", on_progress=nothing)

Execute code on a remote REPL via the gate client using async eval with streaming output.
The `on_progress` callback receives `(message::String)` for each output chunk, enabling
upstream callers (e.g. SSE progress notifications) to forward incremental output.
"""
function execute_via_gate_streaming(
    code::String;
    quiet::Bool = true,
    silent::Bool = false,
    max_output::Int = 6000,
    session::String = "",
    main_thread::Bool = false,
    on_progress::Union{Function,Nothing} = nothing,
)
    conn, err = _resolve_gate_conn(session)
    err !== nothing && return err

    # Warn agent if session is paused at a breakpoint — eval will block or fail
    if conn.debug_paused
        dname = isempty(conn.display_name) ? conn.name : conn.display_name
        return "⏸ Session '$dname' is paused at an @infiltrate breakpoint. " *
               "The REPL cannot evaluate new code while paused.\n\n" *
               "Use debug_ctrl(action=\"status\") to see where it's paused, " *
               "debug_eval(expression=\"...\") to evaluate in the breakpoint scope, " *
               "or debug_ctrl(action=\"continue\") to resume execution first."
    end

    cleaned_code, show_return_value, was_stripped = _prepare_gate_code(code, quiet)

    # Generate eval_id for tracking
    eval_id = bytes2hex(rand(UInt8, 4))  # 8 hex chars
    mgr = GATE_CONN_MGR[]

    # Record eval start
    if mgr !== nothing
        _record_eval_start!(mgr, eval_id, short_key(conn), code)
    end

    # Stream eval_id as first progress message
    if on_progress !== nothing
        try
            on_progress("[eval_id:$eval_id]")
        catch
        end
    end

    # Use async eval with streaming — on_output forwards chunks to on_progress
    on_output = if on_progress !== nothing
        (channel, data) -> begin
            try
                on_progress("[$channel] $data")
            catch
            end
        end
    else
        nothing
    end

    # Run eval in a background task so we can promote to a job if it takes too long
    promotion_threshold = 30.0  # seconds before promoting to background job
    result_channel = Channel{Any}(1)

    eval_task = Threads.@spawn begin
        response = eval_remote_async(
            conn,
            cleaned_code;
            display_code = code,
            on_output = on_output,
            request_id = eval_id,
            main_thread = main_thread,
        )
        try; put!(result_channel, response); catch; end
    end

    # Wait for the result, but promote to background job if too slow
    response = nothing
    deadline = time() + promotion_threshold
    while time() < deadline
        if isready(result_channel)
            response = take!(result_channel)
            break
        end
        sleep(0.1)
    end

    if response === nothing
        # Eval still running — promote to background job
        promoted_at = time()
        if mgr !== nothing
            lock(mgr.eval_history_lock) do
                for r in mgr.eval_history
                    if r.eval_id == eval_id
                        r.status = :promoted
                        r.promoted = true
                        break
                    end
                end
            end
        end

        # Persist to database so job survives TUI restarts
        Database.persist_job!(eval_id, short_key(conn), code,
            mgr !== nothing ? mgr.eval_history[end].started_at : time(), promoted_at)

        # Push activity event and inflight entry so promotion is visible in the TUI
        dname = isempty(conn.display_name) ? conn.name : conn.display_name
        code_preview = length(code) > 60 ? first(code, 60) * "..." : code
        job_inflight_id = _push_inflight_start!("⏳ job:$eval_id", code_preview, short_key(conn))
        _push_inflight_progress!(job_inflight_id, "running in background")
        _register_job_inflight!(eval_id, job_inflight_id)

        # Background task to collect the result when it completes
        Threads.@spawn begin
            try
                res = if isready(result_channel)
                    take!(result_channel)
                else
                    wait(eval_task)
                    isready(result_channel) ? take!(result_channel) : nothing
                end
                if res !== nothing
                    status = if hasproperty(res, :exception) && res.exception !== nothing
                        :failed
                    else
                        :completed
                    end
                    formatted = _format_gate_response(res, show_return_value, quiet, was_stripped, max_output)
                    preview = if hasproperty(res, :value_repr)
                        string(res.value_repr)
                    elseif hasproperty(res, :exception) && res.exception !== nothing
                        string(res.exception)
                    else
                        ""
                    end
                    mgr !== nothing && _record_eval_done!(mgr, eval_id, status, preview; full_result = formatted)
                    Database.update_job!(eval_id;
                        status = string(status),
                        result = formatted,
                        result_preview = preview,
                        finished_at = time())
                    elapsed = round(time() - promoted_at, digits=1)
                    _push_job_progress!(eval_id,
                        "$(status == :completed ? "✓" : "✗") $status after $(elapsed)s")
                    _finish_job_inflight!(eval_id)
                    _push_activity!(status == :completed ? :job_completed : :job_failed,
                        "ex", dname,
                        "$(status == :completed ? "✓" : "✗") Job $eval_id $status after $(elapsed)s";
                        success = status == :completed)
                end
            catch e
                err_msg = sprint(showerror, e)
                mgr !== nothing && _record_eval_done!(mgr, eval_id, :failed, err_msg)
                Database.update_job!(eval_id;
                    status = "failed", result = err_msg,
                    result_preview = first(err_msg, 500), finished_at = time())
                _finish_job_inflight!(eval_id)
                _push_activity!(:job_failed, "ex", dname,
                    "✗ Job $eval_id failed: $(first(err_msg, 80))"; success = false)
            end
        end

        started_at = lock(mgr.eval_history_lock) do
            for r in mgr.eval_history
                r.eval_id == eval_id && return r.started_at
            end
            return time()
        end
        elapsed = round(time() - started_at, digits=1)
        return "⏳ Computation promoted to background job after $(elapsed)s.\n" *
               "Job ID: $eval_id\n" *
               "Session: $(isempty(conn.display_name) ? conn.name : conn.display_name)\n" *
               "Code: $(first(code, 80))$(length(code) > 80 ? "..." : "")\n\n" *
               "Use `check_eval(eval_id=\"$eval_id\")` to check status and retrieve the result.\n" *
               "Wait at least 30s before checking. Do NOT poll rapidly.\n" *
               "Use `cancel_eval(eval_id=\"$eval_id\")` to cancel if needed."
    end

    # Eval completed within threshold — normal path
    # Record eval completion
    if mgr !== nothing
        status = if hasproperty(response, :exception) && response.exception !== nothing
            if contains(string(response.exception), "timed out")
                :timeout
            else
                :failed
            end
        else
            :completed
        end
        preview = if hasproperty(response, :value_repr)
            string(response.value_repr)
        elseif hasproperty(response, :exception) && response.exception !== nothing
            string(response.exception)
        else
            ""
        end
        _record_eval_done!(mgr, eval_id, status, preview)
    end

    result = _format_gate_response(
        response,
        show_return_value,
        quiet,
        was_stripped,
        max_output,
    )

    return result
end

"""
    execute_via_gate(code; quiet=true, max_output=6000)

Execute code on a remote REPL via the gate client. Used when GATE_MODE is
active (TUI server process). Falls back to in-process eval if no gate is
connected.

Delegates to `execute_via_gate_streaming` with async eval for robustness
(avoids blocking the REQ socket during long evals).
"""
function execute_via_gate(
    code::String;
    quiet::Bool = true,
    silent::Bool = false,
    max_output::Int = 6000,
    session::String = "",
)
    return execute_via_gate_streaming(
        code;
        quiet = quiet,
        silent = silent,
        max_output = max_output,
        session = session,
        on_progress = nothing,
    )
end

# ============================================================================
# Tool Configuration Management
# ============================================================================


# ─────────────────────────────────────────────────────────────────────────────
# Kaimon MCP tools · eval/job tracking (check_eval/cancel_eval/list_jobs)  (split from tool_definitions.jl)
# ─────────────────────────────────────────────────────────────────────────────

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
Running code that calls `KaimonGate.is_cancelled()` in its loop will stop cooperatively.
Julia doesn't support forced thread interruption, so cancellation is cooperative —
the running code must check `KaimonGate.is_cancelled()` periodically.""",
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

            # Send cancel to the gate session so KaimonGate.is_cancelled() returns true
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

        "Job $eval_id marked as cancelled. Running code can check KaimonGate.is_cancelled() to stop cooperatively."
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

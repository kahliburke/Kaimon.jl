# ── Server Log Capture ────────────────────────────────────────────────────────
# Redirect Julia's logging system into a ring buffer so @info/@warn/@error
# from the MCP server, HTTP.jl, etc. appear in the Server tab instead of
# corrupting the TUI's terminal output.


const _TUI_LOG_BUFFER = ServerLogEntry[]   # drained into model each frame
const _TUI_LOG_RING = ServerLogEntry[]     # persistent ring for tool reads (never drained)
const _TUI_LOG_LOCK = ReentrantLock()      # protects both buffers

# Track when this Kaimon server process started (used for uptime reporting)
const _SERVER_START_TIME = Dates.now()
const _TUI_OLD_LOGGER = Ref{Any}(nothing)
const _TUI_LOG_FILE = Ref{Union{IOStream,Nothing}}(nothing)

# stderr capture — prevent background code from corrupting the terminal
const _TUI_ORIG_STDERR = Ref{Any}(nothing)
const _TUI_STDERR_TASK = Ref{Union{Task,Nothing}}(nothing)
const _TUI_STDERR_RUNNING = Ref{Bool}(false)

const _TUI_LOG_PATH = joinpath(kaimon_cache_dir(), "server.log")

const _LOG_MAX_BYTES = 10 * 1024 * 1024  # 10 MB

function _open_log_file!()
    try
        mkpath(dirname(_TUI_LOG_PATH))
        # Rotate if too large
        if isfile(_TUI_LOG_PATH) && filesize(_TUI_LOG_PATH) > _LOG_MAX_BYTES
            rotated = _TUI_LOG_PATH * ".1"
            try; rm(rotated; force=true); catch; end
            try; mv(_TUI_LOG_PATH, rotated); catch; end
        end
        _TUI_LOG_FILE[] = open(_TUI_LOG_PATH, "a")
    catch
        _TUI_LOG_FILE[] = nothing
    end
end

function _close_log_file!()
    io = _TUI_LOG_FILE[]
    _TUI_LOG_FILE[] = nothing
    io === nothing && return
    try
        close(io)
    catch
    end
end

function _write_log_entry(ts::DateTime, level::Symbol, msg::String)
    io = _TUI_LOG_FILE[]
    io === nothing && return
    try
        write(
            io,
            Dates.format(ts, "yyyy-mm-dd HH:MM:SS"),
            " [",
            uppercase(string(level)),
            "] ",
            msg,
            "\n",
        )
        flush(io)
    catch
    end
end

struct TUILogger <: Logging.AbstractLogger end

Logging.min_enabled_level(::TUILogger) = Logging.Info
Logging.shouldlog(::TUILogger, level, _module, group, id) = true
Logging.catch_exceptions(::TUILogger) = true

function Logging.handle_message(
    ::TUILogger,
    level,
    message,
    _module,
    group,
    id,
    filepath,
    line;
    kwargs...,
)
    lvl = if level >= Logging.Error
        :error
    elseif level >= Logging.Warn
        :warn
    else
        :info
    end
    msg = string(message)
    if !isempty(kwargs)
        parts = String[string(k, "=", repr(v)) for (k, v) in kwargs]
        msg *= "  " * join(parts, " ")
    end
    ts = now()
    entry = ServerLogEntry(ts, lvl, msg)
    lock(_TUI_LOG_LOCK) do
        push!(_TUI_LOG_BUFFER, entry)
        while length(_TUI_LOG_BUFFER) > 500
            popfirst!(_TUI_LOG_BUFFER)
        end
        push!(_TUI_LOG_RING, entry)
        while length(_TUI_LOG_RING) > 500
            popfirst!(_TUI_LOG_RING)
        end
    end
    _write_log_entry(ts, lvl, msg)
    return nothing
end

function _drain_log_buffer!(dest::Vector{ServerLogEntry})
    lock(_TUI_LOG_LOCK) do
        append!(dest, _TUI_LOG_BUFFER)
        empty!(_TUI_LOG_BUFFER)
    end
    while length(dest) > 500
        popfirst!(dest)
    end
end

function _push_log!(level::Symbol, message::String)
    ts = now()
    entry = ServerLogEntry(ts, level, message)
    lock(_TUI_LOG_LOCK) do
        push!(_TUI_LOG_BUFFER, entry)
        push!(_TUI_LOG_RING, entry)
        while length(_TUI_LOG_RING) > 500
            popfirst!(_TUI_LOG_RING)
        end
    end
    _write_log_entry(ts, level, message)
end

# ── stderr capture ───────────────────────────────────────────────────────────
# Redirect stderr to a pipe so background code (HTTP.jl, etc.) can't write
# raw bytes to the terminal and corrupt the TUI display.

const _TUI_STDERR_WR = Ref{Any}(nothing)

function _start_stderr_capture!()
    _TUI_STDERR_RUNNING[] = true
    _TUI_ORIG_STDERR[] = stderr
    rd, wr = redirect_stderr()
    _TUI_STDERR_WR[] = wr
    _TUI_STDERR_TASK[] = @async begin
        try
            while _TUI_STDERR_RUNNING[]
                line = readline(rd; keep = false)
                isempty(line) && continue
                _push_log!(:warn, "stderr: $line")
            end
        catch e
            e isa EOFError && return
            e isa InterruptException && return
        finally
            try
                close(rd)
            catch
            end
        end
    end
end

function _stop_stderr_capture!()
    _TUI_STDERR_RUNNING[] = false
    # Restore original stderr first
    orig = _TUI_ORIG_STDERR[]
    if orig !== nothing
        try
            redirect_stderr(orig)
        catch
        end
        _TUI_ORIG_STDERR[] = nothing
    end
    # Close the pipe write end so the reader task gets EOF
    wr = _TUI_STDERR_WR[]
    if wr !== nothing
        try
            close(wr)
        catch
        end
        _TUI_STDERR_WR[] = nothing
    end
    task = _TUI_STDERR_TASK[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end
    _TUI_STDERR_TASK[] = nothing
end

# ── stdout capture ───────────────────────────────────────────────────────────
# Redirect stdout to a pipe so background println()/print() from test runs,
# index scheduler, etc. can't write raw bytes into the alternate screen buffer.
# Tachikoma's Terminal.io is set to _TUI_REAL_STDOUT (opened from /dev/tty)
# so rendering still goes to the real terminal regardless of the redirect.

const _TUI_STDOUT_WR = Ref{Any}(nothing)
const _TUI_ORIG_STDOUT = Ref{Any}(nothing)
const _TUI_REAL_STDOUT = Ref{Any}(nothing)   # /dev/tty handle → real terminal
const _TUI_STDOUT_TASK = Ref{Union{Task,Nothing}}(nothing)
const _TUI_STDOUT_RUNNING = Ref{Bool}(false)

function _start_stdout_capture!()
    _TUI_STDOUT_RUNNING[] = true
    _TUI_ORIG_STDOUT[] = stdout
    # Open a handle to the controlling terminal that survives `redirect_stdout`.
    # Unix: /dev/tty. Windows: CON (the console device).
    _TUI_REAL_STDOUT[] = open(Sys.iswindows() ? "CON" : "/dev/tty", "w")
    rd, wr = redirect_stdout()
    _TUI_STDOUT_WR[] = wr
    _TUI_STDOUT_TASK[] = @async begin
        try
            while _TUI_STDOUT_RUNNING[]
                line = readline(rd; keep = false)
                isempty(line) && continue
                _push_log!(:info, "stdout: $line")
            end
        catch e
            e isa EOFError && return
            e isa InterruptException && return
        finally
            try
                close(rd)
            catch
            end
        end
    end
end

function _stop_stdout_capture!()
    _TUI_STDOUT_RUNNING[] = false
    # Restore original stdout first
    orig = _TUI_ORIG_STDOUT[]
    if orig !== nothing
        try
            redirect_stdout(orig)
        catch
        end
        _TUI_ORIG_STDOUT[] = nothing
    end
    # Close the pipe write end so the reader task gets EOF
    wr = _TUI_STDOUT_WR[]
    if wr !== nothing
        try
            close(wr)
        catch
        end
        _TUI_STDOUT_WR[] = nothing
    end
    task = _TUI_STDOUT_TASK[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end
    _TUI_STDOUT_TASK[] = nothing
    # Close the /dev/tty handle
    real = _TUI_REAL_STDOUT[]
    if real !== nothing
        try
            close(real)
        catch
        end
        _TUI_REAL_STDOUT[] = nothing
    end
end

# ── Activity Feed ─────────────────────────────────────────────────────────────
# Unified timeline of tool calls and streaming REPL output. The MCPServer
# tool handler pushes :tool_start / :tool_done events here, and the view()
# loop drains gate SUB messages into :stdout / :stderr events.



const _TUI_ACTIVITY_BUFFER = ActivityEvent[]
const _TUI_ACTIVITY_LOCK = ReentrantLock()

"""
    _push_activity!(kind, tool_name, session_name, data; success=true)

Thread-safe push of an activity event. Called from the MCPServer tool handler.
"""
function _push_activity!(
    kind::Symbol,
    tool_name::String,
    session_name::String,
    data::String;
    success::Bool = true,
)
    lock(_TUI_ACTIVITY_LOCK) do
        push!(
            _TUI_ACTIVITY_BUFFER,
            ActivityEvent(now(), kind, tool_name, session_name, data, success),
        )
        while length(_TUI_ACTIVITY_BUFFER) > 500
            popfirst!(_TUI_ACTIVITY_BUFFER)
        end
    end
end

function _drain_activity_buffer!(dest::Vector{ActivityEvent})
    lock(_TUI_ACTIVITY_LOCK) do
        append!(dest, _TUI_ACTIVITY_BUFFER)
        empty!(_TUI_ACTIVITY_BUFFER)
    end
    while length(dest) > 2000
        popfirst!(dest)
    end
end



const _TUI_TOOL_RESULTS_BUFFER = ToolCallResult[]
const _TUI_TOOL_RESULTS_LOCK = ReentrantLock()

const _LAST_TOOL_SUCCESS = Ref{Float64}(0.0)
const _LAST_TOOL_ERROR = Ref{Float64}(0.0)
const _ECG_NEW_COMPLETIONS = Dict{String,Int}()  # session_key → count of new completions
const _ECG_NEW_COMPLETIONS_LOCK = ReentrantLock()

function _push_tool_result!(r::ToolCallResult)
    lock(_TUI_TOOL_RESULTS_LOCK) do
        push!(_TUI_TOOL_RESULTS_BUFFER, r)
        while length(_TUI_TOOL_RESULTS_BUFFER) > 500
            popfirst!(_TUI_TOOL_RESULTS_BUFFER)
        end
    end
    # Update health gauge timestamps (thread-safe via Ref)
    t = time()
    if r.success
        _LAST_TOOL_SUCCESS[] = t
    else
        _LAST_TOOL_ERROR[] = t
    end
    lock(_ECG_NEW_COMPLETIONS_LOCK) do
        k = r.session_key
        _ECG_NEW_COMPLETIONS[k] = get(_ECG_NEW_COMPLETIONS, k, 0) + 1
    end
end

"""
Record a tool call as 'running' in the SQLite database at execution start.
Returns the request_id (UUID string) for later update, or "" on failure.
"""
function _persist_tool_start!(tool_name::String, args_json::String, session_key::String)::String
    db = Database.DB[]
    db === nothing && return ""
    rid = string(UUIDs.uuid4())
    try
        Database.DBInterface.execute(
            db,
            """
    INSERT INTO tool_executions (
        session_key, request_id, tool_name, request_time,
        duration_ms, input_size, output_size, arguments,
        status, result_summary
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""",
            (
                session_key,
                rid,
                tool_name,
                Dates.format(now(), dateformat"yyyy-mm-dd HH:MM:SS"),
                0.0,
                sizeof(args_json),
                0,
                args_json,
                "running",
                "",
            ),
        )
    catch e
        @debug "Failed to persist tool start" exception = (e, catch_backtrace())
        return ""
    end
    return rid
end

"""
Update a previously-recorded tool call with its final result.
"""
function _persist_tool_complete!(db_request_id::String, r::ToolCallResult)
    db = Database.DB[]
    (db === nothing || isempty(db_request_id)) && return
    try
        dur_ms = if endswith(r.duration_str, "ms")
            parse(Float64, r.duration_str[1:end-2])
        elseif endswith(r.duration_str, "s")
            parse(Float64, r.duration_str[1:end-1]) * 1000.0
        else
            0.0
        end
        summary = length(r.result_text) > 500 ? r.result_text[1:500] : r.result_text
        Database.DBInterface.execute(
            db,
            """
    UPDATE tool_executions SET
        duration_ms = ?, output_size = ?, status = ?, result_summary = ?
    WHERE request_id = ?
""",
            (
                dur_ms,
                sizeof(r.result_text),
                r.success ? "success" : "error",
                summary,
                db_request_id,
            ),
        )
    catch e
        @debug "Failed to persist tool completion" exception = (e, catch_backtrace())
    end
end

"""
Drain tool results from the thread-safe buffer into `dest`.
Returns the number of new results drained (for updating counters).
"""
function _drain_tool_results!(dest::Vector{ToolCallResult})
    n = 0
    lock(_TUI_TOOL_RESULTS_LOCK) do
        n = length(_TUI_TOOL_RESULTS_BUFFER)
        append!(dest, _TUI_TOOL_RESULTS_BUFFER)
        empty!(_TUI_TOOL_RESULTS_BUFFER)
    end
    while length(dest) > 500
        popfirst!(dest)
    end
    return n
end



const _TUI_INFLIGHT_BUFFER = Tuple{Symbol,InFlightToolCall}[]  # (:start/:done/:progress, call)
const _TUI_INFLIGHT_LOCK = ReentrantLock()
const _INFLIGHT_ID_COUNTER = Ref{Int}(0)

"""Push an in-flight start event. Returns the unique inflight ID."""
function _push_inflight_start!(
    tool_name::String,
    args_json::String,
    session_key::String,
)::Int
    lock(_TUI_INFLIGHT_LOCK) do
        _INFLIGHT_ID_COUNTER[] += 1
        id = _INFLIGHT_ID_COUNTER[]
        ifc = InFlightToolCall(
            id,
            time(),
            now(),
            tool_name,
            args_json,
            session_key,
            "",
            String[],
        )
        push!(_TUI_INFLIGHT_BUFFER, (:start, ifc))
        return id
    end
end

"""Push an in-flight progress event (SSE streaming updates)."""
function _push_inflight_progress!(id::Int, message::String)
    lock(_TUI_INFLIGHT_LOCK) do
        ifc = InFlightToolCall(id, 0.0, now(), "", "", "", message, String[])
        push!(_TUI_INFLIGHT_BUFFER, (:progress, ifc))
    end
end

# Map eval_id → inflight_id for background jobs
const _JOB_INFLIGHT_MAP = Dict{String, Int}()
const _JOB_INFLIGHT_MAP_LOCK = ReentrantLock()

"""Register a background job's eval_id with its inflight_id."""
function _register_job_inflight!(eval_id::String, inflight_id::Int)
    lock(_JOB_INFLIGHT_MAP_LOCK) do
        _JOB_INFLIGHT_MAP[eval_id] = inflight_id
    end
end

"""Push inflight progress for a background job by eval_id."""
function _push_job_progress!(eval_id::String, message::String)
    inflight_id = lock(_JOB_INFLIGHT_MAP_LOCK) do
        get(_JOB_INFLIGHT_MAP, eval_id, 0)
    end
    inflight_id > 0 && _push_inflight_progress!(inflight_id, message)
end

"""Complete inflight for a background job by eval_id."""
function _finish_job_inflight!(eval_id::String)
    inflight_id = lock(_JOB_INFLIGHT_MAP_LOCK) do
        pop!(_JOB_INFLIGHT_MAP, eval_id, 0)
    end
    inflight_id > 0 && _push_inflight_done!(inflight_id)
end

"""Push an in-flight done event (tool finished executing)."""
function _push_inflight_done!(id::Int)
    lock(_TUI_INFLIGHT_LOCK) do
        ifc = InFlightToolCall(id, 0.0, now(), "", "", "", "", String[])
        push!(_TUI_INFLIGHT_BUFFER, (:done, ifc))
    end
end

"""Drain the in-flight buffer into the model's inflight_calls vector."""
function _drain_inflight_buffer!(dest::Vector{InFlightToolCall})
    lock(_TUI_INFLIGHT_LOCK) do
        for (kind, ifc) in _TUI_INFLIGHT_BUFFER
            if kind == :start
                push!(dest, ifc)
            elseif kind == :progress
                for existing in dest
                    if existing.id == ifc.id
                        existing.last_progress = ifc.last_progress
                        push!(existing.progress_lines, ifc.last_progress)
                        # Cap progress lines to avoid unbounded growth
                        while length(existing.progress_lines) > 200
                            popfirst!(existing.progress_lines)
                        end
                        break
                    end
                end
            elseif kind == :done
                idx = findfirst(x -> x.id == ifc.id, dest)
                idx !== nothing && deleteat!(dest, idx)
            end
        end
        empty!(_TUI_INFLIGHT_BUFFER)
    end
end


# ── Server Log Pane Helpers ───────────────────────────────────────────────────

function _log_entry_spans(entry::ServerLogEntry)
    time_str = Dates.format(entry.timestamp, "HH:MM:SS")
    level_str = rpad(string(entry.level), 5)
    level_style = if entry.level == :error
        tstyle(:error)
    elseif entry.level == :warn
        tstyle(:warning)
    else
        tstyle(:text_dim)
    end
    return Span[
        Span(time_str * " ", tstyle(:text_dim)),
        Span(level_str * " ", level_style),
        Span(entry.message, tstyle(:text)),
    ]
end

"""Build wrapped span lines for a single log entry. Prefix is "HH:MM:SS level " (15 chars)."""
function _log_entry_spans_wrapped(entry::ServerLogEntry, width::Int)
    time_str = Dates.format(entry.timestamp, "HH:MM:SS")
    level_str = rpad(string(entry.level), 5)
    level_style = if entry.level == :error
        tstyle(:error)
    elseif entry.level == :warn
        tstyle(:warning)
    else
        tstyle(:text_dim)
    end
    prefix_len = 15  # "HH:MM:SS level "
    msg = entry.message
    msg_width = max(10, width - prefix_len)
    lines = Vector{Span}[]
    if length(msg) <= msg_width
        push!(
            lines,
            Span[
                Span(time_str * " ", tstyle(:text_dim)),
                Span(level_str * " ", level_style),
                Span(msg, tstyle(:text)),
            ],
        )
    else
        # First line with prefix
        push!(
            lines,
            Span[
                Span(time_str * " ", tstyle(:text_dim)),
                Span(level_str * " ", level_style),
                Span(first(msg, msg_width), tstyle(:text)),
            ],
        )
        # Continuation lines indented to align with message
        rest = SubString(msg, nextind(msg, 0, msg_width + 1))
        indent = " "^prefix_len
        while !isempty(rest)
            chunk_len = min(length(rest), msg_width)
            push!(
                lines,
                Span[
                    Span(indent, tstyle(:text_dim)),
                    Span(first(rest, chunk_len), tstyle(:text)),
                ],
            )
            if chunk_len >= length(rest)
                break
            end
            rest = SubString(rest, nextind(rest, 0, chunk_len + 1))
        end
    end
    return lines
end

function _ensure_log_pane!(m::KaimonModel)
    if m.log_pane === nothing
        m.log_pane = ScrollPane(
            Vector{Span}[];
            following = true,
            reverse = true,
            block = nothing,
            show_scrollbar = true,
        )
        m._log_pane_synced = 0
    end
end

"""Sync new server_log entries into the ScrollPane."""
function _sync_log_pane!(m::KaimonModel, width::Int = 0)
    _ensure_log_pane!(m)
    pane = m.log_pane::ScrollPane
    n = length(m.server_log)
    if m._log_pane_synced > n
        # Log was truncated (ring buffer popfirst!), rebuild
        m._log_pane_synced = 0
        pane.content = Vector{Span}[]
    end
    for i = (m._log_pane_synced+1):n
        entry = m.server_log[i]
        if m.log_word_wrap && width > 0
            for line in _log_entry_spans_wrapped(entry, width)
                push_line!(pane, line)
            end
        else
            push_line!(pane, _log_entry_spans(entry))
        end
    end
    m._log_pane_synced = n
end

"""Rebuild the entire pane content (e.g. after toggling word wrap)."""
function _rebuild_log_pane!(m::KaimonModel, width::Int = 0)
    _ensure_log_pane!(m)
    pane = m.log_pane::ScrollPane
    lines = Vector{Span}[]
    for entry in m.server_log
        if m.log_word_wrap && width > 0
            append!(lines, _log_entry_spans_wrapped(entry, width))
        else
            push!(lines, _log_entry_spans(entry))
        end
    end
    set_content!(pane, lines)
    m._log_pane_synced = length(m.server_log)
end

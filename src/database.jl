"""
Database — persistent SQLite store for tool-call analytics, the Qdrant index-sync
ledger, test runs, and background jobs.

ENCAPSULATION CONTRACT: the connection (`_DB`) is private and is reachable ONLY
through `_withdb`, which holds `_LOCK` for the whole operation. SQLite.jl is not
thread-safe for concurrent use of a single connection (the Julia-level prepared-
statement cache + finalizers race → heap corruption), and this module is hit from
many threads (MCP request handlers, the TUI render loop, background job/index
workers). Routing every access through `_withdb` makes that lock impossible to
forget. Callers use the named functions below; nothing outside this module should
ever touch the connection or run raw SQL.
"""
module Database

using SQLite
using Dates
using DBInterface
using JSON
using DataFrames

export init_db!,
    get_default_db_path,
    is_ready,
    close_db!,
    get_tool_summary,
    get_tool_executions,
    get_error_hotspots,
    cleanup_old_data!,
    record_tool_start!,
    record_tool_complete!,
    record_indexed_file,
    get_indexed_file,
    get_indexed_files,
    remove_indexed_file,
    file_needs_reindex,
    get_stale_files,
    get_deleted_files,
    record_test_run!,
    get_test_runs,
    get_test_results,
    get_test_failures,
    persist_job!,
    update_job!,
    get_job,
    list_jobs,
    get_job_stats

# ── Connection (private) + the single guarded access path ─────────────────────

const _DB = Ref{Union{SQLite.DB,Nothing}}(nothing)
const _LOCK = ReentrantLock()   # reentrant so guarded ops can nest

"""
    _withdb(f, default=nothing)

The ONLY way to touch the connection. Holds `_LOCK` for the whole call and passes
the live connection to `f(db)`. Returns `default` if the DB isn't open. `f` MUST
materialize any query result before returning (never hand back a live cursor — it
would be stepped outside the lock). Private.
"""
function _withdb(f, default = nothing)
    lock(_LOCK) do
        db = _DB[]
        db === nothing ? default : f(db)
    end
end

# Write: run a statement under the lock; returns nothing.
_exec!(sql, params = ()) = (_withdb(db -> DBInterface.execute(db, sql, params)); nothing)

# Read → Vector{Dict} (materialized inside the lock). `default` when DB is closed.
_query(sql, params = ()) = _withdb(Dict[]) do db
    _df_to_dicts(DBInterface.execute(db, sql, params) |> DataFrame)
end

# Read → DataFrame (materialized inside the lock).
_query_df(sql, params = ()) = _withdb(DataFrame()) do db
    DBInterface.execute(db, sql, params) |> DataFrame
end

"""Convert a DataFrame to a Vector{Dict} for JSON serialization. Private."""
function _df_to_dicts(df::DataFrame)
    nrow(df) == 0 && return Dict[]
    return [Dict(names(df) .=> values(row)) for row in eachrow(df)]
end

# ── Lifecycle ─────────────────────────────────────────────────────────────────

"""Default DB path in the user's cache dir (resolved via the parent Kaimon module)."""
function get_default_db_path()
    # `kaimon_cache_dir` lives in the parent module; resolve at call time so the
    # default works regardless of caller scope.
    return joinpath(parentmodule(@__MODULE__).kaimon_cache_dir(), "kaimon.db")
end

"""True if the connection is open (readiness check; reads the private ref only)."""
is_ready() = _DB[] !== nothing

# Schema as data — created once on init. `IF NOT EXISTS` everywhere, so idempotent.
const _SCHEMA = String[
    """CREATE TABLE IF NOT EXISTS tool_executions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_key TEXT, request_id TEXT NOT NULL, tool_name TEXT NOT NULL,
        request_time DATETIME NOT NULL, duration_ms REAL,
        input_size INTEGER, output_size INTEGER, arguments TEXT,
        status TEXT NOT NULL, result_summary TEXT)""",
    "CREATE INDEX IF NOT EXISTS idx_tool_executions_session ON tool_executions(session_key, request_time DESC)",
    "CREATE INDEX IF NOT EXISTS idx_tool_executions_tool ON tool_executions(tool_name, request_time DESC)",
    "CREATE INDEX IF NOT EXISTS idx_tool_executions_status ON tool_executions(status, request_time DESC)",
    "CREATE INDEX IF NOT EXISTS idx_tool_executions_time ON tool_executions(request_time DESC)",
    """CREATE TABLE IF NOT EXISTS indexed_files (
        file_path TEXT PRIMARY KEY, collection TEXT NOT NULL, mtime REAL NOT NULL,
        indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP, chunk_count INTEGER DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS idx_indexed_files_collection ON indexed_files(collection)",
    """CREATE VIEW IF NOT EXISTS v_daily_tool_usage AS
    SELECT DATE(request_time) as date, tool_name, COUNT(*) as execution_count,
        AVG(duration_ms) as avg_duration_ms, MIN(duration_ms) as min_duration_ms,
        MAX(duration_ms) as max_duration_ms,
        SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_count,
        ROUND(100.0 * SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) / COUNT(*), 2) as error_rate_pct
    FROM tool_executions GROUP BY DATE(request_time), tool_name
    ORDER BY date DESC, execution_count DESC""",
    """CREATE TABLE IF NOT EXISTS test_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT, project_path TEXT NOT NULL,
        started_at DATETIME NOT NULL, finished_at DATETIME, status TEXT NOT NULL,
        pattern TEXT DEFAULT '', total_pass INTEGER DEFAULT 0, total_fail INTEGER DEFAULT 0,
        total_error INTEGER DEFAULT 0, total_tests INTEGER DEFAULT 0,
        duration_ms REAL DEFAULT 0, summary TEXT DEFAULT '')""",
    "CREATE INDEX IF NOT EXISTS idx_test_runs_project ON test_runs(project_path, started_at DESC)",
    """CREATE TABLE IF NOT EXISTS test_results (
        id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER NOT NULL REFERENCES test_runs(id),
        testset_name TEXT NOT NULL, depth INTEGER DEFAULT 0, pass_count INTEGER DEFAULT 0,
        fail_count INTEGER DEFAULT 0, error_count INTEGER DEFAULT 0, total_count INTEGER DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS idx_test_results_run ON test_results(run_id)",
    """CREATE TABLE IF NOT EXISTS test_failures (
        id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER NOT NULL REFERENCES test_runs(id),
        file TEXT, line INTEGER, expression TEXT, evaluated TEXT, testset_name TEXT, backtrace TEXT)""",
    "CREATE INDEX IF NOT EXISTS idx_test_failures_run ON test_failures(run_id)",
    """CREATE TABLE IF NOT EXISTS background_jobs (
        eval_id TEXT PRIMARY KEY, session_key TEXT NOT NULL, code TEXT NOT NULL,
        started_at REAL NOT NULL, finished_at REAL DEFAULT 0.0, promoted_at REAL NOT NULL,
        status TEXT NOT NULL DEFAULT 'running', result TEXT DEFAULT '',
        result_preview TEXT DEFAULT '', cancelled INTEGER DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS idx_background_jobs_status ON background_jobs(status)",
]

"""Open the connection and create the schema if absent. Idempotent. Returns the DB."""
function init_db!(db_path::String = get_default_db_path())
    mkpath(dirname(db_path))
    return lock(_LOCK) do
        db = SQLite.DB(db_path)
        _DB[] = db
        for ddl in _SCHEMA
            DBInterface.execute(db, ddl)
        end
        db
    end
end

"""Close the connection."""
function close_db!()
    lock(_LOCK) do
        _DB[] !== nothing && (SQLite.close(_DB[]); _DB[] = nothing)
    end
    return nothing
end

# ── Tool-call analytics (written on every tool completion, read by the TUI) ───

"""Record the start of a tool call (status 'running'). No-op if the DB is closed."""
record_tool_start!(session_key, request_id, tool_name, request_time, input_size, arguments) =
    _exec!("""INSERT INTO tool_executions
                  (session_key, request_id, tool_name, request_time,
                   duration_ms, input_size, output_size, arguments, status, result_summary)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (session_key, request_id, tool_name, request_time, 0.0, input_size, 0, arguments, "running", ""))

"""Update a tool call with its final result. No-op if DB closed / id empty."""
record_tool_complete!(request_id, duration_ms, output_size, status, summary) =
    isempty(request_id) ? nothing :
    _exec!("""UPDATE tool_executions
                 SET duration_ms = ?, output_size = ?, status = ?, result_summary = ?
               WHERE request_id = ?""",
        (duration_ms, output_size, status, summary, request_id))

"""Summary statistics (counts/durations) per tool."""
get_tool_summary() = _query(
    """SELECT tool_name, COUNT(*) as total_executions,
              COUNT(CASE WHEN status = 'success' THEN 1 END) as success_count,
              COUNT(CASE WHEN status = 'error' THEN 1 END) as error_count,
              AVG(duration_ms) as avg_duration_ms, MIN(duration_ms) as min_duration_ms,
              MAX(duration_ms) as max_duration_ms,
              AVG(input_size) as avg_input_size, AVG(output_size) as avg_output_size
       FROM tool_executions GROUP BY tool_name ORDER BY total_executions DESC""")

"""Tool executions from the last `days` days (most recent first, capped at 1000)."""
function get_tool_executions(; days::Int = 7)
    cutoff = Dates.format(now() - Day(days), "yyyy-mm-dd HH:MM:SS")
    return _query(
        """SELECT id, session_key, request_id, tool_name, request_time,
                  duration_ms, input_size, output_size, status, result_summary
           FROM tool_executions WHERE request_time >= ?
           ORDER BY request_time DESC LIMIT 1000""", (cutoff,))
end

"""Most frequent error-producing tools."""
get_error_hotspots() = _query(
    """SELECT tool_name, COUNT(*) as error_count,
              COUNT(DISTINCT session_key) as affected_sessions,
              MAX(request_time) as last_occurrence
       FROM tool_executions WHERE status = 'error'
       GROUP BY tool_name ORDER BY error_count DESC LIMIT 50""")

"""Delete tool execution records older than `days_to_keep` days."""
function cleanup_old_data!(days_to_keep::Int = 30)
    cutoff = Dates.format(now() - Dates.Day(days_to_keep), "yyyy-mm-dd HH:MM:SS.sss")
    _exec!("DELETE FROM tool_executions WHERE request_time < ?", (cutoff,))
end

# ── Indexed-files ledger (Qdrant vector-index sync) ───────────────────────────

"""Record that a file has been indexed into Qdrant."""
record_indexed_file(file_path::String, collection::String, file_mtime::Float64, chunk_count::Int) =
    _exec!("""INSERT OR REPLACE INTO indexed_files (file_path, collection, mtime, indexed_at, chunk_count)
              VALUES (?, ?, ?, CURRENT_TIMESTAMP, ?)""",
        [file_path, collection, file_mtime, chunk_count])

"""Indexing info for a file, or `nothing` if not indexed."""
function get_indexed_file(file_path::String)
    df = _query_df(
        "SELECT file_path, collection, mtime, indexed_at, chunk_count FROM indexed_files WHERE file_path = ?",
        [file_path])
    nrow(df) == 0 && return nothing
    return (file_path = df[1, :file_path], collection = df[1, :collection], mtime = df[1, :mtime],
            indexed_at = df[1, :indexed_at], chunk_count = df[1, :chunk_count])
end

"""All indexed files for a collection (DataFrame)."""
get_indexed_files(collection::String) = _query_df(
    "SELECT file_path, mtime, indexed_at, chunk_count FROM indexed_files WHERE collection = ?", [collection])

"""Remove a file from the indexed-files ledger."""
remove_indexed_file(file_path::String) =
    _exec!("DELETE FROM indexed_files WHERE file_path = ?", [file_path])

"""True if `file_path` should be (re-)indexed (changed or never indexed)."""
function file_needs_reindex(file_path::String)
    isfile(file_path) || return false
    indexed = get_indexed_file(file_path)
    indexed === nothing && return true
    return mtime(file_path) > indexed.mtime
end

"""All `.jl` files under `project_dir` that need re-indexing."""
function get_stale_files(project_dir::String)
    stale = String[]
    for (root, dirs, files) in walkdir(project_dir)
        filter!(d -> !startswith(d, ".") && d != "node_modules", dirs)
        for file in files
            if endswith(file, ".jl")
                fp = joinpath(root, file)
                file_needs_reindex(fp) && push!(stale, fp)
            end
        end
    end
    return stale
end

"""Indexed files for a collection that no longer exist on disk."""
function get_deleted_files(collection::String)
    return [row.file_path for row in eachrow(get_indexed_files(collection)) if !isfile(row.file_path)]
end

# ── Test runs ─────────────────────────────────────────────────────────────────

const _INSERT_TEST_RUN = """INSERT INTO test_runs
    (project_path, started_at, finished_at, status, pattern, total_pass, total_fail,
     total_error, total_tests, duration_ms, summary)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"""
const _INSERT_TEST_RESULT = """INSERT INTO test_results
    (run_id, testset_name, depth, pass_count, fail_count, error_count, total_count)
    VALUES (?, ?, ?, ?, ?, ?, ?)"""
const _INSERT_TEST_FAILURE = """INSERT INTO test_failures
    (run_id, file, line, expression, evaluated, testset_name, backtrace)
    VALUES (?, ?, ?, ?, ?, ?, ?)"""

"""
    record_test_run!(run, results, failures)

Persist a completed test run and its child rows in ONE locked, atomic unit (so the
`last_insert_rowid()` stays paired with its INSERT). `run` is a NamedTuple of the
test_runs columns; `results`/`failures` are vectors of NamedTuples with the
test_results / test_failures fields (`name` for the testset name, `testset` for the
failure's testset name). Keeps the SQL in this module — callers build plain data.
"""
function record_test_run!(run, results, failures)
    _withdb() do db
        DBInterface.execute(db, _INSERT_TEST_RUN,
            (run.project_path, run.started_at, run.finished_at, run.status, run.pattern,
             run.total_pass, run.total_fail, run.total_error, run.total_tests, run.duration_ms, run.summary))
        run_id = (DBInterface.execute(db, "SELECT last_insert_rowid()") |> DataFrame)[1, 1]
        for r in results
            DBInterface.execute(db, _INSERT_TEST_RESULT,
                (run_id, r.name, r.depth, r.pass_count, r.fail_count, r.error_count, r.total_count))
        end
        for f in failures
            DBInterface.execute(db, _INSERT_TEST_FAILURE,
                (run_id, f.file, f.line, f.expression, f.evaluated, f.testset, f.backtrace))
        end
    end
    return nothing
end

"""Recent test runs, optionally filtered by project path."""
function get_test_runs(; project_path::String = "", limit::Int = 50)
    cols = """id, project_path, started_at, finished_at, status, pattern,
              total_pass, total_fail, total_error, total_tests, duration_ms, summary"""
    return isempty(project_path) ?
        _query("SELECT $cols FROM test_runs ORDER BY started_at DESC LIMIT ?", (limit,)) :
        _query("SELECT $cols FROM test_runs WHERE project_path = ? ORDER BY started_at DESC LIMIT ?",
            (project_path, limit))
end

"""Per-testset results for a test run."""
get_test_results(run_id::Int) = _query(
    """SELECT id, run_id, testset_name, depth, pass_count, fail_count, error_count, total_count
       FROM test_results WHERE run_id = ? ORDER BY id""", (run_id,))

"""Failure details for a test run."""
get_test_failures(run_id::Int) = _query(
    """SELECT id, run_id, file, line, expression, evaluated, testset_name, backtrace
       FROM test_failures WHERE run_id = ? ORDER BY id""", (run_id,))

# ── Background jobs (best-effort: failures are swallowed, never crash a caller) ─

"""Persist a promoted background job."""
function persist_job!(eval_id::String, session_key::String, code::String,
                      started_at::Float64, promoted_at::Float64)
    try
        _exec!("""INSERT OR REPLACE INTO background_jobs
                      (eval_id, session_key, code, started_at, promoted_at, status)
                  VALUES (?, ?, ?, ?, ?, 'running')""",
            [eval_id, session_key, first(code, 2000), started_at, promoted_at])
    catch e
        @debug "Failed to persist background job" eval_id exception = e
    end
end

"""Update a background job's status/result (only the provided fields)."""
function update_job!(eval_id::String; status::String = "", result::String = "",
                     result_preview::String = "", finished_at::Float64 = 0.0,
                     cancelled::Bool = false)
    sets = String[]
    vals = Any[]
    isempty(status) || (push!(sets, "status = ?"); push!(vals, status))
    isempty(result) || (push!(sets, "result = ?"); push!(vals, result))
    isempty(result_preview) || (push!(sets, "result_preview = ?"); push!(vals, first(result_preview, 500)))
    finished_at > 0.0 && (push!(sets, "finished_at = ?"); push!(vals, finished_at))
    cancelled && push!(sets, "cancelled = 1")
    isempty(sets) && return
    push!(vals, eval_id)
    try
        _exec!("UPDATE background_jobs SET $(join(sets, ", ")) WHERE eval_id = ?", vals)
    catch e
        @debug "Failed to update background job" eval_id exception = e
    end
end

"""A background job by eval_id (prefix match), or `nothing`."""
function get_job(eval_id::String)
    try
        df = _query_df(
            "SELECT * FROM background_jobs WHERE eval_id LIKE ? ORDER BY promoted_at DESC LIMIT 1",
            [eval_id * "%"])
        nrow(df) == 0 ? nothing : Dict(String(c) => df[1, c] for c in names(df))
    catch
        nothing
    end
end

"""Background jobs, optionally filtered by status."""
function list_jobs(; status::String = "", limit::Int = 20)
    try
        sql, params = isempty(status) ?
            ("SELECT * FROM background_jobs ORDER BY promoted_at DESC LIMIT ?", Any[limit]) :
            ("SELECT * FROM background_jobs WHERE status = ? ORDER BY promoted_at DESC LIMIT ?", Any[status, limit])
        df = _query_df(sql, params)
        [Dict(String(c) => row[c] for c in names(df)) for row in eachrow(df)]
    catch
        Dict[]
    end
end

"""Aggregate stats over background jobs."""
function get_job_stats()
    try
        df = _query_df(
            """SELECT COUNT(*) as total,
                   SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) as running,
                   SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) as completed,
                   SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) as failed,
                   SUM(CASE WHEN cancelled = 1 THEN 1 ELSE 0 END) as cancelled,
                   AVG(CASE WHEN finished_at > 0 THEN finished_at - started_at END) as avg_duration,
                   MAX(CASE WHEN finished_at > 0 THEN finished_at - started_at END) as max_duration
               FROM background_jobs""")
        nrow(df) == 0 ? Dict() : Dict(String(c) => df[1, c] for c in names(df))
    catch
        Dict()
    end
end

end # module

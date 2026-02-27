"""
Database Schema for Kaimon Analytics

Persistent storage of tool call analytics and Qdrant index tracking.
"""
module Database

using SQLite
using Dates
using DBInterface
using JSON
using DataFrames

export init_db!,
    get_default_db_path,
    get_tool_summary,
    get_tool_executions,
    get_error_hotspots,
    get_test_runs,
    get_test_results,
    get_test_failures,
    cleanup_old_data!,
    close_db!

# Global database connection
const DB = Ref{Union{SQLite.DB,Nothing}}(nothing)

"""
    get_default_db_path() -> String

Get the default database path in the user's cache directory.
"""
function get_default_db_path()
    return joinpath(kaimon_cache_dir(), "kaimon.db")
end

"""
Initialize the SQLite database with schema.
Creates tables if they don't exist.
"""
function init_db!(db_path::String = get_default_db_path())
    mkpath(dirname(db_path))

    db = SQLite.DB(db_path)
    DB[] = db

    # ── Tool Executions ──────────────────────────────────────────────────────
    # Written by _persist_tool_call! in tui.jl on every tool completion.
    # Read by the analytics view in the TUI.
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS tool_executions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_key TEXT,
        request_id TEXT NOT NULL,
        tool_name TEXT NOT NULL,
        request_time DATETIME NOT NULL,
        duration_ms REAL,
        input_size INTEGER,
        output_size INTEGER,
        arguments TEXT,
        status TEXT NOT NULL,
        result_summary TEXT
    )
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_tool_executions_session
    ON tool_executions(session_key, request_time DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_tool_executions_tool
    ON tool_executions(tool_name, request_time DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_tool_executions_status
    ON tool_executions(status, request_time DESC)
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_tool_executions_time
    ON tool_executions(request_time DESC)
""",
    )

    # ── Indexed Files (Qdrant sync) ──────────────────────────────────────────
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS indexed_files (
        file_path TEXT PRIMARY KEY,
        collection TEXT NOT NULL,
        mtime REAL NOT NULL,
        indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        chunk_count INTEGER DEFAULT 0
    )
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_indexed_files_collection
    ON indexed_files(collection)
""",
    )

    # ── Daily Tool Usage View ────────────────────────────────────────────────
    DBInterface.execute(
        db,
        """
    CREATE VIEW IF NOT EXISTS v_daily_tool_usage AS
    SELECT
        DATE(request_time) as date,
        tool_name,
        COUNT(*) as execution_count,
        AVG(duration_ms) as avg_duration_ms,
        MIN(duration_ms) as min_duration_ms,
        MAX(duration_ms) as max_duration_ms,
        SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_count,
        ROUND(100.0 * SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) / COUNT(*), 2) as error_rate_pct
    FROM tool_executions
    GROUP BY DATE(request_time), tool_name
    ORDER BY date DESC, execution_count DESC
""",
    )

    # ── Test Runs ────────────────────────────────────────────────────────────
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS test_runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_path TEXT NOT NULL,
        started_at DATETIME NOT NULL,
        finished_at DATETIME,
        status TEXT NOT NULL,
        pattern TEXT DEFAULT '',
        total_pass INTEGER DEFAULT 0,
        total_fail INTEGER DEFAULT 0,
        total_error INTEGER DEFAULT 0,
        total_tests INTEGER DEFAULT 0,
        duration_ms REAL DEFAULT 0,
        summary TEXT DEFAULT ''
    )
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_test_runs_project
    ON test_runs(project_path, started_at DESC)
""",
    )

    # ── Test Results (per-testset breakdown) ─────────────────────────────────
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS test_results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id INTEGER NOT NULL REFERENCES test_runs(id),
        testset_name TEXT NOT NULL,
        depth INTEGER DEFAULT 0,
        pass_count INTEGER DEFAULT 0,
        fail_count INTEGER DEFAULT 0,
        error_count INTEGER DEFAULT 0,
        total_count INTEGER DEFAULT 0
    )
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_test_results_run
    ON test_results(run_id)
""",
    )

    # ── Test Failures ────────────────────────────────────────────────────────
    DBInterface.execute(
        db,
        """
    CREATE TABLE IF NOT EXISTS test_failures (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id INTEGER NOT NULL REFERENCES test_runs(id),
        file TEXT,
        line INTEGER,
        expression TEXT,
        evaluated TEXT,
        testset_name TEXT,
        backtrace TEXT
    )
""",
    )

    DBInterface.execute(
        db,
        """
    CREATE INDEX IF NOT EXISTS idx_test_failures_run
    ON test_failures(run_id)
""",
    )

    return db
end

# ═══════════════════════════════════════════════════════════════════════════════
# Analytics Queries (read by TUI)
# ═══════════════════════════════════════════════════════════════════════════════

"""
    get_tool_summary() -> Vector{Dict}

Get summary statistics of tool usage.
Returns aggregated counts and metrics per tool.
"""
function get_tool_summary()
    db = DB[]
    db === nothing && return Dict[]

    result =
        DBInterface.execute(
            db,
            """
            SELECT
                tool_name,
                COUNT(*) as total_executions,
                COUNT(CASE WHEN status = 'success' THEN 1 END) as success_count,
                COUNT(CASE WHEN status = 'error' THEN 1 END) as error_count,
                AVG(duration_ms) as avg_duration_ms,
                MIN(duration_ms) as min_duration_ms,
                MAX(duration_ms) as max_duration_ms,
                AVG(input_size) as avg_input_size,
                AVG(output_size) as avg_output_size
            FROM tool_executions
            GROUP BY tool_name
            ORDER BY total_executions DESC
            """,
        ) |> DataFrame

    return dataframe_to_array(result)
end

"""
    get_tool_executions(; days::Int = 7) -> Vector{Dict}

Get tool execution analytics from the last N days.
"""
function get_tool_executions(; days::Int = 7)
    db = DB[]
    db === nothing && return Dict[]

    cutoff_date = Dates.format(now() - Day(days), "yyyy-mm-dd HH:MM:SS")

    result =
        DBInterface.execute(
            db,
            """
            SELECT
                id, session_key, request_id,
                tool_name, request_time,
                duration_ms, input_size, output_size,
                status, result_summary
            FROM tool_executions
            WHERE request_time >= ?
            ORDER BY request_time DESC
            LIMIT 1000
            """,
            (cutoff_date,),
        ) |> DataFrame

    return dataframe_to_array(result)
end

"""
    get_error_hotspots() -> Vector{Dict}

Get most frequent error-producing tools.
"""
function get_error_hotspots()
    db = DB[]
    db === nothing && return Dict[]

    result =
        DBInterface.execute(
            db,
            """
            SELECT
                tool_name,
                COUNT(*) as error_count,
                COUNT(DISTINCT session_key) as affected_sessions,
                MAX(request_time) as last_occurrence
            FROM tool_executions
            WHERE status = 'error'
            GROUP BY tool_name
            ORDER BY error_count DESC
            LIMIT 50
            """,
        ) |> DataFrame

    return dataframe_to_array(result)
end

"""
    cleanup_old_data!(days_to_keep::Int = 30)

Delete old tool execution records beyond a certain age.
"""
function cleanup_old_data!(days_to_keep::Int = 30)
    db = DB[]
    db === nothing && return

    cutoff_date = now() - Dates.Day(days_to_keep)
    cutoff_str = Dates.format(cutoff_date, "yyyy-mm-dd HH:MM:SS.sss")

    DBInterface.execute(
        db,
        "DELETE FROM tool_executions WHERE request_time < ?",
        (cutoff_str,),
    )
end

# ═══════════════════════════════════════════════════════════════════════════════
# Indexed Files Tracking (for Qdrant vector index sync)
# ═══════════════════════════════════════════════════════════════════════════════

"""
    record_indexed_file(file_path::String, collection::String, mtime::Float64, chunk_count::Int)

Record that a file has been indexed into Qdrant.
"""
function record_indexed_file(
    file_path::String,
    collection::String,
    file_mtime::Float64,
    chunk_count::Int,
)
    db = DB[]
    DBInterface.execute(
        db,
        """
        INSERT OR REPLACE INTO indexed_files (file_path, collection, mtime, indexed_at, chunk_count)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP, ?)
        """,
        [file_path, collection, file_mtime, chunk_count],
    )
end

"""
    get_indexed_file(file_path::String) -> Union{NamedTuple, Nothing}

Get indexing info for a file, or nothing if not indexed.
"""
function get_indexed_file(file_path::String)
    db = DB[]
    result =
        DBInterface.execute(
            db,
            "SELECT file_path, collection, mtime, indexed_at, chunk_count FROM indexed_files WHERE file_path = ?",
            [file_path],
        ) |> DataFrame

    if nrow(result) == 0
        return nothing
    end

    return (
        file_path = result[1, :file_path],
        collection = result[1, :collection],
        mtime = result[1, :mtime],
        indexed_at = result[1, :indexed_at],
        chunk_count = result[1, :chunk_count],
    )
end

"""
    get_indexed_files(collection::String) -> DataFrame

Get all indexed files for a collection.
"""
function get_indexed_files(collection::String)
    db = DB[]
    return DBInterface.execute(
        db,
        "SELECT file_path, mtime, indexed_at, chunk_count FROM indexed_files WHERE collection = ?",
        [collection],
    ) |> DataFrame
end

"""
    remove_indexed_file(file_path::String)

Remove a file from the indexed files tracking.
"""
function remove_indexed_file(file_path::String)
    db = DB[]
    DBInterface.execute(db, "DELETE FROM indexed_files WHERE file_path = ?", [file_path])
end

"""
    file_needs_reindex(file_path::String) -> Bool

Check if a file needs to be re-indexed (file changed or not indexed).
Returns true if file should be (re-)indexed.
"""
function file_needs_reindex(file_path::String)
    if !isfile(file_path)
        return false
    end

    indexed = get_indexed_file(file_path)
    if indexed === nothing
        return true
    end

    current_mtime = mtime(file_path)
    return current_mtime > indexed.mtime
end

"""
    get_stale_files(project_dir::String) -> Vector{String}

Get list of files that need re-indexing.
"""
function get_stale_files(project_dir::String)
    stale = String[]

    for (root, dirs, files) in walkdir(project_dir)
        filter!(d -> !startswith(d, ".") && d != "node_modules", dirs)

        for file in files
            if endswith(file, ".jl")
                file_path = joinpath(root, file)
                if file_needs_reindex(file_path)
                    push!(stale, file_path)
                end
            end
        end
    end

    return stale
end

"""
    get_deleted_files(collection::String) -> Vector{String}

Get list of indexed files that no longer exist on disk.
"""
function get_deleted_files(collection::String)
    deleted = String[]
    indexed = get_indexed_files(collection)

    for row in eachrow(indexed)
        if !isfile(row.file_path)
            push!(deleted, row.file_path)
        end
    end

    return deleted
end

# ═══════════════════════════════════════════════════════════════════════════════
# Test Run Queries
# ═══════════════════════════════════════════════════════════════════════════════

"""
    get_test_runs(; project_path="", limit=50) -> Vector{Dict}

Get recent test runs, optionally filtered by project path.
"""
function get_test_runs(; project_path::String = "", limit::Int = 50)
    db = DB[]
    db === nothing && return Dict[]

    if isempty(project_path)
        result =
            DBInterface.execute(
                db,
                """
                SELECT id, project_path, started_at, finished_at, status,
                       pattern, total_pass, total_fail, total_error,
                       total_tests, duration_ms, summary
                FROM test_runs
                ORDER BY started_at DESC
                LIMIT ?
                """,
                (limit,),
            ) |> DataFrame
    else
        result =
            DBInterface.execute(
                db,
                """
                SELECT id, project_path, started_at, finished_at, status,
                       pattern, total_pass, total_fail, total_error,
                       total_tests, duration_ms, summary
                FROM test_runs
                WHERE project_path = ?
                ORDER BY started_at DESC
                LIMIT ?
                """,
                (project_path, limit),
            ) |> DataFrame
    end

    return dataframe_to_array(result)
end

"""
    get_test_results(run_id::Int) -> Vector{Dict}

Get per-testset results for a test run.
"""
function get_test_results(run_id::Int)
    db = DB[]
    db === nothing && return Dict[]

    result =
        DBInterface.execute(
            db,
            """
            SELECT id, run_id, testset_name, depth,
                   pass_count, fail_count, error_count, total_count
            FROM test_results
            WHERE run_id = ?
            ORDER BY id
            """,
            (run_id,),
        ) |> DataFrame

    return dataframe_to_array(result)
end

"""
    get_test_failures(run_id::Int) -> Vector{Dict}

Get failure details for a test run.
"""
function get_test_failures(run_id::Int)
    db = DB[]
    db === nothing && return Dict[]

    result =
        DBInterface.execute(
            db,
            """
            SELECT id, run_id, file, line, expression,
                   evaluated, testset_name, backtrace
            FROM test_failures
            WHERE run_id = ?
            ORDER BY id
            """,
            (run_id,),
        ) |> DataFrame

    return dataframe_to_array(result)
end

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

"""Convert DataFrame to array of dictionaries for JSON serialization."""
function dataframe_to_array(df::DataFrame)
    if nrow(df) == 0
        return Dict[]
    end
    result = Dict[]
    for row in eachrow(df)
        push!(result, Dict(names(df) .=> values(row)))
    end
    return result
end

"""Close the database connection."""
function close_db!()
    if DB[] !== nothing
        SQLite.close(DB[])
        DB[] = nothing
    end
end

end # module

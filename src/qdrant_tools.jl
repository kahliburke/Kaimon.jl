"""
MCP Tools for Qdrant Vector Database

Tools for semantic code search using Qdrant.
"""

using Logging
import ..QdrantClient

# Default embedding model (used by both qdrant_tools and qdrant_indexer)
const DEFAULT_EMBEDDING_MODEL = "qwen3-embedding:0.6b"

# Note: Embeddings are maintained by external process
# The search tool below requires embeddings to be generated externally or via Ollama
# The browse/list tools work without needing embeddings

# ============================================================================
# Optional: Ollama Embeddings Helper (if needed for search)
# ============================================================================

"""
    get_ollama_embedding(text::String; model::String=DEFAULT_EMBEDDING_MODEL) -> Vector{Float64}

Get embedding for text using Ollama `/api/embed` endpoint.
"""
function get_ollama_embedding(text::String; model::String = DEFAULT_EMBEDDING_MODEL)
    try
        body = Dict("model" => model, "input" => text)

        response = HTTP.post(
            "http://localhost:11434/api/embed",
            ["Content-Type" => "application/json"],
            JSON.json(body),
        )
        body_text = String(response.body)

        if response.status != 200
            preview = body_text
            if length(preview) > 500
                preview = first(preview, 500) * "..."
            end
            @warn "Ollama embedding request failed" status = response.status model = model body =
                preview
            return Float64[]
        end

        data = try
            JSON.parse(body_text)
        catch e
            preview = body_text
            if length(preview) > 500
                preview = first(preview, 500) * "..."
            end
            @warn "Ollama embedding response parse failed" model = model body = preview exception =
                e
            return Float64[]
        end

        embeddings = get(data, "embeddings", [])
        if isempty(embeddings) || isempty(first(embeddings))
            preview = body_text
            if length(preview) > 500
                preview = first(preview, 500) * "..."
            end
            @warn "Ollama embedding empty" model = model body = preview
            return Float64[]
        end

        return Float64.(first(embeddings))
    catch e
        @warn "Ollama embedding request error" model = model exception = e
        return Float64[]
    end
end

# ============================================================================
# Health Checks & Service Guards
# ============================================================================

"""
    ping_ollama() -> Bool

Check if Ollama is reachable via GET /api/tags with a 2-second timeout.
"""
function ping_ollama()
    try
        response = HTTP.get(
            "http://localhost:11434/api/tags";
            connect_timeout = 2,
            request_timeout = 3,
        )
        return response.status == 200
    catch
        return false
    end
end

"""
    check_ollama_model(model::String) -> Bool

Check if a specific model is available in Ollama.
"""
function check_ollama_model(model::String)
    try
        response = HTTP.get(
            "http://localhost:11434/api/tags";
            connect_timeout = 2,
            request_timeout = 3,
        )
        data = JSON.parse(String(response.body))
        models = get(data, "models", [])
        for m in models
            name = get(m, "name", "")
            # Match "snowflake-arctic-embed:latest" or just "snowflake-arctic-embed"
            if name == model || startswith(name, split(model, ":")[1])
                return true
            end
        end
        return false
    catch
        return false
    end
end

"""
    list_ollama_models() -> Vector{String}

Return names of all models installed in Ollama.
Calls `GET /api/tags` and extracts the `name` field from each entry.
Returns an empty vector on error or if Ollama is unreachable.
"""
function list_ollama_models()
    try
        response = HTTP.get(
            "http://localhost:11434/api/tags";
            connect_timeout = 2,
            request_timeout = 3,
        )
        data = JSON.parse(String(response.body))
        models = get(data, "models", [])
        return String[get(m, "name", "") for m in models]
    catch
        return String[]
    end
end

"""
    check_search_health(; model=DEFAULT_EMBEDDING_MODEL)

Returns a NamedTuple (qdrant_up, ollama_up, model_available, collection_count,
fts_chunks, fts_collections) — the last two report local lexical-index coverage.
"""
function check_search_health(; model::String = DEFAULT_EMBEDDING_MODEL)
    qdrant_up = QdrantClient.ping()
    ollama_up = ping_ollama()
    model_available = ollama_up ? check_ollama_model(model) : false
    collection_count = qdrant_up ? length(QdrantClient.list_collections()) : 0
    # Lexical (FTS5) coverage — local, so available even when Qdrant/Ollama are down.
    fts_chunks, fts_collections = try
        cov = FtsIndex.coverage()
        (cov.total, length(cov.collections))
    catch
        (0, 0)
    end
    return (
        qdrant_up = qdrant_up,
        ollama_up = ollama_up,
        model_available = model_available,
        collection_count = collection_count,
        fts_chunks = fts_chunks,
        fts_collections = fts_collections,
    )
end

"""
    _require_services(; need_qdrant=true, need_ollama=false, model=DEFAULT_EMBEDDING_MODEL) -> Union{String,Nothing}

Pre-flight check before tool execution. Returns a friendly error string if
any required service is unavailable, or `nothing` if all checks pass.
"""
function _require_services(;
    need_qdrant::Bool = true,
    need_ollama::Bool = false,
    model::String = DEFAULT_EMBEDDING_MODEL,
)
    if need_qdrant && !QdrantClient.ping()
        return "Qdrant is not reachable at $(QdrantClient.QDRANT_URL[]). Is it running? (e.g., `docker run -p 6333:6333 qdrant/qdrant`)"
    end
    if need_ollama
        if !ping_ollama()
            return "Ollama is not reachable at http://localhost:11434. Is it running? (e.g., `ollama serve`)"
        end
        if !check_ollama_model(model)
            return "Ollama model '$model' is not available. Pull it with: `ollama pull $model`"
        end
    end
    return nothing
end

# ============================================================================
# MCP Tool Definitions
# ============================================================================

mutable struct QdrantIndexLogger <: AbstractLogger
    records::Vector{NamedTuple}
    min_level::LogLevel
end

QdrantIndexLogger(; min_level::LogLevel = Logging.Warn) =
    QdrantIndexLogger(NamedTuple[], min_level)

Logging.min_enabled_level(logger::QdrantIndexLogger) = logger.min_level
Logging.shouldlog(logger::QdrantIndexLogger, level, _module, group, id) =
    level >= logger.min_level

function Logging.handle_message(
    logger::QdrantIndexLogger,
    level,
    message,
    _module,
    group,
    id,
    file,
    line;
    kwargs...,
)
    push!(
        logger.records,
        (
            level = level,
            message = message,
            mod = _module,
            file = file,
            line = line,
            kwargs = kwargs,
        ),
    )
end

function format_indexing_report(message::String, records::Vector{NamedTuple})
    error_count = count(r -> r.level >= Logging.Error, records)
    warn_count = count(r -> r.level == Logging.Warn, records)

    output = message
    if error_count > 0 || warn_count > 0
        output *= "\n\n⚠️  Indexing reported $warn_count warnings and $error_count errors."
        max_records = 20
        for (i, record) in enumerate(records)
            if i > max_records
                output *= "\n... (truncated; total $(length(records)) records)"
                break
            end
            level = record.level
            msg = record.message
            output *= "\n- [$level] $msg"
            if !isempty(record.kwargs)
                details = join([string(k, "=", v) for (k, v) in pairs(record.kwargs)], ", ")
                output *= " (" * details * ")"
            end
        end
    end

    return output
end

qdrant_list_collections_tool = @mcp_tool(
    :qdrant_list_collections,
    "List all available Qdrant vector collections. Shows which code collections are available for semantic search.",
    Dict("type" => "object", "properties" => Dict(), "required" => []),
    function (args)
        err = _require_services()
        err !== nothing && return err

        collections = QdrantClient.list_collections()

        if isempty(collections)
            return "No collections found in Qdrant."
        end

        result = "📚 Available Collections:\n\n"
        for (i, name) in enumerate(collections)
            info = QdrantClient.get_collection_info(name)
            vector_count = get(get(info, "vectors_count", Dict()), "count", "unknown")
            result *= "$i. $name (vectors: $vector_count)\n"
        end

        return result
    end
)

qdrant_collection_info_tool = @mcp_tool(
    :qdrant_collection_info,
    "Get detailed information about a Qdrant collection including vector count, size, and configuration.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "collection" =>
                Dict("type" => "string", "description" => "Name of the collection"),
        ),
        "required" => ["collection"],
    ),
    function (args)
        err = _require_services()
        err !== nothing && return err

        raw_collection = get(args, "collection", "")
        if isempty(raw_collection)
            return "Error: collection name is required"
        end

        collections = QdrantClient.list_collections()
        collection, col_err = _resolve_collection(raw_collection, collections)
        if col_err !== nothing
            return "Error: $col_err"
        end

        info = QdrantClient.get_collection_info(collection)

        if haskey(info, "error")
            return "Error: $(info["error"])"
        end

        # Format the info nicely
        result = "📊 Collection: $collection\n\n"

        if haskey(info, "vectors_count")
            result *= "Vectors: $(info["vectors_count"])\n"
        end

        if haskey(info, "points_count")
            result *= "Points: $(info["points_count"])\n"
        end

        if haskey(info, "config")
            config = info["config"]
            if haskey(config, "params") && haskey(config["params"], "vectors")
                vectors_config = config["params"]["vectors"]
                if haskey(vectors_config, "size")
                    result *= "Vector dimension: $(vectors_config["size"])\n"
                end
                if haskey(vectors_config, "distance")
                    result *= "Distance metric: $(vectors_config["distance"])\n"
                end
            end
        end

        return result
    end
)

# Shared JSON schema for the code-search tool (used by the `search_code` primary
# and the deprecated `qdrant_search_code` alias).
const _SEARCH_CODE_PARAMS = Dict(
    "type" => "object",
    "properties" => Dict(
        "query" => Dict(
            "type" => "string",
            "description" => "Search query — natural language ('function that handles HTTP routing') or an exact symbol/string ('_eval_with_capture').",
        ),
        "collection" => Dict(
            "type" => "string",
            "description" => "Collection name to search (optional, defaults to last-used session's project)",
        ),
        "cross_project" => Dict(
            "type" => "boolean",
            "description" => "Search across ALL indexed projects at once (default: false). Ignores 'collection' when true.",
        ),
        "limit" => Dict(
            "type" => "integer",
            "description" => "Maximum number of results (default: 5)",
        ),
        "chunk_type" => Dict(
            "type" => "string",
            "description" => "Filter by chunk type: 'definitions' (functions/structs only), 'windows' (sliding window chunks only), or 'all' (default: all)",
            "enum" => ["all", "definitions", "windows"],
        ),
        "embedding_model" => Dict(
            "type" => "string",
            "description" => "Ollama model for embeddings (default: $DEFAULT_EMBEDDING_MODEL)",
        ),
        "mode" => Dict(
            "type" => "string",
            "description" => "Search mode: 'hybrid' (default — semantic + keyword), 'semantic' (vector only), or 'lexical' (exact keyword/identifier only; works even when embeddings are unavailable).",
            "enum" => ["hybrid", "semantic", "lexical"],
        ),
    ),
    "required" => ["query"],
)

# Primary, backend-agnostic name. Implementation lives in qdrant_hybrid.jl
# (`_qdrant_search_code`) so the semantic + lexical fusion stays readable/testable.
search_code_tool = @mcp_tool(
    :search_code,
    "Search indexed code — the primary way to find code; prefer it over grep/find. Combines semantic (meaning-based) vector search with exact keyword/identifier matching, fused and ranked together. Use it to locate code by concept ('function that handles HTTP routing') OR by exact symbol/string ('_eval_with_capture') — it finds exact identifiers too, so you don't need grep for that. Works even when embeddings are unavailable (lexical fallback). Defaults to the last-used session's project; set cross_project=true to search all. Supports FTS syntax in the keyword half (phrases, AND/OR/NOT, prefix term*).",
    _SEARCH_CODE_PARAMS,
    args -> _qdrant_search_code(args),
)

# Deprecated alias kept for back-compat (CLAUDE.md / configs / clients that still
# reference the old name). Same arguments + handler. Remove in a future release.
qdrant_search_code_tool = @mcp_tool(
    :qdrant_search_code,
    "DEPRECATED alias of `search_code` (same arguments) — use search_code. Hybrid semantic + lexical code search.",
    _SEARCH_CODE_PARAMS,
    args -> _qdrant_search_code(args),
)

qdrant_browse_collection_tool = @mcp_tool(
    :qdrant_browse_collection,
    "Browse points in a collection with pagination. Useful for exploring what's indexed.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "collection" =>
                Dict("type" => "string", "description" => "Name of the collection"),
            "limit" => Dict(
                "type" => "integer",
                "description" => "Number of points to retrieve (default: 10)",
            ),
        ),
        "required" => ["collection"],
    ),
    function (args)
        err = _require_services()
        err !== nothing && return err

        raw_collection = get(args, "collection", "")
        limit = get(args, "limit", 10)

        if isempty(raw_collection)
            return "Error: collection name is required"
        end

        collections = QdrantClient.list_collections()
        collection, col_err = _resolve_collection(raw_collection, collections)
        if col_err !== nothing
            return "Error: $col_err"
        end

        result = QdrantClient.scroll_points(collection; limit = limit)

        if haskey(result, "error")
            return "Error: $(result["error"])"
        end

        points = get(result, "points", [])

        if isempty(points)
            return "No points found in collection: $collection"
        end

        output = "📄 Points in $collection (showing $(length(points))):\n\n"

        for (i, point) in enumerate(points)
            point_id = get(point, "id", "unknown")
            payload = get(point, "payload", Dict())

            output *= "$i. ID: $point_id\n"

            for (key, value) in payload
                value_str = string(value)
                if length(value_str) > 100
                    value_str = value_str[1:100] * "..."
                end
                output *= "   $key: $value_str\n"
            end
            output *= "\n"
        end

        next_offset = get(result, "next_page_offset", nothing)
        if next_offset !== nothing
            output *= "More results available (next offset: $next_offset)\n"
        end

        return output
    end
)

# Run an indexing operation as a tracked background job: register it in the
# background_jobs table, spawn the work, and return the job id immediately so the
# MCP call never blocks (full-project indexing can take minutes and would
# otherwise time out the request). Poll via list_jobs / check_eval — mirrors how
# slow evals are promoted to background jobs.
function _run_index_as_job(description::AbstractString, work::Function)
    job_id = bytes2hex(rand(UInt8, 4))   # 8 hex chars, eval_id-style
    now = time()
    Database.persist_job!(job_id, "indexer", String(description), now, now)
    Threads.@spawn begin
        try
            summary = work()
            Database.update_job!(job_id; status = "completed", result = summary,
                result_preview = summary, finished_at = time())
        catch e
            msg = "Indexing failed: " * sprint(showerror, e)
            Database.update_job!(job_id; status = "failed", result = msg,
                result_preview = msg, finished_at = time())
            @debug "Background index job failed" job_id exception = (e, catch_backtrace())
        end
    end
    return job_id
end

qdrant_index_project_tool = @mcp_tool(
    :qdrant_index_project,
    "Index a Julia project into Qdrant. Runs in the BACKGROUND and returns a job id immediately (full-project indexing can take minutes) — poll with list_jobs() or check_eval(eval_id). Pass wait=true to block and return the chunk count inline (small projects). Creates or recreates the collection and indexes project source files.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "project_path" => Dict(
                "type" => "string",
                "description" => "Project path to index (default: current working directory)",
            ),
            "collection" => Dict(
                "type" => "string",
                "description" => "Collection name to use (optional, defaults to project name)",
            ),
            "recreate" => Dict(
                "type" => "boolean",
                "description" => "Recreate the collection before indexing (default: false)",
            ),
            "extra_dirs" => Dict(
                "type" => "array",
                "items" => Dict("type" => "string"),
                "description" => "Additional directories to index beyond src/ (e.g., [\"frontend/src\", \"dashboard-ui/src\"])",
            ),
            "extensions" => Dict(
                "type" => "array",
                "items" => Dict("type" => "string"),
                "description" => "File extensions to index (default: [\".jl\", \".ts\", \".tsx\", \".jsx\", \".md\"])",
            ),
            "wait" => Dict(
                "type" => "boolean",
                "description" => "Block until indexing finishes and return the chunk count (default: false — runs in the background and returns a job id).",
            ),
        ),
        "required" => [],
    ),
    function (args)
        err = _require_services(need_ollama = true)
        err !== nothing && return err

        project_path = get(args, "project_path", pwd())
        collection = get(args, "collection", nothing)
        recreate = let v = get(args, "recreate", false); v isa Bool ? v : v == "true"; end
        wait_flag = let v = get(args, "wait", false); v isa Bool ? v : v == "true"; end

        # Convert to Vector{String} (args from JSON may be Vector{Any})
        extra_dirs = Vector{String}(get(args, "extra_dirs", String[]))
        extensions = Vector{String}(get(args, "extensions", DEFAULT_INDEX_EXTENSIONS))

        if collection isa String && isempty(collection)
            collection = nothing
        end

        # Normalize for display (index_project also normalizes internally)
        col_name =
            collection === nothing ? get_project_collection_name(project_path) :
            normalize_collection_name(collection)

        work = function ()
            chunks = index_project(
                project_path;
                collection = collection,
                recreate = recreate,
                silent = true,
                extra_dirs = extra_dirs,
                extensions = extensions,
            )
            "✓ Indexed $chunks chunks into '$col_name' from $(1 + length(extra_dirs)) director$(length(extra_dirs) == 0 ? "y" : "ies")."
        end

        wait_flag && return work()

        job_id = _run_index_as_job("index_project $col_name (recreate=$recreate)", work)
        return "🔄 Indexing '$col_name' started in the background (job `$job_id`) — returns immediately so the request won't time out.\n" *
               "Poll: list_jobs() or check_eval(eval_id=\"$job_id\"). Watch growth: qdrant_collection_info(collection=\"$col_name\")."
    end
)

qdrant_sync_index_tool = @mcp_tool(
    :qdrant_sync_index,
    "Sync Qdrant index with current files. Reindexes changed files and removes deleted ones. Uses the directory and extension configuration from the initial index_project call.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "project_path" => Dict(
                "type" => "string",
                "description" => "Project path to sync (default: current working directory)",
            ),
            "collection" => Dict(
                "type" => "string",
                "description" => "Collection name to sync (optional, defaults to project name)",
            ),
            "verbose" => Dict(
                "type" => "boolean",
                "description" => "Print progress to stdout (default: true)",
            ),
        ),
        "required" => [],
    ),
    function (args)
        err = _require_services(need_ollama = true)
        err !== nothing && return err

        project_path = get(args, "project_path", pwd())
        collection = get(args, "collection", nothing)
        verbose = get(args, "verbose", true)

        if collection isa String && isempty(collection)
            collection = nothing
        end

        # Normalize for display (sync_index also normalizes internally)
        col_name =
            collection === nothing ? get_project_collection_name(project_path) :
            normalize_collection_name(collection)

        result = sync_index(
            project_path;
            collection = collection,
            silent = true,
            verbose = verbose,
        )

        return "✓ Sync complete for '$col_name': $(result.reindexed) files reindexed, $(result.deleted) files removed, $(result.chunks) chunks indexed."
    end
)

qdrant_reindex_file_tool = @mcp_tool(
    :qdrant_reindex_file,
    "Re-index a single file: delete old chunks then index fresh.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "file_path" =>
                Dict("type" => "string", "description" => "File path to re-index"),
            "collection" =>
                Dict("type" => "string", "description" => "Collection name"),
            "project_path" => Dict(
                "type" => "string",
                "description" => "Project path for index tracking (default: current working directory)",
            ),
            "verbose" => Dict(
                "type" => "boolean",
                "description" => "Print progress to stdout (default: true)",
            ),
        ),
        "required" => ["file_path", "collection"],
    ),
    function (args)
        err = _require_services(need_ollama = true)
        err !== nothing && return err

        file_path = get(args, "file_path", "")
        raw_collection = get(args, "collection", "")
        project_path = get(args, "project_path", pwd())
        verbose = get(args, "verbose", true)

        if isempty(file_path)
            return "Error: file_path is required"
        end
        if isempty(raw_collection)
            return "Error: collection is required"
        end

        # Resolve collection name (reindex_file also normalizes internally)
        collections = QdrantClient.list_collections()
        collection, col_err = _resolve_collection(raw_collection, collections)
        if col_err !== nothing
            return "Error: $col_err"
        end

        chunks = reindex_file(
            file_path,
            collection;
            project_path = project_path,
            silent = true,
            verbose = false,
        )
        return "✓ Re-indexed $chunks chunks for $(basename(file_path)) in '$collection'."
    end
)

# ============================================================================
# Low-Level Tools (for extensions calling via KaimonGate.call_tool)
# ============================================================================

qdrant_collection_exists_tool = @mcp_tool(
    :qdrant_collection_exists,
    "Check whether a Qdrant collection exists. Returns true/false.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "collection" =>
                Dict("type" => "string", "description" => "Name of the collection to check"),
        ),
        "required" => ["collection"],
    ),
    function (args)
        err = _require_services()
        err !== nothing && return err

        collection = get(args, "collection", "")
        isempty(collection) && return "Error: collection name is required"

        return QdrantClient.collection_exists(collection)
    end
)

qdrant_create_collection_tool = @mcp_tool(
    :qdrant_create_collection,
    "Create a new Qdrant collection with specified vector configuration.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "collection" =>
                Dict("type" => "string", "description" => "Name of the collection to create"),
            "vector_size" => Dict(
                "type" => "integer",
                "description" => "Dimension of vectors (default: 768)",
            ),
            "distance" => Dict(
                "type" => "string",
                "description" => "Distance metric: Cosine, Euclid, or Dot (default: Cosine)",
            ),
        ),
        "required" => ["collection"],
    ),
    function (args)
        err = _require_services()
        err !== nothing && return err

        collection = get(args, "collection", "")
        isempty(collection) && return "Error: collection name is required"
        vector_size = Int(get(args, "vector_size", 768))
        distance = get(args, "distance", "Cosine")

        ok = QdrantClient.create_collection(collection; vector_size = vector_size, distance = distance)
        return ok ? "Created collection '$collection' (dim=$vector_size, distance=$distance)" :
               "Error: failed to create collection '$collection'"
    end
)

qdrant_delete_collection_tool = @mcp_tool(
    :qdrant_delete_collection,
    "Delete a Qdrant collection.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "collection" =>
                Dict("type" => "string", "description" => "Name of the collection to delete"),
        ),
        "required" => ["collection"],
    ),
    function (args)
        err = _require_services()
        err !== nothing && return err

        collection = get(args, "collection", "")
        isempty(collection) && return "Error: collection name is required"

        ok = QdrantClient.delete_collection(collection)
        return ok ? "Deleted collection '$collection'" : "Collection '$collection' not found or already deleted"
    end
)

qdrant_upsert_points_tool = @mcp_tool(
    :qdrant_upsert_points,
    "Upsert points (vectors with payloads) into a Qdrant collection.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "collection" =>
                Dict("type" => "string", "description" => "Name of the collection"),
            "points" => Dict(
                "type" => "array",
                "description" => "Array of point dicts with 'id', 'vector', and 'payload' keys",
                "items" => Dict("type" => "object"),
            ),
        ),
        "required" => ["collection", "points"],
    ),
    function (args)
        err = _require_services()
        err !== nothing && return err

        collection = get(args, "collection", "")
        isempty(collection) && return "Error: collection name is required"
        points = get(args, "points", Dict[])
        isempty(points) && return "Error: points array is empty"

        points_vec = Vector{Dict}(points)
        ok = QdrantClient.upsert_points(collection, points_vec)
        return ok ? "Upserted $(length(points_vec)) points into '$collection'" :
               "Error: upsert failed for '$collection'"
    end
)

qdrant_delete_points_tool = @mcp_tool(
    :qdrant_delete_points,
    "Delete specific points by ID from a Qdrant collection.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "collection" =>
                Dict("type" => "string", "description" => "Name of the collection"),
            "point_ids" => Dict(
                "type" => "array",
                "description" => "Array of point IDs to delete (numeric or UUID; numeric strings like \"1\" delete integer-id points)",
                "items" => Dict("type" => "string"),
            ),
        ),
        "required" => ["collection", "point_ids"],
    ),
    function (args)
        err = _require_services()
        err !== nothing && return err

        collection = get(args, "collection", "")
        isempty(collection) && return "Error: collection name is required"
        # Don't force IDs to String — Qdrant IDs are integers or UUID strings,
        # and the client normalizes each one (a numeric "1" must delete the
        # point stored with integer id 1, not a string "1").
        point_ids = collect(get(args, "point_ids", []))
        isempty(point_ids) && return "No point IDs to delete"

        ok = QdrantClient.delete_points(collection, point_ids)
        return ok ? "Deleted $(length(point_ids)) points from '$collection'" :
               "Error: delete failed for '$collection'"
    end
)

qdrant_search_tool = @mcp_tool(
    :qdrant_search,
    "Search a Qdrant collection with a pre-computed vector. Returns raw results with scores and payloads. Optional filter narrows results by payload fields (Qdrant filter syntax).",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "collection" =>
                Dict("type" => "string", "description" => "Name of the collection"),
            "vector" => Dict(
                "type" => "array",
                "description" => "Query vector (Float64 array)",
                "items" => Dict("type" => "number"),
            ),
            "limit" => Dict(
                "type" => "integer",
                "description" => "Maximum number of results (default: 10)",
            ),
            "filter" => Dict(
                "type" => "object",
                "description" => "Qdrant payload filter (e.g., {\"must\": [{\"key\": \"tier\", \"match\": {\"value\": \"derived\"}}]})",
            ),
        ),
        "required" => ["collection", "vector"],
    ),
    function (args)
        err = _require_services()
        err !== nothing && return err

        collection = get(args, "collection", "")
        isempty(collection) && return "Error: collection name is required"
        raw_vector = get(args, "vector", Float64[])
        isempty(raw_vector) && return "Error: vector is required"
        vector = Vector{Float64}(raw_vector)
        limit = Int(get(args, "limit", 10))
        filter = get(args, "filter", nothing)

        # Serialize to a JSON string so the MCP layer wraps it as text content.
        # Returning the raw array makes the server emit a bare JSON array, which
        # MCP clients can't unmarshal into the standard content format.
        return JSON.json(
            QdrantClient.search(collection, vector; limit = limit, filter = filter),
        )
    end
)

ollama_embed_tool = @mcp_tool(
    :ollama_embed,
    "Get an embedding vector for text using Ollama. Returns Vector{Float64}.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "text" =>
                Dict("type" => "string", "description" => "Text to embed"),
            "model" => Dict(
                "type" => "string",
                "description" => "Ollama embedding model (default: $DEFAULT_EMBEDDING_MODEL)",
            ),
        ),
        "required" => ["text"],
    ),
    function (args)
        model = get(args, "model", DEFAULT_EMBEDDING_MODEL)
        err = _require_services(need_ollama = true, model = model)
        err !== nothing && return err

        text = get(args, "text", "")
        isempty(text) && return "Error: text is required"

        return get_ollama_embedding(text; model = model)
    end
)

# ============================================================================
# Tool Registration
# ============================================================================

function create_qdrant_tools()
    return [
        qdrant_list_collections_tool,
        qdrant_collection_info_tool,
        search_code_tool,
        qdrant_search_code_tool,   # deprecated alias of search_code
        qdrant_browse_collection_tool,
        qdrant_index_project_tool,
        qdrant_sync_index_tool,
        qdrant_reindex_file_tool,
        qdrant_collection_exists_tool,
        qdrant_create_collection_tool,
        qdrant_delete_collection_tool,
        qdrant_upsert_points_tool,
        qdrant_delete_points_tool,
        qdrant_search_tool,
        ollama_embed_tool,
    ]
end

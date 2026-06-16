# (Kaimon Qdrant indexer — split into qdrant_indexer_*.jl; this one loads FIRST)
"""
Code Indexer for Qdrant Vector Search

Indexes Julia source files into Qdrant for semantic code search.
Uses Ollama for embeddings (qwen3-embedding model).
"""

# Uses QdrantClient, get_ollama_embedding, and DEFAULT_EMBEDDING_MODEL from parent scope

# ── Collection prefix for shared Qdrant instances ────────────────────────────
# Set via KAIMON_QDRANT_PREFIX env var or config.json "qdrant_prefix" field.
# When set, all collection names are prefixed: "myprefix_projectname"
const _QDRANT_COLLECTION_PREFIX = Ref{String}("")

"""
    set_collection_prefix!(prefix::AbstractString)

Set a prefix for all Qdrant collection names. Useful when multiple users
share a single Qdrant instance. Set to "" to disable.
"""
function set_collection_prefix!(prefix::AbstractString)
    _QDRANT_COLLECTION_PREFIX[] = String(prefix)
end

"""
    get_collection_prefix() -> String

Return the current Qdrant collection prefix (empty string if none).
"""
get_collection_prefix() = _QDRANT_COLLECTION_PREFIX[]

"""Name of the global cross-project collection."""
function global_collection_name()
    _prefixed("kaimon_all")
end

const _GLOBAL_COLLECTION_ENSURED = Ref{Bool}(false)

"""Ensure the global cross-project collection exists, creating it if needed."""
function _ensure_global_collection!()
    _GLOBAL_COLLECTION_ENSURED[] && return
    gc_name = global_collection_name()
    try
        existing = QdrantClient.list_collections()
        if gc_name ∉ existing
            # Use the same dimensions as the default embedding model
            cfg = get_embedding_config(DEFAULT_EMBEDDING_MODEL)
            QdrantClient.create_collection(gc_name; vector_size=cfg.dims)
        end
        _GLOBAL_COLLECTION_ENSURED[] = true
    catch e
        @debug "Failed to ensure global collection" exception=e
        _GLOBAL_COLLECTION_ENSURED[] = false
    end
end

"""Upsert points to the global cross-project collection (best-effort)."""
function _upsert_to_global!(points::Vector{Dict})
    isempty(points) && return
    try
        _ensure_global_collection!()
        QdrantClient.upsert_points(global_collection_name(), points)
    catch
        # Don't fail the primary index if global write fails
    end
end

"""
    populate_global_collection!(; verbose=true)

One-time migration: copy all vectors from per-project collections into the
global cross-project collection. Safe to run multiple times — uses upsert
so duplicates are overwritten.
"""
function populate_global_collection!(; verbose::Bool=true)
    _ensure_global_collection!()
    gc_name = global_collection_name()
    collections = QdrantClient.list_collections()
    total = 0
    for col in collections
        col == gc_name && continue

        # Validate this is a Kaimon-indexed collection by sampling a point
        # and checking for our schema fields. Skip foreign collections.
        is_kaimon = try
            # Sample a point and check for Kaimon payload fields
            sample = QdrantClient.scroll_points(col; limit=1)
            points = get(sample, "points", [])
            if !isempty(points)
                payload = get(first(points), "payload", Dict())
                haskey(payload, "file") && haskey(payload, "type") && haskey(payload, "text")
            else
                false
            end
        catch
            false
        end
        if !is_kaimon
            verbose && println("  Skipping $col (not a Kaimon index)")
            continue
        end

        verbose && print("  Copying $col... ")
        try
            # Scroll through all points in the collection with vectors
            offset = nothing
            col_count = 0
            while true
                result = QdrantClient.scroll_points(col; limit=100, offset=offset, with_vector=true)
                points = get(result, "points", [])
                isempty(points) && break
                # Convert scroll result points to upsert format
                upsert_batch = Dict[]
                for pt in points
                    id = get(pt, "id", nothing)
                    vector = get(pt, "vector", nothing)
                    payload = get(pt, "payload", Dict())
                    (id === nothing || vector === nothing) && continue
                    push!(upsert_batch, Dict(
                        "id" => id,
                        "vector" => vector,
                        "payload" => payload,
                    ))
                end
                !isempty(upsert_batch) && QdrantClient.upsert_points(gc_name, upsert_batch)
                col_count += length(upsert_batch)
                # Get next offset
                next_offset = get(result, "next_page_offset", nothing)
                next_offset === nothing && break
                offset = next_offset
            end
            verbose && println("$col_count vectors")
            total += col_count
        catch e
            verbose && println("failed: $(sprint(showerror, e))")
        end
    end
    verbose && println("✅ Global collection populated: $total vectors from $(length(collections)-1) collections")
    return total
end

"""Apply the collection prefix to a name, if configured."""
function _prefixed(name::String)
    prefix = _QDRANT_COLLECTION_PREFIX[]
    isempty(prefix) ? name : "$(prefix)_$(name)"
end


# Extensible PDF text extraction — implemented by KaimonPDFIOExt when PDFIO is loaded.
function _extract_pdf_text end

# Embedding model configuration
const EMBEDDING_CONFIGS = Dict(
    "embeddinggemma:latest" => (dims=768, context_tokens=2048, context_chars=4000),
    "qwen3-embedding:0.6b" => (dims=1024, context_tokens=8192, context_chars=16000),
    "qwen3-embedding:4b" => (dims=2560, context_tokens=8192, context_chars=16000),
    "qwen3-embedding:8b" => (dims=4096, context_tokens=8192, context_chars=16000),
    "snowflake-arctic-embed:latest" => (dims=1024, context_tokens=512, context_chars=1000),
    "nomic-embed-text" => (dims=768, context_tokens=512, context_chars=1000),
)

const CHUNK_SIZE = 1500  # Target chunk size in characters
const CHUNK_OVERLAP = 200  # Overlap between chunks

# Supported file extensions for indexing
# Note: .js excluded to avoid indexing compiled output (use .ts/.tsx for TypeScript sources)
const DEFAULT_INDEX_EXTENSIONS = [".jl", ".ts", ".tsx", ".jsx", ".md"]

# Default source directories to index (relative to project root)
# Additional directories can be specified via index_project(extra_dirs=...)
const DEFAULT_SOURCE_DIRS = ["src", "test", "scripts"]

# Known source file extensions for auto-detection (superset of per-language lists)
const SOURCE_EXTENSIONS = Set([
    ".jl", ".py", ".rs", ".go", ".ts", ".tsx", ".js", ".jsx",
    ".c", ".cpp", ".cc", ".h", ".hpp", ".java", ".kt", ".kts",
    ".rb", ".ex", ".exs", ".zig", ".nim", ".lua", ".swift", ".m",
    ".cs", ".fs", ".scala", ".clj", ".cljs", ".erl", ".hrl",
    ".hs", ".ml", ".mli", ".r", ".R", ".jl", ".sh", ".bash",
    ".md", ".mdx", ".rst", ".toml", ".yaml", ".yml", ".json",
    ".xml", ".html", ".css", ".scss", ".sass", ".less",
    ".sql", ".graphql", ".gql", ".proto", ".tf", ".hcl",
    ".vue", ".svelte",
])

# Directories to skip during walkdir and auto-detection, even if tracked by git
const IGNORED_DIRS = Set([
    "node_modules", "__pycache__", ".mypy_cache", ".pytest_cache",
    "vendor", "dist", "build", "_build", ".next", ".nuxt",
    "coverage", ".tox", "target", ".gradle", ".cache",
    ".eggs", ".egg-info", "venv", ".venv", "env",
])

# Get embedding config for a model
function get_embedding_config(model::String)
    return get(EMBEDDING_CONFIGS, model, (dims=768, context_tokens=512, context_chars=2000))
end

# Logging and error tracking for background indexing
const INDEX_LOGGER = Ref{Union{LoggingExtras.TeeLogger,Nothing}}(nothing)
const INDEX_ERROR_COUNT = Ref{Int}(0)
const INDEX_USER_NOTIFIED = Ref{Bool}(false)
const INDEX_FAILED_FILES = Ref{Dict{String,Int}}(Dict{String,Int}())  # file -> consecutive fail count

"""
    setup_index_logging(project_path::String=pwd())

Setup rotating log file for background indexing operations.
Log file is stored in ~/.cache/kaimon/indexer.log with 10MB max size and 3 file rotation (30MB total).
"""
function setup_index_logging(project_path::String=pwd())
    log_file = joinpath(kaimon_cache_dir(), "indexer.log")

    # Create rotating file logger (10MB max, 3 files = 30MB total)
    file_logger = LoggingExtras.MinLevelLogger(
        LoggingExtras.FileLogger(log_file; append=true, always_flush=true),
        Logging.Info
    )

    INDEX_LOGGER[] = file_logger

    @info "Indexer logging initialized" log_file = log_file
    return log_file
end

"""
    with_index_logger(f::Function)

Execute function with indexer logger active, then restore original logger.
"""
function with_index_logger(f::Function)
    if INDEX_LOGGER[] === nothing
        return f()
    end

    old_logger = global_logger()
    try
        global_logger(INDEX_LOGGER[])
        return f()
    finally
        global_logger(old_logger)
    end
end

"""
    check_and_notify_index_errors()

Check error count and notify user (once) if persistent indexing problems detected.
Shows warning after 5+ consecutive failures, resets on success.
"""
function check_and_notify_index_errors()
    if INDEX_ERROR_COUNT[] >= 5 && !INDEX_USER_NOTIFIED[]
        printstyled(
            "\n⚠️  Semantic search indexing is experiencing issues. Check ~/.cache/kaimon/indexer.log for details.\n",
            color=:yellow
        )
        INDEX_USER_NOTIFIED[] = true
    end
end

# ── Search Config (user preferences) ─────────────────────────────────────────
# User search configuration lives in ~/.config/kaimon/search.json so it
# survives cache clears.  Only regenerable index state stays in the cache
# at ~/.cache/kaimon/projects.json.

"""Path to the search config JSON file (user preferences)."""
_search_config_path() = joinpath(kaimon_config_dir(), "search.json")

"""Path to the index cache JSON file (regenerable state)."""
_project_registry_path() = joinpath(kaimon_cache_dir(), "projects.json")


"""
    load_search_config() -> Dict

Load search configuration from `~/.config/kaimon/search.json`.
On first call, migrates config fields from the old cache-only
`projects.json` if `search.json` doesn't exist yet.
"""
function load_search_config()
    path = _search_config_path()
    if isfile(path)
        try
            parsed = JSON.parse(read(path, String))
            if !haskey(parsed, "version")
                parsed["version"] = 1
            end
            if !haskey(parsed, "projects")
                parsed["projects"] = Dict{String,Any}()
            end
            return parsed
        catch e
            @warn "Failed to load search config, starting fresh" exception = e
            return Dict("version" => 1, "projects" => Dict{String,Any}())
        end
    end

    # No search.json yet — start fresh (projects get added as you use them)
    return Dict("version" => 1, "projects" => Dict{String,Any}())
end

"""
    save_search_config(config::AbstractDict)

Write search configuration to `~/.config/kaimon/search.json`.
"""
function save_search_config(config::AbstractDict)
    path = _search_config_path()
    try
        write(path, JSON.json(config, 2))
    catch e
        @error "Failed to save search config" exception = e
    end
end

# ── Per-collection embedding model (search.json `collection_models` map) ───────
# Vectors from different embedding models are incompatible — and NOT just at
# different dimensions: two 1024-dim models (e.g. qwen3-embedding:0.6b vs
# snowflake-arctic) live in different spaces, so a wrong-model query returns
# silent garbage with no error. So we record the model a collection was built
# with and always query with that same model.

"""Record the embedding model `collection` was indexed with."""
function set_collection_model!(collection::String, model::String)
    cfg = load_search_config()
    models = get!(() -> Dict{String,Any}(), cfg, "collection_models")
    models[collection] = model
    save_search_config(cfg)
    return nothing
end

"""The embedding model `collection` was indexed with, or `nothing` if unrecorded
(legacy collections predating model-stamping)."""
function get_collection_model(collection::String)
    models = get(load_search_config(), "collection_models", nothing)
    models isa AbstractDict || return nothing
    m = get(models, collection, nothing)
    m === nothing ? nothing : String(m)
end

"""Resolve which embedding model to query `collection` with: the model it was
indexed with if recorded, else `DEFAULT_EMBEDDING_MODEL` (the long-standing
default that legacy/unstamped collections were almost certainly built with —
backwards-compatible, and avoids querying with a mismatched model)."""
resolve_search_model(collection::String) =
    something(get_collection_model(collection), DEFAULT_EMBEDDING_MODEL)


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
    set_collection_prefix!(prefix::String)

Set a prefix for all Qdrant collection names. Useful when multiple users
share a single Qdrant instance. Set to "" to disable.
"""
function set_collection_prefix!(prefix::String)
    _QDRANT_COLLECTION_PREFIX[] = prefix
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

"""Strip the collection prefix from a name for display."""
function _unprefixed(name::String)
    prefix = _QDRANT_COLLECTION_PREFIX[]
    isempty(prefix) && return name
    full_prefix = "$(prefix)_"
    startswith(name, full_prefix) ? name[length(full_prefix)+1:end] : name
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
const INDEX_LAST_ERROR_TIME = Ref{Float64}(0.0)
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

const _CONFIG_FIELDS = ("collection", "dirs", "extensions", "auto_index", "source")

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

# ── Index Cache (regenerable state) ──────────────────────────────────────────
# ~/.cache/kaimon/projects.json holds only per-file index state (mtimes, chunk
# counts). Cleared safely without losing user preferences.

"""
    load_project_registry() -> Dict

Load search config (project listing). Returns the same shape as the old
cache registry so callers don't change.
"""
function load_project_registry()
    return load_search_config()
end

"""
    save_project_registry(registry::AbstractDict)

Write search config. Kept for internal compatibility.
"""
function save_project_registry(registry::AbstractDict)
    save_search_config(registry)
end

"""
    _load_index_cache() -> Dict

Load the index cache from `~/.cache/kaimon/projects.json`.
"""
function _load_index_cache()
    path = _project_registry_path()
    if !isfile(path)
        return Dict("version" => 1, "projects" => Dict{String,Any}())
    end
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
        @warn "Failed to load index cache, starting fresh" exception = e
        return Dict("version" => 1, "projects" => Dict{String,Any}())
    end
end

"""
    _save_index_cache(cache::AbstractDict)

Write the index cache to `~/.cache/kaimon/projects.json`.
"""
function _save_index_cache(cache::AbstractDict)
    path = _project_registry_path()
    try
        write(path, JSON.json(cache, 2))
    catch e
        @error "Failed to save index cache" exception = e
    end
end

"""
    register_project!(path::String; collection::String="", dirs::Vector{String}=String[],
                       extensions::Vector{String}=DEFAULT_INDEX_EXTENSIONS,
                       auto_index::Bool=true, source::String="gate")

Upsert a project entry in the search config (`~/.config/kaimon/search.json`).
`source` is either `"gate"` (auto-indexed from a REPL connection) or `"manual"`
(user-added via the search manage UI); it controls which UI section a project
appears in.
"""
function register_project!(
    path::String;
    collection::String = "",
    dirs::Vector{String} = String[],
    extensions::Vector{String} = DEFAULT_INDEX_EXTENSIONS,
    exclude_dirs::Vector{String} = String[],
    auto_index::Bool = true,
    source::String = "gate",
)
    path = abspath(path)
    config = load_search_config()
    if isempty(collection)
        collection = get_project_collection_name(path)
    end
    existing = get(config["projects"], path, Dict{String,Any}())
    existing["collection"] = collection
    existing["dirs"] = dirs
    existing["extensions"] = extensions
    existing["exclude_dirs"] = exclude_dirs
    existing["auto_index"] = auto_index
    existing["source"] = source
    config["projects"][path] = existing
    save_search_config(config)
end

"""
    unregister_project!(path::String)

Remove a project from both search config and index cache.
"""
function unregister_project!(path::String)
    path = abspath(path)
    config = load_search_config()
    delete!(config["projects"], path)
    save_search_config(config)

    # Also clean up cache entry
    cache = _load_index_cache()
    if haskey(cache["projects"], path)
        delete!(cache["projects"], path)
        _save_index_cache(cache)
    end
end

"""
    get_project_config(path::String) -> Union{Dict, Nothing}

Look up a project's config by absolute path from the search config.
"""
function get_project_config(path::String)
    path = abspath(path)
    config = load_search_config()
    return get(config["projects"], path, nothing)
end

"""
    _is_external_project(project_path::String) -> Bool

Deprecated — kept only for migration; always returns true now that index state
is stored centrally in ~/.cache/kaimon/projects.json for all projects.
"""
_is_external_project(project_path::String) = !isdir(joinpath(project_path, ".kaimon"))

# ── Project Type Discovery ───────────────────────────────────────────────────

"""
    detect_project_type(project_path::String) -> NamedTuple{(:type, :dirs, :extensions), Tuple{String, Vector{String}, Vector{String}}}

Detect project type from filesystem markers and return recommended indexing config.
Only includes directories that actually exist on disk.
"""
function detect_project_type(project_path::String)
    path = abspath(project_path)

    # Check markers in priority order
    markers = [
        ("Project.toml",  "julia",   ["src", "test"],                   [".jl", ".md"]),
        ("Cargo.toml",    "rust",    ["src"],                           [".rs", ".toml", ".md"]),
        ("go.mod",        "go",      ["."],                             [".go", ".md"]),
        ("pyproject.toml","python",  ["src", basename(path)],           [".py", ".md"]),
        ("setup.py",      "python",  ["src"],                           [".py", ".md"]),
        ("tsconfig.json", "node-ts", ["src", "lib"],                    [".ts", ".tsx", ".md"]),
        ("package.json",  "node",    ["src", "lib"],                    [".ts", ".tsx", ".js", ".jsx", ".json", ".md"]),
        ("CMakeLists.txt","cpp",     ["src", "include"],                [".c", ".cpp", ".h", ".hpp", ".md"]),
    ]

    for (marker, ptype, candidate_dirs, exts) in markers
        if isfile(joinpath(path, marker))
            # If tsconfig.json exists alongside package.json, prefer TS extensions
            if ptype == "node" && isfile(joinpath(path, "tsconfig.json"))
                exts = [".ts", ".tsx", ".md"]
                ptype = "node-ts"
            end
            # Filter to dirs that actually exist
            existing_dirs = String[]
            for d in candidate_dirs
                full = d == "." ? path : joinpath(path, d)
                if isdir(full)
                    push!(existing_dirs, full)
                end
            end
            if isempty(existing_dirs)
                push!(existing_dirs, path)
            end
            return (type = ptype, dirs = existing_dirs, extensions = exts)
        end
    end

    # No known marker found — use fallback detection
    return _fallback_detect(path)
end

"""
    _fallback_detect(project_path::String) -> NamedTuple

For unknown project types: scan for common source dirs, count file extensions
in the top 2 levels, and return the top 5 most common source extensions.
"""
function _fallback_detect(project_path::String)
    # Check common source directory names
    common_dirs = ["src", "lib", "app", "pkg", "cmd"]
    found_dirs = String[]
    for d in common_dirs
        full = joinpath(project_path, d)
        isdir(full) && push!(found_dirs, full)
    end
    if isempty(found_dirs)
        push!(found_dirs, project_path)
    end

    # Walk top 2 levels counting file extensions
    ext_counts = Dict{String,Int}()
    source_exts = Set([".jl", ".py", ".rs", ".go", ".ts", ".tsx", ".js", ".jsx",
                       ".c", ".cpp", ".h", ".hpp", ".java", ".kt", ".rb", ".ex",
                       ".exs", ".zig", ".nim", ".md", ".toml", ".json", ".yaml", ".yml"])
    for (root, dirs, files) in walkdir(project_path)
        # Limit depth to 2 levels
        depth = count(==('/'), relpath(root, project_path))
        depth > 2 && (empty!(dirs); continue)
        # Skip hidden dirs and well-known noise directories
        filter!(d -> !startswith(d, ".") && d ∉ IGNORED_DIRS, dirs)
        for f in files
            ext = lowercase(splitext(f)[2])
            if ext in source_exts
                ext_counts[ext] = get(ext_counts, ext, 0) + 1
            end
        end
    end

    # Top 5 most common extensions
    sorted = sort(collect(ext_counts); by = last, rev = true)
    top_exts = [first(p) for p in sorted[1:min(5, length(sorted))]]
    if isempty(top_exts)
        top_exts = DEFAULT_INDEX_EXTENSIONS
    end

    return (type = "unknown", dirs = found_dirs, extensions = top_exts)
end

"""
    _git_tracked_files(project_path::String) -> Union{Vector{String}, Nothing}

Get list of tracked + untracked-but-not-ignored files via `git ls-files`.
Returns `nothing` if the path is not a git repository or git is unavailable.
"""
function _git_tracked_files(project_path::String)
    try
        output = read(
            `git -C $project_path ls-files --cached --others --exclude-standard`,
            String,
        )
        files = filter(!isempty, split(output, '\n'))
        return String.(files)
    catch
        return nothing
    end
end

"""
    auto_detect_project_config(project_path::String) -> NamedTuple{(:type, :dirs, :extensions, :git_aware), Tuple{String, Vector{String}, Vector{String}, Bool}}

Improved project detection that uses git to filter ignored/generated files.

For git repos:
- Discovers unique source extensions from tracked files (filtered by SOURCE_EXTENSIONS whitelist)
- Collapses file paths to minimal covering top-level directories
- Excludes well-known noise directories (IGNORED_DIRS) even if tracked
- Falls back to marker-based `detect_project_type()` for non-git projects
"""
function auto_detect_project_config(project_path::String)
    path = abspath(project_path)

    # Try git-aware detection first
    git_files = _git_tracked_files(path)
    if git_files !== nothing && !isempty(git_files)
        # Discover unique extensions, filtered to source whitelist
        ext_counts = Dict{String,Int}()
        for f in git_files
            ext = lowercase(splitext(f)[2])
            if ext in SOURCE_EXTENSIONS
                ext_counts[ext] = get(ext_counts, ext, 0) + 1
            end
        end

        # Top extensions by frequency
        sorted_exts = sort(collect(ext_counts); by=last, rev=true)
        detected_exts = [first(p) for p in sorted_exts[1:min(10, length(sorted_exts))]]
        if isempty(detected_exts)
            detected_exts = copy(DEFAULT_INDEX_EXTENSIONS)
        end

        # Collapse file paths to minimal covering top-level dirs
        top_dirs = Set{String}()
        has_root_files = false
        for f in git_files
            ext = lowercase(splitext(f)[2])
            ext in SOURCE_EXTENSIONS || continue
            parts = splitpath(f)
            if length(parts) >= 2
                top_dir = parts[1]
                # Skip ignored dirs and hidden dirs
                if !startswith(top_dir, ".") && top_dir ∉ IGNORED_DIRS
                    push!(top_dirs, top_dir)
                end
            else
                has_root_files = true
            end
        end
        # Only include project root if no subdirectories were found —
        # a few root-level files aren't worth recursing the entire tree.
        if isempty(top_dirs) && has_root_files
            push!(top_dirs, ".")
        end

        # Convert to absolute paths, filter to existing dirs
        abs_dirs = String[]
        for d in sort(collect(top_dirs))
            full = d == "." ? path : joinpath(path, d)
            isdir(full) && push!(abs_dirs, full)
        end
        if isempty(abs_dirs)
            push!(abs_dirs, path)
        end

        # Determine project type from markers (for the type label)
        marker_result = detect_project_type(path)
        ptype = marker_result.type

        return (type=ptype, dirs=abs_dirs, extensions=detected_exts, git_aware=true)
    end

    # Non-git fallback
    result = detect_project_type(path)
    return (type=result.type, dirs=result.dirs, extensions=result.extensions, git_aware=false)
end

# Lightweight file tracking for indexing state.
# Config (dirs, extensions) lives in ~/.config/kaimon/search.json.
# Per-file index state lives in ~/.cache/kaimon/projects.json.
# We never write into the user's project directories.

"""
    load_index_state(project_path::String) -> Dict

Load the index state for a project. Config (dirs, extensions) comes from the
search config (`~/.config/kaimon/search.json`); per-file tracking comes from
the index cache (`~/.cache/kaimon/projects.json`).

Structure:
- "config": Dict with "dirs" (full list of indexed directories) and "extensions"
- "files": Dict mapping file paths to their index metadata
"""
function load_index_state(project_path::String)
    _default_state() = Dict{String,Any}(
        "config" => Dict{String,Any}(
            "dirs" => String[],
            "extensions" => DEFAULT_INDEX_EXTENSIONS,
        ),
        "files" => Dict{String,Any}(),
    )

    # Read dirs/extensions from search config
    search_cfg = get_project_config(project_path)

    # Read per-file state from index cache
    ap = abspath(project_path)
    cache = _load_index_cache()
    cache_entry = get(cache["projects"], ap, Dict{String,Any}())
    idx_state = get(cache_entry, "index_state", Dict())

    # Config priority: search config → cache (backward compat) → defaults
    if search_cfg !== nothing
        dirs = String.(get(search_cfg, "dirs", String[]))
        exts = String.(get(search_cfg, "extensions", DEFAULT_INDEX_EXTENSIONS))
    elseif !isempty(idx_state)
        # Backward compat: old cache entries may still have dirs/extensions
        dirs = String.(get(idx_state, "dirs", String[]))
        exts = String.(get(idx_state, "extensions", DEFAULT_INDEX_EXTENSIONS))
    else
        return _default_state()
    end

    files = Dict(get(idx_state, "files", Dict()))
    return Dict{String,Any}(
        "config" => Dict{String,Any}("dirs" => dirs, "extensions" => exts),
        "files" => files,
    )
end

"""
    save_index_state(project_path::String, state::Dict)

Persist the index state for a project. Only file-level tracking data goes to
the index cache (`~/.cache/kaimon/projects.json`). Config fields (dirs,
extensions) are managed via `register_project!` in the search config.
"""
function save_index_state(project_path::String, state)
    try
        cache = _load_index_cache()
        ap = abspath(project_path)
        entry = get!(cache["projects"], ap, Dict{String,Any}())
        idx = Dict{String,Any}(
            "files" => get(state, "files", Dict()),
        )
        # Preserve last_indexed timestamp if present
        last_indexed = get(state, "last_indexed", nothing)
        if last_indexed !== nothing
            idx["last_indexed"] = last_indexed
        end
        entry["index_state"] = idx
        _save_index_cache(cache)
    catch e
        @error "Failed to save index state to cache" exception = e
    end
end

"""
    record_indexed_file(project_path::String, file_path::String, file_mtime::Float64, chunk_count::Int)

Record that a file has been indexed.
"""
function record_indexed_file(
    project_path::String,
    file_path::String,
    file_mtime::Float64,
    chunk_count::Int,
)
    state = load_index_state(project_path)
    state["files"][file_path] = Dict("mtime" => file_mtime, "chunks" => chunk_count)
    save_index_state(project_path, state)
end

"""
    remove_indexed_file(project_path::String, file_path::String)

Remove a file from the indexed files tracking.
"""
function remove_indexed_file(project_path::String, file_path::String)
    state = load_index_state(project_path)
    delete!(state["files"], file_path)
    save_index_state(project_path, state)
end

"""
    get_stale_files(project_path::String, src_dir::String) -> Vector{String}

Get list of files that need re-indexing. Loads the index state once for the
whole directory scan rather than once per file.
"""
function get_stale_files(project_path::String, src_dir::String;
                         extensions::Vector{String}=DEFAULT_INDEX_EXTENSIONS,
                         exclude_dirs::Vector{String}=String[])
    stale = String[]
    isdir(src_dir) || return stale

    exclude_set = union(IGNORED_DIRS, Set(exclude_dirs))
    files_state = load_index_state(project_path)["files"]

    onerr = e -> begin
        with_index_logger(() -> @warn "Skipping unreadable directory during stale scan" project = project_path src_dir = src_dir exception = e)
    end
    for (root, dirs, files) in walkdir(src_dir; onerror=onerr)
        filter!(d -> !startswith(d, ".") && d ∉ exclude_set, dirs)

        for file in files
            if any(ext -> endswith(file, ext), extensions)
                file_path = joinpath(root, file)
                info = get(files_state, file_path, nothing)
                if info === nothing || mtime(file_path) > info["mtime"]
                    push!(stale, file_path)
                end
            end
        end
    end

    return stale
end

"""
    get_deleted_files(project_path::String) -> Vector{String}

Get list of indexed files that no longer exist on disk.
"""
function get_deleted_files(project_path::String)
    deleted = String[]
    for (file_path, _) in load_index_state(project_path)["files"]
        isfile(file_path) || push!(deleted, file_path)
    end
    return deleted
end

"""
    normalize_collection_name(name::String) -> String

Normalize a collection name for Qdrant: strip `.jl` suffix, lowercase,
replace non-alphanumeric with underscore, collapse runs, strip edges.

This is the single source of truth for collection name normalization.
Both auto-generated names (from project paths) and user-provided names
should go through this function so that "Kaimon.jl", "Kaimon",
"kaimon", and "kaimon_jl" all resolve to the same collection.
"""
function normalize_collection_name(name::String)
    # Strip common suffixes before normalizing
    name = replace(name, r"\.jl$"i => "")
    # Sanitize: lowercase, replace non-alphanumeric with underscore
    name = lowercase(name)
    name = replace(name, r"[^a-z0-9]" => "_")
    name = replace(name, r"_+" => "_")  # Collapse multiple underscores
    name = strip(name, '_')
    return isempty(name) ? "default" : String(name)
end

"""
    get_project_collection_name(project_path::String=pwd()) -> String

Generate a collection name based on the project directory.
Uses the directory name, sanitized via `normalize_collection_name`.
"""
function get_project_collection_name(project_path::String=pwd())
    name = normalize_collection_name(basename(abspath(project_path)))
    return _prefixed(name)
end

"""
    _suggest_collections(target::String, available::Vector{String}; max_suggestions::Int=5) -> Vector{String}

Return collections from `available` that are similar to `target`, sorted by relevance.
Uses normalized prefix/substring matching and simple edit-distance heuristics.
"""
function _suggest_collections(target::String, available::Vector{String}; max_suggestions::Int=5)
    isempty(available) && return String[]
    norm_target = normalize_collection_name(target)

    scored = Tuple{Float64,String}[]
    for col in available
        norm_col = normalize_collection_name(col)
        score = 0.0

        # Exact normalized match (shouldn't reach here, but just in case)
        if norm_col == norm_target
            score = 1.0
        # One is a prefix of the other
        elseif startswith(norm_col, norm_target) || startswith(norm_target, norm_col)
            score = 0.8
        # Substring match
        elseif contains(norm_col, norm_target) || contains(norm_target, norm_col)
            score = 0.6
        # Shared prefix length
        else
            shared = 0
            for (a, b) in zip(norm_target, norm_col)
                a == b ? (shared += 1) : break
            end
            if shared > 0
                score = 0.3 * shared / max(length(norm_target), length(norm_col))
            end
        end
        score > 0.0 && push!(scored, (score, col))
    end

    sort!(scored; by=first, rev=true)
    return [s[2] for s in scored[1:min(max_suggestions, length(scored))]]
end

"""
    _resolve_collection(name::Union{String,Nothing}, available::Vector{String}; project_path::String=pwd()) -> (String, Union{String,Nothing})

Resolve a collection name (possibly user-provided) against available collections.
Returns `(resolved_name, error_message)`. If error_message is nothing, the name is valid.
"""
function _resolve_collection(name::Union{String,Nothing}, available::Vector{String}; project_path::String="")
    # Default to project collection if not specified
    if name === nothing || isempty(name)
        # Try last session's project path, fall back to pwd()
        if isempty(project_path)
            lsp = try; parentmodule(@__MODULE__)._last_session_project_path(); catch; ""; end
            project_path = !isempty(lsp) ? lsp : pwd()
        end
        name = get_project_collection_name(project_path)
    end

    # Direct match — fast path
    if name in available
        return (name, nothing)
    end

    # Try normalized match
    norm_name = normalize_collection_name(name)
    for col in available
        if normalize_collection_name(col) == norm_name
            return (col, nothing)  # Return the actual Qdrant collection name
        end
    end

    # No match — build helpful error with suggestions
    suggestions = _suggest_collections(name, available)
    msg = "Collection '$name' not found."
    if !isempty(suggestions)
        msg *= " Did you mean: $(join(suggestions, ", "))?"
    elseif !isempty(available)
        msg *= " Available: $(join(available, ", "))."
    else
        msg *= " No collections exist. Run index_project first."
    end
    return (name, msg)
end

"""
    chunk_code(content::String, file_path::String) -> Vector{Dict}

Split code into semantic chunks (functions, blocks) with metadata.
Returns vector of dicts with :text, :file, :start_line, :end_line, :type
"""
function chunk_code(content::String, file_path::String)
    chunks = Dict[]

    # Extract definitions using Julia's parser (functions, structs, macros)
    definition_chunks = extract_definitions(content, file_path)
    if !isempty(definition_chunks)
        append!(chunks, definition_chunks)
    end

    # Also create overlapping window chunks for full coverage
    window_chunks = create_window_chunks(content, file_path)
    append!(chunks, window_chunks)

    return chunks
end

"""
    extract_definitions(content::String, file_path::String) -> Vector{Dict}

Extract function, struct, and macro definitions using Julia's parser.
"""
function extract_definitions(content::String, file_path::String)
    chunks = Dict[]
    lines = split(content, '\n')

    # Parse the file
    expr = try
        Meta.parseall(content)
    catch e
        @debug "Failed to parse file" file_path exception = e
        return chunks
    end

    # Walk the AST to find definitions
    extract_from_expr!(chunks, expr, lines, file_path)
    return chunks
end

"""
    extract_from_expr!(chunks, expr, lines, file_path)

Recursively extract definitions from an expression.
"""
function extract_from_expr!(
    chunks::Vector{Dict},
    expr,
    lines::Vector{<:AbstractString},
    file_path::String,
)
    if expr isa Expr
        # Check for definition types
        if expr.head == :function || expr.head == :macro
            extract_definition!(chunks, expr, lines, file_path, "function")
        elseif expr.head == :struct || expr.head == :abstract || expr.head == :primitive
            extract_definition!(chunks, expr, lines, file_path, "struct")
        elseif expr.head == :(=) && length(expr.args) >= 1
            # Short function definition: f(x) = ...
            first_arg = expr.args[1]
            if first_arg isa Expr && first_arg.head == :call
                extract_definition!(chunks, expr, lines, file_path, "function")
            elseif first_arg isa Expr && first_arg.head == :const
                extract_definition!(chunks, expr, lines, file_path, "const")
            end
        elseif expr.head == :const
            extract_definition!(chunks, expr, lines, file_path, "const")
        elseif expr.head == :module
            # Recurse into module
            for arg in expr.args
                extract_from_expr!(chunks, arg, lines, file_path)
            end
        elseif expr.head == :toplevel || expr.head == :block
            # Recurse into blocks
            for arg in expr.args
                extract_from_expr!(chunks, arg, lines, file_path)
            end
        elseif expr.head == :macrocall && length(expr.args) >= 1
            macro_name = string(expr.args[1])
            if occursin("mcp_tool", macro_name)
                extract_definition!(chunks, expr, lines, file_path, "tool")
            elseif occursin("@doc", macro_name)
                # Handle docstring: @doc "docstring" definition
                # The function/struct is typically the last argument
                for arg in expr.args
                    if arg isa Expr && arg.head in (:function, :macro, :struct, :(=))
                        extract_from_expr!(chunks, arg, lines, file_path)
                    end
                end
            end
        end
    end
end

"""
    extract_definition!(chunks, expr, lines, file_path, def_type)

Extract a single definition with its source location.
"""
function extract_definition!(
    chunks::Vector{Dict},
    expr::Expr,
    lines::Vector{<:AbstractString},
    file_path::String,
    def_type::String,
)
    # Get the name of the definition
    name = get_definition_name(expr)
    if name === nothing
        return
    end

    # Get source location if available
    start_line, end_line = get_expr_lines(expr, lines)
    if start_line === nothing
        return
    end

    # Extract the text
    text = join(lines[start_line:end_line], "\n")

    # Check for preceding docstring
    if start_line > 1
        prev_line = start_line - 1
        while prev_line >= 1 && isempty(strip(lines[prev_line]))
            prev_line -= 1
        end
        if prev_line >= 1 && endswith(strip(lines[prev_line]), "\"\"\"")
            # Find start of docstring
            doc_end = prev_line
            doc_start = prev_line
            while doc_start > 1
                doc_start -= 1
                if startswith(strip(lines[doc_start]), "\"\"\"")
                    break
                end
            end
            if doc_start < doc_end
                docstring = join(lines[doc_start:doc_end], "\n")
                text = docstring * "\n" * text
                start_line = doc_start
            end
        end
    end

    # Extract additional metadata from the expression
    metadata = extract_definition_metadata(expr, def_type)

    push!(
        chunks,
        Dict(
            "text" => text,
            "file" => file_path,
            "start_line" => start_line,
            "end_line" => end_line,
            "type" => def_type,
            "name" => name,
            "signature" => get(metadata, "signature", ""),
            "parameters" => get(metadata, "parameters", []),
            "type_params" => get(metadata, "type_params", []),
            "parent_type" => get(metadata, "parent_type", ""),
            "is_mutable" => get(metadata, "is_mutable", false),
            "is_exported" => false,  # Set during post-processing
        ),
    )
end

"""
    extract_definition_metadata(expr::Expr, def_type::String) -> Dict

Extract detailed metadata from a definition expression.
Returns a dict with signature, parameters, type parameters, etc.
"""
function extract_definition_metadata(expr::Expr, def_type::String)
    metadata = Dict{String,Any}()

    if expr.head == :function || expr.head == :macro
        if length(expr.args) >= 1
            sig = expr.args[1]

            # Extract full signature
            metadata["signature"] = string(sig)

            # Extract parameters
            params = extract_parameters(sig)
            metadata["parameters"] = params

            # Extract type parameters (where clause)
            type_params = extract_type_parameters(sig)
            metadata["type_params"] = type_params
        end
    elseif expr.head == :struct
        # Check if mutable
        metadata["is_mutable"] = length(expr.args) >= 1 && expr.args[1] == true

        if length(expr.args) >= 2
            name_expr = expr.args[2]

            # Extract parent type (for subtypes)
            if name_expr isa Expr && name_expr.head == :<:
                metadata["parent_type"] = string(name_expr.args[2])
            end

            # Extract type parameters
            if name_expr isa Expr && name_expr.head == :curly
                metadata["type_params"] = [string(p) for p in name_expr.args[2:end]]
            elseif name_expr isa Expr && name_expr.head == :<: && length(name_expr.args) >= 1
                inner = name_expr.args[1]
                if inner isa Expr && inner.head == :curly
                    metadata["type_params"] = [string(p) for p in inner.args[2:end]]
                end
            end
        end
    elseif expr.head == :abstract || expr.head == :primitive
        if length(expr.args) >= 2
            name_expr = expr.args[2]
            if name_expr isa Expr && name_expr.head == :<:
                metadata["parent_type"] = string(name_expr.args[2])
            end
        end
    end

    return metadata
end

"""
    extract_parameters(sig) -> Vector{String}

Extract parameter names and types from a function signature.
"""
function extract_parameters(sig)
    params = String[]

    if sig isa Expr
        # Handle where clause
        actual_sig = sig.head == :where ? sig.args[1] : sig

        if actual_sig isa Expr && actual_sig.head == :call && length(actual_sig.args) >= 2
            for arg in actual_sig.args[2:end]
                param_str = if arg isa Symbol
                    string(arg)
                elseif arg isa Expr && arg.head == :(::)
                    # x::Type or ::Type
                    if length(arg.args) >= 2
                        string(arg.args[1], "::", arg.args[2])
                    elseif length(arg.args) == 1
                        string("::", arg.args[1])
                    else
                        string(arg)
                    end
                elseif arg isa Expr && arg.head == :kw
                    # Keyword argument: x=default
                    string(arg.args[1], "=", arg.args[2])
                elseif arg isa Expr && arg.head == :parameters
                    # Skip parameters block (handled separately)
                    continue
                else
                    string(arg)
                end
                push!(params, param_str)
            end
        end
    end

    return params
end

"""
    extract_type_parameters(sig) -> Vector{String}

Extract type parameters from where clause.
"""
function extract_type_parameters(sig)
    type_params = String[]

    if sig isa Expr && sig.head == :where
        # Handle single or multiple type parameters
        for i in 2:length(sig.args)
            push!(type_params, string(sig.args[i]))
        end
    end

    return type_params
end

"""
    get_definition_name(expr) -> Union{String, Nothing}

Extract the name from a definition expression.
"""
function get_definition_name(expr::Expr)
    if expr.head == :function || expr.head == :macro
        if length(expr.args) >= 1
            sig = expr.args[1]
            if sig isa Expr && sig.head == :call && length(sig.args) >= 1
                return string(sig.args[1])
            elseif sig isa Expr && sig.head == :where
                # f(x::T) where T = ...
                return get_definition_name(Expr(:function, sig.args[1]))
            elseif sig isa Symbol
                return string(sig)
            end
        end
    elseif expr.head == :struct || expr.head == :abstract || expr.head == :primitive
        if length(expr.args) >= 2
            name_expr = expr.args[2]
            if name_expr isa Symbol
                return string(name_expr)
            elseif name_expr isa Expr && name_expr.head == :<:
                return string(name_expr.args[1])
            elseif name_expr isa Expr && name_expr.head == :curly
                return string(name_expr.args[1])
            end
        end
    elseif expr.head == :(=) && length(expr.args) >= 1
        first_arg = expr.args[1]
        if first_arg isa Expr && first_arg.head == :call
            return string(first_arg.args[1])
        end
    elseif expr.head == :const && length(expr.args) >= 1
        inner = expr.args[1]
        if inner isa Expr && inner.head == :(=)
            return string(inner.args[1])
        end
    elseif expr.head == :macrocall
        # Try to find tool name from @mcp_tool
        for arg in expr.args
            if arg isa QuoteNode
                return string(arg.value)
            end
        end
    end
    return nothing
end

"""
    get_expr_lines(expr, lines) -> Tuple{Union{Int,Nothing}, Union{Int,Nothing}}

Get the start and end line numbers for an expression.
Uses heuristics based on expression structure.
"""
function get_expr_lines(expr::Expr, lines::Vector{<:AbstractString})
    # For functions/macros, look for the signature
    if expr.head in (:function, :macro) && length(expr.args) >= 1
        name = get_definition_name(expr)
        if name !== nothing
            # Find line containing "function name" or "macro name"
            keyword = expr.head == :function ? "function" : "macro"
            for (i, line) in enumerate(lines)
                if occursin(Regex("^\\s*$keyword\\s+$name"), line)
                    # Find matching end
                    depth = 1
                    for j = (i+1):length(lines)
                        l = strip(lines[j])
                        if startswith(l, "function ") ||
                           startswith(l, "macro ") ||
                           startswith(l, "if ") ||
                           startswith(l, "for ") ||
                           startswith(l, "while ") ||
                           startswith(l, "let ") ||
                           startswith(l, "begin") ||
                           startswith(l, "try") ||
                           startswith(l, "struct ") ||
                           startswith(l, "module ")
                            depth += 1
                        elseif l == "end" || startswith(l, "end ")
                            depth -= 1
                            if depth == 0
                                return (i, j)
                            end
                        end
                    end
                end
            end
        end
    elseif expr.head == :struct
        name = get_definition_name(expr)
        if name !== nothing
            for (i, line) in enumerate(lines)
                if occursin(Regex("^\\s*(mutable\\s+)?struct\\s+$name"), line)
                    for j = (i+1):length(lines)
                        if strip(lines[j]) == "end"
                            return (i, j)
                        end
                    end
                end
            end
        end
    elseif expr.head == :(=) && length(expr.args) >= 1
        # Short function definition - single line
        first_arg = expr.args[1]
        if first_arg isa Expr && first_arg.head == :call
            name = string(first_arg.args[1])
            for (i, line) in enumerate(lines)
                if occursin(Regex("^\\s*$name\\s*\\(.*\\)\\s*="), line)
                    return (i, i)
                end
            end
        end
    end

    return (nothing, nothing)
end

"""
    create_window_chunks(content::String, file_path::String) -> Vector{Dict}

Create overlapping window chunks for full file coverage.
"""
function create_window_chunks(content::String, file_path::String)
    chunks = Dict[]
    lines = split(content, '\n')

    if length(content) <= CHUNK_SIZE
        # Small file - single chunk
        push!(
            chunks,
            Dict(
                "text" => content,
                "file" => file_path,
                "start_line" => 1,
                "end_line" => length(lines),
                "type" => "window",
                "name" => basename(file_path),
            ),
        )
        return chunks
    end

    # Create overlapping windows
    chunk_lines = 50  # Approximate lines per chunk
    overlap_lines = 10

    start_line = 1
    while start_line <= length(lines)
        end_line = min(start_line + chunk_lines - 1, length(lines))
        text = join(lines[start_line:end_line], "\n")

        # Extend if we're in the middle of something, but respect CHUNK_SIZE limit
        while end_line < length(lines) && length(text) < CHUNK_SIZE
            next_text = join(lines[start_line:(end_line+1)], "\n")
            if length(next_text) > CHUNK_SIZE
                break  # Don't exceed CHUNK_SIZE
            end
            end_line += 1
            text = next_text
        end

        push!(
            chunks,
            Dict(
                "text" => text,
                "file" => file_path,
                "start_line" => start_line,
                "end_line" => end_line,
                "type" => "window",
                "name" => "$(basename(file_path)):$(start_line)-$(end_line)",
            ),
        )

        # Move to next chunk with overlap, but ensure we make progress
        next_start = end_line - overlap_lines + 1
        if next_start <= start_line
            # Prevent infinite loop - move at least one line forward
            next_start = start_line + 1
        end
        start_line = next_start

        # Exit if we've covered the whole file
        if end_line >= length(lines)
            break
        end
    end

    return chunks
end

"""
    split_chunk_recursive(chunk::Dict, max_length::Int, model::String) -> Vector{Dict}

Recursively split a chunk if it's too large or fails to embed.
Returns a vector of successfully embedded sub-chunks with their embeddings.
"""
function split_chunk_recursive(chunk::Dict, max_length::Int, model::String, depth::Int=0)
    text = chunk["text"]

    # Limit recursion depth to prevent infinite loops
    if depth > 10
        with_index_logger(() -> @warn "Maximum recursion depth reached for chunk splitting" file = chunk["file"] start_line = chunk["start_line"])
        return Dict[]
    end

    # Try to embed the chunk as-is if it's within size limit
    if length(text) <= max_length
        embedding = get_ollama_embedding(text; model=model)
        if !isempty(embedding)
            # Success - return chunk with embedding
            return [merge(chunk, Dict("embedding" => embedding, "text" => text))]
        end
        # Embedding failed even though text is small enough - try splitting anyway
    end

    # Text is too large or embedding failed - split in half by lines
    lines = split(text, '\n')
    if length(lines) <= 1
        # Can't split further - just truncate
        with_index_logger(() -> @warn "Cannot split chunk further, truncating" file = chunk["file"] start_line = chunk["start_line"] original_length = length(text))
        truncated = first(text, max_length)
        embedding = get_ollama_embedding(truncated; model=model)
        if !isempty(embedding)
            return [merge(chunk, Dict("embedding" => embedding, "text" => truncated))]
        else
            return Dict[]
        end
    end

    # Split into two halves
    mid = div(length(lines), 2)
    first_half_text = join(lines[1:mid], '\n')
    second_half_text = join(lines[mid+1:end], '\n')

    # Calculate approximate line numbers for each half
    start_line = chunk["start_line"]
    end_line = chunk["end_line"]
    mid_line = start_line + mid

    # Create sub-chunks
    chunk1 = merge(chunk, Dict(
        "text" => first_half_text,
        "end_line" => mid_line,
        "name" => chunk["name"] * " (part 1)"
    ))

    chunk2 = merge(chunk, Dict(
        "text" => second_half_text,
        "start_line" => mid_line + 1,
        "name" => chunk["name"] * " (part 2)"
    ))

    # Recursively process each half
    results = Dict[]
    append!(results, split_chunk_recursive(chunk1, max_length, model, depth + 1))
    append!(results, split_chunk_recursive(chunk2, max_length, model, depth + 1))

    return results
end

"""
    index_file(file_path::String, collection::String; project_path::String=pwd(), verbose::Bool=true, silent::Bool=false) -> Int

Index a single Julia file into Qdrant. Returns number of chunks indexed.
Uses split-and-retry strategy for oversized chunks.
Set silent=true to suppress all output (logs to file only).
"""
function index_file(
    file_path::String,
    collection::String;
    project_path::String=pwd(),
    verbose::Bool=true,
    silent::Bool=false,
    embedding_model::String=DEFAULT_EMBEDDING_MODEL,
)
    if !isfile(file_path)
        msg = "File not found: $file_path"
        !silent && verbose && println("  ⚠️  $msg")
        with_index_logger(() -> @warn msg)
        return 0
    end

    content = if endswith(lowercase(file_path), ".pdf")
        text = applicable(_extract_pdf_text, file_path) ? _extract_pdf_text(file_path) : nothing
        if text === nothing
            msg = "Skipping PDF (PDFIO not loaded): $(basename(file_path))"
            !silent && verbose && println("  ⏭️  $msg")
            with_index_logger(() -> @info msg)
            return 0
        end
        text
    else
        try
            read(file_path, String)
        catch e
            msg = "Failed to read: $(basename(file_path))"
            !silent && verbose && println("  ⚠️  $msg - $e")
            with_index_logger(() -> @warn msg exception = e)
            return 0
        end
    end

    if isempty(strip(content))
        msg = "Skipping empty file: $(basename(file_path))"
        !silent && verbose && println("  ⏭️  $msg")
        with_index_logger(() -> @debug msg)
        return 0
    end

    chunks = chunk_code(content, file_path)
    if isempty(chunks)
        msg = "No indexable content: $(basename(file_path))"
        !silent && verbose && println("  ⏭️  $msg")
        with_index_logger(() -> @debug msg)
        return 0
    end

    !silent && verbose && println("  📄 $(basename(file_path)): $(length(chunks)) chunks")
    with_index_logger(() -> @info "Indexing file" file = basename(file_path) chunks = length(chunks))

    try
        points = Dict[]

        # Get embedding config for size limits
        embedding_config = get_embedding_config(embedding_model)
        max_length = embedding_config.context_chars

        for (i, chunk) in enumerate(chunks)
            text = chunk["text"]
            if isempty(strip(text))
                continue
            end

            # Use split-and-retry strategy for oversized chunks or embedding failures
            embedded_chunks = split_chunk_recursive(chunk, max_length, embedding_model)

            if isempty(embedded_chunks)
                with_index_logger(() -> @warn "Failed to embed chunk after splitting" file = file_path chunk = i start_line = chunk["start_line"] end_line = chunk["end_line"])
                continue
            end

            # Process each successfully embedded sub-chunk
            for embedded_chunk in embedded_chunks
                # Create point with UUID
                point_id = string(Base.UUID(rand(UInt128)))

                # Build payload with all available metadata
                payload = Dict(
                    "file" => embedded_chunk["file"],
                    "start_line" => embedded_chunk["start_line"],
                    "end_line" => embedded_chunk["end_line"],
                    "type" => embedded_chunk["type"],
                    "name" => embedded_chunk["name"],
                    "text" => first(embedded_chunk["text"], 2000),  # Truncate for storage (Unicode-safe)
                    "project_path" => project_path,
                    "collection" => collection,
                    "indexed_at" => round(Int, time()),
                    "kaimon_schema" => 1,  # schema version for future migrations
                )

                # Add optional metadata fields if they exist
                for key in ["signature", "parameters", "type_params", "parent_type", "is_mutable", "is_exported"]
                    if haskey(embedded_chunk, key) && !isempty(embedded_chunk[key])
                        payload[key] = embedded_chunk[key]
                    end
                end

                push!(
                    points,
                    Dict(
                        "id" => point_id,
                        "vector" => embedded_chunk["embedding"],
                        "payload" => payload,
                    ),
                )

                # Batch upsert every 10 points
                if length(points) >= 10
                    QdrantClient.upsert_points(collection, points)
                    _upsert_to_global!(points)
                    points = Dict[]
                end
            end
        end

        # Upsert remaining points
        if !isempty(points)
            QdrantClient.upsert_points(collection, points)
            _upsert_to_global!(points)
        end

        # Record in index state for change tracking
        record_indexed_file(project_path, file_path, mtime(file_path), length(chunks))

        # Reset failed file counter on success
        delete!(INDEX_FAILED_FILES[], file_path)

        with_index_logger(() -> @info "Successfully indexed file" file = basename(file_path) chunks = length(chunks))

        return length(chunks)
    catch e
        # Track failed files
        INDEX_FAILED_FILES[][file_path] = get(INDEX_FAILED_FILES[], file_path, 0) + 1
        fail_count = INDEX_FAILED_FILES[][file_path]

        msg = "Error indexing $(basename(file_path))"
        !silent && verbose && println("  ❌ $msg: $e")
        with_index_logger(() -> @error msg file = file_path fail_count = fail_count exception = (e, catch_backtrace()))
        return 0
    end
end

"""
    reindex_file(file_path::String, collection::String; project_path::String=pwd(), verbose::Bool=true, silent::Bool=false) -> Int

Re-index a single file: delete old chunks, then index fresh.
Returns number of chunks indexed.
Set silent=true to suppress all output (logs to file only).
"""
function reindex_file(
    file_path::String,
    collection::String;
    project_path::String=pwd(),
    verbose::Bool=true,
    silent::Bool=false,
    embedding_model::String=DEFAULT_EMBEDDING_MODEL,
)
    collection = normalize_collection_name(collection)
    !silent && verbose && println("  Re-indexing: $(basename(file_path))")
    with_index_logger(() -> @info "Re-indexing file" file = basename(file_path))

    # Delete old chunks for this file from both project and global collections
    QdrantClient.delete_by_file(collection, file_path)
    gc = global_collection_name()
    try; QdrantClient.collection_exists(gc) && QdrantClient.delete_by_file(gc, file_path); catch; end

    # Index fresh (dual-writes to both collections)
    return index_file(file_path, collection; project_path=project_path, verbose=verbose, silent=silent, embedding_model=embedding_model)
end

"""
    index_directory(dir_path::String, collection::String; project_path::String=pwd(), extensions::Vector{String}=DEFAULT_INDEX_EXTENSIONS, verbose::Bool=true, silent::Bool=false) -> Int

Index all matching files in a directory. Returns total chunks indexed.
Supports multiple file extensions (.jl, .ts, .tsx, .jsx, .md by default).
Set silent=true to suppress all output (logs to file only).
"""
function index_directory(
    dir_path::String,
    collection::String;
    project_path::String=pwd(),
    extensions::Vector{String}=DEFAULT_INDEX_EXTENSIONS,
    exclude_dirs::Vector{String}=String[],
    verbose::Bool=true,
    silent::Bool=false,
    embedding_model::String=DEFAULT_EMBEDDING_MODEL,
)
    total_chunks = 0
    isdir(dir_path) || return total_chunks

    # Build exclude set from user config + built-in ignores
    exclude_set = union(IGNORED_DIRS, Set(exclude_dirs))

    # Find all matching files
    files = String[]
    onerr = e -> begin
        with_index_logger(() -> @warn "Skipping unreadable directory during indexing" dir = dir_path collection = collection exception = e)
    end
    for (root, dirs, filenames) in walkdir(dir_path; onerror=onerr)
        # Skip hidden directories, well-known noise, and user-excluded dirs
        filter!(d -> !startswith(d, ".") && d ∉ exclude_set, dirs)

        for filename in filenames
            # Check if file matches any of the supported extensions
            if any(ext -> endswith(filename, ext), extensions)
                push!(files, joinpath(root, filename))
            end
        end
    end

    !silent && verbose && println("Found $(length(files)) files to index")
    with_index_logger(() -> @info "Indexing directory" dir = dir_path file_count = length(files))

    for file_path in files
        chunks = index_file(
            file_path,
            collection;
            project_path=project_path,
            verbose=verbose,
            silent=silent,
            embedding_model=embedding_model,
        )
        total_chunks += chunks
    end

    with_index_logger(() -> @info "Directory indexing complete" total_chunks = total_chunks)
    return total_chunks
end

"""
    index_project(project_path::String=pwd(); collection::Union{String,Nothing}=nothing, recreate::Bool=false, silent::Bool=false, extra_dirs::Vector{String}=String[], extensions::Vector{String}=DEFAULT_INDEX_EXTENSIONS) -> Int

Index a Julia project into Qdrant. Uses project directory name as collection if not specified.

# Arguments
- `project_path`: Path to project root (default: current directory)
- `collection`: Collection name (default: project directory name)
- `recreate`: Delete and recreate collection (default: false)
- `silent`: Suppress all output (default: false)
- `extra_dirs`: Additional directories to index beyond configured defaults (e.g., ["frontend/src", "dashboard-ui/src"])
- `extensions`: File extensions to index (default: from config or [".jl", ".ts", ".tsx", ".jsx", ".md"])

# Returns
Total number of chunks indexed across all directories.

# Configuration
Directories and extensions are resolved from the search config
(`~/.config/kaimon/search.json`), which stores per-project `dirs` and `extensions`
arrays. Use the Search Config panel in the TUI to update these settings.
"""
function index_project(
    project_path::String=pwd();
    collection::Union{String,Nothing}=nothing,
    recreate::Bool=false,
    silent::Bool=false,
    extra_dirs::Vector{String}=String[],
    extensions::Union{Vector{String},Nothing}=nothing,
    source::String="manual",
    embedding_model::String=DEFAULT_EMBEDDING_MODEL,
)
    # Use project name as collection if not specified; always normalize
    col_name = collection === nothing ? get_project_collection_name(project_path) : normalize_collection_name(collection)

    # Config resolution priority: explicit args → registry → defaults
    registry_config = get_project_config(project_path)

    config_dirs = String[]
    config_extensions = DEFAULT_INDEX_EXTENSIONS

    config_exclude_dirs = String[]

    # Use registry dirs/extensions/exclude if available
    if registry_config !== nothing
        reg_dirs = get(registry_config, "dirs", String[])
        if !isempty(reg_dirs)
            config_dirs = String.(reg_dirs)
        end
        reg_exts = get(registry_config, "extensions", nothing)
        if reg_exts !== nothing && !isempty(reg_exts)
            config_extensions = String.(reg_exts)
        end
        reg_exclude = get(registry_config, "exclude_dirs", String[])
        if !isempty(reg_exclude)
            config_exclude_dirs = String.(reg_exclude)
        end
    end

    # Use provided extensions or fall back to registry/defaults
    actual_extensions = extensions !== nothing ? extensions : config_extensions

    # Build list of directories to index
    dirs_to_index = String[]

    # If config has index_dirs set, use those as the base
    if !isempty(config_dirs)
        for dir in config_dirs
            full_path = isabspath(dir) ? dir : joinpath(project_path, dir)
            if isdir(full_path)
                push!(dirs_to_index, full_path)
            else
                !silent && @warn "Configured index directory not found, skipping" dir = dir
            end
        end
    else
        # Fall back to src/ if it exists; don't blindly recurse the project root
        src_dir = joinpath(project_path, "src")
        if isdir(src_dir)
            push!(dirs_to_index, src_dir)
        end
    end

    # Add extra directories (e.g., frontend, dashboard-ui) - these are additional to config
    for dir in extra_dirs
        full_path = joinpath(project_path, dir)
        if isdir(full_path) && !(full_path in dirs_to_index)
            push!(dirs_to_index, full_path)
        elseif !isdir(full_path)
            !silent && @warn "Extra directory not found, skipping" dir = dir
        end
    end

    # Get vector size for the embedding model
    embedding_config = get_embedding_config(embedding_model)
    vector_size = embedding_config.dims

    if recreate
        !silent && println("Recreating collection '$col_name' (model: $embedding_model, dims: $vector_size)...")
        with_index_logger(() -> @info "Recreating collection" collection = col_name model = embedding_model vector_size = vector_size)
        QdrantClient.delete_collection(col_name)
        QdrantClient.create_collection(col_name; vector_size=vector_size)
        # Also purge this project's entries from the global collection
        gc = global_collection_name()
        try
            if QdrantClient.collection_exists(gc)
                QdrantClient.delete_by_filter(gc, Dict(
                    "must" => [Dict("key" => "collection", "match" => Dict("value" => col_name))]
                ))
            end
        catch; end
    else
        # Check if collection exists; create if it doesn't
        existing_collections = QdrantClient.list_collections()
        if !(col_name in existing_collections)
            !silent && println("Creating collection '$col_name' (model: $embedding_model, dims: $vector_size)...")
            with_index_logger(() -> @info "Creating collection" collection = col_name model = embedding_model vector_size = vector_size)
            QdrantClient.create_collection(col_name; vector_size=vector_size)
        end
    end

    !silent && println("Indexing $(length(dirs_to_index)) director$(length(dirs_to_index) == 1 ? "y" : "ies") into collection '$col_name'...")
    with_index_logger(() -> @info "Indexing project" collection = col_name dirs = dirs_to_index extensions = actual_extensions)

    # Register project before indexing so that record_indexed_file can persist
    # per-file state to the registry during the loop (external projects store
    # index_state inside the registry entry; if the entry doesn't exist yet,
    # save_index_state silently drops every file's mtime record).
    register_project!(
        project_path;
        collection = col_name,
        dirs = dirs_to_index,
        extensions = actual_extensions,
        exclude_dirs = config_exclude_dirs,
        source = source,
    )

    # Index each directory and sum total chunks
    total_chunks = 0
    for dir in dirs_to_index
        chunks = index_directory(dir, col_name; project_path=project_path, silent=silent,
            extensions=actual_extensions, exclude_dirs=config_exclude_dirs, embedding_model=embedding_model)
        total_chunks += chunks
    end

    # Save completion timestamp to index cache
    state = load_index_state(project_path)
    state["last_indexed"] = round(Int, time())
    save_index_state(project_path, state)

    return total_chunks
end

"""
    sync_index(project_path::String=pwd(); collection::Union{String,Nothing}=nothing, verbose::Bool=true, silent::Bool=false) -> NamedTuple

Sync the Qdrant index with the current state of files on disk.
- Re-indexes files that have been modified since last index
- Removes index entries for deleted files
- Skips unchanged files

Uses the directory and extension configuration from the initial index_project call.

Returns (reindexed=N, deleted=M, chunks=K)
Set silent=true to suppress all output (logs to file only).
"""
function sync_index(
    project_path::String=pwd();
    collection::Union{String,Nothing}=nothing,
    verbose::Bool=true,
    silent::Bool=false,
)
    col_name = collection === nothing ? get_project_collection_name(project_path) : normalize_collection_name(collection)

    # Load indexing configuration from previous index_project call
    state = load_index_state(project_path)
    dirs_to_sync = state["config"]["dirs"]
    extensions = state["config"]["extensions"]

    exclude_dirs = String[]

    # Fallback chain: index state → registry → src/ heuristic
    if isempty(dirs_to_sync)
        reg_config = get_project_config(project_path)
        if reg_config !== nothing
            reg_dirs = get(reg_config, "dirs", String[])
            if !isempty(reg_dirs)
                dirs_to_sync = String.(reg_dirs)
            end
            reg_exts = get(reg_config, "extensions", nothing)
            if reg_exts !== nothing && !isempty(reg_exts)
                extensions = String.(reg_exts)
            end
            reg_exclude = get(reg_config, "exclude_dirs", String[])
            if !isempty(reg_exclude)
                exclude_dirs = String.(reg_exclude)
            end
        end
    end
    if isempty(dirs_to_sync)
        src_dir = joinpath(project_path, "src")
        if isdir(src_dir)
            push!(dirs_to_sync, src_dir)
        end
    end
    if isempty(dirs_to_sync)
        !silent && verbose && println("⚠️  No indexable directories found for '$col_name'")
        with_index_logger(() -> @warn "No indexable directories found" collection = col_name project = project_path)
        return (reindexed=0, deleted=0, chunks=0)
    end

    !silent && verbose && println("🔄 Syncing index for collection '$col_name' ($(length(dirs_to_sync)) director$(length(dirs_to_sync) == 1 ? "y" : "ies"))...")
    with_index_logger(() -> @info "Starting index sync" collection = col_name dirs = dirs_to_sync extensions = extensions)

    # Get files that need re-indexing from all directories
    stale_files = String[]
    for dir in dirs_to_sync
        append!(stale_files, get_stale_files(project_path, dir; extensions=extensions, exclude_dirs=exclude_dirs))
    end

    deleted_files = get_deleted_files(project_path)

    reindexed = 0
    deleted = 0
    total_chunks = 0

    # Handle deleted files (remove from both project and global collections)
    gc = global_collection_name()
    gc_exists = try; QdrantClient.collection_exists(gc); catch; false; end
    for file_path in deleted_files
        !silent && verbose && println("  Removing deleted: $(basename(file_path))")
        with_index_logger(() -> @info "Removing deleted file" file = basename(file_path))
        QdrantClient.delete_by_file(col_name, file_path)
        gc_exists && try; QdrantClient.delete_by_file(gc, file_path); catch; end
        remove_indexed_file(project_path, file_path)
        deleted += 1
    end

    # Re-index stale files
    for file_path in stale_files
        chunks = reindex_file(
            file_path,
            col_name;
            project_path=project_path,
            verbose=verbose,
            silent=silent,
        )
        total_chunks += chunks
        reindexed += 1
    end

    if !silent && verbose
        if reindexed == 0 && deleted == 0
            println("✓ Index is up to date")
        else
            println(
                "✓ Sync complete: $reindexed files re-indexed ($total_chunks chunks), $deleted files removed",
            )
        end
    end

    if reindexed > 0 || deleted > 0
        state = load_index_state(project_path)
        state["last_indexed"] = round(Int, time())
        save_index_state(project_path, state)
    end
    with_index_logger(() -> @info "Index sync complete" reindexed = reindexed deleted = deleted chunks = total_chunks)
    return (reindexed=reindexed, deleted=deleted, chunks=total_chunks)
end

"""
    setup_revise_hook(project_path::String=pwd(); collection::Union{String,Nothing}=nothing, silent::Bool=false)

Set up a Revise.jl callback to automatically re-index files when they change.
Only works if Revise is loaded in Main.
Set silent=true to suppress all output (logs to file only).
"""
function setup_revise_hook(
    project_path::String=pwd();
    collection::Union{String,Nothing}=nothing,
    silent::Bool=false,
)
    if !isdefined(Main, :Revise)
        msg = "Revise.jl not loaded - automatic re-indexing disabled"
        !silent && @warn msg
        with_index_logger(() -> @warn msg)
        return nothing
    end

    col_name = String(
        collection === nothing ? get_project_collection_name(project_path) : collection,
    )

    src_dir = joinpath(project_path, "src")
    if !isdir(src_dir)
        src_dir = project_path
    end

    # Revise callbacks are zero-arg in current Revise API.
    # We run sync_index() to incrementally pick up changed/deleted files.
    callback = function ()
        try
            result = sync_index(
                project_path;
                collection=col_name,
                verbose=false,
                silent=true,  # Always silent in background
            )
            with_index_logger(() -> @info "Auto-sync after Revise event" reindexed = result.reindexed deleted = result.deleted chunks = result.chunks)
        catch e
            with_index_logger(() -> @warn "Failed to sync index after Revise event" exception = e)
        end
    end

    # Register with Revise
    # Watch project source directory; callback is invoked by Revise with no args.
    try
        Main.Revise.add_callback(callback, [src_dir])
        msg = "Revise hook installed for automatic index updates"
        !silent && @info msg
        with_index_logger(() -> @info msg collection = col_name)
        return callback
    catch e
        msg = "Failed to set up Revise hook"
        !silent && @warn msg exception = e
        with_index_logger(() -> @warn msg exception = e)
        return nothing
    end
end

# Global refs for the scheduler
const INDEX_SYNC_TASK = Ref{Union{Task,Nothing}}(nothing)
const INDEX_SYNC_STOP = Ref{Bool}(false)
const REVISE_EVENT_TASK = Ref{Union{Task,Nothing}}(nothing)
const REVISE_EVENT_STOP = Ref{Bool}(false)
const REVISE_EVENT_CHANGES = Ref{Int}(0)

"""
    start_revise_event_watcher(; project_path::String=pwd(), collection::Union{String,Nothing}=nothing, silent::Bool=false)

Start an event-driven Revise watcher that waits on `Revise.revision_event`,
applies revisions, and syncs the Qdrant index after each change.
"""
function start_revise_event_watcher(;
    project_path::String=pwd(),
    collection::Union{String,Nothing}=nothing,
    silent::Bool=false,
)
    if !isdefined(Main, :Revise)
        msg = "Revise.jl not loaded - event watcher disabled"
        !silent && @warn msg
        with_index_logger(() -> @warn msg)
        return nothing
    end

    if REVISE_EVENT_TASK[] !== nothing && !istaskdone(REVISE_EVENT_TASK[])
        msg = "Revise event watcher already running"
        !silent && @warn msg
        with_index_logger(() -> @warn msg)
        return REVISE_EVENT_TASK[]
    end

    col_name = String(
        collection === nothing ? get_project_collection_name(project_path) : collection,
    )
    REVISE_EVENT_STOP[] = false
    REVISE_EVENT_CHANGES[] = 0

    task = @async begin
        while !REVISE_EVENT_STOP[]
            try
                # Wait for filesystem change notification (Revise-level signal)
                wait(Main.Revise.revision_event)
                REVISE_EVENT_STOP[] && break
                Base.reset(Main.Revise.revision_event)

                # Apply pending revisions before syncing index
                Main.Revise.revise()

                REVISE_EVENT_CHANGES[] += 1
                result = sync_index(
                    project_path;
                    collection=col_name,
                    verbose=false,
                    silent=true,
                )
                with_index_logger(() -> @info "Revise applied changes" total_changes = REVISE_EVENT_CHANGES[] reindexed = result.reindexed deleted = result.deleted chunks = result.chunks)
            catch e
                if e isa InterruptException || REVISE_EVENT_STOP[]
                    break
                end
                with_index_logger(() -> @error "Revise watcher error" exception = (e, catch_backtrace()))
                sleep(1)  # Brief back-off on error
            end
        end
    end

    REVISE_EVENT_TASK[] = task
    msg = "Revise event watcher started"
    !silent && @info msg collection = col_name
    with_index_logger(() -> @info msg collection = col_name)
    return task
end

"""
    stop_revise_event_watcher(; silent::Bool=false)

Stop the event-driven Revise watcher if running.
"""
function stop_revise_event_watcher(; silent::Bool=false)
    task = REVISE_EVENT_TASK[]
    if task === nothing || istaskdone(task)
        return false
    end
    REVISE_EVENT_STOP[] = true
    try
        # Wake wait(revision_event) so the task can exit quickly.
        Base.notify(Main.Revise.revision_event)
    catch
    end
    try
        wait(task)
    catch
    end
    REVISE_EVENT_TASK[] = nothing
    msg = "Revise event watcher stopped"
    !silent && @info msg
    with_index_logger(() -> @info msg)
    return true
end

"""
    start_index_sync_scheduler(; project_path::String=pwd(), collection::Union{String,Nothing}=nothing, interval_seconds::Int=300, initial_delay::Int=10, silent::Bool=false)

Start a background task that periodically syncs the Qdrant index with file changes.
Default interval is 5 minutes (300 seconds), initial delay is 10 seconds.

Implements intelligent error handling:
- Exponential backoff on errors: 1min → 5min → 15min → 30min (max)
- Resets to normal interval on success
- Notifies user after 5+ consecutive failures
- Tracks and skips persistently problematic files

Returns the Task, or nothing if already running.
Set silent=true to suppress all output (logs to file only).
"""
function start_index_sync_scheduler(;
    project_path::String=pwd(),
    collection::Union{String,Nothing}=nothing,
    interval_seconds::Int=300,
    initial_delay::Int=10,
    silent::Bool=false,
)
    # Check if already running
    if INDEX_SYNC_TASK[] !== nothing && !istaskdone(INDEX_SYNC_TASK[])
        msg = "Index sync scheduler already running"
        !silent && @warn msg
        with_index_logger(() -> @warn msg)
        return nothing
    end

    col_name = String(
        collection === nothing ? get_project_collection_name(project_path) : collection,
    )

    INDEX_SYNC_STOP[] = false
    INDEX_ERROR_COUNT[] = 0
    INDEX_USER_NOTIFIED[] = false

    msg = "Starting index sync scheduler"
    !silent && @info msg collection = col_name interval_seconds = interval_seconds initial_delay = initial_delay
    with_index_logger(() -> @info msg collection = col_name interval_seconds = interval_seconds)

    task = @async begin
        # Initial delay before first sync
        for _ = 1:initial_delay
            INDEX_SYNC_STOP[] && break
            sleep(1)
        end

        current_interval = interval_seconds

        while !INDEX_SYNC_STOP[]
            try
                # Sleep in small increments to check stop flag
                for _ = 1:current_interval
                    INDEX_SYNC_STOP[] && break
                    sleep(1)
                end
                INDEX_SYNC_STOP[] && break

                # Run sync (always silent in background)
                result = sync_index(project_path; collection=col_name, verbose=false, silent=true)

                # Success - reset error tracking
                if INDEX_ERROR_COUNT[] > 0
                    INDEX_ERROR_COUNT[] = 0
                    INDEX_USER_NOTIFIED[] = false
                    current_interval = interval_seconds  # Reset to normal interval
                    with_index_logger(() -> @info "Index sync recovered" interval_reset_to = interval_seconds)
                end

                if result.reindexed > 0 || result.deleted > 0
                    with_index_logger(() -> @info "Index sync completed" reindexed = result.reindexed deleted = result.deleted chunks = result.chunks)
                end
            catch e
                if !INDEX_SYNC_STOP[]
                    INDEX_ERROR_COUNT[] += 1
                    INDEX_LAST_ERROR_TIME[] = time()

                    # Exponential backoff: 60s → 300s → 900s → 1800s (max)
                    backoff_intervals = [60, 300, 900, 1800]
                    current_interval = backoff_intervals[min(INDEX_ERROR_COUNT[], length(backoff_intervals))]

                    with_index_logger(() -> @error "Index sync scheduler error" error_count = INDEX_ERROR_COUNT[] next_retry_seconds = current_interval exception = (e, catch_backtrace()))

                    # Check if we should notify user
                    check_and_notify_index_errors()
                end
            end
        end

        with_index_logger(() -> @info "Index sync scheduler stopped")
    end

    INDEX_SYNC_TASK[] = task
    return task
end

"""
    stop_index_sync_scheduler()

Stop the background index sync scheduler if running.
"""
function stop_index_sync_scheduler()
    if INDEX_SYNC_TASK[] === nothing || istaskdone(INDEX_SYNC_TASK[])
        @info "Index sync scheduler not running"
        return false
    end

    INDEX_SYNC_STOP[] = true
    @info "Stopping index sync scheduler (will stop within 1 second)..."
    return true
end

"""
    index_sync_status() -> NamedTuple

Get the current status of the index sync scheduler.
"""
function index_sync_status()
    task = INDEX_SYNC_TASK[]
    if task === nothing
        return (running = false, state = :not_started)
    end
    if istaskdone(task)
        return (running = false, state = :finished, failed = istaskfailed(task))
    end
    current_state = task.state
    return (running = true, state = current_state)
end

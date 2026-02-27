"""
Code Indexer for Qdrant Vector Search

Indexes Julia source files into Qdrant for semantic code search.
Uses Ollama for embeddings (qwen3-embedding model).
"""

# Uses QdrantClient, get_ollama_embedding, and DEFAULT_EMBEDDING_MODEL from parent scope

# Embedding model configuration
const EMBEDDING_CONFIGS = Dict(
    "qwen3-embedding:0.6b" => (dims=1024, context_tokens=8192, context_chars=16000),
    "qwen3-embedding" => (dims=4096, context_tokens=8192, context_chars=16000),
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

# ── Project Registry ──────────────────────────────────────────────────────────
# Central JSON file at ~/.cache/kaimon/projects.json that persists indexing
# config for all projects (gate-connected and manually added external ones).
# External projects store their index state inside the registry entry to avoid
# writing any files to the target project directory.

"""Path to the project registry JSON file."""
_project_registry_path() = joinpath(kaimon_cache_dir(), "projects.json")

"""
    load_project_registry() -> Dict

Load the project registry from disk. Returns an empty registry if missing.
"""
function load_project_registry()
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
        @warn "Failed to load project registry, starting fresh" exception = e
        return Dict("version" => 1, "projects" => Dict{String,Any}())
    end
end

"""
    save_project_registry(registry::Dict)

Write the project registry to disk.
"""
function save_project_registry(registry::AbstractDict)
    path = _project_registry_path()
    try
        write(path, JSON.json(registry, 2))
    catch e
        @error "Failed to save project registry" exception = e
    end
end

"""
    register_project!(path::String; collection::String="", dirs::Vector{String}=String[],
                       extensions::Vector{String}=DEFAULT_INDEX_EXTENSIONS,
                       auto_index::Bool=true, source::String="gate")

Upsert a project entry in the registry. `source` is either `"gate"` (auto-indexed
from a REPL connection) or `"manual"` (user-added via the search manage UI);
it controls which UI section a project appears in.
"""
function register_project!(
    path::String;
    collection::String = "",
    dirs::Vector{String} = String[],
    extensions::Vector{String} = DEFAULT_INDEX_EXTENSIONS,
    auto_index::Bool = true,
    source::String = "gate",
)
    path = abspath(path)
    registry = load_project_registry()
    if isempty(collection)
        collection = get_project_collection_name(path)
    end
    existing = get(registry["projects"], path, Dict{String,Any}())
    existing["collection"] = collection
    existing["dirs"] = dirs
    existing["extensions"] = extensions
    existing["auto_index"] = auto_index
    existing["source"] = source
    if !haskey(existing, "index_state")
        existing["index_state"] = Dict{String,Any}()
    end
    registry["projects"][path] = existing
    save_project_registry(registry)
end

"""
    unregister_project!(path::String)

Remove a project entry from the registry.
"""
function unregister_project!(path::String)
    path = abspath(path)
    registry = load_project_registry()
    delete!(registry["projects"], path)
    save_project_registry(registry)
end

"""
    get_project_config(path::String) -> Union{Dict, Nothing}

Look up a project's config by absolute path.
"""
function get_project_config(path::String)
    path = abspath(path)
    registry = load_project_registry()
    return get(registry["projects"], path, nothing)
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
        # Skip hidden dirs and node_modules
        filter!(d -> !startswith(d, ".") && d != "node_modules" && d != "__pycache__", dirs)
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

# Lightweight file tracking for indexing state.
# All state is stored centrally in ~/.cache/kaimon/projects.json — we never
# write into the user's project directories.

"""
    load_index_state(project_path::String) -> Dict

Load the index state for a project from the central registry
(~/.cache/kaimon/projects.json). Returns a default empty state if the
project has not been indexed yet.

Structure:
- "config": Dict with "dirs" (full list of indexed directories) and "extensions"
- "files": Dict mapping file paths to their index metadata
"""
function load_index_state(project_path::String)
    _default_state() = Dict(
        "config" => Dict(
            "dirs" => String[],
            "extensions" => DEFAULT_INDEX_EXTENSIONS,
        ),
        "files" => Dict(),
    )

    config = get_project_config(project_path)
    config === nothing && return _default_state()
    idx_state = get(config, "index_state", Dict())
    parsed_config = Dict(
        "dirs" => Vector{String}(get(idx_state, "dirs", get(config, "dirs", String[]))),
        "extensions" => Vector{String}(get(idx_state, "extensions", get(config, "extensions", DEFAULT_INDEX_EXTENSIONS))),
    )
    files = Dict(get(idx_state, "files", Dict()))
    return Dict("config" => parsed_config, "files" => files)
end

"""
    save_index_state(project_path::String, state::Dict)

Persist the index state for a project into the central registry
(~/.cache/kaimon/projects.json). Creates the registry entry if it does not
exist yet, so state is never silently dropped for unregistered projects.
"""
function save_index_state(project_path::String, state)
    try
        registry = load_project_registry()
        ap = abspath(project_path)
        entry = get!(registry["projects"], ap, Dict{String,Any}())
        entry["index_state"] = Dict(
            "dirs" => get(get(state, "config", Dict()), "dirs", String[]),
            "extensions" => get(get(state, "config", Dict()), "extensions", DEFAULT_INDEX_EXTENSIONS),
            "files" => get(state, "files", Dict()),
        )
        save_project_registry(registry)
    catch e
        @error "Failed to save index state to registry" exception = e
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
function get_stale_files(project_path::String, src_dir::String; extensions::Vector{String}=DEFAULT_INDEX_EXTENSIONS)
    stale = String[]
    isdir(src_dir) || return stale

    files_state = load_index_state(project_path)["files"]

    onerr = e -> begin
        with_index_logger(() -> @warn "Skipping unreadable directory during stale scan" exception = e)
    end
    for (root, dirs, files) in walkdir(src_dir; onerror=onerr)
        filter!(d -> !startswith(d, ".") && d != "node_modules", dirs)

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
    return normalize_collection_name(basename(abspath(project_path)))
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
function _resolve_collection(name::Union{String,Nothing}, available::Vector{String}; project_path::String=pwd())
    # Default to project collection if not specified
    if name === nothing || isempty(name)
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
)
    if !isfile(file_path)
        msg = "File not found: $file_path"
        !silent && verbose && println("  ⚠️  $msg")
        with_index_logger(() -> @warn msg)
        return 0
    end

    content = try
        read(file_path, String)
    catch e
        msg = "Failed to read: $(basename(file_path))"
        !silent && verbose && println("  ⚠️  $msg - $e")
        with_index_logger(() -> @warn msg exception = e)
        return 0
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
        embedding_config = get_embedding_config(DEFAULT_EMBEDDING_MODEL)
        max_length = embedding_config.context_chars

        for (i, chunk) in enumerate(chunks)
            text = chunk["text"]
            if isempty(strip(text))
                continue
            end

            # Use split-and-retry strategy for oversized chunks or embedding failures
            embedded_chunks = split_chunk_recursive(chunk, max_length, DEFAULT_EMBEDDING_MODEL)

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
                    points = Dict[]
                end
            end
        end

        # Upsert remaining points
        if !isempty(points)
            QdrantClient.upsert_points(collection, points)
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
)
    collection = normalize_collection_name(collection)
    !silent && verbose && println("  Re-indexing: $(basename(file_path))")
    with_index_logger(() -> @info "Re-indexing file" file = basename(file_path))

    # Delete old chunks for this file
    QdrantClient.delete_by_file(collection, file_path)

    # Index fresh
    return index_file(file_path, collection; project_path=project_path, verbose=verbose, silent=silent)
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
    verbose::Bool=true,
    silent::Bool=false,
)
    total_chunks = 0
    isdir(dir_path) || return total_chunks

    # Find all matching files
    files = String[]
    onerr = e -> begin
        with_index_logger(() -> @warn "Skipping unreadable directory during indexing" exception = e)
    end
    for (root, dirs, filenames) in walkdir(dir_path; onerror=onerr)
        # Skip hidden directories and node_modules
        filter!(d -> !startswith(d, ".") && d != "node_modules", dirs)

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
Default directories and extensions can be configured in .kaimon/security.json:
- `index_dirs`: Array of directories relative to project root (e.g., ["src", "lib", "dashboard-ui/src"])
- `index_extensions`: Array of file extensions to index (e.g., [".jl", ".ts", ".md"])

Use `Kaimon.set_index_dirs!()` and `Kaimon.set_index_extensions!()` to update config.
"""
function index_project(
    project_path::String=pwd();
    collection::Union{String,Nothing}=nothing,
    recreate::Bool=false,
    silent::Bool=false,
    extra_dirs::Vector{String}=String[],
    extensions::Union{Vector{String},Nothing}=nothing,
    source::String="manual",
)
    # Use project name as collection if not specified; always normalize
    col_name = collection === nothing ? get_project_collection_name(project_path) : normalize_collection_name(collection)

    # Config resolution priority: explicit args → registry → security.json → defaults
    registry_config = get_project_config(project_path)

    config = load_security_config(project_path)
    config_dirs = config !== nothing ? config.index_dirs : String[]
    config_extensions = config !== nothing ? config.index_extensions : DEFAULT_INDEX_EXTENSIONS

    # Use registry dirs/extensions as intermediate fallback
    if isempty(config_dirs) && registry_config !== nothing
        reg_dirs = get(registry_config, "dirs", String[])
        if !isempty(reg_dirs)
            config_dirs = Vector{String}(reg_dirs)
        end
    end
    if registry_config !== nothing && extensions === nothing
        reg_exts = get(registry_config, "extensions", nothing)
        if reg_exts !== nothing && !isempty(reg_exts)
            config_extensions = Vector{String}(reg_exts)
        end
    end

    # Use provided extensions or fall back to config/defaults
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
        # Fall back to existing behavior: add src/ if it exists
        src_dir = joinpath(project_path, "src")
        if isdir(src_dir)
            push!(dirs_to_index, src_dir)
        elseif isempty(extra_dirs)
            # If no src/ and no extra dirs, index entire project
            push!(dirs_to_index, project_path)
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
    embedding_config = get_embedding_config(DEFAULT_EMBEDDING_MODEL)
    vector_size = embedding_config.dims

    if recreate
        !silent && println("Recreating collection '$col_name' (model: $DEFAULT_EMBEDDING_MODEL, dims: $vector_size)...")
        with_index_logger(() -> @info "Recreating collection" collection = col_name model = DEFAULT_EMBEDDING_MODEL vector_size = vector_size)
        QdrantClient.delete_collection(col_name)
        QdrantClient.create_collection(col_name; vector_size=vector_size)
    else
        # Check if collection exists; create if it doesn't
        existing_collections = QdrantClient.list_collections()
        if !(col_name in existing_collections)
            !silent && println("Creating collection '$col_name' (model: $DEFAULT_EMBEDDING_MODEL, dims: $vector_size)...")
            with_index_logger(() -> @info "Creating collection" collection = col_name model = DEFAULT_EMBEDDING_MODEL vector_size = vector_size)
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
        source = source,
    )

    # Index each directory and sum total chunks
    total_chunks = 0
    for dir in dirs_to_index
        chunks = index_directory(dir, col_name; project_path=project_path, silent=silent, extensions=actual_extensions)
        total_chunks += chunks
    end

    # Save indexing configuration and completion timestamp
    state = load_index_state(project_path)
    state["config"]["dirs"] = dirs_to_index
    state["config"]["extensions"] = actual_extensions
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

    # Fallback chain: index state → registry → src/ heuristic
    if isempty(dirs_to_sync)
        reg_config = get_project_config(project_path)
        if reg_config !== nothing
            reg_dirs = get(reg_config, "dirs", String[])
            if !isempty(reg_dirs)
                dirs_to_sync = Vector{String}(reg_dirs)
            end
            reg_exts = get(reg_config, "extensions", nothing)
            if reg_exts !== nothing && !isempty(reg_exts)
                extensions = Vector{String}(reg_exts)
            end
        end
    end
    if isempty(dirs_to_sync)
        src_dir = joinpath(project_path, "src")
        if isdir(src_dir)
            push!(dirs_to_sync, src_dir)
        else
            push!(dirs_to_sync, project_path)
        end
    end

    !silent && verbose && println("🔄 Syncing index for collection '$col_name' ($(length(dirs_to_sync)) director$(length(dirs_to_sync) == 1 ? "y" : "ies"))...")
    with_index_logger(() -> @info "Starting index sync" collection = col_name dirs = dirs_to_sync extensions = extensions)

    # Get files that need re-indexing from all directories
    stale_files = String[]
    for dir in dirs_to_sync
        append!(stale_files, get_stale_files(project_path, dir; extensions=extensions))
    end

    deleted_files = get_deleted_files(project_path)

    reindexed = 0
    deleted = 0
    total_chunks = 0

    # Handle deleted files
    for file_path in deleted_files
        !silent && verbose && println("  Removing deleted: $(basename(file_path))")
        with_index_logger(() -> @info "Removing deleted file" file = basename(file_path))
        QdrantClient.delete_by_file(col_name, file_path)
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

# ─────────────────────────────────────────────────────────────────────────────
# Kaimon Qdrant indexer · index_file/reindex/directory/project · sync_index  (split from qdrant_indexer.jl)
# ─────────────────────────────────────────────────────────────────────────────

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
    embedding_model::String=resolve_search_model(collection),
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
    embedding_model::String=resolve_search_model(collection),
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
    embedding_model::String=resolve_search_model(collection),
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
    embedding_model::String=_load_embedding_model(),
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

    # Resolve the effective model. A recreate (or a brand-new collection) uses the
    # requested model; indexing INTO an existing collection keeps the model it was
    # built with (recorded, else DEFAULT for legacy) so we never mix vector spaces.
    existing_collections = QdrantClient.list_collections()
    col_exists = col_name in existing_collections
    if !recreate && col_exists
        eff_model = resolve_search_model(col_name)
        if eff_model != embedding_model
            !silent && @warn "Indexing into an existing collection with its own model (vectors from different models don't mix)" collection = col_name effective = eff_model requested = embedding_model
        end
        embedding_model = eff_model
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
    elseif !col_exists
        !silent && println("Creating collection '$col_name' (model: $embedding_model, dims: $vector_size)...")
        with_index_logger(() -> @info "Creating collection" collection = col_name model = embedding_model vector_size = vector_size)
        QdrantClient.create_collection(col_name; vector_size=vector_size)
    end

    # Stamp the model so searches query with the right one and future incremental
    # indexing stays consistent.
    set_collection_model!(col_name, embedding_model)

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


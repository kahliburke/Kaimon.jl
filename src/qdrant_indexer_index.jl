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
        fts_rows = Dict[]   # mirror of the same chunks for the lexical (FTS5) index

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

                # Lexical mirror: full chunk text (not the 2000-char vector-payload
                # truncation) so keyword/substring matches can land anywhere in it.
                push!(fts_rows, Dict(
                    "point_id" => point_id,
                    "collection" => collection,
                    "file" => embedded_chunk["file"],
                    "name" => embedded_chunk["name"],
                    "type" => embedded_chunk["type"],
                    "start_line" => embedded_chunk["start_line"],
                    "end_line" => embedded_chunk["end_line"],
                    "text" => embedded_chunk["text"],
                ))

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

        # Mirror chunks into the lexical (FTS5) index for hybrid search. Delete-
        # then-insert keeps it idempotent across fresh-index and reindex alike.
        # Additive: an FTS failure must never fail the (already-done) vector index.
        try
            FtsIndex.delete_file!(collection, file_path)
            FtsIndex.add_chunks!(fts_rows)
        catch e
            with_index_logger(() -> @warn "Lexical (FTS) index write failed (non-fatal)" file = basename(file_path) exception = e)
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
    _qdrant_distinct_files(collection; batch=256) -> Set{String}

Scroll a Qdrant collection and collect the distinct `file` payload values. Heavier
than the FTS list (a full scroll), so only used for `deep` reconciliation — to catch
points whose FTS co-write failed (FTS writes are best-effort) and were then deleted.
"""
function _qdrant_distinct_files(collection::String; batch::Int=256)
    files = Set{String}()
    QdrantClient.collection_exists(collection) || return files
    offset = nothing
    while true
        res = QdrantClient.scroll_points(collection; limit=batch, offset=offset, with_vector=false)
        haskey(res, "error") && break
        pts = get(res, "points", [])
        isempty(pts) && break
        for pt in pts
            f = get(get(pt, "payload", Dict()), "file", "")
            (f === nothing || isempty(f)) && continue
            push!(files, String(f))
        end
        offset = get(res, "next_page_offset", nothing)
        offset === nothing && break
    end
    return files
end

"""
    _orphan_files(collection; deep=false) -> Vector{String}

The indexed files for `collection` that no longer exist on disk. Candidate set is
the FTS `distinct_files` list (cheap, and a faithful proxy since `index_file`
dual-writes Qdrant + FTS); with `deep=true` it is unioned with the Qdrant scroll.
Pure (no side effects) so the detection logic is unit-testable without Qdrant.
"""
function _orphan_files(collection::String; deep::Bool=false)
    collection = normalize_collection_name(collection)
    candidates = Set{String}()
    try
        union!(candidates, FtsIndex.distinct_files(collection))
    catch e
        with_index_logger(() -> @warn "FTS distinct_files failed during orphan scan" collection = collection exception = e)
    end
    if deep
        try
            union!(candidates, _qdrant_distinct_files(collection))
        catch e
            with_index_logger(() -> @warn "Qdrant distinct-file scan failed during orphan scan" collection = collection exception = e)
        end
    end
    return String[f for f in candidates if !isfile(f)]
end

"""
    prune_orphans!(collection; project_path=nothing, deep=false, verbose=true, silent=false) -> NamedTuple

Remove index entries for files that no longer exist on disk, from BOTH the vector
(Qdrant — project + global collections) and lexical (FTS) indexes. When `project_path`
is given, also drops the file from the index-state cache. Returns
`(pruned=N, live=M, files=[...])` where `live` is the count of still-existing indexed
files (used by the sweep to detect wholesale-missing collections).

Each delete is guarded independently: an FTS failure must not abort the Qdrant cleanup
and vice versa.
"""
function prune_orphans!(
    collection::String;
    project_path::Union{String,Nothing}=nothing,
    deep::Bool=false,
    verbose::Bool=true,
    silent::Bool=false,
)
    col = normalize_collection_name(collection)
    orphans = _orphan_files(col; deep=deep)

    # Count of still-live indexed files (for wholesale-missing detection).
    live = 0
    try
        live = count(isfile, FtsIndex.distinct_files(col))
    catch
    end

    isempty(orphans) && return (pruned=0, live=live, files=String[])

    gc = global_collection_name()
    gc_exists = try; QdrantClient.collection_exists(gc); catch; false; end
    for file_path in orphans
        !silent && verbose && println("  Removing orphan: $(basename(file_path))")
        with_index_logger(() -> @info "Removing orphaned index entry" collection = col file = basename(file_path))
        try; QdrantClient.delete_by_file(col, file_path); catch; end
        gc_exists && try; QdrantClient.delete_by_file(gc, file_path); catch; end
        try; FtsIndex.delete_file!(col, file_path); catch; end
        project_path !== nothing && try; remove_indexed_file(project_path, file_path); catch; end
    end
    return (pruned=length(orphans), live=live, files=orphans)
end

"""
    gc_index_orphans!(; deep=false, drop_empty=false, verbose=true, silent=false) -> NamedTuple

Cross-collection sweep: prune orphaned index entries from every project collection
(both Qdrant and FTS). Reaches collections that per-project [`sync_index`](@ref) can
never touch — e.g. a project whose source tree was deleted wholesale. With
`drop_empty=true`, a collection left with zero on-disk files is dropped entirely
(Qdrant collection + FTS rows); otherwise it is left intact with a logged notice
(at startup an empty collection is indistinguishable from a temporarily-unavailable
mount/worktree). Returns `(pruned=N, dropped=[...], collections=K)`.
"""
function gc_index_orphans!(; deep::Bool=false, drop_empty::Bool=false, verbose::Bool=true, silent::Bool=false)
    gc = global_collection_name()
    cols = Set{String}()
    try; union!(cols, QdrantClient.list_collections()); catch; end
    try; union!(cols, (c.collection for c in FtsIndex.coverage().collections)); catch; end
    delete!(cols, gc)

    total_pruned = 0
    dropped = String[]
    for col in cols
        res = try
            prune_orphans!(col; deep=deep, verbose=verbose, silent=silent)
        catch e
            with_index_logger(() -> @warn "Orphan prune failed" collection = col exception = e)
            continue
        end
        total_pruned += res.pruned
        if res.live == 0 && (res.pruned > 0 || drop_empty)
            if drop_empty
                !silent && verbose && println("  Dropping empty collection: $col")
                with_index_logger(() -> @info "Dropping empty collection (no files on disk)" collection = col)
                try; QdrantClient.delete_collection(col); catch; end
                try; FtsIndex.clear_collection!(col); catch; end
                push!(dropped, col)
            else
                with_index_logger(() -> @warn "Collection has no files on disk — possible deleted project or unavailable mount; run gc_index_orphans!(drop_empty=true) to drop" collection = col)
            end
        end
    end
    return (pruned=total_pruned, dropped=dropped, collections=length(cols))
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
        # Purge the lexical index for this collection in lockstep.
        try; FtsIndex.clear_collection!(col_name); catch; end
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

    # Deleted files: the union of cache-tracked-but-missing (fast path) and any
    # orphans the cache no longer knows about (cache reset, narrowed dirs, indexed
    # elsewhere) — found by reconciling the FTS file list against disk. This prunes
    # BOTH the vector and lexical indexes; the cache-only path used to miss the FTS
    # side entirely, leaving stale lexical hits.
    deleted_files = unique(vcat(get_deleted_files(project_path), _orphan_files(col_name)))

    reindexed = 0
    deleted = 0
    total_chunks = 0

    # Handle deleted files (remove from both project and global collections + FTS)
    gc = global_collection_name()
    gc_exists = try; QdrantClient.collection_exists(gc); catch; false; end
    for file_path in deleted_files
        !silent && verbose && println("  Removing deleted: $(basename(file_path))")
        with_index_logger(() -> @info "Removing deleted file" file = basename(file_path))
        try; QdrantClient.delete_by_file(col_name, file_path); catch; end
        gc_exists && try; QdrantClient.delete_by_file(gc, file_path); catch; end
        try; FtsIndex.delete_file!(col_name, file_path); catch; end
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
    backfill_fts!(collection; batch=256) -> Int

Build the lexical (FTS5) index for an already-vector-indexed collection by
scrolling its Qdrant payloads — **no re-embedding**. Each payload already carries
`text` + metadata, so this is cheap and is how existing indexes light up hybrid
search without a re-index. Clears the collection's FTS rows first (idempotent).
Returns the number of chunks written. Skips the global cross-project collection
(lexical search spans per-project collections directly).
"""
function backfill_fts!(collection::String; batch::Int=256)
    collection = normalize_collection_name(collection)
    collection == global_collection_name() && return 0
    QdrantClient.collection_exists(collection) || return 0

    FtsIndex.clear_collection!(collection)
    total = 0
    offset = nothing
    while true
        res = QdrantClient.scroll_points(collection; limit=batch, offset=offset, with_vector=false)
        haskey(res, "error") && break
        pts = get(res, "points", [])
        isempty(pts) && break

        rows = Dict[]
        for pt in pts
            payload = get(pt, "payload", Dict())
            txt = get(payload, "text", "")
            (txt === nothing || isempty(txt)) && continue
            push!(rows, Dict(
                "point_id" => get(pt, "id", nothing),
                "collection" => collection,
                "file" => get(payload, "file", ""),
                "name" => get(payload, "name", ""),
                "type" => get(payload, "type", ""),
                "start_line" => get(payload, "start_line", 0),
                "end_line" => get(payload, "end_line", 0),
                "text" => txt,
            ))
        end
        total += FtsIndex.add_chunks!(rows)

        offset = get(res, "next_page_offset", nothing)
        offset === nothing && break
    end
    with_index_logger(() -> @info "FTS backfill complete" collection = collection chunks = total)
    return total
end

"""
    ensure_fts_coverage(collection::String) -> Int

Ensure one collection's payloads are mirrored into the lexical (FTS5) index so
[`fts_search`](@ref) / hybrid search can find them, and return the chunk count.

Thin, idempotent public wrapper over [`backfill_fts!`](@ref): scrolls the
collection's Qdrant payloads (each carrying a `text` field) — **no re-embedding** —
and clears+rebuilds its FTS rows. Call this AFTER writing points with a `text`
payload via the plain upsert path (`QdrantClient.upsert_points` /
`qdrant_upsert_points`), which does NOT touch the FTS index — only Kaimon's own
`index_file` pipeline co-writes FTS. Safe to call repeatedly: once FTS is at parity
it just re-scrolls and rewrites the same rows.
"""
ensure_fts_coverage(collection::String) = backfill_fts!(collection)

"""Backfill the lexical index for every vector-indexed project collection."""
function backfill_fts_all!()
    gc = global_collection_name()
    counts = Pair{String,Int}[]
    for col in QdrantClient.list_collections()
        col == gc && continue
        n = try; backfill_fts!(col); catch; 0; end
        push!(counts, col => n)
    end
    return counts
end

"""
    ensure_fts_coverage!() -> Vector{Pair{String,Int}}

Bring the lexical (FTS5) index up to parity with the vector index, then return the
collections it (re)built. For each vector collection, if its lexical coverage is
materially below its Qdrant point count — e.g. a collection indexed before the 2.0
hybrid-search upgrade, when no FTS index existed — backfill it from Qdrant payloads
(no re-embedding). Idempotent: once the counts match this is a cheap no-op (one
info call per collection), so it's safe to run on every startup; if the FTS DB is
ever lost it self-heals on the next boot. Runs in the background at startup.
"""
function ensure_fts_coverage!()
    QdrantClient.ping() || return Pair{String,Int}[]
    gc = global_collection_name()
    cov = try; FtsIndex.coverage(); catch; (collections = NamedTuple[], total = 0); end
    fts_counts = Dict(c.collection => c.n for c in cov.collections)

    built = Pair{String,Int}[]
    pruned = 0
    for col in QdrantClient.list_collections()
        col == gc && continue
        # Self-healing GC: drop index entries for files removed since last index,
        # from both Qdrant and FTS (cheap — an FTS DISTINCT scan + isfile). Individual
        # orphans only; a wholesale-missing collection is left intact (at boot that's
        # indistinguishable from an unavailable mount/worktree) — use
        # gc_index_orphans!(drop_empty=true) to drop those.
        pruned += try
            prune_orphans!(col; verbose = false, silent = true).pruned
        catch e
            with_index_logger(() -> @warn "Startup orphan prune failed" collection = col exception = e)
            0
        end
        qn = try
            round(Int, get(QdrantClient.get_collection_info(col), "points_count", 0))
        catch; 0; end
        qn == 0 && continue
        # The mapping is 1:1 — every non-empty chunk is exactly one Qdrant point
        # and one FTS row — so a correct index has fcount == qcount. Any shortfall
        # means FTS genuinely fell behind (never built, or a co-write that threw),
        # so rebuild it; once parity is reached this is a no-op (no churn). A
        # concurrent reindex_file deletes by (collection, file), so any transient
        # duplicate self-heals on that file's next reindex.
        if get(fts_counts, col, 0) < qn
            n = try
                backfill_fts!(col)
            catch e
                with_index_logger(() -> @warn "FTS coverage backfill failed" collection = col exception = e)
                continue
            end
            n > 0 && push!(built, col => n)
        end
    end
    (isempty(built) && pruned == 0) || with_index_logger(() -> @info "FTS coverage sync complete" built = built orphans_pruned = pruned)
    return built
end

"""
    _spawn_fts_coverage_sync!(; delay=8) -> Task

Run [`ensure_fts_coverage!`](@ref) once in the background, after a short delay so
startup auto-indexing settles first. Called from BOTH startup paths — the TUI
(`Tachikoma.setup!`) and headless (`_start_gate_services!`) — since they don't
share a single init. Errors are non-fatal and logged.
"""
function _spawn_fts_coverage_sync!(; delay::Real = 8)
    return Threads.@spawn begin
        try
            sleep(delay)
            ensure_fts_coverage!()
        catch e
            with_index_logger(() -> @warn "FTS coverage sync failed" exception = e)
        end
    end
end


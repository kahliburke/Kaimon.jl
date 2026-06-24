# ─────────────────────────────────────────────────────────────────────────────
# Kaimon Qdrant indexer · project-type discovery · index state · collection naming/resolution  (split from qdrant_indexer.jl)
# ─────────────────────────────────────────────────────────────────────────────

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
    _resolve_search_collection(raw, available) -> (name|nothing, err|nothing)

Default-collection resolution for `search_code`. With an explicit `raw` name it
defers to `_resolve_collection`. Without one, it walks the ladder — the calling
agent's bound session / workspace root → a single connected session → (embedded,
no gates) pwd → else an ambiguity error listing collection ↔ session ↔ project so
the agent can pick. Unlike the bare `pwd()` default, this never silently scopes a
multi-agent server to the wrong project.
"""
function _resolve_search_collection(raw::Union{String,Nothing}, available::Vector{String})
    raw === nothing || return _resolve_collection(raw, available)
    K = parentmodule(@__MODULE__)

    # 1. The caller's bound session / captured workspace root.
    proj = try; K._last_session_project_path(); catch; ""; end
    if !isempty(proj)
        rn, _ = _resolve_collection(get_project_collection_name(proj), available)
        rn in available && return (rn, nothing)
    end

    mgr = try; K.GATE_CONN_MGR[]; catch; nothing; end
    sessions = mgr === nothing ? () : K.connected_sessions(mgr)

    # 2. Embedded / no gates: the legacy pwd() default (one project == the cwd).
    isempty(sessions) && return _resolve_collection(nothing, available)

    # 3. Exactly one session: auto-pick it (mirrors `ex`'s single-session default).
    if length(sessions) == 1
        rn, _ = _resolve_collection(get_project_collection_name(first(sessions).project_path), available)
        rn in available && return (rn, nothing)
    end

    # 4. Ambiguous (≥2 sessions) or unresolved: require an explicit choice, with hints.
    return (nothing, _ambiguous_collection_error(available, sessions))
end

"""Associative error for an unscoped `search_code` when the agent isn't bound:
lists each connected REPL session as collection ↔ ses ↔ project so the agent can
pick the right `collection=` (and learn the `ses=` that would bind it)."""
function _ambiguous_collection_error(available::Vector{String}, sessions)
    K = parentmodule(@__MODULE__)
    io = IOBuffer()
    print(io, "no `collection` specified and no session is bound to this agent. ")
    print(io, "Pass `collection=` explicitly, or run a session tool first (e.g. `ex` with ")
    print(io, "`ses=<key>`) — the session you target becomes this agent's default for later searches.")
    if !isempty(sessions)
        print(io, "\n\nConnected REPL sessions (collection ↔ ses ↔ project):")
        for c in sessions
            nm = get_project_collection_name(c.project_path)
            shown = nm in available ? nm : "$nm (not indexed)"
            print(io, "\n  • ", shown, "  ↔  ses=", K.short_key(c), "  ↔  ", c.project_path)
        end
    end
    isempty(available) || print(io, "\n\nAll collections: ", join(available, ", "))
    return String(take!(io))
end


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

Result is memoized per path with a short TTL: file enumeration runs on a timer for
every registered project, and a non-git project would otherwise spawn a subprocess per
refresh. `git`'s stderr is discarded — "not a git repository" is the expected answer for
a plain directory, not something to surface as a warning.
"""
const _GIT_FILES_TTL = 5.0
const _GIT_FILES_LOCK = ReentrantLock()
const _GIT_FILES_CACHE = Dict{String,Tuple{Float64,Union{Vector{String},Nothing}}}()

function _git_tracked_files(project_path::String)
    now = time()
    lock(_GIT_FILES_LOCK) do
        hit = get(_GIT_FILES_CACHE, project_path, nothing)
        hit !== nothing && now - hit[1] < _GIT_FILES_TTL && return hit[2]
        result = try
            cmd = `git -C $project_path ls-files --cached --others --exclude-standard`
            output = read(pipeline(cmd; stderr=devnull), String)
            String[String(f) for f in split(output, '\n') if !isempty(f)]
        catch
            nothing
        end
        _GIT_FILES_CACHE[project_path] = (now, result)
        return result
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
        # Discover unique extensions, filtered to the source whitelist. Files under a
        # known build/vendor directory don't get a vote: in a JS project the committed
        # bundle output would otherwise outnumber the real sources and dominate the
        # detected extension set.
        ext_counts = Dict{String,Int}()
        for f in git_files
            _is_ignored_relpath(f) && continue
            ext = lowercase(splitext(f)[2])
            if ext in SOURCE_EXTENSIONS && ext ∉ AUTO_DETECT_EXTENSION_DENY
                ext_counts[ext] = get(ext_counts, ext, 0) + 1
            end
        end

        # Top extensions by frequency
        sorted_exts = sort(collect(ext_counts); by=last, rev=true)
        detected_exts = [first(p) for p in sorted_exts[1:min(12, length(sorted_exts))]]
        if isempty(detected_exts)
            detected_exts = copy(DEFAULT_INDEX_EXTENSIONS)
        end

        # Collapse file paths to minimal covering top-level dirs. Root-level source
        # files (scripts in the project root, README.md, ...) count as a target too:
        # skipping them whenever some subdirectory also had sources silently dropped
        # them from the index (#80). `collect_index_files` collapses the root against
        # the subdirectories it subsumes, so this costs no duplicate work.
        top_dirs = Set{String}()
        for f in git_files
            _is_ignored_relpath(f) && continue
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
                push!(top_dirs, ".")
            end
        end

        # Convert to absolute paths, filter to existing dirs. The project root enters
        # the list NON-recursively when it holds sources of its own: root-level files
        # get indexed without the root swallowing every sibling directory — and without
        # silently absorbing whatever top-level directory appears next. When the root is
        # the only target there is nothing to subsume, so it recurses as usual.
        abs_dirs = String[]
        root_files = "." in top_dirs
        for d in sort(collect(top_dirs))
            d == "." && continue
            full = joinpath(path, d)
            isdir(full) && push!(abs_dirs, full)
        end
        if root_files
            push!(abs_dirs, isempty(abs_dirs) ? path : _nonrecursive(path))
        end
        if isempty(abs_dirs)
            push!(abs_dirs, path)
        end
        abs_dirs = _collapse_subsumed_dirs(abs_dirs)

        # Determine project type from markers (for the type label)
        marker_result = detect_project_type(path)
        ptype = marker_result.type

        return (type=ptype, dirs=abs_dirs, extensions=detected_exts, git_aware=true)
    end

    # Non-git fallback
    result = detect_project_type(path)
    return (type=result.type, dirs=result.dirs, extensions=result.extensions, git_aware=false)
end

# ── Canonical index-target resolution ────────────────────────────────────────
#
# "Which files does this project index?" must have exactly one answer. It used to have
# four — index_project, _sync_index_impl, the Collection Manager's stale count, and
# load_index_state — each with its own `src/`-shaped guess. They disagreed: for a project
# with no `src/` the manager counted the whole tree as stale while indexing visited
# nothing, so the TUI reported work that syncing would never do (#80).
#
# resolve_index_config answers "which directories and extensions", collect_index_files
# answers "which files". Everything downstream goes through them, so the counter and the
# indexer cannot drift apart again.

const _PATH_SEP = Base.Filesystem.path_separator

"""
    _dir_prefix(dir) -> String

`dir` with a trailing path separator, for prefix containment tests.
"""
_dir_prefix(dir::String) = endswith(dir, _PATH_SEP) ? dir : dir * _PATH_SEP

"""
    _within(path, dir) -> Bool

True when `path` is `dir` itself or sits underneath it.
"""
_within(path::String, dir::String) = path == dir || startswith(path, _dir_prefix(dir))

# A target directory may be marked non-recursive by a trailing `/*`, meaning "the files
# directly in this directory, not its subtree". This exists mainly for the project root:
# root-level sources should be indexed without the root silently swallowing every
# sibling directory (and every top-level directory added later). Keeping the marker in
# the directory list rather than in a separate flag preserves the property that the list
# alone fully describes what gets scanned.
const _NONRECURSIVE_SUFFIX = "*"

"""
    _parse_target(entry) -> (path, recursive)

Split a configured directory entry into its path and whether it recurses. A trailing
`/*` (or `\\*` on Windows) marks the entry non-recursive.
"""
function _parse_target(entry::String)
    for sep in unique((_PATH_SEP, "/"))
        if endswith(entry, sep * _NONRECURSIVE_SUFFIX)
            trimmed = chop(entry; tail=length(_NONRECURSIVE_SUFFIX) + length(sep))
            return (String(isempty(trimmed) ? sep : trimmed), false)
        end
    end
    return (entry, true)
end

"""
    _nonrecursive(path) -> String

Render `path` as a non-recursive target entry.
"""
_nonrecursive(path::String) = rstrip(path, only(_PATH_SEP)) * _PATH_SEP * _NONRECURSIVE_SUFFIX

"""
    _is_ignored_relpath(rel) -> Bool

True when a project-relative path lies under a hidden or well-known build/vendor
directory, or is itself a generated artifact.
"""
function _is_ignored_relpath(rel::String, exclude_set::Set{String}=IGNORED_DIRS)
    parts = splitpath(rel)
    for d in parts[1:max(0, length(parts) - 1)]
        (startswith(d, ".") || d in exclude_set) && return true
    end
    return _is_generated_file(last(parts))
end

"""
    _is_generated_file(filename) -> Bool

True for compiled/minified artifacts identifiable by name alone.
"""
_is_generated_file(filename::String) =
    any(sfx -> endswith(lowercase(filename), sfx), GENERATED_FILE_SUFFIXES)

"""
    _is_indexable_file(path) -> Bool

Reject generated content that name-based rules miss. A minified bundle is the case
that matters: it can be megabytes on a single line, which is worthless in a semantic
index and expensive to embed. Real source almost never trips either ceiling.
"""
function _is_indexable_file(path::String)
    st = try
        stat(path)
    catch
        return false
    end
    (isfile(st) && st.size > 0) || return false
    st.size > MAX_INDEX_FILE_BYTES && return false
    # A file no bigger than the line ceiling cannot contain an over-long line, so skip
    # the read entirely — this is the overwhelming majority of source files, and the
    # stale-file count re-runs this scan on a timer.
    st.size <= MAX_INDEX_LINE_BYTES && return true
    # Larger file: sniff the head for an implausibly long line (minified/generated).
    try
        open(path, "r") do io
            chunk = read(io, MAX_INDEX_LINE_BYTES + 1)
            # No newline anywhere in a chunk this large ⇒ one enormous line.
            return length(chunk) <= MAX_INDEX_LINE_BYTES || any(==(UInt8('\n')), chunk)
        end
    catch
        return false
    end
end

"""
    _collapse_subsumed_dirs(dirs) -> Vector{String}

Drop directories already covered by another entry so an overlapping target list (the
project root alongside `src`, say) enumerates each file exactly once.

Only a *recursive* entry subsumes anything below it — a non-recursive root covers just
its own files, so sibling directories stay in the list.
"""
function _collapse_subsumed_dirs(dirs::Vector{String})
    parsed = map(dirs) do d
        path, rec = _parse_target(d)
        (path=abspath(path), recursive=rec)
    end
    unique!(parsed)
    # Shortest first so a parent is considered before its children; for equal paths a
    # recursive entry wins over a non-recursive one covering the same directory.
    sort!(parsed; by=t -> (length(t.path), !t.recursive))

    kept = eltype(parsed)[]
    for t in parsed
        covered = any(kept) do k
            k.recursive ? _within(t.path, k.path) : (k.path == t.path && !t.recursive)
        end
        covered && continue
        push!(kept, t)
    end
    return String[t.recursive ? t.path : _nonrecursive(t.path) for t in kept]
end

"""
    resolve_index_config(project_path; extensions=nothing, extra_dirs=String[]) -> NamedTuple

Resolve the indexing targets for a project:
`(dirs, extensions, exclude_dirs, origin, missing_dirs)`.

Priority: explicit `extensions` argument → the project's registered config
(`~/.config/kaimon/search.json`) → the index-state cache → git-aware auto-detection.
`origin` reports which of those supplied the directories (`:config`, `:cache`, or
`:auto`), for logging and for the TUI to explain what it is about to scan.

Directories come back absolute and de-overlapped; `extra_dirs` are appended.
`missing_dirs` holds configured targets that don't exist on disk, so a caller can
report the typo instead of quietly indexing less than the user asked for.
"""
function resolve_index_config(project_path::String;
                              extensions::Union{Vector{String},Nothing}=nothing,
                              extra_dirs::Vector{String}=String[])
    root = abspath(project_path)

    # Config round-trips through JSON, so these arrive as Vector{Any} (and broadcasting
    # `String` over an empty one does not narrow) — convert explicitly.
    _as_strings(v) = String[String(x) for x in v]

    # load_index_state already implements search-config → cache → defaults for
    # dirs/extensions; exclude_dirs only ever lives in the registered config.
    state_cfg = load_index_state(root)["config"]
    dirs = _as_strings(get(state_cfg, "dirs", String[]))
    exts = _as_strings(get(state_cfg, "extensions", DEFAULT_INDEX_EXTENSIONS))

    reg = get_project_config(root)
    exclude_dirs = reg === nothing ? String[] : _as_strings(get(reg, "exclude_dirs", String[]))
    configured_dirs = reg !== nothing && !isempty(get(reg, "dirs", String[]))
    origin = isempty(dirs) ? :auto : (configured_dirs ? :config : :cache)

    if isempty(dirs)
        detected = auto_detect_project_config(root)
        dirs = detected.dirs
        # A project with no stored config also has no considered extension choice —
        # prefer what detection actually found over the generic default, so a Python
        # or Rust project isn't scanned for Julia files and left empty.
        exts == DEFAULT_INDEX_EXTENSIONS && (exts = detected.extensions)
    end

    extensions !== nothing && (exts = extensions)

    for d in extra_dirs
        push!(dirs, isabspath(d) ? d : joinpath(root, d))
    end

    # A configured directory that doesn't exist is a typo worth surfacing, not
    # something to drop in silence. Existence is checked against the parsed path so a
    # non-recursive `dir/*` entry isn't mistaken for a missing directory.
    resolved = _collapse_subsumed_dirs(dirs)
    _exists(entry) = isdir(first(_parse_target(entry)))
    existing = filter(_exists, resolved)
    missing_dirs = filter(!_exists, resolved)

    return (dirs=existing, extensions=_as_strings(exts), exclude_dirs=exclude_dirs,
            origin=origin, missing_dirs=missing_dirs)
end

"""
    collect_index_files(project_path; dirs, extensions, exclude_dirs) -> Vector{String}

Enumerate the files that make up a project's index. Single source of truth: the indexer
and the stale-file counter both call this, so what the TUI reports and what indexing
visits are the same set by construction.

In a git repository the candidate list comes from git, so `.gitignore` is honoured and
the indexer sees the same universe as `grep_code`/`search_code` — which is also what
keeps generated output (`dist/`, `.next/`, bundles) out of the index in practice.
Non-git projects fall back to a directory walk. Either way, hidden and well-known
build/vendor directories are skipped and generated artifacts are rejected.
"""
function collect_index_files(project_path::String;
                             dirs::Vector{String},
                             extensions::Vector{String}=DEFAULT_INDEX_EXTENSIONS,
                             exclude_dirs::Vector{String}=String[])
    root = abspath(project_path)
    targets = map(_parse_target, _collapse_subsumed_dirs(dirs))
    isempty(targets) && return String[]

    exclude_set = union(IGNORED_DIRS, Set(exclude_dirs))
    lc_extensions = lowercase.(extensions)
    matches_ext(f) = (lf = lowercase(f); any(ext -> endswith(lf, ext), lc_extensions))
    # A recursive target claims its whole subtree; a non-recursive one only files
    # sitting directly in it.
    in_scope(full) = any(targets) do (path, recursive)
        recursive ? _within(full, path) : dirname(full) == path
    end

    files = String[]
    tracked = _git_tracked_files(root)
    if tracked !== nothing && !isempty(tracked)
        for rel in tracked
            matches_ext(rel) || continue
            _is_ignored_relpath(rel, exclude_set) && continue
            # git reports `/`-separated paths on every platform; rebuild through
            # splitpath so the result uses native separators and the containment
            # test below compares like with like.
            full = joinpath(root, splitpath(rel)...)
            in_scope(full) || continue
            _is_indexable_file(full) || continue
            push!(files, full)
        end
    else
        for (dir, recursive) in targets
            isdir(dir) || continue
            onerr = e -> with_index_logger(
                () -> @warn "Skipping unreadable directory during scan" dir = dir exception = e
            )
            walker = recursive ? walkdir(dir; onerror=onerr) :
                     [(dir, String[], filter(f -> isfile(joinpath(dir, f)), readdir(dir)))]
            for (r, subdirs, filenames) in walker
                filter!(d -> !startswith(d, ".") && d ∉ exclude_set, subdirs)
                for f in filenames
                    matches_ext(f) || continue
                    _is_generated_file(f) && continue
                    full = joinpath(r, f)
                    _is_indexable_file(full) || continue
                    push!(files, full)
                end
            end
        end
    end

    return sort!(unique!(files))
end

"""
    project_index_files(project_path; extensions=nothing, extra_dirs=String[]) -> Vector{String}

Resolve a project's config and enumerate its indexable files in one step.
"""
function project_index_files(project_path::String;
                             extensions::Union{Vector{String},Nothing}=nothing,
                             extra_dirs::Vector{String}=String[])
    cfg = resolve_index_config(project_path; extensions=extensions, extra_dirs=extra_dirs)
    return collect_index_files(project_path; dirs=cfg.dirs,
                               extensions=cfg.extensions, exclude_dirs=cfg.exclude_dirs)
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
    _filter_stale(project_path, files) -> Vector{String}

Reduce an enumerated file set to those needing re-indexing. Loads the index state once
for the whole set rather than once per file.
"""
function _filter_stale(project_path::String, files::Vector{String})
    files_state = load_index_state(project_path)["files"]
    stale = String[]
    for file_path in files
        info = get(files_state, file_path, nothing)
        if info === nothing || mtime(file_path) > info["mtime"]
            push!(stale, file_path)
        end
    end
    return stale
end

"""
    get_stale_files(project_path::String) -> Vector{String}

Files across the whole project that need re-indexing. Resolves the project's indexing
config itself, so the count shown in the Collection Manager is by construction the set
`sync_index` will actually visit (#80).
"""
get_stale_files(project_path::String) =
    _filter_stale(project_path, project_index_files(project_path))

"""
    get_stale_files(project_path::String, src_dir::String) -> Vector{String}

Files needing re-indexing within a single directory of the project.
"""
function get_stale_files(project_path::String, src_dir::String;
                         extensions::Vector{String}=DEFAULT_INDEX_EXTENSIONS,
                         exclude_dirs::Vector{String}=String[])
    isdir(src_dir) || return String[]
    files = collect_index_files(project_path; dirs=[src_dir],
                                extensions=extensions, exclude_dirs=exclude_dirs)
    return _filter_stale(project_path, files)
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


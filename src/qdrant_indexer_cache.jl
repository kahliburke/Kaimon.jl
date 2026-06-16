# ─────────────────────────────────────────────────────────────────────────────
# Kaimon Qdrant indexer · index cache · project registry · project config  (split from qdrant_indexer.jl)
# ─────────────────────────────────────────────────────────────────────────────

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


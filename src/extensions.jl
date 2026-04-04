# ── Extension Config ──────────────────────────────────────────────────────────
# Extension system configuration: parsing kaimon.toml manifests and the global
# extensions.json registry.

"""
    ExtensionManifest

Parsed from `kaimon.toml` in the extension project root.
Declares how Kaimon should load and namespace the extension's tools.
"""
struct ExtensionManifest
    namespace::String           # dot-namespace prefix (e.g. "smlabnotes")
    module_name::String         # Julia module to `using` (e.g. "SMLabNotes")
    tools_function::String      # exported function returning Vector{GateTool}
    description::String         # human-readable description (from kaimon.toml, optional)
    shutdown_function::String   # optional cleanup function called before process exit
    event_topics::Vector{String}  # stream channels to forward (e.g. ["breakpoint_hit"])
    tui_file::String            # optional path to TUI panel file (relative to project root)
    julia_flags::Vector{String} # optional Julia startup flags (e.g. ["-t4,1", "--heap-size-hint=1G"])
end

"""
    ExtensionEntry

A single entry from the global `~/.config/kaimon/extensions.json` registry.
"""
struct ExtensionEntry
    project_path::String    # absolute path to the Julia project root
    enabled::Bool
    auto_start::Bool
end

"""
    ExtensionConfig

Combined config: the registry entry + parsed manifest.
"""
struct ExtensionConfig
    entry::ExtensionEntry
    manifest::ExtensionManifest
end

# ── Config paths ─────────────────────────────────────────────────────────────

"""
    get_extensions_config_path() -> String

Path to the global extensions registry: `~/.config/kaimon/extensions.json`.
"""
function get_extensions_config_path()
    return joinpath(kaimon_config_dir(), "extensions.json")
end

# ── kaimon.toml parsing ──────────────────────────────────────────────────────

"""
    parse_extension_manifest(project_path::String) -> ExtensionManifest

Parse `kaimon.toml` from the project root. Throws on missing/invalid files.
"""
function parse_extension_manifest(project_path::AbstractString)
    toml_path = joinpath(project_path, "kaimon.toml")
    isfile(toml_path) || error("No kaimon.toml found at $toml_path")
    data = TOML.parsefile(toml_path)
    ext = get(data, "extension", nothing)
    ext === nothing && error("kaimon.toml missing [extension] section at $toml_path")

    namespace = get(ext, "namespace", nothing)
    namespace === nothing && error("kaimon.toml missing extension.namespace at $toml_path")
    module_name = get(ext, "module", nothing)
    module_name === nothing && error("kaimon.toml missing extension.module at $toml_path")
    tools_function = get(ext, "tools_function", nothing)
    tools_function === nothing &&
        error("kaimon.toml missing extension.tools_function at $toml_path")

    description = String(get(ext, "description", ""))
    shutdown_function = String(get(ext, "shutdown_function", ""))
    event_topics = String[String(t) for t in get(ext, "event_topics", String[])]
    tui_file = String(get(ext, "tui_file", ""))
    raw_flags = get(ext, "julia_flags", String[])
    julia_flags = if raw_flags isa AbstractString
        String.(split(raw_flags))
    else
        String[String(f) for f in raw_flags]
    end

    return ExtensionManifest(
        String(namespace),
        String(module_name),
        String(tools_function),
        description,
        shutdown_function,
        event_topics,
        tui_file,
        julia_flags,
    )
end

# ── extensions.json loading/saving ───────────────────────────────────────────

"""
    load_extensions_config() -> Vector{ExtensionEntry}

Load the global extensions registry. Returns empty vector if file doesn't exist.
"""
function load_extensions_config()
    path = get_extensions_config_path()
    isfile(path) || return ExtensionEntry[]
    try
        data = JSON.parsefile(path)
        entries = get(data, "extensions", [])
        return [
            ExtensionEntry(
                expanduser(String(get(e, "project_path", ""))),
                Bool(get(e, "enabled", true)),
                Bool(get(e, "auto_start", true)),
            ) for e in entries
        ]
    catch e
        @warn "Failed to load extensions config" exception = e
        return ExtensionEntry[]
    end
end

"""
    save_extensions_config(entries::Vector{ExtensionEntry})

Write the global extensions registry to disk.
"""
function save_extensions_config(entries::Vector{ExtensionEntry})
    path = get_extensions_config_path()
    mkpath(dirname(path))
    data = Dict(
        "extensions" => [
            Dict(
                "project_path" => e.project_path,
                "enabled" => e.enabled,
                "auto_start" => e.auto_start,
            ) for e in entries
        ],
    )
    open(path, "w") do io
        JSON.print(io, data, 2)
        println(io)
    end
end

"""
    load_extension_configs() -> Vector{ExtensionConfig}

Load registry entries and resolve each against its `kaimon.toml`.
Skips entries with missing/invalid manifests (logs warnings).
"""
function load_extension_configs()
    entries = load_extensions_config()
    configs = ExtensionConfig[]
    for entry in entries
        try
            manifest = parse_extension_manifest(entry.project_path)
            push!(configs, ExtensionConfig(entry, manifest))
        catch e
            @warn "Skipping extension at $(entry.project_path)" exception = e
        end
    end
    return configs
end

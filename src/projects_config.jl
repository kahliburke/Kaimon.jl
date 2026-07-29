# ── Projects Config ───────────────────────────────────────────────────────────
# Manages the list of Julia projects that agents are allowed to spawn sessions
# for. Follows the same load/save JSON pattern as extensions.jl.

"""
    LaunchConfig

Per-project Julia launch flags for agent-spawned sessions.
Empty strings use defaults (threads="auto", others omitted).

`sysimage` and `julia_bin` let a project boot the same way its author does by hand — a
custom system image built against that project's deps, and/or a specific Julia binary
(or a wrapper script that `exec`s one). `startup_file` opts back into `~/.julia/config/startup.jl`,
which is suppressed by default so a spawned session boots predictably.
"""
struct LaunchConfig
    threads::String           # "-t" value: "auto", "4", "2,1", etc. Empty = "auto"
    gcthreads::String         # "--gcthreads" value: "2", "2,1", etc. Empty = omit flag
    heap_size_hint::String    # "--heap-size-hint" value: "4G", "512M", etc. Empty = omit
    extra_flags::Vector{String}  # arbitrary additional Julia flags
    sysimage::String          # "-J" value; relative paths resolve against the project root
    julia_bin::String         # Julia binary/launcher. Empty = the Julia running Kaimon
    startup_file::Bool        # true = --startup-file=yes. Default false
end

LaunchConfig() = LaunchConfig("", "", "", String[], "", "", false)

# Positional constructor for the pre-sysimage field set, so existing callers/tests
# (and any config written by an older Kaimon) keep working.
LaunchConfig(threads, gcthreads, heap_size_hint, extra_flags) =
    LaunchConfig(threads, gcthreads, heap_size_hint, extra_flags, "", "", false)

"""
    ProjectEntry

A Julia project path that agents are allowed (or disallowed) to spawn sessions for.
"""
struct ProjectEntry
    project_path::String
    enabled::Bool
    launch_config::LaunchConfig
end

ProjectEntry(project_path::String, enabled::Bool) = ProjectEntry(project_path, enabled, LaunchConfig())

"""
    get_projects_config_path() -> String

Return the path to the projects config file (`~/.config/kaimon/projects.json`).
"""
function get_projects_config_path()
    return joinpath(kaimon_config_dir(), "projects.json")
end

"""
    load_projects_config() -> Vector{ProjectEntry}

Load the global projects registry. Returns empty vector if file doesn't exist.
"""
function load_projects_config()
    path = get_projects_config_path()
    isfile(path) || return ProjectEntry[]
    try
        data = JSON.parsefile(path)
        entries = get(data, "projects", [])
        return [
            ProjectEntry(
                expanduser(String(get(e, "project_path", ""))),
                Bool(get(e, "enabled", true)),
                _parse_launch_config(get(e, "launch_config", nothing)),
            ) for e in entries
        ]
    catch e
        @warn "Failed to load projects config" exception = e
        return ProjectEntry[]
    end
end

"""
    save_projects_config(entries::Vector{ProjectEntry})

Write the global projects registry to disk.
"""
function save_projects_config(entries::Vector{ProjectEntry})
    path = get_projects_config_path()
    mkpath(dirname(path))
    # Preserve other top-level keys (e.g. session_prefs)
    data = if isfile(path)
        try
            JSON.parsefile(path)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    data["projects"] = [_project_entry_to_dict(e) for e in entries]
    open(path, "w") do io
        JSON.print(io, data, 2)
        println(io)
    end
end

"""Parse a launch_config dict from JSON into a LaunchConfig struct."""
function _parse_launch_config(raw)::LaunchConfig
    raw === nothing && return LaunchConfig()
    # AbstractDict, not Dict: JSON.jl hands back a `JSON.Object`, and TOML a plain Dict —
    # a `isa Dict` guard silently discards every launch config parsed from projects.json.
    raw isa AbstractDict || return LaunchConfig()
    LaunchConfig(
        String(get(raw, "threads", "")),
        String(get(raw, "gcthreads", "")),
        String(get(raw, "heap_size_hint", "")),
        String[String(f) for f in get(raw, "extra_flags", [])],
        String(get(raw, "sysimage", "")),
        String(get(raw, "julia_bin", "")),
        Bool(get(raw, "startup_file", false)),
    )
end

"""Serialize a ProjectEntry to a Dict, only including non-default launch_config fields."""
function _project_entry_to_dict(e::ProjectEntry)
    d = Dict{String,Any}(
        "project_path" => e.project_path,
        "enabled" => e.enabled,
    )
    lc = e.launch_config
    lcd = Dict{String,Any}()
    !isempty(lc.threads) && (lcd["threads"] = lc.threads)
    !isempty(lc.gcthreads) && (lcd["gcthreads"] = lc.gcthreads)
    !isempty(lc.heap_size_hint) && (lcd["heap_size_hint"] = lc.heap_size_hint)
    !isempty(lc.extra_flags) && (lcd["extra_flags"] = lc.extra_flags)
    !isempty(lc.sysimage) && (lcd["sysimage"] = lc.sysimage)
    !isempty(lc.julia_bin) && (lcd["julia_bin"] = lc.julia_bin)
    lc.startup_file && (lcd["startup_file"] = true)
    !isempty(lcd) && (d["launch_config"] = lcd)
    return d
end

"""
    launch_config_summary(lc::LaunchConfig) -> String

Return a compact summary of non-default launch config settings.
"""
function launch_config_summary(lc::LaunchConfig)
    parts = String[]
    !isempty(lc.julia_bin) && push!(parts, basename(lc.julia_bin))
    !isempty(lc.sysimage) && push!(parts, "-J $(basename(lc.sysimage))")
    !isempty(lc.threads) && push!(parts, "-t $(lc.threads)")
    !isempty(lc.gcthreads) && push!(parts, "--gcthreads=$(lc.gcthreads)")
    !isempty(lc.heap_size_hint) && push!(parts, "--heap-size-hint=$(lc.heap_size_hint)")
    lc.startup_file && push!(parts, "--startup-file=yes")
    for f in lc.extra_flags
        push!(parts, f)
    end
    return join(parts, ", ")
end

"""
    load_toml_launch_config(project_path) -> Union{LaunchConfig,Nothing}

Read the `[launch]` section of the project's own `kaimon.toml`, or `nothing` when the
file/section is absent. This is the checked-in, shareable half of the launch config: a
project that ships a sysimage build script can declare the resulting image here and every
collaborator's Kaimon picks it up with no local setup.

```toml
[launch]
sysimage = "my-image.so"   # relative → resolved against the project root
threads = "auto"
startup_file = true
```
"""
function load_toml_launch_config(project_path::AbstractString)
    path = joinpath(String(project_path), "kaimon.toml")
    isfile(path) || return nothing
    raw = try
        get(TOML.parsefile(path), "launch", nothing)
    catch e
        @warn "Failed to parse [launch] from $path" exception = e
        return nothing
    end
    raw isa AbstractDict || return nothing
    return _parse_launch_config(raw)
end

"""
    merge_launch_config(base::LaunchConfig, override::LaunchConfig) -> LaunchConfig

Field-wise overlay: every field the user set in `override` wins, anything left at its
default falls through to `base`. Used to layer the user's `projects.json` entry over the
project's checked-in `kaimon.toml [launch]` defaults.
"""
function merge_launch_config(base::LaunchConfig, override::LaunchConfig)
    pick(o, b) = isempty(o) ? b : o
    LaunchConfig(
        pick(override.threads, base.threads),
        pick(override.gcthreads, base.gcthreads),
        pick(override.heap_size_hint, base.heap_size_hint),
        pick(override.extra_flags, base.extra_flags),
        pick(override.sysimage, base.sysimage),
        pick(override.julia_bin, base.julia_bin),
        override.startup_file || base.startup_file,
    )
end

"""
    is_project_allowed(path::String) -> Bool

Check whether a project path is in the allowed list and enabled.
Normalizes with `realpath()` before comparing.
"""
# ── Session Preferences ───────────────────────────────────────────────────────
# Per-session overrides for gate preferences (mirror_repl, allow_restart).
# Stored in `session_prefs` dict within projects.json.

"""
    SessionPrefs

Per-session gate preference overrides. `nothing` fields inherit from the global default.
"""
struct SessionPrefs
    mirror_repl::Union{Bool,Nothing}
    allow_restart::Union{Bool,Nothing}
end

SessionPrefs(; mirror_repl=nothing, allow_restart=nothing) = SessionPrefs(mirror_repl, allow_restart)

"""
    load_session_prefs() -> Dict{String,SessionPrefs}

Load per-session preference overrides from `session_prefs` in projects.json.
Returns an empty dict if the file or key doesn't exist.
"""
function load_session_prefs()
    path = get_projects_config_path()
    isfile(path) || return Dict{String,SessionPrefs}()
    try
        data = JSON.parsefile(path)
        raw = get(data, "session_prefs", nothing)
        raw === nothing && return Dict{String,SessionPrefs}()
        result = Dict{String,SessionPrefs}()
        for (pattern, prefs_dict) in raw
            prefs_dict isa AbstractDict || continue   # JSON.jl yields a JSON.Object, not a Dict
            mr = get(prefs_dict, "mirror_repl", nothing)
            ar = get(prefs_dict, "allow_restart", nothing)
            result[string(pattern)] = SessionPrefs(
                mr isa Bool ? mr : nothing,
                ar isa Bool ? ar : nothing,
            )
        end
        return result
    catch e
        @warn "Failed to load session prefs" exception = e
        return Dict{String,SessionPrefs}()
    end
end

"""
    save_session_prefs(prefs::Dict{String,SessionPrefs})

Write per-session preference overrides back to projects.json, preserving
the existing `projects` array and any other top-level keys.
"""
function save_session_prefs(prefs::Dict{String,SessionPrefs})
    path = get_projects_config_path()
    mkpath(dirname(path))
    data = if isfile(path)
        try
            JSON.parsefile(path)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    sp = Dict{String,Any}()
    for (pattern, p) in prefs
        d = Dict{String,Any}()
        p.mirror_repl !== nothing && (d["mirror_repl"] = p.mirror_repl)
        p.allow_restart !== nothing && (d["allow_restart"] = p.allow_restart)
        isempty(d) || (sp[pattern] = d)
    end
    data["session_prefs"] = sp
    open(path, "w") do io
        JSON.print(io, data, 2)
        println(io)
    end
end

"""
    resolve_session_pref(prefs, project_path, key::Symbol) -> Union{Bool,Nothing}

Match `project_path` against session pref patterns in priority order:
1. Full path match (pattern contains `/`)
2. Name match (case-insensitive basename comparison)
3. Wildcard `*` fallback

Returns the preference value for `key`, or `nothing` if no match.
"""
function resolve_session_pref(prefs::Dict{String,SessionPrefs}, project_path::String, key::Symbol)
    norm_path = normalize_path(project_path)
    bname = basename(norm_path)

    # Priority 1: full path match
    for (pattern, sp) in prefs
        !contains(pattern, '/') && continue
        pattern_norm = normalize_path(pattern)
        if pattern_norm == norm_path
            val = getfield(sp, key)
            val !== nothing && return val
        end
    end

    # Priority 2: name match (case-insensitive)
    for (pattern, sp) in prefs
        contains(pattern, '/') && continue
        pattern == "*" && continue
        if lowercase(pattern) == lowercase(bname)
            val = getfield(sp, key)
            val !== nothing && return val
        end
    end

    # Priority 3: wildcard
    if haskey(prefs, "*")
        val = getfield(prefs["*"], key)
        val !== nothing && return val
    end

    return nothing  # no match → caller uses global default
end

# ── Project Allow-List ────────────────────────────────────────────────────────

"""
    projects_allow_any() -> Bool

Whether the project allow-list is disabled via the top-level `allow_any_project`
flag in projects.json. Intended for isolated, per-session environments (e.g. a
container/VM that is itself the security boundary), where maintaining an explicit
allow-list each session is pointless friction. Defaults to `false`. (#46)
"""
function projects_allow_any()::Bool
    path = get_projects_config_path()
    isfile(path) || return false
    try
        data = JSON.parsefile(path)
        return Bool(get(data, "allow_any_project", false))
    catch
        return false
    end
end

function is_project_allowed(path::String)
    # An explicit opt-in disables the allow-list entirely (container workflows).
    projects_allow_any() && return true
    entries = load_projects_config()
    norm_path = normalize_path(path)
    for entry in entries
        entry.enabled || continue
        entry_norm = normalize_path(entry.project_path)
        entry_norm == norm_path && return true
    end
    return false
end

"""
    allow_project!(path::String) -> Bool

Add `path` to the projects allow-list (enabled) and persist, re-enabling a
disabled entry if one exists. Used to remember an interactive "allow always"
consent so the user isn't asked again. Returns `true` if the registry changed,
`false` if the project was already allowed.
"""
function allow_project!(path::String)
    norm = normalize_path(path)
    entries = load_projects_config()
    idx = findfirst(e -> normalize_path(e.project_path) == norm, entries)
    if idx === nothing
        push!(entries, ProjectEntry(norm, true))
    elseif entries[idx].enabled
        return false
    else
        old = entries[idx]
        entries[idx] = ProjectEntry(old.project_path, true, old.launch_config)
    end
    save_projects_config(entries)
    return true
end

# ── Grep path allow-list ─────────────────────────────────────────────────────
# grep_code is confined to the bound project + the caller's declared workspace
# roots. Reading anywhere else needs an explicit, persisted opt-in (granted via the
# elicitation "always" consent, or hand-edited), stored as a flat list of absolute
# directories under `grep_paths` in projects.json. This is a per-path whitelist,
# NOT a blanket switch, and it is deliberately separate from the project allow-list
# (approving a project for a session does not make it grep-readable).

"""
    grep_allowed_paths() -> Vector{String}

The persisted list of extra directories `grep_code` may read (`grep_paths` in
projects.json), normalized. Empty when unset.
"""
function grep_allowed_paths()::Vector{String}
    path = get_projects_config_path()
    isfile(path) || return String[]
    try
        raw = get(JSON.parsefile(path), "grep_paths", nothing)
        raw isa AbstractVector || return String[]
        out = String[]
        for p in raw
            (p isa AbstractString && !isempty(p)) && push!(out, normalize_path(String(p)))
        end
        return out
    catch
        return String[]
    end
end

"""
    allow_grep_path!(path::AbstractString) -> Bool

Add `path` to the grep allow-list (`grep_paths` in projects.json) and persist,
preserving all other config keys (read-then-merge). Used to remember an interactive
"always allow" consent. Returns `true` if the list changed, `false` if already present.
"""
function allow_grep_path!(path::AbstractString)::Bool
    norm = normalize_path(String(path))
    isempty(norm) && return false
    cfg = get_projects_config_path()
    mkpath(dirname(cfg))
    data =
        isfile(cfg) ? (try; JSON.parsefile(cfg); catch; Dict{String,Any}(); end) :
        Dict{String,Any}()
    raw = get(data, "grep_paths", nothing)
    list = String[]
    raw isa AbstractVector && for p in raw
        p isa AbstractString && push!(list, String(p))
    end
    any(p -> normalize_path(p) == norm, list) && return false
    push!(list, norm)
    data["grep_paths"] = list
    open(cfg, "w") do io
        JSON.print(io, data, 2)
        println(io)
    end
    return true
end

# ── TCP Gates Registry ───────────────────────────────────────────────────────
# Persistent list of TCP gate endpoints that Kaimon polls for connections.

struct TCPGateEntry
    host::String
    port::Int
    name::String      # display name
    enabled::Bool
    token::String     # auth token (empty = use env/config fallback)
    stream_port::Int  # PUB socket port override for tunneling (0 = discover from pong)
    server_key::String # CURVE server public key to pin (empty = plain TCP)
end
# Back-compat: callers that predate CURVE omit server_key.
TCPGateEntry(host, port, name, enabled, token, stream_port) =
    TCPGateEntry(host, port, name, enabled, token, stream_port, "")

function get_tcp_gates_config_path()
    joinpath(kaimon_config_dir(), "tcp_gates.json")
end

function load_tcp_gates_config()::Vector{TCPGateEntry}
    path = get_tcp_gates_config_path()
    isfile(path) || return TCPGateEntry[]
    try
        data = JSON.parsefile(path)
        gates = get(data, "tcp_gates", [])
        return [
            TCPGateEntry(
                String(get(g, "host", "")),
                Int(get(g, "port", 9876)),
                String(get(g, "name", "")),
                Bool(get(g, "enabled", true)),
                String(get(g, "token", "")),
                Int(get(g, "stream_port", 0)),
                String(get(g, "server_key", "")),
            ) for g in gates
        ]
    catch e
        @warn "Failed to load TCP gates config" exception = e
        return TCPGateEntry[]
    end
end

function save_tcp_gates_config(entries::Vector{TCPGateEntry})
    path = get_tcp_gates_config_path()
    mkpath(dirname(path))
    data = Dict{String,Any}(
        "tcp_gates" => [
            Dict{String,Any}(
                "host" => e.host,
                "port" => e.port,
                "name" => e.name,
                "enabled" => e.enabled,
                "token" => e.token,
                "stream_port" => e.stream_port,
                "server_key" => e.server_key,
            ) for e in entries
        ],
    )
    open(path, "w") do io
        JSON.print(io, data, 2)
        println(io)
    end
end

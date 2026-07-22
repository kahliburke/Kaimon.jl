# ─────────────────────────────────────────────────────────────────────────────
# Kaimon · setup: version_info, gate-global install, @mcp_tool macro  (relocated from Kaimon.jl; part of the Kaimon module)
# ─────────────────────────────────────────────────────────────────────────────


# Export public API functions
# Public API — accessible as Kaimon.foo() but not imported by `using Kaimon`
public start!, stop!, test_server
public setup_security, security_status, generate_key, revoke_key
public allow_ip, deny_ip, set_security_mode
public call_tool, list_tools, tool_help
public tui
public setup_wizard_tui
public get_gate_mirror_repl_preference, set_gate_mirror_repl_preference!
public get_gate_promote_after_preference, set_gate_promote_after_preference!

# ============================================================================
# Port Management
# ============================================================================

"""
    find_free_port(start_port::Int=40000, end_port::Int=49999) -> Int

Find an available port in the specified range by attempting to bind to each port.

# Arguments
- `start_port::Int=40000`: Start of port range to search (default: 40000-49999 for dynamic ports)
- `end_port::Int=49999`: End of port range to search

# Returns
- `Int`: First available port in the range

# Throws
- `ErrorException`: If no free port is found in the range

# Examples
```julia
# Find port in default range (40000-49999)
port = find_free_port()

# Find port in custom range
port = find_free_port(4000, 4999)
```
"""
function find_free_port(start_port::Int = 40000, end_port::Int = 49999)
    last_error = nothing
    ports_tried = 0

    for port = start_port:end_port
        ports_tried += 1
        try
            # Try to bind to the port - if successful, it's available
            server = Sockets.listen(Sockets.InetAddr(parse(IPAddr, "127.0.0.1"), port))
            close(server)
            @info "Found free port" port = port ports_tried = ports_tried
            return port
        catch e
            # Port is in use or binding failed, try next one
            last_error = e
            if ports_tried <= 5 || ports_tried == end_port - start_port + 1
                @debug "Port unavailable" port = port exception = e
            end
            continue
        end
    end

    # Provide detailed error message
    error_msg = "No free ports available in range $start_port-$end_port"
    if last_error !== nothing
        error_msg *= ". Last error: $(sprint(showerror, last_error))"
    end
    error(error_msg)
end

"""Semver version string from Project.toml (e.g. "1.2.2"). Cached at load time."""
const PACKAGE_VERSION = let
    pf = joinpath(pkgdir(@__MODULE__), "Project.toml")
    isfile(pf) ? get(TOML.parsefile(pf), "version", "0.0.0") : "0.0.0"
end

# Version tracking - gets git commit hash at runtime
function version_info()
    try
        pkg_dir = pkgdir(@__MODULE__)
        git_dir = joinpath(pkg_dir, ".git")

        # Check if it's a git repo first (dev package)
        if isdir(git_dir)
            try
                commit = readchomp(`git -C $(pkg_dir) rev-parse --short HEAD`)
                dirty = success(`git -C $(pkg_dir) diff --quiet`) ? "" : "-dirty"
                return "$(commit)$(dirty)"
            catch git_error
                @warn "Failed to get git version" exception = git_error
                # Fall through to read from Project.toml
            end
        end

        # Read version from Project.toml
        project_file = joinpath(pkg_dir, "Project.toml")
        if isfile(project_file)
            project = TOML.parsefile(project_file)
            if haskey(project, "version")
                return "v$(project["version"])"
            end
        end

        return "unknown"
    catch e
        @warn "Failed to get version info" exception = e
        return "unknown"
    end
end

"""
    connect!()

Connect this Julia session to a running Kaimon TUI. Loads Revise (if
available) for live code reloading, then starts the gate server.

Call from any Julia REPL where Kaimon is available:

    using Kaimon
    Kaimon.connect!()
"""
function connect!()
    try
        Base.require(Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise"))
        @info "Revise loaded"
    catch
        @info "Revise not available (optional)"
    end
    @async KaimonGate.serve()
    @info "Kaimon gate started — session will appear in the TUI shortly"
    nothing
end

"""
    _install_gate_global(kaimongate_dir; remove_kaimon=false)

Install KaimonGate into the user's global Julia environment so every session can
run the gate. Prefers the registry; falls back to the bundled `lib/KaimonGate`
path while KaimonGate is unregistered. Optionally removes the heavyweight Kaimon
package from the global env (the `kaimon` CLI lives in its own app environment,
so removing it here does not affect the app).
"""
function _install_gate_global(kaimongate_dir::String; remove_kaimon::Bool = false)
    env = copy(ENV)
    delete!(env, "JULIA_PROJECT")
    delete!(env, "JULIA_LOAD_PATH")
    rm_line = remove_kaimon ? "try; Pkg.rm(\"Kaimon\"); catch; end\n    " : ""
    code = """
    using Pkg
    $(rm_line)try
        Pkg.add("KaimonGate")
    catch
        Pkg.develop(path=$(repr(kaimongate_dir)))
    end
    """
    run(setenv(`$(Base.julia_cmd()) --startup-file=no -e $code`, env))
    return nothing
end

"""
Current version of the gate/session setup the CLI knows how to produce. Bump
this and add a step to `_apply_gate_setup_update!` whenever a change to how
sessions connect should be offered to existing users; the new version is then
prompted once and recorded.
"""
const GATE_SETUP_VERSION = 1

"""
    _apply_gate_setup_update!(; remove_kaimon)

Apply the current gate setup: ensure the lightweight KaimonGate is in the global
environment (optionally removing a legacy full-Kaimon install) and install or
migrate the startup.jl auto-connect snippet.
"""
function _apply_gate_setup_update!(; remove_kaimon::Bool)
    kaimongate_dir = joinpath(dirname(@__DIR__), "lib", "KaimonGate")
    _install_gate_global(kaimongate_dir; remove_kaimon = remove_kaimon)
    _write_gate_startup!()
    return nothing
end

"""
    _apply_wizard_gate_choice!(choice::Symbol)

Apply the gate auto-connect decision made in the first-run wizard (`:yes` /
`:no` / `:never`). Called after the wizard's TUI has closed, so the (slow) Pkg
install and its console output happen in the normal terminal.
"""
function _apply_wizard_gate_choice!(choice::Symbol)
    if choice === :yes
        println("\nSetting up auto-connect (installing KaimonGate, updating startup.jl)…")
        try
            _apply_gate_setup_update!(; remove_kaimon = false)
            _set_gate_setup_version(GATE_SETUP_VERSION)
            println("Done — every Julia session will now connect to Kaimon.\n")
        catch e
            @warn "Auto-connect setup failed" exception = e
        end
    elseif choice === :never
        _set_gate_setup_version(GATE_SETUP_VERSION)
    end
    # :no — leave the version unset so it can be offered again on a later start.
    return nothing
end

"""
    _maybe_run_setup_update()

On an interactive startup, check whether the user's gate setup is behind
`GATE_SETUP_VERSION`. If so, offer a one-time opt-in update; record the applied
version so it isn't offered again. If the setup is already current (e.g. the user
configured it manually), record the version silently.
"""
function _maybe_run_setup_update()
    isa(stdin, Base.TTY) || return
    _get_gate_setup_version() >= GATE_SETUP_VERSION && return

    # Inspect the current setup to decide whether anything needs doing.
    global_env = joinpath(homedir(), ".julia", "environments",
                          "v$(VERSION.major).$(VERSION.minor)")
    global_proj = joinpath(global_env, "Project.toml")
    global_deps = isfile(global_proj) ?
        get(Pkg.TOML.parsefile(global_proj), "deps", Dict()) : Dict()
    gate_in_global = haskey(global_deps, "KaimonGate")
    kaimon_in_global = haskey(global_deps, "Kaimon")

    startup_file = joinpath(homedir(), ".julia", "config", "startup.jl")
    startup = isfile(startup_file) ? read(startup_file, String) : ""
    legacy_startup = occursin("# Kaimon Gate — auto-connect", startup) &&
        !occursin("using KaimonGate", startup)

    needs_action = !gate_in_global || kaimon_in_global || legacy_startup
    if !needs_action
        # Already on the current setup — record and move on without prompting.
        _set_gate_setup_version(GATE_SETUP_VERSION)
        return
    end

    is_migration = kaimon_in_global || legacy_startup
    if is_migration
        println("""

        A Kaimon setup update is available — it modernizes how your Julia
        sessions connect to the dashboard. Applying it will:
        """)
    else
        println("""

        Make every Julia session auto-connect to the Kaimon dashboard?
        Saying yes will:
        """)
    end
    println("  • add the lightweight KaimonGate package to your global Julia")
    println("    environment ($global_env)")
    println("  • append an auto-connect block to $startup_file")
    if kaimon_in_global
        println("  • remove the heavyweight Kaimon package from that global env")
        println("    (the `kaimon` CLI has its own app environment and is unaffected)")
    end
    println("""

    You can undo this anytime: delete the block from startup.jl and run
    `]rm KaimonGate` in your global env. Choose "never" to stop being asked.
    """)
    print(is_migration ? "Apply this update now? [Y/n/never]: " :
                         "Set this up now? [Y/n/never]: ")
    response = lowercase(strip(readline()))
    if isempty(response) || response in ("y", "yes")
        @info "Applying Kaimon setup update..."
        try
            _apply_gate_setup_update!(; remove_kaimon = kaimon_in_global)
            _set_gate_setup_version(GATE_SETUP_VERSION)
            println("\nDone — your Julia sessions are set up to connect to Kaimon.\n")
        catch e
            @warn "Setup update failed" exception = e
        end
    elseif response == "never"
        _set_gate_setup_version(GATE_SETUP_VERSION)
        println("\nGot it — won't ask again. Run `kaimon --reset-global-prompt` to re-check.\n")
    else
        # "n"/"no" (not now): leave the version so we ask again next start.
        println()
    end
end

"""Path to the user's global (shared) environment Manifest for the running Julia."""
_global_manifest_path() = joinpath(homedir(), ".julia", "environments",
                                   "v$(VERSION.major).$(VERSION.minor)", "Manifest.toml")

"""
    _global_kaimongate_version(manifest_path=<global env manifest>)
        -> Union{Nothing, @NamedTuple{version::VersionNumber, is_dev::Bool}}

Read the KaimonGate entry from an environment's `Manifest.toml`. Returns the
installed `version` plus whether it's a `dev`/path install (`is_dev`), or `nothing`
if KaimonGate isn't present or the manifest can't be read/parsed. A `path` entry
tracks the bundled source directly and so is never "stale" against the registry —
callers use `is_dev` to skip the upgrade prompt for such installs. Handles both
Manifest format 2.0 (entries nested under `deps`) and the older flat layout.
"""
function _global_kaimongate_version(manifest_path::AbstractString = _global_manifest_path())
    isfile(manifest_path) || return nothing
    parsed = try
        Pkg.TOML.parsefile(manifest_path)
    catch
        return nothing
    end
    # Format 2.0 nests package tables under "deps"; the older format lists them at
    # the top level. In both, a package maps to a vector-of-tables (one per copy).
    table = get(parsed, "deps", parsed)
    table isa AbstractDict || return nothing
    entries = get(table, "KaimonGate", nothing)
    entries === nothing && return nothing
    entry = entries isa AbstractVector ? (isempty(entries) ? nothing : first(entries)) : entries
    entry isa AbstractDict || return nothing
    vstr = get(entry, "version", nothing)
    vstr === nothing && return nothing
    v = try; VersionNumber(String(vstr)); catch; return nothing; end
    return (version = v, is_dev = haskey(entry, "path"))
end

"""
    _update_gate_global()

Run `Pkg.update("KaimonGate")` in the user's global environment via a clean
subprocess (JULIA_PROJECT/JULIA_LOAD_PATH stripped so it defaults to the shared
`@v#.#` env), so the running app's own package environment is never perturbed.
"""
function _update_gate_global()
    env = copy(ENV)
    delete!(env, "JULIA_PROJECT")
    delete!(env, "JULIA_LOAD_PATH")
    code = "using Pkg; Pkg.update(\"KaimonGate\")"
    run(setenv(`$(Base.julia_cmd()) --startup-file=no -e $code`, env))
    return nothing
end

"""
    _maybe_run_gate_upgrade()

On an interactive startup, if the user's global KaimonGate is registry-installed
and older than the version bundled with this `kaimon`, offer to update it so
auto-connecting REPL sessions pick up the latest gate fixes. No-op when KaimonGate
isn't installed globally, is a dev/path install (already tracks the source), is
already current, or the user has dismissed this target version. A declined prompt
records the target version so it isn't re-asked until a newer `kaimon` ships.
"""
function _maybe_run_gate_upgrade()
    isa(stdin, Base.TTY) || return
    bundled = try; pkgversion(KaimonGate); catch; nothing; end
    bundled === nothing && return
    info = _global_kaimongate_version()
    info === nothing && return          # not installed globally
    info.is_dev && return               # path/dev install tracks source; never stale
    info.version >= bundled && return   # already current or newer
    _get_gate_upgrade_dismissed_version() == string(bundled) && return  # already declined

    global_env = joinpath(homedir(), ".julia", "environments",
                          "v$(VERSION.major).$(VERSION.minor)")
    println("""

    Your global KaimonGate is out of date: v$(info.version) installed, v$(bundled)
    ships with this kaimon. Updating keeps the Julia REPL sessions that auto-connect
    to the dashboard in sync with the latest gate fixes. This will:
      • run the equivalent of `]update KaimonGate` in your global env
        ($global_env)
      • after it finishes, you'll need to restart any running Julia REPLs so they
        load the new gate
    """)
    print("Update KaimonGate now? [Y/n]: ")
    response = lowercase(strip(readline()))
    if isempty(response) || response in ("y", "yes")
        @info "Updating KaimonGate in your global environment…"
        try
            _update_gate_global()
            println("\nDone — restart your Julia REPL sessions to load KaimonGate v$(bundled).\n")
        catch e
            @warn "KaimonGate update failed — run `]update KaimonGate` in your global env manually" exception = e
        end
    else
        # Decline: remember this target version so we don't nag every launch. A later
        # kaimon with a higher bundled version will re-prompt.
        _set_gate_upgrade_dismissed_version(string(bundled))
        println("\nGot it — won't ask again for v$(bundled). Run `]update KaimonGate` anytime.\n")
    end
    return
end

# ============================================================================
# Tool Definition Macros
# ============================================================================

"""
    @mcp_tool id description params handler

Define an MCP tool with symbol-based identification.

# Arguments
- `id`: Symbol literal (e.g., :exec_repl) - becomes both internal ID and string name
- `description`: String describing the tool
- `params`: Parameters schema Dict
- `handler`: Function taking (args) or (args, stream_channel)

# Examples
```julia
tool = @mcp_tool :exec_repl "Execute Julia code" Dict(
    "type" => "object",
    "properties" => Dict("expression" => Dict("type" => "string")),
    "required" => ["expression"]
) (args, stream_channel=nothing) -> begin
    execute_repllike(get(args, "expression", ""); stream_channel=stream_channel)
end
```
"""
macro mcp_tool(id, description, params, handler)
    if !(id isa QuoteNode || (id isa Expr && id.head == :quote))
        error("@mcp_tool requires a symbol literal for id, got: $id")
    end

    # Extract the symbol from QuoteNode
    id_sym = id isa QuoteNode ? id.value : id.args[1]
    name_str = string(id_sym)
    # Auto-generate human-readable title: "navigate_to_file" -> "Navigate To File"
    title_str = join(titlecase.(split(name_str, "_")), " ")

    return esc(
        quote
            MCPTool(
                $(QuoteNode(id_sym)),    # :exec_repl
                $name_str,                # "exec_repl"
                $title_str,               # "Exec Repl"
                $description,
                $params,
                $handler,
            )
        end,
    )
end


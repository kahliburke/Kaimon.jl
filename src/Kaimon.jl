
module Kaimon

using REPL
using JSON
using InteractiveUtils
using Profile
using HTTP
using Random
using SHA
using Dates
using Pkg
using Sockets
using TOML
using LoggingExtras
using Serialization
using FileWatching
using Preferences
using ZMQ
import ripgrep_jll   # bundled ripgrep binary backing grep_code (system `rg` is the fallback)
import CoverageTools # run_tests coverage: the same per-line accounting LocalCoverage/Coverage.jl report
using CommonMark  # triggers Tachikoma's TachikomaMarkdownExt for markdown rendering
using Printf
using UUIDs
using Tachikoma
using Match
using KaimonGate

# The eval gate lives in the lightweight `KaimonGate` package (ZMQ + stdlib);
# Kaimon code uses `KaimonGate.*` directly. `Gate` is retained only as a
# DEPRECATED alias so the historical `Kaimon.Gate.*` API (and old
# `using Kaimon; Gate.serve()` snippets) keep working during the transition —
# it emits a deprecation warning under `--depwarn=yes`. Kaimon enriches the gate
# via host hooks installed in `__init__`.
Base.@deprecate_binding Gate KaimonGate

"""Kaimon-flavored restart preamble: respawn with the full Kaimon package."""
_gate_restart_code(serve_args::AbstractString) = """
try; using Revise; catch; end
using Kaimon
delete!(ENV, "KAIMON_RESTART_SESSION")
Kaimon.KaimonGate.serve($serve_args)
"""

# `@deprecate_binding` above already exports `Gate` (deprecated). Export the
# tool-authoring macro and type; everything else is accessible as Kaimon.foo().
export @mcp_tool, MCPTool

# ── Platform directories ──────────────────────────────────────────────────────
# The base directories every location below is built from. An empty variable counts as unset.

_env_dir(var::AbstractString, default::AbstractString) = (v = get(ENV, var, ""); isempty(v) ? default : v)

"`XDG_CACHE_HOME`, else `~/.cache`."
xdg_cache_home() = _env_dir("XDG_CACHE_HOME", joinpath(homedir(), ".cache"))

"`XDG_CONFIG_HOME`, else `~/.config`."
xdg_config_home() = _env_dir("XDG_CONFIG_HOME", joinpath(homedir(), ".config"))

"Windows' local application-data directory: `LOCALAPPDATA`, else `~/AppData/Local`."
windows_localappdata() = _env_dir("LOCALAPPDATA", joinpath(homedir(), "AppData", "Local"))

"Windows' roaming application-data directory: `APPDATA`, else `~/AppData/Roaming`."
windows_appdata() = _env_dir("APPDATA", joinpath(homedir(), "AppData", "Roaming"))

# ── Shared cache directory ────────────────────────────────────────────────────
# Single source of truth for ~/.cache/kaimon (respects XDG_CACHE_HOME).
# All operational files (logs, sockets, sessions, db, pid files) go here.

"""
    kaimon_cache_dir() -> String

Return the path to the Kaimon cache directory, creating it if needed.
Respects `XDG_CACHE_HOME` on Unix; uses `LOCALAPPDATA` on Windows.
Defaults to `~/.cache/kaimon`.
"""
function kaimon_cache_dir()
    # Append "kaimon" under XDG_CACHE_HOME rather than using it verbatim, so we
    # get our own subdir instead of scattering kaimon.db/sock/sessions.json into
    # the shared cache root. Mirrors kaimon_config_dir's (correct) handling. (#42)
    # `KAIMON_CACHE_DIR` names the directory itself (see `kaimon_config_dir`).
    explicit = get(ENV, "KAIMON_CACHE_DIR", "")
    dir = if !isempty(explicit)
        explicit
    elseif Sys.iswindows()
        joinpath(windows_localappdata(), "Kaimon")
    else
        joinpath(xdg_cache_home(), "kaimon")
    end
    mkpath(dir)
    return dir
end

# ── Shared config directory ───────────────────────────────────────────────────
# Single source of truth for ~/.config/kaimon (respects XDG_CONFIG_HOME).
# All user configuration files (projects.json, config.json, extensions.json) go here.

"""
    kaimon_config_dir() -> String

Return the path to the Kaimon config directory, creating it if needed.
Respects `XDG_CONFIG_HOME` on Unix; uses `APPDATA` on Windows.
Defaults to `~/.config/kaimon`.
"""
function kaimon_config_dir()
    # `KAIMON_CONFIG_DIR` (and `KAIMON_CACHE_DIR`) name the directories themselves, for a Kaimon
    # embedded in another service beside one the same person runs: its own config, keys, sockets,
    # sessions and logs, without changing XDG_* for everything else the process starts.
    explicit = get(ENV, "KAIMON_CONFIG_DIR", "")
    dir = if !isempty(explicit)
        explicit
    elseif Sys.iswindows()
        joinpath(windows_appdata(), "Kaimon")
    else
        joinpath(xdg_config_home(), "kaimon")
    end
    mkpath(dir)
    return dir
end

# ── Other applications' directories ───────────────────────────────────────────
# Where the clients Kaimon registers with keep their configuration. One definition each, so the
# code that writes Kaimon into a client's config and the code that reads it look in the same place.

"VS Code's user directory, holding `settings.json`, `mcp.json` and `globalStorage`."
function vscode_user_dir()
    Sys.isapple() && return joinpath(homedir(), "Library", "Application Support", "Code", "User")
    Sys.iswindows() && return joinpath(windows_appdata(), "Code", "User")
    return joinpath(xdg_config_home(), "Code", "User")
end

"opencode's configuration directory. opencode follows `XDG_CONFIG_HOME` on every platform."
opencode_config_dir() = joinpath(xdg_config_home(), "opencode")

# ── LOAD_PATH assembly ────────────────────────────────────────────────────────
# `JULIA_LOAD_PATH` is parsed like `PATH`: entries are split on the OS path-list
# separator — `;` on Windows, `:` elsewhere. A hardcoded `:` corrupts Windows (drive
# letters like `C:\…` split, and the whole string collapses to one bad entry, dropping
# `@stdlib`), so ALWAYS build it with this. (#42/#41 Windows compat.)

"""Join `JULIA_LOAD_PATH` entries with the OS path-list separator (`;` on Windows)."""
_join_load_path(entries::AbstractString...) = join(entries, Sys.iswindows() ? ";" : ":")

# ── Path normalization ────────────────────────────────────────────────────────

"""
    normalize_path(path::String) -> String

Expand `~`, resolve symlinks and `..` segments. Falls back to `expanduser` +
`normpath` when the target doesn't exist yet (e.g. a path the user is about
to create).
"""
function normalize_path(path::String)
    expanded = expanduser(path)
    try
        realpath(expanded)
    catch
        normpath(expanded)
    end
end

include("utils.jl")
include("database.jl")
include("fts_index.jl")   # lexical (SQLite/FTS5) half of hybrid code search
include("qdrant_client.jl")
include("search_services.jl") # search settings, per-account ports, private service records
include("qdrant_server.jl")   # managed Qdrant child-process launcher (opt-in via Qdrant_jll)
include("llamacpp_server.jl") # managed llama.cpp embedding server (opt-in via llama_cpp_jll)
include("tools.jl")
include("Generate.jl")
include("gate_prefs.jl")
# Gate client (TUI-side connection manager), split from the former monolithic
# gate_client.jl. Order matters: channel (RequestChannel) and types
# (REPLConnection) before the manager/discovery/request layers that use them.
include("gate_client_channel.jl")
include("gate_client_types.jl")
include("gate_client_manager.jl")
include("gate_client_discovery.jl")
include("gate_client_request.jl")
include("gate_client_debug.jl")
include("gate_client_tasks.jl")
include("gate_client_tools.jl")
include("extensions.jl")
include("extension_manager.jl")
include("projects_config.jl")
include("julia_versions.jl")   # portable [launch] julia_version → a juliaup-installed binary
include("session_manager.jl")
include("stress_test.jl")
include("test_output_parser.jl")
include("test_runner.jl")
include("tui.jl")

# Inline implementation relocated into kaimon_*.jl; the module skeleton
# (usings, includes, __init__, exports) stays here. kaimon_setup defines the
# @mcp_tool macro, so it must load before the tool_definitions_* includes below.
include("kaimon_setup.jl")
include("security.jl")
# First-run setup wizard, split from the former monolithic setup_wizard_tui.jl.
# Order follows the original (art → model/enums → update → views → companion).
include("setup_wizard_art.jl")
include("setup_wizard_model.jl")
include("setup_wizard_update.jl")
include("setup_wizard_view.jl")
include("setup_wizard_steps.jl")
include("setup_wizard_companion.jl")
include("repl_status.jl")
# MCP tool definitions, split from the former monolithic tool_definitions.jl.
# All are independent top-level `*_tool = @mcp_tool(...)` bindings (collected by
# name into the registration list below); order is immaterial, but core loads
# first as it holds the shared helpers.
include("tool_definitions_core.jl")
include("tool_definitions_editor.jl")
include("tool_definitions_introspect.jl")
include("tool_definitions_navdebug.jl")
include("tool_definitions_pkg.jl")
include("tool_definitions_jobs.jl")
include("MCPServer.jl")
include("vscode.jl")
include("reflection_tools.jl")
include("qdrant_tools.jl")
include("qdrant_hybrid.jl")   # hybrid (semantic+lexical RRF) impl behind qdrant_search_code
include("grep_code.jl")       # exact-pattern (ripgrep) search behind grep_code
include("edit_code.jl")       # scoped, validated bulk edit — grep_code's write side
include("rename_symbol.jl")   # identifier-aware rename, on the token stream not on text
include("print_strip.jl")     # removes agent print/@show/logging calls from submitted code
# Qdrant indexer, split from the former monolithic qdrant_indexer.jl. Order
# follows the original (config/consts first, then cache, discovery, chunking,
# indexing, revise hook).
include("qdrant_indexer_config.jl")
include("qdrant_indexer_cache.jl")
include("qdrant_indexer_discovery.jl")
include("qdrant_indexer_chunk.jl")
include("qdrant_indexer_index.jl")
include("qdrant_indexer_revise.jl")
include("rate_governor.jl")
include("service_endpoint.jl")
include("agent_acp_types.jl")
include("confine.jl")        # Landlock confinement of agents' processes (Linux)
include("agent_backend.jl")
include("ollama_backend.jl")
include("acp_backend.jl")
include("agent_session.jl")
include("agent_tools.jl")

include("kaimon_vscode.jl")
include("kaimon_eval.jl")
include("kaimon_gate.jl")
include("kaimon_tools.jl")
include("kaimon_lifecycle.jl")

include("precompile.jl")

function __init__()
    # Stamp the real process start for uptime reporting (the const is a
    # precompile-baked placeholder; see tui/io.jl).
    _SERVER_START_TIME[] = Dates.now()

    # The Qdrant client asks Kaimon where Qdrant is and which key it takes (search settings, then
    # the managed instance's record). Installed at runtime: a function in a precompiled Ref would
    # be baked into the image.
    QdrantClient.ENDPOINT[] = qdrant_endpoint

    # Wire Kaimon's host integrations into KaimonGate. Standalone, the gate uses
    # safe defaults; here we give it Kaimon's version, personality, REPL-mirror
    # preference, Tachikoma (for TTY hand-off on restart), and a restart preamble
    # that respawns the full Kaimon package. Must run before _auto_serve!().
    KaimonGate.set_version_provider!(() -> PACKAGE_VERSION)
    KaimonGate.set_personality_provider!(load_personality)
    KaimonGate.set_mirror_pref_provider!(get_gate_mirror_repl_preference)
    KaimonGate.set_tachikoma!(Tachikoma)
    KaimonGate.set_restart_code_builder!(_gate_restart_code)
    KaimonGate.set_auth_token_provider!() do
        config = load_global_config()
        (config.mode != :lax && !isempty(config.api_keys)) ? first(config.api_keys) : ""
    end

    # Set Qdrant collection prefix from env var or config
    env_prefix = get(ENV, "KAIMON_QDRANT_PREFIX", "")
    if !isempty(env_prefix)
        set_collection_prefix!(env_prefix)
    else
        try
            config = load_global_config()
            if config !== nothing && !isempty(config.qdrant_prefix)
                set_collection_prefix!(config.qdrant_prefix)
            end
        catch
        end
    end

    # Reap a Kaimon-managed Qdrant child (if we spawned one) when the process exits.
    atexit(shutdown_qdrant!)
    atexit(shutdown_llamacpp!)

    # Auto-start TCP gate if configured via env vars or kaimon.toml [gate]
    KaimonGate._auto_serve!()
end

end #module

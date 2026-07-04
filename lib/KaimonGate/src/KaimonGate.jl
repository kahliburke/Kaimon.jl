module KaimonGate

using ZMQ
using REPL
using Serialization
using Dates
using TOML
using Base64

"""Return `(version, dir)` for this KaimonGate build — its package version
string and on-disk source directory, so you can tell which copy is running.
Surfaced in the module docstring and the `serve()` startup banner."""
function _build_info()
    ver = try
        string(something(pkgversion(@__MODULE__), "dev"))
    catch
        "dev"
    end
    dir = try
        pkgdir(@__MODULE__)
    catch
        nothing
    end
    return (ver, dir)
end

@doc """
    KaimonGate

Thin eval gate for the Kaimon MCP server — the piece that runs *inside* the
user's Julia session. Binds a ZMQ REP socket on an IPC (or TCP) endpoint so the
persistent Kaimon TUI server can send eval requests without living inside this
process.

`KaimonGate` carries only minimal dependencies (ZMQ + stdlib), so it can be
added to any project. The full
[Kaimon.jl](https://github.com/kahliburke/Kaimon.jl) package depends on
`KaimonGate` for the gate implementation and wire protocol.

# Example
```julia
using KaimonGate
KaimonGate.serve()      # start the gate; the kaimon CLI auto-discovers it
```

See `serve`, `stop`, `restart`, `status`.

---
**This build:** v$(_build_info()[1])$(_build_info()[2] === nothing ? "" : " — `$(_build_info()[2])`")
""" KaimonGate

# ── Wire protocol version ────────────────────────────────────────────────────
"""
    KaimonGate.PROTOCOL_VERSION

Wire-protocol version reported in the gate's pong. The gate and the Kaimon
client exchange Serialization-encoded messages over ZMQ; this constant gates
wire compatibility **independently of the package version** — it is bumped only
on a wire-breaking change to the request/response or PUB/SUB message format. The
client compares this against the range it speaks rather than comparing package
versions, so a `KaimonGate` session and a `Kaimon` CLI on different releases
interoperate as long as their protocol versions match.

Version 2: the request channel moved from per-request ephemeral REQ → a single
persistent DEALER (client) multiplexed by correlation id onto a ROUTER (gate).
Framing is now `[corr_id (8-byte UInt64), payload]`; v1 REP gates are incompatible.
"""
const PROTOCOL_VERSION = 2

# ── Host-integration hooks ───────────────────────────────────────────────────
# KaimonGate runs standalone with the safe defaults below. When the full Kaimon
# package loads KaimonGate it installs richer providers via the setters, so the
# gate can report Kaimon's version, read user preferences, apply personality,
# drive Tachikoma, and respawn the right module on restart.
#
# The standalone defaults also honor `KAIMON_GATE_*` env overrides, so a host
# that spawns a *lightweight* gate (KaimonGate without Kaimon) can still convey
# its identity — REPL-mirror preference, personality, version — via the env
# instead of loading itself into the session. Explicit setters still win.

# Standalone default providers — honor KAIMON_GATE_* env overrides so a host can
# convey its identity to a lightweight gate without loading itself into it.
_default_version_provider() = begin
    v = get(ENV, "KAIMON_GATE_VERSION", "")
    isempty(v) ? string(something(pkgversion(@__MODULE__), "unknown")) : v
end
_default_mirror_pref_provider() = get(ENV, "KAIMON_GATE_MIRROR_REPL", "") == "1"

# Personality name → emoji. Mirrors Kaimon's `PERSONALITY_EMOTICONS` (security.jl)
# so a standalone gate resolves the same emoji Kaimon would, without loading Kaimon.
const _PERSONALITY_EMOTICONS = Dict("dragon" => "🐉", "butterfly" => "🦋", "l33t" => "👻")

"""Path to the shared Kaimon config (`~/.config/kaimon/config.json`), XDG/Windows-aware."""
function _kaimon_config_path()
    dir = if Sys.iswindows()
        joinpath(get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")), "Kaimon")
    else
        joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "kaimon")
    end
    return joinpath(dir, "config.json")
end

# Personality resolution for a STANDALONE gate (no Kaimon loaded). Order:
#   1. KAIMON_GATE_PERSONALITY env — the resolved emoji Kaimon injects when it
#      spawns a session (takes precedence).
#   2. The shared config's `"personality"` NAME mapped to an emoji — same source
#      and result as Kaimon's `load_personality`, but via a flat-key extraction so
#      KaimonGate keeps its no-JSON-dep footprint.
#   3. ⚡ fallback.
# When full Kaimon is loaded it overrides this via `set_personality_provider!`.
_default_personality_provider() = begin
    p = get(ENV, "KAIMON_GATE_PERSONALITY", "")
    isempty(p) || return p
    try
        path = _kaimon_config_path()
        if isfile(path)
            m = match(r"\"personality\"\s*:\s*\"([^\"]*)\"", read(path, String))
            m === nothing || return get(_PERSONALITY_EMOTICONS, m.captures[1], "⚡")
        end
    catch
    end
    return "⚡"
end

const _VERSION_PROVIDER     = Ref{Function}(_default_version_provider)
const _MIRROR_PREF_PROVIDER = Ref{Function}(_default_mirror_pref_provider)
const _PERSONALITY_PROVIDER = Ref{Function}(_default_personality_provider)
const _TACHIKOMA            = Ref{Union{Module,Nothing}}(nothing)
# TCP auth token for the gate when KAIMON_GATE_TOKEN is unset. Standalone there's
# no token (open, same as :lax); the host (Kaimon) injects a provider that derives
# one from its security config so a strict config still enforces auth.
const _AUTH_TOKEN_PROVIDER  = Ref{Function}(() -> "")

"""Default restart preamble for a standalone gate: reload KaimonGate and serve."""
default_restart_code(serve_args::AbstractString) = """
try; using Revise; catch; end
using KaimonGate
delete!(ENV, "KAIMON_RESTART_SESSION")
KaimonGate.serve($serve_args)
"""
const _RESTART_CODE_BUILDER = Ref{Function}(default_restart_code)

"""Install the host's version provider — `() -> String` reported in the pong."""
set_version_provider!(f)      = (_VERSION_PROVIDER[] = f)
"""Install the host's REPL-mirror preference provider — `() -> Bool`."""
set_mirror_pref_provider!(f)  = (_MIRROR_PREF_PROVIDER[] = f)
"""Install the host's personality/emoticon provider — `() -> String`."""
set_personality_provider!(f)  = (_PERSONALITY_PROVIDER[] = f)
"""Install the host's Tachikoma module (or `nothing` to disable TTY hand-off)."""
set_tachikoma!(m)             = (_TACHIKOMA[] = m)
"""Install the host's TCP auth-token provider — `() -> String` (`""` for no auth)."""
set_auth_token_provider!(f)   = (_AUTH_TOKEN_PROVIDER[] = f)
"""Install the host's restart-code builder — `(serve_args::String) -> code::String`."""
set_restart_code_builder!(f)  = (_RESTART_CODE_BUILDER[] = f)

# The gate server, split from the former monolithic gate.jl. Order matters:
# gate_state.jl (constants/state) must load first; the rest are functions that
# forward-reference freely. gate_curve.jl (CURVE/ZAP) loads last, as before.
include("gate_state.jl")
include("gate_debug.jl")
include("gate_tools.jl")
include("gate_eval.jl")
include("gate_stream.jl")
include("gate_protocol.jl")
include("gate_serve.jl")
include("gate_jobs.jl")
include("gate_service.jl")
include("gate_curve.jl")

"""
    connect!()

Connect this Julia session to a running Kaimon TUI. Loads Revise (if available)
for live code reloading, then starts the gate in the background. Call from any
REPL where KaimonGate is available:

    using KaimonGate
    KaimonGate.connect!()
"""
function connect!()
    try
        Base.require(Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise"))
        @info "Revise loaded"
    catch
        @info "Revise not available (optional)"
    end
    @async serve()
    @info "KaimonGate started — session will appear in the Kaimon TUI shortly"
    nothing
end

# ── Public API (mirrors the former `Kaimon.Gate.*` surface) ──────────────────
public serve, stop, restart, status, connect!
public GateTool, call_tool, list_tools, image_result, MCP_CONTENT_SENTINEL
public is_cancelled, stash, progress, push_panel, current_caller, current_agent_id
public tty_path, tty_size, uninstall_infiltrator_hook!, infiltrator_routing
public PROTOCOL_VERSION
public set_version_provider!, set_mirror_pref_provider!, set_personality_provider!
public set_tachikoma!, set_restart_code_builder!, set_auth_token_provider!
# CURVE transport (opt-in TCP encryption + auth)
public curve_keypair, curve_public, pin_server!, authorize_client!
public known_servers, unpin_server!, authorized_clients, revoke_client!
public verify_server_key_via_ssh
# Observe channel (out-of-band PUB/SUB broadcast, e.g. TachiRei tui:<id>)
public publish, subscribe
public on_stream_subscribe, on_stream_unsubscribe
public stream_subscribed, stream_subscriber_count, stream_topics

end # module KaimonGate

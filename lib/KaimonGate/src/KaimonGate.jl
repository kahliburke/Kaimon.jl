"""
    KaimonGate

Thin eval gate for the Kaimon MCP server — the piece that runs *inside* the
user's Julia session. Binds a ZMQ REP socket on an IPC (or TCP) endpoint so the
persistent Kaimon TUI server can send eval requests without living inside this
process.

`KaimonGate` carries only minimal dependencies (ZMQ + stdlib), so it can be
added to any project without dragging in Kaimon's full dependency tree. The full
[Kaimon.jl](https://github.com/kahliburke/Kaimon.jl) package depends on
`KaimonGate` for the gate implementation and wire protocol.

# Example
```julia
using KaimonGate
KaimonGate.serve()      # start the gate; the kaimon CLI auto-discovers it
```

See `serve`, `stop`, `restart`, `status`.
"""
module KaimonGate

using ZMQ
using REPL
using Serialization
using Dates
using TOML

# ── Wire protocol version ────────────────────────────────────────────────────
# The gate and the Kaimon client exchange Serialization-encoded messages over
# ZMQ. This version gates wire compatibility independently of the package
# version — bump it only on a wire-breaking change to the REQ/REP or PUB/SUB
# message format. The client compares this (reported in the pong) against the
# range it speaks, rather than comparing package versions.
const PROTOCOL_VERSION = 1

# ── Host-integration hooks ───────────────────────────────────────────────────
# KaimonGate runs standalone with the safe defaults below. When the full Kaimon
# package loads KaimonGate it installs richer providers via the setters, so the
# gate can report Kaimon's version, read user preferences, apply personality,
# drive Tachikoma, and respawn the right module on restart.

const _VERSION_PROVIDER     = Ref{Function}(() -> string(something(pkgversion(@__MODULE__), "unknown")))
const _MIRROR_PREF_PROVIDER = Ref{Function}(() -> false)
const _PERSONALITY_PROVIDER = Ref{Function}(() -> "⚡")
const _TACHIKOMA            = Ref{Union{Module,Nothing}}(nothing)

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
"""Install the host's restart-code builder — `(serve_args::String) -> code::String`."""
set_restart_code_builder!(f)  = (_RESTART_CODE_BUILDER[] = f)

include("gate.jl")

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
public GateTool, call_tool, list_tools
public is_cancelled, stash, progress, push_panel
public tty_path, tty_size, uninstall_infiltrator_hook!
public PROTOCOL_VERSION
public set_version_provider!, set_mirror_pref_provider!, set_personality_provider!
public set_tachikoma!, set_restart_code_builder!

end # module KaimonGate

# KaimonGate.jl

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

The lightweight **eval gate** for [Kaimon.jl](https://github.com/kahliburke/Kaimon.jl) —
the piece that runs *inside* your Julia session so the Kaimon MCP server can execute
code, debug, profile, and introspect it.

`KaimonGate` depends only on **ZMQ + the standard library** (REPL, Serialization, Dates,
TOML), so you can drop it into any project without dependency conflicts. Install and
precompile are fast — which matters most on remote compute nodes and shared clusters.

> The full `kaimon` CLI is installed separately as a Julia app (`]app add Kaimon`) in its
> own isolated environment. You only need `KaimonGate` in the sessions you want the CLI to
> connect to.

## Installation

```julia
pkg> add KaimonGate
```

## Usage

In the Julia session you want Kaimon to connect to:

```julia
using KaimonGate
KaimonGate.serve()      # binds a ZMQ socket; the kaimon CLI auto-discovers it
```

That's it — start the `kaimon` TUI and the session appears. `KaimonGate.connect!()`
is a convenience wrapper that loads Revise (if present) and serves in the background.
For remote/TCP sessions, SSH tunnels, and fixed ports, see the
[Kaimon documentation](https://kahliburke.github.io/Kaimon.jl).

`serve()` reads its settings from `KAIMON_GATE_*` env vars and a project's
`kaimon.toml` `[gate]` section, but standalone `KaimonGate` does **not** auto-start
from them — call `serve()` explicitly. (The full `Kaimon` install auto-starts the
gate when it loads.)

### Public API

`serve`, `stop`, `restart`, `status`, `connect!`, `GateTool`, `call_tool`,
`list_tools`, `is_cancelled`, `stash`, `progress`, `push_panel`, `tty_path`,
`tty_size`, `uninstall_infiltrator_hook!`, `PROTOCOL_VERSION`.

Embedders integrating `KaimonGate` into another host can override its defaults via
`set_version_provider!`, `set_personality_provider!`, `set_mirror_pref_provider!`,
`set_tachikoma!`, `set_auth_token_provider!`, and `set_restart_code_builder!`.

## Relationship to Kaimon.jl

`KaimonGate` is developed in the [Kaimon.jl](https://github.com/kahliburke/Kaimon.jl)
monorepo (under `lib/KaimonGate`) and owns the gate implementation and wire protocol.
The full `Kaimon` package depends on `KaimonGate` and enriches it at load time (version
reporting, personality, REPL mirroring, Tachikoma TTY hand-off, and a TCP auth token
derived from the security config). Running standalone, `KaimonGate` uses safe defaults —
notably, a TCP gate is unauthenticated unless `KAIMON_GATE_TOKEN` is set.

Wire compatibility between a gate and the Kaimon client is governed by
`KaimonGate.PROTOCOL_VERSION`, independent of package versions.

## Credits

Created by [Kahli Burke](https://github.com/kahliburke). The standalone-extraction
approach was prototyped by [Eben60](https://github.com/Eben60) (see Kaimon issue #20).

## License

MIT

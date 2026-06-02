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

That's it — start the `kaimon` TUI and the session appears. For remote/TCP sessions,
SSH tunnels, fixed ports, and auto-start via `kaimon.toml`, see the
[Kaimon documentation](https://kahliburke.github.io/Kaimon.jl).

### Public API

`serve`, `stop`, `restart`, `status`, `GateTool`, `call_tool`, `list_tools`,
`is_cancelled`, `stash`, `progress`, `push_panel`, `tty_path`, `tty_size`,
`uninstall_infiltrator_hook!`.

## Relationship to Kaimon.jl

`KaimonGate` is developed in the [Kaimon.jl](https://github.com/kahliburke/Kaimon.jl)
monorepo (under `lib/KaimonGate`) and owns the gate implementation and wire protocol.
The full `Kaimon` package depends on `KaimonGate` and enriches it at load time (version
reporting, personality, REPL mirroring, Tachikoma TTY hand-off). Running standalone,
`KaimonGate` uses safe defaults.

Wire compatibility between a gate and the Kaimon client is governed by
`KaimonGate.PROTOCOL_VERSION`, independent of package versions.

## Credits

Created by [Kahli Burke](https://github.com/kahliburke). The standalone-extraction
approach was prototyped by [Eben60](https://github.com/Eben60) (see Kaimon issue #20).

## License

MIT

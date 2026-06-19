# Installation

## Requirements

- **Julia 1.12** or later

## Install Kaimon

### Julia App (Recommended)

Use Julia's package app system to install the `kaimon` command globally:

```julia
]app add Kaimon
```

This installs a `kaimon` script to `~/.julia/bin/`. Make sure `~/.julia/bin` is on your `PATH`, then launch from anywhere:

```bash
kaimon
```

To update to a newer release later:

```julia
]app add Kaimon
```

To pin a specific version:

```julia
]app add Kaimon@1.2.2
```

### Connect a Julia session (KaimonGate)

To make one of your project's Julia sessions reachable by the `kaimon` dashboard,
you only need the lightweight **[KaimonGate](https://github.com/kahliburke/Kaimon.jl)**
package. It depends on just ZMQ and the standard library — fast to install and
free of dependency conflicts (handy on remote/compute nodes):

```julia
pkg> add KaimonGate
```

Then, in the session you want to expose:

```julia
using KaimonGate
KaimonGate.serve()
```

The session appears in the running `kaimon` TUI. This is the recommended way to
connect your own projects, whether local or remote.

### As a Library (full Kaimon)

You can also add the full `Kaimon` package as a dependency; it bundles
`KaimonGate`, so `KaimonGate.serve()` works exactly as above. (The full package
also keeps a **deprecated** `Kaimon.Gate` alias for the historical
`Kaimon.Gate.*` API — new code should use `KaimonGate`.)

```julia
using Pkg
Pkg.add("Kaimon")
```

Or to track the development branch:

```julia
Pkg.develop(url="https://github.com/kahliburke/Kaimon.jl")
```

## Optional Dependencies

### Qdrant (Semantic Search)

Kaimon can index your codebase into [Qdrant](https://qdrant.tech/) for natural language code search. If you want to use the semantic search tools (`qdrant_index_project`, `search_code`, etc.), run a local Qdrant instance:

```bash
docker run -d --name qdrant -p 6333:6333 -p 6334:6334 \
  -v qdrant_storage:/qdrant/storage \
  qdrant/qdrant
```

Qdrant is not required for core functionality. The semantic search tools will simply be unavailable if no Qdrant instance is detected.

### VS Code Remote Control

To use VS Code integration tools (`execute_vscode_command`, `navigate_to_file`, etc.), Kaimon includes a built-in VS Code extension. Install it from the TUI Config tab (press `v`), or from the Julia REPL:

```julia
using Kaimon
Kaimon.install_vscode_remote_control()
```

Reload VS Code after installation to activate. This enables AI agents to execute VS Code commands and navigate to specific file locations from the MCP interface.

## Verify Installation

Run `kaimon` from any terminal:

```bash
kaimon
```

On first launch, a setup wizard will guide you through security configuration and MCP client setup. You should see the TUI dashboard appear with session, activity, and configuration panels.

## Next Steps

- [Getting Started](getting-started.md) -- Configure your MCP client and connect to the server
- [Tool Catalog](tools.md) -- Browse all 32+ available tools
- [Security](security.md) -- Set up API keys and choose a security mode

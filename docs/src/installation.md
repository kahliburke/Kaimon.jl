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

### As a Library

To use Kaimon as a Julia package (e.g., for `Gate.serve()` in your own projects):

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

Kaimon can index your codebase into [Qdrant](https://qdrant.tech/) for natural language code search. If you want to use the semantic search tools (`qdrant_index_project`, `qdrant_search_code`, etc.), run a local Qdrant instance:

```bash
docker run -d --name qdrant -p 6333:6333 -p 6334:6334 \
  -v qdrant_storage:/qdrant/storage \
  qdrant/qdrant
```

Qdrant is not required for core functionality. The semantic search tools will simply be unavailable if no Qdrant instance is detected.

### VS Code Remote Control

To use VS Code integration tools (`execute_vscode_command`, `navigate_to_file`, etc.), install the **Remote Control** extension in VS Code:

1. Open VS Code
2. Go to Extensions (Ctrl+Shift+X / Cmd+Shift+X)
3. Search for "Remote Control" by jeandeaual
4. Install the extension

This enables AI agents to execute VS Code commands and navigate to specific file locations from the MCP interface.

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

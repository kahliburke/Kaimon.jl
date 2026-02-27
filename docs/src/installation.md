# Installation

## Requirements

- **Julia 1.12** or later

## Install Kaimon

From the Julia REPL, add the package from the General registry:

```julia
using Pkg
Pkg.add("Kaimon")
```

Alternatively, install directly from the repository for the latest development version:

```julia
using Pkg
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

### VS Code Remote Control (Debugging)

To use the VS Code debugging tools (`start_debug_session`, `open_file_and_set_breakpoint`, `debug_step_over`, etc.), install the **Remote Control** extension in VS Code:

1. Open VS Code
2. Go to Extensions (Ctrl+Shift+X / Cmd+Shift+X)
3. Search for "Remote Control" by jeandeaual
4. Install the extension

The debugging tools allow AI agents to set breakpoints, step through code, inspect variables, and control debug sessions directly from the MCP interface.

## Verify Installation

Start the server to confirm everything is working:

```julia
using Kaimon
Kaimon.start!()
```

This launches the MCP server on stdio and opens the terminal dashboard. You should see the TUI appear with session and tool call panels. Press `q` to exit the dashboard (the server continues running in the background).

## Next Steps

- [Getting Started](getting-started.md) -- Configure your MCP client and connect to the server
- [Tool Catalog](tools.md) -- Browse all 32+ available tools
- [Security](security.md) -- Set up API keys and choose a security mode

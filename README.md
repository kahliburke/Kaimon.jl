# Kaimon.jl

<p align="center">
  <img src="https://github.com/kahliburke/Kaimon.jl/releases/download/docs-assets/kaimon-logo.jpg" alt="Kaimon" width="320" />
</p>

**Opening the gate between AI and Julia.**

[![CI](https://github.com/kahliburke/Kaimon.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/kahliburke/Kaimon.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://kahliburke.github.io/Kaimon.jl/dev/)
[![Julia 1.12+](https://img.shields.io/badge/julia-1.12%2B-blue)](https://julialang.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Kaimon is an MCP (Model Context Protocol) server that gives AI agents full access to
Julia's runtime. Connect Claude Code, Cursor, or any MCP client to a live Julia session
with 32+ tools for code execution, introspection, debugging, testing, and semantic
code search.

## Key Features

- **Live Code Execution** — evaluate Julia code in persistent REPL sessions with full
  state, package access, and streaming output
- **Deep Introspection** — inspect types, methods, lowered IR, type-inferred code, and
  macro expansions directly from the agent
- **The Gate** — connect external Julia processes and register custom tools via ZMQ.
  Your app's domain logic becomes agent-callable with automatic schema generation
- **VS Code Debugging** — set breakpoints, step through code, watch variables, all
  driven by the AI agent
- **Semantic Code Search** — index projects into Qdrant and search with natural language
  queries like "function that handles HTTP routing"
- **Terminal Dashboard** — real-time TUI monitoring sessions, tool calls, test runs,
  and search results across all connected REPLs
- **Security** — three modes (strict/relaxed/lax), API key management, IP allowlists
- **Testing & Profiling** — run tests with pattern filtering and coverage, profile code,
  stress-test with concurrent simulated agents

## Quick Start

```bash
git clone https://github.com/kahliburke/Kaimon.jl
cd Kaimon.jl
./bin/kaimon
```

The first run opens a setup wizard (security mode, API key, port). After that, the terminal dashboard launches:

![Kaimon dashboard](docs/src/assets/kaimon_overview.gif)

From the dashboard:
- Press **`i`** in the Config tab to write MCP config for Claude Code, Cursor, VS Code, or Gemini CLI
- Press **`g`** to add a Gate snippet to `~/.julia/config/startup.jl` so every Julia session auto-connects
- Or connect manually from any REPL: `using Kaimon; Gate.serve()`

## Tool Categories

| Category | Tools | Description |
|----------|-------|-------------|
| Code Execution | `ex`, `manage_repl` | Evaluate code, restart/shutdown sessions |
| Introspection | `investigate_environment`, `search_methods`, `type_info`, `list_names`, `workspace_symbols`, `document_symbols`, `macro_expand` | Explore types, methods, and symbols |
| Code Analysis | `code_lowered`, `code_typed`, `format_code`, `lint_package` | IR inspection, formatting, linting |
| Navigation | `goto_definition`, `navigate_to_file` | Jump to definitions and source locations |
| VS Code | `execute_vscode_command`, `list_vscode_commands` | VS Code command execution |
| Debugging | `start_debug_session`, `debug_step_*`, `debug_continue`, `debug_stop`, `add_watch_expression`, `copy_debug_value`, `open_file_and_set_breakpoint` | Full debugging workflow |
| Packages | `pkg_add`, `pkg_rm` | Add/remove packages |
| Testing | `run_tests`, `profile_code`, `stress_test` | Test execution, profiling, load testing |
| Search | `qdrant_search_code`, `qdrant_index_project`, `qdrant_sync_index`, `qdrant_list_collections`, `qdrant_collection_info`, `qdrant_browse_collection`, `qdrant_reindex_file` | Semantic code search |
| Info | `ping`, `usage_instructions`, `usage_quiz`, `tool_help` | Server status and documentation |

## The Gate

Connect any Julia process and expose domain-specific tools to AI agents:

```julia
using Kaimon.Gate: GateTool, serve

function analyze_data(path::String, threshold::Float64=0.95)
    data = load(path)
    filter(x -> x.score > threshold, data)
end

# Kaimon auto-generates the MCP schema from the function signature
serve(tools=[GateTool(analyze_data)])
```

The connected REPL appears as a session in Kaimon's TUI. The agent can call
`analyze_data` alongside all built-in tools, with full argument validation
and type checking.

## Documentation

Full documentation: [kahliburke.github.io/Kaimon.jl](https://kahliburke.github.io/Kaimon.jl/dev/)

## Requirements

- Julia 1.12+
- Any MCP-compatible client (Claude Code, Cursor, VS Code with MCP extension)
- Optional: [Qdrant](https://qdrant.tech) for semantic code search
- Optional: [VS Code Remote Control](https://marketplace.visualstudio.com/items?itemName=nicollasricas.vscode-remote-control) extension for debugging

## Contributing

Contributions are welcome. Please open an issue to discuss changes before submitting
a pull request.

## License

MIT

---

**Kaimon** (開門) — "opening the gate." The gate between AI agents and the Julia
ecosystem.

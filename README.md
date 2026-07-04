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
with a focused default surface of 49 tools for code execution, introspection, debugging,
testing, and code search.

## Key Features

- **Live Code Execution** — evaluate Julia code in persistent REPL sessions with full
  state, package access, and streaming output
- **Deep Introspection** — inspect types, methods, lowered IR, type-inferred code, and
  macro expansions directly from the agent
- **The Gate** — connect external Julia processes and register custom tools via ZMQ.
  Your app's domain logic becomes agent-callable with automatic schema generation
- **Interactive Debugging** — Infiltrator.jl integration with breakpoints, variable
  inspection, and expression evaluation at pause points
- **Semantic Code Search** — index projects into Qdrant and search with natural language
  queries like "function that handles HTTP routing"
- **Terminal Dashboard** — real-time TUI monitoring sessions, tool calls, test runs,
  and search results across all connected REPLs
- **Security** — three modes (strict/relaxed/lax), API key management, IP allowlists
- **Testing & Profiling** — run tests with pattern filtering and coverage, profile code,
  stress-test with concurrent simulated agents

## Quick Start

```julia
]app add Kaimon
```

This installs the `kaimon` command to `~/.julia/bin/` (make sure it's on your `PATH`). Then:

```bash
kaimon
```

The first run opens a setup wizard (security mode, API key, port). After that, the terminal dashboard launches:

![Kaimon dashboard](docs/src/assets/kaimon_overview.gif)

From the dashboard:
- Press **`i`** in the Config tab to write MCP config for Claude Code, Cursor, VS Code, or Gemini CLI
- Press **`g`** to add a Gate snippet to `~/.julia/config/startup.jl` so every Julia session auto-connects
- Or connect manually from any REPL: `]add KaimonGate; using KaimonGate; KaimonGate.serve()`

## Tool Categories

| Category | Tools | Description |
|----------|-------|-------------|
| Code Execution | `ex`, `manage_repl` | Evaluate code, restart/shutdown sessions |
| Introspection | `investigate_environment`, `search_methods`, `type_info`, `list_names`, `workspace_symbols`, `document_symbols`, `macro_expand` | Explore types, methods, and symbols |
| Code Analysis | `code_lowered`, `code_typed`, `format_code`, `lint_package` | IR inspection, formatting, linting |
| Navigation | `goto_definition`, `navigate_to_file` | Jump to definitions and source locations |
| VS Code | `execute_vscode_command`, `list_vscode_commands` | VS Code command execution |
| Debugging | `debug_ctrl`, `debug_eval`, `debug_exfiltrate`, `debug_safehouse` | Infiltrator.jl breakpoint debugging |
| Packages | `pkg_add`, `pkg_rm` | Add/remove packages |
| Testing | `run_tests`, `stress_test` | Test execution, load testing |
| Search | `search_code`, `grep_code`, `qdrant_index_project`, `qdrant_sync_index`, `qdrant_reindex_file`, `qdrant_list_collections` | `search_code` finds code by meaning (hybrid semantic + lexical); `grep_code` runs an exact pattern/regex over the live tree and returns each hit's enclosing symbol |
| Agents | `agent_open`, `agent_send`, `agent_run`, `agent_output`, `agent_status`, `agent_list`, `agent_interrupt`, `agent_close` | Spawn & drive headless `claude` agents |
| Extensions | `extension_info`, `manage_extension` | Inspect & control extension lifecycle |
| Info | `ping`, `usage_instructions`, `usage_quiz`, `tool_help` | Server status and documentation |

Advanced/infra tools (IR inspection `code_lowered`/`code_typed`, `macro_expand`, `profile_code`, `lint_package`, and the raw Qdrant vector-DB admin tools) are gated **off the default surface** to keep tool selection focused -- enable them per project in `.kaimon/tools.json`.

## The Gate

The gate is a separately installable, lightweight package — **`KaimonGate`**
(ZMQ + stdlib only, no heavy deps) — so you can drop it into any project, or
onto a remote/compute node, without the full Kaimon dependency tree:

```julia
]add KaimonGate
```

Connect any Julia process and expose domain-specific tools to AI agents:

```julia
using KaimonGate: GateTool, serve

function analyze_data(path::String, threshold::Float64=0.95)
    data = load(path)
    filter(x -> x.score > threshold, data)
end

# Kaimon auto-generates the MCP schema from the function signature
serve(tools=[GateTool("analyze_data", analyze_data)])
```

The connected REPL appears as a session in Kaimon's TUI. The agent can call
`analyze_data` alongside all built-in tools, with full argument validation
and type checking. The full `Kaimon` install bundles `KaimonGate` automatically
(a deprecated `Kaimon.Gate` alias keeps old `Gate.serve()` snippets working).

## Documentation

Full documentation: [kahliburke.github.io/Kaimon.jl](https://kahliburke.github.io/Kaimon.jl/dev/)

## Requirements

- Julia 1.12+
- Any MCP-compatible client (Claude Code, Cursor, VS Code with Copilot Chat or Continue, Gemini CLI). VS Code's Copilot Chat / Continue speak MCP natively — no extra extension needed; press `i` in the Config tab to write the client config (`.vscode/mcp.json`).
- Optional: [Qdrant](https://qdrant.tech) for semantic code search
- Optional: Kaimon's built-in VS Code extension — install from the Config tab with `v` (or run `Kaimon.install_vscode_remote_control()`) — to enable the in-editor command tools (`execute_vscode_command`, `list_vscode_commands`, `navigate_to_file`).

## Contributing

Contributions are welcome. Please open an issue to discuss changes before submitting
a pull request.

## License

MIT

---

**Kaimon** (開門) — "opening the gate." The gate between AI agents and the Julia
ecosystem.

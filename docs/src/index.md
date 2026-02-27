```@raw html
---
layout: home

hero:
  name: Kaimon.jl
  text: Opening the gate between AI and Julia
  tagline: Expose Julia REPLs as MCP servers, enabling AI agents like Claude Code and Cursor to execute code, introspect types, run tests, debug, and search your codebase interactively.
  actions:
    - theme: brand
      text: Get Started
      link: getting-started
    - theme: alt
      text: Tool Catalog
      link: tools
    - theme: alt
      text: GitHub
      link: https://github.com/kahliburke/Kaimon.jl

features:
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>
    title: MCP Server
    details: Full Model Context Protocol implementation over stdio and SSE transports, compatible with Claude Code, Cursor, and any MCP-capable client.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg>
    title: 32+ Tools
    details: Code execution, type introspection, macro expansion, profiling, test running with coverage, VS Code debugging, package management, and more.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>
    title: The Gate
    details: ZMQ bridge that connects external Julia processes to the MCP server, allowing packages to register custom tools with full schema and documentation.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="9" y1="21" x2="9" y2="9"/></svg>
    title: Terminal Dashboard
    details: Real-time TUI built on Tachikoma.jl that monitors all connected sessions, tool calls, output streams, and server status from one terminal.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
    title: Semantic Search
    details: Qdrant-powered vector search over your codebase. Index projects and query with natural language to find relevant functions, types, and patterns.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>
    title: Security
    details: Three security modes -- strict, relaxed, and lax -- with API key authentication and IP allowlisting to control access to your Julia sessions.
---
```

# Kaimon.jl

Kaimon (開門, "opening the gate") turns any Julia REPL into a Model Context Protocol server. AI agents connect over stdio or SSE and gain full access to Julia's runtime: evaluating expressions, inspecting types, running tests, profiling code, managing packages, and searching your codebase semantically.

## Quick Start

**1. Install**

```bash
git clone https://github.com/kahliburke/Kaimon.jl
cd Kaimon.jl
```

**2. Launch the dashboard**

```bash
./bin/kaimon
```

The first run walks you through a setup wizard (security mode, API key, port). After that, the terminal dashboard opens.

**3. Connect your editor**

Press **`i`** in the Config tab to install MCP config for Claude Code, Cursor, VS Code, or Gemini CLI — no manual file editing needed.

**4. Connect a Julia REPL**

```julia
using Kaimon
Gate.serve()
```

Press **`g`** in the Config tab to append a snippet to `~/.julia/config/startup.jl` so every Julia session auto-connects.

See the [Getting Started](getting-started.md) guide for the full walkthrough.

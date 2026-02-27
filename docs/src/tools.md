# Tool Catalog

Kaimon exposes 35+ MCP tools organized into categories. Each tool is available to any MCP client (Claude Code, Claude Desktop, etc.) connected to a running Kaimon server.

Most tools accept an optional `session` parameter (8-character session key) for routing when multiple Julia processes are connected.

## Code Execution

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `ex` | Evaluate Julia code in a persistent REPL. The user sees code in real-time. | `e` (code), `q` (quiet, default true), `s` (silent), `max_output`, `ses` (session) |
| `manage_repl` | Restart or shut down a Julia session. Restart preserves the session key. | `command` ("restart" or "shutdown"), `session` |

**`ex` -- Evaluate Julia code**

The primary tool for interacting with Julia. By default, `q=true` suppresses return values to save tokens. Use `q=false` when you need the computed result.

```
ex(e="using LinearAlgebra; eigvals([1 2; 3 4])", q=false)
# => 2-element Vector{Float64}: -0.3722..., 5.3722...

ex(e="x = rand(100, 100); size(x)")
# (quiet mode -- return value suppressed, but code runs)
```

## Introspection

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `investigate_environment` | Show pwd, active project, packages, dev packages, and Revise status. | `session` |
| `search_methods` | Find all methods of a function, or methods accepting a given type. | `query` (function or type name), `session` |
| `type_info` | Get type hierarchy, fields, parameters, mutability, and subtypes. | `type_expr`, `session` |
| `list_names` | List exported (or all) names in a module. | `module_name`, `all` (bool), `session` |
| `workspace_symbols` | Search for symbols across all loaded modules by name. | `query`, `session` |
| `document_symbols` | List functions, structs, macros, and constants in a file via AST parsing. No session required. | `file_path` |
| `macro_expand` | Expand a macro expression to see the generated code. | `expression`, `session` |

**`investigate_environment` -- Orient yourself**

```
investigate_environment()
# => Project: MyApp v0.2.1
#    Path: /home/user/MyApp
#    pwd: /home/user/MyApp
#    Dev packages:
#      Kaimon v0.8.0 => ~/.julia/dev/Kaimon
#    Revise: active
```

**`search_methods` -- Discover available methods**

```
search_methods(query="sort")
# => Methods for sort:
#    sort(v::AbstractVector; ...) @ Base sort.jl:1489
#    ...

search_methods(query="AbstractString")
# => Methods with argument type AbstractString:
#    ...(all methods that accept AbstractString)...
```

## Code Analysis

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `code_lowered` | Show lowered (desugared) IR for a function. | `function_expr`, `types` (e.g. `"(Float64,)"`), `session` |
| `code_typed` | Show type-inferred IR for debugging type stability. | `function_expr`, `types`, `session` |
| `format_code` | Format Julia source files using JuliaFormatter.jl. | `path` (file or directory), `overwrite`, `verbose`, `session` |
| `lint_package` | Run Aqua.jl quality assurance tests on a package. | `package_name` (defaults to current project), `session` |

## Navigation

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `goto_definition` | Find where a symbol is defined. Uses Julia reflection (`methods`/`functionloc`/`pathof`) with a file-grep fallback. | `file_path`, `line`, `column`, `session` |
| `navigate_to_file` | Open a file at a specific line and column in VS Code. | `file_path`, `line`, `column` |

## VS Code Integration

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `execute_vscode_command` | Run any allowed VS Code command via the Remote Control extension. | `command`, `args`, `wait_for_response`, `timeout` |
| `list_vscode_commands` | List all commands configured in `.vscode/settings.json` as allowed. | (none) |

## Debugging

All debugging tools require VS Code with the Julia extension and an active debug session.

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `start_debug_session` | Open the debug view and begin debugging. | (none) |
| `debug_step_over` | Step over the current line. | `wait_for_response` |
| `debug_step_into` | Step into a function call. | (none) |
| `debug_step_out` | Step out of the current function. | (none) |
| `debug_continue` | Continue execution until next breakpoint or completion. | (none) |
| `debug_stop` | Stop the current debug session. | (none) |
| `add_watch_expression` | Add a watch expression to monitor during debugging. | `expression` |
| `copy_debug_value` | Copy a debug variable value to the clipboard. | `view` ("variables" or "watch") |
| `open_file_and_set_breakpoint` | Open a file in VS Code and set a breakpoint at a specific line. | `file_path`, `line` |

## Package Management

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `pkg_add` | Add packages to the current environment. Modifies `Project.toml`. | `packages` (array of names), `session` |
| `pkg_rm` | Remove packages from the current environment. | `packages` (array of names), `session` |

## Testing and Profiling

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `run_tests` | Run project tests in a subprocess. Supports pattern filtering and coverage. | `pattern` (ReTest regex), `coverage`, `verbose`, `session` |
| `profile_code` | Profile Julia code to identify performance bottlenecks. Uses `@profile` with flat output. | `code`, `session` |
| `stress_test` | Spawn concurrent simulated MCP agents to stress-test a session. | `code`, `num_agents`, `stagger`, `timeout`, `session` |

**`run_tests` -- Run filtered tests**

```
run_tests(pattern="security")
# Runs only tests matching "security"
# => Test Summary: ...
#    2 passed, 0 failed

run_tests(coverage=true)
# Runs all tests with coverage collection
```

## Semantic Search (Qdrant)

Semantic search requires [Qdrant](https://qdrant.tech/) running locally and [Ollama](https://ollama.ai/) for embeddings. The default embedding model is `qwen3-embedding:0.6b`.

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `qdrant_search_code` | Natural language search over an indexed codebase. | `query`, `collection`, `limit`, `chunk_type` ("all", "definitions", "windows"), `embedding_model` |
| `qdrant_index_project` | Index a project's source files into a Qdrant collection. | `project_path`, `collection`, `recreate`, `extra_dirs`, `extensions` |
| `qdrant_sync_index` | Incrementally sync an index -- reindex changed files, remove deleted ones. | `project_path`, `collection`, `verbose` |
| `qdrant_reindex_file` | Re-index a single file (delete old chunks, index fresh). | `file_path`, `collection`, `project_path`, `verbose` |
| `qdrant_list_collections` | List all available Qdrant collections. | (none) |
| `qdrant_collection_info` | Get detailed info about a collection (vector count, dimension, distance metric). | `collection` |
| `qdrant_browse_collection` | Browse points in a collection with pagination. | `collection`, `limit` |

**`qdrant_search_code` -- Find code by meaning**

```
qdrant_search_code(query="function that handles HTTP routing")
# => [1 0.89] handle_request(req::Request) @ src/server.jl:L42-68 (function)
#    [2 0.81] route(path::String, handler) @ src/router.jl:L15-30 (function)
#    ...
```

## Information

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `ping` | Health check. Returns server status, Revise status, and connected sessions. | (none) |
| `usage_instructions` | Get Julia REPL usage instructions and best practices for AI agents. | (none) |
| `usage_quiz` | Self-graded quiz on Kaimon usage patterns. Tests understanding of the shared REPL model. | `show_sols` (bool) |
| `tool_help` | Get detailed help and examples for any specific tool. | `tool_name`, `extended` (bool) |

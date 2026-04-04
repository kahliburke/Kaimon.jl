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

## Debugging (Infiltrator.jl)

Kaimon integrates with Infiltrator.jl for interactive breakpoint debugging. When a session hits `@infiltrate`, execution pauses and you can inspect locals and eval expressions in the breakpoint scope.

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `debug_ctrl` | Check breakpoint status or resume execution. | `action` ("status" or "continue"), `session` |
| `debug_eval` | Evaluate an expression in the context of a paused breakpoint. | `expression`, `session` |
| `debug_exfiltrate` | Evaluate code containing `@exfiltrate` to capture local variables. | `code`, `session` |
| `debug_inspect_safehouse` | Inspect variables captured by `@exfiltrate`. | `expression` (optional), `session` |
| `debug_clear_safehouse` | Clear all captured variables from the safehouse. | `session` |

## Package Management

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `pkg_add` | Add packages to the current environment. Modifies `Project.toml`. | `packages` (array of names), `session` |
| `pkg_rm` | Remove packages from the current environment. | `packages` (array of names), `session` |

## Testing and Profiling

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `run_tests` | Run project tests in a subprocess. Supports pattern filtering and coverage. | `pattern` (ReTest regex), `coverage`, `verbose`, `project_path`, `session` |
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

run_tests(project_path="/path/to/MyPackage.jl")
# Run tests for a project without a gate session
```

Provide `project_path` (absolute path to the project) or `session` to identify the project. If neither is given and only one session is connected, that session's project is used. The test runner handles both `test/Project.toml` environments and legacy `[extras]/[targets]` layouts automatically.

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

## Session Management

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `start_session` | Spawn a managed Julia session for an allowed project. Call with no arguments to list available projects. | `project_path`, `name` |
| `check_eval` | Check status of a previous `ex()` evaluation by its eval ID. Returns status, elapsed time, and result preview. | `eval_id` |
| `extension_info` | List loaded extensions and their tools. With `name`, show detailed tool docs and parameter schemas. | `name` (optional) |

**`start_session` -- Spawn a project session**

```
start_session()
# => Lists all allowed projects and their status

start_session(project_path="/path/to/MyProject")
# => "Session started. Session key: a3f8b2c1"
```

The project must be in the allowed-projects list (`~/.config/kaimon/projects.json`). See [Sessions](sessions.md#managed-sessions) for details.

**`check_eval` -- Poll a long-running evaluation**

Every `ex()` call returns an eval ID as a structured JSON field `{"eval_id": "XXXXXXXX"}` in its first progress notification. Use `check_eval` to poll for completion:

```
check_eval(eval_id="abc12345")
# => status: completed, elapsed: 12.3s, result: "42"
```

## Information

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `ping` | Health check. Returns server status, Revise status, and connected sessions. | (none) |
| `usage_instructions` | Get Julia REPL usage instructions and best practices for AI agents. | (none) |
| `usage_quiz` | Self-graded quiz on Kaimon usage patterns. Tests understanding of the shared REPL model. | `show_sols` (bool) |
| `tool_help` | Get detailed help and examples for any specific tool. | `tool_name`, `extended` (bool) |

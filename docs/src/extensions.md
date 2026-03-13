# Extensions

Extensions add domain-specific MCP tools to Kaimon by running as separate Julia processes that connect back through the Gate. Each extension is a Julia package with a `kaimon.toml` manifest that declares the tools it provides.

## How Extensions Work

An extension is a Julia project that:

1. Defines handler functions for one or more tools.
2. Declares those tools in a `kaimon.toml` manifest at the project root.
3. Is registered in Kaimon's extension registry (`~/.config/kaimon/extensions.json`).

When Kaimon starts (or when you manually start an extension), it spawns a Julia subprocess that activates the extension project, calls its tools function, and connects back via `Gate.serve()`. The extension's tools appear in the MCP tool list under a namespace prefix (e.g., `smlabnotes.search`).

## The `kaimon.toml` Manifest

Every extension project must have a `kaimon.toml` file in its root directory:

```toml
[extension]
namespace = "myext"
module = "MyExtension"
tools_function = "create_gate_tools"
description = "What this extension does."
```

| Field | Required | Description |
|-------|----------|-------------|
| `namespace` | Yes | Dot-prefix for all tool names (e.g., `myext.tool_name`) |
| `module` | Yes | Julia module name to `using` |
| `tools_function` | Yes | Exported function that returns `Vector{GateTool}` |
| `description` | No | Human-readable summary for display in the TUI and `extension_info` |
| `shutdown_function` | No | Exported no-arg function called before the extension process exits (5 s timeout) |

## Extension Registry

The extension registry at `~/.config/kaimon/extensions.json` tracks which extensions are available:

```json
{
  "extensions": [
    {
      "project_path": "/path/to/MyExtension.jl",
      "enabled": true,
      "auto_start": true
    }
  ]
}
```

| Field | Description |
|-------|-------------|
| `project_path` | Absolute path to the extension project directory |
| `enabled` | Whether the extension can be started |
| `auto_start` | If `true` and `enabled`, automatically spawn at Kaimon startup |

Manage the registry through the TUI Extensions tab or by editing the file directly.

## Lifecycle

Extensions go through these states:

| State | Description |
|-------|-------------|
| `:stopped` | Not running |
| `:starting` | Subprocess spawned, waiting for Gate connection |
| `:running` | Connected and serving tools |
| `:crashed` | Process exited unexpectedly |

If an extension crashes, Kaimon automatically restarts it with exponential backoff (5s, 10s, 30s, 60s delays).

### Graceful Shutdown

When an extension is stopped (via the TUI, a restart, or Kaimon exiting), the shutdown sequence is:

1. Gate receives shutdown signal.
2. If `shutdown_function` is declared, the hook is called with a **5-second timeout**. Use this to flush state, close connections, or log a shutdown message.
3. If the hook completes or times out, the process exits normally.
4. If the process does not exit, Kaimon sends `SIGTERM`, then `SIGKILL` after a grace period.

## Tool Namespacing

Extension tools are namespaced with the extension's `namespace` value to avoid collisions with built-in tools and other extensions:

- Extension with `namespace = "smlabnotes"` exporting tool `"search"` → registered as `smlabnotes.search`
- If two sessions declare the same namespace, the second gets a suffix: `smlabnotes_2`

When a gate session connects, the TUI registers its tools into the MCP server's tool registry and sends `notifications/tools/list_changed` so clients refresh their tool list. When the session disconnects, the tools are unregistered.

## Managing Extensions in the TUI

The TUI has an **Extensions tab** (tab 9) with a two-pane layout:

- **Left pane** — Extension list with status indicators and uptime
- **Right pane** — Detail view showing namespace, module, project path, description, status, session key, tools, and recent errors

### Key Reference

| Key | Action |
|-----|--------|
| `a` | Add a new extension (enter project path) |
| `d` | Remove selected extension |
| `e` | Toggle enabled/disabled |
| `t` | Toggle auto-start |
| `s` | Start extension (if stopped) |
| `x` | Stop extension (if running) |
| `r` | Restart extension |
| `Enter` | Expand detail view |
| `Esc` | Close detail view or cancel flow |

## The `extension_info` Tool

AI agents can discover extensions and their tools programmatically:

```
extension_info()
# Lists all extensions with status and tool names

extension_info(name="smlabnotes")
# Detailed view: status, description, tools with parameter schemas
```

## Writing an Extension

### Project Structure

```
MyExtension.jl/
├── Project.toml
├── kaimon.toml
└── src/
    └── MyExtension.jl
```

### `kaimon.toml`

```toml
[extension]
namespace = "myext"
module = "MyExtension"
tools_function = "tools"
description = "A minimal example extension."
# shutdown_function = "on_shutdown"   # optional: called before process exit
```

### `src/MyExtension.jl`

```julia
module MyExtension

export tools

function tools(GateTool::Type)
    """
        greet(name::String) -> String

    Return a greeting for the given name.
    """
    function greet(name::String)::String
        return "Hello, $(name)!"
    end

    return [GateTool("greet", greet)]
end

end
```

The `tools_function` receives the `GateTool` type as its argument and returns a vector of `GateTool` instances. Each tool handler's type signature is reflected automatically to generate MCP JSON Schema — primitive types, enums, structs, `Union{T, Nothing}` (optional parameters), and vectors are all supported.

### Registering

Add the extension through the TUI Extensions tab (`a` key) or add an entry to `~/.config/kaimon/extensions.json` manually. Once registered, start it with `s` in the TUI or enable `auto_start` for automatic startup.

### Accessing Kaimon Tools from Extensions

Extensions can call back into Kaimon's MCP tools via the service endpoint:

```julia
using Kaimon

# Call any registered MCP tool
result = Gate.call_tool(:qdrant_search_code, Dict{String,Any}(
    "query" => "HTTP routing",
    "limit" => "5",
))

# Discover available tools
tools = Gate.list_tools()
```

This uses a ZMQ REQ/REP connection to the Kaimon server's service socket, allowing extensions to compose with built-in tools and other extensions.

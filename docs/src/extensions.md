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
shutdown_function = "cleanup"           # optional
tui_file = "src/tui_panel.jl"          # optional
julia_flags = ["-t4,1"]               # optional
event_topics = ["breakpoint_hit"]      # optional
```

| Field | Required | Description |
|-------|----------|-------------|
| `namespace` | Yes | Dot-prefix for all tool names (e.g., `myext.tool_name`) |
| `module` | Yes | Julia module name to `using` |
| `tools_function` | Yes | Exported function that returns `Vector{GateTool}` |
| `description` | No | Human-readable summary for display in the TUI and `extension_info` |
| `shutdown_function` | No | Exported no-arg function called before the extension process exits (5 s timeout) |
| `tui_file` | No | Path to a lightweight TUI panel file (relative to project root). Press `[u]` on the extension in the Extensions tab to open it. |
| `julia_flags` | No | Julia startup flags for the extension process (e.g., `["-t4,1", "--heap-size-hint=1G"]`). Defaults to `-t auto`. |
| `event_topics` | No | Stream channels to forward from gate sessions to the extension (e.g., `["breakpoint_hit"]`). Requires an `on_event(channel, data, session_name)` function in the module. |

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

![Extensions tab](assets/kaimon_extensions.gif)

The TUI has an **Extensions tab** (tab 8) with a two-pane layout:

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
| `u` | Open TUI panel (if `tui_file` defined) |
| `Enter` | Expand detail view |
| `Esc` | Close detail view / panel / cancel flow |

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

A full-featured extension looks like this:

```
MyExtension.jl/
├── Project.toml
├── kaimon.toml
└── src/
    ├── MyExtension.jl     # module with tools + shutdown hook
    └── tui_panel.jl       # optional TUI panel
```

See [`examples/HelloExtension.jl`](https://github.com/kburke/Kaimon.jl/tree/main/examples/HelloExtension.jl) for a complete working example with tools, push-based panel updates, and a shutdown hook.

### `kaimon.toml`

```toml
[extension]
namespace = "myext"
module = "MyExtension"
tools_function = "create_tools"
description = "What this extension does."
shutdown_function = "on_shutdown"       # optional
tui_file = "src/tui_panel.jl"          # optional
```

### Defining Tools

The `tools_function` receives the `GateTool` type as its argument and returns a vector of tool instances. Each handler's type signature is reflected automatically to generate MCP JSON Schema — primitive types, enums, structs, `Union{T, Nothing}` (optional), and vectors are all supported.

```julia
module MyExtension

export create_tools, on_shutdown

function create_tools(GateTool::Type)
    """
        greet(name::String, enthusiastic::Bool = false) -> String

    Return a greeting for the given name.
    """
    function greet(name::String, enthusiastic::Bool = false)::String
        msg = enthusiastic ? "Hello, $(name)! 🎉" : "Hello, $(name)."
        # Push state to TUI panel (see "TUI Panel Protocol" below)
        Main.Kaimon.Gate.push_panel("last_greeting", msg)
        return msg
    end

    return [GateTool("greet", greet)]
end

function on_shutdown()
    @info "MyExtension shutting down"
end

end
```

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

## TUI Panel Protocol

Extensions can provide a TUI panel that renders inside Kaimon's Extensions tab. Set `tui_file` in `kaimon.toml` to point at a Julia file that defines these functions:

| Function | Required | Signature | Description |
|----------|----------|-----------|-------------|
| `init` | Yes | `(ctx) → state` | Create initial panel state |
| `update!` | No | `(state, ctx)` | Called each frame (~60 fps); read pushed data here |
| `view` | Yes | `(state, area::Rect, buf::Buffer)` | Render into a Tachikoma buffer region |
| `handle_key!` | No | `(state, evt::KeyEvent) → Bool` | Process input; return `true` if consumed |
| `cleanup!` | Yes | `(state, ctx)` | Tear down when panel closes |

### Lifecycle

1. User presses `u` on a running extension in the Extensions tab
2. Kaimon `include()`s the `tui_file` into a fresh anonymous module
3. `init(ctx)` is called to create the panel state
4. Each frame: `update!(state, ctx)` then `view(state, area, buf)`
5. Key events route to `handle_key!(state, evt)` — return `true` to consume
6. When the user presses `Esc`, `cleanup!(state, ctx)` is called and the panel closes

### ExtPanelContext

The `ctx` argument passed to `init`, `update!`, and `cleanup!` provides:

| Field | Type | Description |
|-------|------|-------------|
| `session_key` | `String` | 8-char gate session key for this extension |
| `tick` | `Int` | Frame counter (increments each frame) |
| `_cache` | `Dict{Symbol,Any}` | Scratch space; `:panel_state` is auto-populated by `push_panel` |
| `eval` | `Function` | `eval(code::String) → NamedTuple` — evaluate code in the extension process |
| `request` | `Function` | `request(tool, args) → String` — call a tool on the extension |

### Key Handling with @match

Use the `@match` macro (from [Match.jl](https://github.com/kmsquire/Match.jl), a Kaimon dependency) for clean dispatch:

```julia
using Match

function handle_key!(state, evt::Tachikoma.KeyEvent)::Bool
    @match (evt.key, evt.char) begin
        (:tab, _)    => (state.selected = mod1(state.selected + 1, 3); true)
        (:char, 'g') => begin do_greet!(state); true end
        (:char, 'r') => begin do_roll!(state); true end
        _            => false
    end
end
```

## `Gate.push_panel()` — Extension to Panel Communication

Instead of polling the extension process with `ctx.eval()`, tool handlers can push state updates to the TUI panel in real time:

```julia
# In your tool handler (runs in the extension subprocess):
Main.Kaimon.Gate.push_panel("key", value)

# Batch form:
Main.Kaimon.Gate.push_panel("greetings" => greetings, "status" => "ready")
```

Values can be any serializable Julia type — strings, numbers, vectors, dicts, etc. They're delivered via ZMQ PUB/SUB with no blocking.

On the panel side, pushed values appear in `ctx._cache[:panel_state]` as a `Dict{String,Any}`:

```julia
function update!(state, ctx)
    ps = get(ctx._cache, :panel_state, nothing)
    ps === nothing && return
    if haskey(ps, "greetings")
        state.greetings = ps["greetings"]
    end
end
```

!!! note "Use `Main.Kaimon.Gate`"
    Extension modules run in their own namespace. Since `Kaimon` is loaded at `Main` scope in the extension subprocess, you must use `Main.Kaimon.Gate.push_panel()` — not just `Gate.push_panel()`.

!!! note "Copy mutable values"
    Always `copy()` mutable values before pushing: `push_panel("data", copy(vec))`. The value is serialized asynchronously, and the original may be mutated before serialization completes.

## Shutdown Hooks

Declare `shutdown_function` in `kaimon.toml` to run cleanup logic before the extension exits:

```julia
function on_shutdown()
    # Flush pending writes, close connections, save state...
    @info "Extension shutting down"
end
```

The hook has a **5-second timeout**. If it doesn't complete in time, the process is terminated. Use this for quick cleanup only — don't block on network requests or long computations.

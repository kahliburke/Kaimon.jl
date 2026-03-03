"""
MCP Prompts support for Kaimon.
"""

module Prompts

export get_prompts, get_prompt

const PROMPT_DEFINITIONS = [
    Dict(
        "name" => "getting-started",
        "description" => "Key tips for working effectively with Kaimon",
        "arguments" => [],
    ),
    Dict(
        "name" => "gate-tools",
        "description" => "How to write custom GateTools that expose Julia functions as MCP tools to agents",
        "arguments" => [],
    ),
]

function get_prompts()
    return PROMPT_DEFINITIONS
end

function get_prompt(name::String)
    if name == "getting-started"
        return """
# Kaimon Quick Tips

- **`ex(e="code")`** is your REPL. Default `q=true` suppresses return values (saves tokens). Use `q=false` only when you need the result.
- **`qdrant_search_code(query="...")`** finds Julia code by meaning, not keywords. Prefer it over grep for exploring unfamiliar codebases.
- **`usage_instructions()`** for the full workflow guide.
"""
    elseif name == "gate-tools"
        return """
# Gate Tools — Custom MCP Tools from Your Julia Session

Gate tools let your Julia session expose functions as MCP tools that agents can call directly.
They appear namespaced under your session: e.g. `myapp.greet`.

## Minimal Example

```julia
using Kaimon.Gate

\"\"\"
    greet(name, loud) -> String

Say hello. If loud=true, shout in uppercase.
\"\"\"
function greet(name::String, loud::Bool = false)
    loud ? uppercase("Hello, \$name!") : "Hello, \$name!"
end

Gate.serve(tools = [GateTool("greet", greet)], namespace = "myapp")
```

The agent calls: `myapp.greet(name="world")` → `"Hello, world!"`

## Key Rules

- **Docstring = tool description.** Write a clear docstring; it becomes the MCP tool description.
- **Typed signatures = schema.** The gate reflects on argument types to build the JSON schema automatically.
- **Return a String** (or anything — it will be stringified for the agent).
- **`namespace` prefixes all tool names.** Defaults to the project name if omitted.

## Supported Argument Types

| Julia type | MCP schema | Notes |
|---|---|---|
| `String` | `string` | |
| `Int`, `Float64` | `number` | |
| `Bool` | `boolean` | |
| `@enum T a b c` | `string` (enum) | Values auto-extracted |
| `struct` | `object` | Fields become properties |
| `Vector{T}` | `array` | Element type reflected recursively |
| `Union{T, Nothing}` | optional `T` | Marks parameter as not required |
| keyword args | optional params | `; limit::Int=10` → optional integer |

## Optional / Keyword Arguments

```julia
function search(query::String; limit::Int = 10, fuzzy::Bool = false)
    # limit and fuzzy are optional — agent may omit them
end
```

`Union{T, Nothing}` also marks an argument optional:

```julia
function fetch(url::String, timeout::Union{Float64, Nothing} = nothing)
    t = timeout !== nothing ? timeout : 30.0
    # ...
end
```

## Enums and Structs

The gate coerces incoming string/dict values to your Julia types automatically:

```julia
@enum Priority low medium high critical

struct Tag
    name::String
    color::Symbol
end

function add_task(title::String, priority::Priority, tags::Vector{Tag})
    # priority arrives as e.g. Priority("high") — already coerced
    # tags arrives as Vector{Tag} — each element coerced from dict
end
```

## Progress Updates for Long-Running Tools

Call `Gate.progress("message")` to stream incremental updates to the agent
(displayed as SSE notifications, prevents HTTP timeouts on slow operations):

```julia
function analyze(passes::Int)
    for i in 1:passes
        sleep(1)
        Gate.progress("pass \$i/\$passes complete")
    end
    return "analysis done"
end
```

## Background / Fire-and-Forget

Return immediately and do work in `@async` when the agent shouldn't wait:

```julia
function start_job(config::String)
    @async run_long_job(config)
    return "job started"
end
```

## Updating Tools at Runtime

Call `Gate.serve()` again with a new tools list to replace the registered tools.
The MCP server sends a `tools/list_changed` notification automatically.

## Closing the Gate

```julia
Gate.stop()
```
"""
    else
        return nothing
    end
end

end # module Prompts

# Debugging

Kaimon integrates with [Infiltrator.jl](https://github.com/JuliaDebug/Infiltrator.jl) to provide interactive breakpoint debugging across both the TUI and MCP tools. When code hits an `@infiltrate` breakpoint, execution pauses and you can inspect local variables, evaluate expressions in the breakpoint scope, and resume — all from the Debug tab (keyboard shortcut: `7`) or from agent tools.

![Debug tab with paused breakpoint](./assets/kaimon_debug.gif)

## Prerequisites

Add Infiltrator to your project:

```julia
using Pkg; Pkg.add("Infiltrator")
```

Kaimon automatically detects when Infiltrator is loaded and hooks into it — no configuration needed. If your project has `using Infiltrator` anywhere, `@infiltrate` will route through Kaimon instead of Infiltrator's default terminal prompt.

## Quick Start

1. Add `@infiltrate` to a function you want to debug:

```julia
using Infiltrator

function compute(data)
    result = sum(data) / length(data)
    @infiltrate                          # execution pauses here
    return result * 2
end
```

2. Call the function — execution pauses at the breakpoint
3. The Debug tab (tab 7) activates automatically, showing locals and a console
4. Inspect variables, evaluate expressions, then continue

## The Debug Tab

The Debug tab has two panes:

### Locals Pane (top)

Displays the paused location and all local variables with their types and values:

```
◉ Paused at src/myfile.jl:42

── Locals ──
data::Vector{Float64} = [1.0, 2.0, 3.0, 4.0, 5.0]
result::Float64 = 3.0
```

- Variables are sorted alphabetically
- Values longer than 200 characters are truncated with `…`
- Matrices and complex types render with Julia's `text/plain` display (formatted, not flat)
- Scrollable with arrow keys and page up/down when focused

### Console Pane (bottom)

A REPL-like console with an `infil>` prompt for evaluating expressions in the breakpoint scope:

```
infil> typeof(result)
  → Float64
infil> length(data) + 1
  → 6
infil> @exfiltrate
  → nothing
```

The console also shows agent activity — when an MCP agent evaluates expressions or requests to continue, those actions appear here with an `agent>` prefix.

## TUI Keyboard Shortcuts

When the Debug tab is active:

| Key | Action |
|-----|--------|
| `c` | Continue execution (resume from breakpoint) |
| `a` | Abort execution (throw InterruptException) |
| `Enter` | Start typing in the `infil>` prompt |
| `Escape` | Exit edit mode (stop typing) |
| `Tab` | Cycle focus between locals and console panes |
| `Ctrl-W` | Toggle word wrap in console |

When typing in the `infil>` prompt:

| Key | Action |
|-----|--------|
| `Enter` | Submit expression for evaluation |
| `Escape` | Exit edit mode |
| `Tab` | Autocomplete variable names, functions, and macros |
| `Up/Down` | Scroll console history |

## Console Commands

The `infil>` prompt supports special commands:

| Command | Action |
|---------|--------|
| `:c` or `:continue` | Resume execution |
| `:w` or `:wrap` | Toggle word wrap |
| `:h` or `:help` | Show help |
| `?` | Show help |

Any other input is evaluated as a Julia expression in the breakpoint scope.

## Tab Completion

The console provides tab completion for:

- Local variables at the breakpoint
- Functions and macros from imported modules (e.g., `@exfiltrate`)
- Console commands (`:c`, `:w`, `:h`)

Type the beginning of a name and press `Tab` to complete. If multiple matches exist, completions cycle on repeated `Tab` presses.

## Agent MCP Tools

AI agents interact with breakpoints through dedicated MCP tools. These work in parallel with the TUI — both the user and the agent can inspect and interact with a paused session.

### `debug_ctrl`

Check breakpoint status or control execution:

```
debug_ctrl(action="status")     # see file, line, all locals with types
debug_ctrl(action="continue")   # resume execution
```

### `debug_eval`

Evaluate an expression in the breakpoint scope:

```
debug_eval(expression="typeof(x)")
debug_eval(expression="length(data) + 1")
debug_eval(expression="myVar = a + b")   # assignments persist
```

Assignments made with `debug_eval` persist within the breakpoint session — you can define a variable in one eval and reference it in the next.

### `debug_exfiltrate`

Redefine a function with `@exfiltrate` to capture variables without pausing execution:

```
debug_exfiltrate(code="""
function f(x)
    y = x * 2
    @exfiltrate
    return y
end
f(21)
""")
```

### `debug_inspect_safehouse`

View variables captured by `@exfiltrate`:

```
debug_inspect_safehouse()                        # list all captured variables
debug_inspect_safehouse(expression="x + y")      # evaluate using captured variables
```

### `debug_clear_safehouse`

Clear all captured variables from the safehouse:

```
debug_clear_safehouse()
```

## Dual Access: Agent + User

Both the TUI user and MCP agents can interact with a paused breakpoint simultaneously:

- **Agent evaluations** appear in the console with an `agent>` prefix
- **User evaluations** appear with the standard `infil>` prefix
- Both see the same local variables and can make assignments that the other will see

### Consent Flow

When an agent requests to continue execution while the user has been actively typing in the console, the TUI shows a consent prompt:

```
🤖 Agent requests continue... [Enter=Allow, Esc=Deny]
```

If the user hasn't interacted with the console during the current breakpoint session, agent continue requests auto-approve without prompting.

### Session Guarding

If an agent tries to evaluate code with `ex()` while a session is paused at a breakpoint, Kaimon returns an error message instead of blocking:

```
⏸ Session 'MyApp' is paused at an @infiltrate breakpoint.
The REPL cannot evaluate new code while paused.

Use debug_ctrl(action="status") to see where it's paused,
debug_eval(expression="...") to evaluate in the breakpoint scope,
or debug_ctrl(action="continue") to resume execution first.
```

## @exfiltrate Workflow

`@exfiltrate` captures local variables into Infiltrator's "safehouse" without pausing execution. This is useful when you want to grab values from deep inside a call stack without stopping the program.

### From a Breakpoint

While paused at `@infiltrate`, you can type `@exfiltrate` in the `infil>` prompt to capture all locals to the safehouse. Then continue execution and inspect the captured values later:

```
infil> @exfiltrate
infil> :c
```

Then use `debug_inspect_safehouse()` to examine the captured variables.

### Without Pausing

Use `debug_exfiltrate` to inject `@exfiltrate` into a function definition. The function runs to completion (no pause), and the variables are captured at the point where `@exfiltrate` appears:

```julia
# Agent workflow
debug_exfiltrate(code="function f(x); y = x*2; @exfiltrate; y; end; f(21)")
debug_inspect_safehouse()          # => x = 21, y = 42
debug_inspect_safehouse(expression="x + y")  # => 63
debug_clear_safehouse()            # clean up
```

## Conditional Breakpoints

`@infiltrate` accepts a condition:

```julia
function process(items)
    for (i, item) in enumerate(items)
        result = transform(item)
        @infiltrate i == 50          # only pause on the 50th iteration
    end
end
```

This is particularly useful in loops where you only want to inspect a specific iteration.

## Tips

- **`using Infiltrator` must be a separate eval** from the call that triggers the breakpoint. If you `using Infiltrator; my_function()` in a single eval, the breakpoint may not fire.

- **Assignments persist** within a breakpoint session. You can `debug_eval(expression="z = x + y")` and then `debug_eval(expression="z")` in a subsequent call.

- **Multiple breakpoints**: If your code has multiple `@infiltrate` calls, continuing from one may hit the next. The Debug tab updates to show the new location and locals. Agents calling `debug_ctrl(action="continue")` followed by `ex()` will get a clear error if the session re-pauses at another breakpoint.

- **Matrices and complex types** render with Julia's standard `show(MIME"text/plain"(), ...)` formatting in both the locals pane and eval results. A 5×5 matrix will display as a properly formatted table, not a flat string.

- **Word wrap** can be toggled with `Ctrl-W` when typing, or the `:w` command, for reading long output lines.

- **Restarting clears debug state**. If you `manage_repl(command="restart")`, any active breakpoint session ends and the Debug tab returns to idle.

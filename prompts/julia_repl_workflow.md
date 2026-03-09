# Julia REPL Workflow Guide

## Code Discovery Tools

Kaimon provides Julia-native code discovery tools. Prefer these over grep/shell:

- **`qdrant_search_code(query="...")`** — Semantic search: find code by meaning, not keywords
- **`type_info("Type")`** — Complete type info: fields, hierarchy, subtypes
- **`search_methods("function")`** — All method signatures and overloads
- **`list_names("Module")`** — Exported (or all) names in a module
- **`goto_definition / document_symbols / workspace_symbols`** — Code navigation via Julia reflection

---

## Primary Execution Tool

**`ex()`** is your primary tool for running code, tests, docs, loading packages.

**New to Kaimon?** → `usage_quiz()` then `usage_quiz(show_sols=true)` to self-grade

## Shared REPL Model

**User sees everything you execute in real-time.** You share the same REPL.

**println/print to stdout are always stripped.** To see a value, use `q=false` with the value as the final expression:

```julia
# WRONG - println to stdout is stripped
ex(e="println(x)")

# CORRECT - Use q=false with final expression
ex(e="x", q=false)
ex(e="(length(data), typeof(data))", q=false)
```

**Key points:**
1. **Default to `q=true`** — Saves tokens by suppressing return values
2. **Use `q=false`** ONLY when YOU need the return value for a decision
3. **`s=true`** (rare) — Suppresses agent> prompt and REPL echo for large outputs

**When to use `q=false`:**
```julia
ex(e="length(result) == 5", q=false)     # Need boolean to decide next step
ex(e="methods(my_func)", q=false)        # Need to inspect signatures
```

**Never use `q=false` for:**
```julia
ex(e="x = 42", q=false)                  # Assignments
ex(e="using Pkg", q=false)               # Imports
ex(e="function f() ... end", q=false)    # Definitions
```

---

## Token Efficiency

- **Batch operations:** `ex("x = 1; y = 2; z = 3")`
- **Avoid large outputs:** `ex("result = big_calc(); (length(result), typeof(result))", q=false)`
- **Use `pkg_add`** instead of `Pkg.add()`
- **Never change project** with `Pkg.activate()`

## Eval Tracking

Every `ex()` call returns an eval ID **immediately** as its first progress notification,
as a structured JSON field `{"eval_id": "XXXXXXXX"}` in the notification params. This ID
arrives before the evaluation begins executing, so you always have it available even
for long-running or timed-out calls. The eval ID also appears as a structured field in the
final result object alongside `content`.

```julia
check_eval(eval_id="abc12345")  # status, elapsed time, result preview
```

The eval history keeps the last 64 evaluations. Use `check_eval` when:
- A previous `ex()` timed out and you want to know if it eventually completed
- You kicked off a long computation and want to poll for completion
- You need to confirm a prior eval's result

## Environment & Packages

- **Revise.jl** auto-tracks changes in `src/`. Do not call `Revise.revise()` — it does nothing useful here. If changes aren't picked up, restart.
- **Session start:** `investigate_environment()` to see packages, dev status, Revise status
- **Add packages:** `pkg_add(packages=["Name"])`

## Tool Reference

**Execution:** `ex(e="code")` — primary tool for everything
**Introspection:** `list_names("Module")`, `type_info("Type")`, `search_methods("func")`
**Semantic search:** `qdrant_search_code(query="...")`, `qdrant_list_collections()`
**Code navigation:** `goto_definition()`, `document_symbols()`, `workspace_symbols()`
**Testing:** `run_tests(pattern="...")` — spawns subprocess, streams results
**Debugging:** `debug_ctrl()`, `debug_eval()`, `debug_exfiltrate()`, `debug_inspect_safehouse()`, `debug_clear_safehouse()`
**Utilities:** `format_code(path)`, `ping()`, `investigate_environment()`
**Help:** `tool_help("tool_name")` or `tool_help("tool_name", extended=true)`
**Extensions:** `extension_info()` — list loaded extensions and their tools. `extension_info(name="smlabnotes")` for detailed tool docs.
**Gate tools:** If session tools appear (namespaced as `<ns>.toolname`), use the `gate-tools` MCP prompt for authoring reference.

---

## Debugging with Infiltrator

Kaimon integrates with Infiltrator.jl for interactive breakpoint debugging. When a session hits `@infiltrate`, execution pauses and you can inspect locals and eval expressions in the breakpoint scope. The user can also interact via the TUI's Debug tab simultaneously.

**Triggering a breakpoint:**
```julia
# Define a function with @infiltrate (or use debug_exfiltrate to inject one)
ex(e="using Infiltrator")    # separate eval from the call that triggers it
ex(e="my_function(args)", q=false)  # will pause at @infiltrate
```

**Inspecting state:**
```julia
debug_ctrl(action="status")           # see file, line, all locals with types
debug_eval(expression="typeof(x)")    # eval in breakpoint scope
debug_eval(expression="length(data)") # any valid Julia expression
```

**Resuming:**
```julia
debug_ctrl(action="continue")  # resume execution
```

**Key points:**
- `using SomePackage` MUST be a separate eval from the call that hits `@infiltrate`
- Assignments persist within a breakpoint session: `debug_eval(expression="myVar = a + b")` then `debug_eval(expression="myVar")` works
- `@exfiltrate` is available in the eval scope — captures variables to Infiltrator's safehouse
- If the user is actively typing in the TUI debug console, your continue request needs their approval; otherwise it auto-approves
- Results render with Julia's text/plain display (matrices show formatted, not flat)

**@exfiltrate workflow** (no breakpoint needed):
```julia
debug_exfiltrate(code="function f(x)\n  y = x * 2\n  @exfiltrate\n  return y\nend\nf(21)")
debug_inspect_safehouse()                          # see all captured vars
debug_inspect_safehouse(expression="x + y")        # eval with captured vars
debug_clear_safehouse()                            # clean up
```

---

## Session Restart

Restart is lightweight — the session key is preserved and the gate reconnects automatically. You do lose all in-memory variables and state, so don't restart if that matters. But if you're fighting world-age errors or stale state, restarting is often faster than trying to work around them.

Restart when:
- You upgraded a package that's already loaded and the code feels stale
- `__init__` or module-level code changed
- You're getting `MethodError` / world-age errors that persist after fixing the code
- The session feels stuck or inconsistent

```julia
manage_repl(command="restart")
```

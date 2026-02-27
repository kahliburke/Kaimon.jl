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

## Environment & Packages

- **Revise.jl** auto-tracks changes in `src/`. If it fails: `manage_repl(command="restart")`, then `ping()`
- **Session start:** `investigate_environment()` to see packages, dev status, Revise status
- **Add packages:** `pkg_add(packages=["Name"])`

## Tool Reference

**Execution:** `ex(e="code")` — primary tool for everything
**Introspection:** `list_names("Module")`, `type_info("Type")`, `search_methods("func")`
**Semantic search:** `qdrant_search_code(query="...")`, `qdrant_list_collections()`
**Code navigation:** `goto_definition()`, `document_symbols()`, `workspace_symbols()`
**Testing:** `run_tests(pattern="...")` — spawns subprocess, streams results
**Utilities:** `format_code(path)`, `ping()`, `investigate_environment()`, `manage_repl(command="restart")`
**Help:** `tool_help("tool_name")` or `tool_help("tool_name", extended=true)`

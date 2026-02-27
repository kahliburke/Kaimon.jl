# Extended Help: ex (Execute Julia REPL)

## Overview

**`ex` is the primary tool.** Use it for nearly every generic task: running code, quick tests, docs, and quick checks.

It uses short parameter names to save tokens:
- `e` - expression (required)
- `q` - quiet mode (default: true)
- `s` - silent mode (default: false)

## Other tools for specific tasks
While `ex` is your go-to tool, some tasks are better served by specialized tools:
- **Semantic code search:** `qdrant_search_code()` - for meaning-based searches in the codebase
- **Method discovery:** `search_methods()` - for finding method signatures and overloads
- **Type inspection:** `type_info()` - for detailed type information, fields, and hierarchy
- Check out the extended help pages for these tools for more details.

## Token-Efficient Usage Patterns

The `ex` tool is your primary interface to Julia. Using it efficiently saves massive amounts of tokens.

### 🚀 Quiet Mode (Default Behavior)

**By default, `ex` automatically suppresses return values to save tokens:**

```julia
# ✅ DEFAULT (q=true) - Returns only printed output, no return value
ex(e="x = 42")                              # Returns: ""
# When you NEED the return value, use q=false:
ex(e="2 + 2", q=false)                      # Returns: "4"
ex(e="typeof([1,2,3])", q=false)            # Returns: "Vector{Int64}"
```

**This is equivalent to automatically adding a semicolon!**

## 🚨 CRITICAL: println is ALWAYS Stripped

**`println` is ALWAYS removed from the AST before execution - regardless of `q` setting.**

To see values, use **`q=false`** with the value as the final expression:

```julia
# ❌ WRONG - println is always stripped (never works for agent feedback)
ex(e="println('Result: ', my_result)")

# ✅ CORRECT - Use q=false with value as final expression
ex(e="my_result", q=false)
ex(e="(x, y, z)", q=false)                    # Multiple values
ex(e="(length(data), typeof(data))", q=false) # Summary info
```

### What gets stripped:

- **Always stripped (regardless of `q`):**
  - `println`, `print`, `printstyled` - at ALL levels (even inside functions)
  - Top-level logging macros (`@info`, `@warn`, `@error`, `@debug`)

- **Stripped only with `q=true`:**
  - `@show` macro (available with `q=false` for debugging)

### Silent mode (`s=true`) affects what the user sees live

`s` controls whether the user sees the `agent>` prompt and real-time REPL echo.

- **Default:** `s=false` (recommended)
- **Use `s=true` only rarely** when you intentionally expect very large output

Examples:
```julia
ex(e="undefined_var + 1", q=true, s=false)   # ✅ errors still returned
ex(e="big = rand(10^7); sum(big)", q=true)   # ✅ compute, no spam
ex(e="@show x; x+1", q=false)                # ✅ @show works with q=false
```

### 📦 Combine Multiple Operations

```julia
# ❌ INEFFICIENT - 3 separate calls
ex(e="x = 10")
ex(e="y = 20")
ex(e="z = 30")

# ✅ EFFICIENT - One call, minimal output (quiet mode handles semicolons)
ex(e="x = 10; y = 20; z = 30")
```

### 🧪 Testing Best Practices

```julia
# ✅ Inline test - quiet mode suppresses TestSet object
ex(e="@test my_function(5) == 10")

# ✅ TestSet - quiet mode automatically suppresses return value
ex(e="""
@testset "Feature X" begin
    @test condition1
    @test condition2
end
""")

# ✅ To see test results summary, use verbose mode:
ex(e="@testset \"Tests\" begin @test 1==1 end", q=false)
```

### 🔍 Avoid Displaying Large Data

```julia
# ✅ EFFICIENT - Quiet mode suppresses large output automatically
ex(e="collect(1:1000)")

# ✅ Get summary info when needed
ex(e="result = big_computation(); (length(result), typeof(result))", q=false)

# ✅ For large data, just compute without returning
ex(e="result = expensive_computation()")  # Stores in workspace, doesn't display
```

### 🧹 Use `let` Blocks for Temporary Work

```julia
# ✅ Keeps workspace clean, prints result without returning
ex(e="""
let x = load_data(), y = process(x)
    result = analyze(y)
    println("Result: ", result)
end
""")
```

## Common Workflows

### Loading Packages

```julia
# Load package (quiet mode = no output)
ex(e="using DataFrames")

# Check what's available (need output, so q=false)
ex(e="names(DataFrames)", q=false)
```

### Quick Documentation Lookup

```julia
# Get function documentation (needs output)
ex(e="@doc sort", q=false)

# See all methods (needs output)
ex(e="methods(sort)", q=false)

# Find which method will be called (needs output)
ex(e="@which sort([1,2,3])", q=false)
```

### Debugging Type Issues

```julia
# Check type (needs output)
ex(e="typeof(my_var)", q=false)

# Inspect fields (needs output)
ex(e="fieldnames(typeof(my_var))", q=false)

# Check type hierarchy (needs output)
ex(e="supertype(MyType)", q=false)
```

### Running Code After Edits

```julia
# After editing a file, test changes (quiet mode = just pass/fail output)
ex(e="""
# Revise.jl should auto-reload changes
@test my_updated_function(10) == 20
""")
```

## Error Handling

```julia
# Errors are always returned regardless of quiet mode
ex(e="1/0")
# Returns: "ERROR: DivideByZero..."

# Catch and handle errors (quiet mode suppresses return, shows println)
ex(e="""
try
    risky_operation()
    println("Success")
catch e
    println("Failed: ", e)
end
""")
```

## What NOT to Do

```julia
# ❌ Don't use verbose mode unnecessarily
ex(e="x = 42", q=false)  # Wasteful! Default quiet mode is fine

# ❌ Don't use println to communicate with the user
# (The user sees output in real-time in their REPL already)
ex(e='println("Starting computation...")')

# ❌ Don't change environments
ex(e="Pkg.activate(\".\")")  # Never do this!
```

## Understanding the Parameters

### `q` (quiet) - Default: true
- **Purpose**: Suppress return values to save tokens
- **When to use q=true** (default): When executing code for side effects (assignments, tests, imports)
- **When to use q=false**: When you need to see the computed result

### `s` (silent) - Default: false
- **Purpose**: Suppress the "agent>" prompt and real-time output display
- **Rarely needed**: Only use when output is purely for logging/debugging

## Pro Tips

1. **Trust quiet mode** - The default (q=true) saves 70-90% of tokens
2. **Use q=false sparingly** - Only when you actually need the return value
3. **Combine operations** - Fewer tool calls = better performance
4. **Use `let` blocks** - Keep workspace clean
5. **Trust Revise** - File changes are picked up automatically
6. **Errors always show** - Quiet mode doesn't suppress errors

## When to Use Specialized Tools

- **Semantic search:** `qdrant_search_code()` for meaning-based lookup in the codebase
- **Method discovery:** `search_methods()` for signatures and overloads
- **Type inspection:** `type_info()` for fields and hierarchy

Use `ex()` first, then reach for specialized tools when you need structured results.

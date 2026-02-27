"""
MCP Prompts support for Kaimon.

Prompts are reusable prompt templates that can be exposed through the MCP protocol.
They help agents get started quickly with best practices for using the Julia REPL tools.
"""

module Prompts

export get_prompts, get_prompt

# Define available prompts
const PROMPT_DEFINITIONS = [
    Dict(
        "name" => "getting-started",
        "description" => "Learn how to use Kaimon's Julia code discovery tools effectively. Start here for new sessions!",
        "arguments" => [],  # No arguments needed
    ),
    Dict(
        "name" => "semantic-search-guide",
        "description" => "Guide to using semantic code search with qdrant_search_code",
        "arguments" => [],
    ),
    Dict(
        "name" => "type-exploration",
        "description" => "How to inspect Julia types, hierarchies, and structures using type_info",
        "arguments" => [],
    ),
]

"""
Get list of all available prompts.
Returns array of prompt definitions with name, description, and arguments.
"""
function get_prompts()
    return PROMPT_DEFINITIONS
end

"""
Get a specific prompt by name.
Returns the prompt content as a string.
"""
function get_prompt(name::String)
    if name == "getting-started"
        return """
# Getting Started with Kaimon

Kaimon provides Julia-native code discovery tools that are more effective than grep or shell commands for Julia codebases.

## Code Discovery Tools

### Semantic Code Search
**`qdrant_search_code(query="natural language description")`**
Finds code by meaning, not just keywords. Discovers implementations even with different terminology.
```julia
qdrant_search_code(query="function that handles HTTP requests and dispatches to handlers")
```
Requires Ollama running with embedding model (default: `qwen3-embedding:0.6b`).

### Deep Type Introspection
**`type_info("TypeName")`**
Shows complete type hierarchy, all fields with types, type parameters, and subtypes.
```julia
type_info("AbstractArray")
```

### Method Discovery
**`search_methods("function_name")`**
Finds all method signatures across all modules, including operator overloads.
```julia
search_methods("sort")
```

### Symbol Discovery
**`list_names("ModuleName")`**
Lists exported names (public API). Use `all=true` for internal symbols.
```julia
list_names("Base")
```

### Code Navigation (via Julia reflection)
- `goto_definition(file, line, col)` — Jump to where a symbol is defined
- `document_symbols(file)` — List all symbols defined in a file
- `workspace_symbols(query="...")` — Search for symbols across loaded modules

## Quick Execution Guide

**Primary Tool:** `ex(e="julia code")`
- Default quiet mode (`q=true`) saves tokens by suppressing return values
- Only use `q=false` when you need the return value to make a decision
```julia
ex(e="using DataFrames")             # q=true (default)
ex(e="length(result)", q=false)      # q=false when you need the value
```

## Environment & Packages

- `investigate_environment()` — Check current packages, project, Revise status
- `pkg_add(packages=["Name"])` — Add packages
- `ping()` — Verify server is responsive
- `tool_help("tool_name")` — Detailed help on any tool
"""
    elseif name == "semantic-search-guide"
        return """
# Semantic Code Search Guide

`qdrant_search_code` finds Julia code by meaning, not keywords.

## Best Practices

### Describe what you're looking for
```julia
# Good — specific about behavior
qdrant_search_code(query="function that validates HTTP request headers")
qdrant_search_code(query="code that parses JSON and handles errors")

# Poor — too vague
qdrant_search_code(query="validate")
```

### Increase limit for broader searches
```julia
qdrant_search_code(query="authentication logic", limit=10)
```

### Specify collection for multi-project setups
```julia
qdrant_search_code(query="routing code", collection="MyProject")
```

## Common Use Cases

```julia
# Feature implementations
qdrant_search_code(query="code that implements user authentication and session management")

# Error handling
qdrant_search_code(query="functions that catch exceptions and log errors")

# Configuration
qdrant_search_code(query="code that reads configuration from files or environment variables")
```

## Tips

1. **Start broad, then narrow** — Refine based on initial results
2. **Combine with navigation tools** — Use semantic search to find files, then `goto_definition`/`document_symbols` for precise navigation
3. **Check index** — `qdrant_collection_info(collection="Name")` to verify code is indexed
4. **Rephrase** — Try different descriptions if first attempt doesn't find what you need
5. **Sync after changes** — `qdrant_sync_index()` to update index after code changes
"""
    elseif name == "type-exploration"
        return """
# Julia Type Exploration Guide

`type_info` reveals complete information about Julia types that you can't get from reading source files alone.

## Basic Usage

```julia
type_info("String")          # Concrete type — fields, hierarchy
type_info("Vector{Int}")     # Parametric type — parameters, constraints
type_info("AbstractArray")   # Abstract type — subtypes, interface
```

## What You'll See

- **Type hierarchy:** `String <: AbstractString <: Any`
- **Fields:** All fields with types (including private/internal)
- **Type parameters:** Names, constraints, variance
- **Subtypes:** All types that inherit (for abstract types)

## Common Use Cases

```julia
# Understand data structures
type_info("DataFrame")
type_info("HTTP.Request")

# Explore type hierarchies
type_info("Number")
type_info("AbstractArray")

# Debug type issues — understand what methods will match
type_info("MyCustomType")
```

## Complementary Tools

- `search_methods("func")` — Find all methods for a type
- `list_names("Module")` — Discover available types in a module
- `goto_definition()` — Jump to type source code
"""
    else
        return nothing
    end
end

end # module Prompts

# code_typed

Show type-inferred IR for a function. Used to debug type stability issues.

**Syntax:** `code_typed(function_name, (ArgType1, ArgType2, ...))`

## Examples

```julia
code_typed(sin, (Float64,))
code_typed(+, (Int, Int))
code_typed(my_function, (String, Vector{Int}))
```

## Reading Output

- `%1 = func(x)::Int64` - Type is known ✅
- `%1 = func(x)::Union{Int64, String}` - Type unstable ❌
- `=> Int64` - Return type
- Look for `Union`, `Any`, or `@_call` - these indicate type instability

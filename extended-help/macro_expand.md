# macro_expand

Expand a macro to see what code it generates. Include the `@` symbol.

## Examples

```julia
macro_expand("@time sleep(1)")
macro_expand("@test 1 + 1 == 2)")
macro_expand("@inbounds arr[i]")
```

## Hygiene

Macros generate "hygienic" variable names like `var"#temp#123"` to avoid conflicts with your code.
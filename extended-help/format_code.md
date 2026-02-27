# format_code

Format Julia code using JuliaFormatter.jl. Requires `Pkg.add("JuliaFormatter")`.

## Arguments

- `path` (required) - File or directory to format
- `overwrite` (default: true) - Overwrite files in place
- `verbose` (default: true) - Show progress

## Examples

```json
{"path": "src/MyModule.jl"}
{"path": "src"}
{"path": "src/file.jl", "overwrite": false}
```
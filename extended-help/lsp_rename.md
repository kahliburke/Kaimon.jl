# lsp_rename

Rename a symbol across the workspace using Julia LSP.

## Arguments

- `file_path` - Absolute path to file containing the symbol
- `line` - Line number (1-indexed)
- `column` - Column number (1-indexed)
- `new_name` - New name for the symbol

## Example

```json
{
  "file_path": "/path/to/file.jl",
  "line": 42,
  "column": 10,
  "new_name": "calculate_result"
}
```

Returns a WorkspaceEdit showing all changes that would be made.

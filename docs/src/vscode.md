# VS Code Integration

Kaimon.jl provides deep integration with Visual Studio Code through a built-in VS Code extension. This enables bidirectional communication between the Julia REPL and VS Code, powering features like command execution, debugging, and file navigation.

## Setup

Kaimon ships its own **VS Code Remote Control** extension. Install it from the TUI Config tab (press `v`), or from the Julia REPL:

```julia
using Kaimon
Kaimon.install_vscode_remote_control()
```

Reload VS Code after installation. The extension comes with sensible default allowed commands for Kaimon workflows.

### Allowed Commands

VS Code commands must be explicitly allowlisted before they can be executed via MCP. The extension ships with common defaults (file save, terminal control). To customize, edit your VS Code settings (user or workspace):

```json
{
  "vscode-remote-control.allowedCommands": [
    "workbench.action.files.saveAll",
    "editor.action.formatDocument",
    "workbench.action.debug.start"
  ]
}
```

Use [`list_vscode_commands`](@ref) to see which commands are currently allowed.

## Command Execution

### `execute_vscode_command`

Run any allowlisted VS Code command from Julia or an MCP client:

```
execute_vscode_command("workbench.action.files.saveAll")
```

Set `wait_for_response=true` to get the return value from the command (with an optional timeout):

```
execute_vscode_command("editor.action.clipboardCopyAction", wait_for_response=true, timeout=5)
```

Arguments can be passed as a JSON-encoded array via the `args` parameter.

### `list_vscode_commands`

Returns the list of commands configured in `.vscode/settings.json` under `vscode-remote-control.allowedCommands`. Use this to discover which commands are available before calling `execute_vscode_command`.

## File Navigation

### `navigate_to_file`

Open a file in VS Code at a specific line and column position:

```
navigate_to_file(file_path="/path/to/file.jl", line=100, column=15)
```

Both `line` and `column` are optional (1-indexed, default to 1). This is useful for jumping to search results, navigating code tours, or following up on `goto_definition` results.

# VS Code Integration

Kaimon.jl provides deep integration with Visual Studio Code through the [VS Code Remote Control](https://marketplace.visualstudio.com/items?itemName=nicolo-ribaudo.remote-control) extension. This enables bidirectional communication between the Julia REPL and VS Code, powering features like command execution, debugging, and file navigation.

## Setup

Install the **Remote Control** extension in VS Code. Kaimon detects the extension automatically when running inside a VS Code terminal.

### Allowed Commands

VS Code commands must be explicitly allowlisted in your `.vscode/settings.json` before they can be executed via MCP:

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

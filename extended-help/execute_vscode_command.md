# execute_vscode_command

Execute VS Code commands via the Remote Control extension.

## Common Commands

```julia
# Save/close
execute_vscode_command("workbench.action.files.saveAll")
execute_vscode_command("workbench.action.closeAllEditors")

# Terminal
execute_vscode_command("workbench.action.terminal.focus")
execute_vscode_command("workbench.action.terminal.new")

# Git
execute_vscode_command("git.stageAll")
execute_vscode_command("git.commit")
execute_vscode_command("git.push")

# Testing
execute_vscode_command("testing.runAll")
execute_vscode_command("testing.runAtCursor")

# Debugging
execute_vscode_command("workbench.action.debug.start")
execute_vscode_command("workbench.action.debug.stepOver")
```

## With Arguments

```julia
execute_vscode_command(
    "workbench.action.tasks.runTask",
    ["build"]
)
```

## Wait for Response

```julia
result = execute_vscode_command(
    "someCommand",
    wait_for_response=true,
    timeout=10.0
)
```

Commands must be allowlisted in `.vscode/settings.json` under `vscode-remote-control.allowedCommands`.
Use `list_vscode_commands()` to see available commands.

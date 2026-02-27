# tool_help - Extended Documentation

## Overview

Get detailed help and examples for any MCP tool.

## Description

Provides verbose instructions, parameter descriptions, and usage examples for any available tool.
Use this when you need more detailed information about how to use a specific tool properly.

## Arguments

- **tool_name** (required): Name of the tool (e.g., "ex", "execute_vscode_command", "lsp_goto_definition")
- **extended** (optional, default: false): If true, includes additional examples and detailed documentation

## Examples

### Get basic help
```json
{"tool_name": "ex"}
```

### Get extended help with additional examples
```json
{"tool_name": "ex", "extended": true}
```

## Notes

- Extended help files are located in the `extended-help/` directory
- Not all tools have extended documentation
- The basic help shows the tool's description and parameter schema

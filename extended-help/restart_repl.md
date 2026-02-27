# restart_repl - Extended Documentation

## Overview

Restart the Julia REPL and return immediately.

## Important Behavior

This tool returns a response **BEFORE** the server restarts, so you receive clear instructions.

## AI Agent Workflow

1. Call this tool - you will receive a response immediately
2. Wait 5 seconds before making any new requests
3. Retry every 2 seconds until the connection is reestablished
4. Typical restart time: 5-10 seconds

The MCP server will be temporarily offline during restart. This is expected and normal.

## When to Use

- After making changes to the MCP server code
- When Revise fails to pick up changes (rare)
- When the REPL needs a fresh start
- After installing new packages that require a restart
- When you need to clear all variables and start fresh

## Arguments

None

## Example

```json
{}
```

## Notes

- The server automatically restarts and reconnects
- May take longer if packages need recompilation
- All variables and state will be cleared

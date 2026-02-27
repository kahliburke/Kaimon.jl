# ping - Extended Documentation

## Overview

Check if the MCP server is responsive and healthy.

## Description

Returns a simple health status message with Revise.jl status. Useful for testing connectivity and server availability.

## Arguments

None

## Example

Check server health:
```json
{}
```

## Response

The tool returns:
- Server health status
- Revise.jl status (active, has errors, or not loaded)

## Use Cases

- Testing if the MCP server is running
- Checking connection to the Julia REPL
- Verifying Revise.jl is working properly

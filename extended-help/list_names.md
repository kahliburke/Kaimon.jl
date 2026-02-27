# list_names - Extended Documentation

## Overview

List all exported names from a module or all names in scope.

## Description

Shows what symbols are available in a module or the current scope.
Useful for exploring packages and understanding what's available.

## Arguments

- **module_name** (optional): Module to list names from (defaults to Main)

## Examples

### List names in current scope
```json
{}
```

### List exports from a package
```json
{"module_name": "DataFrames"}
```

## Use Cases

- Exploring package APIs
- Finding available functions
- Understanding module exports
- Debugging name conflicts

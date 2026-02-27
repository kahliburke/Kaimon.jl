# investigate_environment - Extended Documentation

## Overview

Get comprehensive information about the current Julia environment.

## Information Provided

- **Current working directory** - Where files are being read/written
- **Active project** - Which Project.toml is active
- **Package list** - All packages in the environment
- **Development packages** - Packages under development with their file paths
- **Package status** - Current versions and sources
- **Revise.jl status** - Whether hot reloading is active

## Use Cases

- Understanding the development setup
- Debugging environment issues
- Finding where development packages are located
- Checking which project is active
- Verifying package installations
- Determining if Revise is tracking changes

## Arguments

None

## Example

```json
{}
```

## Tips

- Use this before making assumptions about available packages
- Check this if code isn't behaving as expected
- Useful for understanding multi-project setups
- If Revise isn't tracking changes, consider using restart_repl

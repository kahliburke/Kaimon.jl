# lint_package

Run Aqua.jl quality assurance tests. Requires `Pkg.add("Aqua")`.

Checks: ambiguities, undefined exports, unbound type parameters, dependencies, Project.toml validation, type piracy.

## Examples

```json
{}
{"package_name": "MyPackage"}
```
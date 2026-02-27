# type_info

Get type information: hierarchy, fields, and parameters.

## Examples

```julia
type_info("typeof(x)")
type_info("supertype(MyType)")
type_info("fieldnames(MyStruct)")
```
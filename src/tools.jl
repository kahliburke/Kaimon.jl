# Tool definition structure
struct MCPTool
    id::Symbol                    # Internal identifier (:exec_repl)
    name::String                  # JSON-RPC name ("exec_repl")
    title::String                 # Human-readable display name ("Exec Repl")
    description::String
    parameters::Dict{String,Any}
    handler::Function
    hidden::Bool                  # registered & callable, but omitted from tools/list unless explicitly requested
end
# Back-compat: every existing 6-arg construction (the @mcp_tool macro and the
# built-in tools) is a visible tool. Hidden tools opt in with the 7th arg.
MCPTool(id, name, title, description, parameters, handler) =
    MCPTool(id, name, title, description, parameters, handler, false)
# Convenience function to create a simple text parameter schema
function text_parameter(name::String, description::String, required::Bool = true)
    schema = Dict(
        "type" => "object",
        "properties" =>
            Dict(name => Dict("type" => "string", "description" => description)),
    )
    if required
        schema["required"] = [name]
    end
    return schema
end

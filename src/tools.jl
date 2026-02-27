# Tool definition structure
struct MCPTool
    id::Symbol                    # Internal identifier (:exec_repl)
    name::String                  # JSON-RPC name ("exec_repl")
    description::String
    parameters::Dict{String,Any}
    handler::Function
end
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

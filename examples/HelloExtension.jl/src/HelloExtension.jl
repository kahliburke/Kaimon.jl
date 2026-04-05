module HelloExtension

export create_tools, on_shutdown

"""
    create_tools(GateTool) -> Vector{GateTool}

Return the tools this extension provides. Called by Kaimon on startup.
The `GateTool` type is passed in so extensions don't need to import it directly.
"""
function create_tools(GateTool::Type)
    """
        greet(name::String, enthusiastic::Bool = false) -> String

    Return a greeting for the given name.
    """
    function greet(name::String, enthusiastic::Bool = false)::String
        if enthusiastic
            return "Hello, $(name)! 🎉 Welcome to Kaimon extensions!"
        else
            return "Hello, $(name)."
        end
    end

    """
        roll_dice(sides::Int = 6) -> String

    Roll a die with the given number of sides and return the result.
    """
    function roll_dice(sides::Int = 6)::String
        result = rand(1:sides)
        return "🎲 Rolled a $result (d$sides)"
    end

    """
        word_count(text::String) -> String

    Count the words, characters, and lines in the given text.
    """
    function word_count(text::String)::String
        words = length(split(text))
        chars = length(text)
        lines = count('\n', text) + 1
        return "Words: $words | Characters: $chars | Lines: $lines"
    end

    return [
        GateTool("greet", greet),
        GateTool("roll_dice", roll_dice),
        GateTool("word_count", word_count),
    ]
end

"""
    on_shutdown()

Called by Kaimon before the extension process exits.
Use this to flush state, close connections, or log a shutdown message.
"""
function on_shutdown()
    @info "HelloExtension shutting down gracefully"
end

end # module

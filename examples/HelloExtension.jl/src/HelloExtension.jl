# ── HelloExtension ────────────────────────────────────────────────────────────
#
# Complete example Kaimon extension demonstrating:
#   - Tool registration via create_tools(GateTool)
#   - Push-based panel updates via Gate.push_panel()
#   - Graceful shutdown hook
#   - TUI panel (see src/tui_panel.jl)
#
# To register: add this project path in Kaimon's Extensions tab (key: a)
# or add an entry to ~/.config/kaimon/extensions.json.

module HelloExtension

export create_tools, on_shutdown

# Module-level state vectors. Tool handlers append here, then push snapshots
# to the TUI panel via Gate.push_panel() so the panel updates in real time.
const GREETINGS = String[]
const ROLLS = String[]

"""
    create_tools(GateTool) -> Vector{GateTool}

Return the tools this extension provides. Called once at startup.

The `GateTool` type is passed in as an argument so extensions don't need
Kaimon as a dependency — just define handlers with typed signatures and
Kaimon reflects them into MCP JSON Schema automatically.
"""
function create_tools(GateTool::Type)

    """
        greet(name::String, enthusiastic::Bool = false) -> String

    Return a greeting for the given name.
    """
    function greet(name::String, enthusiastic::Bool = false)::String
        msg = enthusiastic ?
            "Hello, $(name)! 🎉 Welcome to Kaimon extensions!" :
            "Hello, $(name)."
        push!(GREETINGS, msg)
        # Push a snapshot to the TUI panel. Must use Main.Kaimon.Gate because
        # this module runs inside the extension subprocess where Kaimon is
        # loaded at Main scope, not inside this module's namespace.
        # copy() is required — push_panel serializes the value across ZMQ,
        # and the original vector may be mutated before serialization completes.
        Main.Kaimon.Gate.push_panel("greetings", copy(GREETINGS))
        return msg
    end

    """
        roll_dice(sides::Int = 6) -> String

    Roll a die with the given number of sides and return the result.
    """
    function roll_dice(sides::Int = 6)::String
        result = rand(1:sides)
        msg = "🎲 Rolled a $result (d$sides)"
        push!(ROLLS, msg)
        Main.Kaimon.Gate.push_panel("rolls", copy(ROLLS))
        return msg
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

Called by Kaimon before the extension process exits (5-second timeout).
Use this to flush state, close connections, or save data.
"""
function on_shutdown()
    @info "HelloExtension shutting down ($(length(GREETINGS)) greetings, $(length(ROLLS)) rolls)"
end

end # module

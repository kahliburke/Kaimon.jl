module GateToolTest

using Tachikoma
using Infiltrator
using Kaimon.Gate: GateTool, serve, progress, tty_path, tty_size, restore_tty!

include("types.jl")
include("tools.jl")
include("debug_scenarios.jl")
include("tui.jl")

"""
    run()

Launch the TodoBoard TUI with gate tools registered.

The TUI renders a kanban board (Todo | In Progress | Done) while GateTools
let an MCP agent manipulate the board programmatically.

# Keyboard shortcuts
- `h`/`l` or `←`/`→`: Switch columns
- `j`/`k` or `↑`/`↓`: Navigate tasks
- `Enter`: Move task to next column
- `q`: Quit
"""
function run()
    model = TodoBoardModel()
    tools = create_tools(model)
    serve(tools = tools, allow_mirror = false, force = true)
    try
        Tachikoma.app(model; tty_out = tty_path(), tty_size = tty_size())
    finally
        restore_tty!()
    end
end

"""
    extension_tools(::Type{GateTool}) -> Vector{GateTool}

Entry point for the Kaimon extension lifecycle. Creates a headless `TodoBoardModel`
and returns all tools operating on it — no TUI required.
"""
function extension_tools(::Type{GateTool})
    model = TodoBoardModel()
    return create_tools(model)
end

"""
    on_shutdown()

Called by the extension manager before the gate process exits.
"""
function on_shutdown()
    @info "GateToolTest extension shutting down"
end

export run, TodoBoardModel, create_tools, extension_tools, on_shutdown
export debug_fibonacci, debug_data_pipeline, debug_matrix_solver

end # module GateToolTest

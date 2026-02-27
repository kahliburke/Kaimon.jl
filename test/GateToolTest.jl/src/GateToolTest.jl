module GateToolTest

using Tachikoma
using Kaimon.Gate: GateTool, serve, progress, tty_path, tty_size, restore_tty!

include("types.jl")
include("tools.jl")
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

export run, TodoBoardModel, create_tools

end # module GateToolTest

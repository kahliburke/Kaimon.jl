# ═══════════════════════════════════════════════════════════════════════════════
# Kaimon TUI — Tachikoma-based terminal UI for the persistent server
#
# Elm architecture: Model → update! → view. Manages REPL connections,
# agent sessions, tool call activity, and the MCP HTTP server.
# ═══════════════════════════════════════════════════════════════════════════════

# Tachikoma is loaded at the Kaimon module level via `using Tachikoma`.
# Exported: Model, Block, StatusBar, Span, Layout, etc.
# Non-exported widgets need explicit import:
import Tachikoma:
    TabBar,
    SelectableList,
    ListItem,
    Table,
    Gauge,
    Sparkline,
    Modal,
    TextInput,
    BOX_HEAVY,
    ResizableLayout,
    split_layout,
    render_resize_handles!,
    handle_resize!,
    TreeView,
    TreeNode,
    PixelImage,
    load_pixels!
# Tachikoma.split (for layouts) is not Base.split, so we alias it.
const tsplit = Tachikoma.split

include("logo.jl")

include("tui/types.jl")
include("tui/io.jl")
include("tui/json.jl")
include("tui/lifecycle.jl")
include("tui/update.jl")
include("tui/config_flow.jl")
include("tui/view.jl")
include("tui/sessions.jl")
include("tui/activity.jl")
include("tui/config_view.jl")
include("tui/advanced.jl")
include("tui/advanced_view.jl")
include("tui/tests.jl")
include("tui/search.jl")
include("tui/search_config.jl")
include("tui/search_config_view.jl")
include("tui/search_manage.jl")
include("tui/search_manage_view.jl")

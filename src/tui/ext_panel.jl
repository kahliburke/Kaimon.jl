# ── Extension TUI Panels ─────────────────────────────────────────────────────
#
# Allows extensions to register a lightweight TUI file that runs in the Kaimon
# process. The file defines a module with a standard protocol:
#
#   module MyExtTUI
#   using Tachikoma
#
#   function init(ctx::ExtPanelContext)      -> state (any type)
#   function update!(state, ctx::ExtPanelContext)
#   function view(state, area::Rect, buf::Buffer)
#   function handle_key!(state, evt::KeyEvent) -> Bool
#   function cleanup!(state, ctx::ExtPanelContext)
#   end
#
# Lifecycle:
#   1. User presses 'u' on selected extension in Extensions tab
#   2. Kaimon include()s the tui_file into a fresh module
#   3. Calls init(ctx) to create state
#   4. Each frame: update!(state, ctx), then view(state, area, buf)
#   5. Key events routed to handle_key!(state, evt)
#   6. Escape calls cleanup!(state, ctx) and dismisses the panel

"""
    ExtPanelContext

Passed to extension TUI panel functions. Provides communication with the
extension's gate session and access to extension metadata.
"""
mutable struct ExtPanelContext
    session_key::String              # gate session key for this extension
    conn_mgr::Any                    # ConnectionManager (avoid type dep)
    namespace::String                # extension namespace
    project_path::String             # extension project root
    tick::Int                        # frame counter (synced from KaimonModel)
    _cache::Dict{Symbol,Any}         # scratch space for the panel
    # Closures for cross-process communication — panels can't reference Kaimon
    # directly since they run in anonymous modules.
    eval::Function                   # (code::String) -> NamedTuple
    request::Function                # (tool_name::String, args::Dict) -> String
end

function ExtPanelContext(ext::ManagedExtension, conn_mgr)
    ctx = ExtPanelContext(
        ext.session_key,
        conn_mgr,
        ext.config.manifest.namespace,
        ext.config.entry.project_path,
        0,
        Dict{Symbol,Any}(),
        identity,  # placeholder
        identity,  # placeholder
    )
    # Close over ctx so the panel just calls ctx.eval("code")
    ctx.eval = code -> ext_panel_eval(ctx, code)
    ctx.request = (tool, args=Dict{String,Any}()) -> ext_panel_request(ctx, tool, args)
    return ctx
end

"""
    ext_panel_request(ctx::ExtPanelContext, tool_name::String, args::Dict) -> String

Send a tool call to the extension's gate session. Blocks until response.
"""
function ext_panel_request(ctx::ExtPanelContext, tool_name::String, args::Dict=Dict{String,Any}())
    isempty(ctx.session_key) && return "Error: extension not connected"
    ctx.conn_mgr === nothing && return "Error: no connection manager"
    conn = get_connection_by_key(ctx.conn_mgr, ctx.session_key)
    conn === nothing && return "Error: extension session not found"
    _call_session_tool(conn, tool_name, args)
end

"""
    ext_panel_eval(ctx::ExtPanelContext, code::String) -> NamedTuple

Evaluate Julia code in the extension's gate session. Blocks until response.
Returns `(stdout, stderr, value_repr, ...)` — see `eval_remote` for full shape.
"""
function ext_panel_eval(ctx::ExtPanelContext, code::String)
    isempty(ctx.session_key) && return (stdout="", stderr="Error: extension not connected", value_repr="")
    ctx.conn_mgr === nothing && return (stdout="", stderr="Error: no connection manager", value_repr="")
    conn = get_connection_by_key(ctx.conn_mgr, ctx.session_key)
    conn === nothing && return (stdout="", stderr="Error: extension session not found", value_repr="")
    eval_remote(conn, code)
end

# ── Active Panel State ───────────────────────────────────────────────────────

"""
    ActiveExtPanel

Holds the runtime state of an open extension TUI panel.
"""
mutable struct ActiveExtPanel
    ext_mod::Module                  # the included TUI module (Module(:_loading) while loading)
    state::Any                       # value returned by init() (nothing while loading)
    ctx::ExtPanelContext
    ext_name::String                 # display name for the panel title
    error_msg::String                # non-empty if panel errored
    loading::Bool                    # true while include/init runs on background thread
end

# ── Load / Open / Close ──────────────────────────────────────────────────────

"""
    open_ext_panel!(m::KaimonModel, ext::ManagedExtension) -> Bool

Load the extension's TUI file and open the panel overlay. The include and
init run on a background thread so precompilation doesn't freeze the TUI.
"""
function open_ext_panel!(m::KaimonModel, ext::ManagedExtension)
    tui_file = ext.config.manifest.tui_file
    isempty(tui_file) && return false

    abs_path = isabspath(tui_file) ? tui_file :
        joinpath(ext.config.entry.project_path, tui_file)

    if !isfile(abs_path)
        @warn "Extension TUI file not found" path=abs_path
        return false
    end

    ctx = ExtPanelContext(ext, m.conn_mgr)
    dname = ext.config.manifest.namespace

    # Show loading state immediately
    panel = ActiveExtPanel(Module(:_loading), nothing, ctx, dname, "", true)
    m.ext_panel = panel

    # Load on background thread so precompilation doesn't freeze the TUI
    let panel=panel, ctx=ctx, dname=dname, abs_path=abs_path
        spawn_task!(m._task_queue, :ext_panel_loaded) do
            try
                mod_name = Symbol("_ExtPanel_", dname, "_", rand(UInt16))
                ext_mod = Module(mod_name)
                Base.include(ext_mod, abs_path)

                for fn in (:init, :view, :cleanup!)
                    isdefined(ext_mod, fn) || error("TUI module missing required function: $fn")
                end

                state = Base.invokelatest() do
                    ext_mod.init(ctx)
                end

                (success=true, ext_mod=ext_mod, state=state)
            catch e
                (success=false, error_msg=sprint(showerror, e))
            end
        end
    end

    return true
end

"""
    close_ext_panel!(m::KaimonModel)

Close the active extension panel, calling cleanup! on the state.
"""
function close_ext_panel!(m::KaimonModel)
    panel = m.ext_panel
    panel === nothing && return

    if isempty(panel.error_msg) && panel.state !== nothing
        try
            Base.invokelatest() do
                panel.ext_mod.cleanup!(panel.state, panel.ctx)
            end
        catch e
            @warn "Extension panel cleanup! failed" exception=e
        end
    end

    m.ext_panel = nothing
end

# ── Frame Update ─────────────────────────────────────────────────────────────

function _ext_panel_update!(panel::ActiveExtPanel, tick::Int)
    panel.loading && return
    isempty(panel.error_msg) || return
    panel.ctx.tick = tick

    # If the extension restarted, its session key changed — update ours
    # so we drain pushes from the correct buffer.
    for ext in get_managed_extensions()
        if ext.config.manifest.namespace == panel.ctx.namespace &&
                !isempty(ext.session_key) &&
                ext.session_key != panel.ctx.session_key
            panel.ctx.session_key = ext.session_key
            break
        end
    end

    # Drain any push_panel() messages into ctx._cache[:panel_state]
    pushes = drain_panel_pushes!(panel.ctx.session_key)
    if !isempty(pushes)
        ps = get!(panel.ctx._cache, :panel_state, Dict{String,Any}())::Dict{String,Any}
        merge!(ps, pushes)
    end

    if isdefined(panel.ext_mod, :update!)
        try
            Base.invokelatest() do
                panel.ext_mod.update!(panel.state, panel.ctx)
            end
        catch e
            panel.error_msg = "update! error: $(sprint(showerror, e))"
        end
    end
end

# ── Render ───────────────────────────────────────────────────────────────────

const _LOADING_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

function _ext_panel_view!(panel::ActiveExtPanel, area::Rect, buf::Buffer)
    # Draw a bordered overlay
    title = "Extension: $(panel.ext_name) [Esc] close"

    block = Block(
        title = title,
        border_style = tstyle(:accent),
        title_style = tstyle(:accent, bold=true),
        box = BOX_HEAVY,
    )
    inner = render(block, area, buf)

    # Clear inner area
    th = Tachikoma.theme()
    for row in inner.y:bottom(inner)
        for col in inner.x:right(inner)
            set_char!(buf, col, row, ' ', Style(bg=th.bg))
        end
    end

    if panel.loading
        si = mod1(panel.ctx.tick ÷ 3, length(_LOADING_FRAMES))
        set_string!(buf, inner.x + 2, inner.y + 1,
            "$(_LOADING_FRAMES[si]) Loading extension panel...",
            tstyle(:accent);
            max_x=right(inner))
        return
    end

    if !isempty(panel.error_msg)
        set_string!(buf, inner.x + 1, inner.y + 1,
            "Panel error:", tstyle(:error, bold=true);
            max_x=right(inner))
        lines = split(panel.error_msg, '\n')
        for (i, line) in enumerate(lines)
            y = inner.y + 2 + i
            y > bottom(inner) && break
            set_string!(buf, inner.x + 1, y, String(line), tstyle(:error);
                max_x=right(inner))
        end
        return
    end

    try
        Base.invokelatest() do
            panel.ext_mod.view(panel.state, inner, buf)
        end
    catch e
        panel.error_msg = "view error: $(sprint(showerror, e))"
    end
end

# ── Key Handling ─────────────────────────────────────────────────────────────

"""
    _ext_panel_handle_key!(panel::ActiveExtPanel, evt::KeyEvent) -> Bool

Route a key event to the extension panel. Returns true if consumed.
"""
function _ext_panel_handle_key!(panel::ActiveExtPanel, evt::KeyEvent)::Bool
    panel.loading && return false
    isempty(panel.error_msg) || return false

    if isdefined(panel.ext_mod, :handle_key!)
        try
            return Base.invokelatest() do
                panel.ext_mod.handle_key!(panel.state, evt)
            end::Bool
        catch e
            panel.error_msg = "handle_key! error: $(sprint(showerror, e))"
            return false
        end
    end
    return false
end

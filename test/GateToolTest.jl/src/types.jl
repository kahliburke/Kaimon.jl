# ═══════════════════════════════════════════════════════════════════════════════
# Type definitions for the TodoBoard GateTool test fixture
#
# Rich type hierarchy exercising: enums, structs, nested objects, arrays,
# optional fields, Symbol coercion, and Union{T, Nothing} handling.
# ═══════════════════════════════════════════════════════════════════════════════

# ── Enums ─────────────────────────────────────────────────────────────────────

"""Task priority level."""
@enum Priority low medium high critical

"""Current status of a task on the board."""
@enum TodoStatus todo in_progress done archived

"""Visual theme for the board."""
@enum BoardTheme minimal colorful compact

"""Keyboard modifier for input events."""
@enum KeyModifier mod_none mod_ctrl mod_alt mod_shift

"""Mouse button type for mouse input events."""
@enum MouseButtonType btn_left btn_right btn_middle btn_scroll_up btn_scroll_down

# ── Structs ───────────────────────────────────────────────────────────────────

"""
    Tag(name, color)

A label that can be attached to a task.

# Fields
- `name::String`: Display name of the tag (e.g. "bug", "feature")
- `color::Symbol`: Color hint for rendering (e.g. `:red`, `:blue`)
"""
struct Tag
    name::String
    color::Symbol
end

"""
    TaskItem(id, title, description, priority, status, tags)

A single task on the kanban board.

# Fields
- `id::Int`: Unique task identifier
- `title::String`: Short task title
- `description::String`: Detailed description
- `priority::Priority`: Priority level (low, medium, high, critical)
- `status::TodoStatus`: Current column (todo, in_progress, done, archived)
- `tags::Vector{Tag}`: Attached labels
"""
struct TaskItem
    id::Int
    title::String
    description::String
    priority::Priority
    status::TodoStatus
    tags::Vector{Tag}
end

"""
    InputEvent(key, modifier, text)

A keyboard input event for the TUI.

# Fields
- `key::String`: Key name ("q", "up", "enter", etc.)
- `modifier::KeyModifier`: Modifier key held during the event
- `text::Union{String, Nothing}`: Optional text payload
"""
struct InputEvent
    key::String
    modifier::KeyModifier
    text::Union{String,Nothing}
end

"""
    MouseInput(x, y, button)

A mouse input event for the TUI.

# Fields
- `x::Int`: Column position (1-based)
- `y::Int`: Row position (1-based)
- `button::MouseButtonType`: Which mouse button was pressed
"""
struct MouseInput
    x::Int
    y::Int
    button::MouseButtonType
end

"""
    EventStep(delay_ms, key_event, mouse_event)

A single step in a batch of input events. Each step has an optional delay
and either a key event or a mouse event (or neither for a pure delay).

# Fields
- `delay_ms::Int`: Milliseconds to wait before dispatching this event
- `key_event::Union{InputEvent, Nothing}`: Optional keyboard event
- `mouse_event::Union{MouseInput, Nothing}`: Optional mouse event
"""
struct EventStep
    delay_ms::Int
    key_event::Union{InputEvent,Nothing}
    mouse_event::Union{MouseInput,Nothing}
end

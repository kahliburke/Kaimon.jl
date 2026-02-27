"""
Session Status Management

Defines valid session statuses and provides validation helpers.
"""
module SessionStatus

# ============================================================================
# Status Constants
# ============================================================================

# Julia session statuses
const READY = "ready"              # Session connected, accepting requests
const DOWN = "down"                # Lost heartbeat, buffering requests
const RESTARTING = "restarting"    # Restart command sent, buffering requests
const STOPPED = "stopped"          # Permanently stopped, reject requests
const REPLACED = "replaced"        # Session superseded by newer session, reject requests

# MCP session statuses
const ACTIVE = "active"            # Agent currently connected
const INACTIVE = "inactive"        # Agent disconnected >1hr (historical record)

# Valid status sets
const VALID_JULIA_STATUSES = Set([READY, DOWN, RESTARTING, STOPPED, REPLACED])
const VALID_MCP_STATUSES = Set([ACTIVE, INACTIVE])

# Statuses that should buffer requests (instead of rejecting)
const BUFFERING_STATUSES = Set([DOWN, RESTARTING])

# Terminal statuses - session won't come back, don't buffer
const TERMINAL_STATUSES = Set([STOPPED, REPLACED])

# ============================================================================
# Validation
# ============================================================================

"""
    validate_julia_status(status::String)

Validate a Julia session status. Throws if invalid.
"""
function validate_julia_status(status::String)
    if !(status in VALID_JULIA_STATUSES)
        error(
            "Invalid Julia session status: '$status'. Valid statuses: $(join(sort(collect(VALID_JULIA_STATUSES)), ", "))",
        )
    end
end

"""
    validate_mcp_status(status::String)

Validate an MCP session status. Throws if invalid.
"""
function validate_mcp_status(status::String)
    if !(status in VALID_MCP_STATUSES)
        error(
            "Invalid MCP session status: '$status'. Valid statuses: $(join(sort(collect(VALID_MCP_STATUSES)), ", "))",
        )
    end
end

"""
    should_buffer(status::String) -> Bool

Returns true if requests should be buffered for this status.
"""
function should_buffer(status::String)
    return status in BUFFERING_STATUSES
end

"""
    is_terminal(status::String) -> Bool

Returns true if session is in a terminal state (won't recover).
"""
function is_terminal(status::String)
    return status in TERMINAL_STATUSES
end

"""
    is_active(status::String) -> Bool

Returns true if session is active (ready or temporarily unavailable).
"""
function is_active(status::String)
    return status in Set([READY, DOWN, RESTARTING])
end

export READY,
    DOWN,
    RESTARTING,
    STOPPED,
    REPLACED,
    ACTIVE,
    INACTIVE,
    VALID_JULIA_STATUSES,
    VALID_MCP_STATUSES,
    BUFFERING_STATUSES,
    TERMINAL_STATUSES,
    validate_julia_status,
    validate_mcp_status,
    should_buffer,
    is_terminal,
    is_active

end # module

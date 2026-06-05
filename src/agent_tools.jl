# ── Agent session MCP tools ───────────────────────────────────────────────────
# The public surface (plan §Public surface). Registered as Kaimon MCP tools so both
# the user's own Claude Code and extensions (via the service endpoint) can drive
# agent sessions. Events stream on the gate bus channel "agent:<id>".

const agent_open_tool = @mcp_tool :agent_open "Spawn a Kaimon-owned AI agent (headless claude) in a directory. Returns the agent_id. Events stream on the gate event bus channel 'agent:<id>' as {kind,turn,data} JSON." Dict(
    "type" => "object",
    "properties" => Dict(
        "cwd" => Dict("type" => "string", "description" => "Working directory for the agent (must exist)."),
        "model" => Dict("type" => "string", "description" => "Model alias or id (default claude-sonnet-4-6)."),
        "permission_mode" => Dict("type" => "string", "description" => "default | acceptEdits | plan | bypassPermissions (default acceptEdits)."),
        "allowed_tools" => Dict("type" => "array", "items" => Dict("type" => "string"), "description" => "Optional allowlist of tool names."),
        "disallowed_tools" => Dict("type" => "array", "items" => Dict("type" => "string"), "description" => "Tools the agent may NOT call. Defaults to the agent_* tools (recursion guard); pass [] to allow nested agents."),
        "mcp_config" => Dict("type" => "string", "description" => "Optional path to an --mcp-config JSON pointing the agent at the live Kaimon MCP (M3)."),
        "system_prompt" => Dict("type" => "string", "description" => "Optional instructions/context to initialize the agent with (appended to its system prompt; applies to every turn)."),
        "id" => Dict("type" => "string", "description" => "Optional caller-supplied agent id (e.g. to key to a notebook)."),
    ),
    "required" => ["cwd"],
) (args) -> begin
    try
        aid = agent_open(;
            cwd = String(get(args, "cwd", "")),
            model = String(get(args, "model", "claude-sonnet-4-6")),
            permission_mode = String(get(args, "permission_mode", "acceptEdits")),
            allowed_tools = String.(get(args, "allowed_tools", String[])),
            disallowed_tools = String.(get(args, "disallowed_tools", AGENT_SELF_TOOLS)),
            mcp_config = get(args, "mcp_config", nothing),
            system_prompt = get(args, "system_prompt", nothing),
            id = get(args, "id", nothing))
        JSON.json(Dict("agent_id" => aid))
    catch e
        "Error opening agent: $(sprint(showerror, e))"
    end
end

const agent_send_tool = @mcp_tool :agent_send "Send a user turn to an agent. Events arrive on the 'agent:<id>' stream; returns the turn number." Dict(
    "type" => "object",
    "properties" => Dict(
        "agent_id" => Dict("type" => "string", "description" => "Agent id from agent_open."),
        "text" => Dict("type" => "string", "description" => "The user message for this turn."),
    ),
    "required" => ["agent_id", "text"],
) (args) -> begin
    try
        turn = agent_send(String(get(args, "agent_id", "")), String(get(args, "text", "")))
        JSON.json(Dict("turn" => turn))
    catch e
        "Error sending to agent: $(sprint(showerror, e))"
    end
end

const agent_interrupt_tool = @mcp_tool :agent_interrupt "Cancel an agent's in-flight turn (best effort)." text_parameter("agent_id", "Agent id from agent_open.") (args) -> begin
    try
        ok = agent_interrupt(String(get(args, "agent_id", "")))
        JSON.json(Dict("interrupted" => ok))
    catch e
        "Error interrupting agent: $(sprint(showerror, e))"
    end
end

const agent_close_tool = @mcp_tool :agent_close "Kill an agent process and free its registry slot." text_parameter("agent_id", "Agent id from agent_open.") (args) -> begin
    try
        ok = agent_close(String(get(args, "agent_id", "")))
        JSON.json(Dict("closed" => ok))
    catch e
        "Error closing agent: $(sprint(showerror, e))"
    end
end

const agent_status_tool = @mcp_tool :agent_status "Get an agent's status, model, cwd, last activity, transcript path, and running token/cost usage." text_parameter("agent_id", "Agent id from agent_open.") (args) -> begin
    try
        st = agent_status(String(get(args, "agent_id", "")))
        st === nothing ? "No such agent: $(get(args, "agent_id", ""))" : JSON.json(st)
    catch e
        "Error getting agent status: $(sprint(showerror, e))"
    end
end

const agent_list_tool = @mcp_tool :agent_list "List all open Kaimon-owned agents with their status and running cost." Dict("type" => "object", "properties" => Dict()) (args) -> begin
    try
        JSON.json(Dict("agents" => list_agents()))
    catch e
        "Error listing agents: $(sprint(showerror, e))"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Kaimon gate client · session-scoped tool support  (split from gate_client.jl)
# ─────────────────────────────────────────────────────────────────────────────

# ── Session-Scoped Tool Support ──────────────────────────────────────────────
# Translates reflected Julia type metadata from gate sessions into MCP-compliant
# JSON schemas and creates MCPTool wrappers that route calls through the gate.

"""
    _type_meta_to_schema(meta::Dict) -> Dict{String,Any}

Convert a Julia type metadata Dict (from `_type_to_meta` on the gate side)
into an MCP-compliant JSON schema fragment.
"""
function _type_meta_to_schema(meta::Dict)::Dict{String,Any}
    kind = get(meta, "kind", "any")

    kind == "string" && return Dict{String,Any}("type" => "string")
    kind == "integer" && return Dict{String,Any}("type" => "integer")
    kind == "number" && return Dict{String,Any}("type" => "number")
    kind == "boolean" && return Dict{String,Any}("type" => "boolean")

    if kind == "enum"
        schema = Dict{String,Any}(
            "type" => "string",
            "enum" => get(meta, "enum_values", String[]),
        )
        desc = get(meta, "description", "")
        !isempty(desc) && (schema["description"] = desc)
        return schema
    end

    if kind == "struct"
        props = Dict{String,Any}()
        required = String[]
        for field in get(meta, "fields", Dict[])
            fname = get(field, "name", "")
            isempty(fname) && continue
            fprop = _type_meta_to_schema(get(field, "type_meta", Dict()))
            fdesc = get(field, "description", "")
            !isempty(fdesc) && (fprop["description"] = fdesc)
            props[fname] = fprop
            # Struct fields are always required (unless their type is Union{T,Nothing})
            field_kind = get(get(field, "type_meta", Dict()), "kind", "any")
            push!(required, fname)
        end
        schema = Dict{String,Any}("type" => "object", "properties" => props)
        !isempty(required) && (schema["required"] = required)
        desc = get(meta, "description", "")
        !isempty(desc) && (schema["description"] = desc)
        return schema
    end

    if kind == "array"
        elem_meta = get(meta, "element_type", Dict())
        return Dict{String,Any}(
            "type" => "array",
            "items" => _type_meta_to_schema(elem_meta),
        )
    end

    # "any" or unrecognized → string fallback
    jt = get(meta, "julia_type", "Any")
    schema = Dict{String,Any}("type" => "string")
    jt != "Any" && jt != "String" && (schema["description"] = "Julia type: $jt")
    return schema
end

"""
    _reflect_to_schema(tool_meta::Dict) -> Dict{String,Any}

Convert reflected tool metadata into an MCP-compliant `inputSchema` Dict.
"""
function _reflect_to_schema(tool_meta::Dict)::Dict{String,Any}
    properties = Dict{String,Any}()
    required = String[]

    for arg in get(tool_meta, "arguments", Dict[])
        name = get(arg, "name", "")
        isempty(name) && continue
        prop = _type_meta_to_schema(get(arg, "type_meta", Dict()))
        properties[name] = prop
        if get(arg, "required", false)
            push!(required, name)
        end
    end

    schema = Dict{String,Any}("type" => "object", "properties" => properties)
    !isempty(required) && (schema["required"] = required)
    return schema
end

# ── Session-tool deadline policy ─────────────────────────────────────────────
# A session tool call fails on SILENCE, not on duration. Every frame the gate publishes for
# the call — progress, completion — refreshes the clock, so a tool that reports progress at a
# sane interval runs as long as it needs. This mirrors `eval_remote_async`, where any message
# resets `last_activity`; a flat wall-clock deadline here meant a well-behaved, progress-
# reporting tool and a genuinely wedged one met the same guillotine.
#
# Two budgets, both in seconds via env:
#   KAIMON_SESSION_TOOL_TIMEOUT — how much CONTINUOUS silence is fatal (default 300)
#   KAIMON_SESSION_TOOL_MAX     — absolute ceiling regardless of chatter; the runaway backstop
#                                 for code that reports progress from inside a spin (default
#                                 3600, matching a notebook worker's own eval ceiling; ≤0 = none)
#
# A tool may also declare its own silence budget (`GateTool(…; timeout_ms=…)`), reflected into
# its metadata. That covers the case progress-refresh cannot: an operation that is legitimately
# slow AND silent. The effective budget is the MORE GENEROUS of declared and global, so raising
# the env floor never shortens a tool that asked for longer, and vice versa.
const _SESSION_TOOL_SILENCE_DEFAULT_S = 300.0
const _SESSION_TOOL_MAX_DEFAULT_S = 3600.0

_env_seconds(key::String) = let v = tryparse(Float64, get(ENV, key, ""))
    (v === nothing || isnan(v)) ? nothing : v
end

# Effective silence budget (seconds) for a call, given the tool's declared value (or `nothing`).
function _session_tool_silence_s(declared_ms::Union{Nothing,Real} = nothing)
    global_s = something(_env_seconds("KAIMON_SESSION_TOOL_TIMEOUT"), _SESSION_TOOL_SILENCE_DEFAULT_S)
    global_s <= 0 && (global_s = _SESSION_TOOL_SILENCE_DEFAULT_S)
    declared_s = (declared_ms === nothing || declared_ms <= 0) ? 0.0 : declared_ms / 1000.0
    return max(global_s, declared_s)
end

# Absolute ceiling (seconds) — `Inf` when disabled.
function _session_tool_max_s()
    v = _env_seconds("KAIMON_SESSION_TOOL_MAX")
    v === nothing && return _SESSION_TOOL_MAX_DEFAULT_S
    return v <= 0 ? Inf : v
end

# A tool's declared silence budget in ms, or `nothing` when it didn't declare one. Absent for
# every tool from a pre-`timeout_ms` gate, which is exactly the "use the client default" case.
function _declared_timeout_ms(tool_meta::Dict)
    v = get(tool_meta, "timeout_ms", nothing)
    v === nothing && return nothing
    v isa Real && return v > 0 ? Int(round(v)) : nothing
    parsed = tryparse(Float64, string(v))
    return (parsed === nothing || parsed <= 0) ? nothing : Int(round(parsed))
end

"""
    _call_session_tool(conn, tool_name, args; timeout_ms=nothing) -> String

Send a `:tool_call` message through the gate's ZMQ REQ socket and return
the result as a string.

This is the blocking, no-progress path (used when no `_on_progress` callback was injected),
so there are no frames to refresh a silence clock — it gets a single flat deadline, raised to
the tool's declared budget when it has one.
"""
function _call_session_tool(conn::REPLConnection, tool_name::String, args::Dict;
                            timeout_ms::Union{Nothing,Real} = nothing)
    if conn.status ∉ (:connected, :evaluating) || conn.req_channel === nothing
        return "Error: Gate not connected (session=$(conn.session_id))"
    end

    # Caller identity: the invoking agent's Mcp-Session-Id, set as a task-local by
    # the MCP server around tool dispatch (empty for a self/nested call). The owning
    # Kaimon agent_id (if any) rides alongside so an extension can tell a built-in
    # agent's calls from an external client's.
    caller_id = string(get(task_local_storage(), :mcp_caller, ""))
    agent_id = string(get(task_local_storage(), :mcp_agent_id, ""))
    request = (
        type = :tool_call,
        name = tool_name,
        arguments = Dict{String,Any}(string(k) => v for (k, v) in args),
        caller = caller_id,
        agent_id = agent_id,
    )
    caller_timeout = timeout_ms === nothing ? 30.0 : max(30.0, timeout_ms / 1000.0)
    result = _req_send_recv(conn, request; caller_timeout = caller_timeout)
    if result.ok
        conn.tool_call_count += 1
        resp_type = get(result.response, :type, :error)
        if resp_type == :error
            return "Error: $(get(result.response, :message, "unknown"))"
        end
        return string(get(result.response, :value, ""))
    else
        return "Error: $(result.error)"
    end
end

"""
    _call_session_tool_async(conn, tool_name, args; timeout_ms=nothing, on_progress=nothing)

Asynchronous session tool call: sends `:tool_call_async` via REQ, gets `:accepted`
ack immediately, then polls SUB socket for tool_complete/tool_error/tool_progress
messages via a per-request inbox.

This avoids blocking the REQ socket during long-running tool calls, allowing health
pings and other operations to proceed. Mirrors the `eval_remote_async` pattern.

`on_progress` callback, if provided, is called as `on_progress(message::String)`
for each progress update received during streaming.

`timeout_ms` is the tool's DECLARED silence budget (or `nothing`); the effective deadline
also honours the global env budgets — see the deadline-policy notes above.

Returns the tool result as a String.
"""
function _call_session_tool_async(
    conn::REPLConnection,
    tool_name::String,
    args::Dict;
    timeout_ms::Union{Nothing,Real} = nothing,
    on_progress::Union{Function,Nothing} = nothing,
)
    if conn.status ∉ (:connected, :evaluating) || conn.req_channel === nothing
        return "Error: Gate not connected (session=$(conn.session_id))"
    end

    # Generate a unique request ID to correlate response with this caller
    request_id = bytes2hex(rand(UInt8, 8))

    # Register inbox BEFORE sending request — fast tool calls can complete
    # and publish on PUB before the REQ/REP round-trip finishes.
    my_inbox = Channel{Any}(Inf)
    lock(conn._eval_inboxes_lock) do
        conn._eval_inboxes[request_id] = my_inbox
    end

    # Caller identity: the invoking agent's Mcp-Session-Id, set as a task-local by the
    # MCP server around tool dispatch (empty for a self/nested call); the owning Kaimon
    # agent_id (if any) rides alongside.
    caller_id = string(get(task_local_storage(), :mcp_caller, ""))
    agent_id = string(get(task_local_storage(), :mcp_agent_id, ""))

    # Phase 1: Send tool_call_async request via REQ worker (non-blocking)
    request = (
        type = :tool_call_async,
        name = tool_name,
        arguments = Dict{String,Any}(string(k) => v for (k, v) in args),
        request_id = request_id,
        caller = caller_id,
        agent_id = agent_id,
    )
    hs_result = _req_send_recv(conn, request; caller_timeout = 10.0)

    ack = if hs_result.ok
        hs_result.response
    else
        (type = :error, message = hs_result.error)
    end

    # Check handshake result
    ack_type = get(ack, :type, :error)
    if ack_type == :error
        lock(conn._eval_inboxes_lock) do
            delete!(conn._eval_inboxes, request_id)
        end
        close(my_inbox)
        return "Error: $(get(ack, :message, "Unknown handshake error"))"
    end
    if ack_type != :accepted
        lock(conn._eval_inboxes_lock) do
            delete!(conn._eval_inboxes, request_id)
        end
        close(my_inbox)
        return "Error: Unexpected ack type: $ack_type"
    end

    # Phase 2: Wait for tool_complete/tool_error on the inbox. The clock measures SILENCE —
    # every frame refreshes it — bounded by an absolute ceiling.

    try
        start_time = time()
        last_activity = start_time
        silence_budget = _session_tool_silence_s(timeout_ms)
        # The ceiling is a backstop against work with no stated bound, so it must never sit BELOW
        # an explicitly-stated budget — otherwise a declared (or requested) 2h silently becomes 1h
        # and the knob we advertise doesn't do what it says.
        ceiling = max(_session_tool_max_s(), silence_budget)
        hard_deadline = start_time + ceiling
        silence_threshold = 60.0    # emit a keepalive after this much quiet
        keepalive_interval = 30.0   # seconds between repeated keepalives
        last_keepalive = 0.0

        while true
            now = time()
            silence = now - last_activity

            if silence >= silence_budget
                return "Error: Gate tool call '$tool_name' timed out after " *
                       "$(round(Int, silence))s with no output (silence budget " *
                       "$(round(Int, silence_budget))s, $(round(Int, now - start_time))s elapsed). " *
                       "The tool may be wedged; a legitimately slow-and-silent tool should " *
                       "declare `GateTool(…; timeout_ms=…)` or report progress."
            end
            if now >= hard_deadline
                return "Error: Gate tool call '$tool_name' exceeded the absolute ceiling of " *
                       "$(round(Int, ceiling))s and was abandoned (it may still be running on the " *
                       "session). Raise KAIMON_SESSION_TOOL_MAX if this is legitimate."
            end

            # Silent-but-alive is indistinguishable from wedged unless we say so. Report elapsed
            # time upstream so the agent (and the TUI) can tell waiting from hanging.
            if on_progress !== nothing && silence >= silence_threshold &&
               (now - last_keepalive) >= keepalive_interval
                elapsed = now - start_time
                mins = round(Int, elapsed ÷ 60)
                secs = round(Int, elapsed % 60)
                elapsed_str = mins > 0 ? "$(mins)m $(secs)s" : "$(secs)s"
                on_progress("⏳ $tool_name still running ($elapsed_str elapsed, no output for " *
                            "$(round(Int, silence))s).")
                last_keepalive = now
            end

            # Bail immediately if the session disconnected while we were waiting
            if !isopen(my_inbox) || conn.status == :disconnected
                return "Error: Session disconnected during tool call. The process may have exited or been restarted."
            end

            # Block for the next tool message (event-driven; tool_progress streams with low
            # latency), but wake no later than the next silence/keepalive/ceiling checkpoint so
            # the periodic logic above still runs. Disconnect closes my_inbox → wakes us → the
            # guard above returns the error.
            wake = min(last_activity + silence_budget, hard_deadline)
            if on_progress !== nothing
                wake = min(wake, max(last_activity + silence_threshold,
                                     last_keepalive + keepalive_interval))
            end
            msg = _await_inbox(my_inbox, wake)

            msg === nothing && continue

            # Any frame counts as activity — this is what keeps a progress-reporting tool alive
            last_activity = time()

            ch = string(get(msg, :channel, ""))
            data = string(get(msg, :data, ""))

            if ch == "tool_progress"
                on_progress !== nothing && on_progress(data)
            elseif ch == "tool_complete"
                conn.tool_call_count += 1
                return data
            elseif ch == "tool_error"
                conn.tool_call_count += 1
                return "Error: $data"
            end
        end
    finally
        lock(conn._eval_inboxes_lock) do
            delete!(conn._eval_inboxes, request_id)
        end
    end
end

"""
    _create_session_tools(conn::REPLConnection) -> Vector{MCPTool}

Create MCPTool wrappers for all session-scoped tools declared by a gate session.
Tool names are namespaced by the connection's namespace: `<namespace>.<tool_name>`.
"""
function _create_session_tools(conn::REPLConnection)::Vector{MCPTool}
    tools = MCPTool[]
    prefix = conn.namespace

    for tool_meta in conn.session_tools
        raw_name = get(tool_meta, "name", "")
        isempty(raw_name) && continue

        tool_name = "$(prefix).$(raw_name)"
        tool_id = Symbol(replace(tool_name, "." => "_"))
        description = get(tool_meta, "description", "Session tool: $raw_name")
        schema = _reflect_to_schema(tool_meta)

        # Capture raw_name, conn, and the tool's declared silence budget in the closure
        local_name = raw_name
        local_conn = conn
        local_timeout = _declared_timeout_ms(tool_meta)

        # Advertise the budget in the DESCRIPTION so the agent knows what it's working with — it
        # decides whether to expect this call to outlive its budget, rather than discovering the
        # wall by hitting it. There is deliberately no caller-facing override: a tool whose work
        # can outrun its budget should report progress or promote to a background job, both of
        # which serve the agent better than asking it to predict a duration.
        if local_timeout !== nothing
            description = rstrip(description) * "\n\nThis tool may run up to " *
                          "$(round(_session_tool_silence_s(local_timeout), digits = 1))s without " *
                          "producing output before the call is abandoned (the limit is on SILENCE " *
                          "— each progress update resets it — and the work continues on the " *
                          "session regardless)."
        end
        handler = function (args)
            on_progress = pop!(args, "_on_progress", nothing)
            if on_progress !== nothing
                _call_session_tool_async(
                    local_conn,
                    local_name,
                    args;
                    timeout_ms = local_timeout,
                    on_progress = on_progress,
                )
            else
                _call_session_tool(local_conn, local_name, args; timeout_ms = local_timeout)
            end
        end

        tool_title = get(tool_meta, "title", join(titlecase.(split(raw_name, "_")), " "))
        # A `__`-prefixed gate tool is an internal worker tool: an intermediary
        # session relays to it behind the scenes, so it stays registered and
        # callable but is kept off the agent's tools/list by default.
        hidden = startswith(raw_name, "__")
        push!(
            tools,
            MCPTool(tool_id, tool_name, tool_title, description, schema, handler, hidden),
        )
    end

    return tools
end

"""
    _resolve_namespace!(conn, mgr) -> String

Resolve namespace collisions. If another connected session already owns the
same namespace prefix, add a dedup suffix (_2, _3, …). Updates `conn.namespace`
in place and returns the final namespace.

Extension sessions (spawned_by="extension") are singletons by namespace:
when a new extension claims a namespace already held by a stale extension
connection, the old connection is evicted instead of deduplicating.
"""
function _resolve_namespace!(conn::REPLConnection, mgr::ConnectionManager)
    base_ns = conn.namespace
    isempty(base_ns) && return base_ns

    # Find colliding connections
    colliders = lock(mgr.lock) do
        [
            c for c in mgr.connections if
            c !== conn && c.namespace == base_ns && c.status in (:connected, :evaluating, :stalled, :connecting)
        ]
    end

    # Extension sessions are singletons — evict ALL old extension connections
    # with the same namespace (any status) instead of deduplicating.
    # Must check all statuses because the old connection may have been marked
    # :disconnected by the health checker before the new one resolves its namespace.
    if is_extension(conn)
        lock(mgr.lock) do
            to_evict = [
                c for c in mgr.connections if
                c !== conn && is_extension(c) && c.namespace == base_ns
            ]
            for old in to_evict
                _push_log!(:info, "Evicting stale extension connection: $(base_ns) $(short_key(old)) → $(short_key(conn))")
                _unregister_session_tools!(old)
                disconnect!(old)
                idx = findfirst(c -> c === old, mgr.connections)
                if idx !== nothing
                    _remove_session_files(mgr.sock_dir, old.session_id)
                    deleteat!(mgr.connections, idx)
                end
            end
        end
        _fire_sessions_changed(mgr)
        return base_ns
    end

    # No active collisions for non-extension sessions — keep the namespace
    if isempty(colliders)
        return base_ns
    end

    # Non-extension collision — add dedup suffix
    taken = lock(mgr.lock) do
        Set(
            c.namespace for c in mgr.connections if
            c !== conn && c.status in (:connected, :evaluating) && !isempty(c.namespace)
        )
    end
    n = 2
    candidate = "$(base_ns)_$n"
    while candidate in taken
        n += 1
        candidate = "$(base_ns)_$n"
    end
    conn.namespace = candidate
    @debug "Namespace collision resolved" original = base_ns resolved = candidate
    return candidate
end

"""
    _register_session_tools!(conn::REPLConnection)

Create MCPTool wrappers for session tools and register them in the global
tool registry. Sends `tools/list_changed` notification.
"""
function _register_session_tools!(conn::REPLConnection)
    isempty(conn.session_tools) && return

    session_mcp_tools = _create_session_tools(conn)
    isempty(session_mcp_tools) && return

    _register_dynamic_tools!(session_mcp_tools)
    @debug "Registered session tools" session = short_key(conn) namespace = conn.namespace count =
        length(session_mcp_tools)
end

"""
    _unregister_session_tools!(conn::REPLConnection)

Remove all MCPTool wrappers for a session from the global tool registry.
Sends `tools/list_changed` notification.
"""
function _unregister_session_tools!(conn::REPLConnection)
    isempty(conn.session_tools) && return
    prefix = "$(conn.namespace)."
    _unregister_dynamic_tools!(prefix)
    @debug "Unregistered session tools" session = short_key(conn) namespace = conn.namespace
end

# ── ACPClientBackend ──────────────────────────────────────────────────────────
# Drives any agent that speaks the Agent Client Protocol over stdio: opencode
# (`opencode acp`), Gemini CLI, Codex, Copilot CLI. One adapter, N agents.
#
# The shape differs from ClaudeBackend in one way that matters. Claude's
# stream-JSON is a one-way firehose: we write turns and read events. ACP is
# JSON-RPC, so the agent calls back mid-turn — for permission, to read a file —
# and a client that doesn't answer leaves the turn wedged forever. This is a
# peer, not a reader, and `_handle_request!` is the half that makes turns finish.
#
# Two measured notes on opencode specifically, from dev/acp:
#   * It never calls back. It does its own file I/O and ignores the client's
#     declared fs capabilities, so `session/request_permission` never fires and
#     tool policy has to be enforced by the bridge plugin instead.
#   * `rawInput` arrives whole on the first update rather than streaming, so
#     there is nothing to map onto ACP.ToolInputDelta.

import JSON

# Model strings routed here: "acp:<agent>[:<model>]". The separator is a colon
# rather than a slash because agents' own model ids contain slashes —
# "acp:opencode:opencode/minimax-m3" has to keep the provider prefix intact.
const ACP_PREFIX = "acp:"

"""
Known ACP agents → the argv that starts them in ACP mode.

`claude` is Claude Code itself, through the official adapter. It matters more than one more entry
in a table: once Claude Code is reachable over ACP it is a Kaimon-owned agent like any other, with
an id that can be SENT to. An orchestrator that is merely talking to Kaimon over MCP cannot be
pushed at — it has to poll — whereas one that is spawned here can be handed a turn the moment a
specialist asks it something. That is the difference between agents that interact and agents that
take turns checking on each other.
"""
const ACP_AGENTS = Dict{String,Vector{String}}(
    "opencode" => ["opencode", "acp"],
    "gemini"   => ["gemini", "--experimental-acp"],
    "claude"   => ["claude-agent-acp"],
)

"Split \"acp:opencode:opencode/minimax-m3\" into its argv and model."
function _parse_acp_model(model::AbstractString)
    rest = chop(String(model); head = length(ACP_PREFIX), tail = 0)
    i = findfirst(':', rest)
    agent, mdl = i === nothing ? (rest, "") : (rest[1:i-1], rest[i+1:end])
    argv = get(ACP_AGENTS, agent, nothing)
    argv === nothing && throw(ArgumentError(
        "unknown ACP agent '$agent' — known: $(join(sort(collect(keys(ACP_AGENTS))), ", "))"))
    (argv, String(mdl))
end

"Bridge plugin shipped with the package; copied into each session's config dir."
_acp_plugin_dir() = get(ENV, "KAIMON_ACP_PLUGIN_DIR",
                        normpath(joinpath(@__DIR__, "assets", "acp")))


"""
    ACPClientBackend(; argv, model, system_prompt, permission, mcp_servers, config_dir)

`argv` is the agent command (default `opencode acp`). `model` is passed through
the generated per-session config rather than over the wire: ACP has no model
parameter on `session/new`, and giving each session its own config directory is
also what lets two notebooks run under different permission presets at once.
"""
Base.@kwdef struct ACPClientBackend <: AgentBackend
    argv::Vector{String} = ["opencode", "acp"]
    model::String = ""
    system_prompt::Union{String,Nothing} = nothing
    permission::String = "default"                       # preset, enforced by the bridge plugin
    permission_mode::String = ""                         # "plan" maps onto the agent's own plan mode
    disallowed_tools::Vector{String} = copy(AGENT_SELF_TOOLS)
    # Empty = no allowlist, i.e. whatever the preset permits. Non-empty makes this agent a
    # SPECIALIST: the listed tools are the whole of its world and everything else is refused,
    # whatever the preset would otherwise allow. Enforced here rather than dropped, because an
    # allowlist that silently does nothing is worse than one that isn't offered.
    allowed_tools::Vector{String} = String[]
    mcp_servers::Vector{Any} = Any[]                     # passed to session/new
    plugin_dir::Union{String,Nothing} = nothing          # bridge plugin source, copied per session
    allow_writes::Bool = true                            # client fs capability we advertise
end

mutable struct ACPHandle <: AgentHandle
    backend::ACPClientBackend
    proc::Base.Process
    in::IO
    out::IO
    events::Channel{ACP.AgentEvent}
    reader::Task
    turn::Base.RefValue{Int}
    session_id::Base.RefValue{String}
    next_id::Base.RefValue{Int}
    pending::Dict{Int,Channel{Any}}
    cwd::String
    config_dir::String
    log_file::String
    agent_id::String
    last_cost::Base.RefValue{Union{Float64,Nothing}}   # newest usage_update cost, folded into TurnEnded
    msg_buf::Vector{String}       # streamed assistant text, replayed as one authoritative chunk
    think_buf::Vector{String}     # same for reasoning
    # What the agent said it can do, from `initialize` (plus the `session/new` reply under
    # "session"). Kept because capability differs per agent and guessing means assuming the least.
    caps::Dict{String,Any}
    lk::ReentrantLock
end

backend_status(h::ACPHandle) = Base.process_running(h.proc) ? :alive : :dead
backend_pid(h::ACPHandle) = getpid(h.proc)
backend_session_id(h::ACPHandle) = h.session_id[]

# ── bridge policy ─────────────────────────────────────────────────────────────
# The plugin could decide locally from an env var, but only Julia has the real
# matcher: allow/deny entries come in three forms (bare `ex`, qualified
# `mcp__kaimon__ex`, server-prefix `mcp__kaimon`) and an exact-match Set in JS
# silently fails to block any of them. So the decision lives here and the plugin
# asks. One token per agent, so a decision is attributable and a stray process
# on the same box can't vote.

const ACP_BRIDGE_TOKENS = Dict{String,String}()
const ACP_BRIDGE_LOCK = ReentrantLock()

# Tool names that mutate state, used only when policy can't be resolved.
const ACP_MUTATING_TOOLS = ("write", "edit", "patch", "bash", "shell", "run", "delete", "move")

_acp_register_token!(agent_id::AbstractString) = lock(ACP_BRIDGE_LOCK) do
    ACP_BRIDGE_TOKENS[String(agent_id)] = string(rand(UInt128); base = 16)
end
_acp_forget_token!(agent_id::AbstractString) = lock(ACP_BRIDGE_LOCK) do
    delete!(ACP_BRIDGE_TOKENS, String(agent_id))
end
_acp_token(agent_id::AbstractString) = lock(ACP_BRIDGE_LOCK) do
    get(ACP_BRIDGE_TOKENS, String(agent_id), "")
end

"""
    _acp_mcp_servers(agent_id) -> Vector

The `session/new` equivalent of `_agent_mcp_config`: point the agent at this
Kaimon over HTTP, tagged with its id so tool calls stay attributable. ACP takes
headers as a list of `{name, value}` pairs, not the object shape claude's
`--mcp-config` uses. Empty when the server port isn't up yet — the agent then
runs with its own tools only, rather than failing to start.
"""
function _acp_mcp_servers(agent_id::AbstractString)
    port = MCP_SERVER_PORT[]
    port == 0 && return Any[]
    headers = Any[Dict("name" => "X-Kaimon-Agent-Id", "value" => String(agent_id))]
    key = try; _get_api_key(); catch; nothing; end
    key === nothing || push!(headers, Dict("name" => "Authorization", "value" => "Bearer $key"))
    Any[Dict("type" => "http", "name" => "kaimon",
             "url" => "http://localhost:$port/mcp", "headers" => headers)]
end

"""
    acp_bridge_decide(agent_id, tool, args) -> Dict

Answer one `tool.execute.before` question from the bridge plugin. The recursion
guard is absolute; presets only widen from there. An unknown agent is refused —
a decision we can't attribute is one we shouldn't make.
"""
function acp_bridge_decide(agent_id::AbstractString, tool::AbstractString, args)
    s = lock(AGENT_SESSIONS_LOCK) do; get(AGENT_SESSIONS, String(agent_id), nothing); end
    s === nothing && return Dict("allow" => false, "why" => "unknown agent")
    b = s.backend
    b isa ACPClientBackend || return Dict("allow" => false, "why" => "not an ACP agent")
    return _acp_decide(b, tool)
end

"Name we register Kaimon's MCP server under, and therefore the prefix its tools carry."
const ACP_MCP_SERVER = "kaimon"

_acp_qualified(n::AbstractString) = occursin(r"^mcp__[A-Za-z0-9_]+__", n)

"""
Split a tool name into `(server, bare)`, with `server === nothing` for a native one.

Two spellings reach us. Allow/deny entries are written claude-style
(`mcp__kaimon__ex`), but opencode names an MCP tool `<server>_<tool>` — measured:
it called Kaimon's `ping` as `kaimon_ping`. Without folding both to the same
`(server, bare)` pair the recursion guard misses entirely, and an agent with
Kaimon attached can call `kaimon_agent_open` and spawn agents recursively.
"""
function _acp_split_tool(n::AbstractString)
    m = match(r"^mcp__([A-Za-z0-9_]+?)__(.+)$", String(n))
    m === nothing || return (String(m.captures[1]), String(m.captures[2]))
    p = ACP_MCP_SERVER * "_"
    startswith(n, p) && return (ACP_MCP_SERVER, String(n)[length(p)+1:end])
    return (nothing, String(n))
end

"""
Match a tool name against one allow/deny entry, ACP-style.

`_tool_name_matches` can't be reused here. It treats a bare name as implicitly
belonging to the Kaimon server, which holds for OllamaBackend — there every tool
is a Kaimon MCP tool — but not for an ACP agent, whose own built-ins (`write`,
`read`, `bash`) sit alongside any MCP tools. Under that rule a `mcp__kaimon`
server-prefix entry matches `write`, and the recursion guard silently disables
the agent's whole native toolset. So a server prefix here matches only names
actually qualified with that server.
"""
function _acp_tool_matches(name::AbstractString, entry::AbstractString)
    n, e = String(name), String(entry)
    n == e && return true
    nserver, nbare = _acp_split_tool(n)
    # A server-prefix entry ("mcp__kaimon", no tool part) covers every tool from
    # that server and nothing else — notably not the agent's own built-ins.
    if startswith(e, "mcp__") && !_acp_qualified(e)
        return nserver == e[length("mcp__")+1:end]
    end
    eserver, ebare = _acp_split_tool(e)
    nbare == ebare || return false
    # A bare entry matches the tool whatever server it came from; a qualified one
    # only matches that server's copy.
    return eserver === nothing || nserver === nothing || nserver == eserver
end

"The policy itself, split out from the session lookup so it can be tested directly."
function _acp_decide(b::ACPClientBackend, tool::AbstractString)
    bare = _bare_tool(tool)
    for entry in b.disallowed_tools
        _acp_tool_matches(tool, entry) && return Dict("allow" => false, "why" => "denied by policy")
    end
    # Before the preset, not after: a specialist's allowlist has to out-rank a permissive preset,
    # or "default"/"lab" would wave through the very tools it was drawn up to exclude.
    if !isempty(b.allowed_tools) && !any(e -> _acp_tool_matches(tool, e), b.allowed_tools)
        return Dict("allow" => false, "why" => "not in this agent's allowlist")
    end

    preset = lowercase(b.permission)
    preset in ("bypass", "lab", "default") && return Dict("allow" => true)
    if preset == "auto"
        # `auto` means the agent's own classifier governs. ACP gives us no way to
        # consult it, so rather than inventing a second classifier here, refuse
        # the mutating tools and let everything else through.
        return bare in ACP_MUTATING_TOOLS ?
            Dict("allow" => false, "why" => "auto preset cannot consult a classifier over ACP") :
            Dict("allow" => true)
    end
    # An unrecognized preset is a typo, and a typo used to mean "allow everything" — the one
    # direction a policy must never fail in. Refuse, and say which name was not understood.
    return Dict("allow" => false, "why" => "unknown permission preset '$(b.permission)'")
end

# ── JSON-RPC plumbing ─────────────────────────────────────────────────────────

function _rpc_write!(h::ACPHandle, obj::AbstractDict)
    lock(h.lk) do
        write(h.in, JSON.json(obj), "\n")
        flush(h.in)
    end
    nothing
end

"Send a request and block until the matching response arrives."
function _rpc_call!(h::ACPHandle, method::AbstractString, params; timeout::Real = 600)
    id, ch = lock(h.lk) do
        h.next_id[] += 1
        c = Channel{Any}(1)
        h.pending[h.next_id[]] = c
        (h.next_id[], c)
    end
    _rpc_write!(h, Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    reply = nothing
    timer = Timer(timeout) do _
        isready(ch) || (isopen(ch) && close(ch))
    end
    try
        reply = take!(ch)
    catch
        throw(ErrorException("ACP $method timed out or the agent went away"))
    finally
        close(timer)
        lock(h.lk) do; delete!(h.pending, id); end
    end
    haskey(reply, "error") && error("ACP $method failed: $(JSON.json(reply["error"]))")
    return get(reply, "result", nothing)
end

_rpc_respond!(h::ACPHandle, id, result) =
    _rpc_write!(h, Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
_rpc_error!(h::ACPHandle, id, code::Int, msg::AbstractString) =
    _rpc_write!(h, Dict("jsonrpc" => "2.0", "id" => id,
                        "error" => Dict("code" => code, "message" => msg)))

# ── agent → client requests ───────────────────────────────────────────────────

"Least destructive option the agent offered, preferring a one-shot allow."
function _pick_permission(options)
    options isa AbstractVector && !isempty(options) || return nothing
    for want in ("allow_once", "allow_always"), o in options
        o isa AbstractDict && get(o, "kind", "") == want && return get(o, "optionId", nothing)
    end
    # No option says it allows anything, so there is nothing here to choose. Taking the first one
    # by position picked whatever the agent happened to list first, which for an agent that leads
    # with its reject option meant silently rejecting every request. Answer `cancelled` instead:
    # the caller turns that into an explicit outcome rather than a decision nobody made.
    return nothing
end

"""
Largest whole-file read served to an agent over `fs/read_text_file`.

A cap rather than no cap: the call names a path and gets the file, and an agent that asks for
something enormous should get an error it can act on instead of this process growing to match.
ACP applies the same idea to terminal output through `outputByteLimit`.
"""
const ACP_READ_CAP = 8 * 1024 * 1024

function _acp_read_capped(path::AbstractString)
    sz = try; filesize(path); catch; 0; end
    sz > ACP_READ_CAP && throw(ArgumentError(
        "file is $(sz) bytes, over the $(ACP_READ_CAP) byte read limit; ask for a line range"))
    return read(path, String)
end

"""
    acp_capabilities(h) -> Dict

What the agent said it can do at `initialize`, plus the `session/new` reply under `"session"`.
"""
acp_capabilities(h::ACPHandle) = h.caps

"""
Does this agent QUEUE a prompt sent while a turn is running?

Queueing is read as SERIALISING: the queued prompt does not begin streaming until the running turn
has finished and its `session/prompt` has answered. Everything downstream depends on that, because
`session/update` carries a session id and no turn id — if two turns ever streamed at once their
chunks would be indistinguishable and neither message could be reconstructed. The protocol does
not promise serialisation, so an agent that advertised queueing and meant concurrency would break
the reassembly rather than merely surprise it.

Asked rather than assumed. An agent that cannot queue loses the reply in progress when a second
prompt arrives, so a caller has to hold the message back; one that can queue takes it immediately,
and holding it back is a limitation borrowed from a different agent. The capability is on the wire
at `initialize`, and answering "no" for everything is what discarding the handshake amounted to.
"""
function acp_queues_prompts(h::ACPHandle)
    caps = get(h.caps, "agentCapabilities", nothing)
    caps isa AbstractDict || return false
    meta = get(caps, "_meta", nothing)
    meta isa AbstractDict || return false
    cc = get(meta, "claudeCode", nothing)
    cc isa AbstractDict || return false
    return get(cc, "promptQueueing", false) === true
end

"""
Resolve a path the agent asked for, and refuse it unless it is inside the session's `cwd`.

The fs callbacks are a second door into this process, and they used to open straight onto the
filesystem: a bare `read`, and a `write` gated only by one all-or-nothing flag. An agent summoned
with a seven-verb allowlist could still read `~/.ssh/id_rsa`, because these calls never went near
the policy. That is the same shape as the allowlist bug this file already fixed once — a
restriction that appears to constrain and does not — and it made a system prompt saying "you
cannot edit files" untrue.

Resolution happens BEFORE the check and follows symlinks, so a link inside the workspace cannot
be used to step outside it. A path that does not exist yet is resolved through its nearest
existing parent, because a write to a new file is legitimate. The resolved path is what the caller
then opens, so a lexical `..` cannot mean one thing here and another to the OS.

WHAT THIS IS NOT. It is a correctness boundary against a cooperative agent, not a sandbox against
a hostile one, and two gaps are inherent rather than oversights:

  * The check and the open are separate steps, and an agent doing its own file I/O can replace a
    component with a symlink in between. Closing that needs `openat`/`O_NOFOLLOW` walked component
    by component, which is a great deal of machinery for a threat model where the agent is trusted
    to run in this workspace at all.
  * A hard link inside the workspace pointing at a file outside it resolves to an inside path, so
    containment passes and the outside content is read. No path-based check can see this.

An agent that would exploit either is one that should not have been summoned.
"""
function _acp_confine(h::ACPHandle, path::AbstractString)
    isempty(path) && throw(ArgumentError("no path given"))
    root = try; realpath(h.cwd); catch; abspath(h.cwd); end
    p = abspath(isabspath(path) ? String(path) : joinpath(root, String(path)))
    # Resolve as far as the filesystem knows, then re-attach the part that doesn't exist yet.
    probe, rest = p, String[]
    while !ispath(probe)
        parent = dirname(probe)
        parent == probe && break
        pushfirst!(rest, basename(probe))
        probe = parent
    end
    resolved = try; realpath(probe); catch; probe; end
    full = isempty(rest) ? resolved : joinpath(resolved, rest...)
    (full == root || startswith(full, root * "/")) ||
        throw(ArgumentError("path is outside this agent's workspace: $path"))
    return full
end

"""
Emit whatever a client request should put on the event stream, ON the reader task.

Ordering is the reason this is separate from `_handle_request!`. That runs on its own task now, so
an event emitted inside it can be overtaken by later `session/update` lines the reader is still
consuming: a permission prompt could arrive after the tool-call update that already resolved it.
Announcing here keeps every event in wire order, and costs the reader nothing, because this does
no I/O. The work that can block stays off-task.
"""
function _announce_request!(h::ACPHandle, id, method::AbstractString, params)
    method == "session/request_permission" || return nothing
    params = params isa AbstractDict ? params : Dict{String,Any}()
    opts = get(params, "options", Any[])
    put!(h.events, ACP.PermissionRequested(
        ACP.ToolCallUpdate(; tool_call_id = String(get(get(params, "toolCall", Dict()), "toolCallId", ""))),
        ACP.PermissionOption[
            ACP.PermissionOption(String(get(o, "optionId", "")), String(get(o, "name", "")),
                                 ACP.as_enum(get(o, "kind", ""), ACP.PERMISSION_KINDS, :allow_once))
            for o in opts if o isa AbstractDict],
        string(id)))
    return nothing
end

function _handle_request!(h::ACPHandle, id, method::AbstractString, params)
    params = params isa AbstractDict ? params : Dict{String,Any}()

    if method == "session/request_permission"
        # The event was ANNOUNCED on the reader (see `_announce_request!`); this half only
        # decides and answers. Blocking on a human here would hang every headless turn.
        opts = get(params, "options", Any[])
        opt = _pick_permission(opts)
        _rpc_respond!(h, id, opt === nothing ?
            Dict("outcome" => Dict("outcome" => "cancelled")) :
            Dict("outcome" => Dict("outcome" => "selected", "optionId" => opt)))

    elseif method == "fs/read_text_file"
        try
            # Policy first, then the workspace boundary. The allowlist names it `fs/read_text_file`
            # so a specialist's toolset can exclude reading outright, not merely reading elsewhere.
            d = _acp_decide(h.backend, "fs/read_text_file")
            get(d, "allow", false) === true ||
                return _rpc_error!(h, id, -32000, String(get(d, "why", "denied by policy")))
            path = _acp_confine(h, String(get(params, "path", "")))
            content = if haskey(params, "line") || haskey(params, "limit")
                # Read only as far as the requested window. Slicing AFTER a whole-file read meant
                # `limit: 10` still pulled a multi-gigabyte file into memory to throw nearly all
                # of it away.
                from = max(1, Int(get(params, "line", 1)))
                n = Int(get(params, "limit", typemax(Int)))
                want = String[]
                open(path, "r") do io
                    for (i, ln) in enumerate(eachline(io))
                        i < from && continue
                        length(want) >= n && break
                        push!(want, ln)
                    end
                end
                join(want, '\n')
            else
                _acp_read_capped(path)
            end
            _rpc_respond!(h, id, Dict("content" => content))
        catch e
            _rpc_error!(h, id, -32000, sprint(showerror, e))
        end

    elseif method == "fs/write_text_file"
        d = _acp_decide(h.backend, "fs/write_text_file")
        if !h.backend.allow_writes
            _rpc_error!(h, id, -32000, "client denied write to $(get(params, "path", "?"))")
        elseif get(d, "allow", false) !== true
            _rpc_error!(h, id, -32000, String(get(d, "why", "denied by policy")))
        else
            try
                # Confined before anything is created: `mkpath` on an unchecked path would build
                # directories outside the workspace even when the write itself then failed.
                path = _acp_confine(h, String(get(params, "path", "")))
                mkpath(dirname(path))
                write(path, String(get(params, "content", "")))
                _rpc_respond!(h, id, nothing)
            catch e
                _rpc_error!(h, id, -32000, sprint(showerror, e))
            end
        end

    else
        _rpc_error!(h, id, -32601, "unsupported client method $method")
    end
    nothing
end

# ── session/update → ACP.AgentEvent ───────────────────────────────────────────

"""
Map one ACP content block onto its type.

Every variant the spec defines is constructed. Falling through to `TextBlock(get(c,"text",""))`
turned a resource, a link or an audio block into an EMPTY text block, so the content vanished with
nothing to show it had been sent. An unrecognized type keeps its payload as text rather than
discarding it.
"""
function _content_block(c)
    c isa AbstractDict || return ACP.TextBlock(c === nothing ? "" : string(c))
    t = String(get(c, "type", "text"))
    if t == "text"
        return ACP.TextBlock(String(get(c, "text", "")))
    elseif t == "image"
        return ACP.ImageBlock(String(get(c, "data", "")), String(get(c, "mimeType", "image/png")),
                              get(c, "uri", nothing))
    elseif t == "audio"
        return ACP.AudioBlock(String(get(c, "data", "")), String(get(c, "mimeType", "audio/wav")))
    elseif t == "resource_link"
        return ACP.ResourceLinkBlock(String(get(c, "uri", "")), get(c, "name", nothing),
                                     get(c, "mimeType", nothing))
    elseif t == "resource"
        r = get(c, "resource", Dict{String,Any}())
        r isa AbstractDict || (r = Dict{String,Any}())
        return ACP.ResourceBlock(String(get(r, "uri", "")),
                                 get(r, "text", nothing), get(r, "blob", nothing),
                                 get(r, "mimeType", nothing))
    end
    return ACP.TextBlock(String(get(c, "text", isempty(c) ? "" : JSON.json(c))))
end

_locations(v) = v isa AbstractVector ?
    [ACP.ToolCallLocation(String(get(l, "path", "")),
                          haskey(l, "line") ? Int(l["line"]) : nothing)
     for l in v if l isa AbstractDict] : ACP.ToolCallLocation[]

function _tool_content(v)
    v isa AbstractVector || return ACP.ToolCallContent[]
    out = ACP.ToolCallContent[]
    for c in v
        c isa AbstractDict || continue
        if get(c, "type", "") == "diff"
            push!(out, ACP.DiffToolContent(String(get(c, "path", "")),
                                           get(c, "oldText", nothing),
                                           String(get(c, "newText", ""))))
        else
            push!(out, ACP.ContentToolContent(_content_block(get(c, "content", c))))
        end
    end
    out
end

"""
Per-turn usage, from the `session/prompt` response — the only place opencode
reports a real input/output split (the `usage_update` notification carries
cumulative context instead). Reasoning tokens are billed like output, so they
are counted there. `cost` is carried over from the last `usage_update`, which is
the only frame that has it.
"""
function _acp_turn_usage(u, cost::Union{Float64,Nothing} = nothing)
    u isa AbstractDict || return cost === nothing ? nothing : ACP.Usage(; cost_usd = cost)
    ACP.Usage(; input_tokens = Int(get(u, "inputTokens", 0)),
                output_tokens = Int(get(u, "outputTokens", 0)) + Int(get(u, "thoughtTokens", 0)),
                cache_read_tokens = Int(get(u, "cachedReadTokens", 0)),
                cost_usd = cost)
end

# Updates we knowingly drop: they carry no information an AgentEvent models.
# `current_mode_update` is NOT ignored: it is how an agent reports it changed its own mode, and
# `permission_mode` (notably "plan") is enforced by the agent rather than by us. Silently dropping
# it meant plan mode could lapse with nothing anywhere saying so. Handled below.
const ACP_IGNORED_UPDATES = ("available_commands_update", "usage_update")

function _map_acp_update(upd)::Vector{ACP.AgentEvent}
    upd isa AbstractDict || return ACP.AgentEvent[]
    kind = String(get(upd, "sessionUpdate", ""))
    out = ACP.AgentEvent[]

    if kind == "agent_message_chunk"
        push!(out, ACP.AgentMessageChunk(_content_block(get(upd, "content", nothing)), true))
    elseif kind == "agent_thought_chunk"
        push!(out, ACP.AgentThoughtChunk(_content_block(get(upd, "content", nothing)), true))
    elseif kind == "user_message_chunk"
        push!(out, ACP.UserMessageChunk(_content_block(get(upd, "content", nothing))))
    elseif kind == "tool_call"
        push!(out, ACP.ToolCallStarted(ACP.ToolCall(;
            tool_call_id = String(get(upd, "toolCallId", "")),
            title = String(get(upd, "title", "")),
            kind = ACP.as_enum(get(upd, "kind", ""), ACP.TOOL_KINDS, :other),
            status = ACP.as_enum(get(upd, "status", ""), ACP.TOOL_CALL_STATUSES, :pending),
            content = _tool_content(get(upd, "content", nothing)),
            locations = _locations(get(upd, "locations", nothing)),
            raw_input = get(upd, "rawInput", nothing),
            raw_output = get(upd, "rawOutput", nothing))))
    elseif kind == "tool_call_update"
        push!(out, ACP.ToolCallUpdated(ACP.ToolCallUpdate(;
            tool_call_id = String(get(upd, "toolCallId", "")),
            title = haskey(upd, "title") ? String(upd["title"]) : nothing,
            kind = haskey(upd, "kind") ? ACP.as_enum(upd["kind"], ACP.TOOL_KINDS, :other) : nothing,
            status = haskey(upd, "status") ? ACP.as_enum(upd["status"], ACP.TOOL_CALL_STATUSES, :pending) : nothing,
            content = haskey(upd, "content") ? _tool_content(upd["content"]) : nothing,
            locations = haskey(upd, "locations") ? _locations(upd["locations"]) : nothing,
            raw_input = get(upd, "rawInput", nothing),
            raw_output = get(upd, "rawOutput", nothing))))
    elseif kind == "current_mode_update"
        # The agent enforces its own mode, so a change here can quietly undo what was asked for at
        # spawn. Surfaced rather than mapped to an event: the consumers read a fixed set of event
        # kinds, and a mode is worth knowing about without inventing one for them to learn.
        @info "ACP agent changed mode" mode = String(get(upd, "currentModeId", "?"))
    elseif kind == "plan"
        entries = get(upd, "entries", Any[])
        push!(out, ACP.PlanUpdated([
            ACP.PlanEntry(String(get(e, "content", "")),
                          ACP.as_enum(get(e, "priority", ""), ACP.PLAN_PRIORITIES, :medium),
                          ACP.as_enum(get(e, "status", ""), ACP.PLAN_STATUSES, :pending))
            for e in entries if e isa AbstractDict]))
    elseif !(kind in ACP_IGNORED_UPDATES)
        push!(out, ACP.AgentError("unmapped session/update: $kind", upd))
    end
    out
end

# ── reader ────────────────────────────────────────────────────────────────────

_txt_of(c) = c isa ACP.TextBlock ? c.text : ""

"""
Replay the turn's streamed text as one authoritative (`delta=false`) chunk.

Claude's stream-JSON emits deltas AND a final complete block; ACP emits deltas
only. Everything downstream that reconstructs a message — `agent_run`'s waiter,
the JSONL event log, the TUI ring buffer — reads the non-delta copy and ignores
deltas, so without this the assistant's reply is invisible to all three and
`agent_run` returns an empty string.
"""
function _authoritative_events(msg::AbstractString, think::AbstractString)
    out = ACP.AgentEvent[]
    isempty(strip(think)) || push!(out, ACP.AgentThoughtChunk(ACP.TextBlock(String(think)), false))
    isempty(strip(msg)) || push!(out, ACP.AgentMessageChunk(ACP.TextBlock(String(msg)), false))
    out
end

function _flush_authoritative!(h::ACPHandle)
    msg, think = lock(h.lk) do
        m, t = join(h.msg_buf), join(h.think_buf)
        empty!(h.msg_buf); empty!(h.think_buf)
        (m, t)
    end
    for ev in _authoritative_events(msg, think)
        put!(h.events, ev)
    end
    nothing
end

function _start_acp_reader!(h::ACPHandle, log_io::IO)
    @async begin
        try
            for line in eachline(h.out)
                isempty(strip(line)) && continue
                println(log_io, line); flush(log_io)
                local obj
                try
                    obj = JSON.parse(line)
                catch
                    put!(h.events, ACP.AgentError("ACP parse error", line))
                    continue
                end
                obj isa AbstractDict || continue

                if haskey(obj, "method") && haskey(obj, "id")
                    # Off the reader, always. Handling a client request inline stalled this loop
                    # for as long as the request took, and the loop is also what delivers every
                    # `_rpc_call!` response — so one slow fs call timed out every call in flight,
                    # and one that never returns (a named pipe inside the workspace, a stalled
                    # network mount) wedged the connection for good. `_rpc_write!` takes the lock,
                    # so replies from several handlers cannot interleave.
                    let rid = obj["id"], meth = String(obj["method"]), prm = get(obj, "params", nothing)
                        # Announce in wire order, serve off-task. Emitting from the spawned half
                        # let later `session/update` events overtake a permission prompt, so a UI
                        # could render it after the tool call it had already resolved.
                        try; _announce_request!(h, rid, meth, prm); catch; end
                        Threads.@spawn try
                            _handle_request!(h, rid, meth, prm)
                        catch e
                            try; _rpc_error!(h, rid, -32000, sprint(showerror, e)); catch; end
                        end
                    end
                elseif haskey(obj, "method")
                    if String(obj["method"]) == "session/update"
                        upd = get(get(obj, "params", Dict()), "update", nothing)
                        # `usage_update` is the only place cost appears, but its token
                        # figure is cumulative context. Keep the cost, drop the event,
                        # and let TurnEnded carry both (see backend_send).
                        if upd isa AbstractDict && get(upd, "sessionUpdate", "") == "usage_update"
                            c = get(upd, "cost", nothing)
                            c isa AbstractDict && (h.last_cost[] = Float64(get(c, "amount", 0.0)))
                        end
                        for ev in _map_acp_update(upd)
                            if ev isa ACP.AgentMessageChunk
                                lock(h.lk) do; push!(h.msg_buf, _txt_of(ev.content)); end
                            elseif ev isa ACP.AgentThoughtChunk
                                lock(h.lk) do; push!(h.think_buf, _txt_of(ev.content)); end
                            end
                            put!(h.events, ev)
                        end
                    end
                elseif haskey(obj, "id")
                    ch = lock(h.lk) do; get(h.pending, obj["id"], nothing); end
                    ch === nothing || (isopen(ch) && put!(ch, obj))
                end
            end
        catch e
            e isa InterruptException || put!(h.events, ACP.AgentError("ACP reader crashed: $(sprint(showerror, e))"))
        finally
            put!(h.events, ACP.StatusChanged(:dead))
            close(h.events)
            try; close(log_io); catch; end
        end
    end
end

# ── per-session config ────────────────────────────────────────────────────────

"""
Give the agent its own config directory: it is how the model gets pinned (ACP has
no model parameter), how the bridge plugin gets loaded, and how two sessions can
run under different tool policies at the same time.
"""
function _acp_session_config(b::ACPClientBackend, dir::AbstractString)
    mkpath(joinpath(dir, "opencode"))
    cfg = Dict{String,Any}("\$schema" => "https://opencode.ai/config.json")
    isempty(b.model) || (cfg["model"] = b.model)
    write(joinpath(dir, "opencode", "opencode.json"), JSON.json(cfg, 2))

    if b.plugin_dir !== nothing && isdir(b.plugin_dir)
        # `plugin/`, singular — `plugins/` is what the docs say and it loads nothing.
        pdir = joinpath(dir, "opencode", "plugin")
        mkpath(pdir)
        for f in readdir(b.plugin_dir)
            endswith(f, ".js") && cp(joinpath(b.plugin_dir, f), joinpath(pdir, f); force = true)
        end
    end
    dir
end

# ── lifecycle ─────────────────────────────────────────────────────────────────

"""
    backend_start(b::ACPClientBackend; cwd, agent_id, parent_pid, bridge_port) -> ACPHandle

Spawn the ACP agent, then complete the `initialize` + `session/new` handshake
before returning — a handle without a session id can't take a turn.
"""
function backend_start(b::ACPClientBackend; cwd::String, agent_id::String,
                       parent_pid::Integer = getpid(), bridge_port::Int = 0)
    isdir(cwd) || throw(ArgumentError("agent cwd does not exist: $cwd"))
    config_dir = _acp_session_config(b, mktempdir(; prefix = "kaimon-acp-"))

    log_dir = joinpath(kaimon_cache_dir(), "agents")
    mkpath(log_dir)
    log_file = joinpath(log_dir, "$(agent_id).log")
    log_io = open(log_file, "a")

    env = copy(ENV)
    env["XDG_CONFIG_HOME"] = config_dir
    env[KAIMON_AGENT_MARKER] = agent_id
    env["KAIMON_PARENT_PID"] = string(parent_pid)
    # The bridge plugin asks Kaimon over the MCP server's own HTTP port — no
    # second listener, and the port is already known here. Falling back to the
    # env-var copy of the policy keeps a turn moving if the server isn't up yet.
    port = bridge_port > 0 ? bridge_port : MCP_SERVER_PORT[]
    port > 0 && (env["KAIMON_BRIDGE_PORT"] = string(port))
    env["KAIMON_BRIDGE_TOKEN"] = _acp_register_token!(agent_id)
    env["KAIMON_AGENT_ID"] = agent_id
    env["KAIMON_AGENT_PERMISSION"] = b.permission
    env["KAIMON_AGENT_DENY_TOOLS"] = join(b.disallowed_tools, ",")
    isempty(b.allowed_tools) || (env["KAIMON_AGENT_ALLOW_TOOLS"] = join(b.allowed_tools, ","))
    b.system_prompt === nothing || (env["KAIMON_AGENT_SYSTEM_PROMPT"] = b.system_prompt)

    args = _spawn_argv(b.argv)
    inp, outp = Pipe(), Pipe()
    proc = try
        run(pipeline(setenv(Cmd(Cmd(args); dir = cwd), env);
                     stdin = inp, stdout = outp, stderr = log_io); wait = false)
    catch e
        try; close(log_io); catch; end
        throw(_agent_spawn_error(e, args))
    end
    close(inp.out); close(outp.in)

    h = ACPHandle(b, proc, inp, outp, Channel{ACP.AgentEvent}(Inf), Task(() -> nothing),
                  Ref(0), Ref(""), Ref(0), Dict{Int,Channel{Any}}(),
                  String(cwd), config_dir, log_file, agent_id,
                  Ref{Union{Float64,Nothing}}(nothing), String[], String[],
                  Dict{String,Any}(), ReentrantLock())
    h.reader = _start_acp_reader!(h, log_io)

    # Handshake. Both calls must land before the handle is usable, so they run
    # here rather than lazily on the first turn.
    #
    # The reply is KEPT. It carries what this agent can actually do, and discarding it meant
    # treating every agent as the least capable one we had met: `prompt_queueing` in particular
    # decides whether a second message during a turn is queued or destroys the reply in progress,
    # and that differs between agents. It is also why setting an option had to be done by trying
    # both method names and catching the failure.
    init = _rpc_call!(h, "initialize", Dict(
        "protocolVersion" => 1,
        "clientCapabilities" => Dict(
            "fs" => Dict("readTextFile" => true, "writeTextFile" => b.allow_writes),
            "terminal" => false)); timeout = 60)
    init isa AbstractDict && merge!(h.caps, Dict{String,Any}(String(k) => v for (k, v) in init))
    sess = _rpc_call!(h, "session/new",
                      Dict("cwd" => abspath(cwd), "mcpServers" => b.mcp_servers); timeout = 120)
    sess isa AbstractDict && (h.caps["session"] = Dict{String,Any}(String(k) => v for (k, v) in sess))
    h.session_id[] = String(get(sess, "sessionId", ""))
    # Plan mode is the agent's own restriction on edit tools; prefer it over the
    # bridge, which can only refuse a call after the model has committed to it.
    lowercase(b.permission_mode) == "plan" && acp_set_mode!(h, "plan")
    h
end

"""
    backend_send(h::ACPHandle, text) -> Int

Send one user turn. `session/prompt` only answers when the turn is over, so the
wait happens on a task: the call returns as soon as the request is on the wire,
and `TurnEnded` reaches the event channel whenever the agent is done.
"""
function backend_send(h::ACPHandle, text::AbstractString)
    Base.process_running(h.proc) || throw(ArgumentError("agent process is not running"))
    turn = (h.turn[] += 1)
    # Clearing the buffers is right for an agent that takes one turn at a time: the send starts a
    # turn, and whatever is in them belongs to the last one. For a QUEUEING agent it is wrong and
    # destructive — the running turn is still streaming into them, and this would discard its text
    # to make room for a turn that has not begun. Queueing is read as serialising (see
    # `acp_queues_prompts`), so each turn's text is flushed at its own prompt response and the
    # buffers are already empty by the time the queued turn starts.
    acp_queues_prompts(h) || lock(h.lk) do; empty!(h.msg_buf); empty!(h.think_buf); end
    put!(h.events, ACP.TurnStarted())
    @async try
        res = _rpc_call!(h, "session/prompt", Dict(
            "sessionId" => h.session_id[],
            "prompt" => [Dict("type" => "text", "text" => String(text))]))
        _flush_authoritative!(h)
        put!(h.events, ACP.TurnEnded(
            ACP.as_enum(get(res, "stopReason", ""), ACP.STOP_REASONS, :end_turn),
            _acp_turn_usage(get(res, "usage", nothing), h.last_cost[])))
    catch e
        isopen(h.events) || return
        put!(h.events, ACP.AgentError("turn failed: $(sprint(showerror, e))"))
        _flush_authoritative!(h)   # a failed turn still has partial text worth keeping
        put!(h.events, ACP.TurnEnded(:refusal, nothing))
    end
    turn
end

# ── live session configuration ────────────────────────────────────────────────
# ClaudeBackend binds model and permission mode at spawn, so changing either means
# reaping the agent and losing the conversation. ACP exposes both as session
# methods, so a picker change can land on the next turn instead.

"""
Try a standard ACP method, then opencode's `session/set_config_option` fallback.

Returns whether either stuck. Both spellings are attempted because the standard
method is the portable one and the fallback is what opencode advertises in the
`configOptions` it returns from `session/new` — an agent implementing only one of
them should still be configurable.
"""
function _acp_set_option!(h::ACPHandle, method::AbstractString, key::AbstractString,
                          param::AbstractString, value::AbstractString)
    isempty(value) && return false
    try
        _rpc_call!(h, method, Dict("sessionId" => h.session_id[], param => value); timeout = 30)
        return true
    catch
    end
    try
        _rpc_call!(h, "session/set_config_option",
                   Dict("sessionId" => h.session_id[], "optionId" => key, "value" => value);
                   timeout = 30)
        return true
    catch e
        put!(h.events, ACP.AgentError("could not set $key=$value: $(sprint(showerror, e))"))
        return false
    end
end

"Switch the model on a live session, keeping its history."
acp_set_model!(h::ACPHandle, model::AbstractString) =
    _acp_set_option!(h, "session/set_model", "model", "modelId", model)

"""
Switch session mode. opencode's `plan` mode disallows every edit tool, which is
what Kaimon's `permission_mode="plan"` means, enforced by the agent itself rather
than by the bridge.
"""
acp_set_mode!(h::ACPHandle, mode::AbstractString) =
    _acp_set_option!(h, "session/set_mode", "mode", "modeId", mode)

function backend_interrupt(h::ACPHandle)
    Base.process_running(h.proc) || return false
    try
        _rpc_write!(h, Dict("jsonrpc" => "2.0", "method" => "session/cancel",
                            "params" => Dict("sessionId" => h.session_id[])))
        true
    catch
        false
    end
end

function backend_close(h::ACPHandle)
    try; close(h.in); catch; end
    if Base.process_running(h.proc)
        try
            kill(h.proc, Base.SIGTERM)
            t0 = time()
            while Base.process_running(h.proc) && time() - t0 < 3.0
                sleep(0.1)
            end
            Base.process_running(h.proc) && kill(h.proc, Base.SIGKILL)
        catch
        end
    end
    _acp_forget_token!(h.agent_id)
    try; rm(h.config_dir; recursive = true, force = true); catch; end
    nothing
end

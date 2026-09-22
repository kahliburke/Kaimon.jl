# ── ACPClientBackend ──────────────────────────────────────────────────────────
# Drives any agent that speaks the Agent Client Protocol over stdio. `ACP_AGENTS` is the
# registered set, and adding one is its argv plus a measurement of what it enforces for itself
# (see `_acp_enforcement_gap`). Codex and Copilot speak ACP and are not registered.
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

`claude` is Claude Code itself, through the official adapter. A Claude spawned here is a
Kaimon-owned agent with an id, so `agent_send` can hand it a turn. A Claude that is only talking
to Kaimon over MCP has no such id and can only poll.
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
Can this agent load the bridge plugin?

Only opencode: the plugin is written against its plugin API and config layout. Any other agent
ignores the generated file, so the preset enforces nothing while still reading as configured.
"""
_acp_plugin_supported(argv::Vector{String}) = !isempty(argv) && basename(first(argv)) == "opencode"

"""
Does the per-session config directory mean anything to this agent?

`_acp_session_config` writes opencode's `opencode.json` and points `XDG_CONFIG_HOME` at it, which
is also how the model gets chosen. An agent that reads neither runs its own default model, so the
requested one has to be set over the wire instead.
"""
_acp_config_supported(argv::Vector{String}) = _acp_plugin_supported(argv)


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
    # The caller's own allowlist. Non-empty makes this agent a specialist: the listed tools are
    # the whole of its world, and anything else is refused even if the preset would permit it.
    # Must stay separate from `preset_tools`, since merging them makes every preset-carrying
    # agent look like a specialist whose allowlist happens to be wide.
    allowed_tools::Vector{String} = String[]
    # What the preset permits. Consulted only when `allowed_tools` is empty.
    preset_tools::Vector{String} = String[]
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
    # toolCallId → the paths that call named, learned from its `tool_call` update.
    #
    # A permission request is allowed to carry a bare toolCall: `rawInput` and `locations` are
    # optional in the schema, and claude-agent-acp sends the minimal form. But the call and its
    # first update arrive BEFORE the permission request that names the same id, and those do carry
    # the path. So the path is on the wire; it is just not on the message that asks.
    tool_paths::Dict{String,Vector{String}}
    # Ids in the order they were recorded, so the lookaside can evict its oldest entry instead of
    # emptying itself. Wiping it drops the paths of calls still waiting to be asked about, and a
    # call whose paths cannot be found is allowed — so the workspace boundary stopped applying at
    # the point the cap was reached.
    tool_order::Vector{String}
    # Tool calls seen started and not yet seen finish. Cancelling a turn stops the agent without
    # it retracting them, so they would otherwise stay spinning in the UI forever.
    open_tools::Vector{String}
    # When the agent last said anything at all. A prompt waits without a deadline, so this is the
    # only way to tell a long turn from a wedged one.
    last_rx::Base.RefValue{Float64}
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

# From the OS CSPRNG, not the default generator: this token is the only credential on
# `/agent/permission`, which answers yes or no to tool execution and so runs ahead of the API-key
# gate. A token drawn from a seedable generator is one an observer can work back to.
_acp_register_token!(agent_id::AbstractString) = lock(ACP_BRIDGE_LOCK) do
    ACP_BRIDGE_TOKENS[String(agent_id)] = bytes2hex(secret_bytes(32))
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
    d = _acp_decide(b, tool)
    get(d, "allow", false) === true || return d
    # Confine to the session cwd here as well as in the permission branch. An agent that asks
    # permission gets checked there; opencode never asks, and reaches this hook instead. Without
    # the check its only boundary is the tool name, which cannot say which file a call touches.
    h = s.handle
    if h isa ACPHandle && args isa AbstractDict
        for p in _tool_call_paths(Dict{String,Any}("rawInput" => args))
            try
                _acp_confine(h, p)
            catch e
                return Dict("allow" => false, "why" => sprint(showerror, e))
            end
        end
    end
    return d
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

Case-insensitive, because the two sides are written in different conventions. A deny list names
the CLI's tools the way the CLI does (`Read`, `Bash`) while an ACP agent reports its own in lower
case, so an exact compare let every entry in `AGENT_NATIVE_FILE_TOOLS` miss and the deny half of
a preset enforce nothing.
"""
function _acp_tool_matches(name::AbstractString, entry::AbstractString)
    n, e = lowercase(String(name)), lowercase(String(entry))
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
    # or "default"/"lab" would wave through the very tools it was drawn up to exclude. The
    # preset's own allowances are deliberately not consulted here.
    if !isempty(b.allowed_tools) && !any(e -> _acp_tool_matches(tool, e), b.allowed_tools)
        return Dict("allow" => false, "why" => "not in this agent's allowlist")
    end
    # The preset's own allowances widen whatever it would otherwise permit. This is how `lab`
    # reaches the fs callbacks.
    any(e -> _acp_tool_matches(tool, e), b.preset_tools) && return Dict("allow" => true)

    preset = lowercase(b.permission)
    preset in ("bypass", "lab", "default") && return Dict("allow" => true)
    # `notebook` allows the Kaimon tools and nothing else, so anything reaching here is refused.
    # It gets its own answer rather than falling through to the unknown-preset one below, because
    # the refusal is read by the agent and the next thing it should do is in the message.
    preset == "notebook" && return Dict("allow" => false,
        "why" => "the `notebook` preset has no shell or file tools — use the slate tools, or " *
                 "ask for file access with slate_request_file_access")
    # A specialist is gated by its own allowlist above, which it has already passed to reach here.
    # With no allowlist there was no gate, and the preset is not one: refuse rather than hand a
    # misconfigured role everything the deny list happens not to name.
    preset == "specialist" && return isempty(b.allowed_tools) ?
        Dict("allow" => false, "why" => "a specialist with no allowlist may call nothing") :
        Dict("allow" => true)
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

"""
    agent_tool_refusal(agent_id, tool, args) -> Union{Nothing,String}

Why this agent may not call this Kaimon MCP tool, or `nothing` to let it through.

Called from `tools/call` dispatch, so the policy holds at the door Kaimon controls rather than
only inside each agent's own bridge. The bridge is still the better place to refuse, because it
stops the call before it is made; this is the backstop for agents that never consult it.

`tool` arrives bare, since this server is the one being called. Qualifying it is what lets a
preset entry naming the whole server (`mcp__kaimon`) match.

An extension tool answers to two spellings: `slate_dbg.dbg_frame` is the canonical registered
name and `slate_dbg_dbg_frame` is the alias an MCP client sees, and both reach the same handler.
Allowlists are written in the underscore spelling, so the separator is normalised before matching.

That normalisation is required, not defensive. The agent sends the underscore alias, but
`_rpc_tools_call` resolves it and passes `tool.name` — the canonical dotted form — so the name
checked here is one the agent never sent. Without normalising, an allowlist written in the
spelling agents use is compared against a spelling they never use, and every permitted verb is
refused.

Normalising collapses `<ns>.<verb>` pairs that differ only in where the split falls, so
`slate.dbg_frame` and `slate_dbg.frame` would both match an entry naming either. Comparing a
canonical tool identity from the registry would not have that property. It is not done here
because an agent's allowlist is generated from a single namespace, which keeps the ambiguity out
of reach; a tool list assembled from two namespaces that share a prefix would need the stronger
comparison.

Only ACP agents are judged. The claude CLI enforces its own allowlist, and an empty `agent_id`
means a caller that is not a Kaimon-owned agent at all.

`args` is read for the same reason `acp_bridge_decide` reads it: a tool name says what was called
and not which file it touches. The bridge hook confines the paths an opencode agent passes, so
confining here is what keeps the two doors at the same strength.

That reaches path ARGUMENTS only, which is the whole of what a tool call exposes. A shell tool
carries its target inside a command string, so nothing here confines where `bash` reads or writes,
and the presets that permit a shell (`default`, `lab`, `bypass`) are granting exactly that. The
boundary a preset without a shell gets is real; the one it gets with a shell is the agent's own
good behaviour.
"""
function agent_tool_refusal(agent_id::AbstractString, tool::AbstractString, args = nothing)
    isempty(agent_id) && return nothing
    s = lock(AGENT_SESSIONS_LOCK) do; get(AGENT_SESSIONS, String(agent_id), nothing); end
    s === nothing && return nothing
    s.backend isa ACPClientBackend || return nothing
    bare = replace(String(tool), '.' => '_')
    qualified = _acp_qualified(bare) ? bare : "mcp__$(ACP_MCP_SERVER)__$bare"
    d = _acp_decide(s.backend, qualified)
    get(d, "allow", false) === true || return String(get(d, "why", "refused by policy"))
    h = s.handle
    if h isa ACPHandle && args isa AbstractDict
        for p in _tool_call_paths(Dict{String,Any}("rawInput" => args))
            try
                _acp_confine(h, p)
            catch e
                return sprint(showerror, e)
            end
        end
    end
    return nothing
end

# ── JSON-RPC plumbing ─────────────────────────────────────────────────────────

function _rpc_write!(h::ACPHandle, obj::AbstractDict)
    lock(h.lk) do
        write(h.in, JSON.json(obj), "\n")
        flush(h.in)
    end
    nothing
end

"A request that got no reply, kept distinct so a caller can tell it from an agent-side error."
struct ACPTimeout <: Exception
    method::String
end
Base.showerror(io::IO, e::ACPTimeout) = print(io, "ACP $(e.method) timed out or the agent went away")

"""
Send a request and block until the matching response arrives.

`timeout = 0` waits indefinitely. That is right for `session/prompt`, whose duration is the
agent's to decide; the reader releases every pending call when the process dies, so waiting
without a deadline still ends.
"""
function _rpc_call!(h::ACPHandle, method::AbstractString, params; timeout::Real = 600)
    id, ch = lock(h.lk) do
        h.next_id[] += 1
        c = Channel{Any}(1)
        h.pending[h.next_id[]] = c
        (h.next_id[], c)
    end
    _rpc_write!(h, Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    reply = nothing
    timer = timeout > 0 ? Timer(timeout) do _
        isready(ch) || (isopen(ch) && close(ch))
    end : nothing
    try
        reply = take!(ch)
    catch
        throw(ACPTimeout(String(method)))
    finally
        timer === nothing || close(timer)
        lock(h.lk) do; delete!(h.pending, id); end
    end
    haskey(reply, "error") && error("ACP $method failed: $(JSON.json(reply["error"]))")
    return get(reply, "result", nothing)
end

"""
Answer an agent→client request.

Do not look for the reply in the agent's wire log. That log is the agent's stdout and stderr; this
writes to its stdin, so nothing sent from here is ever in it. Checking a decision means reading
the `AgentError` event or the agent's own account of what it got.
"""
_rpc_respond!(h::ACPHandle, id, result) =
    _rpc_write!(h, Dict("jsonrpc" => "2.0", "id" => id, "result" => result))
_rpc_error!(h::ACPHandle, id, code::Int, msg::AbstractString) =
    _rpc_write!(h, Dict("jsonrpc" => "2.0", "id" => id,
                        "error" => Dict("code" => code, "message" => msg)))

# ── agent → client requests ───────────────────────────────────────────────────

"Least destructive option the agent offered, preferring a one-shot allow."
function _pick_permission(options; want = ("allow_once", "allow_always"))
    options isa AbstractVector && !isempty(options) || return nothing
    for want in want, o in options
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
    # A size we cannot determine is a cap we cannot enforce, so refuse rather than read. Treating
    # the failure as 0 bytes let exactly the files the cap exists for through.
    sz = try
        filesize(path)
    catch e
        throw(ArgumentError("cannot size $path to apply the read limit: $(sprint(showerror, e))"))
    end
    sz > ACP_READ_CAP && throw(ArgumentError(
        "file is $(sz) bytes, over the $(ACP_READ_CAP) byte read limit; ask for a line range"))
    return read(path, String)
end

"Every path a tool call names, from wherever the agent chose to put it."
function _tool_call_paths(tc)
    tc isa AbstractDict || return String[]
    out = String[]
    ri = get(tc, "rawInput", nothing)
    if ri isa AbstractDict
        # Agents name the argument differently (`file_path`, `path`, `notebook_path`), and an edit
        # carries a list. Take anything that looks like one rather than guessing a single key.
        for (k, v) in ri
            ks = lowercase(String(k))
            # `cwd` and its spellings count: a call that names a working directory outside the
            # workspace escapes a boundary that only looks for keys saying "path".
            (occursin("path", ks) || ks in ("file", "cwd", "dir", "directory")) || continue
            v isa AbstractString && push!(out, String(v))
            v isa AbstractVector && for x in v; x isa AbstractString && push!(out, String(x)); end
        end
    end
    locs = get(tc, "locations", nothing)
    locs isa AbstractVector && for l in locs
        l isa AbstractDict || continue
        p = get(l, "path", nothing)
        p isa AbstractString && push!(out, String(p))
    end
    return unique!(out)
end

"""
Record the paths a `tool_call` / `tool_call_update` named, against its id.

The permission request for that call arrives afterwards and may name only the id. Bounded, because
a long turn is thousands of calls and this is a lookaside, not a record.

Oldest out first, one at a time. Emptying it at the cap took the paths of calls that had not been
asked about yet, and a call whose paths cannot be found is allowed — so the workspace boundary
lapsed for every call in flight at that moment, silently, once per 512.
"""
const ACP_TOOL_PATHS_CAP = 512

"The eviction on its own, so the invariant can be tested without a live agent."
function _remember_path!(seen::Dict{String,Vector{String}}, order::Vector{String},
                         key::AbstractString, paths::Vector{String}; cap::Int = ACP_TOOL_PATHS_CAP)
    k = String(key)
    haskey(seen, k) || push!(order, k)
    seen[k] = paths
    while length(order) > cap
        delete!(seen, popfirst!(order))
    end
    return nothing
end

function _remember_tool_paths!(h::ACPHandle, upd)
    upd isa AbstractDict || return nothing
    id = get(upd, "toolCallId", nothing)
    id isa AbstractString && !isempty(id) || return nothing
    paths = _tool_call_paths(upd)
    isempty(paths) && return nothing
    lock(h.lk) do; _remember_path!(h.tool_paths, h.tool_order, id, paths); end
    return nothing
end

"Note a tool call as open or finished, from the event about to be published."
function _track_tool_call!(h::ACPHandle, ev)
    id, status = if ev isa ACP.ToolCallStarted
        ev.call.tool_call_id, ev.call.status
    elseif ev isa ACP.ToolCallUpdated
        ev.update.tool_call_id, ev.update.status
    else
        return nothing
    end
    lock(h.lk) do
        if status === :completed || status === :failed
            filter!(!=(id), h.open_tools)
        elseif status !== nothing && !(id in h.open_tools)
            push!(h.open_tools, id)
        end
    end
    return nothing
end

"""
Retire every open tool call as failed, with `why` as its result.

ACP has no cancelled tool status, so `:failed` is the only terminal one available. Without this
a cancelled turn leaves its calls in `:in_progress` and nothing ever moves them.
"""
function _close_open_tools!(h::ACPHandle, why::AbstractString)
    ids = lock(h.lk) do
        got = copy(h.open_tools); empty!(h.open_tools); got
    end
    isopen(h.events) || return nothing
    for id in ids
        put!(h.events, ACP.ToolCallUpdated(ACP.ToolCallUpdate(;
            tool_call_id = id, status = :failed,
            content = [ACP.ContentToolContent(ACP.TextBlock(String(why)))])))
    end
    return nothing
end

"""
The native tools an ACP `kind` stands for, so a deny list written in CLI names can be applied to a
call that reports only its category.

ACP gives a tool call a `title` and a `kind` and no name. `title` is whatever the agent chose to
render, so it is checked first and matched loosely; `kind` is a fixed enum and is what remains when
the title says nothing useful.

Both halves earn their place. Measured against claude-agent-acp: `Write` titles itself `Write` and
the title match catches it, while `Bash` titles itself `Terminal` and only `kind == "execute"`
does. A deny list checked against titles alone would have let every shell command through.
"""
const ACP_KIND_TOOLS = Dict(
    "read"    => ["Read"],
    "edit"    => ["Edit", "Write"],
    "delete"  => ["Write"],
    "move"    => ["Write"],
    "execute" => ["Bash"],
    "search"  => ["Grep", "Glob"],
)

"""
Is this call one the agent's deny list names? Returns the refusal, or `nothing`.

Only the deny half, and only when there is one, so a preset without it costs nothing here. An
MCP-qualified call is left alone: those are decided at the MCP door where the real name is known,
and `notebook` allows `mcp__kaimon` outright, so matching one on `kind` here would refuse the tools
the preset exists to permit.
"""
function _denied_tool(b::ACPClientBackend, tc)
    deny = b.disallowed_tools
    isempty(deny) && return nothing
    title = String(get(tc, "title", ""))
    # The first word of a title like "Read src/foo.jl" is the part that names a tool.
    head = isempty(title) ? "" : String(first(split(strip(title), r"[\s(]"; limit = 2)))
    # A qualified name means an MCP tool or an fs callback, both of which are decided where the real
    # name is known. Neither the name nor the category is judged here: `notebook` allows
    # `mcp__kaimon` outright, and its calls carry the same categories the native tools do.
    #
    # Both MCP spellings count, which is what `_acp_split_tool` is for: opencode names Kaimon's
    # tools `kaimon_<tool>`, carrying none of the punctuation a `mcp__kaimon__<tool>` name does.
    # Sniffing the title sees only the second spelling, and a Kaimon call that slips past here is
    # judged on `kind` instead — where `read` maps onto `Read`, the tool these presets deny.
    (occursin("/", head) || occursin(".", head) ||
     _acp_split_tool(head)[1] !== nothing) && return nothing
    if !isempty(head)
        for e in deny
            _acp_tool_matches(head, e) && return "denied by policy: $head"
        end
    end
    # Nothing usable in the title. Fall back to the category, which every agent reports the same way.
    kind = lowercase(String(get(tc, "kind", "")))
    for nm in get(ACP_KIND_TOOLS, kind, String[])
        for e in deny
            _acp_tool_matches(nm, e) && return "denied by policy: $kind"
        end
    end
    return nothing
end

"""
Why this tool call should be refused, or `nothing` to let it through.

The workspace boundary, applied to every path the call names. This is where it has to happen: both
agents we ship through do their own file I/O and ask here, so the `fs/*` callbacks that already
confine are a door neither of them uses.

Deliberately NOT the tool-name ALLOWLIST. A preset's allowance names Kaimon's MCP tools and the
`fs/*` callbacks, not an agent's native `Read` and `Edit`, so checking the name here would refuse
an ordinary `lab` agent every file operation it has always been allowed. The path is the part that
means the same thing for every agent.

The DENY half is different, and is checked. It exists to say "not this tool, ever", and the presets
that carry one (`notebook`, `specialist`) mean it about exactly the tools this door sees. Leaving it
unchecked here is why those two enforced nothing against a non-opencode agent: the opencode plugin
is the only other place it was consulted, and `plugin_dir` is `nothing` for everyone else. A preset
with an empty deny list reaches none of this, so `default`, `lab`, `auto` and `bypass` are untouched.

A call that names no path is allowed — refusing what cannot be parsed would break every tool that
touches no file.
"""
function _permission_refusal(h::ACPHandle, tc)
    tc isa AbstractDict || return nothing
    why = _denied_tool(h.backend, tc)
    why === nothing || return why
    paths = _tool_call_paths(tc)
    if isempty(paths)
        # The asking message carried no path. Fall back to what the call itself announced: the
        # `tool_call` update precedes the permission request for the same id, which is exactly the
        # ordering the inline announce preserves.
        id = get(tc, "toolCallId", nothing)
        if id isa AbstractString
            paths = lock(h.lk) do; copy(get(h.tool_paths, String(id), String[])); end
        end
    end
    for p in paths
        try
            _acp_confine(h, p)
        catch e
            return sprint(showerror, e)
        end
    end
    return nothing
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
    cc = _acp_claude_meta(h)
    cc === nothing && return false
    return get(cc, "promptQueueing", false) === true
end

"""
The `claudeCode` extension block from the `initialize` reply, or `nothing`.

Doubles as the runtime test for whether this agent understood the `_meta.claudeCode.options` sent
with `session/new`: an agent that publishes the extension is the one that reads it. ACP has no
capability for "I will ask permission", so this is the only signal on the wire that a deny list
handed to the agent will be honoured.
"""
function _acp_claude_meta(h::ACPHandle)
    caps = get(h.caps, "agentCapabilities", nothing)
    caps isa AbstractDict || return nothing
    meta = get(caps, "_meta", nothing)
    meta isa AbstractDict || return nothing
    cc = get(meta, "claudeCode", nothing)
    return cc isa AbstractDict ? cc : nothing
end

"""
What this agent's own tools are NOT bound by, given how it turned out to be configurable.

A deny list reaches an agent's native tools by one of two routes, and both are agent-specific: the
bridge plugin, which only opencode loads, or the `_meta.claudeCode.options` handed to
`session/new`, which only an agent publishing that extension reads. An agent with neither keeps
just the ask-time check, and an agent that does its own file I/O without asking keeps nothing.

Returns the sentence to put on the event stream, or `nothing` when the configuration is enforced.
Reported rather than refused: the caller asked for this agent, and a preset that covers Kaimon's
tools and not the agent's own is still worth having — it just has to say so. Kaimon's own door is
unaffected, so every `mcp__kaimon` entry (the recursion guard included) holds whatever the agent is.

Only for a spawn that ASKED to be bounded: an allowlist, or a deny entry naming a native tool that
the caller or a preset added. `default` and `lab` deny nothing native, so they have no claim to
qualify — what is left in the stock deny list there is the CLI's own subagent spawners under
Claude's names for them, and an agent with no such tool cannot call them anyway.
"""
function _acp_enforcement_gap(h::ACPHandle)
    b = h.backend
    # Only the entries naming the agent's OWN tools are at stake. A qualified or server-prefixed
    # entry is decided at Kaimon's `tools/call` door, which no agent can route around.
    native = [e for e in b.disallowed_tools
              if _acp_split_tool(lowercase(e))[1] === nothing && !(e in AGENT_SELF_TOOLS)]
    isempty(native) && isempty(b.allowed_tools) && return nothing
    _acp_plugin_supported(b.argv) && return nothing
    _acp_claude_meta(h) === nothing || return nothing
    what = isempty(native) ? "this agent's allowlist" :
           "the deny list ($(join(sort(native), ", ")))"
    return "$(basename(first(b.argv))) loads neither the bridge plugin nor the `_meta.claudeCode` " *
           "options, so $what binds its own tools only where it asks permission for a call, and " *
           "an agent doing its own file I/O does not ask about everything. Kaimon's own tools and " *
           "the workspace boundary are unaffected. Use `acp:opencode` or `acp:claude` for a " *
           "preset that holds against native tools."
end

"""
    _path_within(root, full) -> Bool

Whether `full` is `root` or sits beneath it, comparing path components rather than string
prefixes.

A `startswith(full, root * "/")` test is wrong twice over. It reads `/` as the separator, which on
Windows matches nothing, so every in-workspace path fails containment and the agent can touch no
file at all. And a prefix compare reads `/ws-evil` as inside `/ws`, which componentwise cannot.
Windows filenames are case-insensitive, so the comparison follows the platform.
"""
function _path_within(root::AbstractString, full::AbstractString)
    fold(s) = Sys.iswindows() ? lowercase(s) : s
    rp = fold.(splitpath(String(root)))
    fp = fold.(splitpath(String(full)))
    length(fp) >= length(rp) || return false
    return all(i -> fp[i] == rp[i], eachindex(rp))
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
_acp_confine(h::ACPHandle, path::AbstractString) = _confine_to(h.cwd, path)

"The resolution and the check on their own, so the boundary can be tested without a live agent."
function _confine_to(cwd::AbstractString, path::AbstractString)
    isempty(path) && throw(ArgumentError("no path given"))
    root = try; realpath(cwd); catch; abspath(cwd); end
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
    _path_within(root, full) ||
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

"""
Ask a human whether to allow a call policy would refuse. `nothing` when nobody can be asked.

Set by whoever owns the agent and knows where its person is looking — Kaimon spawns agents and does
not. Called as `f(agent_id, tool, why) -> :allow | :always | :deny`, and anything else counts as
deny, so a hook that errors or invents an answer cannot widen a policy.
"""
const _PERMISSION_ASK = Ref{Any}(nothing)
set_permission_ask!(f) = (_PERMISSION_ASK[] = f; nothing)

"""
Put a refusal to the human, and answer with what they say.

A policy that can only refuse teaches people to work around it; one that asks is the same policy
with a door in it. Silence is a refusal, so a headless run behaves exactly as it did before this
existed — nobody answers, and the call is refused.

Asked EVERY time, with no memory of the answer here. "Always allow" is a statement about a role or
a project, and an agent id is neither: it belongs to one summoning and the next one has a different
one, so consent kept against it would be forgotten exactly when someone wanted it and inherited
exactly when they did not. Whoever owns the agent knows what the durable thing is called, and it is
also the side that should decide how long consent lasts, so remembering lives there. A hook that
has an answer already returns it without troubling anyone.

Safe to block: the caller is already on its own task (see `_start_acp_reader!`), so the reader
keeps draining while this waits.
"""
function _permission_answer(aid::AbstractString, tool::AbstractString, why::AbstractString)
    f = _PERMISSION_ASK[]
    # No hook is nobody to ask. No agent id is nobody to attribute the decision to.
    (f === nothing || isempty(aid)) && return (:deny, "")
    try
        # Only a clear yes is a yes. A hook that times out into a default or answers something
        # unexpected must not be able to widen a policy.
        return (Symbol(f(String(aid), String(tool), String(why))) === :allow ? :allow : :deny, "")
    catch e
        return (:deny, "could not ask about $tool: $(sprint(showerror, e))")
    end
end

function _ask_permission(h::ACPHandle, tool::AbstractString, why::AbstractString)
    decision, err = _permission_answer(h.agent_id, tool, why)
    isempty(err) || put!(h.events, ACP.AgentError(err))
    return decision
end

function _handle_request!(h::ACPHandle, id, method::AbstractString, params)
    params = params isa AbstractDict ? params : Dict{String,Any}()

    if method == "session/request_permission"
        # The event was ANNOUNCED on the reader (see `_announce_request!`); this half only
        # decides and answers. Blocking on a human here would hang every headless turn.
        #
        # THIS is the door the agents we actually ship through use. Neither opencode nor
        # claude-agent-acp calls `fs/read_text_file`: both do their own file I/O and ask here
        # instead. So a branch that just picked an allow option was the whole file boundary, and it
        # authorised a read four levels outside the workspace with the scope printed in the option
        # name it accepted. Policy and confinement have to be applied here or they apply to nobody.
        opts = get(params, "options", Any[])
        why = _permission_refusal(h, get(params, "toolCall", nothing))
        # A refusal is put to the person first. Policy still decides what needs asking about; what
        # it no longer decides alone is the answer.
        if why !== nothing
            tc = get(params, "toolCall", nothing)
            tool = tc isa AbstractDict ? String(get(tc, "title", get(tc, "kind", "a tool"))) : "a tool"
            why = _ask_permission(h, tool, why) === :allow ? nothing : why
        end
        if why !== nothing
            rej = _pick_permission(opts; want = ("reject_once", "reject_always"))
            put!(h.events, ACP.AgentError("refused a tool call: $why"))
            _rpc_respond!(h, id, rej === nothing ?
                Dict("outcome" => Dict("outcome" => "cancelled")) :
                Dict("outcome" => Dict("outcome" => "selected", "optionId" => rej)))
        else
            opt = _pick_permission(opts)
            _rpc_respond!(h, id, opt === nothing ?
                Dict("outcome" => Dict("outcome" => "cancelled")) :
                Dict("outcome" => Dict("outcome" => "selected", "optionId" => opt)))
        end

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
    ACP.Usage(; input_tokens = _token_count(get(u, "inputTokens", 0)),
                output_tokens = _token_count(get(u, "outputTokens", 0)) +
                                _token_count(get(u, "thoughtTokens", 0)),
                cache_read_tokens = _token_count(get(u, "cachedReadTokens", 0)),
                cost_usd = cost)
end

"""
One token figure off the wire, as an `Int`, with anything unusable reading as zero.

`Int(x)` is the strict reading, and this is called while the turn's `TurnEnded` is being built.
A figure that is fractional, a string or null throws there, and the only handler around it is the
one that reports the turn as failed — so a completed turn comes out as a refusal over a number
nothing depends on. A count is telemetry; it does not get to decide what the turn did.
"""
function _token_count(v)
    v isa Integer && return Int(v)
    v isa Real && isfinite(v) && return round(Int, v)
    v isa AbstractString && return something(tryparse(Int, v), 0)
    return 0
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
                h.last_rx[] = time()
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
                        # Remember what each tool call named, so the permission request that
                        # follows it can be judged even when it carries a bare toolCall.
                        _remember_tool_paths!(h, upd)
                        for ev in _map_acp_update(upd)
                            _track_tool_call!(h, ev)
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
                    # A reply whose caller has already given up has nowhere to go, and finding
                    # that out is a race: `_rpc_call!` closes this channel on timeout, so it can
                    # shut between the check and the put. An exception here is not scoped to the
                    # line that raised it — it leaves the read loop entirely, which retires every
                    # open tool call and publishes `:dead` for an agent that is still healthy.
                    if ch !== nothing
                        try
                            isopen(ch) && put!(ch, obj)
                        catch
                        end
                    end
                end
            end
        catch e
            e isa InterruptException || put!(h.events, ACP.AgentError("ACP reader crashed: $(sprint(showerror, e))"))
        finally
            _close_open_tools!(h, "agent exited")
            # Nothing else will ever answer these, so release them instead of leaving each caller
            # to wait out its own timeout.
            lock(h.lk) do
                for c in values(h.pending); isopen(c) && close(c); end
            end
            put!(h.events, ACP.StatusChanged(:dead))
            close(h.events)
            try; close(log_io); catch; end
        end
    end
end

# ── per-session config ────────────────────────────────────────────────────────

"""
The user's own opencode config, read before `XDG_CONFIG_HOME` is redirected away from it.
"""
function _opencode_user_config()
    base = get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config"))
    path = joinpath(base, "opencode", "opencode.json")
    isfile(path) || return Dict{String,Any}()
    try
        cfg = JSON.parse(read(path, String))
        return cfg isa AbstractDict ? cfg : Dict{String,Any}()
    catch
        return Dict{String,Any}()
    end
end

"""
Give the agent its own config directory: it is how the model gets pinned (ACP has
no model parameter), how the bridge plugin gets loaded, and how two sessions can
run under different tool policies at the same time.

The generated file REPLACES the user's own, because `XDG_CONFIG_HOME` points here. That is what
isolates two sessions from each other, and it is also what stops a setting on the machine from
widening a preset. So almost nothing is carried across.

`provider` is the exception. It declares how to reach a model and grants no tool, and without it
`model` can only name something opencode already knows: a locally served model, which is the
cheapest way to run an agent, cannot be selected at all. Carrying it makes `acp:opencode:<model>`
mean what it says.

`mcp` is deliberately NOT carried. An inherited server is one Kaimon did not attach, so its calls
arrive without the `X-Kaimon-Agent-Id` header and no preset applies to them — the same hole
`strictMcpConfig` closes on the claude path.
"""
function _acp_session_config(b::ACPClientBackend, dir::AbstractString)
    # Nothing to generate for an agent that reads neither the config nor the plugin. Writing it
    # anyway was harmless; pointing `XDG_CONFIG_HOME` at it was not, since an agent that keeps its
    # settings there would find an empty directory and silently run without them.
    _acp_config_supported(b.argv) || return dir
    mkpath(joinpath(dir, "opencode"))
    cfg = Dict{String,Any}("\$schema" => "https://opencode.ai/config.json")
    user = _opencode_user_config()
    haskey(user, "provider") && (cfg["provider"] = user["provider"])
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
    # Only for the agent whose config was generated. Redirecting it for the others replaced their
    # own settings directory with an empty one.
    _acp_config_supported(b.argv) && (env["XDG_CONFIG_HOME"] = config_dir)
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
                  Dict{String,Any}(), Dict{String,Vector{String}}(), String[], String[],
                  Ref(time()), ReentrantLock())
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
                      merge(Dict{String,Any}("cwd" => abspath(cwd), "mcpServers" => b.mcp_servers),
                            _acp_session_meta(b)); timeout = 120)
    sess isa AbstractDict && (h.caps["session"] = Dict{String,Any}(String(k) => v for (k, v) in sess))
    h.session_id[] = String(get(sess, "sessionId", ""))
    # An agent that does not read the generated config never saw `model`, so select it over the
    # wire. A failure is reported rather than swallowed, since the agent then runs its default.
    if !isempty(b.model) && !_acp_config_supported(b.argv)
        acp_set_model!(h, b.model) ||
            put!(h.events, ACP.AgentError("could not select model '$(b.model)'; " *
                                          "the agent is running its own default"))
    end
    # Same treatment for the tool policy. Which enforcement routes this agent has is only knowable
    # once its capabilities are in, and a preset that cannot reach its native tools has to say so
    # here — otherwise it reads as configured for the whole session.
    let gap = _acp_enforcement_gap(h)
        gap === nothing || put!(h.events, ACP.AgentError(gap))
    end
    # Plan mode is the agent's own restriction on edit tools; prefer it over the
    # bridge, which can only refuse a call after the model has committed to it.
    lowercase(b.permission_mode) == "plan" && acp_set_mode!(h, "plan")
    h
end

"""
The `_meta` for `session/new`: the deny list, handed to the agent to enforce on itself.

A deny list at this end only bites where the agent ASKS, and an agent that does its own file I/O
does not ask about everything. Measured against claude-agent-acp: writes, shell commands and any
path outside the session cwd come through `session/request_permission` and are refused there, but
reading a file inside the cwd never arrives at all. There is no door to hold.

So the list is also given to the agent, which applies it before choosing a tool rather than after.
`_meta.claudeCode.options` is claude-agent-acp's own extension: it spreads those options into the
SDK query, and `disallowedTools` is one of them. ACP says a receiver ignores `_meta` it does not
recognise, so an agent without this extension is unaffected and keeps the ask-time check as its
only enforcement.

Belt and braces on purpose. This half depends on the agent honouring what it was handed, and the
ask-time half does not.

`settingSources` goes with it for the two presets that claim to bound the toolset. A deny list can
only name tools, and the agent also loads whatever MCP servers the machine's own settings declare:
a notebook agent came up holding a documents server, with mail and file-storage servers a step
behind it, and neither preset governs any of them — those calls go to another server and Kaimon
never sees them. Loading no settings at all removes the whole class instead of naming members of
it. Kaimon's own servers are unaffected: they ride `session/new` and are merged after this.

The cost is that those two presets also lose CLAUDE.md and every other filesystem setting. For a
specialist that is nothing, since its brief comes from here. For `notebook` it is the project's
conventions, traded for a toolset that is what it says it is.
"""
function _acp_session_meta(b::ACPClientBackend)
    opts = Dict{String,Any}()
    isempty(b.disallowed_tools) || (opts["disallowedTools"] = collect(b.disallowed_tools))
    if lowercase(b.permission) in ("notebook", "specialist")
        opts["settingSources"] = String[]
        # Settings are one source of MCP servers and not the only one: dropping them left an agent
        # holding servers that come with the account rather than the filesystem. This restricts the
        # session to the servers passed on the command line, which are the ones sent here.
        opts["strictMcpConfig"] = true
    end
    isempty(opts) && return Dict{String,Any}()
    return Dict{String,Any}("_meta" => Dict{String,Any}("claudeCode" => Dict{String,Any}("options" => opts)))
end

"How long an agent may say nothing during a turn before we say so."
const ACP_SILENCE_WARN = 300.0

"""
Report a turn that has gone quiet, without ending it.

A prompt waits indefinitely, which is right: only the agent knows how long its turn is, and the
reader releases the wait when the process dies. That covers a crashed agent and not a live one
that has stopped answering, which would otherwise hold the turn with nothing surfaced. So the
silence is reported as an error event and the wait continues. Ending the turn here would
truncate a long one that is merely thinking.
"""
function _watch_silence!(h::ACPHandle, done::Ref{Bool})
    @async begin
        warned = false
        while !done[] && Base.process_running(h.proc)
            sleep(5.0)
            if !warned && !done[] && time() - h.last_rx[] > ACP_SILENCE_WARN
                warned = true
                isopen(h.events) && put!(h.events, ACP.AgentError(
                    "no response for $(round(Int, time() - h.last_rx[]))s; the turn is still open"))
            end
        end
    end
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
    done = Ref(false)
    # The watchdog measures silence since the last thing the agent said, and only the reader writes
    # that. Between turns an agent says nothing by definition, so an agent that sat idle longer than
    # ACP_SILENCE_WARN already looks wedged before this turn has asked it for anything. The clock
    # starts when the turn does.
    h.last_rx[] = time()
    _watch_silence!(h, done)
    @async try
        res = _rpc_call!(h, "session/prompt", Dict(
            "sessionId" => h.session_id[],
            "prompt" => [Dict("type" => "text", "text" => String(text))]); timeout = 0)
        _flush_authoritative!(h)
        put!(h.events, ACP.TurnEnded(
            ACP.as_enum(get(res, "stopReason", ""), ACP.STOP_REASONS, :end_turn),
            _acp_turn_usage(get(res, "usage", nothing), h.last_cost[])))
    catch e
        isopen(h.events) || return
        put!(h.events, ACP.AgentError("turn failed: $(sprint(showerror, e))"))
        _flush_authoritative!(h)   # a failed turn still has partial text worth keeping
        # `:refusal` is reserved for what the agent actually said. A turn ended by a lost
        # connection reports as cancelled.
        put!(h.events, ACP.TurnEnded(e isa ACPTimeout ? :cancelled : :refusal, nothing))
    finally
        done[] = true
    end
    turn
end

# ── live session configuration ────────────────────────────────────────────────
# ClaudeBackend binds model and permission mode at spawn, so changing either means
# reaping the agent and losing the conversation. ACP exposes both as session
# methods, so a picker change can land on the next turn instead.

"How long one attempt at setting a session option waits. Setting one is a round trip to a process
that is already up, so this is a wedge detector rather than a work budget."
const ACP_SET_OPTION_TIMEOUT = 15

"""
Try a standard ACP method, then the `session/set_config_option` fallback in both its spellings.

Returns whether any of them stuck. The standard method is the portable one; the fallback is what
both agents advertise in the `configOptions` they return from `session/new`, and they disagree on
what the id field is called — opencode reads `optionId`, claude-agent-acp reads `configId` and
rejects the request outright without it. An agent implementing only one of these should still be
configurable, so all three are tried before giving up.
"""
function _acp_set_option!(h::ACPHandle, method::AbstractString, key::AbstractString,
                          param::AbstractString, value::AbstractString)
    isempty(value) && return false
    attempts = [(method, Dict{String,Any}(param => value))]
    for idkey in ("configId", "optionId")
        push!(attempts, ("session/set_config_option",
                         Dict{String,Any}(idkey => key, "value" => value)))
    end
    err = nothing
    for (m, extra) in attempts
        try
            _rpc_call!(h, m, merge(Dict{String,Any}("sessionId" => h.session_id[]), extra);
                       timeout = ACP_SET_OPTION_TIMEOUT)
            return true
        catch e
            err = e
            # The attempts exist for agents that name this RPC differently, and one that does not
            # know a method says so at once. A TIMEOUT is the other thing: the agent is not
            # answering, and the remaining attempts can only wait the same span again. This runs
            # inside `agent_open`, so three of them put the caller past a client's tool timeout for
            # an option that is optional anyway.
            e isa ACPTimeout && break
        end
    end
    put!(h.events, ACP.AgentError("could not set $key=$value: $(sprint(showerror, err))"))
    return false
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
        _close_open_tools!(h, "cancelled")
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

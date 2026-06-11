# ── OllamaBackend ─────────────────────────────────────────────────────────────
# A second AgentBackend (see agent_backend.jl) that drives a LOCAL Ollama model
# instead of the `claude` CLI. Unlike ClaudeBackend — where the CLI runs the agent
# loop and speaks MCP itself — Ollama speaks neither, so this backend runs the
# agentic ReAct loop IN-PROCESS: translate Kaimon's tools → Ollama function specs,
# POST /api/chat, detect tool_calls, dispatch them, feed results back, loop until
# the model answers with no tool calls. It emits the same ACP.AgentEvent stream as
# ClaudeBackend, so AgentSession / the gate stream / KaimonSlate are unchanged.
#
# There is NO subprocess: `backend_start` just builds the handle (HTTP config +
# conversation + events Channel); each `backend_send` runs one turn task.

import HTTP

const OLLAMA_PREFIX = "ollama:"
# vmlx (MLX inference server for Apple Silicon) speaks the Ollama /api/chat wire
# protocol, so it reuses this backend — a distinct prefix + default host, not an
# overload of `ollama:`. Default host is vmlx's own default port (no env needed).
const VMLX_PREFIX = "vmlx:"

# Unlike claude (which ships its own agent harness/system prompt), a local model
# gets none — so a bare Ollama agent has no idea it's a tool-using agent. This
# default framing is seeded when no system_prompt is supplied; a caller (e.g.
# KaimonSlate) that passes its own prompt overrides it entirely.
const OLLAMA_DEFAULT_SYSTEM = """
You are an AI agent operating inside Kaimon, a Julia development environment. You \
have a set of tools (functions) available to you. Use them to take actions and to \
fetch real, current information instead of answering from memory or guessing. When \
a request can be served by a tool, CALL THE TOOL with the documented arguments \
rather than describing what you would do. Tool names are bare (e.g. `ex`, `ping`). \
After tool results return, give a concise answer grounded in them."""

Base.@kwdef struct OllamaBackend <: AgentBackend
    model::String = "qwen2.5-coder"                       # model tag (after the prefix)
    host::String = get(ENV, "OLLAMA_HOST", "http://127.0.0.1:11434")
    label::String = "ollama"                              # attribution/error label ("ollama"/"vmlx")
    allowed_tools::Vector{String} = String[]              # bare names; empty ⇒ all non-self tools
    disallowed_tools::Vector{String} = copy(AGENT_SELF_TOOLS)   # recursion guard (reuse!)
    system_prompt::Union{String,Nothing} = nothing
    num_ctx::Int = 16384
    temperature::Float64 = 0.0
    max_tool_rounds::Int = 24                             # safety cap on the ReAct loop per turn
end

mutable struct OllamaHandle <: AgentHandle
    backend::OllamaBackend
    events::Channel{ACP.AgentEvent}
    messages::Vector{Any}                                 # running conversation (Dicts)
    tools_spec::Vector{Any}                               # precomputed Ollama `tools` array
    turn::Base.RefValue{Int}
    cancel::Base.RefValue{Bool}
    task::Base.RefValue{Task}                             # current in-flight turn task
    cwd::String
    agent_id::String                                     # for TUI Activity attribution
    log_file::String
    alive::Base.RefValue{Bool}
end

backend_status(h::OllamaHandle) = h.alive[] ? :alive : :dead

# ── Tool bridging ─────────────────────────────────────────────────────────────
# OllamaBackend runs IN the Kaimon server process, so it dispatches tools via the
# in-process unified dispatchers in service_endpoint.jl (_dispatch_list_tools /
# _dispatch_tool_call) — the same registry (SERVER[].name_to_id/tools) the MCP
# server and the gate service endpoint use, covering native + extension tools
# (slate_*, ex, …). MCPTool.parameters is already a JSON Schema, so no reflection
# is needed (unlike gate-session GateTools, which go through _reflect_tool).

"""Strip an MCP server prefix (`mcp__kaimon__foo` → `foo`) so allow/deny lists and
tool names compare on the bare name regardless of which form the caller used."""
_bare_tool(name::AbstractString) = replace(String(name), r"^mcp__[A-Za-z0-9_]+__" => "")

"""Match a bare tool name against a claude-style allow/deny entry. Entries may be a
bare name (`"ex"`), a fully-qualified MCP name (`"mcp__kaimon__ex"`), or a server
prefix (`"mcp__kaimon"`, matching every tool from that server) — the same semantics
as claude's `--allowedTools`, so the permission presets / allowlists work
identically for both backends. (The `lab` preset is exactly `["mcp__kaimon"]`.)"""
function _tool_name_matches(bare::AbstractString, entry::AbstractString)
    e = String(entry)
    isempty(e) && return false
    bare == e && return true
    bare == _bare_tool(e) && return true
    return startswith("mcp__kaimon__" * bare, e)   # server-prefix form
end

"""Whether `bare` passes the allow/deny lists: deny wins; an empty allow list means
allow everything (minus deny)."""
function _tool_permitted(bare::AbstractString, allowed, disallowed)
    any(d -> _tool_name_matches(bare, d), disallowed) && return false
    isempty(allowed) && return true
    return any(a -> _tool_name_matches(bare, a), allowed)
end

"""Pure filter+shape: turn a tool list (each with `.name`, `.description`,
`.parameters`) into the Ollama `tools` array, honoring the allow/deny lists. Split
out from the dispatcher-backed method so it's unit-testable without a server."""
function _ollama_tools_spec(tools, allowed::Vector{String}, disallowed::Vector{String})
    spec = Any[]
    for t in tools
        bare = _bare_tool(string(t.name))
        _tool_permitted(bare, allowed, disallowed) || continue
        params = t.parameters isa AbstractDict && !isempty(t.parameters) ? t.parameters :
                 Dict("type" => "object", "properties" => Dict{String,Any}())
        push!(spec, Dict("type" => "function", "function" => Dict(
            "name" => bare, "description" => t.description, "parameters" => params)))
    end
    return spec
end

"""Build the Ollama `tools` array from the in-process tool registry
(`_dispatch_list_tools`), applying the allow/deny filter (self-management tools
stay filtered — recursion guard)."""
function _ollama_tools_spec(allowed::Vector{String}, disallowed::Vector{String})
    res = _dispatch_list_tools()
    res.status === :ok || return Any[]
    return _ollama_tools_spec(res.value, allowed, disallowed)
end

"""Dispatch one tool call in-process. Returns `(model_text, acp_content, is_error)`:
`model_text` is the text fed back to the model (most local models are text-only, so
image blocks become a short note); `acp_content` is the ACP ToolCallContent the UI
renders (text + images, exactly like ClaudeBackend's `_tool_result_content`)."""
function _ollama_dispatch(name::AbstractString, args, allowed::Vector{String},
                          disallowed::Vector{String})
    bare = _bare_tool(name)
    # Defense in depth — re-enforce the boundary at call time.
    if !_tool_permitted(bare, allowed, disallowed)
        return ("tool '$bare' is not permitted", ACP.ToolCallContent[
            ACP.ContentToolContent(ACP.TextBlock("tool '$bare' is not permitted"))], true)
    end
    dargs = args isa AbstractDict ? Dict{String,Any}(string(k) => v for (k, v) in args) :
            Dict{String,Any}()
    res = _dispatch_tool_call((type = :tool_call, tool_name = Symbol(bare), args = dargs))
    if res.status !== :ok
        msg = "Error: $(res.message)"
        return (msg, ACP.ToolCallContent[ACP.ContentToolContent(ACP.TextBlock(msg))], true)
    end
    raw = string(res.value)
    blocks, env_err = _build_tool_content(raw)         # unwraps image envelopes + downsamples
    is_err = env_err || startswith(raw, "Error") || startswith(raw, "ERROR")
    parts = String[]
    acp = ACP.ToolCallContent[]
    for b in blocks
        if get(b, "type", "") == "text"
            txt = String(get(b, "text", ""))
            push!(parts, txt)
            push!(acp, ACP.ContentToolContent(ACP.TextBlock(txt)))
        elseif get(b, "type", "") == "image"
            mime = String(get(b, "mimeType", "image/png"))
            push!(parts, "[image returned: $mime]")     # text-only models can't see it
            push!(acp, ACP.ContentToolContent(ACP.ImageBlock(String(get(b, "data", "")), mime)))
        end
    end
    return (isempty(parts) ? raw : join(parts, "\n"), acp, is_err)
end

# ── NDJSON line → ACP events (pure; unit-testable without HTTP) ────────────────

"""Accumulator for one streamed turn: the assistant text built from deltas, the
tool calls Ollama emits, the final usage, and whether `done` was seen."""
Base.@kwdef mutable struct _OllamaTurnAcc
    assistant::String = ""
    toolcalls::Vector{Any} = Any[]
    usage::ACP.Usage = ACP.Usage(cost_usd = 0.0)
    done::Bool = false
end

"""Process one parsed `/api/chat` NDJSON object, updating `acc` and returning the
ACP events to emit (streamed text/thought deltas). Tool calls and usage are folded
into `acc` (the loop acts on them after the stream ends). Mirror of
`_map_claude_event` — the seam tests target."""
function _map_ollama_chunk(obj, acc::_OllamaTurnAcc)::Vector{ACP.AgentEvent}
    out = ACP.AgentEvent[]
    msg = _get(obj, "message")
    if msg isa AbstractDict
        c = _get(msg, "content")
        if c isa AbstractString && !isempty(c)
            acc.assistant *= c
            push!(out, ACP.AgentMessageChunk(ACP.TextBlock(c), true))   # delta
        end
        th = _get(msg, "thinking")
        if th isa AbstractString && !isempty(th)
            push!(out, ACP.AgentThoughtChunk(ACP.TextBlock(th), true))
        end
        tcs = _get(msg, "tool_calls")
        tcs isa AbstractVector && append!(acc.toolcalls, tcs)
    end
    if something(_get(obj, "done"), false) === true
        acc.done = true
        acc.usage = ACP.Usage(
            input_tokens = Int(something(_get(obj, "prompt_eval_count"), 0)),
            output_tokens = Int(something(_get(obj, "eval_count"), 0)),
            cost_usd = 0.0)
    end
    return out
end

# ── Backend interface ─────────────────────────────────────────────────────────

function backend_start(b::OllamaBackend; cwd::String, agent_id::String,
                       parent_pid::Integer = getpid())
    isdir(cwd) || throw(ArgumentError("agent cwd does not exist: $cwd"))
    log_dir = joinpath(kaimon_cache_dir(), "agents")
    mkpath(log_dir)
    log_file = joinpath(log_dir, "$(agent_id).log")
    try; write(log_file, ""); catch; end

    messages = Any[]
    sys = (b.system_prompt === nothing || isempty(b.system_prompt)) ?
          OLLAMA_DEFAULT_SYSTEM : b.system_prompt
    push!(messages, Dict("role" => "system", "content" => sys))
    tools_spec = try
        _ollama_tools_spec(b.allowed_tools, b.disallowed_tools)
    catch e
        @debug "Failed to build Ollama tool spec" exception = e
        Any[]
    end

    OllamaHandle(b, Channel{ACP.AgentEvent}(Inf), messages, tools_spec,
                 Ref(0), Ref(false), Ref(Task(() -> nothing)), cwd, agent_id, log_file, Ref(true))
end

"""Push a user turn and run the ReAct loop on a task. Events arrive on `events(h)`."""
function backend_send(h::OllamaHandle, text::AbstractString)
    h.alive[] || throw(ArgumentError("agent is not alive"))
    turn = (h.turn[] += 1)
    h.cancel[] = false
    push!(h.messages, Dict("role" => "user", "content" => String(text)))
    put!(h.events, ACP.TurnStarted())
    h.task[] = @async _run_ollama_turn(h, turn)
    turn
end

function _run_ollama_turn(h::OllamaHandle, turn::Int)
    b = h.backend
    usage = ACP.Usage(cost_usd = 0.0)
    try
        for roundno in 1:b.max_tool_rounds
            if h.cancel[]
                put!(h.events, ACP.TurnEnded(:cancelled, usage)); return
            end
            acc = _OllamaTurnAcc()
            body = Dict("model" => b.model, "messages" => h.messages, "stream" => true,
                        "tools" => h.tools_spec,
                        "options" => Dict("num_ctx" => b.num_ctx, "temperature" => b.temperature))
            try
                _ollama_stream_chat(b.host, body, h, acc)
            catch e
                put!(h.events, ACP.AgentError("$(b.label): $(sprint(showerror, e))"))
                put!(h.events, ACP.TurnEnded(:refusal, acc.usage)); return
            end
            h.cancel[] && (put!(h.events, ACP.TurnEnded(:cancelled, acc.usage)); return)
            usage = usage + acc.usage

            # Authoritative assistant text (self-heals any dropped deltas; matches Claude).
            isempty(acc.assistant) ||
                put!(h.events, ACP.AgentMessageChunk(ACP.TextBlock(acc.assistant), false))
            amsg = Dict{String,Any}("role" => "assistant", "content" => acc.assistant)
            isempty(acc.toolcalls) || (amsg["tool_calls"] = acc.toolcalls)
            push!(h.messages, amsg)

            if isempty(acc.toolcalls)
                put!(h.events, ACP.TurnEnded(:end_turn, usage)); return
            end

            for (i, tc) in enumerate(acc.toolcalls)
                fn = _get(tc, "function")
                name = String(something(_get(fn, "name"), "tool"))
                args = something(_get(fn, "arguments"), Dict{String,Any}())
                bare = _bare_tool(name)
                id = "ollama-$(turn)-$(roundno)-$(i)"
                put!(h.events, ACP.ToolCallStarted(ACP.ToolCall(
                    tool_call_id = id, title = bare, kind = _tool_kind(name),
                    status = :in_progress, raw_input = args)))
                # Mirror the MCP HTTP handler's Activity instrumentation so an agent's
                # in-process tool call ALSO appears in the Server → Activity ring,
                # attributed to THIS agent (not the server). TUI mode only; the agent
                # stream (agent:<id>) carries it regardless.
                tui = GATE_MODE[]
                args_json = try; JSON.json(args); catch; "{}"; end
                inflight = 0
                if tui
                    _push_activity!(:tool_start, bare, h.agent_id, "")
                    inflight = _push_inflight_start!(bare, args_json, h.agent_id)
                end
                t0 = time()
                model_text, acp_content, is_err =
                    _ollama_dispatch(name, args, b.allowed_tools, b.disallowed_tools)
                if tui
                    dur = time() - t0
                    dstr = dur < 1.0 ? string(round(Int, dur * 1000), "ms") :
                           string(round(dur; digits = 1), "s")
                    _push_activity!(:tool_done, bare, h.agent_id, dstr; success = !is_err)
                    _push_inflight_done!(inflight)
                    _push_tool_result!(ToolCallResult(now(), bare, args_json,
                        _tool_result_log_text(model_text), dstr, !is_err, h.agent_id))
                end
                put!(h.events, ACP.ToolCallUpdated(ACP.ToolCallUpdate(
                    tool_call_id = id, status = (is_err ? :failed : :completed),
                    content = acp_content)))
                push!(h.messages, Dict("role" => "tool", "name" => bare,
                                       "content" => model_text))
            end
            # loop: next round feeds the tool results back to the model
        end
        # Ran out of rounds without a final answer.
        put!(h.events, ACP.AgentError("$(b.label): hit max tool rounds ($(b.max_tool_rounds))"))
        put!(h.events, ACP.TurnEnded(:refusal, usage))
    catch e
        e isa InvalidStateException && return   # events channel closed (backend_close)
        put!(h.events, ACP.AgentError("$(b.label) turn crashed: $(sprint(showerror, e))"))
        try; put!(h.events, ACP.TurnEnded(:refusal, usage)); catch; end
    end
end

"""Stream `POST {host}/api/chat` (NDJSON), feeding each line through
`_map_ollama_chunk` into `acc` and emitting the deltas. Honors `h.cancel`."""
function _ollama_stream_chat(host::AbstractString, body, h::OllamaHandle, acc::_OllamaTurnAcc)
    url = rstrip(host, '/') * "/api/chat"
    payload = JSON.json(body)
    HTTP.open("POST", url, ["Content-Type" => "application/json"]) do io
        write(io, payload)
        HTTP.closewrite(io)
        HTTP.startread(io)
        while !eof(io)
            h.cancel[] && break
            line = readline(io)
            isempty(strip(line)) && continue
            local obj
            try
                obj = JSON.parse(line)
            catch
                continue
            end
            for ev in _map_ollama_chunk(obj, acc)
                put!(h.events, ev)
            end
            acc.done && break
        end
        try; HTTP.closeread(io); catch; end
    end
    return nothing
end

backend_interrupt(h::OllamaHandle) = (h.cancel[] = true; true)

function backend_close(h::OllamaHandle)
    h.cancel[] = true
    h.alive[] = false
    try; put!(h.events, ACP.StatusChanged(:dead)); catch; end
    try; close(h.events); catch; end
    nothing
end

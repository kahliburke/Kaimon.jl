# ── Agent backends ────────────────────────────────────────────────────────────
# The thin, vendor-neutral seam. Everything above it (AgentSession, the gate tools,
# the agent:<id> stream) is written once against this interface; only the adapter is
# per-CLI. ClaudeBackend (native `claude -p` stream-JSON) is the first; an
# ACPClientBackend / GeminiBackend slot in later by implementing the same handful of
# methods. All backends emit ACP.AgentEvent — Kaimon's lingua franca (see
# agent_acp_types.jl and docs/src/agents.md).

import JSON

# ── Interface ─────────────────────────────────────────────────────────────────
# A backend is a spawn strategy + config. `backend_start` spawns the process and
# returns an AgentHandle whose `events` Channel carries normalized ACP events.

abstract type AgentBackend end
abstract type AgentHandle end

"`events(h)` — the Channel{ACP.AgentEvent} a consumer drains."
events(h::AgentHandle) = h.events
"Current 1-based turn counter (incremented by `backend_send`)."
current_turn(h::AgentHandle) = h.turn[]

# Each backend implements: backend_start(::AgentBackend; cwd, kwargs...) -> AgentHandle,
# backend_send(h, text), backend_interrupt(h), backend_close(h), backend_status(h).

# ── ClaudeBackend ─────────────────────────────────────────────────────────────

"""
    ClaudeBackend(; model, permission_mode, allowed_tools, mcp_config, strict_mcp)

Drives the local `claude` CLI in headless multi-turn stream-JSON mode. Auth is the
host's own `claude` login (subscription) — we never touch credentials. `mcp_config`
(a path) + `strict_mcp` point the agent at the live Kaimon MCP (M3); omit for plain
chat (M1).
"""
# The agent-management tools an owned agent must NOT be able to call — otherwise an
# agent could recursively spawn/kill agents (fork-bomb). Blocked by default via
# --disallowedTools; a caller can override `disallowed_tools` to allow nested agents.
const AGENT_SELF_TOOLS = ["mcp__kaimon__agent_open", "mcp__kaimon__agent_send",
    "mcp__kaimon__agent_interrupt", "mcp__kaimon__agent_close",
    "mcp__kaimon__agent_status", "mcp__kaimon__agent_list"]

Base.@kwdef struct ClaudeBackend <: AgentBackend
    claude_path::String = _find_claude()
    model::String = "claude-sonnet-4-6"
    permission_mode::String = "acceptEdits"           # default|acceptEdits|plan|bypassPermissions
    allowed_tools::Vector{String} = String[]
    disallowed_tools::Vector{String} = copy(AGENT_SELF_TOOLS)  # recursion guard (see above)
    mcp_config::Union{String,Nothing} = nothing       # path to --mcp-config JSON (M3)
    strict_mcp::Bool = true
    system_prompt::Union{String,Nothing} = nothing    # --append-system-prompt: persistent instructions/context
    dangerously_skip::Bool = false                    # --dangerously-skip-permissions (bypass posture)
    stream::Bool = true                               # --include-partial-messages: token-by-token deltas
end

function _find_claude()
    p = Sys.which("claude")
    p === nothing ? "claude" : p
end

mutable struct ClaudeHandle <: AgentHandle
    backend::ClaudeBackend
    proc::Base.Process
    in::IO                                 # write user turns here
    out::IO                                # read JSONL events here
    events::Channel{ACP.AgentEvent}
    reader::Task
    turn::Base.RefValue{Int}
    session_id::Base.RefValue{String}      # claude's own session id (for transcript path)
    cwd::String
    log_file::String
end

backend_status(h::ClaudeHandle) =
    Base.process_running(h.proc) ? :alive : :dead

# ── Launch marker (orphan reaping, like KAIMON_EXTENSION) ──────────────────────
const KAIMON_AGENT_MARKER = "KAIMON_AGENT_SESSION"

"Build the `claude` argv for a backend + cwd (pure; unit-testable without spawning)."
function _claude_args(b::ClaudeBackend, cwd::AbstractString)
    args = String[b.claude_path, "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--model", b.model,
        "--permission-mode", b.permission_mode,
        "--add-dir", cwd]
    b.stream && push!(args, "--include-partial-messages")   # token-by-token deltas
    if !isempty(b.allowed_tools)
        push!(args, "--allowedTools"); append!(args, b.allowed_tools)
    end
    if !isempty(b.disallowed_tools)
        push!(args, "--disallowedTools"); append!(args, b.disallowed_tools)
    end
    b.dangerously_skip && push!(args, "--dangerously-skip-permissions")
    if b.mcp_config !== nothing
        push!(args, "--mcp-config", b.mcp_config)
        b.strict_mcp && push!(args, "--strict-mcp-config")
    end
    if b.system_prompt !== nothing && !isempty(b.system_prompt)
        push!(args, "--append-system-prompt", b.system_prompt)
    end
    args
end

"""
    backend_start(b::ClaudeBackend; cwd, agent_id, parent_pid) -> ClaudeHandle

Spawn `claude -p` in stream-JSON mode and start the stdout reader task.
"""
function backend_start(b::ClaudeBackend; cwd::String, agent_id::String,
                       parent_pid::Integer = getpid())
    isdir(cwd) || throw(ArgumentError("agent cwd does not exist: $cwd"))

    args = _claude_args(b, cwd)

    env = copy(ENV)
    env[KAIMON_AGENT_MARKER] = agent_id            # marks the process as Kaimon-owned
    env["KAIMON_PARENT_PID"] = string(parent_pid)

    log_dir = joinpath(kaimon_cache_dir(), "agents")
    mkpath(log_dir)
    log_file = joinpath(log_dir, "$(agent_id).log")
    log_io = open(log_file, "a")

    cmd = setenv(Cmd(args), env; dir = cwd)
    proc = open(pipeline(cmd; stderr = log_io), "r+")   # proc.in = write, proc.out = read

    events = Channel{ACP.AgentEvent}(Inf)
    h = ClaudeHandle(b, proc, proc.in, proc.out, events, Task(() -> nothing),
                     Ref(0), Ref(""), cwd, log_file)
    h.reader = _start_reader!(h, log_io)
    h
end

function _start_reader!(h::ClaudeHandle, log_io::IO)
    @async begin
        try
            for line in eachline(h.out)
                isempty(strip(line)) && continue
                local obj
                try
                    obj = JSON.parse(line)
                catch e
                    put!(h.events, ACP.AgentError("stream-json parse error", line))
                    continue
                end
                for ev in _map_claude_event(obj, h.session_id)
                    put!(h.events, ev)
                end
            end
        catch e
            e isa InterruptException || put!(h.events, ACP.AgentError("reader task crashed: $(sprint(showerror, e))"))
        finally
            put!(h.events, ACP.StatusChanged(:dead))
            close(h.events)
            try; close(log_io); catch; end
        end
    end
end

"""
    backend_send(h::ClaudeHandle, text) -> Int

Write one user turn to stdin and return the new turn number. Events for the turn
arrive on `events(h)`.
"""
function backend_send(h::ClaudeHandle, text::AbstractString)
    Base.process_running(h.proc) || throw(ArgumentError("agent process is not running"))
    turn = (h.turn[] += 1)
    msg = Dict("type" => "user",
               "message" => Dict("role" => "user",
                                 "content" => [Dict("type" => "text", "text" => String(text))]))
    write(h.in, JSON.json(msg), "\n")
    flush(h.in)
    put!(h.events, ACP.TurnStarted())
    turn
end

"""
    backend_interrupt(h::ClaudeHandle)

Best-effort cancel of the in-flight turn via the stream-JSON control channel.
(Verify against the installed CLI during manual testing — falls back to a no-op if
the control request isn't accepted.)
"""
function backend_interrupt(h::ClaudeHandle)
    Base.process_running(h.proc) || return false
    ctrl = Dict("type" => "control_request",
                "request_id" => "int-$(h.turn[])",
                "request" => Dict("subtype" => "interrupt"))
    try
        write(h.in, JSON.json(ctrl), "\n"); flush(h.in)
        true
    catch
        false
    end
end

"""Close stdin (ends the conversation), then SIGTERM→SIGKILL the process."""
function backend_close(h::ClaudeHandle)
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
    nothing
end

# ── stream-JSON → ACP mapping ─────────────────────────────────────────────────
# This is what ClaudeBackend exists to do: translate Claude's native event stream
# into ACP.AgentEvent. Field names verified against @anthropic-ai/claude-agent-sdk
# sdk.d.ts (SDKSystemMessage / SDKAssistantMessage / SDKUserMessage / SDKResultMessage).

# claude tool name → ACP ToolKind
function _tool_kind(name::AbstractString)
    n = lowercase(name)
    occursin("read", n)                        ? :read    :
    n in ("edit","write","multiedit","notebookedit") ? :edit    :
    occursin("bash", n) || occursin("exec", n) ? :execute :
    n in ("grep","glob") || occursin("search", n) ? :search :
    occursin("fetch", n) || occursin("websearch", n) ? :fetch :
    n == "todowrite"                           ? :think   : :other
end

_get(d, k, default=nothing) = d isa AbstractDict ? get(d, k, default) : default

"""Map one stream-JSON object to zero or more ACP events. Takes only the
`session_id` Ref it needs from the handle (so it's unit-testable without a process)."""
function _map_claude_event(obj, session_id::Base.RefValue{String})::Vector{ACP.AgentEvent}
    out = ACP.AgentEvent[]
    t = _get(obj, "type")
    if t == "system"
        sid = _get(obj, "session_id")
        sid isa AbstractString && (session_id[] = sid)
        # init = ready; no user-facing event needed
    elseif t == "assistant"
        msg = _get(obj, "message")
        for blk in something(_get(msg, "content"), [])
            bt = _get(blk, "type")
            if bt == "text"
                push!(out, ACP.AgentMessageChunk(ACP.TextBlock(String(something(_get(blk, "text"), "")))))
            elseif bt == "thinking"
                push!(out, ACP.AgentThoughtChunk(ACP.TextBlock(String(something(_get(blk, "thinking"), "")))))
            elseif bt == "tool_use"
                push!(out, ACP.ToolCallStarted(ACP.ToolCall(
                    tool_call_id = String(something(_get(blk, "id"), "")),
                    title = String(something(_get(blk, "name"), "tool")),
                    kind = _tool_kind(something(_get(blk, "name"), "")),
                    status = :in_progress,
                    raw_input = _get(blk, "input"))))
            end
        end
    elseif t == "user"
        msg = _get(obj, "message")
        content = _get(msg, "content")
        if content isa AbstractVector
            for blk in content
                if _get(blk, "type") == "tool_result"
                    is_err = something(_get(blk, "is_error"), false) === true
                    push!(out, ACP.ToolCallUpdated(ACP.ToolCallUpdate(
                        tool_call_id = String(something(_get(blk, "tool_use_id"), "")),
                        status = is_err ? :failed : :completed,
                        content = _tool_result_content(_get(blk, "content")))))
                end
            end
        end
    elseif t == "stream_event"
        # Partial deltas (--include-partial-messages): stream assistant text/thinking
        # token chunks for liveness. The final complete `assistant` message still arrives
        # and is the authoritative copy (delta=false). See docs/src/agents.md.
        sev = _get(obj, "event")
        if _get(sev, "type") == "content_block_delta"
            d = _get(sev, "delta")
            dt = _get(d, "type")
            if dt == "text_delta"
                push!(out, ACP.AgentMessageChunk(ACP.TextBlock(String(something(_get(d, "text"), ""))), true))
            elseif dt == "thinking_delta"
                push!(out, ACP.AgentThoughtChunk(ACP.TextBlock(String(something(_get(d, "thinking"), ""))), true))
            end
            # input_json_delta (tool-input streaming) intentionally ignored for v1
        end
        # content_block_start/stop, message_*, signature_delta: ignored — the complete
        # `assistant` message handles block boundaries and authoritative content.
    elseif t == "result"
        usage = _claude_usage(_get(obj, "usage"), _get(obj, "total_cost_usd"))
        sr = _get(obj, "stop_reason")
        stop = sr isa AbstractString ? ACP.as_enum(sr, ACP.STOP_REASONS, :end_turn) :
               (something(_get(obj, "is_error"), false) === true ? :refusal : :end_turn)
        push!(out, ACP.TurnEnded(stop, usage))
    end
    out
end

# tool_result.content is either a string or an array of {type:text|image,...}
function _tool_result_content(content)::Vector{ACP.ToolCallContent}
    out = ACP.ToolCallContent[]
    if content isa AbstractString
        push!(out, ACP.ContentToolContent(ACP.TextBlock(String(content))))
    elseif content isa AbstractVector
        for blk in content
            bt = _get(blk, "type")
            if bt == "text"
                push!(out, ACP.ContentToolContent(ACP.TextBlock(String(something(_get(blk, "text"), "")))))
            elseif bt == "image"
                src = _get(blk, "source")
                push!(out, ACP.ContentToolContent(ACP.ImageBlock(
                    String(something(_get(src, "data"), "")),
                    String(something(_get(src, "media_type"), "image/png")))))
            end
        end
    end
    out
end

function _claude_usage(u, cost)::ACP.Usage
    u isa AbstractDict || return ACP.Usage(cost_usd = (cost isa Number ? Float64(cost) : nothing))
    ACP.Usage(
        input_tokens         = Int(something(_get(u, "input_tokens"), 0)),
        output_tokens        = Int(something(_get(u, "output_tokens"), 0)),
        cache_read_tokens    = Int(something(_get(u, "cache_read_input_tokens"), 0)),
        cache_creation_tokens= Int(something(_get(u, "cache_creation_input_tokens"), 0)),
        cost_usd             = cost isa Number ? Float64(cost) : nothing)
end

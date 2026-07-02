# ── Agent backends ────────────────────────────────────────────────────────────
# The thin, vendor-neutral seam. Everything above it (AgentSession, the gate tools,
# the agent:<id> stream) is written once against this interface; only the adapter is
# per-CLI. ClaudeBackend (native `claude -p` stream-JSON) is the first; an
# ACPClientBackend / GeminiBackend slot in later by implementing the same handful of
# methods. All backends emit ACP.AgentEvent — Kaimon's lingua franca (see
# agent_acp_types.jl and docs/src/agents.md).

import JSON
import PNGFiles
import Base64
using ColorTypes: RGBA, red, green, blue, alpha
using FixedPointNumbers: N0f8

# ── Interface ─────────────────────────────────────────────────────────────────
# A backend is a spawn strategy + config. `backend_start` spawns the process and
# returns an AgentHandle whose `events` Channel carries normalized ACP events.

abstract type AgentBackend end
abstract type AgentHandle end

"`events(h)` — the Channel{ACP.AgentEvent} a consumer drains."
events(h::AgentHandle) = h.events
"Current 1-based turn counter (incremented by `backend_send`)."
current_turn(h::AgentHandle) = h.turn[]
"OS pid of the backing process, or `nothing` for process-less backends (Ollama)."
backend_pid(::AgentHandle) = nothing
"Vendor session id for the transcript path; `\"\"` if the backend keeps no transcript."
backend_session_id(::AgentHandle) = ""

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
    "mcp__kaimon__agent_run",
    "mcp__kaimon__agent_interrupt", "mcp__kaimon__agent_close",
    "mcp__kaimon__agent_status", "mcp__kaimon__agent_list"]

Base.@kwdef struct ClaudeBackend <: AgentBackend
    claude_path::String = _find_claude()
    model::String = "sonnet"                          # family alias → the CLI's latest Sonnet (auto-tracks new releases)
    permission_mode::String = "acceptEdits"           # default|acceptEdits|plan|bypassPermissions
    allowed_tools::Vector{String} = String[]
    disallowed_tools::Vector{String} = copy(AGENT_SELF_TOOLS)  # recursion guard (see above)
    mcp_config::Union{String,Nothing} = nothing       # path to --mcp-config JSON (M3)
    strict_mcp::Bool = true
    system_prompt::Union{String,Nothing} = nothing    # --append-system-prompt: persistent instructions/context
    dangerously_skip::Bool = false                    # --dangerously-skip-permissions (bypass posture)
    stream::Bool = true                               # --include-partial-messages: token-by-token deltas
    effort::Union{String,Nothing} = nothing           # --effort <level>: thinking/effort level (lower = faster turns)
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
    tool_blocks::Dict{Int,String}          # streamed content-block index → tool_call_id (input deltas)
    cwd::String
    log_file::String
    ctrl_seq::Base.RefValue{Int}           # monotonic id for control requests (interrupts)
end

backend_status(h::ClaudeHandle) =
    Base.process_running(h.proc) ? :alive : :dead
backend_pid(h::ClaudeHandle) = getpid(h.proc)
backend_session_id(h::ClaudeHandle) = h.session_id[]

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
    if b.effort !== nothing && !isempty(b.effort)
        push!(args, "--effort", b.effort)                   # less thinking → faster round-trips
    end
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
                     Ref(0), Ref(""), Dict{Int,String}(), cwd, log_file, Ref(0))
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
                for ev in _map_claude_event(obj, h.session_id, h.tool_blocks)
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
                "request_id" => "int-$(h.ctrl_seq[] += 1)",   # unique per interrupt (no collisions)
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
function _map_claude_event(obj, session_id::Base.RefValue{String},
                           tool_blocks::Dict{Int,String} = Dict{Int,String}())::Vector{ACP.AgentEvent}
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
                # The authoritative call with full, parsed input. For a streamed call
                # this is the *second* tool_use for the id — the one announced at
                # content_block_start had no input yet; consumers replace by toolCallId.
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
        # Partial deltas (--include-partial-messages): stream assistant text/thinking and
        # tool-call input token chunks for liveness. The final complete `assistant` message
        # still arrives and is authoritative (delta=false / a tool-call update). See agents.md.
        sev = _get(obj, "event")
        et = _get(sev, "type")
        if et == "content_block_start"
            # A tool call begins: announce it immediately (the call appears before its args
            # finish) and remember its block index so the input deltas below can address it.
            cb = _get(sev, "content_block")
            if _get(cb, "type") == "tool_use"
                idx = Int(something(_get(sev, "index"), -1))
                tid = String(something(_get(cb, "id"), ""))
                tool_blocks[idx] = tid
                push!(out, ACP.ToolCallStarted(ACP.ToolCall(
                    tool_call_id = tid,
                    title = String(something(_get(cb, "name"), "tool")),
                    kind = _tool_kind(something(_get(cb, "name"), "")),
                    status = :in_progress)))
            end
        elseif et == "content_block_delta"
            d = _get(sev, "delta")
            dt = _get(d, "type")
            if dt == "text_delta"
                push!(out, ACP.AgentMessageChunk(ACP.TextBlock(String(something(_get(d, "text"), ""))), true))
            elseif dt == "thinking_delta"
                push!(out, ACP.AgentThoughtChunk(ACP.TextBlock(String(something(_get(d, "thinking"), ""))), true))
            elseif dt == "input_json_delta"
                idx = Int(something(_get(sev, "index"), -1))
                push!(out, ACP.ToolInputDelta(get(tool_blocks, idx, ""),
                                              String(something(_get(d, "partial_json"), ""))))
            end
        end
        # content_block_stop, message_*, signature_delta: ignored — the complete
        # `assistant` message handles block boundaries and authoritative content.
    elseif t == "result"
        empty!(tool_blocks)   # per-turn streaming state; ids are unique so this is just hygiene
        usage = _claude_usage(_get(obj, "usage"), _get(obj, "total_cost_usd"))
        sr = _get(obj, "stop_reason")
        is_err = something(_get(obj, "is_error"), false) === true
        # A failed turn (API 429/overloaded, max-turns, execution error) otherwise
        # collapses to TurnEnded(:refusal) with no detail — the error text/subtype the
        # CLI carries in the `result` event is dropped. Surface it as an AgentError so
        # observers and the rate governor can classify it (e.g. is_rate_limited). The CLI
        # retries transient 429s internally and only emits this once it has given up.
        if is_err
            subtype = _get(obj, "subtype")          # e.g. "error_during_execution", "error_max_turns"
            rtext   = _get(obj, "result")           # error description / final text
            msg = rtext isa AbstractString && !isempty(rtext) ? String(rtext) :
                  subtype isa AbstractString ? String(subtype) : "agent turn failed"
            push!(out, ACP.AgentError(msg, Dict("subtype" => subtype, "is_error" => true,
                                                "result" => rtext)))
        end
        stop = sr isa AbstractString ? ACP.as_enum(sr, ACP.STOP_REASONS, :end_turn) :
               (is_err ? :refusal : :end_turn)
        push!(out, ACP.TurnEnded(stop, usage))
    elseif t == "control_response"
        # Ack for a control request we sent (e.g. an interrupt). Surface failures as an
        # AgentError so a dropped/ rejected interrupt is observable; a success needs no
        # user-facing event (a real cancel also lands as result{stopReason: cancelled}).
        resp = _get(obj, "response")
        if _get(resp, "subtype") == "error"
            push!(out, ACP.AgentError(
                "control request failed: " * String(something(_get(resp, "error"), "unknown")),
                Dict("request_id" => _get(resp, "request_id"))))
        end
    end
    out
end

# ── Image downscaling (tool-result PNGs) ──────────────────────────────────────
# Vision tool-results (Makie plots, etc.) are the biggest Agent-SDK-credit burner.
# Anthropic bills images ≈ (w×h)/750 tokens and auto-downscales anything over ~1568px
# long edge / ~1.15 MP — so we cap the long edge to a configurable max (default 1568,
# the model's own effective resolution: never ship more than it uses; lower it to trade
# image quality for credit). Box-average downscale via PNGFiles — no heavy image stack.

"""Max image long-edge (px) before tool-result PNGs are downsampled. Global config key
`agent_image_max_long_edge` in `~/.config/kaimon/config.json`; default 1568."""
function _agent_image_max_edge()
    try
        d = JSON.parsefile(get_global_config_path())
        v = get(d, "agent_image_max_long_edge", 1568)
        v isa Integer && return Int(v)
        v isa Real && return round(Int, v)
    catch
    end
    return 1568
end

"""Box-average downscale a base64 PNG so its long edge ≤ `max_edge`, returning the
re-encoded base64. If already within bound, `max_edge ≤ 0`, or anything fails, returns
the input unchanged — a resize hiccup must never drop a tool result."""
function _downscale_png_b64(b64::AbstractString, max_edge::Integer)
    max_edge > 0 || return String(b64)
    try
        img = PNGFiles.load(IOBuffer(Base64.base64decode(b64)))   # Matrix{<:Colorant}
        h, w = size(img)
        long = max(h, w)
        long <= max_edge && return String(b64)
        factor = cld(long, max_edge)                              # integer box factor → ≤ max_edge
        oh, ow = cld(h, factor), cld(w, factor)
        out = Matrix{RGBA{N0f8}}(undef, oh, ow)
        @inbounds for oj in 1:ow, oi in 1:oh
            i0 = (oi - 1) * factor + 1; i1 = min(i0 + factor - 1, h)
            j0 = (oj - 1) * factor + 1; j1 = min(j0 + factor - 1, w)
            ar = ag = ab = aa = 0.0f0; n = 0
            for j in j0:j1, i in i0:i1
                px = img[i, j]
                ar += Float32(red(px)); ag += Float32(green(px))
                ab += Float32(blue(px)); aa += Float32(alpha(px)); n += 1
            end
            out[oi, oj] = RGBA{N0f8}(clamp(ar / n, 0f0, 1f0), clamp(ag / n, 0f0, 1f0),
                                     clamp(ab / n, 0f0, 1f0), clamp(aa / n, 0f0, 1f0))
        end
        io = IOBuffer(); PNGFiles.save(io, out)
        return Base64.base64encode(take!(io))
    catch
        return String(b64)
    end
end

# tool_result.content is either a string or an array of {type:text|image,...}
function _tool_result_content(content)::Vector{ACP.ToolCallContent}
    out = ACP.ToolCallContent[]
    if content isa AbstractString
        push!(out, ACP.ContentToolContent(ACP.TextBlock(String(content))))
    elseif content isa AbstractVector
        max_edge = _agent_image_max_edge()                # read config once per result
        for blk in content
            bt = _get(blk, "type")
            if bt == "text"
                push!(out, ACP.ContentToolContent(ACP.TextBlock(String(something(_get(blk, "text"), "")))))
            elseif bt == "image"
                src = _get(blk, "source")
                data = String(something(_get(src, "data"), ""))
                mime = String(something(_get(src, "media_type"), "image/png"))
                mime == "image/png" && (data = _downscale_png_b64(data, max_edge))
                push!(out, ACP.ContentToolContent(ACP.ImageBlock(data, mime)))
            end
        end
    end
    out
end

# ── Rich MCP tool results (images) ────────────────────────────────────────────
# Tool handlers can return an image via `KaimonGate.image_result` (a sentinel-
# tagged JSON envelope String). `_build_tool_content` unwraps it at tool-result
# egress (MCPServer), downsamples image blocks *here* — before the result reaches
# the agent — and emits real MCP content blocks. This is the cost lever for
# tool-result images (unlike the stream-output downscaler above, which only
# governs what we forward to the log/bus after the model already paid).

"""Max long-edge (px) for images returned *in MCP tool results* — the resolution
the agent actually consumes (and pays vision tokens for). Global config key
`tool_image_max_long_edge` in `~/.config/kaimon/config.json`; default 1024.
Distinct from `agent_image_max_long_edge`, which caps streamed-result images on the
display/forwarding path."""
function _tool_image_max_edge()
    try
        d = JSON.parsefile(get_global_config_path())
        v = get(d, "tool_image_max_long_edge", 1024)
        v isa Integer && return Int(v)
        v isa Real && return round(Int, v)
    catch
    end
    return 1024
end

"""
    _build_tool_content(result_text) -> (content::Vector, is_error::Bool)

Turn a tool handler's (stringified) return into the MCP `content` array. A plain
string becomes a single text block — the overwhelming default, unchanged. A string
carrying `KaimonGate.MCP_CONTENT_SENTINEL` is parsed into structured content;
`image/png` blocks are downsampled to `_tool_image_max_edge()` before reaching the
model. A malformed envelope falls back to a text block, so a result is never
dropped."""
function _build_tool_content(result_text::AbstractString)
    sentinel = KaimonGate.MCP_CONTENT_SENTINEL
    startswith(result_text, sentinel) ||
        return (Any[Dict("type" => "text", "text" => result_text)], false)
    try
        env = JSON.parse(chop(result_text; head = length(sentinel), tail = 0))
        max_edge = _tool_image_max_edge()
        blocks = Any[]
        for b in env["content"]
            if get(b, "type", "") == "image" && get(b, "mimeType", "") == "image/png"
                b = merge(b, Dict("data" => _downscale_png_b64(String(b["data"]), max_edge)))
            end
            push!(blocks, b)
        end
        return (blocks, get(env, "isError", false) === true)
    catch
        return (Any[Dict("type" => "text", "text" => result_text)], false)
    end
end

"""Log-safe stand-in for a tool result on the TUI activity ring / SQLite: a rich
content envelope is collapsed to a short note instead of dumping ~1 MB of base64."""
function _tool_result_log_text(s::AbstractString)
    startswith(s, KaimonGate.MCP_CONTENT_SENTINEL) || return s
    return "[MCP rich content — $(round(Int, ncodeunits(s) / 1024)) KB envelope]"
end

"""Server-side mirror of `KaimonGate.image_result` for native (in-process) Kaimon
tools — returns the same sentinel envelope so an in-server tool can return an
image. `png` is raw image bytes (base64-encoded internally)."""
image_result(png::AbstractVector{UInt8}; mime::AbstractString = "image/png",
    text::AbstractString = "") = KaimonGate.image_result(png; mime, text)

# WIP: cost is zeroed for now. claude's reported `total_cost_usd` is inaccurate /
# misleading (especially on subscription plans), so we don't surface it. The
# `cost_usd` field is kept in the schema (UsageUpdated/TurnEnded payloads,
# agent_status) but always reads 0.0 until we compute a real figure — the `cost`
# arg is intentionally ignored. TODO: replace with a real per-turn cost estimate.
function _claude_usage(u, cost)::ACP.Usage
    u isa AbstractDict || return ACP.Usage(cost_usd = 0.0)
    ACP.Usage(
        input_tokens         = Int(something(_get(u, "input_tokens"), 0)),
        output_tokens        = Int(something(_get(u, "output_tokens"), 0)),
        cache_read_tokens    = Int(something(_get(u, "cache_read_input_tokens"), 0)),
        cache_creation_tokens= Int(something(_get(u, "cache_creation_input_tokens"), 0)),
        cost_usd             = 0.0)
end

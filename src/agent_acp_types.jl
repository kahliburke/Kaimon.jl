# ── ACP update model (native Julia) ───────────────────────────────────────────
# Kaimon's vendor-neutral lingua franca for agent sessions. These types mirror the
# Agent Client Protocol schema ($defs in @agentclientprotocol/sdk/schema/schema.json,
# protocol v1) — curated to the *update model* a UI actually needs, not the full
# 255-def surface. Every AgentBackend (ClaudeBackend now; ACPClientBackend/Gemini
# later) maps its native events into these types; the gate stream and consumers
# (KaimonSlate) only ever see this shape.
#
# NOTE: we do NOT run the ACP wire protocol to Claude — Claude has no native ACP
# agent (only a Node adapter). We adopt ACP's *data model* and feed it from Claude's
# native `claude -p` stream-JSON. See docs/src/agents.md.
module ACP

import JSON

# ── Closed enums (schema string literals) ─────────────────────────────────────
# Represented as validated Symbols rather than @enum: JSON-clean (Symbol↔string),
# and collision-free (the schema reuses pending/in_progress/completed across
# ToolCallStatus and PlanEntryStatus, which would clash as @enum members).

const TOOL_CALL_STATUSES = (:pending, :in_progress, :completed, :failed)
const TOOL_KINDS         = (:read, :edit, :delete, :move, :search, :execute,
                            :think, :fetch, :switch_mode, :other)
const STOP_REASONS       = (:end_turn, :max_tokens, :max_turn_requests,
                            :refusal, :cancelled)
const PERMISSION_KINDS   = (:allow_once, :allow_always, :reject_once, :reject_always)
const PLAN_PRIORITIES    = (:high, :medium, :low)
const PLAN_STATUSES      = (:pending, :in_progress, :completed)

"""Coerce a JSON string / Symbol to one of `allowed`, falling back to `fallback`."""
function as_enum(x, allowed::Tuple, fallback::Symbol)
    s = x isa Symbol ? x : Symbol(string(x))
    s in allowed ? s : fallback
end

# ── Content blocks (schema: ContentBlock union) ───────────────────────────────
# type ∈ {text, image, audio, resource_link, resource}

abstract type ContentBlock end

"schema: TextContent"
struct TextBlock <: ContentBlock
    text::String
end

"""schema: ImageContent. `data` is base64. This is the load-bearing path for
"the agent must SEE results" — vision models iterate on returned PNGs/plots."""
struct ImageBlock <: ContentBlock
    data::String                       # base64
    mime_type::String
    uri::Union{String,Nothing}
end
ImageBlock(data, mime_type) = ImageBlock(data, mime_type, nothing)

"schema: AudioContent"
struct AudioBlock <: ContentBlock
    data::String                       # base64
    mime_type::String
end

"schema: ResourceLink (type=resource_link)"
struct ResourceLinkBlock <: ContentBlock
    uri::String
    name::Union{String,Nothing}
    mime_type::Union{String,Nothing}
end

"schema: EmbeddedResource (type=resource) — kept minimal; carries text or blob."
struct ResourceBlock <: ContentBlock
    uri::String
    text::Union{String,Nothing}
    blob::Union{String,Nothing}        # base64
    mime_type::Union{String,Nothing}
end

# ── Tool calls (schema: ToolCall / ToolCallUpdate / ToolCallContent) ───────────

"schema: ToolCallLocation"
struct ToolCallLocation
    path::String
    line::Union{Int,Nothing}
end

abstract type ToolCallContent end

"schema: ToolCallContent type=content — a wrapped ContentBlock (incl. images)."
struct ContentToolContent <: ToolCallContent
    content::ContentBlock
end

"schema: ToolCallContent type=diff"
struct DiffToolContent <: ToolCallContent
    path::String
    old_text::Union{String,Nothing}
    new_text::String
end

"schema: ToolCallContent type=terminal"
struct TerminalToolContent <: ToolCallContent
    terminal_id::String
end

"schema: ToolCall (a new tool invocation, status usually :pending/:in_progress)."
Base.@kwdef struct ToolCall
    tool_call_id::String
    title::String
    kind::Symbol = :other                                  # TOOL_KINDS
    status::Symbol = :pending                              # TOOL_CALL_STATUSES
    content::Vector{ToolCallContent} = ToolCallContent[]
    locations::Vector{ToolCallLocation} = ToolCallLocation[]
    raw_input::Any = nothing
    raw_output::Any = nothing
end

"""schema: ToolCallUpdate (a delta to an existing call; every field but the id is
optional). Used for status transitions and to attach results/output."""
Base.@kwdef struct ToolCallUpdate
    tool_call_id::String
    title::Union{String,Nothing} = nothing
    kind::Union{Symbol,Nothing} = nothing
    status::Union{Symbol,Nothing} = nothing
    content::Union{Vector{ToolCallContent},Nothing} = nothing
    locations::Union{Vector{ToolCallLocation},Nothing} = nothing
    raw_input::Any = nothing
    raw_output::Any = nothing
end

# ── Plan & permissions ────────────────────────────────────────────────────────

"schema: PlanEntry"
struct PlanEntry
    content::String
    priority::Symbol            # PLAN_PRIORITIES
    status::Symbol              # PLAN_STATUSES
end

"schema: PermissionOption"
struct PermissionOption
    option_id::String
    name::String
    kind::Symbol                # PERMISSION_KINDS
end

# ── Usage / cost (schema: Usage; augmented with Claude result cost fields) ─────

"""Token usage + cost for a turn. ACP carries a Usage; Claude's `result` event adds
`total_cost_usd`. Both surface here so the gate can track per-session spend against
the post-June-15 Agent SDK credit (see plan §Cost model)."""
Base.@kwdef struct Usage
    input_tokens::Int = 0
    output_tokens::Int = 0
    cache_read_tokens::Int = 0
    cache_creation_tokens::Int = 0
    cost_usd::Union{Float64,Nothing} = nothing
end

Base.:+(a::Usage, b::Usage) = Usage(
    a.input_tokens + b.input_tokens,
    a.output_tokens + b.output_tokens,
    a.cache_read_tokens + b.cache_read_tokens,
    a.cache_creation_tokens + b.cache_creation_tokens,
    _addcost(a.cost_usd, b.cost_usd),
)
_addcost(::Nothing, ::Nothing) = nothing
_addcost(a, ::Nothing) = a
_addcost(::Nothing, b) = b
_addcost(a, b) = a + b

# ── Normalized event union (schema: SessionUpdate variants + turn lifecycle) ──
# Concrete subtypes map 1:1 to the ACP sessionUpdate discriminators, plus a few
# turn-level events derived from PromptResponse / process lifecycle that a UI needs.

abstract type AgentEvent end

"""sessionUpdate=agent_message_chunk — streamed assistant text/content. `delta=true`
is an incremental token chunk to append; `delta=false` (the default) is a complete,
authoritative block. See docs/src/agents.md (token streaming)."""
struct AgentMessageChunk <: AgentEvent
    content::ContentBlock
    delta::Bool
end
AgentMessageChunk(content::ContentBlock) = AgentMessageChunk(content, false)
"sessionUpdate=agent_thought_chunk — streamed reasoning. `delta` as in `AgentMessageChunk`."
struct AgentThoughtChunk <: AgentEvent
    content::ContentBlock
    delta::Bool
end
AgentThoughtChunk(content::ContentBlock) = AgentThoughtChunk(content, false)
"sessionUpdate=user_message_chunk — echo of the user's own input."
struct UserMessageChunk <: AgentEvent; content::ContentBlock; end
"sessionUpdate=tool_call — a new tool invocation."
struct ToolCallStarted <: AgentEvent; call::ToolCall; end
"sessionUpdate=tool_call_update — status/result delta for a call."
struct ToolCallUpdated <: AgentEvent; update::ToolCallUpdate; end
"""Kaimon extension (not an ACP sessionUpdate): a streamed fragment of a tool call's
input JSON, emitted token-by-token for liveness while the model writes the call's
arguments. `partial_json` chunks concatenate to the tool's full input (not valid JSON
until complete); the authoritative input arrives as a later tool-call update. See
docs/src/agents.md (tool-input streaming)."""
struct ToolInputDelta <: AgentEvent
    tool_call_id::String
    partial_json::String
end
"sessionUpdate=plan / plan_update — the agent's execution plan."
struct PlanUpdated <: AgentEvent; entries::Vector{PlanEntry}; end
"sessionUpdate=usage_update — running token/cost usage."
struct UsageUpdated <: AgentEvent; usage::Usage; end

# Turn-level / lifecycle (not ACP sessionUpdate, but needed by consumers):
"Turn began (we wrote a prompt; agent started working)."
struct TurnStarted <: AgentEvent; end
"""Turn finished. `stop_reason` ∈ STOP_REASONS; `usage` is the turn total
(from Claude's `result` event / ACP PromptResponse)."""
struct TurnEnded <: AgentEvent
    stop_reason::Symbol
    usage::Union{Usage,Nothing}
end
"A backend/process error (parse failure, crash, non-zero exit)."
struct AgentError <: AgentEvent; message::String; data::Any; end
AgentError(message::AbstractString) = AgentError(String(message), nothing)
"Session status transition (:starting/:idle/:working/:dead)."
struct StatusChanged <: AgentEvent; status::Symbol; end
"""Agent is asking the user to approve a tool call (schema:
RequestPermissionRequest). `request_id` lets the consumer route the answer back."""
struct PermissionRequested <: AgentEvent
    tool_call::ToolCallUpdate
    options::Vector{PermissionOption}
    request_id::String
end

# ── Wire form: {kind, turn, data} envelope ────────────────────────────────────
# `event_kind` is the stream envelope's discriminator; `event_payload` is a
# JSON-ready Dict. The gate publishes these on channel "agent:<id>"; consumers
# (KaimonSlate→SSE) JSON-encode `payload` at the browser edge.

event_kind(::AgentMessageChunk)  = :assistant_text
event_kind(::AgentThoughtChunk)  = :thought
event_kind(::UserMessageChunk)   = :user_text
event_kind(::ToolCallStarted)    = :tool_use
event_kind(::ToolCallUpdated)    = :tool_result
event_kind(::ToolInputDelta)     = :tool_input_delta
event_kind(::PlanUpdated)        = :plan
event_kind(::UsageUpdated)       = :usage
event_kind(::TurnStarted)        = :turn_started
event_kind(::TurnEnded)          = :result
event_kind(::AgentError)         = :error
event_kind(::StatusChanged)      = :status
event_kind(::PermissionRequested)= :permission

# content block → Dict
to_dict(b::TextBlock)         = Dict("type"=>"text", "text"=>b.text)
to_dict(b::ImageBlock)        = Dict("type"=>"image", "data"=>b.data, "mimeType"=>b.mime_type, "uri"=>b.uri)
to_dict(b::AudioBlock)        = Dict("type"=>"audio", "data"=>b.data, "mimeType"=>b.mime_type)
to_dict(b::ResourceLinkBlock) = Dict("type"=>"resource_link", "uri"=>b.uri, "name"=>b.name, "mimeType"=>b.mime_type)
to_dict(b::ResourceBlock)     = Dict("type"=>"resource", "uri"=>b.uri, "text"=>b.text, "blob"=>b.blob, "mimeType"=>b.mime_type)

to_dict(l::ToolCallLocation) = Dict("path"=>l.path, "line"=>l.line)
to_dict(c::ContentToolContent)  = Dict("type"=>"content", "content"=>to_dict(c.content))
to_dict(c::DiffToolContent)     = Dict("type"=>"diff", "path"=>c.path, "oldText"=>c.old_text, "newText"=>c.new_text)
to_dict(c::TerminalToolContent) = Dict("type"=>"terminal", "terminalId"=>c.terminal_id)

to_dict(t::ToolCall) = Dict(
    "toolCallId"=>t.tool_call_id, "title"=>t.title, "kind"=>string(t.kind),
    "status"=>string(t.status), "content"=>[to_dict(c) for c in t.content],
    "locations"=>[to_dict(l) for l in t.locations],
    "rawInput"=>t.raw_input, "rawOutput"=>t.raw_output)

function to_dict(t::ToolCallUpdate)
    d = Dict{String,Any}("toolCallId"=>t.tool_call_id)
    t.title    !== nothing && (d["title"]   = t.title)
    t.kind     !== nothing && (d["kind"]    = string(t.kind))
    t.status   !== nothing && (d["status"]  = string(t.status))
    t.content  !== nothing && (d["content"] = [to_dict(c) for c in t.content])
    t.locations!== nothing && (d["locations"]= [to_dict(l) for l in t.locations])
    t.raw_input  !== nothing && (d["rawInput"]  = t.raw_input)
    t.raw_output !== nothing && (d["rawOutput"] = t.raw_output)
    d
end

to_dict(e::PlanEntry)       = Dict("content"=>e.content, "priority"=>string(e.priority), "status"=>string(e.status))
to_dict(o::PermissionOption)= Dict("optionId"=>o.option_id, "name"=>o.name, "kind"=>string(o.kind))
to_dict(u::Usage) = Dict(
    "inputTokens"=>u.input_tokens, "outputTokens"=>u.output_tokens,
    "cacheReadTokens"=>u.cache_read_tokens, "cacheCreationTokens"=>u.cache_creation_tokens,
    "costUsd"=>u.cost_usd)

event_payload(e::AgentMessageChunk) = Dict("delta"=>e.delta, "content"=>to_dict(e.content))
event_payload(e::AgentThoughtChunk) = Dict("delta"=>e.delta, "content"=>to_dict(e.content))
event_payload(e::UserMessageChunk)  = Dict("content"=>to_dict(e.content))
event_payload(e::ToolCallStarted)   = Dict("call"=>to_dict(e.call))
event_payload(e::ToolCallUpdated)   = Dict("update"=>to_dict(e.update))
event_payload(e::ToolInputDelta)    = Dict("toolCallId"=>e.tool_call_id, "partialJson"=>e.partial_json)
event_payload(e::PlanUpdated)       = Dict("entries"=>[to_dict(x) for x in e.entries])
event_payload(e::UsageUpdated)      = Dict("usage"=>to_dict(e.usage))
event_payload(::TurnStarted)        = Dict{String,Any}()
event_payload(e::TurnEnded)         = Dict("stopReason"=>string(e.stop_reason),
                                           "usage"=>(e.usage === nothing ? nothing : to_dict(e.usage)))
event_payload(e::AgentError)        = Dict("message"=>e.message, "data"=>e.data)
event_payload(e::StatusChanged)     = Dict("status"=>string(e.status))
event_payload(e::PermissionRequested)= Dict("toolCall"=>to_dict(e.tool_call),
                                            "options"=>[to_dict(o) for o in e.options],
                                            "requestId"=>e.request_id)

"""
    envelope(e::AgentEvent, turn::Int) -> NamedTuple

The `{kind, turn, data}` wire message published on the gate stream channel
`agent:<id>`. `data` is a JSON-ready Dict.
"""
envelope(e::AgentEvent, turn::Int) = (kind = event_kind(e), turn = turn, data = event_payload(e))

end # module ACP

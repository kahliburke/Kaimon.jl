# ── Agent Session Manager ─────────────────────────────────────────────────────
# Kaimon-owned AI agent sessions: spawn/own a `claude` process (via an AgentBackend),
# relay its normalized ACP events onto the gate event bus on channel "agent:<id>",
# and track lifecycle + per-session cost. The natural sibling of a gate REPL session
# and a managed extension. See AGENT_SESSION_SERVICE_PLAN.md.
#
# The manager lives in the main Kaimon process (beside the ConnectionManager). Events
# are published on the ConnectionManager's global event PUB (kaimon-events.sock) — the
# same bus extensions already subscribe to — so consumers (KaimonSlate) drain
# "agent:<id>" exactly like any other event topic.

import JSON

"""
    AgentSession

One owned agent process + its event relay. Status FSM:
`:starting → :idle ⇄ :working → :dead`.
"""
mutable struct AgentSession
    id::String
    backend::AgentBackend
    handle::AgentHandle
    cwd::String
    model::String
    status::Symbol
    relay::Task
    created_at::Float64
    last_activity::Float64
    usage::ACP.Usage              # running cost/token total across all turns
    recent::Vector{Any}           # ring buffer of (t,kind,summary) for the TUI monitor
    lock::ReentrantLock
end

const AGENT_SESSIONS = Dict{String,AgentSession}()
const AGENT_SESSIONS_LOCK = ReentrantLock()

_gen_agent_id() = bytes2hex(rand(UInt8, 4))

# ── Open ──────────────────────────────────────────────────────────────────────

"""
    agent_open(; cwd, model, permission_mode, allowed_tools, mcp_config, id) -> String

Spawn and own a new agent. Returns the agent id. Events stream on the gate bus
channel `agent:<id>`.
"""
function agent_open(; cwd::String,
                    model::String = "claude-sonnet-4-6",
                    permission_mode::String = "acceptEdits",
                    allowed_tools::Vector{String} = String[],
                    disallowed_tools::Vector{String} = copy(AGENT_SELF_TOOLS),
                    mcp_config::Union{String,Nothing} = nothing,
                    system_prompt::Union{String,Nothing} = nothing,
                    id::Union{String,Nothing} = nothing)
    aid = id === nothing ? _gen_agent_id() : id
    lock(AGENT_SESSIONS_LOCK) do
        haskey(AGENT_SESSIONS, aid) && error("agent id already in use: $aid")
    end

    backend = ClaudeBackend(; model = model, permission_mode = permission_mode,
                            allowed_tools = allowed_tools, disallowed_tools = disallowed_tools,
                            mcp_config = mcp_config, system_prompt = system_prompt)
    handle = backend_start(backend; cwd = cwd, agent_id = aid)
    _record_agent_pid!(aid, getpid(handle.proc))
    # Start a fresh Kaimon-owned event log for this agent instance.
    try
        p = _event_log_path(aid)
        mkpath(dirname(p))
        write(p, "")
    catch
    end

    s = AgentSession(aid, backend, handle, cwd, model, :starting,
                     Task(() -> nothing), time(), time(), ACP.Usage(), Any[], ReentrantLock())
    s.relay = _start_relay!(s)
    lock(AGENT_SESSIONS_LOCK) do
        AGENT_SESSIONS[aid] = s
    end
    _set_status!(s, :idle)
    _push_log!(:info, "Agent '$aid' opened (model=$model, cwd=$cwd, pid=$(getpid(handle.proc)))")
    aid
end

function _start_relay!(s::AgentSession)
    @async begin
        try
            for ev in events(s.handle)
                # fold lifecycle + cost into session state
                if ev isa ACP.TurnStarted
                    _set_status!(s, :working)
                elseif ev isa ACP.TurnEnded
                    ev.usage === nothing || (s.usage = s.usage + ev.usage)
                    _set_status!(s, :idle)
                elseif ev isa ACP.UsageUpdated
                    s.usage = s.usage + ev.usage
                elseif ev isa ACP.StatusChanged && ev.status === :dead
                    _set_status!(s, :dead)
                end
                s.last_activity = time()
                _push_recent!(s, ev)
                env = ACP.envelope(ev, current_turn(s.handle))
                _log_event!(s.id, env)                       # Kaimon-owned JSONL (we control the schema)
                # publish the {kind,turn,data} envelope on the bus as a JSON string
                mgr = GATE_CONN_MGR[]
                mgr === nothing ||
                    _republish_event!(mgr, "agent:$(s.id)", JSON.json(env), "agent")
            end
        catch e
            _push_log!(:warn, "Agent '$(s.id)' relay stopped: $(sprint(showerror, e))")
        finally
            _set_status!(s, :dead)
            _forget_agent_pid!(s.id)
        end
    end
end

# ── Recent-events ring buffer (read by the TUI Agents tab) ────────────────────

_txt(b::ACP.TextBlock) = b.text
_txt(b::ACP.ImageBlock) = "[image $(b.mime_type)]"
_txt(b) = "[" * string(nameof(typeof(b))) * "]"

_event_summary(e::ACP.AgentMessageChunk) = _txt(e.content)
_event_summary(e::ACP.AgentThoughtChunk) = "💭 " * _txt(e.content)
_event_summary(e::ACP.UserMessageChunk)  = "» " * _txt(e.content)
_event_summary(e::ACP.ToolCallStarted)   = "▶ $(e.call.title) ($(e.call.kind))"
_event_summary(e::ACP.ToolCallUpdated)   = "↳ $(something(e.update.status, :update)) $(e.update.tool_call_id)"
_event_summary(e::ACP.PlanUpdated)       = "plan: $(length(e.entries)) step(s)"
_event_summary(::ACP.UsageUpdated)       = "usage update"
_event_summary(::ACP.TurnStarted)        = "— turn started —"
function _event_summary(e::ACP.TurnEnded)
    cost = (e.usage === nothing || e.usage.cost_usd === nothing) ? "" :
           ", \$$(round(e.usage.cost_usd, digits = 4))"
    "— turn ended ($(e.stop_reason)$cost) —"
end
_event_summary(e::ACP.StatusChanged)     = "status: $(e.status)"
_event_summary(e::ACP.AgentError)        = "error: $(e.message)"
_event_summary(::ACP.PermissionRequested)= "permission requested"
_event_summary(e::ACP.AgentEvent)        = string(ACP.event_kind(e))

function _push_recent!(s::AgentSession, ev::ACP.AgentEvent)
    entry = (t = time(), kind = ACP.event_kind(ev), summary = _event_summary(ev))
    lock(s.lock) do
        push!(s.recent, entry)
        n = length(s.recent)
        n > 200 && deleteat!(s.recent, 1:(n - 200))
    end
end

"""Thread-safe snapshot of an agent's recent events (oldest→newest)."""
function agent_recent(id::String)
    s = _get_agent(id)
    s === nothing && return Any[]
    lock(s.lock) do
        copy(s.recent)
    end
end

# ── Kaimon-owned event log ────────────────────────────────────────────────────
# A vendor-neutral, stable-schema JSONL we control (independent of claude's own
# transcript files): one {ts,kind,turn,data} record per normalized event, at
# ~/.cache/kaimon/agents/<id>.events.jsonl. Consumers can tail it instead of (or
# alongside) the live bus, and it survives restarts.

_event_log_path(id::AbstractString) = joinpath(kaimon_cache_dir(), "agents", "$(id).events.jsonl")

function _log_event!(id::AbstractString, env)
    try
        open(_event_log_path(id), "a") do io
            JSON.print(io, (ts = time(), kind = env.kind, turn = env.turn, data = env.data))
            print(io, '\n')
        end
    catch
    end
end

function _set_status!(s::AgentSession, status::Symbol)
    s.status === status && return
    s.status = status
    s.last_activity = time()
    # surface the transition on the bus too (consumers may want it without a turn)
    mgr = GATE_CONN_MGR[]
    if mgr !== nothing && status !== :dead   # :dead already arrives via StatusChanged event
        env = ACP.envelope(ACP.StatusChanged(status), current_turn(s.handle))
        _republish_event!(mgr, "agent:$(s.id)", JSON.json(env), "agent")
    end
end

# ── Send / interrupt / close / status ─────────────────────────────────────────

_get_agent(id) = lock(AGENT_SESSIONS_LOCK) do
    get(AGENT_SESSIONS, id, nothing)
end

"""Enqueue a user turn. Returns the turn number."""
function agent_send(id::String, text::AbstractString)
    s = _get_agent(id)
    s === nothing && error("no such agent: $id")
    s.status === :dead && error("agent '$id' is dead")
    backend_send(s.handle, text)
end

"""Cancel the in-flight turn (best effort)."""
function agent_interrupt(id::String)
    s = _get_agent(id)
    s === nothing && error("no such agent: $id")
    backend_interrupt(s.handle)
end

"""Kill the agent process and free the registry slot."""
function agent_close(id::String)
    s = _get_agent(id)
    s === nothing && return false
    backend_close(s.handle)
    _set_status!(s, :dead)
    _forget_agent_pid!(id)
    lock(AGENT_SESSIONS_LOCK) do
        delete!(AGENT_SESSIONS, id)
    end
    _push_log!(:info, "Agent '$id' closed")
    true
end

"""Snapshot of an agent's state (status, model, cwd, activity, running cost)."""
function agent_status(id::String)
    s = _get_agent(id)
    s === nothing && return nothing
    Dict{String,Any}(
        "id" => s.id,
        "status" => string(s.status),
        "model" => s.model,
        "cwd" => s.cwd,
        "turn" => current_turn(s.handle),
        "created_at" => s.created_at,
        "last_activity" => s.last_activity,
        "session_id" => s.handle.session_id[],
        "transcript" => _transcript_path(s),       # claude's own (vendor-specific) transcript
        "event_log" => _event_log_path(s.id),       # Kaimon-owned normalized JSONL
        "usage" => ACP.to_dict(s.usage),
    )
end

function list_agents()
    lock(AGENT_SESSIONS_LOCK) do
        [agent_status(id) for id in keys(AGENT_SESSIONS)]
    end
end

# claude writes ~/.claude/projects/<munged-cwd>/<sessionId>.jsonl
function _transcript_path(s::AgentSession)
    sid = s.handle.session_id[]
    isempty(sid) && return nothing
    # claude munges the *canonical* cwd (symlinks resolved, e.g. /tmp -> /private/tmp)
    canonical = try
        realpath(s.cwd)
    catch
        abspath(s.cwd)
    end
    munged = replace(canonical, r"[/.]" => "-")
    joinpath(homedir(), ".claude", "projects", munged, "$(sid).jsonl")
end

# ── Lifecycle: reaping & shutdown ─────────────────────────────────────────────

_agent_pid_file() = joinpath(kaimon_cache_dir(), "agents", "pids.json")

function _read_pid_file()
    f = _agent_pid_file()
    isfile(f) || return Dict{String,Int}()
    try
        Dict{String,Int}(k => Int(v) for (k, v) in JSON.parsefile(f))
    catch
        Dict{String,Int}()
    end
end

function _write_pid_file(d::AbstractDict)
    f = _agent_pid_file()
    mkpath(dirname(f))
    try; write(f, JSON.json(d)); catch; end
end

function _record_agent_pid!(id::String, pid::Integer)
    d = _read_pid_file(); d[id] = Int(pid); _write_pid_file(d)
end
function _forget_agent_pid!(id::String)
    d = _read_pid_file(); haskey(d, id) || return; delete!(d, id); _write_pid_file(d)
end

"""
    reap_orphan_agents!()

On Kaimon (re)start, kill leftover owned-agent processes from a prior instance
(tracked in the pid file) so we never leak `claude` children across restarts.
"""
function reap_orphan_agents!()
    d = _read_pid_file()
    isempty(d) && return
    for (id, pid) in d
        try
            run(pipeline(`kill -0 $pid`; stderr = devnull))    # alive?
            _push_log!(:info, "Reaping orphan agent '$id' (pid=$pid)")
            run(pipeline(`kill $pid`; stderr = devnull); wait = false)
            sleep(0.5)
            try
                run(pipeline(`kill -0 $pid`; stderr = devnull))
                run(pipeline(`kill -9 $pid`; stderr = devnull); wait = false)
            catch; end
        catch
            # not running — nothing to reap
        end
    end
    _write_pid_file(Dict{String,Int}())
end

"""Kill all owned agents. Called from Kaimon shutdown."""
function stop_all_agents!()
    ids = lock(AGENT_SESSIONS_LOCK) do
        collect(keys(AGENT_SESSIONS))
    end
    for id in ids
        try; agent_close(id); catch; end
    end
end

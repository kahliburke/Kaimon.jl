# ── Agent Session Manager ─────────────────────────────────────────────────────
# Kaimon-owned AI agent sessions: spawn/own a `claude` process (via an AgentBackend),
# relay its normalized ACP events onto the gate event bus on channel "agent:<id>",
# and track lifecycle + per-session cost. The natural sibling of a gate REPL session
# and a managed extension. See docs/src/agents.md.
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

# ── Synchronous run waiters (agent_run) ───────────────────────────────────────
# A run waiter taps the live relay for one in-flight turn: it accumulates the
# authoritative (non-delta) assistant text and is signalled on TurnEnded. Keyed by
# agent id (one synchronous run per agent at a time), so `agent_run` blocks for a
# turn without a second consumer of the event stream and without an AgentSession
# field. `done` carries the joined text on success, or `:timeout`/`:dead` as a signal.
struct RunWaiter
    buf::Vector{String}
    done::Channel{Any}
end
const AGENT_RUN_WAITERS = Dict{String,RunWaiter}()
const AGENT_RUN_LOCK = ReentrantLock()
_run_waiter(id) = lock(AGENT_RUN_LOCK) do; get(AGENT_RUN_WAITERS, id, nothing); end

_gen_agent_id() = bytes2hex(rand(UInt8, 4))

# ── Open ──────────────────────────────────────────────────────────────────────

"""
    agent_open(; cwd, model, permission_mode, allowed_tools, mcp_config, id) -> String

Spawn and own a new agent. Returns the agent id. Events stream on the gate bus
channel `agent:<id>`.
"""
# High-level permission posture → (permission_mode, extra allowed tools, skip-flag).
# Lets a consumer pick one word per spawn instead of assembling raw flags. The
# recursion guard (disallowed agent_* tools) stays on regardless.
function _permission_preset(p::AbstractString)
    pl = lowercase(p)
    pl == "lab"    ? ("acceptEdits", ["mcp__kaimon"], false) :      # drive the lab: slate.*/ex/...
    pl == "auto"   ? ("auto", String[], false) :                   # model classifier self-governs
    pl == "bypass" ? ("bypassPermissions", String[], true) :       # no checks (sandbox/trusted only)
                     ("acceptEdits", String[], false)              # "default": edits only
end

function agent_open(; cwd::String,
                    model::String = "claude-sonnet-4-6",
                    permission::String = "default",
                    permission_mode::Union{String,Nothing} = nothing,
                    allowed_tools::Vector{String} = String[],
                    disallowed_tools::Vector{String} = copy(AGENT_SELF_TOOLS),
                    mcp_config::Union{String,Nothing} = nothing,
                    system_prompt::Union{String,Nothing} = nothing,
                    id::Union{String,Nothing} = nothing)
    aid = id === nothing ? _gen_agent_id() : id
    lock(AGENT_SESSIONS_LOCK) do
        existing = get(AGENT_SESSIONS, aid, nothing)
        if existing !== nothing
            # A previously-closed/dead agent is retained for review; reopening the
            # same id (e.g. a notebook reconnecting) replaces it. A live one is an error.
            existing.status === :dead || error("agent id already in use: $aid")
            delete!(AGENT_SESSIONS, aid)
        end
    end

    pmode, pallow, dangerous = _permission_preset(permission)
    final_mode = permission_mode === nothing ? pmode : permission_mode  # explicit mode overrides preset
    final_allowed = unique(vcat(allowed_tools, pallow))                  # preset composes with explicit allowlist
    backend = ClaudeBackend(; model = model, permission_mode = final_mode,
                            allowed_tools = final_allowed, disallowed_tools = disallowed_tools,
                            mcp_config = mcp_config, system_prompt = system_prompt,
                            dangerously_skip = dangerous)
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
                # Feed a synchronous agent_run() waiter for this agent, if one is
                # parked: accumulate authoritative (non-delta) assistant text, and
                # release the caller on TurnEnded with the joined result.
                let w = _run_waiter(s.id)
                    if w !== nothing
                        if ev isa ACP.AgentMessageChunk && !ev.delta
                            push!(w.buf, _txt(ev.content))
                        elseif ev isa ACP.TurnEnded
                            lock(AGENT_RUN_LOCK) do; delete!(AGENT_RUN_WAITERS, s.id); end
                            try; put!(w.done, join(w.buf, "\n")); catch; end
                        end
                    end
                end
                # Streaming deltas (delta=true) ride the bus for liveness but are NOT
                # persisted to the event log or pushed to the TUI ring buffer — the
                # authoritative delta=false copy covers reload-replay and the monitor.
                # Keeps both compact under thousands of token chunks. See docs/src/agents.md.
                is_delta = ev isa ACP.ToolInputDelta ||
                           ((ev isa ACP.AgentMessageChunk || ev isa ACP.AgentThoughtChunk) && ev.delta)
                is_delta || _push_recent!(s, ev)
                env = ACP.envelope(ev, current_turn(s.handle))
                is_delta || _log_event!(s.id, env)           # Kaimon-owned JSONL (we control the schema)
                # publish the {kind,turn,data} envelope on the bus as a JSON string
                mgr = GATE_CONN_MGR[]
                mgr === nothing ||
                    _republish_event!(mgr, "agent:$(s.id)", JSON.json(env), "agent")
            end
        catch e
            _push_log!(:warn, "Agent '$(s.id)' relay stopped: $(sprint(showerror, e))")
        finally
            _set_status!(s, :dead)
            # Release any parked agent_run() waiter — the stream ended without a
            # TurnEnded (agent died/closed), so signal :dead rather than hang to timeout.
            let w = _run_waiter(s.id)
                if w !== nothing
                    lock(AGENT_RUN_LOCK) do; delete!(AGENT_RUN_WAITERS, s.id); end
                    try; put!(w.done, :dead); catch; end
                end
            end
            _forget_agent_pid!(s.id)
            _prune_dead_agents!()
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
_event_summary(e::ACP.TurnEnded)         = "— turn ended ($(e.stop_reason)) —"  # cost WIP/zeroed
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

"""
    agent_run(id, text; timeout=600.0) -> String

Send a user turn and BLOCK until the turn ends, returning the agent's assistant
text (authoritative, non-delta blocks joined). The synchronous sibling of
`agent_send` — for callers that want a request/response shape (e.g. Seaworthy's
`:agent` backend) rather than draining the `agent:<id>` event stream themselves.

Events still stream on the bus as usual (this only taps the relay to collect the
reply). Throws on timeout or if the agent dies mid-turn. One synchronous run per
agent at a time.
"""
function agent_run(id::String, text::AbstractString; timeout::Real = 600.0)
    s = _get_agent(id)
    s === nothing && error("no such agent: $id")
    s.status === :dead && error("agent '$id' is dead")
    lock(AGENT_RUN_LOCK) do
        haskey(AGENT_RUN_WAITERS, id) && error("agent '$id' already has a synchronous run in flight")
    end
    w = RunWaiter(String[], Channel{Any}(1))
    lock(AGENT_RUN_LOCK) do; AGENT_RUN_WAITERS[id] = w; end
    timer = nothing
    try
        backend_send(s.handle, text)                       # the relay tap collects the reply
        timer = Timer(_ -> (try put!(w.done, :timeout); catch; end), float(timeout))
        result = take!(w.done)
        result === :timeout && error("agent '$id' run timed out after $(timeout)s")
        result === :dead && error("agent '$id' died during the turn")
        return String(result)
    finally
        timer === nothing || close(timer)
        lock(AGENT_RUN_LOCK) do; delete!(AGENT_RUN_WAITERS, id); end
        close(w.done)                                      # unblock any late relay put! (it catches)
    end
end

"""Cancel the in-flight turn (best effort)."""
function agent_interrupt(id::String)
    s = _get_agent(id)
    s === nothing && error("no such agent: $id")
    backend_interrupt(s.handle)
end

"""Kill the agent process. The session is retained as `:dead` (greyed-out in the
TUI) for review; it's pruned later or dismissed manually."""
function agent_close(id::String)
    s = _get_agent(id)
    s === nothing && return false
    backend_close(s.handle)
    _set_status!(s, :dead)
    _forget_agent_pid!(id)
    _prune_dead_agents!()
    _push_log!(:info, "Agent '$id' closed")
    true
end

const MAX_DEAD_AGENTS = 10

"""Cap retained dead/closed agents so the registry can't grow without bound
(oldest dropped first). On-disk event logs persist regardless."""
function _prune_dead_agents!()
    lock(AGENT_SESSIONS_LOCK) do
        dead = [(id, s.last_activity) for (id, s) in AGENT_SESSIONS if s.status === :dead]
        length(dead) <= MAX_DEAD_AGENTS && return
        sort!(dead, by = x -> x[2])
        for (id, _) in dead[1:(length(dead) - MAX_DEAD_AGENTS)]
            delete!(AGENT_SESSIONS, id)
        end
    end
end

"""Remove a dead agent from the registry (TUI dismiss). No-op if still alive."""
function _dismiss_agent!(id::AbstractString)
    lock(AGENT_SESSIONS_LOCK) do
        s = get(AGENT_SESSIONS, id, nothing)
        s !== nothing && s.status === :dead && delete!(AGENT_SESSIONS, id)
    end
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

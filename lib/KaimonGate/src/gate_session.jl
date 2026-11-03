# ── Per-session gate state ────────────────────────────────────────────────────
#
# One `GateSession` holds everything that belongs to a RUNNING gate. `serve` builds it,
# `_cleanup` drops it, and dropping it IS the teardown — there is no list of fields to keep in
# sync. Adding a field here is automatically reset on stop; adding a module-level `Ref` is not,
# which is how an explicit TCP gate came to restart as an IPC gate.
#
# Three kinds of state live in this package and only the first belongs here:
#
#   1. SESSION scope (this struct) — created by `serve`, meaningless once the gate stops.
#
#   2. PROCESS scope (module-level, deliberately) — outlives any one gate, and resetting it
#      would be a bug. Job results and the Infiltrator safehouse hold user data that must
#      survive a restart. The capture mux and wedge guard rebind the PROCESS's stdout/stderr,
#      so two gates in one process must not both install them. The Infiltrator/TTY hooks and
#      the host-integration hooks Kaimon installs before `serve` are likewise per-process.
#      So are the reflection caches: they key on a file's stamp and a handler's identity, so
#      two sessions should share them and a restart should keep them warm.
#      `_ORIGINAL_ARGV` looks session-ish but is captured once per process and must survive
#      restarts, which is the whole point of it. The stream-presence callbacks
#      (`_ON_STREAM_SUBSCRIBE`/`_UNSUBSCRIBE`) are process scope for a sharper reason: a host
#      registers them BEFORE calling `serve`, so a session field would be constructed empty
#      and silently discard them.
#
#   3. CONFIGURATION (module-level) — read from `ENV` at load and effectively constant:
#      `_GATE_MAX_WORKERS`, `_GATE_RCVTIMEO_BUSY`/`_IDLE`, `_STREAM_SUBPOLL_INTERVAL`,
#      `_SERVICE_TCP_PORT`, `_EVAL_SEM`, and `_NO_IPC_TRANSPORT` (which tests override to
#      exercise the Windows coerce path). Resetting these would silently discard an
#      operator's environment overrides.

"""
    GateSession

Runtime state of one running gate. Held in `_SESSION`; see `_session()`.

Constructed with keywords, all defaulted, so `serve` sets only what it has resolved and the
rest start at the same values the old module-level `Ref`s used.
"""
mutable struct GateSession
    # ── identity and resolved configuration ──────────────────────────────────
    id::String
    namespace::String
    mode::Symbol                    # :ipc or :tcp
    tcp_host::String
    tcp_port::Int                   # RESOLVED port, not the requested one: a gate asked for
    tcp_stream_port::Int            # port 0 must rebind to the port it actually got
    auth_token::String              # non-empty ⇒ require a token on TCP requests
    # TCP only because a requested :ipc gate was coerced (Windows) — a LOCAL,
    # file-discoverable gate rather than an explicit remote one. Restart keys off this: a
    # coerced gate must come back as :ipc so it re-coerces and re-advertises, whereas an
    # explicit remote gate replays its mode/host/port to rebind the same endpoint.
    local_tcp_coerced::Bool
    allow_mirror::Bool
    allow_restart::Bool
    mirror_repl::Bool
    start_time::Float64

    # ── transport ────────────────────────────────────────────────────────────
    context::Union{ZMQ.Context,Nothing}
    socket::Union{ZMQ.Socket,Nothing}          # request ROUTER
    stream_socket::Union{ZMQ.Socket,Nothing}   # XPUB
    stream_endpoint::String

    # ── tasks ────────────────────────────────────────────────────────────────
    task::Union{Task,Nothing}                  # supervisor owning the message loop
    stream_task::Union{Task,Nothing}           # XPUB broadcaster
    revise_watcher_task::Union{Task,Nothing}

    # ── CURVE ────────────────────────────────────────────────────────────────
    curve_enabled::Bool
    curve_allow_any::Bool
    curve_server_secret::String
    curve_server_public::String
    zap_socket::Union{ZMQ.Socket,Nothing}
    zap_task::Union{Task,Nothing}

    # ── lifecycle ────────────────────────────────────────────────────────────
    running::Bool
    restarting::Bool                # between the :restart reply and execvp
    shutting_down::Bool             # set by :shutdown so the task's finally cleans up
    on_shutdown::Any

    # ── counters ─────────────────────────────────────────────────────────────
    ping_count::Int
    msg_count::Int
    last_ping_time::Float64

    # ── tools and request plumbing ───────────────────────────────────────────
    # Built fresh per session, which is what stops a same-process restart inheriting a
    # half-drained outbox or a non-zero in-flight count.
    tools::Vector{GateTool}
    outbox::Channel{Tuple{Vector{UInt8},Vector{UInt8},Vector{UInt8}}}
    inflight::Threads.Atomic{Int}           # every request being served
    default_inflight::Threads.Atomic{Int}   # those on the default lane, which `_GATE_MAX_WORKERS` caps
    stream_outbox::Channel{Vector{Vector{UInt8}}}
end

function GateSession(;
    id::AbstractString = "",
    namespace::AbstractString = "",
    mode::Symbol = :ipc,
    tcp_host::AbstractString = "127.0.0.1",
    tcp_port::Integer = 0,
    tcp_stream_port::Integer = 0,
    auth_token::AbstractString = "",
    local_tcp_coerced::Bool = false,
    allow_mirror::Bool = true,
    allow_restart::Bool = true,
    mirror_repl::Bool = false,
    start_time::Real = 0.0,
    context = nothing,
    socket = nothing,
    stream_socket = nothing,
    stream_endpoint::AbstractString = "",
    task = nothing,
    stream_task = nothing,
    revise_watcher_task = nothing,
    curve_enabled::Bool = false,
    curve_allow_any::Bool = false,
    curve_server_secret::AbstractString = "",
    curve_server_public::AbstractString = "",
    zap_socket = nothing,
    zap_task = nothing,
    running::Bool = false,
    restarting::Bool = false,
    shutting_down::Bool = false,
    on_shutdown = nothing,
    ping_count::Integer = 0,
    msg_count::Integer = 0,
    last_ping_time::Real = 0.0,
    tools::Vector{GateTool} = GateTool[],
)
    return GateSession(
        String(id), String(namespace), mode, String(tcp_host), Int(tcp_port),
        Int(tcp_stream_port), String(auth_token), local_tcp_coerced, allow_mirror,
        allow_restart, mirror_repl, Float64(start_time),
        context, socket, stream_socket, String(stream_endpoint),
        task, stream_task, revise_watcher_task,
        curve_enabled, curve_allow_any, String(curve_server_secret),
        String(curve_server_public), zap_socket, zap_task,
        running, restarting, shutting_down, on_shutdown,
        Int(ping_count), Int(msg_count), Float64(last_ping_time),
        tools,
        Channel{Tuple{Vector{UInt8},Vector{UInt8},Vector{UInt8}}}(Inf),
        Threads.Atomic{Int}(0),
        Threads.Atomic{Int}(0),
        Channel{Vector{Vector{UInt8}}}(Inf),
    )
end

"""The current session, or `nothing` when no gate is running."""
const _SESSION = Ref{Union{GateSession,Nothing}}(nothing)

"""
    _session() -> GateSession

The running gate's session. Throws when there is none, which is what every WRITE goes
through: setting a field with no gate is a bug, not a no-op.

The concrete return type matters — it keeps `Union{GateSession,Nothing}` out of the message
loop and the per-output-line mirror check, which read these fields constantly.
"""
@inline function _session()::GateSession
    s = _SESSION[]
    s === nothing && error("no gate session: serve() has not run")
    return s
end

"""The session if a gate is running, else `nothing`. For reads that must tolerate no gate."""
@inline _session_or_nothing() = _SESSION[]

"""
    gate_context() -> Union{ZMQ.Context,Nothing}

The running gate's ZMQ context, or `nothing` when no gate is running.

Public because the host creates its own sockets on the gate's context rather than a second
one — Kaimon's extension stream subscriber does exactly this. Everything else about the
session stays internal.
"""
gate_context() = _gate_context()

# ── Field accessors ───────────────────────────────────────────────────────────
#
# Reads answer with the field's default when no gate is running, because a lot of code asks
# "is a gate up?" before one exists (`_auto_serve!`, `status`, the test skip guards). Writes go
# through `_session()` and throw, because setting a field with no session is a bug rather than
# something to swallow.
#
# Written out rather than generated by a loop: `@eval`-generated definitions are invisible to
# grep and to this repo's code search, and this block doubles as the index of what session
# state exists.

# identity and configuration
_session_id()          = (s = _SESSION[]; s === nothing ? ""    : s.id)
_session_id!(v)        = (_session().id = String(v))
_session_namespace()   = (s = _SESSION[]; s === nothing ? ""    : s.namespace)
_session_namespace!(v) = (_session().namespace = String(v))
_mode()                = (s = _SESSION[]; s === nothing ? :ipc  : s.mode)
_mode!(v)              = (_session().mode = Symbol(v))
_tcp_host()            = (s = _SESSION[]; s === nothing ? "127.0.0.1" : s.tcp_host)
_tcp_host!(v)          = (_session().tcp_host = String(v))
_tcp_port()            = (s = _SESSION[]; s === nothing ? 0     : s.tcp_port)
_tcp_port!(v)          = (_session().tcp_port = Int(v))
_tcp_stream_port()     = (s = _SESSION[]; s === nothing ? 0     : s.tcp_stream_port)
_tcp_stream_port!(v)   = (_session().tcp_stream_port = Int(v))
_auth_token()          = (s = _SESSION[]; s === nothing ? ""    : s.auth_token)
_auth_token!(v)        = (_session().auth_token = String(v))
_local_tcp_coerced()   = (s = _SESSION[]; s === nothing ? false : s.local_tcp_coerced)
_local_tcp_coerced!(v) = (_session().local_tcp_coerced = v)
_allow_mirror()        = (s = _SESSION[]; s === nothing ? true  : s.allow_mirror)
_allow_mirror!(v)      = (_session().allow_mirror = v)
_allow_restart()       = (s = _SESSION[]; s === nothing ? true  : s.allow_restart)
_allow_restart!(v)     = (_session().allow_restart = v)
_mirror_repl()         = (s = _SESSION[]; s === nothing ? false : s.mirror_repl)
_mirror_repl!(v)       = (_session().mirror_repl = v)
_start_time()          = (s = _SESSION[]; s === nothing ? 0.0   : s.start_time)
_start_time!(v)        = (_session().start_time = Float64(v))

# transport
_gate_context()        = (s = _SESSION[]; s === nothing ? nothing : s.context)
_gate_context!(v)      = (_session().context = v)
_gate_socket()         = (s = _SESSION[]; s === nothing ? nothing : s.socket)
_gate_socket!(v)       = (_session().socket = v)
_stream_socket()       = (s = _SESSION[]; s === nothing ? nothing : s.stream_socket)
_stream_socket!(v)     = (_session().stream_socket = v)
_stream_endpoint()     = (s = _SESSION[]; s === nothing ? ""      : s.stream_endpoint)
_stream_endpoint!(v)   = (_session().stream_endpoint = String(v))

# tasks
_gate_task()             = (s = _SESSION[]; s === nothing ? nothing : s.task)
_gate_task!(v)           = (_session().task = v)
_stream_task()           = (s = _SESSION[]; s === nothing ? nothing : s.stream_task)
_stream_task!(v)         = (_session().stream_task = v)
_revise_watcher_task()   = (s = _SESSION[]; s === nothing ? nothing : s.revise_watcher_task)
_revise_watcher_task!(v) = (_session().revise_watcher_task = v)

# CURVE
_curve_enabled()        = (s = _SESSION[]; s === nothing ? false : s.curve_enabled)
_curve_enabled!(v)      = (_session().curve_enabled = v)
_curve_allow_any()      = (s = _SESSION[]; s === nothing ? false : s.curve_allow_any)
_curve_allow_any!(v)    = (_session().curve_allow_any = v)
_curve_server_secret()  = (s = _SESSION[]; s === nothing ? "" : s.curve_server_secret)
_curve_server_secret!(v) = (_session().curve_server_secret = String(v))
_curve_server_public()  = (s = _SESSION[]; s === nothing ? "" : s.curve_server_public)
_curve_server_public!(v) = (_session().curve_server_public = String(v))
_zap_socket()           = (s = _SESSION[]; s === nothing ? nothing : s.zap_socket)
_zap_socket!(v)         = (_session().zap_socket = v)
_zap_task()             = (s = _SESSION[]; s === nothing ? nothing : s.zap_task)
_zap_task!(v)           = (_session().zap_task = v)

# lifecycle
_running()          = (s = _SESSION[]; s === nothing ? false : s.running)
# Stopping wakes a parked `message_loop` so it sees the flag. The wake is a plain Event: at exit
# this runs inside libuv's own loop, where a timer or socket event can never fire.
_running!(v)        = (_session().running = v; v || _gate_wake!(); v)
_restarting()       = (s = _SESSION[]; s === nothing ? false : s.restarting)
_restarting!(v)     = (_session().restarting = v)
_shutting_down()    = (s = _SESSION[]; s === nothing ? false : s.shutting_down)
_shutting_down!(v)  = (_session().shutting_down = v)
_on_shutdown()      = (s = _SESSION[]; s === nothing ? nothing : s.on_shutdown)
_on_shutdown!(v)    = (_session().on_shutdown = v)

# counters
_ping_count()       = (s = _SESSION[]; s === nothing ? 0   : s.ping_count)
_ping_count!(v)     = (_session().ping_count = Int(v))
_msg_count()        = (s = _SESSION[]; s === nothing ? 0   : s.msg_count)
_msg_count!(v)      = (_session().msg_count = Int(v))
_last_ping_time()   = (s = _SESSION[]; s === nothing ? 0.0 : s.last_ping_time)
_last_ping_time!(v) = (_session().last_ping_time = Float64(v))

# tools
_session_tools()    = (s = _SESSION[]; s === nothing ? GateTool[] : s.tools)
_session_tools!(v)  = (_session().tools = v)

# Containers are mutated in place and never reassigned, so they need no setter. Callers that
# used the bare name (`isready(_gate_outbox())`, `atomic_add!(_gate_inflight(), 1)`) call these
# instead; note `_gate_inflight()[]` is still the atomic load.
_gate_outbox()           = _session().outbox
_gate_inflight()         = _session().inflight
_gate_default_inflight() = _session().default_inflight
_stream_outbox()         = _session().stream_outbox

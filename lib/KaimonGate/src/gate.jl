# ═══════════════════════════════════════════════════════════════════════════════
# Gate — Thin eval gate for the user's REPL
#
# Runs inside the user's Julia session. Binds a ZMQ REP socket on an IPC
# endpoint so the persistent TUI server can send eval requests without living
# inside this process. Dependencies: ZMQ.jl + Serialization (stdlib).
#
# This file is `include`d into the `KaimonGate` module (see KaimonGate.jl),
# which provides the `using` imports and the host-integration hooks
# (`_VERSION_PROVIDER`, `_MIRROR_PREF_PROVIDER`, `_PERSONALITY_PROVIDER`,
# `_TACHIKOMA`). When KaimonGate runs standalone the hooks return safe
# defaults; when Kaimon loads KaimonGate it installs richer providers.
# ═══════════════════════════════════════════════════════════════════════════════

# ── Thread-safe ZMQ recv ──────────────────────────────────────────────────────
# ZMQ Message objects have finalizers that call zmq_msg_close, which is NOT
# thread-safe. If a Message escapes to GC and gets finalized on a worker
# thread during parallel computation (e.g. @threads kNN), it segfaults.
#
# Fix: use recv(sock, Vector{UInt8}) which internally uses ZMQ._Message
# (a stack-allocated struct with NO finalizer), copies bytes out, and closes
# immediately. No Message object is ever created, so nothing escapes to GC.

"""Receive from a ZMQ socket, returning raw bytes (no finalizer-bearing objects)."""
function _zmq_recv(sock::ZMQ.Socket)::Vector{UInt8}
    return recv(sock, Vector{UInt8})
end

# Thread-safe socket *construction*. ZMQ.jl appends every new Socket to its
# Context's `sockets::Vector{WeakRef}` with an UNLOCKED `push!`. The gate creates
# an ephemeral REQ per `_service_request`, so concurrent extension tool calls
# race that push! → a resize frees the backing Memory under a concurrent GC scan
# of the WeakRef array → intermittent heap corruption in `gc_sweep_pool`. One
# lock around construction closes the window (the I/O afterward is unaffected).
const _ZMQ_SOCKET_LOCK = ReentrantLock()
_zmq_socket(ctx::ZMQ.Context, typ) = lock(_ZMQ_SOCKET_LOCK) do
    ZMQ.Socket(ctx, typ)
end

# ── Constants ─────────────────────────────────────────────────────────────────

# Cache + socket directories MUST be resolved at runtime (functions), not as
# top-level consts. A const is evaluated at precompile time, baking in whatever
# XDG_CACHE_HOME was set then — which breaks per-instance isolation (e.g. a
# second kaimon server, or a gate meant to register in an alternate cache dir).
# Mirrors the server-side Kaimon.kaimon_cache_dir().
function _gate_cache_dir()
    d = get(ENV, "XDG_CACHE_HOME") do
        Sys.iswindows() ?
        joinpath(
            get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local")),
            "Kaimon",
        ) : joinpath(homedir(), ".cache", "kaimon")
    end
    mkpath(d)
    return d
end

"""Directory holding the gate's IPC sockets and session metadata. Honors
`XDG_CACHE_HOME` at runtime (see `_gate_cache_dir`)."""
function sock_dir()
    d = joinpath(_gate_cache_dir(), "sock")
    mkpath(d)
    return d
end

"""
    _install_peek_report_override(session_id::String)

Override `Profile.peek_report[]` so that SIGINFO/SIGUSR1 writes the profile
report to `sock_dir()/<session_id>-backtrace.txt` instead of stderr. This avoids
deadlocking PTY-backed sessions where the kernel buffer is small.
"""
function _install_peek_report_override(session_id::String)
    try
        Profile = Base.require(Base.PkgId(Base.UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"), "Profile"))
        bt_path = joinpath(sock_dir(),"$(session_id)-backtrace.txt")
        Profile.peek_report[] = function ()
            try
                open(bt_path, "w") do io
                    Base.invokelatest(Profile.print, io; groupby = [:thread, :task])
                    if position(io) == 0
                        # Profile.print produced no output — write a diagnostic
                        println(io, "(no profiling samples collected)")
                    end
                end
            catch e
                try
                    open(bt_path, "w") do io
                        println(io, "peek_report error: $(sprint(showerror, e))")
                    end
                catch
                end
            end
        end
    catch
        # Profile not available — skip
    end
end
const GATE_LOCK = ReentrantLock()

# Global state for the running gate
const _GATE_TASK = Ref{Union{Task,Nothing}}(nothing)
const _GATE_CONTEXT = Ref{Union{ZMQ.Context,Nothing}}(nothing)
const _GATE_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)
const _STREAM_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)  # PUB for streaming output
const _STREAM_ENDPOINT = Ref{String}("")                       # resolved PUB endpoint
const _SESSION_ID = Ref{String}("")
const _RUNNING = Ref{Bool}(false)
const _START_TIME = Ref{Float64}(0.0)
const _MIRROR_REPL = Ref{Bool}(false)
const _ALLOW_MIRROR = Ref{Bool}(true)
const _REVISE_WATCHER_TASK = Ref{Union{Task,Nothing}}(nothing)
const _SESSION_NAMESPACE = Ref{String}("")
const _ALLOW_RESTART = Ref{Bool}(true)
const _ORIGINAL_ARGV = Ref{Vector{String}}(String[])
const _MODE = Ref{Symbol}(:ipc)
const _TCP_HOST = Ref{String}("127.0.0.1")
const _TCP_PORT = Ref{Int}(0)          # actual bound port (resolved from ephemeral)
const _TCP_STREAM_PORT = Ref{Int}(0)   # actual bound PUB port
const _AUTH_TOKEN = Ref{String}("")  # non-empty = require token on TCP requests
const _PING_COUNT = Ref{Int}(0)
const _MSG_COUNT = Ref{Int}(0)       # total messages handled (pings + evals + tool calls + ...)
const _LAST_PING_TIME = Ref{Float64}(0.0)
const _GATE_TTY_PATH = Ref{Union{String,Nothing}}(nothing)
const _GATE_TTY_SIZE =
    Ref{Union{Nothing,NamedTuple{(:rows, :cols),Tuple{Int,Int}}}}(nothing)
const _GATE_TTY_ECHO_DISABLED = Ref{Bool}(false)
const _GATE_TTY_PARKED_PGRP = Ref{Union{Int32,Nothing}}(nothing)
# Set to true between the :restart reply and the actual execvp call.
# Prevents the message-loop task's `finally` from closing sockets prematurely
# and defeating the 0.3 s grace period for the ZMQ reply to flush.
const _RESTARTING = Ref{Bool}(false)
# Set by :shutdown handler so the message loop's `finally` block knows
# to call _cleanup() after the reply has been sent and the loop exits.
const _SHUTTING_DOWN = Ref{Bool}(false)
const _ON_SHUTDOWN = Ref{Any}(nothing)

# ── ROUTER request channel (protocol v2) ─────────────────────────────────────
# The gate's request socket is a ROUTER. A single owner task (the message loop)
# is the ONLY thing that touches it — it interleaves recv (new requests) with
# draining replies that worker tasks hand back via _GATE_OUTBOX, routed to the
# right client by ROUTER identity. Workers never touch the socket, so a slow
# handler (a multi-second sync eval, or a blocked debug_eval) can't stall intake.
# Each outbox entry is (identity, corr_id, reply-bytes); the corr_id is echoed
# back so the client DEALER can demultiplex concurrent in-flight requests.
const _GATE_OUTBOX =
    Channel{Tuple{Vector{UInt8},Vector{UInt8},Vector{UInt8}}}(Inf)
# Backstop on concurrent worker tasks so a request storm can't spawn unbounded
# tasks. At the cap the owner stops accepting new requests; pending requests
# stay queued in the ROUTER (client DEALER blocks in its own recv) until a slot
# frees. Env-overridable.
const _GATE_INFLIGHT = Threads.Atomic{Int}(0)
const _GATE_MAX_WORKERS = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_GATE_MAX_WORKERS", "")), 16))

# ── Stream broadcaster (XPUB) + subscriber presence ──────────────────────────
# The stream socket is an XPUB (drop-in for SUB clients) owned by ONE task: the
# broadcaster. It interleaves draining _STREAM_OUTBOX (publish work, the hot
# stdout path) with recv'ing XPUB subscription frames — so the same task that
# sends also reads subscription events, satisfying ZMQ's single-owner rule (no
# more _PUB_LOCK multi-writer send). Publishers just enqueue frames.
#
# XPUB_VERBOSER delivers every sub/unsub; we tally per topic in _STREAM_SUBS and
# fire callbacks on 0->1 / 1->0 transitions. TCP keepalive (set on the socket)
# makes libzmq emit a dead viewer's unsubscribe so counts self-correct.
const _STREAM_OUTBOX = Channel{Vector{Vector{UInt8}}}(Inf)  # each entry = one msg's frames
const _STREAM_TASK = Ref{Union{Task,Nothing}}(nothing)
const _STREAM_SUBS = Dict{String,Int}()                     # topic => live subscriber count
const _STREAM_SUBS_LOCK = ReentrantLock()                   # guards _STREAM_SUBS + callbacks
const _ON_STREAM_SUBSCRIBE = Any[]                          # f(topic::String) on 0->1
const _ON_STREAM_UNSUBSCRIBE = Any[]                        # f(topic::String) on 1->0
const _STREAM_RECONCILE_EVERY = 5.0                         # seconds between hygiene passes

# libzmq socket-option ids (stable ZMTP ABI; see gate_curve.jl for the pattern).
const _ZMQ_TCP_KEEPALIVE       = 34
const _ZMQ_TCP_KEEPALIVE_CNT   = 35
const _ZMQ_TCP_KEEPALIVE_IDLE  = 36
const _ZMQ_TCP_KEEPALIVE_INTVL = 37
const _ZMQ_XPUB_VERBOSER       = 78

# ── Debug Breakpoint State ───────────────────────────────────────────────────
# Programmatic breakpoint system for agent-assisted debugging.
# _breakpoint_hook() blocks the calling thread and communicates with the
# gate's message loop via Channels, allowing agents to inspect locals and
# eval expressions in the paused context.

const _DEBUG_PAUSED = Ref{Any}(nothing)        # NamedTuple with pause info, or nothing
const _DEBUG_RESUME_CH = Ref{Any}(nothing)      # Channel{Symbol} — :continue
const _DEBUG_EVAL_CH = Ref{Any}(nothing)        # Channel{Pair{String, Channel{Any}}}
const _INFILTRATOR_HOOKED = Ref(false)          # true once _install_infiltrator_hook! succeeds
const _INFILTRATOR_DISABLED = Ref(false)        # true after explicit uninstall — suppresses callback
const _INFILTRATOR_ORIG_PROMPT = Ref{Any}(nothing)  # original start_prompt method for restore

"""
    _breakpoint_hook(locals::Dict{Symbol,Any}; file="unknown", line=0)

Programmatic breakpoint for agent-assisted debugging. Pauses execution,
publishes breakpoint info via the PUB socket, and blocks until an agent
sends a continue command via the debug protocol.

Insert into code as:
    KaimonGate._breakpoint_hook(Base.@locals; file=@__FILE__, line=@__LINE__)
"""
function _breakpoint_hook(locals::Dict{Symbol,Any}; file::String = "unknown", line::Int = 0)
    # Keep Infiltrator's async check disabled so subsequent @infiltrate calls work
    Infiltrator = _find_infiltrator()
    if Infiltrator !== nothing
        isdefined(Infiltrator, :toggle_async_check) && Infiltrator.toggle_async_check(false)
        isdefined(Infiltrator, :clear_disabled!) && Infiltrator.clear_disabled!()
    end

    info = (
        file = file,
        line = line,
        locals = Dict(string(k) => sprint(show, MIME"text/plain"(), v; context = :limit => true) for (k, v) in locals),
        locals_types = Dict(string(k) => string(typeof(v)) for (k, v) in locals),
    )
    _publish_stream("breakpoint_hit", _serialize_result(info))

    resume_ch = Channel{Symbol}(1)
    eval_ch = Channel{Pair{String,Channel{Any}}}(32)
    _DEBUG_PAUSED[] = info
    _DEBUG_RESUME_CH[] = resume_ch
    _DEBUG_EVAL_CH[] = eval_ch

    # Process eval requests while paused — single persistent module so
    # assignments survive across evals and Infiltrator macros are available.
    eval_mod = Module()
    for (k, v) in locals
        Core.eval(eval_mod, Expr(:(=), k, QuoteNode(v)))
    end
    # Import Infiltrator exports (@exfiltrate etc.) if available
    try
        Core.eval(eval_mod, :(using Infiltrator))
    catch; end
    @async begin
        for (code, result_ch) in eval_ch
            try
                val = Base.invokelatest(Core.eval, eval_mod, Meta.parse(code))
                put!(result_ch, sprint(show, MIME"text/plain"(), val; context = :limit => true))
            catch e
                put!(result_ch, "ERROR: " * sprint(showerror, e))
            end
        end
    end

    try
        take!(resume_ch)
    catch e
        # Let the user break out of a paused breakpoint locally (Ctrl-C) instead
        # of being stuck until an agent resumes it (#34). Any failure to wait
        # (interrupt or a closed channel during shutdown) just resumes execution.
        e isa InterruptException || e isa InvalidStateException || rethrow()
        @info "Breakpoint released locally"
    end
    close(eval_ch)
    _DEBUG_PAUSED[] = nothing
    _DEBUG_RESUME_CH[] = nothing
    _DEBUG_EVAL_CH[] = nothing
    _publish_stream("breakpoint_resumed", "")
    return nothing
end

"""
    _install_infiltrator_hook!()

Override `Infiltrator.start_prompt` so that `@infiltrate` routes through the
gate's breakpoint system instead of opening an interactive REPL prompt.
Called automatically when `Infiltrator` is detected during `serve()`.

This also disables Infiltrator's async-context check (which would block
`@infiltrate` inside gate evals that run on spawned threads).
"""
function _find_infiltrator()
    for (pkgid, mod) in Base.loaded_modules
        pkgid.name == "Infiltrator" && return mod
    end
    return nothing
end

function _install_infiltrator_hook!()
    Infiltrator = _find_infiltrator()
    Infiltrator === nothing && error("Infiltrator not loaded")
    # Disable the async check — gate evals run on spawned threads
    if isdefined(Infiltrator, :toggle_async_check)
        Infiltrator.toggle_async_check(false)
    elseif isdefined(Infiltrator, :CHECK_TASK)
        Infiltrator.CHECK_TASK[] = false
    end
    # Clear any previously disabled infiltration points (from before hook install)
    if isdefined(Infiltrator, :clear_disabled!)
        Infiltrator.clear_disabled!()
    end
    # Save original start_prompt before overriding (for uninstall)
    if _INFILTRATOR_ORIG_PROMPT[] === nothing
        _INFILTRATOR_ORIG_PROMPT[] = Infiltrator.start_prompt
    end
    # (Re)enable routing — a prior stop()/uninstall_infiltrator_hook! set the
    # disabled flag, so a fresh serve() in the same process must clear it.
    _INFILTRATOR_DISABLED[] = false
    # Override start_prompt to route through our breakpoint system. Falls back to
    # the original prompt when the gate is stopped or the hook was disabled, so a
    # breakpoint hit after Gate.stop() opens the normal Infiltrator REPL instead
    # of hanging on a dead gate (#34).
    @eval function ($Infiltrator).start_prompt(
        mod, locals::Dict{Symbol,Any}, file, fileline, ex = nothing, bt = nothing;
        terminal = nothing, repl = nothing, nostack = false,
    )
        M = $(@__MODULE__)
        if M._INFILTRATOR_DISABLED[] || !M._RUNNING[]
            orig = M._INFILTRATOR_ORIG_PROMPT[]
            return orig === nothing ? nothing :
                   orig(mod, locals, file, fileline, ex, bt;
                        terminal = terminal, repl = repl, nostack = nostack)
        end
        M._breakpoint_hook(locals; file = string(file), line = Int(fileline))
    end
    _INFILTRATOR_HOOKED[] = true
    @info "Infiltrator.jl integration active — @infiltrate routes through gate debug protocol"
end

"""
    uninstall_infiltrator_hook!()

Restore Infiltrator's original `start_prompt` so `@infiltrate` opens the normal
interactive REPL prompt instead of routing through the gate debug protocol.
"""
function uninstall_infiltrator_hook!()
    _INFILTRATOR_DISABLED[] = true
    _INFILTRATOR_HOOKED[] || return
    Infiltrator = _find_infiltrator()
    Infiltrator === nothing && return
    orig = _INFILTRATOR_ORIG_PROMPT[]
    if orig !== nothing
        @eval function ($Infiltrator).start_prompt(
            mod, locals::Dict{Symbol,Any}, file, fileline, ex = nothing, bt = nothing;
            terminal = nothing, repl = nothing, nostack = false,
        )
            ($orig)(mod, locals, file, fileline, ex, bt;
                    terminal = terminal, repl = repl, nostack = nostack)
        end
    end
    _INFILTRATOR_HOOKED[] = false
    @info "Infiltrator.jl hook removed — @infiltrate uses default REPL prompt"
end


# ── Session-Scoped Tools ──────────────────────────────────────────────────────

"""
    GateTool(name, handler)

A tool declared by a gate session. The handler is a normal Julia function;
the gate infrastructure reflects on its signature to generate MCP schema
and reconstructs typed arguments from incoming Dict values.

# Example
```julia
function send_key(key::String, modifier::Symbol=:none)
    # handle key event
end

KaimonGate.serve(tools=[GateTool("send_key", send_key)])
```
"""
struct GateTool
    name::String
    handler::Function
end

const _SESSION_TOOLS = Ref{Vector{GateTool}}(GateTool[])

# ── Rich tool results (images) ────────────────────────────────────────────────
# MCP tool results are otherwise plain text. A handler that wants to return an
# image returns this sentinel-tagged JSON envelope as its String result; the
# Kaimon server detects the prefix at tool-result egress, parses the JSON,
# downsamples any image blocks to its configured cap, and emits real MCP image
# content blocks. The string carrier rides the (string-only) gate transport
# untouched — see `image_result`.

"""
    KaimonGate.MCP_CONTENT_SENTINEL

Versioned prefix marking a tool result String as a structured MCP content
envelope (rich content / images) rather than plain text. Collision-proof: any
result not starting with this is treated as plain text — no parsing.
"""
const MCP_CONTENT_SENTINEL = "KAIMON-MCP-CONTENT/v1\n"

# Minimal JSON string encoder — avoids a JSON dependency in lightweight KaimonGate.
# (base64 payloads are JSON-safe; only free-text `text`/`mime` need escaping.)
function _json_str(s::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c < ' '
            print(io, "\\u", lpad(string(UInt16(c), base = 16), 4, '0'))
        else
            print(io, c)
        end
    end
    print(io, '"')
    String(take!(io))
end

"""
    image_result(png; mime="image/png", text="") -> String

Build a structured MCP tool-result envelope carrying an image, for return from a
gate tool handler. `png` is raw image bytes (base64-encoded internally). The
Kaimon server unwraps this at tool-result egress into a real MCP image content
block, downsampling to its configured cap (`tool_image_max_long_edge`, default
1024 px) *before* the image reaches the agent — that is the tool-result cost
lever. An optional `text` block is included before the image.

```julia
GateTool("slate_view", a -> KaimonGate.image_result(render_png(a); text="Cell 3"))
```
"""
function image_result(
    png::AbstractVector{UInt8};
    mime::AbstractString = "image/png",
    text::AbstractString = "",
)
    b64 = Base64.base64encode(png)
    blocks = String[]
    isempty(text) || push!(blocks, "{\"type\":\"text\",\"text\":$(_json_str(text))}")
    push!(
        blocks,
        "{\"type\":\"image\",\"data\":$(_json_str(b64)),\"mimeType\":$(_json_str(mime))}",
    )
    return MCP_CONTENT_SENTINEL * "{\"content\":[" * join(blocks, ",") * "]}"
end

# ── Type Reflection & Coercion ────────────────────────────────────────────────
# Reflects on handler function signatures to build type metadata for MCP schema
# generation, and reconstructs typed Julia args from incoming Dict values.

"""Strip "No documentation found" boilerplate from docstrings."""
function _clean_docstring(s::String)::String
    isempty(s) && return ""
    # Remove the "No documentation found" preamble and everything after
    if startswith(s, "No documentation found")
        return ""
    end
    return strip(s)
end

"""
    _type_to_meta(T; depth=0, max_depth=5) -> Dict

Convert a Julia type to a metadata Dict for serialization. Handles primitives,
enums, structs (recursive), arrays, Union{T,Nothing}, and falls back to "any".
"""
function _type_to_meta(T; depth::Int = 0, max_depth::Int = 5)
    depth >= max_depth &&
        return Dict{String,Any}("kind" => "any", "julia_type" => string(T))

    # Handle Union{T, Nothing} → unwrap to T, mark optionality upstream
    if T isa Union
        non_nothing = [t for t in Base.uniontypes(T) if t !== Nothing]
        if length(non_nothing) == 1
            return _type_to_meta(non_nothing[1]; depth, max_depth)
        end
    end

    # Primitives
    T === Any && return Dict{String,Any}("kind" => "any", "julia_type" => "Any")
    T === String && return Dict{String,Any}("kind" => "string", "julia_type" => "String")
    T === Bool && return Dict{String,Any}("kind" => "boolean", "julia_type" => "Bool")
    T === Symbol && return Dict{String,Any}("kind" => "string", "julia_type" => "Symbol")
    T <: Integer && return Dict{String,Any}("kind" => "integer", "julia_type" => string(T))
    T <: AbstractFloat &&
        return Dict{String,Any}("kind" => "number", "julia_type" => string(T))

    # Enums
    if T isa DataType && T <: Enum
        vals = [string(x) for x in instances(T)]
        desc = try
            _clean_docstring(string(Base.Docs.doc(T)))
        catch
            ""
        end
        return Dict{String,Any}(
            "kind" => "enum",
            "julia_type" => string(T),
            "enum_values" => vals,
            "description" => desc,
        )
    end

    # Structs (but not String/Number/Array subtypes — arrays are handled below)
    if T isa DataType &&
       isstructtype(T) &&
       !(T <: AbstractString) &&
       !(T <: Number) &&
       !(T <: AbstractVector)
        fields = Dict{String,Any}[]
        for (fname, ftype) in zip(fieldnames(T), fieldtypes(T))
            fdoc = try
                _clean_docstring(string(Base.Docs.fielddoc(T, fname)))
            catch
                ""
            end
            push!(
                fields,
                Dict{String,Any}(
                    "name" => string(fname),
                    "type_meta" => _type_to_meta(ftype; depth = depth + 1, max_depth),
                    "description" => fdoc,
                ),
            )
        end
        desc = try
            _clean_docstring(string(Base.Docs.doc(T)))
        catch
            ""
        end
        return Dict{String,Any}(
            "kind" => "struct",
            "julia_type" => string(T),
            "fields" => fields,
            "description" => desc,
        )
    end

    # Arrays
    if T <: AbstractVector
        elem = eltype(T)
        return Dict{String,Any}(
            "kind" => "array",
            "julia_type" => string(T),
            "element_type" => _type_to_meta(elem; depth = depth + 1, max_depth),
        )
    end

    return Dict{String,Any}("kind" => "any", "julia_type" => string(T))
end

"""
    _is_optional_type(T) -> Bool

Returns true if `T` is `Union{..., Nothing}` — i.e. the argument is optional.
"""
function _is_optional_type(T)
    T isa Union || return false
    return Nothing in Base.uniontypes(T)
end

"""
    _source_docstring(f) -> String

Look for a triple-quoted string literal immediately before the line where `f`
is defined in its source file. This supports the closure-factory pattern:

```julia
function _make_my_tool()
    \"\"\"Tool description here.\"\"\"
    function my_tool(; arg::String)::String
        ...
    end
end
```

Since the inner function has no module-level binding, `Base.Docs.doc` cannot
attach a docstring to it. This function reads the source file directly and
extracts the string literal that precedes the function definition.
"""
function _source_docstring(f::Function)::String
    try
        m = methods(f)
        isempty(m) && return ""
        file = string(first(m).file)
        line = first(m).line
        isfile(file) || return ""
        src = readlines(file)
        # Scan backwards from the function definition line looking for \"\"\"...\"\"\".
        # Collect lines that are part of a triple-quoted block, stopping at the
        # first non-blank, non-closing-delimiter line that isn't a string.
        doc_lines = String[]
        in_block = false
        i = line - 1
        while i >= 1
            l = rstrip(src[i])
            stripped = strip(l)
            if !in_block
                # Closing delimiter of a block above (reading upward)
                if endswith(stripped, "\"\"\"")
                    if stripped == "\"\"\""
                        # Lone """ on its own line — closing delimiter, start accumulating
                        in_block = true
                    elseif startswith(stripped, "\"\"\"")
                        # Single-line: """content"""
                        inner = stripped[4:end-3]
                        return strip(inner)
                    else
                        # content""" — content before the closing delimiter
                        pushfirst!(doc_lines, rstrip(l[1:end-3]))
                        in_block = true
                    end
                elseif isempty(stripped)
                    i -= 1
                    continue
                else
                    break  # non-string content before the function
                end
            else
                if startswith(stripped, "\"\"\"")
                    pushfirst!(doc_lines, lstrip(l)[4:end])  # drop opening """
                    return strip(join(doc_lines, "\n"))
                else
                    pushfirst!(doc_lines, l)
                end
            end
            i -= 1
        end
    catch
    end
    return ""
end

"""
    _extract_kwarg_types(f) -> Dict{Symbol,Type}

Recover annotated kwarg types from a function handler. Tries two strategies:

1. **Module-level functions:** Use `code_lowered` to find the kwbody function
   (the `#funcname#N` inner function Julia generates for kwargs), then read
   its typed signature directly.

2. **Closure-based handlers** (e.g. inner `function foo(; kw::T...)` returned
   by a factory): Julia stores the typed implementation as a field of the outer
   callable struct. The inner method's positional signature is
   `(InnerType, kwarg_types..., OuterClosureType)`.

Falls back to an empty dict (callers treat missing entries as `Any`).
"""
function _extract_kwarg_types(f::Function)::Dict{Symbol,Type}
    kw_names = try
        Base.kwarg_decl(first(methods(f)))
    catch
        return Dict{Symbol,Type}()
    end
    isempty(kw_names) && return Dict{Symbol,Type}()

    # Strategy 1: code_lowered → find kwbody function → read typed signature
    result = _extract_kwarg_types_from_lowered(f, kw_names)
    !isempty(result) && return result

    # Strategy 2: closure struct field inspection (legacy pattern)
    return _extract_kwarg_types_from_closure(f, kw_names)
end

"""Extract kwarg types by finding the kwbody function via code_lowered."""
function _extract_kwarg_types_from_lowered(f::Function, kw_names::Vector{Symbol})::Dict{Symbol,Type}
    try
        cl = Base.code_lowered(f)
        isempty(cl) && return Dict{Symbol,Type}()
        ci = cl[1]

        # Find the kwbody function — it's a GlobalRef matching #funcname#N
        inner_f = nothing
        fname = string(nameof(f))
        for stmt in ci.code
            if stmt isa GlobalRef
                name_str = string(stmt.name)
                if startswith(name_str, "#") && contains(name_str, "#$(fname)#")
                    inner_f = getfield(stmt.mod, stmt.name)
                    break
                end
            end
        end
        inner_f === nothing && return Dict{Symbol,Type}()

        inner_ms = methods(inner_f)
        isempty(inner_ms) && return Dict{Symbol,Type}()
        sig = first(inner_ms).sig
        while sig isa UnionAll
            sig = sig.body
        end
        params = sig.parameters
        # params = (InnerFuncType, kwarg_types..., OuterFuncType, positional_types...)
        nkw = length(kw_names)
        length(params) < nkw + 2 && return Dict{Symbol,Type}()
        kw_types = params[2:1+nkw]
        Dict{Symbol,Type}(kw_names[i] => kw_types[i] for i in eachindex(kw_names))
    catch
        Dict{Symbol,Type}()
    end
end

"""Extract kwarg types from closure struct internals (legacy factory pattern)."""
function _extract_kwarg_types_from_closure(f::Function, kw_names::Vector{Symbol})::Dict{Symbol,Type}
    fnames = fieldnames(typeof(f))
    isempty(fnames) && return Dict{Symbol,Type}()
    try
        inner = getfield(f, fnames[1])
        ms = methods(inner)
        isempty(ms) && return Dict{Symbol,Type}()
        params = only(ms).sig.parameters   # (InnerT, kw_types..., OuterT)
        length(params) < 3 && return Dict{Symbol,Type}()
        kw_types = params[2:end-1]
        length(kw_types) == length(kw_names) || return Dict{Symbol,Type}()
        Dict{Symbol,Type}(kw_names[i] => kw_types[i] for i in eachindex(kw_names))
    catch
        Dict{Symbol,Type}()
    end
end

"""
    _extract_required_kwargs(f) -> Set{Symbol}

Detect which kwargs are required (have no default value) by inspecting lowered IR.
Julia emits `Core.UndefKeywordError(:name)` for required kwargs.
"""
function _extract_required_kwargs(f::Function)::Set{Symbol}
    required = Set{Symbol}()
    cl = try
        Base.code_lowered(f)
    catch
        return required
    end
    isempty(cl) && return required
    ci = cl[1]
    for stmt in ci.code
        if stmt isa Expr && stmt.head == :call && length(stmt.args) >= 2
            callee = stmt.args[1]
            if callee isa GlobalRef && callee.mod === Core && callee.name == :UndefKeywordError
                arg = stmt.args[2]
                if arg isa QuoteNode && arg.value isa Symbol
                    push!(required, arg.value)
                end
            end
        end
    end
    required
end

"""
    _reflect_tool(tool::GateTool) -> Dict

Reflect on a GateTool's handler to extract argument metadata and docstring.
Returns a serializable Dict sent to the TUI via pong for MCP schema generation.
"""
function _reflect_tool(tool::GateTool)
    f = tool.handler
    ms = methods(f)

    if isempty(ms)
        return Dict{String,Any}("name" => tool.name, "description" => "", "arguments" => [])
    end

    # A function with optional positional args defines one method PER ARITY. Reflect the
    # MOST complete signature for the full parameter list; `first(ms)` is unreliable —
    # for closure handlers it can be the lowest-arity stub, silently dropping every
    # optional param from the schema.
    allms = collect(ms)
    m = argmax(mm -> Int(mm.nargs), allms)
    nmin = minimum(Int(mm.nargs) for mm in allms)   # fewest args ⇒ required positional count

    # Argument names (first is the function itself)
    arg_names_all = Base.method_argnames(m)
    arg_names = length(arg_names_all) > 1 ? arg_names_all[2:end] : Symbol[]

    # Argument types from signature
    sig = m.sig
    while sig isa UnionAll
        sig = sig.body
    end
    sig_params = sig.parameters
    arg_types = length(sig_params) > 1 ? sig_params[2:end] : []

    # Build positional arg metadata
    args_meta = Dict{String,Any}[]
    for i in eachindex(arg_names)
        T = i <= length(arg_types) ? arg_types[i] : Any
        push!(
            args_meta,
            Dict{String,Any}(
                "name" => string(arg_names[i]),
                "type_meta" => _type_to_meta(T),
                "required" => !_is_optional_type(T),
                "is_kwarg" => false,
            ),
        )
    end

    # Mark args beyond the MINIMUM arity (the required count) as optional — params that
    # appear only in higher-arity methods carry defaults. (nargs counts the function.)
    nreq = nmin - 1
    for i in eachindex(args_meta)
        if i > nreq
            args_meta[i]["required"] = false
        end
    end

    # Keyword arguments — recover types and required status
    kw_names = try
        Base.kwarg_decl(m)
    catch
        Symbol[]
    end
    kw_types = _extract_kwarg_types(f)
    required_kws = _extract_required_kwargs(f)
    for kw in kw_names
        T = get(kw_types, kw, Any)
        push!(
            args_meta,
            Dict{String,Any}(
                "name" => string(kw),
                "type_meta" => _type_to_meta(T),
                "required" => kw in required_kws,
                "is_kwarg" => true,
            ),
        )
    end

    # Description: try Base.Docs first (named functions), then look for a
    # string literal immediately before the function definition in source
    # (the pattern used by closure-factory handlers).
    description = try
        _clean_docstring(string(Base.Docs.doc(f)))
    catch
        ""
    end
    if isempty(description)
        description = _source_docstring(f)
    end

    return Dict{String,Any}(
        "name" => tool.name,
        "description" => description,
        "arguments" => args_meta,
    )
end

"""
    _coerce_value(value, T) -> Any

Coerce a raw JSON value to the expected Julia type `T`.
Handles: primitives, Symbol, Enum, struct construction, vectors.
"""
function _coerce_value(value, T)
    # Already correct type
    value isa T && return value

    # Any — pass through
    T === Any && return value

    # Handle Union{T, Nothing}
    if T isa Union
        value === nothing && Nothing <: T && return nothing
        non_nothing = [t for t in Base.uniontypes(T) if t !== Nothing]
        if length(non_nothing) == 1
            return _coerce_value(value, non_nothing[1])
        end
    end

    # Primitives
    T === String && return string(value)
    T === Bool && value isa Bool && return value
    T === Bool && value isa AbstractString && return value in ("true", "1", "yes")
    T <: Integer && value isa Number && return T(value)
    T <: Integer && value isa AbstractString && return T(parse(Int, value))
    T <: AbstractFloat && value isa Number && return T(value)
    T <: AbstractFloat && value isa AbstractString && return T(parse(Float64, value))

    # Symbol
    T === Symbol && value isa String && return Symbol(value)

    # Enum
    if T isa DataType && T <: Enum && value isa String
        for inst in instances(T)
            string(inst) == value && return inst
        end
        error(
            "Invalid enum value '$value' for $T. Valid: $(join(string.(instances(T)), ", "))",
        )
    end

    # Struct from Dict
    if T isa DataType && isstructtype(T) && value isa Dict
        fnames = fieldnames(T)
        ftypes = fieldtypes(T)
        fargs = Any[]
        for (fname, ftype) in zip(fnames, ftypes)
            fval = get(value, string(fname), nothing)
            push!(fargs, _coerce_value(fval, ftype))
        end
        return T(fargs...)
    end

    # Vector
    if T <: AbstractVector && value isa Vector
        elem = eltype(T)
        isempty(value) && return elem[]
        return elem[_coerce_value(v, elem) for v in value]
    end

    # Fallback: try convert
    try
        return convert(T, value)
    catch
        return value
    end
end

"""Return a Dict mapping kwarg name → declared type, using the inner body function.

Works for both top-level functions (via Base.bodyfunction) and closures (by
extracting the inner body closure stored as a field of the outer kwarg wrapper).
In both cases the inner function's positional args are [self, kw1, kw2, ..., outer_fn].
"""
function _kwarg_types(handler::Function)::Dict{Symbol,Any}
    result = Dict{Symbol,Any}()
    try
        m = first(methods(handler))
        kw_names = Base.kwarg_decl(m)
        isempty(kw_names) && return result

        # Get the inner body function — it has kwargs as typed positional args.
        # For top-level functions, Base.bodyfunction works directly.
        # For closures, the outer kwarg wrapper captures the inner body as its
        # only field (e.g. handler.#foo#16).
        inner_fn = try
            body = Base.bodyfunction(m)
            isempty(methods(body)) ? nothing : body
        catch
            nothing
        end

        if inner_fn === nothing
            # Closure: extract inner body from the single captured field
            fnames = fieldnames(typeof(handler))
            if length(fnames) == 1
                candidate = getfield(handler, fnames[1])
                candidate isa Function && (inner_fn = candidate)
            end
        end

        inner_fn === nothing && return result

        inner_m = first(methods(inner_fn))
        sig = inner_m.sig
        while sig isa UnionAll; sig = sig.body; end
        # Layout: [typeof(inner), kwarg_types..., typeof(outer_fn)]
        params = sig.parameters
        for (i, kw) in enumerate(kw_names)
            idx = i + 1   # skip the function-type param at position 1
            idx < length(params) && (result[kw] = params[idx])
        end
    catch
    end
    return result
end

"""
    _dispatch_tool_call(handler, args::Dict{String,Any})

Dispatch a tool call to the handler with properly typed arguments.
If the handler accepts a Dict, calls directly. Otherwise, reflects on
the method signature to reconstruct typed positional and keyword arguments.
"""
function _dispatch_tool_call(handler::Function, args::Dict{String,Any})
    # Fast path: handler accepts a Dict directly
    if hasmethod(handler, Tuple{Dict{String,Any}})
        return handler(args)
    end

    ms = methods(handler)
    isempty(ms) && error("No methods found for handler")
    m = first(ms)

    # Get arg names (skip first = function itself)
    arg_names_all = Base.method_argnames(m)
    arg_names = length(arg_names_all) > 1 ? arg_names_all[2:end] : Symbol[]

    # Get types from signature
    sig = m.sig
    while sig isa UnionAll
        sig = sig.body
    end
    sig_params = sig.parameters
    arg_types = length(sig_params) > 1 ? sig_params[2:end] : []

    # Build positional args
    pos_args = Any[]
    for i in eachindex(arg_names)
        name = string(arg_names[i])
        T = i <= length(arg_types) ? arg_types[i] : Any
        if haskey(args, name)
            push!(pos_args, _coerce_value(args[name], T))
        end
    end

    # Build kwargs
    kw_names = try
        Base.kwarg_decl(m)
    catch
        Symbol[]
    end
    kw_types = _kwarg_types(handler)
    kwargs = Pair{Symbol,Any}[]
    for kw in kw_names
        kw_str = string(kw)
        if haskey(args, kw_str)
            T = get(kw_types, kw, Any)
            push!(kwargs, kw => _coerce_value(args[kw_str], T))
        end
    end

    return handler(pos_args...; kwargs...)
end

# ── Core eval logic ──────────────────────────────────────────────────────────
# Extracted from Kaimon's execute_repllike, stripped of MCP-specific concerns
# (truncation, println stripping, prompt display). Those stay on the server side.

function _mirror_print(f::Function)
    try
        f()
    catch e
        e isa Base.IOError && (_MIRROR_REPL[] = false)
    end
end

function gate_eval(code::String; _mod::Module = Main, display_code::String = code)
    lock(GATE_LOCK)
    try
        if _MIRROR_REPL[]
            _mirror_print() do
                printstyled("\nagent> ", color = :red, bold = true)
                print(display_code, "\n")
            end
        end

        # Check REPL availability
        repl =
            (isdefined(Base, :active_repl) && Base.active_repl !== nothing) ?
            Base.active_repl : nothing
        backend =
            repl !== nothing && hasproperty(repl, :backendref) ? repl.backendref : nothing
        has_repl =
            repl !== nothing &&
            backend !== nothing &&
            hasproperty(backend, :repl_channel) &&
            hasproperty(backend, :response_channel) &&
            isopen(backend.repl_channel) &&
            isopen(backend.response_channel)

        expr = Base.parse_input_line(code)

        # Use call_on_backend only from the message loop (synchronous :eval
        # on the interactive thread). Async evals run on default-pool threads
        # via Threads.@spawn — call_on_backend would deadlock because the
        # REPL backend is occupied by the user's interactive session.
        on_interactive = Threads.threadpool(Threads.threadid()) === :interactive
        if has_repl && on_interactive
            result = REPL.call_on_backend(() -> _eval_with_capture(expr), backend)
            # call_on_backend returns (value, iserr) Pair or NamedTuple
            val = if result isa Pair
                result.first
            elseif result isa Tuple && length(result) == 2
                result[1]
            else
                result
            end
            _maybe_echo_result(val)
            return val
        else
            val = _eval_with_capture(expr)
            _maybe_echo_result(val)
            return val
        end
    catch e
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = sprint(showerror, e, catch_backtrace()),
            backtrace = sprint(Base.show_backtrace, catch_backtrace()),
        )
    finally
        unlock(GATE_LOCK)
    end
end

function _maybe_echo_result(result)
    _MIRROR_REPL[] || return

    has_exc = hasproperty(result, :exception) && result.exception !== nothing
    if has_exc
        _mirror_print() do
            printstyled("ERROR: ", color = :red, bold = true)
            println(string(result.exception))
        end
        return
    end

    # stdout/stderr are mirrored live while reading redirected streams.
    if hasproperty(result, :value_repr)
        val = string(result.value_repr)
        isempty(val) || _mirror_print(() -> println(val))
    end
end

function _set_option!(key::String, value)
    if key == "mirror_repl"
        if value === true && !_ALLOW_MIRROR[]
            return (type = :ok, key = key, value = false)
        end
        _MIRROR_REPL[] = value === true
        return (type = :ok, key = key, value = _MIRROR_REPL[])
    end
    return (type = :error, message = "unknown option: $key")
end

function _current_options()
    return (type = :options, mirror_repl = _MIRROR_REPL[], allow_mirror = _ALLOW_MIRROR[])
end

"""
    tty_path() -> Union{String, Nothing}

Return the TTY device path configured for this gate session (e.g.
`"/dev/ttys042"`), or `nothing` if no external TTY has been set.

Use this in app code to forward rendering to a separate terminal window:

```julia
Tachikoma.app(model; tty_out = KaimonGate.tty_path(), tty_size = KaimonGate.tty_size())
```
"""
tty_path() = _GATE_TTY_PATH[]

"""
    tty_size() -> Union{Nothing, NamedTuple{(:rows, :cols)}}

Return the detected size of the configured external TTY, or `nothing`.
"""
tty_size() = _GATE_TTY_SIZE[]

function _detect_tty_size(path::String)
    try
        out = readchomp(pipeline(`stty size`, stdin = open(path, "r")))
        parts = split(out)
        length(parts) == 2 || return nothing
        rows = parse(Int, parts[1])
        cols = parse(Int, parts[2])
        rows > 0 && cols > 0 ? (rows = rows, cols = cols) : nothing
    catch
        nothing
    end
end

# Signal numbers (platform-specific)
const _SIGSTOP = @static Sys.isapple() ? Cint(17) : Cint(19)
const _SIGCONT = @static Sys.isapple() ? Cint(19) : Cint(18)

"""
Park the foreground shell of `path` by sending SIGSTOP to its process group,
and disable echo so no input appears on the display. Idempotent.
"""
function _park_remote_shell!(path::String)
    # Resume any previously parked shell first
    _unpark_remote_shell!()
    try
        # Use `ps` to find the process group IDs on this TTY.
        # TIOCGPGRP ioctl fails (ENOTTY) when our process doesn't own the session.
        tty_name = basename(path)  # e.g. "ttys019" from "/dev/ttys019"
        out = read(`ps -t $tty_name -o pgid=`, String)
        pgrps = unique([
            p for line in split(out, '\n') for
            p in (tryparse(Int32, strip(line)),) if p !== nothing && p > 0
        ])
        isempty(pgrps) && return
        # Disable echo
        try
            run(pipeline(`stty -echo`, stdin = open(path, "r")), wait = true)
            _GATE_TTY_ECHO_DISABLED[] = true
        catch
        end
        # Pause all process groups on this TTY (SIGSTOP cannot be caught or ignored)
        for pgrp in pgrps
            ccall(:kill, Cint, (Cint, Cint), -pgrp, _SIGSTOP)
        end
        _GATE_TTY_PARKED_PGRP[] = pgrps[1]
    catch
    end
end

"""
Resume a shell previously parked by `_park_remote_shell!` and restore echo.
"""
function _unpark_remote_shell!()
    pgrp = _GATE_TTY_PARKED_PGRP[]
    pgrp === nothing && return
    _GATE_TTY_PARKED_PGRP[] = nothing
    # Restore echo before resuming so the shell sees the correct settings
    if _GATE_TTY_ECHO_DISABLED[]
        path = _GATE_TTY_PATH[]
        if path !== nothing
            try
                run(pipeline(`stty echo`, stdin = open(path, "r")), wait = true)
            catch
            end
        end
        _GATE_TTY_ECHO_DISABLED[] = false
    end
    # Resume the process group
    try
        ccall(:kill, Cint, (Cint, Cint), -pgrp, _SIGCONT)
    catch
    end
end

"""
    set_tty!(path::String)

Configure an external TTY for rendering.

Detects the terminal size, pauses the shell in the remote terminal (via
SIGSTOP so nothing can be typed or echoed), and stores the path so
[`tty_path`](@ref) and [`tty_size`](@ref) return it for use by app code.

Call [`restore_tty!`](@ref) (or use the `finally` block pattern) after the
TUI exits to resume the shell and restore echo.

The TUI polls the remote terminal's size once per second, so resizing the
window works during rendering.
"""
function set_tty!(path::String)
    Sys.iswindows() && return (
        type = :error,
        message = "set_tty! requires a Unix TTY device (macOS/Linux only)",
    )
    ispath(path) || return (type = :error, message = "TTY device not found: $path")
    sz = _detect_tty_size(path)
    _GATE_TTY_PATH[] = path
    _GATE_TTY_SIZE[] = sz
    _park_remote_shell!(path)
    return (
        type = :ok,
        tty_path = path,
        rows = sz !== nothing ? sz.rows : nothing,
        cols = sz !== nothing ? sz.cols : nothing,
    )
end

"""
    restore_tty!()

Resume the shell paused by [`set_tty!`](@ref) and restore echo.
Call this after the TUI app exits (typically in a `finally` block).
"""
function restore_tty!()
    _unpark_remote_shell!()
end

# ── Stream broadcaster: the XPUB's single owning task ────────────────────────

# Apply a 0->1 / 1->0 transition for a topic and fire the right callbacks.
# Parses one XPUB subscription frame: first byte 0x01=subscribe / 0x00=
# unsubscribe, remaining bytes = the subscription topic (e.g. "tui:bounce", or
# "" for a subscribe-all client like the Kaimon TUI).
function _handle_subscription_frame(frame::Vector{UInt8})
    isempty(frame) && return nothing
    is_sub = frame[1] == 0x01
    topic = String(@view frame[2:end])
    transition = lock(_STREAM_SUBS_LOCK) do
        n = get(_STREAM_SUBS, topic, 0)
        if is_sub
            _STREAM_SUBS[topic] = n + 1
            return n == 0 ? :join : :none
        else
            m = max(n - 1, 0)
            m == 0 ? delete!(_STREAM_SUBS, topic) : (_STREAM_SUBS[topic] = m)
            return (n > 0 && m == 0) ? :leave : :none
        end
    end
    transition === :join && _fire_stream_callbacks(_ON_STREAM_SUBSCRIBE, topic)
    transition === :leave && _fire_stream_callbacks(_ON_STREAM_UNSUBSCRIBE, topic)
    return nothing
end

# Invoke presence callbacks on the broadcaster's owning thread. Snapshot under
# the lock, call outside it. Keep callbacks cheap (or hand off to a channel).
function _fire_stream_callbacks(cbs::Vector{Any}, topic::String)
    fns = lock(_STREAM_SUBS_LOCK) do
        copy(cbs)
    end
    for f in fns
        try
            Base.invokelatest(f, topic)
        catch e
            @debug "stream presence callback error" topic = topic exception = e
        end
    end
    return nothing
end

# Hygiene pass: prune non-positive topics. XPUB can't re-derive the live set, so
# correctness of leaves rests on clean closes + TCP keepalive; this is just
# cleanup + a place to surface anomalies.
function _reconcile_stream_subs()
    lock(_STREAM_SUBS_LOCK) do
        for (t, n) in collect(_STREAM_SUBS)
            n <= 0 && delete!(_STREAM_SUBS, t)
        end
    end
    return nothing
end

# Send one message's frames as a multipart on the owner-only socket.
function _stream_send(sock::ZMQ.Socket, frames::Vector{Vector{UInt8}})
    n = length(frames)
    for (i, f) in enumerate(frames)
        send(sock, f; more = (i < n))
    end
    return nothing
end

# The XPUB's single owner. Interleaves draining publish work (the hot stdout
# path — prioritized) with polling for subscription events. Polls `events &
# POLLIN` before recv to avoid the costly throw path when idle (mirrors the
# client SUB drain).
function _stream_broadcaster(sock::ZMQ.Socket)
    last_reconcile = time()
    while _RUNNING[]
        work = false
        # 1. drain all queued publishes first (owner-only send).
        while isready(_STREAM_OUTBOX)
            frames = take!(_STREAM_OUTBOX)
            try
                _stream_send(sock, frames)
            catch e
                @debug "stream publish failed" exception = e
            end
            work = true
        end
        # 2. poll one subscription event (non-blocking; rcvtimeo=0 as a backstop).
        if (try (sock.events & ZMQ.POLLIN) != 0 catch; false end)
            frame = try
                _zmq_recv(sock)
            catch e
                e isa ZMQ.StateError && !_RUNNING[] && break
                UInt8[]
            end
            if !isempty(frame)
                _handle_subscription_frame(frame)
                work = true
            end
        end
        # 3. periodic hygiene.
        if time() - last_reconcile >= _STREAM_RECONCILE_EVERY
            _reconcile_stream_subs()
            last_reconcile = time()
        end
        work || sleep(0.005)   # idle backoff; keeps event latency ~<=5ms
    end
    # Final bounded drain so late lifecycle messages (eval_complete) flush.
    deadline = time() + 1.0
    while isready(_STREAM_OUTBOX) && time() < deadline
        try
            _stream_send(sock, take!(_STREAM_OUTBOX))
        catch
            break
        end
    end
    return nothing
end

# ── Stream presence API (for out-of-band consumers, e.g. TachiRei) ───────────

"""
    on_stream_subscribe(f) -> nothing

Register `f(topic::String)` to be called when a topic gains its FIRST subscriber
(0->1). Invoked on the broadcaster's owning thread, so keep `f` cheap (or hand
off to a channel). Use to e.g. publish a keyframe the moment a viewer attaches.
"""
on_stream_subscribe(f) = (lock(_STREAM_SUBS_LOCK) do; push!(_ON_STREAM_SUBSCRIBE, f); end; nothing)

"""
    on_stream_unsubscribe(f) -> nothing

Register `f(topic::String)` to be called when a topic loses its LAST subscriber
(1->0). Invoked on the broadcaster's owning thread; keep `f` cheap.
"""
on_stream_unsubscribe(f) = (lock(_STREAM_SUBS_LOCK) do; push!(_ON_STREAM_UNSUBSCRIBE, f); end; nothing)

"""    stream_subscribed(topic) -> Bool

True if at least one subscriber is currently attached to `topic`."""
stream_subscribed(topic::AbstractString) =
    lock(_STREAM_SUBS_LOCK) do; get(_STREAM_SUBS, String(topic), 0) > 0 end

"""    stream_subscriber_count(topic) -> Int

Current subscriber count for `topic` (via XPUB_VERBOSER). Reliable on clean
closes/IPC; on hard TCP-viewer disconnects the count self-corrects once libzmq's
keepalive detects the dead peer."""
stream_subscriber_count(topic::AbstractString) =
    lock(_STREAM_SUBS_LOCK) do; get(_STREAM_SUBS, String(topic), 0) end

"""    stream_topics() -> Vector{String}

All topics with at least one subscriber, sorted."""
stream_topics() = lock(_STREAM_SUBS_LOCK) do; sort!(collect(keys(_STREAM_SUBS))) end

# ── Publishing (enqueue-only; the broadcaster owns the socket) ───────────────

function _publish_stream(channel::String, data; request_id::String = "")
    _STREAM_SOCKET[] === nothing && return
    io = IOBuffer()
    msg =
        isempty(request_id) ? (channel = channel, data = data) :
        (channel = channel, data = data, request_id = request_id)
    serialize(io, msg)
    try
        put!(_STREAM_OUTBOX, Vector{UInt8}[take!(io)])
    catch e
        # The caller hangs if eval-lifecycle messages are lost.
        if channel in ("eval_complete", "eval_error", "tool_complete", "tool_error")
            @error "Failed to enqueue $channel (request_id=$request_id)" exception = e
        end
    end
    return
end

"""
    publish(topic, payload) -> nothing

Broadcast `payload` on the gate's stream socket under `topic` as a **2-frame
multipart** message `[topic, serialize(payload)]`, so subscribers can prefix-
filter server-side (e.g. `KaimonGate.subscribe(endpoint; topic="tui:")`). For
out-of-band consumers such as TachiRei's `tui:<session>` observe stream. No-op if
the gate isn't serving.

Enqueues to the broadcaster (the XPUB's single owner); the actual send happens on
that task. This is distinct from the internal single-blob `_publish_stream`
(stdout/stderr/eval lifecycle) that the Kaimon client consumes — the multipart
framing lets that client recognize and skip observe broadcasts (it checks
`rcvmore`). Subscribe with [`subscribe`](@ref); observe presence with
[`stream_subscribed`](@ref) / [`on_stream_subscribe`](@ref).
"""
function publish(topic::AbstractString, payload)
    _STREAM_SOCKET[] === nothing && return nothing
    io = IOBuffer()
    serialize(io, payload)
    frames = Vector{UInt8}[Vector{UInt8}(codeunits(String(topic))), take!(io)]
    try
        put!(_STREAM_OUTBOX, frames)
    catch e
        @debug "publish enqueue failed" topic = topic exception = e
    end
    return nothing
end

function _start_revise_watcher()
    isdefined(Main, :Revise) || return
    isdefined(Main.Revise, :revision_event) || return
    _REVISE_WATCHER_TASK[] = @async begin
        try
            while _RUNNING[]
                wait(Main.Revise.revision_event)
                _RUNNING[] || break
                Base.reset(Main.Revise.revision_event)
                project_path = dirname(Base.active_project())
                _publish_stream("files_changed", project_path)
            end
        catch e
            e isa InterruptException && return
            @debug "Revise watcher exited" exception = e
        end
    end
end

function _eval_with_capture(expr)
    orig_stdout = stdout
    orig_stderr = stderr

    stdout_read, stdout_write = redirect_stdout()
    stderr_read, stderr_write = redirect_stderr()

    stdout_content = String[]
    stderr_content = String[]

    stdout_task = @async begin
        try
            while !eof(stdout_read)
                line = readline(stdout_read; keep = true)
                push!(stdout_content, line)
                if _MIRROR_REPL[]
                    try
                        write(orig_stdout, line)
                        flush(orig_stdout)
                    catch e
                        e isa Base.IOError && (_MIRROR_REPL[] = false)
                    end
                end
                _publish_stream("stdout", line)
            end
        catch e
            e isa EOFError || @debug "stdout read error" exception = e
        end
    end

    stderr_task = @async begin
        try
            while !eof(stderr_read)
                line = readline(stderr_read; keep = true)
                push!(stderr_content, line)
                if _MIRROR_REPL[]
                    try
                        write(orig_stderr, line)
                        flush(orig_stderr)
                    catch e
                        e isa Base.IOError && (_MIRROR_REPL[] = false)
                    end
                end
                _publish_stream("stderr", line)
            end
        catch e
            e isa EOFError || @debug "stderr read error" exception = e
        end
    end

    value = nothing
    caught = nothing
    bt = nothing
    try
        # Apply REPL ast_transforms (Revise, softscope, etc.)
        if isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing
            for xf in Base.active_repl_backend.ast_transforms
                expr = Base.invokelatest(xf, expr)
            end
        end
        value = Core.eval(Main, expr)
    catch e
        caught = e
        bt = catch_backtrace()
    finally
        # Restore original streams. If orig_stdout/orig_stderr is a broken pipe
        # (e.g. Tachikoma pixel renderer closed its terminal pipe), fall back to
        # devnull rather than leaving stdout in an unusable state.
        try
            redirect_stdout(orig_stdout)
        catch
            redirect_stdout(devnull)
        end
        try
            redirect_stderr(orig_stderr)
        catch
            redirect_stderr(devnull)
        end
        # Close pipes and wait for drain tasks asynchronously.
        # Blocking here would delay the eval response, and with @async
        # drain tasks on the same thread the close→EOF→drain exit path
        # needs the event loop to run (which it can't if we're blocking).
        @async begin
            try; close(stdout_write); catch; end
            try; close(stderr_write); catch; end
            try; wait(stdout_task); catch; end
            try; wait(stderr_task); catch; end
            try; close(stdout_read); catch; end
            try; close(stderr_read); catch; end
        end
        # Yield to let drain tasks collect any final buffered output
        yield()
    end

    # Format value representation.
    # Use invokelatest so that methods defined during this eval (e.g. by
    # `using SomePackage`) are visible — without it, show/repr can fail with
    # "method too new to be called from this world context" when run on the
    # REPL backend thread.
    value_repr = ""
    if value !== nothing
        io = IOBuffer()
        try
            Base.invokelatest(show, io, MIME("text/plain"), value)
            value_repr = String(take!(io))
        catch
            value_repr = Base.invokelatest(repr, value)
        end
    end

    exception_str = if caught !== nothing
        io = IOBuffer()
        try
            Base.invokelatest(showerror, io, caught, bt)
        catch
            Base.invokelatest(showerror, io, caught)
        end
        String(take!(io))
    else
        nothing
    end

    return (
        stdout = join(stdout_content),
        stderr = join(stderr_content),
        value_repr = value_repr,
        exception = exception_str,
        backtrace = nothing,
    )
end

# ── Metadata ──────────────────────────────────────────────────────────────────

function _json_value(v)
    v isa Bool && return v ? "true" : "false"
    v isa Number && return string(v)
    return "\"$v\""
end

function write_metadata(
    session_id::String,
    name::String,
    endpoint::String,
    stream_endpoint::String = "";
    spawned_by::String = "user",
    mode::Symbol = :ipc,
)
    meta_path = joinpath(sock_dir(),"$(session_id).json")
    meta = Dict{String,Any}(
        "session_id" => session_id,
        "name" => name,
        "pid" => getpid(),
        "julia_version" => string(VERSION),
        "project_path" => dirname(Base.active_project()),
        "endpoint" => endpoint,
        "stream_endpoint" => stream_endpoint,
        "started_at" => string(now()),
        "spawned_by" => spawned_by,
        "mode" => string(mode),
    )
    open(meta_path, "w") do io
        # Simple JSON without dependency — just key-value pairs
        print(io, "{\n")
        pairs = collect(meta)
        for (i, (k, v)) in enumerate(pairs)
            print(io, "  \"$k\": $(_json_value(v))")
            i < length(pairs) && print(io, ",")
            print(io, "\n")
        end
        print(io, "}\n")
    end

    return meta_path
end

function cleanup_files(session_id::String)
    # Always clean up the metadata JSON. Socket files only exist in IPC mode.
    for ext in [".sock", "-stream.sock", ".json"]
        path = joinpath(sock_dir(),"$(session_id)$(ext)")
        isfile(path) && rm(path; force = true)
    end
end

# ── Message loop ──────────────────────────────────────────────────────────────

"""
Serialize a result NamedTuple to bytes for PUB transport.
"""
function _serialize_result(result)::String
    io = IOBuffer()
    serialize(io, result)
    return String(take!(io))
end

"""
    _capture_original_argv()

Capture the original process argv once, for replay on restart.
"""
function _capture_original_argv()
    !isempty(_ORIGINAL_ARGV[]) && return
    try
        if Sys.isapple()
            argc_ptr = ccall(:_NSGetArgc, Ptr{Cint}, ())
            argv_ptr = ccall(:_NSGetArgv, Ptr{Ptr{Ptr{UInt8}}}, ())
            argc = unsafe_load(argc_ptr)
            argv_p = unsafe_load(argv_ptr)
            _ORIGINAL_ARGV[] = [unsafe_string(unsafe_load(argv_p, i)) for i = 1:argc]
        elseif Sys.islinux()
            parts = split(read("/proc/self/cmdline", String), '\0'; keepempty = false)
            _ORIGINAL_ARGV[] = String.(parts)
        end
    catch e
        @debug "Failed to capture original argv" exception = e
    end
end

"""
    _should_replay_argv()

Check if the original process was started with user-provided code that should
be replayed on restart: a `-e` command (not our own restart code) or a script file.
"""
function _should_replay_argv()
    argv = _ORIGINAL_ARGV[]
    isempty(argv) && return false
    # Check for -e flag with user code
    for (i, arg) in enumerate(argv)
        if arg == "-e" && i < length(argv)
            code = argv[i+1]
            # Our restart serve() pattern → not user code
            occursin("Gate.serve(session_id=", code) && return false
            return true
        end
    end
    # Check for script file (positional arg that's a file path, not a flag)
    # Skip argv[1] (julia binary). Look for first non-flag argument.
    for i = 2:length(argv)
        arg = argv[i]
        startswith(arg, "-") && continue
        # Previous arg was a flag expecting a value (e.g. -C native, -J sysimg, --project=...)
        i > 1 && argv[i-1] in ("-C", "-J", "--project", "-t") && continue
        # This is a positional argument — likely a script file
        isfile(arg) && return true
    end
    return false
end

"""
    _base_julia_args() -> Vector{String}

Return the Julia binary + original launch flags, stripping only the arguments
that `_exec_restart` will inject itself: `-e`/`--eval` (+ value), `--project`
(+ value), and `-i`.  Everything else — `-t`, `--heap-size-hint`, `--gcthreads`,
`-O`, custom sysimage flags, etc. — is preserved verbatim from `_ORIGINAL_ARGV[]`.

Falls back to `Base.julia_cmd().exec` if `_ORIGINAL_ARGV[]` was not captured
(non-macOS/non-Linux or capture failed).
"""
function _base_julia_args()::Vector{String}
    orig = _ORIGINAL_ARGV[]
    isempty(orig) && return Base.julia_cmd().exec

    # Flags that take a separate value and should be combined into one token
    # (e.g. `-t 4,2` → `-t4,2`) to avoid the value being misinterpreted as a
    # positional script argument on restart.
    _VALUE_FLAGS = Set(["-t", "--threads", "-C", "--cpu-target",
                        "-J", "--sysimage", "-O", "--optimize",
                        "-L", "--load",
                        "--gcthreads", "--heap-size-hint"])

    result = [orig[1]]   # preserve exact Julia binary path
    i = 2
    while i <= length(orig)
        arg = orig[i]
        # Strip flags whose values we inject ourselves
        if arg in ("-e", "--eval", "--project")
            i += 2   # skip flag + separate value
            continue
        end
        if startswith(arg, "--eval=") || startswith(arg, "--project=")
            i += 1   # skip combined form
            continue
        end
        # Strip bare -i (we add our own); leave e.g. --inline alone
        if arg == "-i"
            i += 1
            continue
        end
        # Combine short flags with their separate value into one token
        # so the value isn't mistaken for a positional arg on restart
        if arg in _VALUE_FLAGS && i < length(orig) && !startswith(orig[i+1], "-")
            if startswith(arg, "--")
                push!(result, "$(arg)=$(orig[i+1])")
            else
                push!(result, "$(arg)$(orig[i+1])")
            end
            i += 2
            continue
        end
        push!(result, arg)
        i += 1
    end
    return result
end

"""
    _exec_restart(name, session_id, project_path)

Replace the current process with a fresh Julia via `execvp`. Same PID, same
terminal, fresh Julia state. The `-i` flag keeps the REPL interactive.
"""
function _exec_restart(name::String, session_id::String, project_path::String)
    # Signal to all serve() callers in the new process (startup.jl, app code,
    # or our injected -e fallback) that this is a restart and they should
    # reuse this session_id so the TUI reconnects to the same session.
    ENV["KAIMON_RESTART_SESSION"] = session_id

    args = if _should_replay_argv()
        # Replay original argv exactly — the app code (e.g. GateToolTest.run()
        # or bin/kaimon) will call serve(force=true) itself; the env var carries
        # the session_id through. Don't inject -i: it would initialize a REPL
        # backend that conflicts with TUI terminal handling.
        copy(_ORIGINAL_ARGV[])
    else
        # Plain REPL session — reconstruct from the original argv, preserving
        # all launch flags (-t, --heap-size-hint, --gcthreads, -O, etc.), then
        # inject our own --project / -i / -e serve(...).
        julia_args = _base_julia_args()
        ns      = _SESSION_NAMESPACE[]
        mirror  = _ALLOW_MIRROR[]
        restart = _ALLOW_RESTART[]
        mode    = _MODE[]
        ns_kwarg      = isempty(ns) ? "" : ", namespace=$(repr(ns))"
        mirror_kwarg  = mirror  ? "" : ", allow_mirror=false"
        restart_kwarg = restart ? "" : ", allow_restart=false"
        # TCP mode: replay host, port, stream_port so the gate rebinds on the same address
        tcp_kwargs = if mode == :tcp
            host = _TCP_HOST[]
            port = _TCP_PORT[]
            sp   = _TCP_STREAM_PORT[]
            base = ", mode=:tcp, host=$(repr(host)), port=$port, stream_port=$sp"
            # CURVE: replay the flag; the server secret + allow-list persist on
            # disk (curve/ dir) so the gate rebinds with the same identity.
            curve_kw = _CURVE_ENABLED[] ?
                ", curve=true" * (_CURVE_ALLOW_ANY[] ? ", allow_any=true" : "") : ""
            base * curve_kw
        else
            ""
        end
        # The injected -e code runs after startup.jl.  If startup.jl already
        # called serve() and picked up KAIMON_RESTART_SESSION, the gate
        # will already be running with the correct session_id; our serve() call
        # becomes a no-op that updates mutable options (mirror, restart flag).
        # If startup.jl didn't call serve, this creates the gate from scratch.
        serve_args = "session_id=$(repr(session_id))$ns_kwarg$mirror_kwarg$restart_kwarg$tcp_kwargs"
        serve_code = _RESTART_CODE_BUILDER[](serve_args)
        vcat(julia_args, ["--project=$project_path", "-i", "-e", serve_code])
    end

    # Restore terminal state and stdio fds before execvp. Tachikoma's
    # with_terminal() has the TUI in alt screen/raw mode and stdout/stderr
    # redirected to pipes. prepare_for_exec!() restores everything at the
    # OS fd level so the new process gets clean TTY IO.
    # Use the host-injected Tachikoma hook; nothing when running standalone.
    try
        T = _TACHIKOMA[]
        if T !== nothing
            if isdefined(T, :prepare_for_exec!)
                Base.invokelatest(getfield(T, :prepare_for_exec!))
            end
        end
    catch
    end

    # Clear the terminal so the restarted session starts with a clean screen.
    # prepare_for_exec!() has already restored the TTY to cooked mode.
    print(stdout, "\e[H\e[2J")
    flush(stdout)

    # execvp replaces the process image — same PID, same terminal
    argv = map(String, args)
    ptrs = Ptr{UInt8}[pointer(s) for s in argv]
    push!(ptrs, Ptr{UInt8}(0))  # NULL terminator
    GC.@preserve argv ccall(:execvp, Cint, (Cstring, Ptr{Ptr{UInt8}}), argv[1], ptrs)

    # If we reach here, execvp failed — fall back to exit
    @error "execvp failed, falling back to exit" errno = Base.Libc.errno()
    exit(1)
end

function handle_message(request::NamedTuple)
    # TCP auth: reject unauthenticated requests when a token is set
    if _MODE[] == :tcp && !isempty(_AUTH_TOKEN[])
        token = get(request, :token, "")
        if token != _AUTH_TOKEN[]
            return (type = :error, message = "Authentication required")
        end
    end

    msg_type = get(request, :type, :unknown)
    _MSG_COUNT[] += 1

    if msg_type == :eval
        code = get(request, :code, "")
        display_code = get(request, :display_code, code)
        result = gate_eval(code; display_code = display_code)
        return result
    elseif msg_type == :eval_async
        code = get(request, :code, "")
        display_code = get(request, :display_code, code)
        request_id = get(request, :request_id, "")
        main_thread = get(request, :main_thread, false)
        # Run eval on a spawned thread so the interactive message loop stays
        # responsive to pings during CPU-intensive evals.
        # When main_thread=true, spawn on :interactive so gate_eval routes
        # through REPL.call_on_backend (thread 1) — required for GLMakie/GLFW.
        function _do_async_eval()
            try
                task_local_storage(:gate_request_id, request_id)
                result = gate_eval(code; display_code = display_code)
                try
                    serialized = _serialize_result(result)
                    # Cache result so TUI can retrieve it after a restart
                    lock(_COMPLETED_RESULTS_LOCK) do
                        _COMPLETED_RESULTS[request_id] = Vector{UInt8}(serialized)
                        # Trim to max size
                        while length(_COMPLETED_RESULTS) > _COMPLETED_RESULTS_MAX
                            delete!(_COMPLETED_RESULTS, first(keys(_COMPLETED_RESULTS)))
                        end
                    end
                    _stderr_finish!()  # finalize any \r-overwritten progress/stash lines
                    _publish_stream("eval_complete", serialized; request_id)
                catch pub_err
                    # Serialization of result failed — send a plain-text fallback
                    @error "Failed to serialize eval result" exception = pub_err
                    fallback = (
                        stdout = "",
                        stderr = "",
                        value_repr = "(result could not be serialized: $(sprint(showerror, pub_err)))",
                        exception = nothing,
                        backtrace = nothing,
                    )
                    _publish_stream("eval_complete", _serialize_result(fallback); request_id)
                end
            catch e
                error_result = (
                    stdout = "",
                    stderr = "",
                    value_repr = "",
                    exception = sprint(showerror, e, catch_backtrace()),
                    backtrace = nothing,
                )
                _publish_stream("eval_error", _serialize_result(error_result); request_id)
            end
        end
        if main_thread
            Threads.@spawn :interactive _do_async_eval()
        else
            Threads.@spawn _do_async_eval()
        end
        return (type = :accepted, request_id = request_id)
    elseif msg_type == :set_option
        key = string(get(request, :key, ""))
        value = get(request, :value, nothing)
        return _set_option!(key, value)
    elseif msg_type == :get_options
        return _current_options()
    elseif msg_type == :set_tty
        path = string(get(request, :path, ""))
        isempty(path) && return (type = :error, message = "path required")
        return set_tty!(path)
    elseif msg_type == :ping
        _PING_COUNT[] += 1
        _LAST_PING_TIME[] = time()
        _kv = try; _VERSION_PROVIDER[](); catch; "unknown"; end
        return (
            type = :pong,
            pid = getpid(),
            uptime = time() - _START_TIME[],
            julia_version = string(VERSION),
            protocol_version = PROTOCOL_VERSION,
            kaimon_version = _kv,
            project_path = dirname(Base.active_project()),
            tools = [_reflect_tool(t) for t in _SESSION_TOOLS[]],
            namespace = _SESSION_NAMESPACE[],
            allow_restart = _ALLOW_RESTART[],
            allow_mirror = _ALLOW_MIRROR[],
            mirror_repl = _MIRROR_REPL[],
            stream_endpoint = _STREAM_ENDPOINT[],
            server_pubkey = _CURVE_SERVER_PUBLIC[],
        )
    elseif msg_type == :tool_call
        tool_name = string(get(request, :name, ""))
        raw_args = get(request, :arguments, Dict{String,Any}())
        # Convert to Dict{String,Any} whether args come as NamedTuple or Dict
        tool_args = if raw_args isa Dict
            Dict{String,Any}(string(k) => v for (k, v) in raw_args)
        else
            Dict{String,Any}(string(k) => v for (k, v) in pairs(raw_args))
        end
        idx = findfirst(t -> t.name == tool_name, _SESSION_TOOLS[])
        if idx === nothing
            return (type = :error, message = "Unknown session tool: $tool_name")
        end
        tool = _SESSION_TOOLS[][idx]
        try
            result = _dispatch_tool_call(tool.handler, tool_args)
            return (type = :result, value = result)
        catch e
            return (type = :error, message = sprint(showerror, e))
        end
    elseif msg_type == :tool_call_async
        tool_name = string(get(request, :name, ""))
        raw_args = get(request, :arguments, Dict{String,Any}())
        tool_args = if raw_args isa Dict
            Dict{String,Any}(string(k) => v for (k, v) in raw_args)
        else
            Dict{String,Any}(string(k) => v for (k, v) in pairs(raw_args))
        end
        request_id = string(get(request, :request_id, ""))

        idx = findfirst(t -> t.name == tool_name, _SESSION_TOOLS[])
        if idx === nothing
            return (type = :error, message = "Unknown session tool: $tool_name")
        end
        tool = _SESSION_TOOLS[][idx]

        # Run tool handler on a default-pool thread so the interactive message
        # loop stays responsive to pings during CPU-intensive tool calls.
        Threads.@spawn begin
            try
                # Make progress function available via task-local storage
                task_local_storage(:gate_request_id, request_id)
                task_local_storage(:gate_progress, true)

                result = _dispatch_tool_call(tool.handler, tool_args)
                _stderr_finish!()
                _publish_stream("tool_complete", string(result); request_id)
            catch e
                _publish_stream(
                    "tool_error",
                    sprint(showerror, e, catch_backtrace());
                    request_id,
                )
            end
        end

        return (type = :accepted, request_id = request_id)
    elseif msg_type == :list_tools
        tool_meta = [_reflect_tool(t) for t in _SESSION_TOOLS[]]
        return (type = :tools, tools = tool_meta)
    elseif msg_type == :shutdown
        _SHUTTING_DOWN[] = true
        _RUNNING[] = false
        return (type = :ok, message = "shutting down")
    elseif msg_type == :restart
        # Save metadata before cleanup
        old_name = string(get(request, :name, "julia"))
        old_session_id = _SESSION_ID[]
        old_project = dirname(Base.active_project())

        # Signal the message-loop task's `finally` block to skip _cleanup().
        # We need the ZMQ sockets to stay open for ~0.3 s so the :ok reply
        # above actually reaches the client before we tear down the process.
        _RESTARTING[] = true
        _RUNNING[] = false

        @async begin
            try
                sleep(0.3)  # Let ZMQ reply flush through IPC buffer
                _RESTARTING[] = false
                _cleanup()  # Close sockets, remove metadata files
                _exec_restart(old_name, old_session_id, old_project)
            catch e
                _RESTARTING[] = false
                @error "Restart failed" exception = (e, catch_backtrace())
                exit(1)
            end
        end

        return (type = :ok, message = "restarting via exec")
    # ── Debug Protocol ──────────────────────────────────────────────────────
    elseif msg_type == :debug_status
        paused = _DEBUG_PAUSED[]
        if paused !== nothing
            return (type = :debug_status, is_paused = true, paused...)
        else
            return (type = :debug_status, is_paused = false)
        end

    elseif msg_type == :debug_eval
        eval_ch = _DEBUG_EVAL_CH[]
        eval_ch === nothing &&
            return (type = :error, message = "Not paused at a breakpoint")
        code = string(get(request, :code, ""))
        result_ch = Channel{Any}(1)
        put!(eval_ch, code => result_ch)
        result = take!(result_ch)
        # Publish so TUI can show agent evals in console
        src = get(request, :source, :agent)
        _publish_stream("debug_eval", _serialize_result((source = src, code = code, result = result)))
        return (type = :debug_eval_result, result = result)

    elseif msg_type == :debug_continue
        resume_ch = _DEBUG_RESUME_CH[]
        resume_ch === nothing &&
            return (type = :error, message = "Not paused at a breakpoint")
        put!(resume_ch, :continue)
        return (type = :ok, message = "Execution resumed")

    elseif msg_type == :get_job_result
        eid = string(get(request, :eval_id, ""))
        cached = lock(_COMPLETED_RESULTS_LOCK) do
            get(_COMPLETED_RESULTS, eid, nothing)
        end
        if cached !== nothing
            return (type = :job_result, eval_id = eid, data = String(cached))
        else
            return (type = :not_found, eval_id = eid)
        end

    elseif msg_type == :cancel_job
        eid = string(get(request, :eval_id, ""))
        if !isempty(eid)
            cancel_job!(eid)
            return (type = :ok, message = "Job $eid marked for cancellation")
        end
        return (type = :error, message = "Missing eval_id")

    else
        return (type = :error, message = "unknown request type: $msg_type")
    end
end

# ── Multipart framing (ZMQ.jl 1.5 has no multipart helper) ────────────────────
# A DEALER→ROUTER message arrives as [identity, corr_id, payload]; the reply is
# sent with the same identity envelope and corr_id echoed back. recv the first
# frame (bounded by rcvtimeo), then the rest atomically while `rcvmore`.
function _recv_multipart(sock::ZMQ.Socket)
    parts = Vector{UInt8}[_zmq_recv(sock)]   # may throw ZMQ.TimeoutError
    while sock.rcvmore
        push!(parts, _zmq_recv(sock))
    end
    return parts
end

function _send_multipart(sock::ZMQ.Socket, parts::Vector{Vector{UInt8}})
    n = length(parts)
    for (i, p) in enumerate(parts)
        send(sock, p; more = (i < n))
    end
end

# Drain whatever replies are ready onto the ROUTER (owner-only socket access).
function _drain_gate_outbox!(socket::ZMQ.Socket)
    while isready(_GATE_OUTBOX)
        (identity, corr_id, reply) = take!(_GATE_OUTBOX)
        try
            _send_multipart(socket, Vector{UInt8}[identity, corr_id, reply])
        catch
            # ROUTER drops replies to vanished peers (timed-out/gone clients) —
            # expected; nothing else can be done with this reply.
            _RUNNING[] || break
        end
    end
end

# Run one request to completion on its own task and hand the reply to the outbox.
# Never touches the socket. invokelatest so handle_message (and the session tools
# it calls) runs in the latest world age — required for tools whose types were
# defined after the gate loop started.
function _serve_request(identity::Vector{UInt8}, corr_id::Vector{UInt8}, request)
    reply = try
        Base.invokelatest(handle_message, request)
    catch e
        (type = :error, message = sprint(showerror, e))
    end
    io = IOBuffer()
    serialize(io, reply)
    put!(_GATE_OUTBOX, (identity, corr_id, take!(io)))
    Threads.atomic_sub!(_GATE_INFLIGHT, 1)
    return nothing
end

function message_loop(socket::ZMQ.Socket)
    while _RUNNING[]
        try
            # 1. flush any ready worker replies first (owner-only socket access)
            _drain_gate_outbox!(socket)

            # 2. backpressure: at the worker cap, let the outbox drain before
            #    accepting more. Pending requests stay queued in the ROUTER.
            if _GATE_INFLIGHT[] >= _GATE_MAX_WORKERS[]
                sleep(0.005)
                continue
            end

            # 3. recv one request — [identity, corr_id, payload] (bounded by rcvtimeo)
            parts = _recv_multipart(socket)
            length(parts) >= 3 || continue
            identity = parts[1]
            corr_id = parts[2]
            payload = parts[end]

            request = try
                deserialize(IOBuffer(payload))
            catch
                io = IOBuffer()
                serialize(io, (type = :error, message = "malformed request"))
                put!(_GATE_OUTBOX, (identity, corr_id, take!(io)))
                continue
            end

            # 4. hand off to a worker — DO NOT run inline (a slow sync eval or a
            #    blocked debug_eval must not stall intake / pings).
            Threads.atomic_add!(_GATE_INFLIGHT, 1)
            Threads.@spawn _serve_request(identity, corr_id, request)
        catch e
            if !_RUNNING[]
                break  # Clean shutdown
            end
            # Timeout is expected — just loop to check _RUNNING and drain outbox.
            if e isa ZMQ.TimeoutError
                continue
            end
            if e isa ZMQ.StateError || e isa EOFError
                break
            end
            @debug "Gate message loop error" exception = e
        end
    end

    # Final bounded drain so in-flight replies (notably the :shutdown / :restart
    # :ok that the client is still waiting on) get flushed before teardown. The
    # :restart handler then sleeps 0.3s before execvp, so the reply lands.
    deadline = time() + 1.0
    while (isready(_GATE_OUTBOX) || _GATE_INFLIGHT[] > 0) && time() < deadline
        try
            _drain_gate_outbox!(socket)
        catch
            break
        end
        sleep(0.005)
    end
end

# ── Public API ────────────────────────────────────────────────────────────────

"""
    serve(; session_id=nothing, force=false, tools=GateTool[], namespace="", allow_mirror=true, allow_restart=true)

Start the eval gate. Binds a ZMQ REP socket on an IPC endpoint and
listens for eval requests from the Kaimon TUI server.

Non-blocking — returns immediately. The gate runs in a background task.
The session name is derived automatically from the active project path.

Skips registration for non-interactive processes (no TTY). Use `force=true`
to override the TTY check.

# Arguments
- `session_id::Union{String,Nothing}`: Reuse a session ID (e.g. after exec restart)
- `force::Bool`: Skip the TTY gate (for non-interactive processes that want a gate)
- `tools::Vector{GateTool}`: Session-scoped tools to expose via MCP
- `namespace::String`: Stable prefix for tool names. Auto-derived from project basename
  if empty. Use explicit namespaces for multi-instance workflows:
  ```julia
  serve(tools=tools, namespace="todo_dev")    # branch A
  serve(tools=tools, namespace="todo_main")   # branch B
  ```
- `mode::Symbol`: Transport mode — `:ipc` (default, local Unix socket) or
  `:tcp` (network-accessible, for remote debugging).
- `host::String`: Bind address for TCP mode (default `"127.0.0.1"`, localhost only).
  Use `"0.0.0.0"` to accept connections from remote machines (no auth — use with care).
- `port::Int`: Port for TCP mode (default `0` = ephemeral, ZMQ picks a free port).
  Both REP and PUB sockets support this. Use a fixed port for predictable endpoints.

# Example
```julia
using KaimonGate
KaimonGate.serve()

# With custom tools
KaimonGate.serve(tools=[GateTool("send_key", my_key_handler)])

# TCP mode for remote debugging (e.g. from a model server)
KaimonGate.serve(mode=:tcp, port=9876, force=true)
```

# Environment variables
These override the keyword defaults when set:
- `KAIMON_GATE_MODE`: `"ipc"` or `"tcp"` (default: `"ipc"`)
- `KAIMON_GATE_HOST`: Bind address for TCP (default: `"127.0.0.1"`)
- `KAIMON_GATE_PORT`: Port for TCP (default: `"0"` = ephemeral)
- `KAIMON_GATE_STREAM_PORT`: PUB stream port for TCP (default: `"0"` = ephemeral).
  Use a fixed port when tunneling so the client can connect to a known port.
"""
function serve(;
    session_id::Union{String,Nothing} = nothing,
    force::Union{Bool,Nothing} = nothing,
    tools::Vector{GateTool} = GateTool[],
    namespace::String = "",
    allow_mirror::Bool = true,
    allow_restart::Bool = true,
    spawned_by::String = "user",
    on_shutdown::Any = nothing,
    infiltrator::Bool = true,
    mode::Union{Symbol,Nothing} = nothing,
    host::Union{String,Nothing} = nothing,
    port::Union{Int,Nothing} = nothing,
    stream_port::Union{Int,Nothing} = nothing,
    curve::Union{Bool,Nothing} = nothing,
    server_secret::Union{String,Nothing} = nothing,
    allow_any::Union{Bool,Nothing} = nothing,
    allowed_clients::Union{Vector{String},Nothing} = nothing,
)
    # Resolve defaults: explicit kwargs > env vars > kaimon.toml [gate] > defaults
    toml = _load_gate_config()

    if mode === nothing
        env_mode = get(ENV, "KAIMON_GATE_MODE", "")
        has_env_port = haskey(ENV, "KAIMON_GATE_PORT") || haskey(ENV, "KAIMON_GATE_STREAM_PORT")
        toml_mode = get(toml, "mode", "")
        has_toml_port = haskey(toml, "port") || haskey(toml, "stream_port")
        mode = if !isempty(env_mode)
            Symbol(env_mode)
        elseif has_env_port
            :tcp
        elseif toml_mode == "tcp" || has_toml_port
            :tcp
        else
            :ipc
        end
    end
    if host === nothing
        env_host = get(ENV, "KAIMON_GATE_HOST", "")
        host = !isempty(env_host) ? env_host :
            get(toml, "host", "127.0.0.1")
    end
    if port === nothing
        env_port = get(ENV, "KAIMON_GATE_PORT", "")
        port = !isempty(env_port) ? parse(Int, env_port) :
            Int(get(toml, "port", 0))
    end
    if stream_port === nothing
        env_sp = get(ENV, "KAIMON_GATE_STREAM_PORT", "")
        stream_port = !isempty(env_sp) ? parse(Int, env_sp) :
            Int(get(toml, "stream_port", 0))
    end
    if force === nothing
        force = Bool(get(toml, "force", false))
    end
    # CURVE (opt-in TCP encryption + auth). server_secret defaults to nothing here
    # and is resolved (env > persisted keypair) inside _resolve_server_keypair.
    _truthy(s) = lowercase(strip(s)) in ("1", "true", "yes", "on")
    if curve === nothing
        env_curve = get(ENV, "KAIMON_GATE_CURVE", "")
        curve = !isempty(env_curve) ? _truthy(env_curve) : Bool(get(toml, "curve", false))
    end
    if allow_any === nothing
        env_aa = get(ENV, "KAIMON_GATE_CURVE_ALLOW_ANY", "")
        allow_any = !isempty(env_aa) ? _truthy(env_aa) : Bool(get(toml, "curve_allow_any", false))
    end
    if allowed_clients === nothing
        env_allow = get(ENV, "KAIMON_GATE_CURVE_ALLOW", "")
        allowed_clients = isempty(env_allow) ? String[] :
            String[String(strip(x)) for x in split(env_allow, ",") if !isempty(strip(x))]
    end

    mode in (:ipc, :tcp) || throw(ArgumentError("mode must be :ipc or :tcp, got :$mode"))
    _serve(;
        name = basename(dirname(something(Base.active_project(), "julia"))),
        session_id,
        force,
        tools,
        namespace,
        allow_mirror,
        allow_restart,
        spawned_by,
        on_shutdown,
        infiltrator,
        mode,
        host,
        port,
        stream_port,
        curve,
        server_secret,
        allow_any,
        allowed_clients,
    )
end

function _serve(;
    name::String,
    session_id::Union{String,Nothing},
    force::Bool = false,
    tools::Vector{GateTool} = GateTool[],
    namespace::String = "",
    allow_mirror::Bool = true,
    allow_restart::Bool = true,
    spawned_by::String = "user",
    on_shutdown::Any = nothing,
    infiltrator::Bool = true,
    mode::Symbol = :ipc,
    host::String = "127.0.0.1",
    port::Int = 9876,
    stream_port::Int = 0,
    curve::Bool = false,
    server_secret::Union{String,Nothing} = nothing,
    allow_any::Bool = false,
    allowed_clients::Vector{String} = String[],
)
    # Capture original argv for restart replay (once, on first call)
    _capture_original_argv()

    # Interactive gate: skip scripts, -e commands, precompilation, workers, etc.
    # TCP mode always forces — it's designed for non-interactive processes (model servers).
    if !force && mode != :tcp && !isinteractive()
        @debug "Skipping gate: non-interactive session"
        return nothing
    end

    # Restart gate: if KAIMON_RESTART_SESSION is set the current process was
    # launched by _exec_restart.  Any serve() call — whether from startup.jl,
    # app code (force=true), or our injected -e fallback — picks up the
    # session_id so the TUI can reconnect to the same session.
    if session_id === nothing
        restart_sid = get(ENV, "KAIMON_RESTART_SESSION", "")
        if !isempty(restart_sid)
            session_id = pop!(ENV, "KAIMON_RESTART_SESSION")
        end
    end

    # Auto-derive namespace from project basename if not specified
    if isempty(namespace)
        project = something(Base.active_project(), "julia")
        namespace = lowercase(replace(basename(dirname(project)), r"[^a-zA-Z0-9]" => "_"))
    end

    if _RUNNING[]
        if session_id !== nothing && session_id != _SESSION_ID[]
            # Restart with a specific session_id (e.g. _exec_restart) —
            # stop the gate started by startup.jl and continue below
            # to rebind with the requested session_id.
            old_task = _GATE_TASK[]
            _cleanup()
            # Wait for old message loop task to finish so its `finally`
            # block doesn't race with the new gate we're about to create.
            if old_task !== nothing && !istaskdone(old_task)
                try
                    wait(old_task)
                catch
                end
            end
        elseif !isempty(tools)
            # Gate already running — replace tools; the TUI health checker
            # picks up changes via pong and sends tools/list_changed.
            _SESSION_TOOLS[] = tools
            _SESSION_NAMESPACE[] = namespace
            if !allow_mirror
                _ALLOW_MIRROR[] = false
                _MIRROR_REPL[] = false
            end
            @info "Registered $(length(tools)) tool(s) on running gate (session=$(_SESSION_ID[]))"
            return _SESSION_ID[]
        else
            # Same session already running (e.g. startup.jl created the gate,
            # then our injected -e fallback fires).  Update mutable options so
            # allow_mirror / allow_restart from the original session are
            # restored; namespace is auto-derived so it will match already.
            _ALLOW_MIRROR[] = allow_mirror
            _ALLOW_RESTART[] = allow_restart
            return _SESSION_ID[]
        end
    end

    # Store session tools and namespace
    _SESSION_TOOLS[] = tools
    _SESSION_NAMESPACE[] = namespace
    _ALLOW_MIRROR[] = allow_mirror
    _ALLOW_RESTART[] = allow_restart
    _ON_SHUTDOWN[] = on_shutdown

    # Ensure socket directory exists
    sock_dir()  # ensure it exists (mkpath is inside)

    # Generate or reuse session ID
    sid = session_id !== nothing ? session_id : string(Base.UUID(rand(UInt128)))
    _SESSION_ID[] = sid
    _START_TIME[] = time()
    _MIRROR_REPL[] = if allow_mirror
        try
            _MIRROR_PREF_PROVIDER[]()
        catch
            false
        end
    else
        false
    end

    # Create ZMQ context and sockets. The request socket is a ROUTER (protocol
    # v2): a single client DEALER multiplexes concurrent requests onto it, demuxed
    # by correlation id. Replaces the old REP, which forced strict request/reply
    # alternation and drove per-request ephemeral REQ churn on the client.
    ctx = Context()
    socket = _zmq_socket(ctx, ROUTER)
    _GATE_CONTEXT[] = ctx
    _GATE_SOCKET[] = socket
    _MODE[] = mode

    # Set auth token for TCP mode.
    # Priority: KAIMON_GATE_TOKEN env var > host-provided token > none.
    # Standalone there's no host token, so the gate is open unless the env var is
    # set; full Kaimon injects a token derived from its security config via
    # set_auth_token_provider!.
    if mode == :tcp
        env_token = get(ENV, "KAIMON_GATE_TOKEN", "")
        if !isempty(env_token)
            _AUTH_TOKEN[] = env_token
        else
            # Host-provided token (Kaimon derives it from its security config).
            # Standalone the default provider returns "" — no auth, same as :lax.
            try
                tok = Base.invokelatest(_AUTH_TOKEN_PROVIDER[])
                isempty(tok) || (_AUTH_TOKEN[] = tok)
            catch
                # No provider/config — no auth (same as lax)
            end
        end
    end

    # Short receive timeout so the owner loop cycles back to drain _GATE_OUTBOX
    # (worker replies) and re-check _RUNNING promptly.
    # linger=0: close() returns immediately without blocking to drain.
    socket.rcvtimeo = 200
    socket.linger = 0

    # CURVE (opt-in, TCP only): make the REP socket a CURVE server. Unless
    # allow_any, also start a ZAP handler (one per context, covers PUB too) and
    # set ZAP_DOMAIN so libzmq enforces the client allow-list (fail-closed: an
    # empty authorized_clients list rejects everyone). Apply before bind.
    if mode == :tcp && curve
        spub, ssec = _resolve_server_keypair(server_secret)
        _CURVE_SERVER_SECRET[] = ssec
        _CURVE_SERVER_PUBLIC[] = spub
        _CURVE_ENABLED[] = true
        _CURVE_ALLOW_ANY[] = allow_any
        for ck in allowed_clients
            isempty(ck) || authorize_client!(ck)
        end
        allow_any || _start_zap_handler!(ctx; allow_any = false)
        make_curve_server!(socket, ssec)
        allow_any || _setsockopt_str(socket, _ZMQ_ZAP_DOMAIN, _ZAP_DOMAIN)
    end

    # Bind endpoint — IPC (local socket file) or TCP (network port)
    # TCP mode supports port=0 for ephemeral port assignment (ZMQ picks a free port).
    if mode == :tcp
        bind(socket, "tcp://$(host):$(port)")
        endpoint = rstrip(ZMQ._get_last_endpoint(socket), '\0')
        # Store resolved TCP settings for restart replay
        _TCP_HOST[] = host
        m = match(r":(\d+)$", endpoint)
        _TCP_PORT[] = m !== nothing ? parse(Int, m.captures[1]) : port
    else
        sock_path = joinpath(sock_dir(),"$(sid).sock")
        endpoint = "ipc://$(sock_path)"
        bind(socket, endpoint)
    end

    # Create XPUB socket for streaming stdout/stderr to TUI. XPUB is wire-
    # compatible with SUB clients but also delivers subscription events, which the
    # broadcaster turns into per-topic presence (see _stream_broadcaster).
    # sndhwm=0: unlimited send buffer — never drop messages under load.
    # linger=0: close() returns immediately.
    # rcvtimeo=0: non-blocking subscription recv (the owner polls events first).
    pub_socket = _zmq_socket(ctx, XPUB)
    pub_socket.sndhwm = 0
    pub_socket.linger = 0
    pub_socket.rcvtimeo = 0
    # XPUB_VERBOSER: deliver EVERY subscribe/unsubscribe (not just 0->1/1->0) so
    # we can count subscribers per topic.
    _setsockopt_int(pub_socket, _ZMQ_XPUB_VERBOSER, 1)
    # TCP keepalive: detect dead viewers so libzmq emits their unsubscribe and the
    # count self-corrects on ungraceful disconnects (IPC detects peer-close already).
    if mode == :tcp
        _setsockopt_int(pub_socket, _ZMQ_TCP_KEEPALIVE, 1)
        _setsockopt_int(pub_socket, _ZMQ_TCP_KEEPALIVE_IDLE, 30)
        _setsockopt_int(pub_socket, _ZMQ_TCP_KEEPALIVE_INTVL, 5)
        _setsockopt_int(pub_socket, _ZMQ_TCP_KEEPALIVE_CNT, 3)
    end
    # CURVE: same server treatment as the REP socket (ZAP handler already running).
    if mode == :tcp && curve
        make_curve_server!(pub_socket, _CURVE_SERVER_SECRET[])
        _CURVE_ALLOW_ANY[] || _setsockopt_str(pub_socket, _ZMQ_ZAP_DOMAIN, _ZAP_DOMAIN)
    end
    if mode == :tcp
        bind(pub_socket, "tcp://$(host):$(stream_port)")
        stream_endpoint = rstrip(ZMQ._get_last_endpoint(pub_socket), '\0')
        m = match(r":(\d+)$", stream_endpoint)
        _TCP_STREAM_PORT[] = m !== nothing ? parse(Int, m.captures[1]) : stream_port
    else
        stream_endpoint = "ipc://$(joinpath(sock_dir(),"$(sid)-stream.sock"))"
        bind(pub_socket, stream_endpoint)
    end
    _STREAM_SOCKET[] = pub_socket
    _STREAM_ENDPOINT[] = stream_endpoint

    # Write metadata file for session discovery (IPC only — TCP sessions
    # are connected manually via connect_tcp! and don't use file-based discovery)
    if mode != :tcp
        write_metadata(sid, name, endpoint, stream_endpoint; spawned_by, mode)
    end

    # Register cleanup
    atexit(() -> stop())

    # Start message loop on an interactive thread so it stays scheduled even
    # when the main thread is busy executing REPL code.
    # Async handlers (eval_async, tool_call_async) use Threads.@spawn to run
    # on the default thread pool, keeping this interactive thread free to
    # answer pings during CPU-intensive operations.
    _RUNNING[] = true
    # Broadcaster owns the XPUB stream socket (send + subscription recv). Runs on
    # :interactive so it stays scheduled alongside the message loop.
    _STREAM_TASK[] = Threads.@spawn :interactive begin
        try
            _stream_broadcaster(pub_socket)
        catch e
            @debug "Stream broadcaster exited" exception = e
        end
    end
    local this_task
    this_task = _GATE_TASK[] = Threads.@spawn :interactive begin
        try
            message_loop(socket)
        catch e
            @debug "Gate task exited" exception = e
        finally
            if _SHUTTING_DOWN[]
                # Remote shutdown: run optional cleanup hook, then exit
                _SHUTTING_DOWN[] = false
                hook = _ON_SHUTDOWN[]
                if hook !== nothing
                    try
                        ch = Channel{Nothing}(1)
                        @async begin
                            try
                                Base.invokelatest(hook)
                            catch e
                                @debug "on_shutdown hook error" exception = e
                            finally
                                put!(ch, nothing)
                            end
                        end
                        # Wait up to 5s for the hook to complete
                        timer = Timer(5.0)
                        @async begin
                            wait(timer)
                            isready(ch) || put!(ch, nothing)
                        end
                        take!(ch)
                        close(timer)
                    catch
                    end
                end
                _cleanup()
                exit(0)
            end
            # Otherwise don't call _cleanup() here — stop() owns cleanup
            # via atexit. With Threads.@spawn :interactive, this finally
            # block can race with stop() during Julia shutdown, causing
            # double-cleanup of ZMQ resources and intermittent segfaults.
        end
    end

    _start_revise_watcher()

    # Install Infiltrator hook if available — makes @infiltrate route through
    # the gate's breakpoint protocol instead of opening an interactive prompt.
    if infiltrator
        try
            _install_infiltrator_hook!()
        catch
            # Infiltrator not loaded yet — will be picked up by package callback below.
        end
        # Register a package-load callback so the hook installs as soon as Infiltrator
        # gets loaded (e.g. via `using GateToolTest` from the REPL).
        push!(Base.package_callbacks, function (pkgid)
            _RUNNING[] || return
            _INFILTRATOR_HOOKED[] && return
            _INFILTRATOR_DISABLED[] && return
            pkgid.name == "Infiltrator" || return
            try
                _install_infiltrator_hook!()
            catch
            end
        end)
    end

    # Override Profile peek report to write to a file instead of stderr.
    # When SIGINFO/SIGUSR1 fires, the C runtime prints a small message to
    # stderr, but the bulk profile output goes through this Julia function.
    # Writing to a file avoids filling the PTY buffer and deadlocking.
    _install_peek_report_override(sid)

    emoticon = try
        _PERSONALITY_PROVIDER[]()
    catch
        "⚡"
    end
    print("  $emoticon ")
    printstyled("Kaimon gate "; color = :green, bold = true)
    printstyled("connected"; color = :green)
    printstyled(" ($name)\n"; color = :light_black)
    let (kg_ver, kg_dir) = _build_info()
        printstyled("  KaimonGate v$kg_ver"; color = :light_black)
        kg_dir === nothing || printstyled(" — $kg_dir"; color = :light_black)
        # Under the full Kaimon CLI, the host injects its own version via the
        # provider hook. Surface it only when it differs from KaimonGate's own
        # (standalone they're the same, so nothing extra is shown).
        host_ver = try
            string(Base.invokelatest(_VERSION_PROVIDER[]))
        catch
            kg_ver
        end
        host_ver == kg_ver || printstyled(" (Kaimon v$host_ver)"; color = :light_black)
        print("\n")
    end
    if mode == :tcp
        printstyled("  TCP mode: "; color = :light_black)
        printstyled("$endpoint"; color = :cyan)
        printstyled(" (PUB: $stream_endpoint)\n"; color = :light_black)
        if !isempty(_AUTH_TOKEN[])
            printstyled("  Auth token: "; color = :light_black)
            printstyled("$(_AUTH_TOKEN[])\n"; color = :yellow)
        else
            printstyled("  Auth: "; color = :light_black)
            printstyled("none (lax mode)\n"; color = :yellow)
        end
        if _CURVE_ENABLED[]
            printstyled("  🔒 CURVE: "; color = :light_black)
            printstyled("on"; color = :green)
            printstyled(_CURVE_ALLOW_ANY[] ? " (pin-only)" : " (allow-list)";
                        color = :light_black)
            printstyled("\n  Server key: "; color = :light_black)
            printstyled("$(_CURVE_SERVER_PUBLIC[])\n"; color = :cyan)
        end
    end
    if _MIRROR_REPL[]
        printstyled("  host REPL mirroring enabled\n"; color = :light_black)
    end

    return sid
end

"""
    stop()

Stop the eval gate, clean up socket and metadata files.
"""
function stop()
    if !_RUNNING[]
        return
    end

    _RUNNING[] = false

    # Wait for task to finish
    task = _GATE_TASK[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end

    _cleanup()
    # Restore Infiltrator's normal prompt so @infiltrate works locally after
    # stop() instead of routing to the now-dead gate and hanging (#34).
    try
        uninstall_infiltrator_hook!()
    catch
    end
    printstyled("  Kaimon gate "; color = :yellow, bold = true)
    printstyled("disconnected\n"; color = :yellow)
end

"""
    restart()

Restart the Julia session, preserving the Kaimon session ID so the TUI
reconnects automatically.  Equivalent to what the agent's `manage_repl` tool
does, but callable directly from your REPL.

Uses `execvp` to replace the current process image — same PID, fresh Julia
state.  Your startup.jl runs again and `KaimonGate.serve()` reconnects with the
same session key.
"""
function restart()
    _RUNNING[] || error("Gate is not running")
    _ALLOW_RESTART[] || error("Restart is disabled for this session (allow_restart=false)")
    sid  = _SESSION_ID[]
    name = basename(dirname(something(Base.active_project(), "julia")))
    proj = dirname(something(Base.active_project(), "."))

    # Tell the message-loop's finally block to skip cleanup — we handle it here.
    _RESTARTING[] = true
    _RUNNING[] = false

    # Wait for the message-loop task to exit before tearing down sockets,
    # same as stop() does.
    task = _GATE_TASK[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end

    _RESTARTING[] = false
    _cleanup()
    _exec_restart(name, sid, proj)
end

function _cleanup()
    # Stop Revise watcher
    watcher = _REVISE_WATCHER_TASK[]
    if watcher !== nothing && !istaskdone(watcher)
        try
            # Wake the blocked wait so the task can exit
            if isdefined(Main, :Revise)
                Base.notify(Main.Revise.revision_event)
            end
        catch
        end
    end
    _REVISE_WATCHER_TASK[] = nothing

    # Stop the stream broadcaster and wait for it to release the XPUB BEFORE any
    # socket close below — a concurrent close+recv corrupts the heap (#51 class).
    # It exits once _RUNNING is false (set by every caller before _cleanup).
    stask = _STREAM_TASK[]
    if stask !== nothing && !istaskdone(stask)
        try; wait(stask); catch; end
    end
    _STREAM_TASK[] = nothing

    # IPC mode: don't explicitly close ZMQ sockets/context — GC finalizers handle
    # it. Explicit close during atexit was causing intermittent segfaults in LLVM's
    # JIT compiler on Julia 1.12.5.
    # TCP mode: must close explicitly so the port is released immediately. Without
    # this, restarting a TCP gate on the same port fails until GC runs. This is safe
    # because TCP stop is user-initiated (not atexit).
    if _MODE[] == :tcp
        for sock in (_GATE_SOCKET, _STREAM_SOCKET, _SERVICE_SOCKET, _ZAP_SOCKET)
            s = sock[]
            if s !== nothing
                try; close(s); catch; end
            end
        end
        ctx = _GATE_CONTEXT[]
        if ctx !== nothing
            try; close(ctx); catch; end
        end
    end
    # Drain any undelivered worker replies and reset the worker counter so a
    # restart (same process, fresh serve()) starts with an empty channel.
    while isready(_GATE_OUTBOX)
        try; take!(_GATE_OUTBOX); catch; break; end
    end
    Threads.atomic_xchg!(_GATE_INFLIGHT, 0)

    # Drain leftover stream publishes and clear presence state (the broadcaster
    # has already stopped above) so a same-process restart starts clean.
    while isready(_STREAM_OUTBOX)
        try; take!(_STREAM_OUTBOX); catch; break; end
    end
    lock(_STREAM_SUBS_LOCK) do
        empty!(_STREAM_SUBS)
        empty!(_ON_STREAM_SUBSCRIBE)
        empty!(_ON_STREAM_UNSUBSCRIBE)
    end

    _ZAP_SOCKET[] = nothing
    _ZAP_TASK[] = nothing
    _CURVE_ENABLED[] = false
    _CURVE_ALLOW_ANY[] = false
    _CURVE_SERVER_SECRET[] = ""
    _CURVE_SERVER_PUBLIC[] = ""
    _GATE_SOCKET[] = nothing
    _STREAM_SOCKET[] = nothing
    _STREAM_ENDPOINT[] = ""
    _AUTH_TOKEN[] = ""
    _PING_COUNT[] = 0
    _MSG_COUNT[] = 0
    _LAST_PING_TIME[] = 0.0
    _SERVICE_SOCKET[] = nothing
    _GATE_CONTEXT[] = nothing

    # Remove files
    cleanup_files(_SESSION_ID[])

    _GATE_TASK[] = nothing
    _RUNNING[] = false
    _RESTARTING[] = false
    _SHUTTING_DOWN[] = false
    _MIRROR_REPL[] = false
    _ALLOW_MIRROR[] = true
    _ALLOW_RESTART[] = true
    _SESSION_TOOLS[] = GateTool[]
    _SESSION_NAMESPACE[] = ""
    _MODE[] = :ipc
    _ON_SHUTDOWN[] = nothing
end

"""
    status()

Print current gate status.
"""
function status()
    if _RUNNING[]
        uptime = time() - _START_TIME[]
        mins = round(Int, uptime / 60)
        sock = _GATE_SOCKET[]
        rep_ep = sock !== nothing ? rstrip(ZMQ._get_last_endpoint(sock), '\0') : "unknown"
        println("Gate: running")
        println("  Session:   $(_SESSION_ID[])")
        println("  Namespace: $(_SESSION_NAMESPACE[])")
        println("  Uptime:    $(mins)m")
        println("  PID:       $(getpid())")
        println("  ROUTER:    $rep_ep")
        println("  PUB:       $(_STREAM_ENDPOINT[])")
        println("  Mirror:    $(_MIRROR_REPL[])")
        println("  Tools:     $(length(_SESSION_TOOLS[]))")
        println("  Pings:     $(_PING_COUNT[])$(  _LAST_PING_TIME[] > 0 ? " (last $(round(Int, time() - _LAST_PING_TIME[]))s ago)" : "")")
        println("  Messages:  $(_MSG_COUNT[])")
        if _MODE[] == :tcp
            auth = isempty(_AUTH_TOKEN[]) ? "none (lax)" : "token"
            println("  Auth:      $auth")
        end
    else
        println("Gate: not running")
    end
end

"""
    KaimonGate.progress(message::String)

Send a progress update from a long-running GateTool handler. The message is
streamed to the MCP client as an SSE progress notification.

Only works when called from within a GateTool handler invoked via the async
path. No-op otherwise.
"""
# Track last stderr output length for \r overwrite
const _STDERR_LAST_LEN = Ref{Int}(0)
const _STDERR_LAST_KIND = Ref{Symbol}(:none)  # :progress, :stash, :none

function _stderr_overwrite!(line::String, kind::Symbol)
    # If same kind as last output, overwrite with \r; otherwise newline first
    if _STDERR_LAST_KIND[] == kind && _STDERR_LAST_LEN[] > 0
        print(stderr, "\r")
        # Clear previous line if new one is shorter
        if length(line) < _STDERR_LAST_LEN[]
            print(stderr, " " ^ _STDERR_LAST_LEN[])
            print(stderr, "\r")
        end
    elseif _STDERR_LAST_KIND[] != :none && _STDERR_LAST_LEN[] > 0
        println(stderr)  # newline to preserve previous different-kind output
    end
    print(stderr, line)
    flush(stderr)
    _STDERR_LAST_LEN[] = length(line)
    _STDERR_LAST_KIND[] = kind
end

"""Finish the current stderr overwrite line (newline + reset)."""
function _stderr_finish!()
    if _STDERR_LAST_LEN[] > 0
        println(stderr)
        _STDERR_LAST_LEN[] = 0
        _STDERR_LAST_KIND[] = :none
    end
end

"""
    progress(message::String)

Stream a real-time progress update to the agent from inside a running eval or
`GateTool` handler. The message is delivered as an MCP `notifications/progress`
event (and echoed in the host REPL), which also keeps long-running HTTP requests
from timing out.

Only has an effect while running inside a gate request (it keys off the current
request via task-local storage); outside one it's a no-op.

```julia
function analyze(passes::Int)
    for i in 1:passes
        KaimonGate.progress("pass \$i/\$passes complete")
        # ...
    end
end
```
"""
function progress(message::String)
    rid = get(task_local_storage(), :gate_request_id, nothing)
    rid === nothing && return
    _publish_stream("tool_progress", message; request_id = string(rid))
    try
        ts = Dates.format(Dates.now(), "HH:MM:SS")
        line = "[$ts] ⏳ $message"
        _stderr_overwrite!(line, :progress)
    catch
    end
end

# ── Job Safehouse ─────────────────────────────────────────────────────────────
# Allows long-running evals/tools to stash intermediate values that can be
# inspected while the job is still running (like Infiltrator's @exfiltrate).

const _JOB_SAFEHOUSE = Dict{String, Dict{String, Any}}()
const _JOB_SAFEHOUSE_LOCK = ReentrantLock()

# ── Cooperative Cancellation ─────────────────────────────────────────────────
# Set by the TUI when cancel_eval is called. User code checks via is_cancelled().

const _CANCELLED_JOBS = Set{String}()
const _CANCELLED_JOBS_LOCK = ReentrantLock()

# ── Completed Job Results Cache ──────────────────────────────────────────────
# Stores serialized results of completed evals so the TUI can retrieve them
# after a restart (when the original PUB/SUB delivery was missed).

const _COMPLETED_RESULTS = Dict{String, Vector{UInt8}}()  # eval_id → serialized result
const _COMPLETED_RESULTS_LOCK = ReentrantLock()
const _COMPLETED_RESULTS_MAX = 50  # keep last N results

"""
    cancel_job!(eval_id::String)

Mark a job as cancelled. Called from the TUI side (via PUB/SUB or direct).
"""
function cancel_job!(eval_id::String)
    lock(_CANCELLED_JOBS_LOCK) do
        push!(_CANCELLED_JOBS, eval_id)
    end
end

"""
    is_cancelled(; job_id::String="") -> Bool

Check if the current job has been cancelled. Call this in long-running loops
to support cooperative cancellation.

If called from within a GateTool handler or async eval, the job ID is
detected automatically. Otherwise, pass `job_id` explicitly.

# Example
```julia
for epoch in 1:1000
    KaimonGate.is_cancelled() && break
    loss = train_epoch!(model)
    KaimonGate.stash("epoch", epoch)
    KaimonGate.progress("Epoch \$epoch: loss=\$loss")
end
```
"""
function is_cancelled(; job_id::String="")
    if isempty(job_id)
        job_id = string(get(task_local_storage(), :gate_request_id, ""))
    end
    isempty(job_id) && return false
    lock(_CANCELLED_JOBS_LOCK) do
        job_id in _CANCELLED_JOBS
    end
end

"""
    stash(key::String, value; job_id::String="")

Stash a value in the current job's safehouse. If called from within a GateTool
handler or async eval, the job ID is detected automatically. Otherwise, pass
`job_id` explicitly.

Retrieve stashed values with `check_eval` or `inspect_job`.

# Example
```julia
for epoch in 1:100
    loss = train_epoch!(model)
    KaimonGate.stash("epoch", epoch)
    KaimonGate.stash("loss", loss)
    KaimonGate.stash("lr", get_lr(optimizer))
    KaimonGate.progress("Epoch \$epoch: loss=\$loss")
end
```
"""
function stash(key::String, value; job_id::String="")
    if isempty(job_id)
        job_id = string(get(task_local_storage(), :gate_request_id, ""))
    end
    isempty(job_id) && return
    lock(_JOB_SAFEHOUSE_LOCK) do
        if !haskey(_JOB_SAFEHOUSE, job_id)
            _JOB_SAFEHOUSE[job_id] = Dict{String, Any}()
        end
        _JOB_SAFEHOUSE[job_id][key] = value
    end
    # Publish stash update so TUI can collect it
    try
        repr_v = sprint(show, value; context=:limit => true)
        if length(repr_v) > 500
            repr_v = first(repr_v, 500) * "..."
        end
        _publish_stream("job_stash", "$key=$repr_v"; request_id = job_id)
    catch
    end
    # Echo to stderr — uses \r overwrite so rapid stash calls stay on one line
    try
        short_v = sprint(show, value; context=:limit => true)
        if length(short_v) > 40
            short_v = first(short_v, 40) * "…"
        end
        ts = Dates.format(Dates.now(), "HH:MM:SS")
        line = "[$ts] 📌 $key=$short_v"
        _stderr_overwrite!(line, :stash)
    catch
    end
    nothing
end

"""
    stash(pairs::Pair...; job_id::String="")

Stash multiple values at once.

# Example
```julia
KaimonGate.stash("epoch" => epoch, "loss" => loss, "accuracy" => acc)
```
"""
function stash(pairs::Pair{String}...; job_id::String="")
    if isempty(pairs)
        return
    end
    # Batch: stash each value individually (publishes + safehouse)
    for (k, v) in pairs
        if isempty(job_id)
            stash(k, v)
        else
            stash(k, v; job_id)
        end
    end
end

"""
    push_panel(key::String, value)

Push a state update to the extension's TUI panel. The value is delivered
via PUB/SUB and appears in the panel's `ctx._cache[:panel_state][key]`
on the next frame.

Use this from tool handlers or background tasks to stream data to the
panel without the panel needing to poll via `ctx.eval()`.

# Example
```julia
function my_tool_handler(args)
    result = do_work(args)
    KaimonGate.push_panel("result", result)
    KaimonGate.push_panel("status", "done")
    return "OK"
end
```
"""
function push_panel(key::String, value)
    _publish_stream("panel_push", (key = key, value = value))
end

"""
    push_panel(pairs::Pair{String}...)

Push multiple panel state updates at once.

# Example
```julia
KaimonGate.push_panel("greetings" => greetings, "rolls" => rolls)
```
"""
function push_panel(pairs::Pair{String}...)
    for (k, v) in pairs
        push_panel(k, v)
    end
end

"""
    get_stash(job_id::String) -> Dict{String, Any}

Retrieve all stashed values for a job. Returns empty Dict if none.
"""
function get_stash(job_id::String)
    lock(_JOB_SAFEHOUSE_LOCK) do
        for (k, v) in _JOB_SAFEHOUSE
            if startswith(k, job_id)
                return copy(v)
            end
        end
        return Dict{String, Any}()
    end
end

"""
    clear_stash(job_id::String)

Clear the safehouse for a job. Called automatically when check_eval retrieves
a completed job's result.
"""
function clear_stash(job_id::String)
    lock(_JOB_SAFEHOUSE_LOCK) do
        for k in collect(keys(_JOB_SAFEHOUSE))
            startswith(k, job_id) && delete!(_JOB_SAFEHOUSE, k)
        end
    end
end

# ── Service Client (reverse channel to Kaimon server) ─────────────────────────
# Extensions call KaimonGate.call_tool(name, args) to invoke any registered Kaimon
# MCP tool. This is the reverse of the existing gate protocol: instead of
# Kaimon calling into the gate, the gate calls back into Kaimon.

# Legacy ref: per-call sockets are used now (below), but cleanup still nils this.
const _SERVICE_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)

# Per-call REQ recv timeout (ms). Must exceed the worst case admission-wait +
# slowest-tool timeout (agent_run defaults to 600s and is caller-settable). Kept
# finite on purpose — an infinite timeout blocks forever if the server dies
# mid-recv (e.g. an /mcp reconnect); a finite one lets a dead server be noticed.
# A per-call socket can't wedge, so on timeout we just fail that one call cleanly.
const _SERVICE_RCV_TIMEOUT_MS = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_SERVICE_RCV_TIMEOUT_MS", "")), 660_000))

"""
    _service_request(request::NamedTuple) -> Any

Send a request to the Kaimon service endpoint and return the response value.

Each call uses its OWN short-lived REQ socket (create → connect → send → recv →
close). The server is a ROUTER, so concurrent `call_tool`s from one gate session
run in parallel — no shared socket, no lock — and a per-call socket can never
wedge: the strict REQ send/recv FSM starts fresh every call. Supersedes the old
single shared REQ + lock (+ reset-on-throw) design.
"""
function _service_request(request)
    sock_path = joinpath(sock_dir(), "kaimon-service.sock")
    ispath(sock_path) || error("Kaimon service endpoint not available. Is the Kaimon TUI running?")
    ctx = _GATE_CONTEXT[]
    ctx === nothing && error("Kaimon service endpoint not available (no ZMQ context).")

    sock = _zmq_socket(ctx, REQ)
    sock.rcvtimeo = _SERVICE_RCV_TIMEOUT_MS[]
    sock.sndtimeo = 5000   # 5s send timeout
    sock.linger = 0
    connect(sock, "ipc://$(sock_path)")
    try
        io = IOBuffer()
        serialize(io, request)
        send(sock, take!(io))
        raw = _zmq_recv(sock)
        response = deserialize(IOBuffer(raw))

        status = if hasproperty(response, :status)
            response.status
        elseif response isa Dict
            get(response, :status, :error)
        else
            :error
        end

        if status == :error
            msg = if hasproperty(response, :message)
                response.message
            elseif response isa Dict
                get(response, :message, "unknown error")
            else
                "unknown error"
            end
            error("Kaimon service error: $msg")
        end

        return response.value
    finally
        close(sock)   # fresh socket per call — nothing to reset/wedge
    end
end

"""
    KaimonGate.call_tool(tool_name::Symbol, args::Dict{String,Any}) -> Any

Call a Kaimon MCP tool from within a gate session. The request is sent over
a dedicated ZMQ REQ socket to the Kaimon server's service endpoint, which
looks up the tool in its registry and calls the handler.

This gives extensions access to all of Kaimon's registered tools — Qdrant
search, Ollama embeddings, code indexing, etc. — without bundling their
own clients.

# Example
```julia
# From a gate tool handler:
result = KaimonGate.call_tool(:qdrant_search_code, Dict{String,Any}(
    "query" => "function that handles HTTP routing",
    "limit" => "5",
))

# List collections
collections = KaimonGate.call_tool(:qdrant_list_collections, Dict{String,Any}())
```
"""
function call_tool(tool_name::Symbol, args::Dict{String,Any} = Dict{String,Any}())
    _service_request((type = :tool_call, tool_name = tool_name, args = args))
end

"""
    KaimonGate.list_tools() -> Vector{NamedTuple}

Discover all MCP tools registered on the Kaimon server.
Returns a vector of `(name, description, parameters)` tuples.

# Example
```julia
tools = KaimonGate.list_tools()
for t in tools
    println(t.name, " — ", first(split(t.description, '\\n')))
end
```
"""
function list_tools()
    _service_request((type = :list_tools,))
end

# ── kaimon.toml [gate] section support ─────────────────────────────────────────

"""
    _load_gate_config() -> Dict{String,Any}

Read the `[gate]` section from `kaimon.toml` in the active project root.
Returns an empty Dict if the file doesn't exist or has no `[gate]` section.
"""
function _load_gate_config()
    project = Base.active_project()
    project === nothing && return Dict{String,Any}()
    toml_path = joinpath(dirname(project), "kaimon.toml")
    if !isfile(toml_path)
        @debug "kaimon.toml not found" toml_path
        return Dict{String,Any}()
    end
    try
        data = TOML.parsefile(toml_path)
        gate = get(data, "gate", Dict{String,Any}())
        !isempty(gate) && @debug "Loaded kaimon.toml [gate]" gate
        return gate
    catch e
        @warn "Failed to parse kaimon.toml" toml_path exception=e
        return Dict{String,Any}()
    end
end

"""
    _auto_serve!()

Auto-start the gate if environment variables or kaimon.toml `[gate]` section
indicate TCP mode.

Invoked by the host package (Kaimon) from its `__init__`. A standalone
`using KaimonGate` session does **not** auto-start — call [`serve`](@ref)
explicitly (it still reads env vars / `kaimon.toml` for its settings).

Configuration priority: env vars > kaimon.toml > defaults.
"""
function _auto_serve!()
    _RUNNING[] && return  # already running

    # Merge kaimon.toml [gate] config with env var overrides
    toml = _load_gate_config()
    toml_mode = get(toml, "mode", "")
    toml_port = get(toml, "port", nothing)
    toml_stream_port = get(toml, "stream_port", nothing)
    toml_host = get(toml, "host", "")
    toml_force = Bool(get(toml, "force", false))

    env_mode = get(ENV, "KAIMON_GATE_MODE", "")
    has_env_port = haskey(ENV, "KAIMON_GATE_PORT") || haskey(ENV, "KAIMON_GATE_STREAM_PORT")

    # Determine effective mode
    mode = if !isempty(env_mode)
        Symbol(env_mode)
    elseif has_env_port
        :tcp
    elseif toml_mode == "tcp"
        :tcp
    elseif toml_port !== nothing || toml_stream_port !== nothing
        :tcp
    else
        return  # no auto-start configured
    end

    mode == :tcp || return  # only auto-start for TCP mode

    # Resolve parameters (env > toml > defaults)
    host = let h = get(ENV, "KAIMON_GATE_HOST", "")
        !isempty(h) ? h : !isempty(toml_host) ? toml_host : "127.0.0.1"
    end
    port = let p = get(ENV, "KAIMON_GATE_PORT", "")
        !isempty(p) ? parse(Int, p) : toml_port !== nothing ? Int(toml_port) : 0
    end
    stream_port = let sp = get(ENV, "KAIMON_GATE_STREAM_PORT", "")
        !isempty(sp) ? parse(Int, sp) : toml_stream_port !== nothing ? Int(toml_stream_port) : 0
    end
    force = toml_force || has_env_port || !isempty(env_mode)

    try
        serve(; mode, host, port, stream_port, force)
    catch e
        @warn "Gate auto-start failed" exception=e
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Gate — Thin eval gate for the user's REPL
#
# Runs inside the user's Julia session. Binds a ZMQ REP socket on an IPC
# endpoint so the persistent TUI server can send eval requests without living
# inside this process. Dependencies: ZMQ.jl + Serialization (stdlib).
# ═══════════════════════════════════════════════════════════════════════════════

module Gate

using ZMQ
using REPL
using Serialization
using Dates

# ── Constants ─────────────────────────────────────────────────────────────────

const _GATE_CACHE_DIR = let
    d = get(ENV, "XDG_CACHE_HOME") do
        Sys.iswindows() ?
        joinpath(
            get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local")),
            "Kaimon",
        ) : joinpath(homedir(), ".cache", "kaimon")
    end
    mkpath(d)
    d
end
const SOCK_DIR = joinpath(_GATE_CACHE_DIR, "sock")

"""
    _install_peek_report_override(session_id::String)

Override `Profile.peek_report[]` so that SIGINFO/SIGUSR1 writes the profile
report to `SOCK_DIR/<session_id>-backtrace.txt` instead of stderr. This avoids
deadlocking PTY-backed sessions where the kernel buffer is small.
"""
function _install_peek_report_override(session_id::String)
    try
        Profile = Base.require(Base.PkgId(Base.UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"), "Profile"))
        bt_path = joinpath(SOCK_DIR, "$(session_id)-backtrace.txt")
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
const _PUB_LOCK = ReentrantLock()

# Global state for the running gate
const _GATE_TASK = Ref{Union{Task,Nothing}}(nothing)
const _GATE_CONTEXT = Ref{Union{ZMQ.Context,Nothing}}(nothing)
const _GATE_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)
const _STREAM_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)  # PUB for streaming output
const _SESSION_ID = Ref{String}("")
const _RUNNING = Ref{Bool}(false)
const _START_TIME = Ref{Float64}(0.0)
const _MIRROR_REPL = Ref{Bool}(false)
const _ALLOW_MIRROR = Ref{Bool}(true)
const _REVISE_WATCHER_TASK = Ref{Union{Task,Nothing}}(nothing)
const _SESSION_NAMESPACE = Ref{String}("")
const _ALLOW_RESTART = Ref{Bool}(true)
const _ORIGINAL_ARGV = Ref{Vector{String}}(String[])
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
    Kaimon.Gate._breakpoint_hook(Base.@locals; file=@__FILE__, line=@__LINE__)
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

    take!(resume_ch)
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
    # Override start_prompt to route through our breakpoint system
    @eval function ($Infiltrator).start_prompt(
        mod, locals::Dict{Symbol,Any}, file, fileline, ex = nothing, bt = nothing;
        terminal = nothing, repl = nothing, nostack = false,
    )
        Gate._breakpoint_hook(locals; file = string(file), line = Int(fileline))
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

Gate.serve(tools=[GateTool("send_key", send_key)])
```
"""
struct GateTool
    name::String
    handler::Function
end

const _SESSION_TOOLS = Ref{Vector{GateTool}}(GateTool[])

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

    m = first(ms)

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

    # Mark args beyond nargs-1 (the required positional count) as optional
    # Julia's m.nargs includes the function itself, so required count = m.nargs - 1
    nreq = m.nargs - 1
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

        if has_repl
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
Tachikoma.app(model; tty_out = Gate.tty_path(), tty_size = Gate.tty_size())
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
# TIOCGPGRP: get foreground process group of a TTY
const _TIOCGPGRP =
    @static (Sys.isapple() || Sys.isbsd()) ? Culong(0x40047477) : Culong(0x540F)

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

function _publish_stream(channel::String, data; request_id::String = "")
    pub = _STREAM_SOCKET[]
    pub === nothing && return
    lock(_PUB_LOCK) do
        try
            io = IOBuffer()
            msg =
                isempty(request_id) ? (channel = channel, data = data) :
                (channel = channel, data = data, request_id = request_id)
            serialize(io, msg)
            send(pub, Message(take!(io)))
        catch e
            # Log failures for eval lifecycle messages — the caller hangs if these are lost
            if channel in ("eval_complete", "eval_error", "tool_complete", "tool_error")
                @error "Failed to publish $channel (request_id=$request_id)" exception = e
            end
        end
    end
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

    # Format value representation
    value_repr = ""
    if value !== nothing
        io = IOBuffer()
        try
            show(io, MIME("text/plain"), value)
            value_repr = String(take!(io))
        catch
            value_repr = repr(value)
        end
    end

    exception_str = if caught !== nothing
        io = IOBuffer()
        try
            showerror(io, caught, bt)
        catch
            showerror(io, caught)
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
    meta_path = joinpath(SOCK_DIR, "$(session_id).json")
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
        path = joinpath(SOCK_DIR, "$(session_id)$(ext)")
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
        # inject our own --project / -i / -e Gate.serve(...).
        julia_args = _base_julia_args()
        ns      = _SESSION_NAMESPACE[]
        mirror  = _ALLOW_MIRROR[]
        restart = _ALLOW_RESTART[]
        ns_kwarg      = isempty(ns) ? "" : ", namespace=$(repr(ns))"
        mirror_kwarg  = mirror  ? "" : ", allow_mirror=false"
        restart_kwarg = restart ? "" : ", allow_restart=false"
        # The injected -e code runs after startup.jl.  If startup.jl already
        # called Gate.serve() and picked up KAIMON_RESTART_SESSION, the gate
        # will already be running with the correct session_id; our serve() call
        # becomes a no-op that updates mutable options (mirror, restart flag).
        # If startup.jl didn't call serve, this creates the gate from scratch.
        serve_code = """
        try; using Revise; catch; end
        using Kaimon
        delete!(ENV, "KAIMON_RESTART_SESSION")
        Gate.serve(session_id=$(repr(session_id))$ns_kwarg$mirror_kwarg$restart_kwarg)
        """
        vcat(julia_args, ["--project=$project_path", "-i", "-e", serve_code])
    end

    # Restore terminal state and stdio fds before execvp. Tachikoma's
    # with_terminal() has the TUI in alt screen/raw mode and stdout/stderr
    # redirected to pipes. prepare_for_exec!() restores everything at the
    # OS fd level so the new process gets clean TTY IO.
    # Use dynamic lookup since the gate submodule doesn't depend on Tachikoma.
    try
        tachi = parentmodule(@__MODULE__)  # Kaimon
        if isdefined(tachi, :Tachikoma)
            T = getfield(tachi, :Tachikoma)
            if isdefined(T, :prepare_for_exec!)
                Base.invokelatest(getfield(T, :prepare_for_exec!))
            end
        end
    catch
    end

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
    msg_type = get(request, :type, :unknown)

    if msg_type == :eval
        code = get(request, :code, "")
        display_code = get(request, :display_code, code)
        result = gate_eval(code; display_code = display_code)
        return result
    elseif msg_type == :eval_async
        code = get(request, :code, "")
        display_code = get(request, :display_code, code)
        request_id = get(request, :request_id, "")
        # Run eval on a default-pool thread so the interactive message loop
        # stays responsive to pings during CPU-intensive evals.
        Threads.@spawn begin
            try
                result = gate_eval(code; display_code = display_code)
                try
                    _publish_stream("eval_complete", _serialize_result(result); request_id)
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
        return (
            type = :pong,
            pid = getpid(),
            uptime = time() - _START_TIME[],
            julia_version = string(VERSION),
            project_path = dirname(Base.active_project()),
            tools = [_reflect_tool(t) for t in _SESSION_TOOLS[]],
            namespace = _SESSION_NAMESPACE[],
            allow_restart = _ALLOW_RESTART[],
            allow_mirror = _ALLOW_MIRROR[],
            mirror_repl = _MIRROR_REPL[],
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

    else
        return (type = :error, message = "unknown request type: $msg_type")
    end
end

function message_loop(socket::ZMQ.Socket)
    while _RUNNING[]
        try
            # recv with timeout — throws TimeoutError on timeout
            raw = recv(socket)
            request = deserialize(IOBuffer(raw))

            # invokelatest so handle_message (and everything it calls) runs
            # in the latest world age — required for session tools whose
            # types/methods were defined after the gate loop started.
            response = Base.invokelatest(handle_message, request)

            # Serialize and send response
            io = IOBuffer()
            serialize(io, response)
            send(socket, Message(take!(io)))
        catch e
            if !_RUNNING[]
                break  # Clean shutdown
            end
            # Timeout is expected — just loop to check _RUNNING
            if e isa ZMQ.TimeoutError
                continue
            end
            if e isa ZMQ.StateError || e isa EOFError
                break
            end
            @debug "Gate message loop error" exception = e
            # Try to send error response
            try
                io = IOBuffer()
                serialize(io, (type = :error, message = sprint(showerror, e)))
                send(socket, Message(take!(io)))
            catch
                # If we can't even send the error, just continue
            end
        end
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
- `port::Int`: Port for TCP mode (default `9876`). In TCP mode, the PUB socket
  binds to `port + 1`.

# Example
```julia
using Kaimon
Gate.serve()

# With custom tools
Gate.serve(tools=[GateTool("send_key", my_key_handler)])

# TCP mode for remote debugging (e.g. from a model server)
Gate.serve(mode=:tcp, port=9876, force=true)
```
"""
function serve(;
    session_id::Union{String,Nothing} = nothing,
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
)
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
    # TCP mode: disable mirror and restart (they're IPC/REPL-specific features)
    _ALLOW_MIRROR[] = mode == :tcp ? false : allow_mirror
    _ALLOW_RESTART[] = mode == :tcp ? false : allow_restart
    _ON_SHUTDOWN[] = on_shutdown

    # Ensure socket directory exists
    mkpath(SOCK_DIR)

    # Generate or reuse session ID
    sid = session_id !== nothing ? session_id : string(Base.UUID(rand(UInt128)))
    _SESSION_ID[] = sid
    _START_TIME[] = time()
    _MIRROR_REPL[] = if allow_mirror
        try
            parentmodule(@__MODULE__).get_gate_mirror_repl_preference()
        catch
            false
        end
    else
        false
    end

    # Create ZMQ context and sockets
    ctx = Context()
    socket = Socket(ctx, REP)
    _GATE_CONTEXT[] = ctx
    _GATE_SOCKET[] = socket

    # 1s receive timeout so message loop can check _RUNNING periodically.
    # linger=0: close() returns immediately without blocking to drain.
    socket.rcvtimeo = 1000
    socket.linger = 0

    # Bind endpoint — IPC (local socket file) or TCP (network port)
    if mode == :tcp
        endpoint = "tcp://$(host):$(port)"
        bind(socket, endpoint)
        stream_endpoint = "tcp://$(host):$(port + 1)"
    else
        sock_path = joinpath(SOCK_DIR, "$(sid).sock")
        endpoint = "ipc://$(sock_path)"
        bind(socket, endpoint)
        stream_endpoint = "ipc://$(joinpath(SOCK_DIR, "$(sid)-stream.sock"))"
    end

    # Create PUB socket for streaming stdout/stderr to TUI.
    # sndhwm=0: unlimited send buffer — never drop messages under load.
    # linger=0: close() returns immediately.
    pub_socket = Socket(ctx, PUB)
    pub_socket.sndhwm = 0
    pub_socket.linger = 0
    bind(pub_socket, stream_endpoint)
    _STREAM_SOCKET[] = pub_socket

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
        parentmodule(@__MODULE__).load_personality()
    catch
        "⚡"
    end
    print("  $emoticon ")
    printstyled("Kaimon gate "; color = :green, bold = true)
    printstyled("connected"; color = :green)
    printstyled(" ($name)\n"; color = :light_black)
    if mode == :tcp
        printstyled("  TCP mode: "; color = :light_black)
        printstyled("$endpoint"; color = :cyan)
        printstyled(" (PUB: $stream_endpoint)\n"; color = :light_black)
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
    printstyled("  Kaimon gate "; color = :yellow, bold = true)
    printstyled("disconnected\n"; color = :yellow)
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

    # Don't explicitly close ZMQ sockets/context here — Julia's GC finalizers
    # handle it. Explicit close + finalize during atexit was causing intermittent
    # segfaults in LLVM's JIT compiler on Julia 1.12.5.
    # Just null the refs so our code doesn't use them after cleanup.
    _GATE_SOCKET[] = nothing
    _STREAM_SOCKET[] = nothing
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
        println("Gate: running")
        println("  Session: $(_SESSION_ID[])")
        println("  Uptime:  $(mins)m")
        println("  PID:     $(getpid())")
        println("  Mirror:  $(_MIRROR_REPL[])")
    else
        println("Gate: not running")
    end
end

"""
    Gate.progress(message::String)

Send a progress update from a long-running GateTool handler. The message is
streamed to the MCP client as an SSE progress notification.

Only works when called from within a GateTool handler invoked via the async
path. No-op otherwise.
"""
function progress(message::String)
    rid = get(task_local_storage(), :gate_request_id, nothing)
    rid === nothing && return
    _publish_stream("tool_progress", message; request_id = string(rid))
end

# ── Service Client (reverse channel to Kaimon server) ─────────────────────────
# Extensions call Gate.call_tool(name, args) to invoke any registered Kaimon
# MCP tool. This is the reverse of the existing gate protocol: instead of
# Kaimon calling into the gate, the gate calls back into Kaimon.

const _SERVICE_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)
const _SERVICE_LOCK = ReentrantLock()

"""
    _connect_service!() -> Bool

Connect to the Kaimon service endpoint. Returns true on success.
The service socket is a ZMQ REQ that connects to the Kaimon server's
REP socket at `ipc://~/.cache/kaimon/sock/kaimon-service.sock`.
"""
function _connect_service!()
    sock_path = joinpath(SOCK_DIR, "kaimon-service.sock")
    ispath(sock_path) || return false
    ctx = _GATE_CONTEXT[]
    ctx === nothing && return false
    sock = Socket(ctx, REQ)
    sock.rcvtimeo = 30000  # 30s timeout (some tools are slow)
    sock.sndtimeo = 5000   # 5s send timeout
    sock.linger = 0
    connect(sock, "ipc://$(sock_path)")
    _SERVICE_SOCKET[] = sock
    return true
end

"""
    _service_request(request::NamedTuple) -> Any

Send a request to the Kaimon service endpoint and return the response value.
Handles connection, serialization, error handling, and socket reset on failure.
"""
function _service_request(request)
    lock(_SERVICE_LOCK) do
        sock = _SERVICE_SOCKET[]
        if sock === nothing
            _connect_service!() || error("Kaimon service endpoint not available. Is the Kaimon TUI running?")
            sock = _SERVICE_SOCKET[]
        end

        io = IOBuffer()
        serialize(io, request)
        send(sock, Message(take!(io)))

        raw = recv(sock)
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
            # Reset socket on error — ZMQ REQ/REP is strict about send/recv alternation
            _SERVICE_SOCKET[] = nothing
            error("Kaimon service error: $msg")
        end

        return response.value
    end
end

"""
    Gate.call_tool(tool_name::Symbol, args::Dict{String,Any}) -> Any

Call a Kaimon MCP tool from within a gate session. The request is sent over
a dedicated ZMQ REQ socket to the Kaimon server's service endpoint, which
looks up the tool in its registry and calls the handler.

This gives extensions access to all of Kaimon's registered tools — Qdrant
search, Ollama embeddings, code indexing, etc. — without bundling their
own clients.

# Example
```julia
# From a gate tool handler:
result = Gate.call_tool(:qdrant_search_code, Dict{String,Any}(
    "query" => "function that handles HTTP routing",
    "limit" => "5",
))

# List collections
collections = Gate.call_tool(:qdrant_list_collections, Dict{String,Any}())
```
"""
function call_tool(tool_name::Symbol, args::Dict{String,Any} = Dict{String,Any}())
    _service_request((type = :tool_call, tool_name = tool_name, args = args))
end

"""
    Gate.list_tools() -> Vector{NamedTuple}

Discover all MCP tools registered on the Kaimon server.
Returns a vector of `(name, description, parameters)` tuples.

# Example
```julia
tools = Gate.list_tools()
for t in tools
    println(t.name, " — ", first(split(t.description, '\\n')))
end
```
"""
function list_tools()
    _service_request((type = :list_tools,))
end

end # module Gate

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

For closure-based handlers (e.g. inner `function foo(; kw::T...)` returned by a
factory), Julia stores the typed implementation as a field of the outer callable
struct. The inner method's positional signature is `(InnerType, kwarg_types...,
OuterClosureType)`, which lets us recover the annotated kwarg types that are
invisible via the standard `methods`/`kwarg_decl` path.

Falls back to an empty dict (callers treat missing entries as `Any`).
"""
function _extract_kwarg_types(f::Function)::Dict{Symbol,Type}
    fnames = fieldnames(typeof(f))
    isempty(fnames) && return Dict{Symbol,Type}()
    try
        inner = getfield(f, fnames[1])
        ms = methods(inner)
        isempty(ms) && return Dict{Symbol,Type}()
        params = only(ms).sig.parameters   # (InnerT, kw_types..., OuterT)
        length(params) < 3 && return Dict{Symbol,Type}()
        kw_types = params[2:end-1]
        kw_names = Base.kwarg_decl(methods(f)[1])
        length(kw_types) == length(kw_names) || return Dict{Symbol,Type}()
        Dict{Symbol,Type}(kw_names[i] => kw_types[i] for i in eachindex(kw_names))
    catch
        Dict{Symbol,Type}()
    end
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

    # Keyword arguments — try to recover types from the inner closure signature
    kw_names = try
        Base.kwarg_decl(m)
    catch
        Symbol[]
    end
    kw_types = _extract_kwarg_types(f)
    for kw in kw_names
        T = get(kw_types, kw, Any)
        push!(
            args_meta,
            Dict{String,Any}(
                "name" => string(kw),
                "type_meta" => _type_to_meta(T),
                "required" => !_is_optional_type(T),
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
    T <: Integer && value isa Number && return T(value)
    T <: AbstractFloat && value isa Number && return T(value)

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
    kwargs = Pair{Symbol,Any}[]
    for kw in kw_names
        kw_str = string(kw)
        if haskey(args, kw_str)
            push!(kwargs, kw => args[kw_str])
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
        catch
            # Non-critical — subscriber may not be connected
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
                # Echo to original stdout for REPL visibility.
                # Guard against broken pipes (e.g. when a Tachikoma pixel renderer
                # has taken over the terminal and its internal pipe has closed).
                if _MIRROR_REPL[]
                    try
                        write(orig_stdout, line)
                        flush(orig_stdout)
                    catch e
                        e isa Base.IOError && (_MIRROR_REPL[] = false)
                    end
                end
                # Publish to TUI stream
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
        close(stdout_write)
        close(stderr_write)
        wait(stdout_task)
        wait(stderr_task)
        close(stdout_read)
        close(stderr_read)
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
    stream_endpoint::String = "",
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
    _exec_restart(name, session_id, project_path)

Replace the current process with a fresh Julia via `execvp`. Same PID, same
terminal, fresh Julia state. The `-i` flag keeps the REPL interactive.
"""
function _exec_restart(name::String, session_id::String, project_path::String)
    # Tell startup.jl to skip serve() — the app or -e code will handle it.
    ENV["MCPREPL_RESTART_SESSION"] = session_id

    args = if _should_replay_argv()
        # Replay original argv exactly — the app code (e.g. GateToolTest.run()
        # or bin/kaimon) will call serve(force=true) itself; the env var carries
        # the session_id through. Don't inject -i: it would initialize a REPL
        # backend that conflicts with TUI terminal handling.
        copy(_ORIGINAL_ARGV[])
    else
        # Plain REPL session — construct minimal -e to re-establish the gate
        julia_args = Base.julia_cmd().exec
        ns = _SESSION_NAMESPACE[]
        mirror = _ALLOW_MIRROR[]
        ns_kwarg = isempty(ns) ? "" : ", namespace=$(repr(ns))"
        mirror_kwarg = mirror ? "" : ", allow_mirror=false"
        serve_code = """
        try; using Revise; catch; end
        using Kaimon
        delete!(ENV, "MCPREPL_RESTART_SESSION")
        Gate.serve(session_id=$(repr(session_id))$ns_kwarg$mirror_kwarg)
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
        # Run eval in background, return :accepted immediately
        @async begin
            try
                result = gate_eval(code; display_code = display_code)
                _publish_stream("eval_complete", _serialize_result(result); request_id)
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

        @async begin
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
        _RUNNING[] = false
        return (type = :ok, message = "shutting down")
    elseif msg_type == :restart
        # Save metadata before cleanup
        old_name = string(get(request, :name, "julia"))
        old_session_id = _SESSION_ID[]
        old_project = dirname(Base.active_project())

        _RUNNING[] = false

        @async begin
            try
                sleep(0.3)  # Let ZMQ reply go through
                _cleanup()  # Close sockets, remove metadata files
                _exec_restart(old_name, old_session_id, old_project)
            catch e
                @error "Restart failed" exception = (e, catch_backtrace())
                exit(1)
            end
        end

        return (type = :ok, message = "restarting via exec")
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

# Example
```julia
using Kaimon
Gate.serve()

# With custom tools
Gate.serve(tools=[GateTool("send_key", my_key_handler)])
```
"""
function serve(;
    session_id::Union{String,Nothing} = nothing,
    force::Bool = false,
    tools::Vector{GateTool} = GateTool[],
    namespace::String = "",
    allow_mirror::Bool = true,
    allow_restart::Bool = true,
)
    _serve(;
        name = basename(dirname(something(Base.active_project(), "julia"))),
        session_id,
        force,
        tools,
        namespace,
        allow_mirror,
        allow_restart,
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
)
    # Capture original argv for restart replay (once, on first call)
    _capture_original_argv()

    # Interactive gate: skip scripts, -e commands, precompilation, workers, etc.
    if !force && !isinteractive()
        @debug "Skipping gate: non-interactive session"
        return nothing
    end

    # Restart gate: when a session is restarting via _exec_restart, skip
    # startup.jl's serve() call so we don't create a temporary gate.
    # App code calling serve(force=true) picks up the session_id from the env var.
    if session_id === nothing && haskey(ENV, "MCPREPL_RESTART_SESSION")
        if !force
            @debug "Skipping gate: restart in progress, app code will handle it"
            return nothing
        end
        # App code (e.g. GateToolTest.run()) calling serve(force=true) —
        # restore the session_id so the TUI reconnects to the same session.
        session_id = pop!(ENV, "MCPREPL_RESTART_SESSION")
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
            # Duplicate serve() call (e.g. startup.jl ran twice) — no-op
            return _SESSION_ID[]
        end
    end

    # Store session tools and namespace
    _SESSION_TOOLS[] = tools
    _SESSION_NAMESPACE[] = namespace
    _ALLOW_MIRROR[] = allow_mirror
    _ALLOW_RESTART[] = allow_restart

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

    # Set receive timeout (1 second) so message loop can check _RUNNING
    socket.rcvtimeo = 1000

    # Bind IPC endpoint
    sock_path = joinpath(SOCK_DIR, "$(sid).sock")
    endpoint = "ipc://$(sock_path)"
    bind(socket, endpoint)

    # Create PUB socket for streaming stdout/stderr to TUI
    pub_socket = Socket(ctx, PUB)
    stream_path = joinpath(SOCK_DIR, "$(sid)-stream.sock")
    stream_endpoint = "ipc://$(stream_path)"
    bind(pub_socket, stream_endpoint)
    _STREAM_SOCKET[] = pub_socket

    # Write metadata file for session discovery
    write_metadata(sid, name, endpoint, stream_endpoint)

    # Register cleanup
    atexit(() -> stop())

    # Start message loop in background
    _RUNNING[] = true
    local this_task
    this_task = _GATE_TASK[] = @async begin
        try
            message_loop(socket)
        catch e
            @debug "Gate task exited" exception = e
        finally
            # Only clean up if we're still the active gate — a restart may
            # have already torn us down and created a replacement gate.
            if _GATE_TASK[] === this_task
                _cleanup()
            end
        end
    end

    _start_revise_watcher()

    emoticon = try
        parentmodule(@__MODULE__).load_personality()
    catch
        "⚡"
    end
    printstyled("  $emoticon Kaimon gate "; color = :green, bold = true)
    printstyled("connected"; color = :green)
    printstyled(" ($name)\n"; color = :light_black)
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

    # Close REP socket
    socket = _GATE_SOCKET[]
    if socket !== nothing
        try
            close(socket)
        catch
        end
        _GATE_SOCKET[] = nothing
    end

    # Close PUB socket
    pub = _STREAM_SOCKET[]
    if pub !== nothing
        try
            close(pub)
        catch
        end
        _STREAM_SOCKET[] = nothing
    end

    # Close context
    ctx = _GATE_CONTEXT[]
    if ctx !== nothing
        try
            close(ctx)
        catch
        end
        _GATE_CONTEXT[] = nothing
    end

    # Remove files
    cleanup_files(_SESSION_ID[])

    _GATE_TASK[] = nothing
    _RUNNING[] = false
    _MIRROR_REPL[] = false
    _ALLOW_MIRROR[] = true
    _ALLOW_RESTART[] = true
    _SESSION_TOOLS[] = GateTool[]
    _SESSION_NAMESPACE[] = ""
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

end # module Gate

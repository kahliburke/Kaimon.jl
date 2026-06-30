# ─────────────────────────────────────────────────────────────────────────────
# KaimonGate · session tools · image results · type reflection & coercion  (split from gate.jl; part of the KaimonGate module)
# ─────────────────────────────────────────────────────────────────────────────

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
    _is_dict_handler(handler) -> Bool

True only when `handler`'s first positional parameter is *explicitly* typed to
receive the raw args Dict (e.g. `f(args::Dict{String,Any})`).

`hasmethod(handler, Tuple{Dict{String,Any}})` alone is too loose: a handler whose
first positional is untyped (`::Any`, the common case — e.g. `f(cells; kw...)`)
also matches it, because a Dict satisfies `::Any`. Taking the fast path there
binds the *entire* args Dict to that one positional and silently drops every
other argument (positional and kwarg) to its default. We require the declared
type `T` to actually be a Dict supertype (and not `Any`) before short-circuiting.
"""
function _is_dict_handler(handler::Function)
    hasmethod(handler, Tuple{Dict{String,Any}}) || return false
    m = which(handler, Tuple{Dict{String,Any}})
    sig = m.sig
    while sig isa UnionAll
        sig = sig.body
    end
    params = sig.parameters
    length(params) >= 2 || return false
    T = params[2]
    return T !== Any && Dict{String,Any} <: T
end

"""
    _dispatch_tool_call(handler, args::Dict{String,Any})

Dispatch a tool call to the handler with properly typed arguments.
If the handler explicitly accepts a Dict, calls directly. Otherwise, reflects on
the method signature to reconstruct typed positional and keyword arguments.
"""
function _dispatch_tool_call(handler::Function, args::Dict{String,Any})
    # Fast path: handler explicitly declares a single raw-Dict argument. Must be
    # an explicit Dict-typed param — an untyped (::Any) first positional also
    # accepts a Dict but would swallow all args into one param (see _is_dict_handler).
    if _is_dict_handler(handler)
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


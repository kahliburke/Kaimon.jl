# ── Minimal JSON helpers (no dependency on JSON3) ────────────────────────────

function _to_json(d::AbstractDict; indent::Int = 2)
    io = IOBuffer()
    _write_json(io, d, 0, indent)
    write(io, '\n')
    String(take!(io))
end

function _write_json(io::IO, d::AbstractDict, level::Int, indent::Int)
    write(io, "{\n")
    entries = collect(pairs(d))
    for (i, (k, v)) in enumerate(entries)
        write(io, ' '^((level + 1) * indent))
        _write_json(io, string(k), level + 1, indent)
        write(io, ": ")
        _write_json(io, v, level + 1, indent)
        i < length(entries) && write(io, ',')
        write(io, '\n')
    end
    write(io, ' '^(level * indent))
    write(io, '}')
end

function _write_json(io::IO, s::AbstractString, ::Int, ::Int)
    write(io, '"')
    for ch in s
        if ch == '"'
            write(io, "\\\"")
        elseif ch == '\\'
            write(io, "\\\\")
        elseif ch == '\n'
            write(io, "\\n")
        else
            write(io, ch)
        end
    end
    write(io, '"')
end

_write_json(io::IO, b::Bool, ::Int, ::Int) = write(io, b ? "true" : "false")
_write_json(io::IO, n::Number, ::Int, ::Int) = write(io, string(n))
_write_json(io::IO, ::Nothing, ::Int, ::Int) = write(io, "null")

function _write_json(io::IO, arr::AbstractVector, level::Int, indent::Int)
    if isempty(arr)
        write(io, "[]")
        return
    end
    write(io, "[\n")
    for (i, v) in enumerate(arr)
        write(io, ' '^((level + 1) * indent))
        _write_json(io, v, level + 1, indent)
        i < length(arr) && write(io, ',')
        write(io, '\n')
    end
    write(io, ' '^(level * indent))
    write(io, ']')
end

function _parse_json_simple(s::AbstractString)
    # Minimal recursive-descent JSON parser for settings files.
    # Handles objects, strings, booleans, null. No arrays needed for config files.
    s = strip(s)
    isempty(s) && return Dict{String,Any}()
    try
        val, _ = _json_parse_value(s, 1)
        return val isa Dict ? val : Dict{String,Any}()
    catch
        return Dict{String,Any}()
    end
end

function _json_skip_ws(s, i)
    while i <= length(s) && s[i] in (' ', '\t', '\n', '\r')
        i += 1
    end
    i
end

function _json_parse_value(s, i)
    i = _json_skip_ws(s, i)
    i > length(s) && error("unexpected end")
    c = s[i]
    if c == '"'
        _json_parse_string(s, i)
    elseif c == '{'
        _json_parse_object(s, i)
    elseif c == 't' && i + 3 <= length(s) && s[i:i+3] == "true"
        (true, i + 4)
    elseif c == 'f' && i + 4 <= length(s) && s[i:i+4] == "false"
        (false, i + 5)
    elseif c == 'n' && i + 3 <= length(s) && s[i:i+3] == "null"
        (nothing, i + 4)
    elseif c == '-' || isdigit(c)
        j = i
        (c == '-') && (j += 1)
        while j <= length(s) && (isdigit(s[j]) || s[j] == '.')
            j += 1
        end
        (parse(Float64, s[i:j-1]), j)
    else
        error("unexpected char '$c' at $i")
    end
end

function _json_parse_string(s, i)
    i += 1  # skip opening "
    buf = IOBuffer()
    while i <= length(s) && s[i] != '"'
        if s[i] == '\\' && i + 1 <= length(s)
            i += 1
            c = s[i]
            if c == 'n'
                write(buf, '\n')
            elseif c == 't'
                write(buf, '\t')
            elseif c == '"'
                write(buf, '"')
            elseif c == '\\'
                write(buf, '\\')
            elseif c == '/'
                write(buf, '/')
            else
                write(buf, '\\')
                write(buf, c)
            end
        else
            write(buf, s[i])
        end
        i += 1
    end
    (String(take!(buf)), i + 1)  # skip closing "
end

function _json_parse_object(s, i)
    i += 1  # skip {
    d = Dict{String,Any}()
    i = _json_skip_ws(s, i)
    i <= length(s) && s[i] == '}' && return (d, i + 1)
    while true
        i = _json_skip_ws(s, i)
        key, i = _json_parse_string(s, i)
        i = _json_skip_ws(s, i)
        (i <= length(s) && s[i] == ':') || error("expected ':'")
        i += 1
        val, i = _json_parse_value(s, i)
        d[key] = val
        i = _json_skip_ws(s, i)
        i > length(s) && break
        if s[i] == ','
            i += 1
        elseif s[i] == '}'
            i += 1
            break
        else
            break
        end
    end
    (d, i)
end

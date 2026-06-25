# ── grep_code: exact-pattern code search (ripgrep-backed, symbol-enriched) ─────
#
# The pattern half of the two-tool search split: `search_code` finds by MEANING,
# `grep_code` finds an EXACT PATTERN — a "better grep than grep". Backed by ripgrep
# over the live working tree (.gitignore-aware, true regex), and every on-disk hit is
# enriched with its enclosing definition, parsed FRESH from the file (so the symbol is
# always current, never a stale index). Default scope is the calling agent's bound
# project; narrow with `path` / `file` / `glob`.
#
# Three layers, each optional and additive:
#   1. pattern + scope + enclosing symbol           (always)
#   2. semantic-assisted file ranking               (when an NL `query` is supplied)
#   3. adaptive context: expand a hit's surrounding  (where a semantic window overlaps
#      lines only where semantics says it's relevant  it — else stay tight to save tokens)

# ── small arg coercions (JSON args arrive as Any) ──────────────────────────────
_grep_str(args, k) = let v = get(args, k, nothing)
    (v isa AbstractString && !isempty(v)) ? String(v) : nothing
end
_grep_bool(args, k) = let v = get(args, k, false)
    v isa Bool ? v : (v == "true" || v === true)
end
function _grep_globs(args)
    v = get(args, "glob", nothing)
    v === nothing && return String[]
    v isa AbstractString && return isempty(v) ? String[] : [String(v)]
    v isa AbstractVector && return String[String(x) for x in v if x isa AbstractString && !isempty(x)]
    return String[]
end

# Resolve the ripgrep invocation prefix as an argv vector. Prefer the bundled
# `ripgrep_jll` artifact (guaranteed) when it's been loaded as a dep; fall back to a
# system `rg` on PATH so the tool works before the JLL is precompiled in. Returns the
# argv prefix (e.g. ["/path/to/rg"]) or `nothing` when no ripgrep is available.
function _rg_argv()
    if isdefined(@__MODULE__, :ripgrep_jll)
        try
            c = getfield(@__MODULE__, :ripgrep_jll).rg()   # a Cmd wrapping the binary
            return collect(String, c.exec)
        catch
        end
    end
    p = Sys.which("rg")
    return p === nothing ? nothing : String[p]
end

# The project root to search: the caller's bound session project (per-agent binding,
# same source `search_code` defaults to), else the cwd.
function _grep_base_root()
    p = try; _last_session_project_path(); catch; ""; end
    (!isempty(p) && isdir(p)) ? p : pwd()
end

# Resolve the search root + base (for relative display). `file`/`path` narrow the scan;
# both resolve relative to the bound project (or absolute). Returns (root, base, err).
function _grep_resolve_root(args)
    base = _grep_base_root()
    target = something(_grep_str(args, "file"), _grep_str(args, "path"), Some(nothing))
    target === nothing && return (base, base, nothing)
    abs = isabspath(target) ? target : abspath(joinpath(base, target))
    ispath(abs) || return (nothing, base, "Error: path not found: $(target) (resolved to $abs)")
    return (abs, base, nothing)
end

# Collection name for semantic ranking: explicit `collection` arg, else the scope
# project's default collection. `nothing` when there's no project to derive one from.
function _grep_collection(args, base::AbstractString)
    raw = _grep_str(args, "collection")
    raw !== nothing && return raw
    isempty(base) ? nothing : get_project_collection_name(base)
end

# ── ripgrep --json parse ───────────────────────────────────────────────────────

# Parse ripgrep's `--json` stream into match hits, stopping once `cap` is collected
# (the remainder is reported as truncated). Each hit: (file, line, text, subs) where
# `subs` are the matched substrings (for highlighting).
function _grep_parse_rg(out::AbstractString, cap::Int)
    hits = NamedTuple[]
    more = false
    for ln in eachsplit(out, '\n'; keepempty = false)
        obj = try; JSON.parse(ln); catch; continue; end
        get(obj, "type", "") == "match" || continue
        if length(hits) >= cap
            more = true
            break
        end
        d = get(obj, "data", Dict())
        path = get(get(d, "path", Dict()), "text", "")
        (path isa AbstractString && !isempty(path)) || continue   # skip non-UTF8 (bytes) paths
        text = get(get(d, "lines", Dict()), "text", "")
        text isa AbstractString || continue
        subs = String[]
        for s in get(d, "submatches", [])
            mt = get(get(s, "match", Dict()), "text", "")
            mt isa AbstractString && !isempty(mt) && push!(subs, mt)
        end
        push!(hits, (file = String(path), line = Int(get(d, "line_number", 0)),
                     text = rstrip(String(text), ['\n', '\r']), subs = unique(subs)))
    end
    return hits, more
end

# ── per-file context (raw lines + definitions), parsed once per grep call ──────

# (lines, defs) for a file, cached for the duration of one grep call. `defs` are the
# non-window definitions as (start, end, name, type); empty on read/parse failure.
function _grep_file_ctx(file::AbstractString, cache::Dict)
    return get!(cache, file) do
        content = try; read(file, String); catch; return (String[], Tuple{Int,Int,String,String}[]); end
        lines = collect(eachsplit(content, '\n'))
        defs = Tuple{Int,Int,String,String}[]
        try
            for d in extract_definitions(content, String(file))
                get(d, "type", "") == "window" && continue
                sl = get(d, "start_line", nothing); el = get(d, "end_line", nothing)
                (sl isa Integer && el isa Integer) || continue
                push!(defs, (Int(sl), Int(el), String(get(d, "name", "")), String(get(d, "type", ""))))
            end
        catch
        end
        (lines, defs)
    end
end

# Enclosing definition (smallest span containing `line`) as (name, type), or nothing.
function _grep_enclosing(line::Int, defs::Vector{Tuple{Int,Int,String,String}})
    best = nothing
    for (s, e, name, typ) in defs
        if s <= line <= e && (best === nothing || (e - s) < (best[2] - best[1]))
            best = (s, e, name, typ)
        end
    end
    best === nothing && return nothing
    return (best[3], best[4])
end

# ── semantic windows (Stage 2/3): rank files + flag context-worthy hits ────────

# Semantically-ranked windows for `query`, scoped to a collection: (file, start, end,
# score), best first. Empty when no query, services down, or the collection is unknown
# — callers then fall back to ripgrep's file-traversal order with tight context.
function _grep_semantic_windows(query::Union{Nothing,AbstractString}, collection::Union{Nothing,AbstractString})
    (query === nothing || isempty(query) || collection === nothing) && return Tuple{String,Int,Int,Float64}[]
    QdrantClient.ping() || return Tuple{String,Int,Int,Float64}[]
    col, err = _resolve_collection(String(collection), QdrantClient.list_collections())
    err === nothing || return Tuple{String,Int,Int,Float64}[]
    model = resolve_search_model(col)
    (ping_ollama() && check_ollama_model(model)) || return Tuple{String,Int,Int,Float64}[]
    emb = get_ollama_embedding(String(query); model = model)
    isempty(emb) && return Tuple{String,Int,Int,Float64}[]
    out = Tuple{String,Int,Int,Float64}[]
    for r in QdrantClient.search(col, emb; limit = 80)
        p = get(r, "payload", Dict())
        f = string(get(p, "file", ""))
        isempty(f) && continue
        push!(out, (f, Int(get(p, "start_line", 0)), Int(get(p, "end_line", 0)),
                    Float64(get(r, "score", 0.0))))
    end
    return out
end

_grep_in_window(file, line, windows) = any(w -> w[1] == file && w[2] <= line <= w[3], windows)

# ── rendering ──────────────────────────────────────────────────────────────────

function _grep_relfile(f::AbstractString, base::AbstractString)
    try
        !isempty(base) && startswith(f, base) && return relpath(f, base)
        startswith(f, pwd()) && return relpath(f, pwd())
    catch
    end
    return f
end

# Bold the matched substrings within a line (capped width). Literal, case-sensitive
# replace of the actual ripgrep submatch text — no regex escaping needed.
function _grep_highlight(text::AbstractString, subs::Vector{String}; width::Int = 200)
    t = strip(text)
    length(t) > width && (t = first(t, width) * "…")
    for st in subs
        occursin("**" * st * "**", t) && continue   # avoid double-bolding
        t = replace(t, st => "**" * st * "**")
    end
    return t
end

_grep_trunc(s::AbstractString; width::Int = 200) = (t = strip(s); length(t) > width ? first(t, width) * "…" : t)

# One hit: a tight single line, or — when `ctx > 0` (a semantic window overlaps it, or
# the caller forced context) — the match plus `ctx` lines either side for a peek at
# what it's part of.
function _grep_render_hit(h, lines::Vector, defs, ctx::Int)
    enc = _grep_enclosing(h.line, defs)
    label = enc === nothing ? "" :
        (enc[2] == "function" || enc[2] == "tool" ? "  $(enc[1])" : "  $(enc[2]) $(enc[1])")
    ctx <= 0 && return "  L$(h.line)$label  $(_grep_highlight(h.text, h.subs))\n"
    lo = max(1, h.line - ctx); hi = min(length(lines), h.line + ctx)
    out = "  L$(h.line)$label\n"
    for n in lo:hi
        if n == h.line
            out *= "    ▸ L$n  $(_grep_highlight(h.text, h.subs))\n"
        else
            out *= "      L$n  $(_grep_trunc(lines[n]))\n"
        end
    end
    return out
end

function _grep_format(pattern, scope_label, hits, more, base, query, sem_windows, ctx_arg::Int)
    # Group hits by file (encounter order).
    files = String[]
    byfile = Dict{String,Vector{Any}}()
    for h in hits
        haskey(byfile, h.file) || (push!(files, h.file); byfile[h.file] = Any[])
        push!(byfile[h.file], h)
    end

    # Stage 2: when ranking, order file groups by each file's best semantic score.
    ranked = !isempty(sem_windows)
    if ranked
        best = Dict{String,Float64}()
        for (f, _, _, sc) in sem_windows
            best[f] = max(get(best, f, -Inf), sc)
        end
        files = sort(files; by = f -> -get(best, f, -Inf), alg = Base.Sort.MergeSort)  # stable
    end

    nh = length(hits)
    out = "🔎 /$pattern/ in $scope_label — $nh match$(nh == 1 ? "" : "es") in " *
          "$(length(files)) file$(length(files) == 1 ? "" : "s")"
    ranked && (out *= " · ranked by relevance to \"$query\"")
    more && (out *= " (truncated)")
    out *= ":\n"

    cache = Dict{String,Any}()
    for f in files
        lines, defs = _grep_file_ctx(f, cache)
        out *= "\n$(_grep_relfile(f, base))\n"
        for h in byfile[f]
            # Stage 3: expand context where a semantic window overlaps the hit (or the
            # caller forced it); otherwise stay tight to one line.
            ctx = max(ctx_arg, (ranked && _grep_in_window(f, h.line, sem_windows)) ? 2 : 0)
            out *= _grep_render_hit(h, lines, defs, ctx)
        end
    end
    return out
end

"""
    _grep_code(args) -> String

Implementation behind the `grep_code` MCP tool. Exact-pattern (regex) search over the
working tree via ripgrep, scoped to the bound project (or `path`/`file`/`glob`), each
hit enriched with its enclosing definition. With an NL `query`, files are ranked by
semantic relevance and overlapping hits get a little surrounding context.
"""
function _grep_code(args)
    pattern = String(get(args, "pattern", ""))
    isempty(pattern) && return "Error: pattern is required"

    rg = _rg_argv()
    rg === nothing && return "Error: ripgrep (rg) is not available. Install it, or add ripgrep_jll."

    root, base, err = _grep_resolve_root(args)
    root === nothing && return err

    limit = Int(get(args, "limit", 40))
    ctx_arg = max(0, Int(get(args, "context", 0)))
    query = _grep_str(args, "query")

    flags = String[]
    _grep_bool(args, "ignore_case") && push!(flags, "-i")
    _grep_bool(args, "word") && push!(flags, "-w")
    _grep_bool(args, "fixed") && push!(flags, "-F")
    for g in _grep_globs(args)
        push!(flags, "-g"); push!(flags, g)
    end

    # `--` terminates flags so a pattern starting with `-` is taken literally.
    argv = String[rg...; "--json"; flags...; "--"; pattern; root]
    errbuf = IOBuffer()
    out = try
        read(pipeline(ignorestatus(Cmd(argv)), stderr = errbuf), String)
    catch e
        return "Error running ripgrep: $(sprint(showerror, e))"
    end

    hits, more = _grep_parse_rg(out, limit)
    if isempty(hits)
        errtxt = strip(String(take!(errbuf)))
        isempty(errtxt) && return "No matches for /$pattern/ in $(_grep_relfile(root, base))"
        return "Error: ripgrep — $(first(errtxt, 300))"
    end

    sem_windows = _grep_semantic_windows(query, _grep_collection(args, base))
    scope_label = root == base ? basename(rstrip(base, '/')) : _grep_relfile(root, base)
    return _grep_format(pattern, scope_label, hits, more, base, query, sem_windows, ctx_arg)
end

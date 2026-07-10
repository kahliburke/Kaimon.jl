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

# Canonicalize a path (resolve symlinks). rg anchors slash-globs to the search root
# STRING, but reports canonicalized file paths — if the root we pass still contains a
# symlink (e.g. macOS `/var` → `/private/var`), the prefixes disagree and every slash
# glob silently fails. Canonicalizing root + base up front keeps them aligned with what
# rg emits (and with each other, so relative-path display stays correct). Falls back to
# the raw path if it can't be resolved.
_grep_canon(p::AbstractString) = try; realpath(p); catch; String(p); end

# Nearest enclosing git repo root of `p` (the dir holding `.git`), canonicalized, or
# `nothing` if none is found before the filesystem root. Used to anchor globs when the
# search root lies OUTSIDE the bound project (a foreign absolute `path=`): so those globs
# are still repo-root-relative — the `cd repo && rg -g '<glob>'` model — matching the
# in-project case instead of silently anchoring one directory deeper.
function _grep_repo_root(p::AbstractString)
    d = _grep_canon(isdir(p) ? p : dirname(p))
    while true
        ispath(joinpath(d, ".git")) && return d
        parent = dirname(d)
        parent == d && return nothing   # hit filesystem root, no repo
        d = parent
    end
end

const _GREP_NO_PROJECT_MSG =
    "Error: no project is bound to your MCP session, so grep_code has nothing to scope " *
    "to. This usually means the session hasn't reassociated with its project after a " *
    "Kaimon server restart. Reconnect the session and try again. (Refusing to default " *
    "to the server's own working directory, which would search the wrong repo.)"

# The project root to search: the caller's bound session project (per-agent binding,
# same source `search_code` defaults to). Returns "" for an AGENT caller with no bound
# project — the caller then errors rather than silently scoping to the server's cwd
# (the wrong-repo bug). Caller-less (REPL/self) calls still fall back to cwd as before.
function _grep_base_root()
    p = try; _last_session_project_path(); catch; ""; end
    (!isempty(p) && isdir(p)) && return _grep_canon(p)
    isempty(_current_mcp_caller()) || return ""   # agent with no project → signal error
    return _grep_canon(pwd())
end

# ── Path confinement ─────────────────────────────────────────────────────────
# grep_code runs in the Kaimon server process with full filesystem access, and no
# MCP client enforces a file-access scope for a custom tool. So we confine it here:
# a resolved path outside the session's allowed roots (the bound project, the caller's
# declared MCP workspace roots, and the persisted grep whitelist) is not read until
# the user approves it, via the same elicitation flow project approval uses. This
# stops an agent from reading arbitrary files (e.g. ~/.ssh) through an absolute path.
# Confinement is lifted for caller-less REPL/self calls (the human is driving) and in
# `allow_any_project` container mode (the environment is the boundary).

# The absolute roots grep may read for the current caller: the resolved project, the
# caller's declared MCP workspace roots (the dirs the user opened in their client), and
# the persisted grep whitelist — canonicalized (realpath) so `..`/symlinks can't slip
# the fence. NOTE: allowed *projects* are intentionally NOT included; approving a
# project for a session doesn't make it grep-readable — that needs its own opt-in.
function _grep_allowed_roots()
    raw = String[]
    p = try; _last_session_project_path(); catch; ""; end
    isempty(p) || push!(raw, p)
    caller = try; _current_mcp_caller(); catch; ""; end
    if !isempty(caller)
        wr = try
            lock(_SESSION_WORKSPACE_ROOT_LOCK) do
                get(_SESSION_WORKSPACE_ROOT, caller, "")
            end
        catch
            ""
        end
        isempty(wr) || push!(raw, wr)
        for f in (_persisted_workspace_root, _persisted_session_project)
            v = try; f(caller); catch; nothing; end
            v === nothing || push!(raw, v)
        end
    end
    append!(raw, try; grep_allowed_paths(); catch; String[]; end)   # persisted whitelist
    out = String[]
    for r in raw
        isempty(r) && continue
        c = _grep_canon(r)
        (isdir(c) && !(c in out)) && push!(out, c)
    end
    return out
end

_grep_path_within(abs::AbstractString, roots::Vector{String}) = any(roots) do r
    a = rstrip(String(abs), '/')
    rr = rstrip(r, '/')
    a == rr || startswith(a, rr * "/")
end

_grep_out_of_scope_msg(abs::AbstractString, roots::Vector{String}) =
    "Error: `$abs` is outside this session's allowed scope. grep_code is confined to " *
    (isempty(roots) ? "the bound project (none is bound to this session)" :
     "the project and workspace (" * join(roots, ", ") * ")") *
    ". Reading elsewhere requires the user's approval, which was not given (no prompt " *
    "shown, or declined). If you need this path, ask the user to approve it — don't try " *
    "to grant it yourself."

# Ask the user (via MCP elicitation) to approve grep reading an out-of-scope `path`.
# Mirrors `_elicit_session_consent`: accept allows this call; the "remember" checkbox
# adds it to the persisted grep whitelist. Returns :always / :once / :denied /
# :timeout / :unsupported (no caller, no session, or a client that can't elicit).
function _elicit_grep_path_consent(path::AbstractString)
    caller = _current_mcp_caller()
    isempty(caller) && return :unsupported
    session = lock(STANDALONE_SESSIONS_LOCK) do
        get(STANDALONE_SESSIONS, caller, nothing)
    end
    session === nothing && return :unsupported
    _caps_may_elicit(session.client_capabilities) || return :unsupported
    schema = Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "remember" => Dict{String,Any}(
                "type" => "boolean",
                "title" => "Always allow grep to read this path (add to the allow-list)",
                "default" => false,
            ),
        ),
    )
    msg =
        "Claude wants grep_code to search files under:\n$path\n\nThis is outside the " *
        "current project and workspace. Accept to allow this search. Check \"Always " *
        "allow\" to add it to your grep allow-list and skip this prompt next time."
    res = request_elicitation(caller, msg, schema; timeout = elicitation_timeout())
    res isa AbstractDict || return :timeout
    get(res, "action", "") == "accept" || return :denied
    content = get(res, "content", nothing)
    remember = content isa AbstractDict && get(content, "remember", false) === true
    return remember ? :always : :once
end

# Confine an AGENT caller's resolved search root to its allowed roots. Caller-less and
# container-mode calls are unconfined. An out-of-scope root triggers the consent prompt;
# "always" persists the directory to the grep whitelist. Returns an error string to
# abort, or `nothing` to proceed.
function _grep_enforce_scope(root::AbstractString; consent = _elicit_grep_path_consent)
    caller = try; _current_mcp_caller(); catch; ""; end
    isempty(caller) && return nothing
    (try; projects_allow_any(); catch; false; end) && return nothing
    roots = _grep_allowed_roots()
    _grep_path_within(root, roots) && return nothing
    decision = try; consent(root); catch; :unsupported; end
    if decision === :always
        try; allow_grep_path!(isdir(root) ? root : dirname(root)); catch; end
        return nothing
    elseif decision === :once
        return nothing
    elseif decision === :timeout
        return "Error: no answer to the grep access prompt within " *
               "$(round(Int, elicitation_timeout()))s. Retry when you're ready to " *
               "approve reading `$root`."
    else  # :denied / :unsupported
        return _grep_out_of_scope_msg(root, roots)
    end
end

# Resolve the search root + base (for relative display). `file`/`path` narrow the scan;
# both resolve relative to the bound project (or absolute). Returns (root, base, err).
# Both are canonical so rg's slash-globs anchor correctly (see `_grep_canon`). Path
# CONFINEMENT is enforced separately in `_grep_enforce_scope` (it may prompt the user).
function _grep_resolve_root(args)
    base = _grep_base_root()
    target = something(_grep_str(args, "file"), _grep_str(args, "path"), Some(nothing))
    if target === nothing
        # No explicit path and no bound project (agent caller) → refuse, don't guess.
        isempty(base) && return (nothing, "", _GREP_NO_PROJECT_MSG)
        return (base, base, nothing)
    end
    # A relative path needs a project to anchor to; without one we can't resolve it.
    (!isabspath(target) && isempty(base)) && return (nothing, "", _GREP_NO_PROJECT_MSG)
    abs = _grep_canon(isabspath(target) ? target : abspath(joinpath(base, target)))
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

# Parse ripgrep's `--json --stats` stream. Returns (files, total, scanned):
#   files   — Vector of (path, count, hits) in ENCOUNTER order. `count` is the file's EXACT
#             match total (from its `end` message); `hits` are the first ≤`retain` matched
#             lines (document order), each (file, line, text) kept VERBATIM.
#   total   — total matches across the whole search (`summary` message).
#   scanned — files ripgrep examined (`summary.searches`), so a true "no matches" can say
#             how much was looked at ("0 of N files scanned") instead of being mistaken for
#             a scoping error.
# Lines are kept verbatim (no `**`/marker): an in-band marker splits identifiers into
# unfamiliar subword fragments and costs exact-string fidelity, while the "which substring
# matched" signal is worth ~nothing to a consumer that knows its own pattern. Retaining is
# bounded (≤`retain` lines per file, and only for the first `_GREP_RETAIN_FILES` files) so a
# broad match can't blow up memory — the `end`/`summary` COUNTS stay exact regardless.
function _grep_parse_rg(out::AbstractString, retain::Int)
    order = String[]
    idx = Dict{String,Int}()
    counts = Int[]
    hitsv = Vector{NamedTuple}[]
    total = 0; scanned = 0; have_summary = false
    for ln in eachsplit(out, '\n'; keepempty = false)
        obj = try; JSON.parse(ln); catch; continue; end
        typ = get(obj, "type", "")
        d = get(obj, "data", Dict())
        if typ == "match"
            path = get(get(d, "path", Dict()), "text", "")
            (path isa AbstractString && !isempty(path)) || continue   # skip non-UTF8 paths
            gi = get(idx, path, 0)
            if gi == 0
                push!(order, path); push!(counts, 0); push!(hitsv, NamedTuple[])
                gi = length(order); idx[path] = gi
            end
            if gi <= _GREP_RETAIN_FILES && length(hitsv[gi]) < retain
                text = get(get(d, "lines", Dict()), "text", "")
                text isa AbstractString || continue
                push!(hitsv[gi], (file = String(path), line = Int(get(d, "line_number", 0)),
                                  text = rstrip(String(text), ['\n', '\r'])))
            end
        elseif typ == "end"
            path = get(get(d, "path", Dict()), "text", "")
            (path isa AbstractString && !isempty(path)) || continue
            c = Int(get(get(d, "stats", Dict()), "matches", 0))
            gi = get(idx, path, 0)
            if gi == 0
                push!(order, path); push!(counts, c); push!(hitsv, NamedTuple[]); idx[path] = length(order)
            else
                counts[gi] = c
            end
        elseif typ == "summary"
            s = get(d, "stats", Dict())
            total = Int(get(s, "matches", 0)); scanned = Int(get(s, "searches", 0))
            have_summary = true
        end
    end
    files = [(path = order[i], count = counts[i], hits = hitsv[i]) for i in eachindex(order)]
    have_summary || (total = sum(counts; init = 0))
    return files, total, scanned
end

# Max-min fair-share (water-filling): hand out a `budget` of match slots across files with
# the given `counts`, in order. Each round gives every still-unsatisfied file an equal
# share (capped at what it can absorb); small files take only what they have and the
# leftover redistributes to the bigger ones. Depth is spent before breadth — losing lines
# in a big file is recoverable (narrow and re-query), losing a whole file to depth-first
# truncation is not (you never learn to go back). e.g. counts=[40,18], budget=40 → [22,18].
function _grep_waterfill(counts::Vector{Int}, budget::Int)
    n = length(counts)
    alloc = zeros(Int, n)
    remaining = max(0, budget)
    while remaining > 0
        active = [i for i in 1:n if alloc[i] < counts[i]]
        isempty(active) && break
        share = remaining ÷ length(active)
        if share == 0                        # remainder < #active → one each, in order
            for i in active
                remaining == 0 && break
                alloc[i] += 1; remaining -= 1
            end
            break
        end
        for i in active
            give = min(share, counts[i] - alloc[i])
            alloc[i] += give; remaining -= give
        end
    end
    return alloc
end

# ── per-file context (raw lines + definitions), parsed once per grep call ──────

# Extensions we attempt enclosing-symbol enrichment for. The chunker parses CODE, not
# logs/data — so non-code files (logs, generated output, csv/json/txt) still match via
# ripgrep, they just show file:line + the matched line, which is all you want there.
const _GREP_CODE_EXTS = Set([".jl", ".ts", ".tsx", ".jsx", ".js", ".py", ".rs", ".go",
    ".c", ".h", ".cpp", ".hpp", ".cc", ".java", ".rb", ".ex", ".exs"])
_grep_is_code_file(file::AbstractString) = lowercase(splitext(file)[2]) in _GREP_CODE_EXTS

# (lines, defs) for a file, cached for the duration of one grep call. `defs` are the
# non-window definitions as (start, end, name, type) — only parsed for code files (a log
# isn't worth parsing as code), else empty.
function _grep_file_ctx(file::AbstractString, cache::Dict)
    return get!(cache, file) do
        content = try; read(file, String); catch; return (String[], Tuple{Int,Int,String,String}[]); end
        lines = collect(eachsplit(content, '\n'))
        defs = Tuple{Int,Int,String,String}[]
        if _grep_is_code_file(file)
            try
                for d in extract_definitions(content, String(file))
                    get(d, "type", "") == "window" && continue
                    sl = get(d, "start_line", nothing); el = get(d, "end_line", nothing)
                    (sl isa Integer && el isa Integer) || continue
                    push!(defs, (Int(sl), Int(el), String(get(d, "name", "")), String(get(d, "type", ""))))
                end
            catch
            end
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

# Smallest enclosing definition SPAN (start, end) containing `line`, or nothing — the
# identity hits are grouped by when collapsing repeats within one function.
function _grep_enclosing_span(line::Int, defs::Vector{Tuple{Int,Int,String,String}})
    best = nothing
    for (s, e, _, _) in defs
        if s <= line <= e && (best === nothing || (e - s) < (best[2] - best[1]))
            best = (s, e)
        end
    end
    return best
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

# Trim + width-cap a matched/context line for display. The line is returned VERBATIM (no
# inline match markers) — see `_grep_parse_rg` for why highlighting is deliberately absent.
# A human-facing TUI is free to re-highlight at RENDER time (it has the search pattern), so
# decoration lives at the display surface, not on the MCP wire.
_grep_trunc(s::AbstractString; width::Int = 200) = (t = strip(s); length(t) > width ? first(t, width) * "…" : t)

# One hit: a tight single line, or — when `ctx > 0` (a semantic window overlaps it, or
# the caller forced context) — the match plus `ctx` lines either side for a peek at
# what it's part of.
function _grep_render_hit(h, lines::Vector, defs, ctx::Int)
    enc = _grep_enclosing(h.line, defs)
    # Suppress the enclosing-symbol column when the hit is ON the definition's own line: the
    # line text already spells out the signature, so the label would just duplicate it (e.g.
    # `L79  const _MEMO_OK  const _MEMO_OK = try`). The column earns its keep only when the
    # hit sits deeper in the body, away from the name.
    span = _grep_enclosing_span(h.line, defs)
    on_def_line = span !== nothing && span[1] == h.line
    label = (enc === nothing || on_def_line) ? "" :
        (enc[2] == "function" || enc[2] == "tool" ? "  $(enc[1])" : "  $(enc[2]) $(enc[1])")
    ctx <= 0 && return "  L$(h.line)$label  $(_grep_trunc(h.text))\n"
    lo = max(1, h.line - ctx); hi = min(length(lines), h.line + ctx)
    out = "  L$(h.line)$label\n"
    for n in lo:hi
        if n == h.line
            out *= "    ▸ L$n  $(_grep_trunc(h.text))\n"
        else
            out *= "      L$n  $(_grep_trunc(lines[n]))\n"
        end
    end
    return out
end

# Output-shaping budgets (keep a single grep result token-cheap):
const _GREP_OUT_BUDGET = 8192          # ~8 KB total-output cap; overflow is truncated with guidance
const _GREP_RANK_EXPAND_TOPN = 5       # only the top-N ranked files get context expansion
const _GREP_MAX_FILES = 15             # cap on files shown; the rest roll into a "…N more files" stub
const _GREP_RETAIN_FILES = 200         # retain hit LINES for at most this many files (counts stay exact)

# Collapse a file's hits that share one enclosing definition: the first hit represents
# the function, the rest fold into a single "(+N more)" line. Hits with no enclosing def
# (or distinct spans) each form their own group. First-encounter order is preserved.
# Returns a vector of (representative_hit, other_hits).
function _grep_group_by_enclosing(hits::Vector, defs::Vector{Tuple{Int,Int,String,String}})
    groups = Vector{Any}[]
    index = Dict{Tuple{Int,Int},Int}()   # enclosing span → group index
    for h in hits
        span = _grep_enclosing_span(h.line, defs)
        if span === nothing
            push!(groups, Any[h])                                  # ungrouped line
        else
            gi = get(index, span, 0)
            gi == 0 ? (push!(groups, Any[h]); index[span] = length(groups)) : push!(groups[gi], h)
        end
    end
    return [(g[1], @view g[2:end]) for g in groups]
end

# Render the parsed files into the final text. `files` is the parser's per-file data
# (path, count, hits). Match slots are FAIR-SHARED across files (waterfill) so a broad
# match spends its budget on breadth, not depth — every matching file stays visible (with
# a per-file "showing X of N" when clipped), and files past the display cap collapse into a
# one-line stub rather than vanishing silently.
function _grep_format(pattern, scope_label, files, total, header_extra, base, query,
                      sem_windows, ctx_arg::Int, limit::Int)
    F = length(files)
    # File order: ranked by best semantic score when a `query` is given, else encounter order.
    ranked = !isempty(sem_windows)
    order = collect(1:F)
    if ranked
        best = Dict{String,Float64}()
        for (f, _, _, sc) in sem_windows
            best[f] = max(get(best, f, -Inf), sc)
        end
        sort!(order; by = i -> -get(best, files[i].path, -Inf), alg = Base.Sort.MergeSort)  # stable
    end

    # File-count cap: allocate the budget only across the first _GREP_MAX_FILES files; the
    # rest are summarized so a broad match can't silently swallow whole files.
    ncap = min(F, _GREP_MAX_FILES)
    cap_idx = order[1:ncap]
    beyond = order[ncap+1:end]
    alloc = _grep_waterfill([files[i].count for i in cap_idx], limit)
    rendered = [(cap_idx[k], alloc[k]) for k in 1:ncap if alloc[k] > 0]
    starved = [cap_idx[k] for k in 1:ncap if alloc[k] == 0]   # in-cap but budget ran out
    hidden = vcat(starved, beyond)
    shown_total = sum(a for (_, a) in rendered; init = 0)

    # Context expansion stays confined to the top-N ranked rendered files.
    expandable = Set{String}()
    if ranked
        for k in 1:min(length(rendered), _GREP_RANK_EXPAND_TOPN)
            push!(expandable, files[rendered[k][1]].path)
        end
    end

    out = "🔎 /$pattern/ in $scope_label$header_extra — $total match$(total == 1 ? "" : "es") in " *
          "$F file$(F == 1 ? "" : "s")"
    ranked && (out *= " · ranked by relevance to \"$query\"")
    shown_total < total && (out *= ", showing $shown_total")
    out *= ":\n"

    cache = Dict{String,Any}()
    byte_hit = false
    for (i, a) in rendered
        f = files[i].path
        fh = files[i].hits
        take = fh[1:min(a, length(fh))]                 # first `a` matches, document order
        lines, defs = _grep_file_ctx(f, cache)
        clip = files[i].count > a ? " (showing $a of $(files[i].count))" : ""
        out *= "\n$(_grep_relfile(f, base))$clip\n"
        # Respect an explicit context= request by rendering every hit (empty defs → no
        # collapsing); otherwise collapse repeats that share an enclosing function.
        groups = _grep_group_by_enclosing(take, ctx_arg > 0 ? Tuple{Int,Int,String,String}[] : defs)
        for (rep, rest) in groups
            if sizeof(out) >= _GREP_OUT_BUDGET
                byte_hit = true
                break
            end
            ctx = max(ctx_arg, (f in expandable && _grep_in_window(f, rep.line, sem_windows)) ? 2 : 0)
            out *= _grep_render_hit(rep, lines, defs, ctx)
            isempty(rest) ||
                (out *= "      (+$(length(rest)) more: $(join(("L$(h.line)" for h in rest), ", ")))\n")
        end
        byte_hit && break
    end

    if !isempty(hidden)
        hm = sum(files[i].count for i in hidden; init = 0)
        nh = length(hidden)
        out *= "\n…and $nh more file$(nh == 1 ? "" : "s") ($hm match$(hm == 1 ? "" : "es") not shown) — " *
               "narrow the pattern or scope (glob=/path=), or raise limit=.\n"
    elseif byte_hit
        out *= "\n… output truncated at ~$(_GREP_OUT_BUDGET ÷ 1024) KB — narrow with glob=/path= " *
               "or a tighter pattern.\n"
    end
    return out
end

# Count files IN SCOPE (after .gitignore + globs) by asking rg to LIST them (`--files`).
# Used only on the empty path — cheap, and it answers the question `stats.searches` can't
# on this rg build: was anything actually searched? 0 ⇒ the path/glob matched no files (a
# scoping mistake); N ⇒ a genuine negative over N files.
function _grep_scope_file_count(rg, scan_flags, root, rg_cwd)
    argv = String[rg...; "--files"; scan_flags...; "--"; root]
    try
        out = read(pipeline(ignorestatus(Cmd(Cmd(argv); dir = rg_cwd)), stderr = devnull), String)
        isempty(out) && return 0
        return count(==('\n'), out) + (endswith(out, '\n') ? 0 : 1)
    catch
        return 0
    end
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
    # Path confinement (may prompt the user to approve an out-of-scope read).
    scope_err = _grep_enforce_scope(root)
    scope_err === nothing || return scope_err

    limit = Int(get(args, "limit", 20))
    ctx_arg = max(0, Int(get(args, "context", 0)))
    query = _grep_str(args, "query")

    # Pattern flags (-i/-w/-F) vs traversal flags (glob + ignore/hidden). Kept apart so the
    # traversal set can be reused to COUNT files in scope on an empty result (below).
    pat_flags = String[]
    _grep_bool(args, "ignore_case") && push!(pat_flags, "-i")
    _grep_bool(args, "word") && push!(pat_flags, "-w")
    _grep_bool(args, "fixed") && push!(pat_flags, "-F")
    scan_flags = String[]
    # no_ignore: also search .gitignored + hidden files (logs, build/ output, generated,
    # dotfiles) — makes grep_code the one pattern-search tool instead of falling back to
    # shell grep for non-tracked text. Default off keeps code search free of build noise.
    if _grep_bool(args, "no_ignore")
        push!(scan_flags, "--no-ignore"); push!(scan_flags, "--hidden")
    end
    globs = _grep_globs(args)
    for g in globs
        push!(scan_flags, "-g"); push!(scan_flags, g)
    end

    # Echo the normalized search inputs (glob + active flags) in the header, so a caller
    # sees WHAT was actually searched — a header of just `in src` hides whether a glob or
    # case-fold was applied, which turns a surprising result into a guessing game.
    echo = String[]
    isempty(globs) || push!(echo, "glob=[" * join((repr(g) for g in globs), ", ") * "]")
    _grep_bool(args, "ignore_case") && push!(echo, "ignore_case")
    _grep_bool(args, "word") && push!(echo, "word")
    _grep_bool(args, "fixed") && push!(echo, "fixed")
    _grep_bool(args, "no_ignore") && push!(echo, "no_ignore")
    header_extra = isempty(echo) ? "" : " · " * join(echo, " ")

    # `--stats` makes rg emit a `summary` (total matches) and per-file `end` counts, which
    # drive fair-share truncation. (`stats.searches` is NOT used for "files scanned" — some
    # rg builds report it as matched-files, so it reads 0 exactly on the empty case we need
    # it for; we count scope files with `rg --files` instead.)
    # `--` terminates flags so a pattern starting with `-` is taken literally.
    argv = String[rg...; "--json"; "--stats"; pat_flags...; scan_flags...; "--"; pattern; root]
    # Glob anchoring. ripgrep matches slash-containing globs (`src/**/*.jl`) against each
    # file's path RELATIVE TO rg's PROCESS CWD, not the positional search argument. We want
    # a `glob` to be written the SAME WAY as `path=`/`file=` — both project-root-relative —
    # so that `glob=['src/**/*.jl']` matches `<project>/src/…` whether or not `path` also
    # narrows the scan, and `path:"src"` + `glob:["src/…"]` doesn't double-anchor to
    # `src/src/…`. So run rg from the PROJECT ROOT (`base`): the positional `root` stays
    # absolute (rg still emits absolute paths → context reads + relative display unchanged),
    # but glob matching now resolves against the base-relative path. When the search root
    # sits OUTSIDE the bound project (a foreign absolute `path=`), anchor instead at that
    # path's OWN git repo root, so its globs stay repo-root-relative too (same `cd repo &&
    # rg` feel); only when there's no enclosing repo do we anchor at the root itself.
    rg_cwd = if !isempty(base) && _grep_path_within(root, [base])
        base
    else
        something(_grep_repo_root(root), isdir(root) ? root : dirname(root))
    end
    errbuf = IOBuffer()
    out = try
        read(pipeline(ignorestatus(Cmd(Cmd(argv); dir = rg_cwd)), stderr = errbuf), String)
    catch e
        return "Error running ripgrep: $(sprint(showerror, e))"
    end

    files_parsed, total, _ = _grep_parse_rg(out, limit)
    scope_label = root == base ? basename(rstrip(base, '/')) : _grep_relfile(root, base)
    if total == 0 || isempty(files_parsed)
        errtxt = strip(String(take!(errbuf)))
        isempty(errtxt) || return "Error: ripgrep — $(first(errtxt, 300))"
        # Self-evidencing empty: report how many files were in scope, so a true negative
        # (searched N files, found nothing) is distinguishable from a scoping mistake
        # (path=/glob= matched no files → nothing was searched).
        nscope = _grep_scope_file_count(rg, scan_flags, root, rg_cwd)
        note = nscope == 0 ? " (0 files in scope — check path=/glob=)" :
               " ($nscope file$(nscope == 1 ? "" : "s") in scope)"
        return "No matches for /$pattern/ in $scope_label$header_extra$note"
    end

    sem_windows = _grep_semantic_windows(query, _grep_collection(args, base))
    return _grep_format(pattern, scope_label, files_parsed, total, header_extra, base, query,
                        sem_windows, ctx_arg, limit)
end

# ── Anti-shell-grep nudge: the brain behind the agent PreToolUse hooks ─────────
#
# Instead of a per-machine detector script, each agent's PreToolUse(Bash) hook is a
# one-line `curl` that POSTs the tool-call JSON to `/hook/nudge?agent=<name>`; this is
# where the decision is made (Julia, hot-reloadable, one source of truth). It is a SOFT
# nudge — it only ever injects guidance, never blocks — and fails open: any parse error
# yields "no nudge" so a misread can't break the agent's shell call.

const _HOOK_GREP_PROGS = Set(["grep", "egrep", "fgrep", "rg", "ripgrep", "ag", "ack"])
const _HOOK_CODE_EXTS =
    Set(["jl", "ts", "tsx", "jsx", "py", "rs", "go", "c", "h", "cpp", "js", "md"])
const _HOOK_NUDGE_MSG =
    "You ran a shell code-search. Prefer Kaimon's MCP tools: grep_code(pattern=...) for an " *
    "exact pattern/regex (repo-scoped, .gitignore-aware, returns each hit's enclosing " *
    "function/struct), or search_code(query=...) for finding code by meaning. grep_code also " *
    "searches logs and generated/gitignored files with no_ignore=true — so it covers the same " *
    "ground as shell grep. Shell grep/find is only really needed to TRANSFORM matches (sed/awk) " *
    "or pipe them into another command."

# Is this shell command a code-search? Inspects each command segment at its program
# position (so `echo grep` / `x | grep` are judged by the actual program invoked), matching
# grep/rg/ag/ack or `find … -name '*.<codeext>'`. Best-effort tokenization — a soft nudge
# doesn't need a full shell parser.
# Quote-aware tokenization into simple-commands. Heredoc bodies are dropped first (they
# are data — commit messages, etc.), then the string is walked tracking quote state, so
# operators (&&, ||, |, ;, &) inside quotes are literal and quote characters are removed
# while their content is kept (a quoted `-name '*.jl'` arg survives intact). Returns
# (piped, tokens) per command, where `piped` is true when it's downstream of a `|`.
function _shell_commands(cmd::AbstractString)
    s = replace(String(cmd), r"<<-?\s*['\"]?(\w+)['\"]?[\s\S]*?\n[ \t]*\1\b" => "\n")
    chars = collect(s)
    n = length(chars)
    cmds = Tuple{Bool,Vector{String}}[]
    toks = String[]
    buf = Char[]
    q = '\0'
    piped = false
    endtok!() = (isempty(buf) || (push!(toks, String(buf)); empty!(buf)))
    endcmd!() = (endtok!(); isempty(toks) || (push!(cmds, (piped, copy(toks))); empty!(toks)))
    i = 1
    while i <= n
        ch = chars[i]
        if q != '\0'
            ch == q ? (q = '\0') : push!(buf, ch); i += 1
        elseif ch == '\'' || ch == '"' || ch == '`'
            q = ch; i += 1
        elseif ch == '&' && i < n && chars[i+1] == '&'
            endcmd!(); piped = false; i += 2
        elseif ch == '|' && i < n && chars[i+1] == '|'
            endcmd!(); piped = false; i += 2
        elseif ch == '|'
            endcmd!(); piped = true; i += 1
        elseif ch == ';' || ch == '&' || ch == '\n'
            endcmd!(); piped = false; i += 1
        elseif isspace(ch)
            endtok!(); i += 1
        else
            push!(buf, ch); i += 1
        end
    end
    endcmd!()
    return cmds
end

function _is_code_search(cmd::AbstractString)
    # A grep-family program searches the filesystem only when it's NOT reading piped
    # stdin: `grep foo src/`, `cd x && grep …`, `rg …` (searches cwd) qualify; `git
    # status | grep …` / `ps | grep …` (filtering a stream) do not. `find … -name
    # '*.<codeext>'` qualifies too.
    for (piped, toks) in _shell_commands(cmd)
        i = 1
        while i <= length(toks) && occursin(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[i])
            i += 1   # skip leading VAR=val env assignments
        end
        i <= length(toks) || continue
        prog = last(split(toks[i], '/'))   # basename
        if prog in _HOOK_GREP_PROGS
            piped && continue   # downstream of a pipe → filtering output, not a search
            return true
        end
        if prog == "find"
            for j = (i + 1):(length(toks) - 1)
                if toks[j] in ("-name", "-iname", "-path", "-ipath")
                    m = match(r"\.([A-Za-z0-9]+)$", toks[j + 1])
                    m !== nothing && lowercase(m.captures[1]) in _HOOK_CODE_EXTS && return true
                end
            end
        end
    end
    return false
end

# Pull a query-string parameter out of a request target (`/hook/nudge?agent=claude`).
function _hook_query_param(target::AbstractString, key::AbstractString, default::AbstractString)
    q = findfirst('?', target)
    q === nothing && return default
    for kv in split(SubString(target, q + 1), '&')
        parts = split(kv, '='; limit = 2)
        length(parts) == 2 && String(parts[1]) == key && return String(parts[2])
    end
    return default
end

# Extract the shell command from an agent's PreToolUse payload (Claude `tool_input.command`,
# else a top-level `command`). Returns nothing when absent.
function _hook_extract_command(payload::AbstractDict)
    ti = get(payload, "tool_input", nothing)
    if ti isa AbstractDict
        c = get(ti, "command", nothing)
        c isa AbstractString && return c
    end
    c = get(payload, "command", nothing)
    return c isa AbstractString ? c : nothing
end

# Per-agent PreToolUse decision JSON for a soft nudge (ALLOW + inject context). The Claude
# shape is implemented; other agents' decision shapes differ and are added as each is wired
# — default to the Claude shape for now.
function _hook_decision_json(agent::AbstractString)
    return JSON.json(Dict(
        "hookSpecificOutput" => Dict(
            "hookEventName" => "PreToolUse",
            "additionalContext" => _HOOK_NUDGE_MSG,
        ),
    ))
end

"""
    _hook_nudge_payload(target, body) -> String

Decide the nudge for a `/hook/nudge` request: parse the agent from the target query and
the tool command from the POST body, and return the per-agent decision JSON when the
command is a code-search — else "" (no nudge). Never throws (fails open).
"""
function _hook_nudge_payload(target::AbstractString, body::AbstractString)
    try
        payload = JSON.parse(body)
        payload isa AbstractDict || return ""
        cmd = _hook_extract_command(payload)
        (cmd === nothing || isempty(cmd) || !_is_code_search(cmd)) && return ""
        return _hook_decision_json(_hook_query_param(target, "agent", "claude"))
    catch
        return ""
    end
end

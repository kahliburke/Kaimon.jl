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

const _GREP_NO_PROJECT_MSG =
    "Error: no project is bound to your MCP session, so there's nothing to scope the " *
    "search to. This usually means your session hasn't reassociated with its project " *
    "after a Kaimon server restart. Pass an absolute `path=\"/abs/project\"` to scope " *
    "the search explicitly, or reconnect the session. (Refusing to default to the " *
    "server's own working directory, which would search the wrong repo.)"

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

# Resolve the search root + base (for relative display). `file`/`path` narrow the scan;
# both resolve relative to the bound project (or absolute). Returns (root, base, err).
# Both are canonical so rg's slash-globs anchor correctly (see `_grep_canon`).
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
    abs = isabspath(target) ? target : abspath(joinpath(base, target))
    ispath(abs) || return (nothing, base, "Error: path not found: $(target) (resolved to $abs)")
    return (_grep_canon(abs), base, nothing)
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
    # no_ignore: also search .gitignored + hidden files (logs, build/ output, generated,
    # dotfiles) — makes grep_code the one pattern-search tool instead of falling back to
    # shell grep for non-tracked text. Default off keeps code search free of build noise.
    if _grep_bool(args, "no_ignore")
        push!(flags, "--no-ignore"); push!(flags, "--hidden")
    end
    for g in _grep_globs(args)
        push!(flags, "-g"); push!(flags, g)
    end

    # `--` terminates flags so a pattern starting with `-` is taken literally.
    argv = String[rg...; "--json"; flags...; "--"; pattern; root]
    # ripgrep anchors slash-containing globs (`src/**/*.jl`) to the PROCESS CWD, not to
    # the search-path argument. This server is long-lived and its CWD is not the searched
    # repo, so without pinning rg's cwd to the root every `-g dir/…` glob silently matches
    # nothing — including this tool's own advertised `['src/**/*.jl']` example. Run rg from
    # the root (its containing dir when the root resolved to a single file).
    rg_cwd = isdir(root) ? root : dirname(root)
    errbuf = IOBuffer()
    out = try
        read(pipeline(ignorestatus(Cmd(Cmd(argv); dir = rg_cwd)), stderr = errbuf), String)
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

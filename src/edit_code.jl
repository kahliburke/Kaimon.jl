# ── edit_code: scoped bulk edit, validated before write, diff as the result ───
#
# The write-side counterpart to `grep_code`, and deliberately its mirror image:
# same scoping model (`path` / `file` / `glob`, .gitignore-aware, confined to the
# bound project), so you locate with one and change with the other without
# re-learning how scope works.
#
# Three properties a shell one-liner doesn't have, and the reasons this exists:
#   * every modified file is PARSED before anything is written, and one failure
#     aborts the whole batch — no half-applied edit to unpick
#   * the unified diff comes back as the tool RESULT, so the change is reviewable
#     in place instead of needing a follow-up `git diff`
#   * the contract is bounded ("edit files in this scope"), so it can be approved
#     once, unlike `python3 -c` which has to be re-authorized forever
#
# Files are enumerated with ripgrep, for its .gitignore handling, but matched and
# rewritten in Julia. One regex engine decides both what matches and what is
# replaced: rg's Rust dialect and PCRE disagree in enough corners that using rg to
# select and Julia to substitute would let a file be picked and then not edited.

const _EDIT_MAX_FILES = 50        # refuse a wider blast radius unless raised explicitly
const _EDIT_OUT_BUDGET = 12288    # ~12 KB of diff before truncation

const _RE_SPECIAL = Set(collect("\\^\$.|?*+()[]{}"))

function _edit_escape_re(s::AbstractString)
    io = IOBuffer()
    for c in s
        c in _RE_SPECIAL && print(io, '\\')
        print(io, c)
    end
    return String(take!(io))
end

# Build the matcher. `fixed` means the pattern is literal; it still has to become a
# regex when `word`/`ignore_case` are on, so escape it rather than refusing.
function _edit_regex(pattern::AbstractString, fixed::Bool, ignore_case::Bool, word::Bool)
    pat = fixed ? _edit_escape_re(pattern) : pattern
    word && (pat = "\\b(?:" * pat * ")\\b")
    try
        return Regex(pat, ignore_case ? "i" : "")
    catch e
        return "Error: invalid regex $(repr(pattern)) — $(sprint(showerror, e))"
    end
end

# Substitution. Under `fixed` the replacement must stay literal, so it goes in as a
# function (Julia treats a function replacement verbatim); otherwise a
# SubstitutionString so `\1` backrefs work as written.
_edit_sub(replacement::AbstractString, fixed::Bool) =
    fixed ? (_ -> replacement) : SubstitutionString(replacement)

# Apply to one file's content. Line-wise by default — the sed model, and what makes
# the diff exactly line-aligned. `multiline` switches to whole-content matching so a
# pattern can span lines, at the cost of a coarser diff.
#
# Note the anchoring consequence, which is the sed behaviour people expect: line-wise,
# each line is matched as its own string, so `^`/`$` mean line start/end. Under
# `multiline` they mean start/end of the file.
#
# Returns `(new_content, nmatches)`. The count is taken where the substitution actually
# happens — counting over the whole content instead would disagree with the line-wise
# result for exactly those anchored patterns.
function _edit_apply(content::AbstractString, rx::Regex, sub, multiline::Bool)
    if multiline
        return (replace(content, rx => sub), count(_ -> true, eachmatch(rx, content)))
    end
    ends_nl = endswith(content, '\n')
    lines = split(content, '\n')
    # A trailing newline leaves an empty final element; editing it would append junk.
    n = ends_nl ? length(lines) - 1 : length(lines)
    out = similar(lines)
    copyto!(out, lines)
    total = 0
    @inbounds for i in 1:n
        total += count(_ -> true, eachmatch(rx, lines[i]))
        out[i] = replace(lines[i], rx => sub)
    end
    return (join(out, '\n'), total)
end

# ── validation ────────────────────────────────────────────────────────────────

# `Meta.parseall` does not throw; it embeds `Expr(:error)` / `Expr(:incomplete)`
# nodes in the returned toplevel. Walk for those instead of trusting a try/catch.
function _edit_find_parse_error(x)
    x isa Expr || return nothing
    if x.head === :error || x.head === :incomplete
        isempty(x.args) && return "syntax error"
        a = first(x.args)
        # `string(::ParseError)` is the constructor repr, escapes and all. showerror
        # gives the caret diagnostic that actually locates the problem.
        return a isa Exception ? sprint(showerror, a) : string(a)
    end
    for a in x.args
        e = _edit_find_parse_error(a)
        e === nothing || return e
    end
    return nothing
end

"""
    _edit_validate(path, content) -> nothing | String

Reject content that would not survive being read back. Julia files must parse;
TOML must parse. Anything else is accepted — this guards against corrupting code,
not against a bad idea.
"""
function _edit_validate(path::AbstractString, content::AbstractString)
    ext = lowercase(splitext(path)[2])
    if ext == ".jl"
        parsed = try
            Meta.parseall(content; filename = path)
        catch e   # a throwing parser (older/newer frontends) still counts as invalid
            return sprint(showerror, e)
        end
        return _edit_find_parse_error(parsed)
    elseif ext == ".toml"
        try
            TOML.parse(content)
        catch e
            return sprint(showerror, e)
        end
        return nothing
    end
    return nothing
end

# ── unified diff ──────────────────────────────────────────────────────────────

function _edit_hunk_header(ostart, olen, nstart, nlen)
    "@@ -$(ostart),$(olen) +$(nstart),$(nlen) @@"
end

# Line-aligned case: old and new have equal length, so a changed index maps 1:1 and
# the hunks are exact without any LCS work.
function _edit_diff_aligned(old::Vector{<:AbstractString}, new::Vector{<:AbstractString}, ctx::Int)
    changed = [i for i in eachindex(old) if old[i] != new[i]]
    isempty(changed) && return String[]
    groups = Vector{UnitRange{Int}}()
    gs = changed[1]
    ge = changed[1]
    for i in changed[2:end]
        if i - ge <= 2ctx + 1
            ge = i
        else
            push!(groups, gs:ge)
            gs = ge = i
        end
    end
    push!(groups, gs:ge)

    out = String[]
    for g in groups
        lo = max(1, first(g) - ctx)
        hi = min(length(old), last(g) + ctx)
        push!(out, _edit_hunk_header(lo, hi - lo + 1, lo, hi - lo + 1))
        # A run of changed lines is emitted as all removals then all additions, the
        # conventional unified-diff grouping; interleaving them still parses but
        # reads badly and trips some patch tools.
        i = lo
        while i <= hi
            if old[i] == new[i]
                push!(out, " " * old[i])
                i += 1
            else
                j = i
                while j <= hi && old[j] != new[j]
                    j += 1
                end
                for k in i:(j-1)
                    push!(out, "-" * old[k])
                end
                for k in i:(j-1)
                    push!(out, "+" * new[k])
                end
                i = j
            end
        end
    end
    return out
end

# Whole-content case: lengths can differ, so trim the common prefix/suffix and emit
# the middle as one block. Not a minimal diff, but a correct one.
function _edit_diff_block(old::Vector{<:AbstractString}, new::Vector{<:AbstractString}, ctx::Int)
    p = 0
    while p < length(old) && p < length(new) && old[p+1] == new[p+1]
        p += 1
    end
    q = 0
    while q < length(old) - p && q < length(new) - p &&
          old[end-q] == new[end-q]
        q += 1
    end
    omid = (p+1):(length(old)-q)
    nmid = (p+1):(length(new)-q)
    (isempty(omid) && isempty(nmid)) && return String[]

    lo = max(1, p + 1 - ctx)
    out = String[_edit_hunk_header(lo, length(omid) + (p + 1 - lo), lo, length(nmid) + (p + 1 - lo))]
    for i in lo:p
        push!(out, " " * old[i])
    end
    for i in omid
        push!(out, "-" * old[i])
    end
    for i in nmid
        push!(out, "+" * new[i])
    end
    return out
end

function _edit_diff(rel::AbstractString, before::AbstractString, after::AbstractString,
                    multiline::Bool; ctx::Int = 3)
    old = split(before, '\n')
    new = split(after, '\n')
    body = (!multiline && length(old) == length(new)) ?
        _edit_diff_aligned(old, new, ctx) : _edit_diff_block(old, new, ctx)
    isempty(body) && return ""
    return join(vcat(["--- a/$rel", "+++ b/$rel"], body), '\n')
end

# ── file collection ───────────────────────────────────────────────────────────

# `rg --files` gives the same universe grep_code searches: .gitignore honored,
# globs applied, hidden files only with no_ignore.
function _edit_scope_files(rg::Vector{String}, scan_flags::Vector{String},
                           root::AbstractString, rg_cwd::AbstractString)
    isfile(root) && return String[root]
    argv = String[rg...; "--files"; scan_flags...; "--"; root]
    out = try
        read(pipeline(ignorestatus(Cmd(Cmd(argv); dir = rg_cwd)), stderr = devnull), String)
    catch
        return String[]
    end
    return String[String(l) for l in split(out, '\n') if !isempty(l)]
end

# Read as text, or `nothing` for anything binary — a NUL byte or invalid UTF-8 means
# a regex edit would corrupt it.
function _edit_read_text(path::AbstractString)
    bytes = try
        read(path)
    catch
        return nothing
    end
    (0x00 in bytes) && return nothing
    s = String(bytes)
    isvalid(s) || return nothing
    return s
end

# Same-directory temp + rename, so a reader never sees a partially written file.
function _edit_write_atomic(path::AbstractString, content::AbstractString)
    dir = dirname(path)
    tmp, io = mktemp(isempty(dir) ? pwd() : dir)
    try
        write(io, content)
        close(io)
        mv(tmp, path; force = true)
    catch e
        close(io)
        rm(tmp; force = true)
        rethrow(e)
    end
    return nothing
end

# ── handler ───────────────────────────────────────────────────────────────────

function _edit_code(args)
    pattern = String(get(args, "pattern", ""))
    isempty(pattern) && return "Error: pattern is required"
    haskey(args, "replacement") || return "Error: replacement is required (use \"\" to delete matches)"
    replacement = String(get(args, "replacement", ""))

    rg = _rg_argv()
    rg === nothing && return "Error: ripgrep (rg) is not available. Install it, or add ripgrep_jll."

    root, base, err = _grep_resolve_root(args)
    root === nothing && return err
    scope_err = _grep_enforce_scope(root)
    scope_err === nothing || return scope_err

    fixed = _grep_bool(args, "fixed")
    ignore_case = _grep_bool(args, "ignore_case")
    word = _grep_bool(args, "word")
    multiline = _grep_bool(args, "multiline")
    dry_run = _grep_bool(args, "dry_run")
    max_files = Int(get(args, "max_files", _EDIT_MAX_FILES))

    rx = _edit_regex(pattern, fixed, ignore_case, word)
    rx isa Regex || return rx           # error string from the compiler
    sub = _edit_sub(replacement, fixed)

    scan_flags = String[]
    if _grep_bool(args, "no_ignore")
        push!(scan_flags, "--no-ignore")
        push!(scan_flags, "--hidden")
    end
    for g in _grep_globs(args)
        push!(scan_flags, "-g")
        push!(scan_flags, g)
    end

    # Glob anchoring matches grep_code: run rg from the project root so a slash-glob
    # is project-relative, not relative to `path`.
    rg_cwd = if !isempty(base) && _grep_path_within(root, [base])
        base
    else
        something(_grep_repo_root(root), isdir(root) ? root : dirname(root))
    end

    candidates = _edit_scope_files(rg, scan_flags, root, rg_cwd)
    isempty(candidates) && return "No files in scope. (Check `path`/`glob`; add no_ignore=true for gitignored files.)"

    # Pass 1 — compute every edit and validate it. Nothing is written in this pass,
    # so a syntax error anywhere means the tree is still untouched.
    # (path, rel, before, after, nmatches) — `before` is retained because after the
    # write the file no longer holds it, and it is what the diff is against.
    edits = Tuple{String,String,String,String,Int}[]
    failures = String[]
    for f in candidates
        content = _edit_read_text(f)
        content === nothing && continue
        occursin(rx, content) || continue
        new_content, nmatches = _edit_apply(content, rx, sub, multiline)
        new_content == content && continue
        # Display relative to the glob anchor, not the bound project: when the scope
        # lies outside the project, the project prefix doesn't apply and paths would
        # render absolute.
        rel = _grep_relfile(f, rg_cwd)
        verr = _edit_validate(f, new_content)
        if verr === nothing
            push!(edits, (f, rel, content, new_content, nmatches))
        else
            detail = join(("      " * l for l in split(rstrip(verr), '\n')), '\n')
            push!(failures, "  $rel\n$(first(detail, 400))")
        end
    end

    isempty(edits) && isempty(failures) &&
        return "No matches for $(repr(pattern)) in $(length(candidates)) file(s) in scope. Nothing written."

    # One bad file aborts everything. A partially applied bulk edit is the outcome
    # this tool exists to prevent, so it is never traded for partial progress.
    if !isempty(failures)
        shown = first(failures, 5)
        more = length(failures) - length(shown)
        return string(
            "Aborted — nothing written. $(length(failures)) file(s) would not parse after the edit:\n",
            join(shown, "\n"),
            more > 0 ? "\n  … and $more more" : "",
            "\n\n($(length(edits)) other file(s) would have changed. Refine the pattern, or use ",
            "dry_run=true to inspect.)",
        )
    end

    if length(edits) > max_files
        return "Refusing to edit $(length(edits)) files (max_files=$max_files). " *
               "Narrow the scope with path=/glob=, or raise max_files deliberately."
    end

    # Pass 2 — write. Validation is done, so this is the only place anything changes.
    written = 0
    if !dry_run
        for (f, rel, _, new_content, _) in edits
            try
                _edit_write_atomic(f, new_content)
                written += 1
            catch e
                return "Wrote $written file(s), then failed on $rel: $(sprint(showerror, e))"
            end
        end
    end

    total = sum(e[5] for e in edits)
    head = dry_run ?
        "Dry run — nothing written. $total replacement(s) would change $(length(edits)) file(s):" :
        "$total replacement(s) in $(length(edits)) file(s):"

    io = IOBuffer()
    println(io, head)
    truncated = 0
    for (_, rel, before, after, _) in edits
        d = _edit_diff(rel, before, after, multiline)
        isempty(d) && continue
        if position(io) + sizeof(d) > _EDIT_OUT_BUDGET
            truncated += 1
            continue
        end
        println(io, "\n", d)
    end
    truncated > 0 && println(io, "\n… and $truncated more file(s) not shown (diff budget).")
    return String(take!(io))
end

# ── tool definition ───────────────────────────────────────────────────────────

const _EDIT_CODE_PARAMS = Dict(
    "type" => "object",
    "properties" => Dict(
        "pattern" => Dict(
            "type" => "string",
            "description" => "Regex to match (or a literal string with fixed=true). Same dialect you'd pass to grep_code, but matched by Julia's engine — see `multiline` for how it's applied.",
        ),
        "replacement" => Dict(
            "type" => "string",
            "description" => "Text to substitute. Supports `\\1`, `\\2`… backreferences unless fixed=true, in which case it is inserted literally. Pass \"\" to delete matches.",
        ),
        "path" => Dict(
            "type" => "string",
            "description" => "Directory or file to edit, relative to the bound project or absolute (default: the bound project root). Narrow it — the default scope is the whole repo.",
        ),
        "file" => Dict(
            "type" => "string",
            "description" => "Edit a single file (relative to the bound project or absolute).",
        ),
        "glob" => Dict(
            "type" => "array",
            "items" => Dict("type" => "string"),
            "description" => "Include-only globs in ripgrep syntax, e.g. ['src/**/*.jl', '!**/test/**']. Anchored to the PROJECT ROOT, exactly as in grep_code — don't repeat a `path=` prefix inside the glob. A glob with no `/` matches that basename at any depth.",
        ),
        "multiline" => Dict(
            "type" => "boolean",
            "description" => "Match against whole file content rather than line by line (default: false). Leave it off unless the pattern must span lines — line-wise matching is the sed model and yields an exactly line-aligned diff.",
        ),
        "dry_run" => Dict(
            "type" => "boolean",
            "description" => "Compute and return the diff without writing (default: false). The normal path already returns the diff, so reach for this only when the pattern is untrusted.",
        ),
        "max_files" => Dict(
            "type" => "integer",
            "description" => "Refuse the batch if it would touch more than this many files (default: 50). A guard against a pattern that is broader than intended.",
        ),
        "ignore_case" => Dict("type" => "boolean", "description" => "Case-insensitive match (default: false)."),
        "word" => Dict("type" => "boolean", "description" => "Match whole words only (default: false). Worth setting for identifier renames."),
        "fixed" => Dict("type" => "boolean", "description" => "Treat pattern AND replacement as literal text, not regex (default: false)."),
        "no_ignore" => Dict("type" => "boolean", "description" => "Also edit .gitignored and hidden files (default: false)."),
    ),
    "required" => ["pattern", "replacement"],
)

edit_code_tool = @mcp_tool(
    :edit_code,
    "Apply a find-and-replace across files, validated before anything is written, returning the unified diff. This is the write-side counterpart to `grep_code` and the right tool for any multi-file mechanical change — a rename, a signature update, retiring a deprecated call — instead of a shell/python one-liner or a run of one-file-at-a-time edits. Scoping is identical to grep_code (`path`/`file`/`glob`, project-root-anchored, .gitignore-aware, confined to the bound project), so you can locate with grep_code and change with the same arguments. Every modified .jl is PARSED and every .toml checked before the first write, and any failure aborts the entire batch untouched — a partially applied edit is never a possible outcome. Matching is line-wise by default (the sed model); set multiline=true only when the pattern must span lines. Writes are atomic per file and the result is the diff itself, so the change is reviewable without a follow-up `git diff`. Use fixed=true for literal text, word=true for identifier renames. Note it edits TEXT, not syntax: a pattern will match inside strings, comments and docstrings too, so prefer word=true and a narrow `glob` over a broad pattern.",
    _EDIT_CODE_PARAMS,
    args -> _edit_code(args),
)

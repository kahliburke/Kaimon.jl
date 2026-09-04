# ── rename_symbol: identifier-aware rename, on the lexer rather than on text ──
#
# `edit_code`'s one structural weakness is that it edits TEXT: a pattern matches inside
# strings, comments and docstrings as happily as in code, so a rename has to be scoped
# carefully and read back. This is the answer to that, for the specific case that is worth
# doing properly — renaming a symbol.
#
# It works off JuliaSyntax's token stream rather than a regex. The lexer has already made
# exactly the distinction a regex cannot:
#
#   foo(1)                # `foo` here      → Identifier   → renamed
#   # foo in a comment                      → Comment      → untouched
#   "plain foo here"                        → String       → untouched
#   \"\"\"docstring … foo\"\"\"                     → String       → untouched
#   "interp $foo here"                      → Identifier   → renamed (a real reference)
#   Val{:foo}                               → Identifier   → renamed
#   @foo x                                  → MacroName    → only with macros=true
#
# What it is NOT: scope-aware. It renames every identifier token with that exact name in
# scope, so an unrelated local named `foo` in another function is renamed too. Real
# scope resolution needs binding analysis, which is a much larger job; token-level already
# removes the entire class of error people actually hit with a regex rename.
#
# Everything downstream — validation, all-or-nothing batching, atomic writes, the returned
# diff — is shared with edit_code.

# Base vendors JuliaSyntax as its own parser, so this needs no dependency and is guaranteed
# to agree with the `Meta.parseall` check that validates the result. The trade is that it's
# Base-internal rather than public API: the surface used here is small on purpose —
# `tokenize`, `kind`, the `K"…"` kinds, and `Token.range` — and the tests pin every one of
# them, so a change under a future Julia fails loudly here rather than silently renaming the
# wrong thing. Compat is `julia = "1.12"`.
const _JS = Base.JuliaSyntax

# Byte ranges of identifier tokens whose text is exactly `name`, in ascending order.
# Compared over code units so a multi-byte source (identifiers may be non-ASCII) can't
# produce an invalid string index.
function _rename_ranges(src::AbstractString, name::AbstractString, macros::Bool)
    out = UnitRange{Int}[]
    cu = codeunits(src)
    target = codeunits(name)
    for t in _JS.tokenize(src)
        k = _JS.kind(t)
        (k === _JS.K"Identifier" || (macros && k === _JS.K"MacroName")) || continue
        r = Int(first(t.range)):Int(last(t.range))
        (checkbounds(Bool, cu, r) && length(r) == length(target)) || continue
        view(cu, r) == target || continue
        push!(out, r)
    end
    return out
end

# Splice the replacements in one forward pass. Ranges arrive ascending and never overlap,
# so everything outside them is copied through byte-for-byte — comments, spacing and string
# contents are preserved exactly, which is the point of editing at this level.
function _rename_apply(src::AbstractString, ranges::Vector{UnitRange{Int}}, new_name::AbstractString)
    isempty(ranges) && return src
    cu = codeunits(src)
    io = IOBuffer()
    prev = 1
    for r in ranges
        write(io, view(cu, prev:(first(r)-1)))
        write(io, new_name)
        prev = last(r) + 1
    end
    write(io, view(cu, prev:length(cu)))
    return String(take!(io))
end

function _rename_symbol(args)
    old_name = String(get(args, "old_name", ""))
    new_name = String(get(args, "new_name", ""))
    isempty(old_name) && return "Error: old_name is required"
    isempty(new_name) && return "Error: new_name is required"
    Base.isidentifier(old_name) ||
        return "Error: old_name $(repr(old_name)) is not a Julia identifier. For arbitrary text use edit_code."
    Base.isidentifier(new_name) ||
        return "Error: new_name $(repr(new_name)) is not a Julia identifier — the result would not parse."
    old_name == new_name && return "Error: old_name and new_name are the same."

    rg = _rg_argv()
    rg === nothing && return "Error: ripgrep (rg) is not available. Install it, or add ripgrep_jll."

    root, base, err = _grep_resolve_root(args)
    root === nothing && return err
    scope_err = _grep_enforce_scope(root)
    scope_err === nothing || return scope_err

    macros = _grep_bool(args, "macros")
    dry_run = _grep_bool(args, "dry_run")
    max_files = Int(get(args, "max_files", _EDIT_MAX_FILES))

    scan_flags = String[]
    if _grep_bool(args, "no_ignore")
        push!(scan_flags, "--no-ignore")
        push!(scan_flags, "--hidden")
    end
    for g in _grep_globs(args)
        push!(scan_flags, "-g")
        push!(scan_flags, g)
    end

    rg_cwd = if !isempty(base) && _grep_path_within(root, [base])
        base
    else
        something(_grep_repo_root(root), isdir(root) ? root : dirname(root))
    end

    candidates = filter(f -> lowercase(splitext(f)[2]) == ".jl",
                        _edit_scope_files(rg, scan_flags, root, rg_cwd))
    isempty(candidates) &&
        return "No .jl files in scope. (rename_symbol only edits Julia source; use edit_code for anything else.)"

    edits = Tuple{String,String,String,String,Int}[]   # (path, rel, before, after, count)
    failures = String[]
    skipped = String[]
    for f in candidates
        content = _edit_read_text(f)
        content === nothing && continue
        # A file that ALREADY fails to parse is skipped rather than failed: the lexer will
        # still hand back tokens, so we'd rename happily and then blame our own edit for
        # breakage that was there beforehand.
        if _edit_validate(f, content) !== nothing
            occursin(old_name, content) && push!(skipped, _grep_relfile(f, rg_cwd))
            continue
        end
        ranges = _rename_ranges(content, old_name, macros)
        isempty(ranges) && continue
        new_content = _rename_apply(content, ranges, new_name)
        new_content == content && continue
        rel = _grep_relfile(f, rg_cwd)
        verr = _edit_validate(f, new_content)
        if verr === nothing
            push!(edits, (f, rel, content, new_content, length(ranges)))
        else
            detail = join(("      " * l for l in split(rstrip(verr), '\n')), '\n')
            push!(failures, "  $rel\n$(first(detail, 400))")
        end
    end

    note = isempty(skipped) ? "" :
        "\n\nSkipped $(length(skipped)) file(s) that already fail to parse: " *
        join(first(skipped, 5), ", ") * (length(skipped) > 5 ? ", …" : "")

    if isempty(edits) && isempty(failures)
        return "No identifier `$old_name` in $(length(candidates)) .jl file(s) in scope. " *
               "Nothing written. (Occurrences in comments and string literals are not renamed" *
               (macros ? "" : "; pass macros=true to include @$old_name") * ".)" * note
    end

    if !isempty(failures)
        shown = first(failures, 5)
        more = length(failures) - length(shown)
        return string(
            "Aborted — nothing written. $(length(failures)) file(s) would not parse after the rename:\n",
            join(shown, "\n"),
            more > 0 ? "\n  … and $more more" : "",
            "\n\n($(length(edits)) other file(s) would have changed.)", note,
        )
    end

    if length(edits) > max_files
        return "Refusing to rename across $(length(edits)) files (max_files=$max_files). " *
               "Narrow the scope with path=/glob=, or raise max_files deliberately." * note
    end

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
        "Dry run — nothing written. `$old_name` → `$new_name`: $total occurrence(s) in $(length(edits)) file(s):" :
        "`$old_name` → `$new_name`: $total occurrence(s) in $(length(edits)) file(s):"

    io = IOBuffer()
    println(io, head)
    truncated = 0
    for (_, rel, before, after, _) in edits
        d = _edit_diff(rel, before, after, false)
        isempty(d) && continue
        if position(io) + sizeof(d) > _EDIT_OUT_BUDGET
            truncated += 1
            continue
        end
        println(io, "\n", d)
    end
    truncated > 0 && println(io, "\n… and $truncated more file(s) not shown (diff budget).")
    isempty(note) || print(io, note)
    return String(take!(io))
end

# ── tool definition ───────────────────────────────────────────────────────────

const _RENAME_SYMBOL_PARAMS = Dict(
    "type" => "object",
    "properties" => Dict(
        "old_name" => Dict(
            "type" => "string",
            "description" => "The identifier to rename. Must be a valid Julia identifier — for arbitrary text use edit_code.",
        ),
        "new_name" => Dict(
            "type" => "string",
            "description" => "The replacement identifier. Rejected if it isn't a valid Julia identifier, since the result could not parse.",
        ),
        "path" => Dict(
            "type" => "string",
            "description" => "Directory or file to rename within, relative to the bound project or absolute (default: the bound project root).",
        ),
        "file" => Dict(
            "type" => "string",
            "description" => "Rename within a single file (relative to the bound project or absolute).",
        ),
        "glob" => Dict(
            "type" => "array",
            "items" => Dict("type" => "string"),
            "description" => "Include-only globs in ripgrep syntax, anchored to the PROJECT ROOT exactly as in grep_code.",
        ),
        "macros" => Dict(
            "type" => "boolean",
            "description" => "Also rename the macro form `@old_name` (default: false). Off by default because a function and a macro of the same name are usually unrelated.",
        ),
        "dry_run" => Dict(
            "type" => "boolean",
            "description" => "Compute and return the diff without writing (default: false).",
        ),
        "max_files" => Dict(
            "type" => "integer",
            "description" => "Refuse the rename if it would touch more than this many files (default: 50).",
        ),
        "no_ignore" => Dict(
            "type" => "boolean",
            "description" => "Also rename in .gitignored and hidden files (default: false).",
        ),
    ),
    "required" => ["old_name", "new_name"],
)

rename_symbol_tool = @mcp_tool(
    :rename_symbol,
    "Rename a Julia identifier across files, matching on the PARSED token stream rather than on text. Prefer this over edit_code (and far over a shell one-liner) for any symbol rename: it renames identifier tokens only, so occurrences inside comments, string literals and docstrings are left alone, while a genuine reference such as an interpolated `\$name` inside a string IS renamed — a distinction no regex can make. Everything outside the renamed tokens is preserved byte-for-byte. Scoping matches grep_code (`path`/`file`/`glob`, project-root-anchored, .gitignore-aware); .jl files only. Every file is parsed before and after, a file that already fails to parse is skipped rather than blamed, one failure aborts the whole batch untouched, and the unified diff is returned as the result. `new_name` must be a valid identifier or the call is refused. NOT scope-aware: an unrelated local of the same name in another function is renamed too, so scope with `path`/`glob` and read the diff. Set macros=true to also rename `@old_name`.",
    _RENAME_SYMBOL_PARAMS,
    args -> _rename_symbol(args),
)

# grep_code

Find an **exact pattern** in code — a better grep than grep. It runs a real regex over
the **live working tree** (`.gitignore`-aware, no stale index), scoped to your bound
project by default, and returns `file:line` **with the enclosing function/struct** for
every hit. Prefer it over shell `grep`/`rg`/`find` for code: those miss the enclosing
symbol, aren't repo-scoped, and don't rank by relevance.

## grep_code vs search_code

- **`grep_code`** — you have an exact symbol, string, or regex (a name, a call site, a
  `TODO`). You want *every* occurrence, exactly.
- **`search_code`** — you can describe *what the code does* but not its exact name. Finds
  by meaning, ranked semantically.

## Pattern

`pattern` is a standard regex (PCRE-ish, via ripgrep). Examples:

| pattern | finds |
|---|---|
| `_eval_with_capture` | every occurrence of that identifier |
| `function\s+set_\w+` | function definitions named `set_…` |
| `TODO\|FIXME` | either word |
| `@\w+macro` | a macro-call shape |

Flags:

- `fixed=true` — treat `pattern` as a **literal** string, not a regex (no escaping).
- `word=true` — whole-word match only (ripgrep `-w`).
- `ignore_case=true` — case-insensitive.

## Scope

Defaults to your **bound session's project** (same per-agent binding `search_code` uses).
Narrow it:

- `path="src/server"` — a subdirectory (relative to the project, or absolute).
- `file="src/bind.jl"` — a single file (the common "grep one file to locate a function").
- `glob=["src/**/*.jl", "!**/test/**"]` — ripgrep include/exclude globs, repeatable.

## Semantic-assisted ranking + adaptive context (optional `query`)

Pass a natural-language `query` alongside `pattern` to say *what you're actually after*.
Then:

- the files that matched are **ranked by semantic relevance** to the query (most relevant
  first) instead of directory order, and
- hits that fall inside a semantically-relevant region get a few lines of **surrounding
  context** automatically; everything else stays tight to one line (saves tokens).

`collection` picks the collection used for that ranking (defaults to the scope project's).
`context=N` forces N context lines on **every** hit regardless of `query`.

## Output

Hits are grouped by file (relevance-ranked when `query` is set). Each line shows
`L<n>  <enclosing symbol>  <matched line>` with the match **bolded**; expanded hits show
the `▸` marker on the match line and plain context around it. `limit` caps the number of
matches (default 40; more are reported as truncated).

## Examples

```julia
grep_code(pattern="_eval_with_capture")                       # every occurrence in the bound project
grep_code(pattern="function\\s+set_\\w+", glob=["src/**/*.jl"])  # def sites, scoped by glob
grep_code(pattern="assign_bind!", file="src/bind.jl")         # locate it in one file
grep_code(pattern="TODO|FIXME", word=true)                    # loose ends
grep_code(pattern="set_bind", query="apply a browser value change to a cell")  # rank + context
grep_code(pattern="error", path="src/server", fixed=true, ignore_case=true)    # literal, case-insensitive
```

> Looking for code by *meaning* (a concept you can't name)? Use `search_code` instead.

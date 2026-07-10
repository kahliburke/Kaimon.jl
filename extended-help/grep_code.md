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
- `no_ignore=true` — also search `.gitignore`d and hidden files (see below).

## Scope

Defaults to your **bound session's project** (same per-agent binding `search_code` uses).
If you're driving from a REPL that isn't bound to the repo you mean — or an agent whose
session isn't that project — pass an absolute `path=`/`file=`, or point at the right repo
first. Narrow it:

- `path="src/server"` — a subdirectory (relative to the project, or absolute).
- `file="src/bind.jl"` — a single file (the common "grep one file to locate a function").
- `glob=["src/**/*.jl", "!**/test/**"]` — ripgrep include/exclude globs, repeatable.

### Globs are project-root-relative — write them like `path=`/`file=`

`path=` and `file=` resolve **relative to the project root**, and so do `glob=` patterns.
A `glob` is anchored to the **repo root**, exactly as if you had `cd`'d into the repo and
run `rg -g '<glob>'` — *not* relative to `path=`. Two consequences:

- **Don't repeat a `path=` prefix inside the glob.** `path="src"` already narrows the scan
  to `src/`; a glob is still written from the repo root. `path="src"` + `glob=["src/**/*.jl"]`
  is correct (both project-relative — no double-anchor). The old footgun — `path="src"`
  double-anchoring the glob to `src/src/…` and silently matching nothing — is gone.
- **A glob with no `/` matches that basename at any depth.** `glob=["worker.jl"]` finds
  `worker.jl` anywhere; `glob=["*.jl"]` finds every `.jl` file. Use a bare basename when you
  don't care where the file lives; use a slash-glob (`src/**/*.jl`) to anchor by path.

```julia
grep_code(pattern="memo", glob=["src/**/*.jl"])              # every .jl under src/, from the repo root
grep_code(pattern="memo", path="src", glob=["**/*.jl"])     # scan src/ only; glob need not repeat "src/"
grep_code(pattern="memo", glob=["worker.jl"])               # this basename, wherever it lives
```

## Logs, generated, and gitignored files (`no_ignore`)

By default `grep_code` respects `.gitignore` (so code search isn't drowned in `build/`,
`node_modules/`, etc.). Pass `no_ignore=true` to also search **gitignored and hidden
files** — logs, build/generated output, dotfiles. Non-code files still match (it's
ripgrep over any text); they just show `file:line + the matched line` with no enclosing
symbol (a log has none). This means `grep_code` covers the same ground as shell `grep`:
reach for the shell only when you need to *transform* matches (`sed`/`awk`) or pipe them
into another command.

```julia
grep_code(pattern="ERROR|panic", path="logs", no_ignore=true)   # grep the logs
grep_code(pattern="TODO", no_ignore=true)                       # incl. generated/ignored
```

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
`L<n>  <enclosing symbol>  <matched line>`, and the matched line is **verbatim** — no inline
markers (they split identifiers and cost exact-string fidelity; the human-facing TUI
re-highlights at render time instead). The enclosing-symbol column is omitted when the hit
is on the definition's own line (it would just repeat the line). Expanded hits show a `▸`
marker on the match line with plain context around it.

The header echoes the normalized inputs — `🔎 /pattern/ in <scope> · glob=[…] ignore_case` —
so you can see *what* was actually searched.

**Fair-share truncation.** `limit` is a budget of match lines (default 20), and it's split
across files by max-min *water-filling*, not depth-first: every matching file stays visible,
each getting `min(its matches, fair share)` with the slack flowing to the bigger files.
Depth is sacrificed before breadth — losing lines in one file is recoverable (narrow and
re-query), a whole file vanishing is not. When a file is clipped its header says
`path (showing X of N)`, and the global header says `T matches in F files, showing S`. Files
past a display cap collapse into one honest stub: `…and K more files (M matches not shown)`.
A single-file / `file=` scope degrades naturally to first-`limit`.

**Self-evidencing empties.** No match reports how much was searched —
`No matches for /pat/ in src (94 files in scope)` — so a true negative is distinguishable
from a scoping mistake, which instead reads `(0 files in scope — check path=/glob=)`.

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

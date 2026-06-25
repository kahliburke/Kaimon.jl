# search_code

Find code by **meaning** — prefer it (and its exact-pattern sibling `grep_code`) over
shell grep/find. Semantic (vector) search is the primary signal, lightly boosted by
exact keyword matches; results come back ranked by relevance.

## search_code vs grep_code

- **`search_code`** — you can describe *what the code does* but not its exact name.
- **`grep_code`** — you have an exact symbol, string, or regex. It runs a true regex
  over the live working tree and returns each hit's enclosing function. This is the
  right replacement for "find every call site of `_eval_with_capture`" — which used to
  be a `mode="lexical"` search here.

## Just describe what you want

Semantic-first means a **natural-language phrase is good, not bad** — you don't need to
boil it down to a few keywords or ration common words. Say what the code does:

- Concept / behaviour → a short phrase: `"where is HTTP routing handled"`,
  `"apply a browser value change to a cell"`. (default `hybrid`, or `mode="semantic"`.)
- An exact symbol you can name → reach for `grep_code(pattern="…")`; or stay here with
  `mode="lexical"` if you want semantic neighbours ranked alongside the exact hits.

> Good (concept): `search_code(query="apply a browser value change to a cell")`
> Good (concept): `search_code(query="recompute reactive cells when a dependency changes")`
> Exact symbol:   `grep_code(pattern="_eval_with_capture")`

## Scope to a collection

Search is scoped to one collection (project). It defaults to the last-used session's
project; pass `collection="name"` for another. A scoped search is far cheaper than
`cross_project=true`, which fans out over every indexed project — use cross-project
only when you genuinely don't know which project holds the code.

## Modes

- `mode="hybrid"` (default) — semantic + lexical, fused and ranked. Good default when
  unsure; still keep the query focused.
- `mode="semantic"` — vector search only (concept/behavior queries).
- `mode="lexical"` — exact keyword/identifier only; works even when embeddings
  (Ollama) are unavailable. (For pure exact-symbol/pattern hunts, `grep_code` is
  usually the better tool — it's repo-scoped and shows the enclosing function.)

## Output format

- `format="text"` (default) — a ranked, human-readable list: relevance score, a
  source glyph (≈ semantic / ⚡ lexical / ⚯ both / ⊂ substring), `file:Lstart-end`,
  the signature, then the matched source line(s) with their **absolute line numbers**
  (`L372  …`, grep-style, query terms in bold). Read this yourself. (Semantic-only
  hits whose terms aren't literally in the text fall back to a short preview.)
- `format="structured"` — a **JSON array of hit objects** instead of prose, for
  programmatic use (parse it, jump to `file:line`, dedupe, post-process, or feed it
  to another tool). One object per result:

  ```json
  [{"point_id":"…","name":"_toggle_ext_field!","file":"…/extensions.jl",
    "type":"function","start_line":637,"end_line":645,"text":"…full chunk…",
    "snippet":"…matched span with highlight marks…","sources":["lexical","substr"],
    "score":0.051}]
  ```

  `score` is the fused RRF score (higher = better, relative within the result set);
  `sources` is which halves matched (`semantic`/`lexical`/`substr`); `snippet`
  carries `\x02`/`\x03` highlight marks around the matched span. Works with any
  `mode` — e.g. `search_code(query="…", mode="lexical", format="structured")` for
  structured exact-symbol hits.

## Query syntax (lexical half)

**Just type the symbols.** Julia punctuation is handled automatically — you do not
need to escape or quote anything for the common cases.

| You type | What runs | Why |
|----------|-----------|-----|
| `agent_add_cell! guard_commit` | `"agent_add_cell!" OR guard_commit` | bare terms are OR-joined (find any), ranked |
| `push!` | `"push!"` | punctuation attached to a word → matched literally |
| `@view` / `Base.foo` | `"@view"` / `"Base.foo"` | macros and dotted names matched literally |
| `one! two` | `"one!" OR two` | the `!` is part of `one!` |
| `one ! two` | `one NOT two` | a **standalone** `!` is the NOT operator |

### Rules

- **Multiple bare terms → OR** (any-of) on the lexical half, ranked so chunks matching
  more/better terms float up. This half is a *light boost* on top of semantic now, so
  you don't need to ration keywords — describe what you want and let meaning lead.
- **Attached punctuation** (`push!`, `sort!`, `@view`, `Base.push!`, `foo?`) is quoted
  for you and matched literally — never a syntax error.
- **Full-word operators** `AND` / `OR` / `NOT` / `NEAR` (any case) are honored as
  operators: `commit AND floor`, `token NOT renew`. Use `AND` to *intersect* (narrow)
  instead of OR-ing when you have two terms that must co-occur.
- **Standalone punctuation** acts as an operator: `!` → NOT, `&&`/`&` → AND, `||`/`|`
  → OR. (`one ! two` ⇒ `one NOT two`.)
- **`"exact phrase"`** — double-quote to match an exact token sequence.
- **`prefix*`** — trailing `*` on a clean term does prefix matching (`agent_*`).

If a query still can't be parsed as FTS5 (e.g. unbalanced quotes), it's searched as a
single literal phrase and a ⚠ note is returned explaining why.

> Note: substring (trigram) matching — finding a fragment *inside* an identifier, e.g.
> `ApplyPower` inside `onApplyPowerActions` — runs only for a **single, short
> identifier-ish token**. It is deliberately not run for multi-word queries (a phrase
> would scan the whole index). To find a fragment, search the fragment alone.

## Other arguments

- `collection` — defaults to the last-used session's project.
- `cross_project=true` — search ALL indexed projects at once (ignores `collection`).
  Slower; use only when you don't know the project.
- `chunk_type` — `"definitions"` (functions/structs), `"windows"` (sliding windows),
  or `"all"` (default).
- `limit` — max results (default 5).
- `embedding_model` — Ollama model for the semantic half.

## Examples

```julia
search_code(query="function that handles HTTP routing")          # concept (default hybrid)
search_code(query="apply a browser value change to a cell")      # behaviour, full phrase
search_code(query="commit AND floor")                            # intersect two required terms (lexical half)
search_code(query="render output to HTML", collection="kaimonslate")  # scope to a project
search_code(query="how dependency cycles are detected", cross_project=true)  # only when unknown
# Exact symbol or pattern? Use grep_code instead:
grep_code(pattern="_eval_with_capture")                          # every call site, with enclosing fn
```

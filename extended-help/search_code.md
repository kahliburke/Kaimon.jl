# search_code

The primary way to find code — prefer it over grep/find. It fuses **semantic**
(meaning-based vector) search with **lexical** (exact keyword/identifier) search,
ranks them together, and returns the best hits. Finds exact identifiers too, so you
don't need grep for symbol lookups.

## Pick the mode for your intent — then keep the query focused

Two kinds of search; choose deliberately:

- **You know the symbol** (a function/type name or a distinctive fragment of one) →
  `mode="lexical"`, and type **1–3 distinctive identifiers**. Fast, exact, and works
  with embeddings down. This is the right tool for "find `atStartOfTurn`" or "where
  is `onApplyPower` defined", and the right answer for hunting symbols in a large
  decompiled / generated codebase.
- **You know the concept, not the name** ("where is HTTP routing handled") →
  `mode="semantic"` (or the default `hybrid`), with a **short natural-language
  phrase** — a handful of meaningful words.

**Do NOT dump a sentence of keywords.** A long bag of words is the #1 cause of slow,
imprecise searches: bare terms are OR-joined, so common words (`parse`, `method`,
`body`, `value`, `data`) each drag in an enormous match set the engine must merge and
rank. Pick the few distinctive terms that actually identify what you want. The tool
caps the OR fan-out and returns a `⚠` note if you over-stuff a query — heed it and
narrow.

> Bad: `transform power parse STS1 power java method body atStartOfTurn onApplyPower actions`
> Good (symbol hunt): `search_code(query="atStartOfTurn onApplyPower", mode="lexical")`
> Good (concept):     `search_code(query="apply power on turn start")`

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
  (Ollama) are unavailable. Best for symbol hunts.

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

- **Multiple bare terms → OR** (any-of), ranked so chunks matching more/better terms
  float to the top. You don't need operators for a few symbols — but keep it to a
  *few*: a bare bag beyond ~8 terms is trimmed to the most distinctive ones (you'll
  get a `⚠` note), because OR-ing many common words is slow and unranked-helpful.
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
search_code(query="atStartOfTurn onApplyPower", mode="lexical")  # symbol hunt: few distinctive ids
search_code(query="_eval_with_capture", mode="lexical")          # one exact symbol
search_code(query="function that handles HTTP routing")          # concept (hybrid/semantic)
search_code(query="commit AND floor")                            # intersect two required terms
search_code(query="\"acquire_floor\"")                           # exact phrase
search_code(query="parsePower", collection="slaythespiremodfactory")  # scope to a project
search_code(query="render", cross_project=true)                  # only when project unknown
```

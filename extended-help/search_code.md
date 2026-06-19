# search_code

The primary way to find code — prefer it over grep/find. It fuses **semantic**
(meaning-based vector) search with **lexical** (exact keyword/identifier) search,
ranks them together, and returns the best hits. Finds exact identifiers too, so you
don't need grep for symbol lookups.

## Modes

- `mode="hybrid"` (default) — semantic + lexical, fused and ranked.
- `mode="semantic"` — vector search only (concept/behavior queries).
- `mode="lexical"` — exact keyword/identifier only; works even when embeddings
  (Ollama) are unavailable.

## Output format

- `format="text"` (default) — a ranked, human-readable list: relevance score, a
  source glyph (≈ semantic / ⚡ lexical / ⚯ both), `file:Lstart-end`, the
  signature, and a highlighted snippet. Read this yourself.
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
| `agent_add_cell! guard_commit token` | `"agent_add_cell!" OR guard_commit OR token` | bare terms are OR-joined (find any), ranked |
| `push!` | `"push!"` | punctuation attached to a word → matched literally |
| `@view` / `Base.foo` | `"@view"` / `"Base.foo"` | macros and dotted names matched literally |
| `one! two` | `"one!" OR two` | the `!` is part of `one!` |
| `one ! two` | `one NOT two` | a **standalone** `!` is the NOT operator |

### Rules

- **Multiple bare terms → OR** (any-of), ranked so chunks matching more/better terms
  float to the top. You don't need operators for a bag of symbols.
- **Attached punctuation** (`push!`, `sort!`, `@view`, `Base.push!`, `foo?`) is quoted
  for you and matched literally — never a syntax error.
- **Full-word operators** `AND` / `OR` / `NOT` / `NEAR` (any case) are honored as
  operators: `commit AND floor`, `token NOT renew`.
- **Standalone punctuation** acts as an operator: `!` → NOT, `&&`/`&` → AND, `||`/`|`
  → OR. (`one ! two` ⇒ `one NOT two`.)
- **`"exact phrase"`** — double-quote to match an exact token sequence.
- **`prefix*`** — trailing `*` on a clean term does prefix matching (`agent_*`).

If a query still can't be parsed as FTS5 (e.g. unbalanced quotes), it's searched as a
single literal phrase and a ⚠ note is returned explaining why.

> Note: the word index tokenizes on punctuation, so attached `!`/`@`/`.` match by the
> identifier's *word* parts plus a substring (trigram) pass — exact punctuated
> identifiers are found, ranked alongside semantic hits.

## Other arguments

- `collection` — defaults to the last-used session's project.
- `cross_project=true` — search ALL indexed projects at once (ignores `collection`).
- `chunk_type` — `"definitions"` (functions/structs), `"windows"` (sliding windows),
  or `"all"` (default).
- `limit` — max results (default 5).
- `embedding_model` — Ollama model for the semantic half.

## Examples

```julia
search_code(query="function that handles HTTP routing")          # concept (hybrid)
search_code(query="_eval_with_capture")                          # exact symbol
search_code(query="push! sort! collect", mode="lexical")         # symbol bag → OR
search_code(query="agent_add_cell! guard_commit", mode="lexical")
search_code(query="commit AND floor")                            # explicit AND
search_code(query="\"acquire_floor\"")                           # exact phrase
search_code(query="render", cross_project=true)                  # all projects
```

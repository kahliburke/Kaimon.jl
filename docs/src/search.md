# Code Search

Kaimon provides **hybrid** search over Julia codebases: it combines semantic
(meaning-based) vector search with exact keyword/identifier matching, fuses the
two, and returns one ranked list. Describe what you want in plain language — "function
that handles HTTP routing" — *or* paste an exact symbol like `_eval_with_capture`,
and the right half of the engine surfaces it. Both go through the same
`search_code` tool; you don't have to choose.

![Kaimon search tab](./assets/kaimon_search.gif)

## How It Works

1. Source files are split into **chunks** (function definitions, struct definitions, and sliding text windows).
2. Each chunk is converted into a vector embedding using a local Ollama model **and** mirrored into a local SQLite/FTS5 full-text index.
3. Embeddings are stored in a Qdrant vector database; the chunk text + metadata are stored in the lexical index.
4. When you search, the query is embedded and compared against stored vectors (semantic), and matched against the full-text index (lexical). The two ranked lists are fused with [Reciprocal Rank Fusion](https://en.wikipedia.org/wiki/Learning_to_rank) so a chunk found by both rises to the top.

All processing happens locally — no code leaves your machine.

## Hybrid Search (Semantic + Lexical)

The lexical half is a local SQLite/FTS5 index with two tokenizers — word-level
(`get_ollama_embedding` → `get`/`ollama`/`embedding`) and trigram (substring, so
`eval_with` finds `_eval_with_capture`). It catches exactly what embeddings miss:
exact identifiers, error strings, config keys, and rare tokens. The keyword half
also supports FTS query syntax — phrases (`"exact phrase"`), boolean
(`memory AND leak`), and prefix (`mem*`) — through the same query box.

### Modes

`search_code` takes an optional `mode`:

| Mode | Behavior |
|---|---|
| `hybrid` (default) | Semantic + lexical, fused. Best results; no need to think about it. |
| `semantic` | Vector search only. |
| `lexical` | Exact keyword/identifier only. **Works even when Ollama/Qdrant are down** (the index is local SQLite). |

Each result is tagged with its origin: `⚯` found by both, `≈` semantic, `⚡` exact
keyword, `⊂` substring — and lexical hits show the matched snippet.

### Resilience

Hybrid mode degrades gracefully: if embeddings are unavailable (Ollama down or a
missing model) or Qdrant is unreachable, search automatically falls back to
lexical-only results with a note, instead of failing. The lexical index is local,
so basic search keeps working through service outages.

## Requirements

Semantic search requires two external services running locally:

- **Qdrant** — a vector database that stores and searches embeddings.
- **Ollama** — a local model runner that generates embeddings from text.

### Setting Up Qdrant

Start Qdrant using Docker:

```bash
docker run -d --name qdrant -p 6333:6333 \
  -v qdrant_storage:/qdrant/storage \
  qdrant/qdrant
```

This runs Qdrant on the default port (`6333`). Kaimon connects to it
automatically. The `-v qdrant_storage:/qdrant/storage` volume persists your
index across container restarts and reboots.

### Setting Up Ollama

Install Ollama from [ollama.com](https://ollama.com), then pull the default embedding model:

```bash
ollama pull qwen3-embedding:0.6b
```

The Search tab will show a health indicator for both services. If either is not running, the indicator turns red with an error message.

## Indexing a Project

Before you can search, index the project. From the Search tab press `i`, or use the MCP tool directly:

```
qdrant_index_project()
qdrant_index_project(project_path="/path/to/project")
qdrant_index_project(recreate=true)   # rebuild from scratch
```

Indexing scans `.jl`, `.ts`, `.tsx`, `.jsx`, and `.md` files under the project's `src/`, `test/`, and `scripts/` directories. It splits them into chunks, computes embeddings, and stores everything in a Qdrant collection named after the project.

### Auto-Indexing

When a Julia REPL gate connects to Kaimon, the server automatically indexes its project in the background:

- If no collection exists yet, Kaimon detects the project type and runs a full index.
- If a collection already exists, Kaimon runs an incremental sync to pick up any changed files.

File-change notifications from the gate trigger incremental re-indexing automatically, with a 5-second debounce to batch rapid edits.

### Backfilling the Lexical Index

The lexical index is populated automatically as files are indexed or re-indexed.
For collections that were indexed before hybrid search existed, you can build the
lexical index from the existing Qdrant payloads — **without re-embedding** — by
running once from the REPL:

```julia
Kaimon.backfill_fts!("MyProject")   # one collection
Kaimon.backfill_fts_all!()          # every indexed collection
```

A normal `qdrant_sync_index` or reindex also fills it in.

## The Search Tab

Press `4` in the TUI to open the Search tab. It has three panes:

**Status pane** (top) — shows Qdrant and Ollama health, the active collection, and the current embedding model.

**Query pane** (middle) — type your search query here.

**Results pane** (bottom) — scrollable list of matching code chunks with relevance scores.

### Running a Search

1. Press `/` to focus the query input.
2. Type your query in plain language.
3. Press `Enter` to run the search.
4. Use `Tab` to move focus to the results pane, then `↑`/`↓` to scroll.

### Switching Collections

If you have multiple projects indexed, use `↑`/`↓` in the status pane to cycle through available collections. The active collection is highlighted.

### Filtering by Chunk Type

Press `d` to cycle through chunk type filters:

| Filter | What it returns |
|---|---|
| `all` (default) | Both definition chunks and window chunks |
| `definitions` | Only functions, structs, macros, and constants |
| `windows` | Only sliding-window context chunks |

Use `definitions` when looking for a specific function or type. Use `windows` when you need broader context that spans multiple definitions.

### Key Reference

| Key | Action |
|---|---|
| `/` | Focus query input |
| `Enter` | Submit query (when input focused) |
| `Tab` | Cycle pane focus |
| `d` | Cycle chunk type filter |
| `o` | Open embedding model configuration |
| `m` | Open collection manager |
| `r` | Force-refresh service health |

## Embedding Model Configuration

Press `o` to open the model configuration overlay. This shows all supported embedding models with their vector dimensions, context window size, and whether they are installed in Ollama.

| Model | Dimensions | Context | Notes |
|---|---|---|---|
| `qwen3-embedding:0.6b` | 1024 | 8192 tokens | **Default** — best balance of quality, speed, and size |
| `qwen3-embedding:4b` | 2560 | 8192 tokens | Highest quality, 4x larger |
| `qwen3-embedding:8b` | 4096 | 8192 tokens | Largest model |
| `embeddinggemma:latest` | 768 | 2048 tokens | Most consistent on Julia code |
| `nomic-embed-text:latest` | 768 | 512 tokens | Lightweight alternative |
| `snowflake-arctic-embed:latest` | 1024 | 512 tokens | Not recommended |

### Switching Models

Press `o` from the Search tab to open the model configuration overlay. Navigate with `↑`/`↓` and press `Enter` to select a model. Select "Custom..." at the bottom to enter any Ollama model name manually.

If the new model has a different vector dimension than the current collection, Kaimon will warn you and prompt you to reindex (`y`/`n`). Press `y` to reindex all connected project collections with the new model.

Your model choice is saved to `~/.config/kaimon/search.json` and persists across restarts.

Changing the embedding model requires reindexing — vectors from different models are not compatible. If you search and see a "dimension mismatch" error, press `o`, confirm the correct model is selected, and reindex.

## Collection Manager

Press `m` to open the Collection Manager overlay. This shows all indexed projects with their status: vector count, stale file count (files changed since last index), and any active operations.

From the Collection Manager you can:

- **Reindex** a collection — re-index all stale files in the background.
- **Delete** a collection — remove it from Qdrant entirely.
- **Add an external project** — index a project that is not currently connected as a gate session. Enter the project path, optionally adjust the source directories and file extensions, then confirm.

### Stale Files

The stale count shows how many files have been modified since the last indexing run. A stale collection will return outdated results for changed code. Use reindex (from the Collection Manager or `qdrant_sync_index`) to bring it up to date.

## Collection Management Tools

| Tool | Description |
|---|---|
| `qdrant_index_project` | Index or re-index a project. Use `recreate=true` to rebuild from scratch. |
| `qdrant_sync_index` | Sync the index: re-index changed files, remove deleted ones. |
| `qdrant_reindex_file` | Re-index a single file. |
| `qdrant_browse_collection` | Browse indexed points with pagination. |
| `qdrant_collection_info` | Get vector count, size, and configuration for a collection. |
| `qdrant_list_collections` | List all available collections. |

```
qdrant_sync_index()
qdrant_sync_index(collection="MyProject")
```

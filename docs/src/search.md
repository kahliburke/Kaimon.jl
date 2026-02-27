# Semantic Code Search

Kaimon provides natural language search over Julia codebases using vector embeddings. Instead of matching exact keywords, you can describe what you are looking for in plain language — for example, "function that handles HTTP routing" or "struct for database configuration" — and Kaimon returns the most semantically relevant code snippets.

![Kaimon search tab](./assets/kaimon_search.gif)

## How It Works

1. Source files are split into **chunks** (function definitions, struct definitions, and sliding text windows).
2. Each chunk is converted into a vector embedding using a local Ollama model.
3. Embeddings are stored in a Qdrant vector database.
4. When you search, your query is embedded and compared against stored vectors to find the closest matches.

All processing happens locally — no code leaves your machine.

## Requirements

Semantic search requires two external services running locally:

- **Qdrant** — a vector database that stores and searches embeddings.
- **Ollama** — a local model runner that generates embeddings from text.

### Setting Up Qdrant

Start Qdrant using Docker:

```bash
docker run -p 6333:6333 qdrant/qdrant
```

This runs Qdrant on the default port (`6333`). Kaimon connects to it automatically.

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
| `p` | Pull the active embedding model via Ollama |

## Embedding Model Configuration

Press `o` to open the model configuration overlay. This shows all supported embedding models with their vector dimensions, context window size, and whether they are installed in Ollama.

| Model | Dimensions | Context | Notes |
|---|---|---|---|
| `qwen3-embedding:0.6b` | 1024 | 8192 tokens | Default — fast, small |
| `qwen3-embedding:4b` | 2560 | 8192 tokens | Better quality, larger |
| `qwen3-embedding:8b` | 4096 | 8192 tokens | Highest quality |
| `qwen3-embedding` (latest) | 4096 | 8192 tokens | Latest qwen3 release |
| `snowflake-arctic-embed` | 1024 | 512 tokens | Alternative model |
| `nomic-embed-text` | 768 | 512 tokens | Lightweight alternative |

### Switching Models

Press `o` from the Search tab to open the model configuration overlay:

![Kaimon search model configuration](./assets/kaimon_search_config.gif)

Navigate with `↑`/`↓` and press `Enter` to select a model. Installed models are marked. If the new model has a different vector dimension than the current collection, Kaimon will warn you and prompt you to reindex (`y`/`n`). Press `y` to reindex all connected project collections with the new model.

Changing the embedding model requires reindexing — vectors from different models are not compatible. If you search and see a "dimension mismatch" error, press `o`, confirm the correct model is selected, and reindex.

### Installing a Model

If a model shows as not installed, press `p` to pull it from Ollama. The pull runs in the background and the status updates when complete.

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

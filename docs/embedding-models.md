# Embedding Models for Kaimon

## Default: qwen3-embedding:0.6b

- **Dimensions**: 1024
- **Parameters**: 600M
- **Context**: 8192 tokens (~16K chars)
- **Size**: 639MB
- **Install**: `ollama pull qwen3-embedding:0.6b`

Best balance of quality, speed, and size. Produces the fewest chunks (most efficient storage) and handles both Julia and TypeScript/React code well.

## Supported Models

| Model | Dims | Context | Size | Chunks | Notes |
|---|---|---|---|---|---|
| `qwen3-embedding:0.6b` | 1024 | 8192 tokens | 639MB | ~1715 | **Default** — best value |
| `qwen3-embedding:4b` | 2560 | 8192 tokens | ~2.5GB | ~1916 | Highest quality, 4x larger |
| `qwen3-embedding:8b` | 4096 | 8192 tokens | ~4.9GB | — | Largest model |
| `embeddinggemma:latest` | 768 | 2048 tokens | ~400MB | ~1838 | Most consistent on Julia |
| `nomic-embed-text:latest` | 768 | 512 tokens | ~274MB | ~2302 | Smallest model, more chunks |
| `snowflake-arctic-embed:latest` | 1024 | 512 tokens | ~335MB | ~4161 | Not recommended (see below) |

Chunk counts are from indexing the Kaimon project (~20K lines of Julia + 6 TSX files from rEVAlation).

## Comparison Results

We benchmarked 5 models across 15 search queries covering Julia code (health checks, ZMQ connections, AST serialization, SQLite schemas, TUI event handling) and TypeScript/React code (form validation, telemetry charts, tree views, API calls). Each query was scored 0-3 based on whether the top results returned the correct code.

### Scores by Query

| # | Query | qwen3:0.6b | embeddinggemma | nomic-embed | snowflake | qwen3:4b |
|---|-------|:---:|:---:|:---:|:---:|:---:|
| 1 | health check ping pong session | 0 | 3 | 3 | 0 | 2 |
| 2 | ZMQ TCP socket auth token | 2 | 2 | 2 | 1 | 2 |
| 3 | tab bar mouse click handling | 2 | 2 | 2 | 0 | 2 |
| 4 | background job promotion eval timeout | 3 | 3 | 3 | 0 | 2 |
| 5 | extension process spawn restart env | 1 | 3 | 3 | 1 | 3 |
| 6 | serialize Julia AST to string | 3 | 2 | 1 | 0 | 3 |
| 7 | Qdrant create collection upsert | 3 | 2 | 2 | 1 | 3 |
| 8 | MCP JSON-RPC initialize request | 2 | 2 | 3 | 1 | 2 |
| 9 | save/load config preferences JSON | 3 | 2 | 2 | 0 | 3 |
| 10 | keyboard shortcut dispatch to tab | 3 | 2 | 2 | 1 | 2 |
| 11 | database SQLite schema migration | 2 | 2 | 1 | 2 | 2 |
| 12 | React form training hyperparameters | 3 | 2 | 1 | 1 | 3 |
| 13 | websocket telemetry chart loss curve | 3 | 2 | 1 | 1 | 2 |
| 14 | tree view expand/collapse nodes | 2 | 1 | 2 | 2 | 2 |
| 15 | fetch API error handling loading state | 2 | 1 | 1 | 2 | 2 |

### Summary

| Model | Dims | Size | Julia /33 | TSX /12 | Total /45 | Avg |
|-------|------|------|:---------:|:-------:|:---------:|:---:|
| **qwen3:4b** | 2560 | 2.5GB | 26 | 9 | **35** | 2.33 |
| **qwen3:0.6b** | 1024 | 639MB | 24 | 10 | **34** | 2.27 |
| **embeddinggemma** | 768 | ~400MB | 25 | 6 | **31** | 2.07 |
| **nomic-embed-text** | 768 | ~274MB | 24 | 5 | **29** | 1.93 |
| **snowflake-arctic** | 1024 | ~335MB | 7 | 6 | **13** | 0.87 |

### Key Findings

- **qwen3:4b** scores highest overall but is 4x the model size and noticeably slower to index. Best choice if you have the resources and want maximum search quality.
- **qwen3:0.6b** (default) is within 1 point of qwen3:4b at 1/4 the size. Best on TSX queries. Weakness: conceptual queries where it occasionally misses the right file entirely.
- **embeddinggemma** is the most consistent on Julia (no zeros) but falls off on TSX. Good if you only index Julia.
- **nomic-embed-text** produces 35% more chunks than qwen3:0.6b for similar quality. Not recommended.
- **snowflake-arctic-embed** is not recommended — it produces 2.4x more chunks than other models and returns high-confidence scores on completely irrelevant results.

## Changing Models

Press `o` on the Search tab to open the model configuration overlay. Navigate with arrow keys and press `Enter` to select. Select "Custom..." at the bottom to enter any Ollama model name manually.

If the new model has different dimensions than the current collection, Kaimon will prompt you to reindex. Press `y` to reindex all connected project collections.

Your model choice is saved to `~/.config/kaimon/search.json` and persists across restarts.

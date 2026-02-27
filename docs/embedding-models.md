# Embedding Models for Kaimon

## Default: qwen3-embedding:0.6b

- **Dimensions**: 1024
- **Parameters**: 600M
- **Context**: 8192 tokens (~16K chars)
- **Size**: 639MB
- **MTEB-Code score**: 75.41
- **Install**: `ollama pull qwen3-embedding:0.6b`

Best balance of quality, speed, and compatibility. The 1024-dim output matches existing Qdrant collections.

## Qwen3 Embedding Family

| Model | Dims | Context | Size | Notes |
|---|---|---|---|---|
| `qwen3-embedding:0.6b` | 1024 | 8192 tokens | 639MB | **Default** |
| `qwen3-embedding:4b` | 2560 | 8192 tokens | ~2.5GB | Higher quality, requires collection recreation |
| `qwen3-embedding:8b` | 4096 | 8192 tokens | ~4.9GB | Best quality, requires collection recreation |

## Legacy Models (still supported)

| Model | Dims | Context | Notes |
|---|---|---|---|
| `snowflake-arctic-embed:latest` | 1024 | 512 tokens | Previous default, compatible collections |
| `nomic-embed-text` | 768 | 512 tokens | Requires 768-dim collections |

## Changing Models

Set `DEFAULT_EMBEDDING_MODEL` in `src/qdrant_tools.jl` and add a config entry in `EMBEDDING_CONFIGS` in `src/qdrant_indexer.jl`.

If the new model has different dimensions, existing collections must be recreated (re-index with `recreate=true`).

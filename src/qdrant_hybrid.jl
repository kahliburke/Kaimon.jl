# ── Hybrid code search: fuse semantic (Qdrant) + lexical (FTS5) via RRF ────────
#
# Backs `qdrant_search_code`. The agent calls the same tool with the same args; it
# transparently returns the union of vector hits and exact keyword/identifier hits,
# fused with Reciprocal Rank Fusion. Resilient by design: if embeddings (Ollama) or
# Qdrant are down, it degrades to lexical-only instead of erroring.

# Unified hit used for ranking + rendering across both sources.
mutable struct HybridHit
    point_id::Union{String,Nothing}
    file::String
    name::String
    type::String
    start_line::Int
    end_line::Int
    text::String
    payload::Dict          # full semantic payload when available (rich metadata)
    snippet::String        # FTS snippet (lexical hits), with \x02/\x03 highlight marks
    sources::Set{Symbol}   # :semantic, :lexical (word), :substr (trigram)
    rrf::Float64
end

const _RRF_K = 60          # standard RRF constant
const _NAME_BOOST = 0.02   # ≈ a couple of ranks; floats exact-symbol matches up
const _CONTENT_BOOST = 0.02 # hit text contains every query token (what FTS matched)

# Dedup key: same Qdrant point, else same file+span (a chunk found by several
# methods collapses to one hit whose sources union and whose RRF scores sum).
_hit_key(h::HybridHit) = h.point_id !== nothing ? "pid:" * h.point_id :
    string(h.file, ':', h.start_line, ':', h.end_line)

function _rrf_accumulate!(acc::Dict{String,HybridHit}, ranked::Vector{HybridHit};
                          weight::Float64 = 1.0, k::Int = _RRF_K)
    for (rank, h) in enumerate(ranked)
        key = _hit_key(h)
        contrib = weight / (k + rank)
        if haskey(acc, key)
            ex = acc[key]
            ex.rrf += contrib
            union!(ex.sources, h.sources)
            isempty(ex.snippet) && !isempty(h.snippet) && (ex.snippet = h.snippet)
            isempty(ex.payload) && !isempty(h.payload) && (ex.payload = h.payload)
            length(h.text) > length(ex.text) && (ex.text = h.text)
            isempty(ex.name) && !isempty(h.name) && (ex.name = h.name)
        else
            h.rrf = contrib
            acc[key] = h
        end
    end
    return acc
end

# Qdrant search results → HybridHit (carry the full payload for rich formatting).
function _semantic_hits(results)::Vector{HybridHit}
    out = HybridHit[]
    for r in results
        payload = get(r, "payload", Dict())
        push!(out, HybridHit(
            (haskey(r, "id") && r["id"] !== nothing) ? string(r["id"]) : nothing,
            string(get(payload, "file", "")),
            string(get(payload, "name", "")),
            string(get(payload, "type", "")),
            Int(get(payload, "start_line", 0)),
            Int(get(payload, "end_line", 0)),
            string(get(payload, "text", "")),
            payload, "", Set([:semantic]), 0.0,
        ))
    end
    return out
end

# FtsHit list → HybridHit.
function _lexical_hits(hits::Vector{FtsIndex.FtsHit})::Vector{HybridHit}
    out = HybridHit[]
    for h in hits
        push!(out, HybridHit(
            h.point_id, h.file, h.name, h.type, h.start_line, h.end_line,
            h.text, Dict(), h.snippet, Set([h.source]), 0.0,
        ))
    end
    return out
end

# Exactness boosts: reward hits whose name/content literally matches the query, so
# a chunk that *contains what you typed* beats a semantic look-alike that doesn't
# — even when the vector half ranked the look-alike higher. `_NAME_BOOST` fires
# when a hit's (≥4-char) name appears in the query ("just find `_eval_with_capture`");
# `_CONTENT_BOOST` fires when the chunk text contains every significant (≥3-char)
# query token, which is what FTS matched on, and what semantic look-alikes lack.
function _apply_boosts!(hits::Vector{HybridHit}, query::AbstractString)
    ql = lowercase(query)
    toks = [t for t in split(ql, r"[^a-z0-9_]+"; keepempty = false) if length(t) >= 3]
    for h in hits
        n = lowercase(h.name)
        length(n) >= 4 && occursin(n, ql) && (h.rrf += _NAME_BOOST)
        if !isempty(toks)
            txt = lowercase(h.text)
            all(t -> occursin(t, txt), toks) && (h.rrf += _CONTENT_BOOST)
        end
    end
    return hits
end

# Qdrant payload filter for the chunk_type facet (mirrors the legacy behavior).
function _chunk_type_filter(chunk_type::AbstractString)
    if chunk_type == "definitions"
        return Dict("should" => [
            Dict("key" => "type", "match" => Dict("value" => "function")),
            Dict("key" => "type", "match" => Dict("value" => "struct")),
            Dict("key" => "type", "match" => Dict("value" => "macro")),
            Dict("key" => "type", "match" => Dict("value" => "const")),
            Dict("key" => "type", "match" => Dict("value" => "tool")),
        ])
    elseif chunk_type == "windows"
        return Dict("must" => [Dict("key" => "type", "match" => Dict("value" => "window"))])
    end
    return nothing
end

# Origin glyph for a hit (so the agent sees *why* it surfaced).
function _source_glyph(s::Set{Symbol})
    has_sem = :semantic in s
    has_lex = (:lexical in s) || (:substr in s)
    has_sem && has_lex && return "⚯"   # both
    has_sem && return "≈"              # semantic
    :lexical in s && return "⚡"        # exact keyword
    return "◎"                          # substring
end

function _format_hybrid(query, where_label, hits::Vector{HybridHit},
                        cross_project::Bool, notes::Vector{String}, mode::String)
    out = "🔍 \"$query\" in $where_label" * (mode == "hybrid" ? "" : " [$mode]") * ":\n"
    for n in notes
        out *= "  ⚠ $n\n"
    end
    out *= "\n"

    # Relevance score normalized to the top hit (0–100). Relative within this
    # result set only — it shows how far each hit trails #1, not an absolute match
    # quality (semantic cosine and lexical BM25 aren't on one scale).
    maxrrf = maximum(h -> h.rrf, hits)

    for (i, h) in enumerate(hits)
        payload = h.payload
        file = h.file
        rel = maxrrf > 0 ? round(Int, 100 * h.rrf / maxrrf) : 0
        sig = string(get(payload, "signature", ""))
        parent_type = string(get(payload, "parent_type", ""))
        type_params = get(payload, "type_params", [])
        is_mutable = get(payload, "is_mutable", false)

        # Relative path (against the indexed project, else cwd).
        proj_path = string(get(payload, "project_path", ""))
        if !isempty(file)
            if !isempty(proj_path) && startswith(file, proj_path)
                file = relpath(file, proj_path)
            elseif startswith(file, pwd())
                file = relpath(file, pwd())
            end
        end
        proj_label = (cross_project && !isempty(proj_path)) ? basename(proj_path) : ""

        out *= "[$i $(_source_glyph(h.sources)) $rel] "
        if !isempty(sig)
            out *= "$sig @ "
        elseif !isempty(h.name)
            out *= "$(h.name) @ "
        end
        !isempty(proj_label) && (out *= "$proj_label/")
        out *= isempty(file) ? "?" : "$file:L$(h.start_line)"
        out *= (h.start_line != h.end_line && h.end_line > 0) ? "-$(h.end_line)" : ""

        type_info = h.type
        type_info == "struct" && is_mutable && (type_info = "mutable struct")
        !isempty(parent_type) && (type_info *= " <: $parent_type")
        !isempty(type_params) && (type_info *= "{" * join(type_params, ",") * "}")
        out *= isempty(type_info) ? "" : " ($type_info)"
        out *= "\n"

        # Lexical hits show the matched snippet (highlighted); semantic hits a preview.
        if !isempty(h.snippet)
            snip = replace(replace(h.snippet, '\x02' => "**"), '\x03' => "**")
            snip = replace(snip, '\n' => ' ')
            out *= "  $snip\n"
        else
            prev = strip(string(h.text))
            if length(prev) > 20
                length(prev) > 150 && (prev = first(prev, 150) * "...")
                out *= "  $(replace(prev, '\n' => ' '))\n"
            end
        end
        out *= "\n"
    end
    return out
end

"""
    _qdrant_search_code(args) -> String

Hybrid implementation behind the `qdrant_search_code` MCP tool. `mode` ∈
{hybrid (default), semantic, lexical}. Degrades gracefully: missing embeddings or
Qdrant fall back to lexical; a missing lexical index falls back to semantic.
"""
function _qdrant_search_code(args)
    query = String(get(args, "query", ""))
    isempty(query) && return "Error: query is required"
    limit = Int(get(args, "limit", 5))
    chunk_type = String(get(args, "chunk_type", "all"))
    mode = lowercase(String(get(args, "mode", "hybrid")))
    mode in ("hybrid", "semantic", "lexical") || (mode = "hybrid")
    fetch = max(limit * 3, limit)

    explicit_model = let v = get(args, "embedding_model", nothing)
        (v isa AbstractString && !isempty(v)) ? String(v) : nothing
    end
    cross_project = let v = get(args, "cross_project", false)
        v isa Bool ? v : v == "true" || v == true
    end

    want_semantic = mode != "lexical"
    want_lexical = mode != "semantic"
    notes = String[]

    # ── Resolve the collection (Qdrant-backed; also scopes the lexical search) ──
    sem_collection = nothing          # Qdrant collection for vector search
    fts_collection = nothing          # FTS collection (nothing ⇒ all, cross-project)
    if QdrantClient.ping()
        collections = QdrantClient.list_collections()
        if cross_project
            gc = global_collection_name()
            if gc ∉ collections
                try; populate_global_collection!(; verbose = false); catch; end
                collections = QdrantClient.list_collections()
            end
            sem_collection = gc ∈ collections ? gc : nothing
            fts_collection = nothing
        else
            raw = get(args, "collection", nothing)
            raw isa String && isempty(raw) && (raw = nothing)
            col, col_err = _resolve_collection(raw, collections)
            col_err !== nothing && return "Error: $col_err"
            sem_collection = col
            fts_collection = col
        end
    else
        # Qdrant unreachable: semantic impossible. Lexical can still serve.
        mode == "semantic" && return _require_services()
        want_semantic = false
        push!(notes, "Qdrant unreachable — lexical results only.")
        if !cross_project
            raw = get(args, "collection", nothing)
            fts_collection = (raw isa String && !isempty(raw)) ? normalize_collection_name(raw) : nothing
        end
    end

    # ── Semantic ──
    sem = HybridHit[]
    if want_semantic && sem_collection !== nothing
        model = something(explicit_model, resolve_search_model(sem_collection))
        if !ping_ollama() || !check_ollama_model(model)
            mode == "semantic" && return _require_services(need_ollama = true, model = model)
            push!(notes, "Embeddings unavailable (Ollama/model) — lexical results only.")
        else
            embedding = get_ollama_embedding(query; model = model)
            if isempty(embedding)
                mode == "semantic" && return "Error: Failed to generate embedding with model '$model'."
                push!(notes, "Embedding failed — lexical results only.")
            else
                results = QdrantClient.search(sem_collection, embedding;
                    limit = fetch, filter = _chunk_type_filter(chunk_type))
                sem = _semantic_hits(results)
            end
        end
    end

    # ── Lexical ──
    word = FtsIndex.FtsHit[]
    tri = FtsIndex.FtsHit[]
    if want_lexical
        try
            lex = FtsIndex.search(query; collection = fts_collection, limit = fetch, chunk_type = chunk_type)
            word, tri = lex.word, lex.tri
        catch e
            mode == "lexical" && return "Error: lexical index unavailable: $e"
        end
    end

    # ── Fuse (RRF), boost exact symbols, rank ──
    acc = Dict{String,HybridHit}()
    _rrf_accumulate!(acc, sem; weight = 1.0)
    _rrf_accumulate!(acc, _lexical_hits(word); weight = 1.0)
    _rrf_accumulate!(acc, _lexical_hits(tri); weight = 0.9)
    hits = collect(values(acc))
    _apply_boosts!(hits, query)
    sort!(hits; by = h -> -h.rrf)
    isempty(hits) && return "No results found for query: \"$query\""
    hits = hits[1:min(limit, length(hits))]

    where_label = sem_collection !== nothing ? sem_collection :
        (fts_collection !== nothing ? fts_collection : "all projects")
    return _format_hybrid(query, where_label, hits, cross_project, notes, mode)
end

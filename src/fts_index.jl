"""
Lexical (full-text) code index — the keyword half of hybrid search.

A local SQLite/FTS5 store that mirrors the chunks the Qdrant indexer produces, so
`qdrant_search_code` can fuse semantic (vector) hits with exact keyword/identifier
hits. Two FTS5 tables share one external-content `chunks` table:

  • `code_fts`  (unicode61) — word-level recall: splits `get_ollama_embedding`
                 into `get`/`ollama`/`embedding`; supports phrase / AND·OR·NOT /
                 prefix `term*` query syntax.
  • `code_tri`  (trigram)   — substring precision: `eval_with` finds
                 `_eval_with_capture`. Requires ≥3-char queries.

External-content tables (`content='chunks'`) keep the searchable text in `chunks`
and let us delete-by-file with a plain `DELETE` + sync triggers — no FTS5 rowid
bookkeeping. This module owns its own DB file (`code_fts.db`) so its write bursts
don't contend with the analytics DB's per-tool-call writes for SQLite's single
writer lock. It has NO Qdrant/Ollama dependency: lexical search keeps working when
those services are down (the resilience half of the delivery).
"""
module FtsIndex

using SQLite
using DBInterface

export FtsHit

# ── Connection ────────────────────────────────────────────────────────────────

const DB = Ref{Union{SQLite.DB,Nothing}}(nothing)
const DB_PATH = Ref{String}("")
const HAS_TRIGRAM = Ref{Bool}(true)   # cleared if the bundled SQLite predates trigram

"""Default DB path in the user's cache dir (resolved via the parent Kaimon module)."""
function default_db_path()
    return joinpath(parentmodule(@__MODULE__).kaimon_cache_dir(), "code_fts.db")
end

"""Open (lazily) and return the connection, creating the schema on first use."""
function _db()
    db = DB[]
    db === nothing && return init!()
    return db
end

"""
    init!(path=default_db_path()) -> SQLite.DB

Open the lexical index DB and create the schema if absent. Idempotent.
"""
function init!(path::String = default_db_path())
    mkpath(dirname(path))
    db = SQLite.DB(path)
    DB[] = db
    DB_PATH[] = path

    # WAL + a busy timeout so concurrent readers (search) never block on the
    # indexer's write bursts, and a brief writer contention just waits.
    SQLite.execute(db, "PRAGMA journal_mode=WAL;")
    SQLite.execute(db, "PRAGMA busy_timeout=5000;")
    SQLite.execute(db, "PRAGMA synchronous=NORMAL;")

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS chunks(
            id         INTEGER PRIMARY KEY,
            point_id   TEXT,
            collection TEXT NOT NULL,
            file       TEXT NOT NULL,
            name       TEXT,
            type       TEXT,
            start_line INTEGER,
            end_line   INTEGER,
            text       TEXT NOT NULL
        );
    """)
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_chunks_cf ON chunks(collection, file);")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_chunks_pid ON chunks(point_id);")

    SQLite.execute(db, """
        CREATE VIRTUAL TABLE IF NOT EXISTS code_fts USING fts5(
            text, name, file, content='chunks', content_rowid='id'
        );
    """)
    # Trigram is SQLite ≥3.34; degrade to word-only on older builds.
    HAS_TRIGRAM[] = try
        SQLite.execute(db, """
            CREATE VIRTUAL TABLE IF NOT EXISTS code_tri USING fts5(
                text, name, content='chunks', content_rowid='id', tokenize='trigram'
            );
        """)
        true
    catch
        false
    end

    # Keep the FTS shadow tables in sync with `chunks` (insert + delete only;
    # reindex is delete-then-insert, so no update trigger is needed).
    SQLite.execute(db, """
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO code_fts(rowid, text, name, file)
                VALUES (new.id, new.text, new.name, new.file);
        END;
    """)
    SQLite.execute(db, """
        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
            INSERT INTO code_fts(code_fts, rowid, text, name, file)
                VALUES('delete', old.id, old.text, old.name, old.file);
        END;
    """)
    if HAS_TRIGRAM[]
        SQLite.execute(db, """
            CREATE TRIGGER IF NOT EXISTS chunks_ai_tri AFTER INSERT ON chunks BEGIN
                INSERT INTO code_tri(rowid, text, name) VALUES (new.id, new.text, new.name);
            END;
        """)
        SQLite.execute(db, """
            CREATE TRIGGER IF NOT EXISTS chunks_ad_tri AFTER DELETE ON chunks BEGIN
                INSERT INTO code_tri(code_tri, rowid, text, name)
                    VALUES('delete', old.id, old.text, old.name);
            END;
        """)
    end

    return db
end

"""Close the connection (mainly for tests)."""
function close!()
    db = DB[]
    db !== nothing && (SQLite.close(db); DB[] = nothing)
    return nothing
end

# ── Writes ────────────────────────────────────────────────────────────────────

_field(row, k, default = nothing) = row isa AbstractDict ? get(row, k, default) :
    (hasproperty(row, Symbol(k)) ? getproperty(row, Symbol(k)) : default)

"""
    add_chunks!(rows) -> Int

Insert chunk rows into the lexical index (triggers populate the FTS tables). Each
row is a Dict/NamedTuple with: `point_id`, `collection`, `file`, `name`, `type`,
`start_line`, `end_line`, `text`. Wrapped in one transaction. Returns rows written.
"""
function add_chunks!(rows)
    isempty(rows) && return 0
    db = _db()
    n = 0
    SQLite.transaction(db) do
        stmt = """
            INSERT INTO chunks(point_id, collection, file, name, type, start_line, end_line, text)
            VALUES (?,?,?,?,?,?,?,?)
        """
        for r in rows
            txt = _field(r, "text", "")
            (txt === nothing || isempty(txt)) && continue
            DBInterface.execute(db, stmt, (
                something(_field(r, "point_id"), missing),
                String(_field(r, "collection", "")),
                String(_field(r, "file", "")),
                something(_field(r, "name"), missing),
                something(_field(r, "type"), missing),
                something(_field(r, "start_line"), missing),
                something(_field(r, "end_line"), missing),
                String(txt),
            ))
            n += 1
        end
    end
    return n
end

"""Remove all chunks for one file in one collection (the reindex delete step)."""
function delete_file!(collection::AbstractString, file::AbstractString)
    db = _db()
    DBInterface.execute(db, "DELETE FROM chunks WHERE collection = ? AND file = ?",
        (String(collection), String(file)))
    return nothing
end

"""Drop every chunk for a collection (used on collection recreate / backfill reset)."""
function clear_collection!(collection::AbstractString)
    db = _db()
    DBInterface.execute(db, "DELETE FROM chunks WHERE collection = ?", (String(collection),))
    return nothing
end

# ── Search ────────────────────────────────────────────────────────────────────

struct FtsHit
    point_id::Union{String,Nothing}
    file::String
    name::String
    type::String
    start_line::Int
    end_line::Int
    text::String
    snippet::String
    rank::Float64        # bm25 — lower is better
    source::Symbol       # :lexical (word) or :substr (trigram)
end

# Map the public chunk_type filter to a SQL fragment over chunks.type. Values are
# a fixed whitelist (no user input), so direct interpolation is safe.
function _type_clause(chunk_type::AbstractString)
    if chunk_type == "definitions"
        return "AND c.type IN ('function','struct','macro','const','tool')"
    elseif chunk_type == "windows"
        return "AND c.type = 'window'"
    end
    return ""
end

_s(x, default = "") = x === missing || x === nothing ? default : x
_i(x, default = 0) = x === missing || x === nothing ? default : Int(x)

# Execute an FTS MATCH and build FtsHits, reading each row's columns DURING
# iteration — SQLite.jl `Row`s are only valid for the current step, so they must
# never be collected and read afterwards. Retries with the query quoted as a
# literal phrase if the raw form trips FTS5 query syntax (agent queries carry
# punctuation / operators).
function _match_hits(db, sql, query::AbstractString, tail::Tuple, source::Symbol)
    build(q) = begin
        out = FtsHit[]
        for r in DBInterface.execute(db, sql, (String(q), tail...))
            push!(out, FtsHit(
                r.point_id === missing ? nothing : String(r.point_id),
                _s(r.file), _s(r.name), _s(r.type),
                _i(r.start_line), _i(r.end_line),
                _s(r.text), _s(r.snip),
                Float64(r.rank), source,
            ))
        end
        out
    end
    try
        return build(query)
    catch
        quoted = "\"" * replace(String(query), "\"" => "\"\"") * "\""
        try; return build(quoted); catch; return FtsHit[]; end
    end
end

"""
    search(query; collection=nothing, limit=20, chunk_type="all") -> (word, tri)

Lexical search returning two ranked `FtsHit` lists: `word` (unicode61 / BM25) and
`tri` (trigram substring). `collection=nothing` searches all collections (used by
cross-project search). The caller fuses these with the semantic list.
"""
function search(query::AbstractString; collection::Union{AbstractString,Nothing} = nothing,
                limit::Int = 20, chunk_type::AbstractString = "all")
    isempty(strip(query)) && return (word = FtsHit[], tri = FtsHit[])
    db = _db()
    tclause = _type_clause(chunk_type)
    cclause = collection === nothing ? "" : "AND c.collection = ?"
    ctail = collection === nothing ? () : (String(collection),)

    word_sql = """
        SELECT c.point_id, c.file, c.name, c.type, c.start_line, c.end_line, c.text,
               snippet(code_fts, 0, char(2), char(3), '…', 12) AS snip,
               bm25(code_fts) AS rank
        FROM code_fts JOIN chunks c ON c.id = code_fts.rowid
        WHERE code_fts MATCH ? $cclause $tclause
        ORDER BY rank LIMIT ?
    """
    word = _match_hits(db, word_sql, query, (ctail..., limit), :lexical)

    tri = FtsHit[]
    if HAS_TRIGRAM[] && length(strip(query)) >= 3
        tri_sql = """
            SELECT c.point_id, c.file, c.name, c.type, c.start_line, c.end_line, c.text,
                   snippet(code_tri, 0, char(2), char(3), '…', 12) AS snip,
                   bm25(code_tri) AS rank
            FROM code_tri JOIN chunks c ON c.id = code_tri.rowid
            WHERE code_tri MATCH ? $cclause $tclause
            ORDER BY rank LIMIT ?
        """
        # Trigram does substring containment; quote the whole query as a phrase so
        # punctuation in identifiers (`!`, `_`) matches literally.
        phrase = "\"" * replace(String(query), "\"" => "\"\"") * "\""
        tri = _match_hits(db, tri_sql, phrase, (ctail..., limit), :substr)
    end

    return (word = word, tri = tri)
end

# ── Coverage (for search-health visibility) ───────────────────────────────────

"""Per-collection chunk counts + total, for the search-health surface."""
function coverage()
    db = _db()
    # Materialize during iteration (see _match_hits note on transient Rows).
    per = [(collection = String(r.collection), n = Int(r.n))
           for r in DBInterface.execute(db,
               "SELECT collection, COUNT(*) AS n FROM chunks GROUP BY collection ORDER BY n DESC")]
    return (collections = per, total = sum(p -> p.n, per; init = 0))
end

end # module FtsIndex

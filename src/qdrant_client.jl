"""
Qdrant Vector Database Client

Simple HTTP client for interacting with Qdrant vector database.
Assumes Qdrant is running locally (e.g., via Docker).
"""
module QdrantClient

using HTTP
using JSON

# Qdrant server configuration
const QDRANT_URL = Ref("http://localhost:6333")

"""
    set_url(url::String)

Set the Qdrant server URL (default: http://localhost:6333).
"""
function set_url(url::String)
    QDRANT_URL[] = url
end

"""
    list_collections() -> Vector{String}

List all collections in the Qdrant instance.
"""
function list_collections()
    try
        response = HTTP.get("$(QDRANT_URL[])/collections")
        data = JSON.parse(String(response.body))

        if haskey(data, "result") && haskey(data["result"], "collections")
            return [c["name"] for c in data["result"]["collections"]]
        end
        return String[]
    catch e
        @error "Failed to list collections" exception = e
        return String[]  # empty → callers check length; _friendly_error used at tool layer
    end
end

"""
    get_collection_info(collection::String) -> Dict

Get information about a specific collection.
"""
function get_collection_info(collection::String)
    try
        response = HTTP.get("$(QDRANT_URL[])/collections/$(collection)")
        data = JSON.parse(String(response.body))
        return get(data, "result", Dict())
    catch e
        @error "Failed to get collection info" collection = collection exception = e
        return Dict("error" => _friendly_error(e))
    end
end

"""
    search(collection::String, vector::Vector{Float64}; limit::Int=5, score_threshold::Float64=0.0, filter::Union{Dict,Nothing}=nothing) -> Vector{Dict}

Search for similar vectors in a collection.

# Arguments
- `collection::String`: Name of the collection to search
- `vector::Vector{Float64}`: Query vector
- `limit::Int`: Maximum number of results (default: 5)
- `score_threshold::Float64`: Minimum similarity score (default: 0.0)
- `filter::Union{Dict,Nothing}`: Qdrant filter for metadata (e.g., Dict("must" => [Dict("key" => "type", "match" => Dict("value" => "function"))]))

# Returns
Vector of result dictionaries containing id, score, and payload.
"""
function search(
    collection::String,
    vector::Vector{Float64};
    limit::Int = 5,
    score_threshold::Float64 = 0.0,
    filter::Union{Dict,Nothing} = nothing,
)
    try
        body = Dict(
            "vector" => vector,
            "limit" => limit,
            "score_threshold" => score_threshold,
            "with_payload" => true,
            "with_vector" => false,
        )

        # Add filter if provided
        if filter !== nothing
            body["filter"] = filter
        end

        response = HTTP.post(
            "$(QDRANT_URL[])/collections/$(collection)/points/search",
            ["Content-Type" => "application/json"],
            JSON.json(body),
        )

        data = JSON.parse(String(response.body))
        return get(data, "result", [])
    catch e
        @error "Search failed" collection = collection exception = e
        return [Dict("error" => _friendly_error(e))]
    end
end

"""
    search_with_text(collection::String, query_text::String; limit::Int=5, embed_func::Function) -> Vector{Dict}

Search using text by first converting to embedding.

# Arguments
- `collection::String`: Name of the collection to search
- `query_text::String`: Text query to search for
- `limit::Int`: Maximum number of results (default: 5)
- `embed_func::Function`: Function that takes text and returns Vector{Float64} embedding
"""
function search_with_text(
    collection::String,
    query_text::String;
    limit::Int = 5,
    embed_func::Function,
)
    try
        # Get embedding for query text
        embedding = embed_func(query_text)

        # Search using the embedding
        return search(collection, embedding; limit = limit)
    catch e
        @error "Text search failed" collection = collection exception = e
        return [Dict("error" => _friendly_error(e))]
    end
end

"""
    scroll_points(collection::String; limit::Int=10, offset=nothing) -> Dict

Retrieve points from a collection with pagination.

# Arguments
- `collection::String`: Name of the collection
- `limit::Int`: Number of points to retrieve (default: 10)
- `offset`: Offset for pagination (optional)
"""
function scroll_points(collection::String; limit::Int = 10, offset = nothing)
    try
        body = Dict("limit" => limit, "with_payload" => true, "with_vector" => false)

        if offset !== nothing
            body["offset"] = offset
        end

        response = HTTP.post(
            "$(QDRANT_URL[])/collections/$(collection)/points/scroll",
            ["Content-Type" => "application/json"],
            JSON.json(body),
        )

        data = JSON.parse(String(response.body))
        return get(data, "result", Dict())
    catch e
        @error "Scroll failed" collection = collection exception = e
        return Dict("error" => _friendly_error(e))
    end
end

"""
    get_point(collection::String, point_id) -> Dict

Retrieve a specific point by ID.
"""
function get_point(collection::String, point_id)
    try
        response = HTTP.get("$(QDRANT_URL[])/collections/$(collection)/points/$(point_id)")
        data = JSON.parse(String(response.body))
        return get(data, "result", Dict())
    catch e
        @error "Failed to get point" collection = collection point_id = point_id exception =
            e
        return Dict("error" => _friendly_error(e))
    end
end

"""
    upsert_points(collection::String, points::Vector{Dict}) -> Bool

Upsert points into a collection.

# Arguments
- `collection::String`: Name of the collection
- `points::Vector{Dict}`: Vector of point dictionaries with keys:
  - `id`: Point ID (string UUID or integer)
  - `vector`: Vector{Float64} embedding
  - `payload`: Dict with metadata

# Returns
true on success, false on failure.
"""
function upsert_points(collection::String, points::Vector{Dict})
    try
        body = Dict("points" => points)

        response = HTTP.put(
            "$(QDRANT_URL[])/collections/$(collection)/points",
            ["Content-Type" => "application/json"],
            JSON.json(body),
        )

        data = JSON.parse(String(response.body))
        return get(data, "status", "") == "ok"
    catch e
        @error "Upsert failed" collection = collection exception = e
        return false
    end
end

"""
    delete_collection(collection::String) -> Bool

Delete a collection.
"""
function delete_collection(collection::String)
    try
        response = HTTP.delete("$(QDRANT_URL[])/collections/$(collection)")
        data = JSON.parse(String(response.body))
        return get(data, "result", false) == true
    catch e
        @error "Delete collection failed" collection = collection exception = e
        return false
    end
end

"""
    create_collection(collection::String; vector_size::Int=768, distance::String="Cosine") -> Bool

Create a new collection.
"""
function create_collection(
    collection::String;
    vector_size::Int = 768,
    distance::String = "Cosine",
)
    try
        body = Dict("vectors" => Dict("size" => vector_size, "distance" => distance))

        response = HTTP.put(
            "$(QDRANT_URL[])/collections/$(collection)",
            ["Content-Type" => "application/json"],
            JSON.json(body),
        )

        data = JSON.parse(String(response.body))
        return get(data, "result", false) == true
    catch e
        @error "Create collection failed" collection = collection exception = e
        return false
    end
end

"""
    delete_by_filter(collection::String, filter::Dict) -> Bool

Delete points matching a filter condition.

# Arguments
- `collection::String`: Name of the collection
- `filter::Dict`: Qdrant filter condition (e.g., Dict("must" => [Dict("key" => "file", "match" => Dict("value" => "/path/to/file.jl"))]))

# Returns
true on success, false on failure.
"""
function delete_by_filter(collection::String, filter::Dict)
    try
        body = Dict("filter" => filter)

        response = HTTP.post(
            "$(QDRANT_URL[])/collections/$(collection)/points/delete",
            ["Content-Type" => "application/json"],
            JSON.json(body),
        )

        data = JSON.parse(String(response.body))
        return get(data, "status", "") == "ok"
    catch e
        @error "Delete by filter failed" collection = collection exception = e
        return false
    end
end

"""
    delete_by_file(collection::String, file_path::String) -> Bool

Delete all points from a specific file.

# Arguments
- `collection::String`: Name of the collection
- `file_path::String`: Path to the file whose chunks should be deleted

# Returns
true on success, false on failure.
"""
function delete_by_file(collection::String, file_path::String)
    filter = Dict("must" => [Dict("key" => "file", "match" => Dict("value" => file_path))])
    return delete_by_filter(collection, filter)
end

"""
    count_by_file(collection::String, file_path::String) -> Int

Count points from a specific file.

# Returns
Number of points from the file, or -1 on error.
"""
function count_by_file(collection::String, file_path::String)
    try
        filter =
            Dict("must" => [Dict("key" => "file", "match" => Dict("value" => file_path))])
        body = Dict("filter" => filter, "exact" => true)

        response = HTTP.post(
            "$(QDRANT_URL[])/collections/$(collection)/points/count",
            ["Content-Type" => "application/json"],
            JSON.json(body),
        )

        data = JSON.parse(String(response.body))
        return get(get(data, "result", Dict()), "count", 0)
    catch e
        @error "Count by file failed" collection = collection exception = e
        return -1
    end
end

"""
    ping() -> Bool

Check if Qdrant is reachable. Returns true if /healthz returns 200.
"""
function ping()
    try
        response = HTTP.get("$(QDRANT_URL[])/healthz"; connect_timeout = 2, readtimeout = 3)
        return response.status == 200
    catch
        return false
    end
end

"""
    _friendly_error(e) -> String

Classify an exception into a user-friendly error message.
"""
function _friendly_error(e)
    msg = string(e)
    if e isa HTTP.Exceptions.ConnectError ||
       contains(msg, "ConnectError") ||
       contains(msg, "connection refused")
        return "Qdrant is not reachable at $(QDRANT_URL[]). Is it running?"
    elseif e isa HTTP.Exceptions.StatusError
        status = e.status
        if status == 404
            return "Collection not found (404)"
        elseif status == 400
            return "Bad request to Qdrant (400): $(first(msg, 200))"
        else
            return "Qdrant returned HTTP $status"
        end
    elseif contains(msg, "TimeoutError") || contains(msg, "timeout")
        return "Qdrant request timed out"
    else
        return "Qdrant error: $(first(msg, 300))"
    end
end

end # module

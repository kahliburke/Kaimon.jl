# ─────────────────────────────────────────────────────────────────────────────
# Kaimon Qdrant indexer · code chunking + AST definition extraction + window chunks  (split from qdrant_indexer.jl)
# ─────────────────────────────────────────────────────────────────────────────

"""
    chunk_code(content::String, file_path::String) -> Vector{Dict}

Split code into semantic chunks (functions, blocks) with metadata.
Returns vector of dicts with :text, :file, :start_line, :end_line, :type
"""
function chunk_code(content::String, file_path::String)
    chunks = Dict[]

    # Extract definitions using Julia's parser (functions, structs, macros)
    definition_chunks = extract_definitions(content, file_path)
    if !isempty(definition_chunks)
        append!(chunks, definition_chunks)
    end

    # Also create overlapping window chunks for full coverage
    window_chunks = create_window_chunks(content, file_path)
    append!(chunks, window_chunks)

    return chunks
end

"""
    extract_definitions(content::String, file_path::String) -> Vector{Dict}

Extract function, struct, and macro definitions using Julia's parser.
"""
function extract_definitions(content::String, file_path::String)
    chunks = Dict[]
    lines = split(content, '\n')

    # Parse the file
    expr = try
        Meta.parseall(content)
    catch e
        @debug "Failed to parse file" file_path exception = e
        return chunks
    end

    # Walk the AST to find definitions
    extract_from_expr!(chunks, expr, lines, file_path)
    return chunks
end

"""
    extract_from_expr!(chunks, expr, lines, file_path)

Recursively extract definitions from an expression.
"""
function extract_from_expr!(
    chunks::Vector{Dict},
    expr,
    lines::Vector{<:AbstractString},
    file_path::String,
)
    if expr isa Expr
        # Check for definition types
        if expr.head == :function || expr.head == :macro
            extract_definition!(chunks, expr, lines, file_path, "function")
        elseif expr.head == :struct || expr.head == :abstract || expr.head == :primitive
            extract_definition!(chunks, expr, lines, file_path, "struct")
        elseif expr.head == :(=) && length(expr.args) >= 1
            # Short function definition: f(x) = ...
            first_arg = expr.args[1]
            if first_arg isa Expr && first_arg.head == :call
                extract_definition!(chunks, expr, lines, file_path, "function")
            elseif first_arg isa Expr && first_arg.head == :const
                extract_definition!(chunks, expr, lines, file_path, "const")
            end
        elseif expr.head == :const
            extract_definition!(chunks, expr, lines, file_path, "const")
        elseif expr.head == :module
            # Recurse into module
            for arg in expr.args
                extract_from_expr!(chunks, arg, lines, file_path)
            end
        elseif expr.head == :toplevel || expr.head == :block
            # Recurse into blocks
            for arg in expr.args
                extract_from_expr!(chunks, arg, lines, file_path)
            end
        elseif expr.head == :macrocall && length(expr.args) >= 1
            macro_name = string(expr.args[1])
            if occursin("mcp_tool", macro_name)
                extract_definition!(chunks, expr, lines, file_path, "tool")
            else
                # Any other macro that wraps a definition — a docstring (`@doc`,
                # i.e. `"""..."""  <def>`) on a module/struct/function/const,
                # `Base.@kwdef struct`, etc. Recurse into the macrocall's Expr
                # arguments so the wrapped definition is found via normal dispatch.
                # NB: a file-leading docstring makes the WHOLE file
                # `@doc "..." module X ... end`; the old `@doc` branch only
                # descended into function/struct/=, so it skipped the module and
                # hid every symbol in the file.
                for arg in expr.args
                    arg isa Expr && extract_from_expr!(chunks, arg, lines, file_path)
                end
            end
        end
    end
end

"""
    extract_definition!(chunks, expr, lines, file_path, def_type)

Extract a single definition with its source location.
"""
function extract_definition!(
    chunks::Vector{Dict},
    expr::Expr,
    lines::Vector{<:AbstractString},
    file_path::String,
    def_type::String,
)
    # Get the name of the definition
    name = get_definition_name(expr)
    if name === nothing
        return
    end

    # Get source location if available
    start_line, end_line = get_expr_lines(expr, lines)
    if start_line === nothing
        return
    end

    # Extract the text
    text = join(lines[start_line:end_line], "\n")

    # Check for preceding docstring
    if start_line > 1
        prev_line = start_line - 1
        while prev_line >= 1 && isempty(strip(lines[prev_line]))
            prev_line -= 1
        end
        if prev_line >= 1 && endswith(strip(lines[prev_line]), "\"\"\"")
            # Find start of docstring
            doc_end = prev_line
            doc_start = prev_line
            while doc_start > 1
                doc_start -= 1
                if startswith(strip(lines[doc_start]), "\"\"\"")
                    break
                end
            end
            if doc_start < doc_end
                docstring = join(lines[doc_start:doc_end], "\n")
                text = docstring * "\n" * text
                start_line = doc_start
            end
        end
    end

    # Extract additional metadata from the expression
    metadata = extract_definition_metadata(expr, def_type)

    push!(
        chunks,
        Dict(
            "text" => text,
            "file" => file_path,
            "start_line" => start_line,
            "end_line" => end_line,
            "type" => def_type,
            "name" => name,
            "signature" => get(metadata, "signature", ""),
            "parameters" => get(metadata, "parameters", []),
            "type_params" => get(metadata, "type_params", []),
            "parent_type" => get(metadata, "parent_type", ""),
            "is_mutable" => get(metadata, "is_mutable", false),
            "is_exported" => false,  # Set during post-processing
        ),
    )
end

"""
    extract_definition_metadata(expr::Expr, def_type::String) -> Dict

Extract detailed metadata from a definition expression.
Returns a dict with signature, parameters, type parameters, etc.
"""
function extract_definition_metadata(expr::Expr, def_type::String)
    metadata = Dict{String,Any}()

    if expr.head == :function || expr.head == :macro
        if length(expr.args) >= 1
            sig = expr.args[1]

            # Extract full signature
            metadata["signature"] = string(sig)

            # Extract parameters
            params = extract_parameters(sig)
            metadata["parameters"] = params

            # Extract type parameters (where clause)
            type_params = extract_type_parameters(sig)
            metadata["type_params"] = type_params
        end
    elseif expr.head == :struct
        # Check if mutable
        metadata["is_mutable"] = length(expr.args) >= 1 && expr.args[1] == true

        if length(expr.args) >= 2
            name_expr = expr.args[2]

            # Extract parent type (for subtypes)
            if name_expr isa Expr && name_expr.head == :<:
                metadata["parent_type"] = string(name_expr.args[2])
            end

            # Extract type parameters
            if name_expr isa Expr && name_expr.head == :curly
                metadata["type_params"] = [string(p) for p in name_expr.args[2:end]]
            elseif name_expr isa Expr && name_expr.head == :<: && length(name_expr.args) >= 1
                inner = name_expr.args[1]
                if inner isa Expr && inner.head == :curly
                    metadata["type_params"] = [string(p) for p in inner.args[2:end]]
                end
            end
        end
    elseif expr.head == :abstract || expr.head == :primitive
        if length(expr.args) >= 2
            name_expr = expr.args[2]
            if name_expr isa Expr && name_expr.head == :<:
                metadata["parent_type"] = string(name_expr.args[2])
            end
        end
    end

    return metadata
end

"""
    extract_parameters(sig) -> Vector{String}

Extract parameter names and types from a function signature.
"""
function extract_parameters(sig)
    params = String[]

    if sig isa Expr
        # Handle where clause
        actual_sig = sig.head == :where ? sig.args[1] : sig

        if actual_sig isa Expr && actual_sig.head == :call && length(actual_sig.args) >= 2
            for arg in actual_sig.args[2:end]
                param_str = if arg isa Symbol
                    string(arg)
                elseif arg isa Expr && arg.head == :(::)
                    # x::Type or ::Type
                    if length(arg.args) >= 2
                        string(arg.args[1], "::", arg.args[2])
                    elseif length(arg.args) == 1
                        string("::", arg.args[1])
                    else
                        string(arg)
                    end
                elseif arg isa Expr && arg.head == :kw
                    # Keyword argument: x=default
                    string(arg.args[1], "=", arg.args[2])
                elseif arg isa Expr && arg.head == :parameters
                    # Skip parameters block (handled separately)
                    continue
                else
                    string(arg)
                end
                push!(params, param_str)
            end
        end
    end

    return params
end

"""
    extract_type_parameters(sig) -> Vector{String}

Extract type parameters from where clause.
"""
function extract_type_parameters(sig)
    type_params = String[]

    if sig isa Expr && sig.head == :where
        # Handle single or multiple type parameters
        for i in 2:length(sig.args)
            push!(type_params, string(sig.args[i]))
        end
    end

    return type_params
end

"""
    get_definition_name(expr) -> Union{String, Nothing}

Extract the name from a definition expression.
"""
function get_definition_name(expr::Expr)
    if expr.head == :function || expr.head == :macro
        if length(expr.args) >= 1
            sig = expr.args[1]
            if sig isa Expr && sig.head == :call && length(sig.args) >= 1
                return string(sig.args[1])
            elseif sig isa Expr && sig.head == :where
                # f(x::T) where T = ...
                return get_definition_name(Expr(:function, sig.args[1]))
            elseif sig isa Symbol
                return string(sig)
            end
        end
    elseif expr.head == :struct || expr.head == :abstract || expr.head == :primitive
        if length(expr.args) >= 2
            name_expr = expr.args[2]
            if name_expr isa Symbol
                return string(name_expr)
            elseif name_expr isa Expr && name_expr.head == :<:
                return string(name_expr.args[1])
            elseif name_expr isa Expr && name_expr.head == :curly
                return string(name_expr.args[1])
            end
        end
    elseif expr.head == :(=) && length(expr.args) >= 1
        first_arg = expr.args[1]
        if first_arg isa Expr && first_arg.head == :call
            return string(first_arg.args[1])
        end
    elseif expr.head == :const && length(expr.args) >= 1
        inner = expr.args[1]
        if inner isa Expr && inner.head == :(=)
            return string(inner.args[1])
        end
    elseif expr.head == :macrocall
        # Try to find tool name from @mcp_tool
        for arg in expr.args
            if arg isa QuoteNode
                return string(arg.value)
            end
        end
    end
    return nothing
end

"""
    get_expr_lines(expr, lines) -> Tuple{Union{Int,Nothing}, Union{Int,Nothing}}

Get the start and end line numbers for an expression.
Uses heuristics based on expression structure.
"""
function get_expr_lines(expr::Expr, lines::Vector{<:AbstractString})
    # For functions/macros, look for the signature
    if expr.head in (:function, :macro) && length(expr.args) >= 1
        name = get_definition_name(expr)
        if name !== nothing
            # Find line containing "function name" or "macro name"
            keyword = expr.head == :function ? "function" : "macro"
            for (i, line) in enumerate(lines)
                if occursin(Regex("^\\s*$keyword\\s+$name"), line)
                    # Find matching end
                    depth = 1
                    for j = (i+1):length(lines)
                        l = strip(lines[j])
                        if startswith(l, "function ") ||
                           startswith(l, "macro ") ||
                           startswith(l, "if ") ||
                           startswith(l, "for ") ||
                           startswith(l, "while ") ||
                           startswith(l, "let ") ||
                           startswith(l, "begin") ||
                           startswith(l, "try") ||
                           startswith(l, "struct ") ||
                           startswith(l, "module ")
                            depth += 1
                        elseif l == "end" || startswith(l, "end ")
                            depth -= 1
                            if depth == 0
                                return (i, j)
                            end
                        end
                    end
                end
            end
        end
    elseif expr.head == :struct
        name = get_definition_name(expr)
        if name !== nothing
            for (i, line) in enumerate(lines)
                if occursin(Regex("^\\s*(mutable\\s+)?struct\\s+$name"), line)
                    for j = (i+1):length(lines)
                        if strip(lines[j]) == "end"
                            return (i, j)
                        end
                    end
                end
            end
        end
    elseif expr.head == :(=) && length(expr.args) >= 1
        # Short function definition - single line
        first_arg = expr.args[1]
        if first_arg isa Expr && first_arg.head == :call
            name = string(first_arg.args[1])
            for (i, line) in enumerate(lines)
                if occursin(Regex("^\\s*$name\\s*\\(.*\\)\\s*="), line)
                    return (i, i)
                end
            end
        end
    elseif expr.head == :const
        # `const NAME = ...` — locate the declaring line (consts had no line
        # lookup, so they were silently dropped from results entirely).
        name = get_definition_name(expr)
        if name !== nothing
            for (i, line) in enumerate(lines)
                if occursin(Regex("^\\s*const\\s+$name\\b"), line)
                    return (i, i)
                end
            end
        end
    end

    return (nothing, nothing)
end

"""
    create_window_chunks(content::String, file_path::String) -> Vector{Dict}

Create overlapping window chunks for full file coverage.
"""
function create_window_chunks(content::String, file_path::String)
    chunks = Dict[]
    lines = split(content, '\n')

    if length(content) <= CHUNK_SIZE
        # Small file - single chunk
        push!(
            chunks,
            Dict(
                "text" => content,
                "file" => file_path,
                "start_line" => 1,
                "end_line" => length(lines),
                "type" => "window",
                "name" => basename(file_path),
            ),
        )
        return chunks
    end

    # Create overlapping windows
    chunk_lines = 50  # Approximate lines per chunk
    overlap_lines = 10

    start_line = 1
    while start_line <= length(lines)
        end_line = min(start_line + chunk_lines - 1, length(lines))
        text = join(lines[start_line:end_line], "\n")

        # Extend if we're in the middle of something, but respect CHUNK_SIZE limit
        while end_line < length(lines) && length(text) < CHUNK_SIZE
            next_text = join(lines[start_line:(end_line+1)], "\n")
            if length(next_text) > CHUNK_SIZE
                break  # Don't exceed CHUNK_SIZE
            end
            end_line += 1
            text = next_text
        end

        push!(
            chunks,
            Dict(
                "text" => text,
                "file" => file_path,
                "start_line" => start_line,
                "end_line" => end_line,
                "type" => "window",
                "name" => "$(basename(file_path)):$(start_line)-$(end_line)",
            ),
        )

        # Move to next chunk with overlap, but ensure we make progress
        next_start = end_line - overlap_lines + 1
        if next_start <= start_line
            # Prevent infinite loop - move at least one line forward
            next_start = start_line + 1
        end
        start_line = next_start

        # Exit if we've covered the whole file
        if end_line >= length(lines)
            break
        end
    end

    return chunks
end

"""
    split_chunk_recursive(chunk::Dict, max_length::Int, model::String) -> Vector{Dict}

Recursively split a chunk if it's too large or fails to embed.
Returns a vector of successfully embedded sub-chunks with their embeddings.
"""
function split_chunk_recursive(chunk::Dict, max_length::Int, model::String, depth::Int=0)
    text = chunk["text"]

    # Limit recursion depth to prevent infinite loops
    if depth > 10
        with_index_logger(() -> @warn "Maximum recursion depth reached for chunk splitting" file = chunk["file"] start_line = chunk["start_line"])
        return Dict[]
    end

    # Try to embed the chunk as-is if it's within size limit
    if length(text) <= max_length
        embedding = get_ollama_embedding(text; model=model)
        if !isempty(embedding)
            # Success - return chunk with embedding
            return [merge(chunk, Dict("embedding" => embedding, "text" => text))]
        end
        # Embedding failed even though text is small enough - try splitting anyway
    end

    # Text is too large or embedding failed - split in half by lines
    lines = split(text, '\n')
    if length(lines) <= 1
        # Can't split further - just truncate
        with_index_logger(() -> @warn "Cannot split chunk further, truncating" file = chunk["file"] start_line = chunk["start_line"] original_length = length(text))
        truncated = first(text, max_length)
        embedding = get_ollama_embedding(truncated; model=model)
        if !isempty(embedding)
            return [merge(chunk, Dict("embedding" => embedding, "text" => truncated))]
        else
            return Dict[]
        end
    end

    # Split into two halves
    mid = div(length(lines), 2)
    first_half_text = join(lines[1:mid], '\n')
    second_half_text = join(lines[mid+1:end], '\n')

    # Calculate approximate line numbers for each half
    start_line = chunk["start_line"]
    end_line = chunk["end_line"]
    mid_line = start_line + mid

    # Create sub-chunks
    chunk1 = merge(chunk, Dict(
        "text" => first_half_text,
        "end_line" => mid_line,
        "name" => chunk["name"] * " (part 1)"
    ))

    chunk2 = merge(chunk, Dict(
        "text" => second_half_text,
        "start_line" => mid_line + 1,
        "name" => chunk["name"] * " (part 2)"
    ))

    # Recursively process each half
    results = Dict[]
    append!(results, split_chunk_recursive(chunk1, max_length, model, depth + 1))
    append!(results, split_chunk_recursive(chunk2, max_length, model, depth + 1))

    return results
end


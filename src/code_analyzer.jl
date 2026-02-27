"""
Code Analysis Tools for Kaimon

Identifies duplicate code, similar patterns, and refactoring opportunities.
"""
module CodeAnalyzer


export analyze_codebase, find_duplicates, find_similar_functions

# Simple hash-based code fingerprint
function code_fingerprint(expr)
    # Normalize the expression by removing variable names and literals
    normalized = normalize_expr(expr)
    return hash(string(normalized))
end

function normalize_expr(expr)
    if expr isa Expr
        # Remove line number nodes
        if expr.head == :line
            return nothing
        end
        # Normalize variable names to generic placeholders
        if expr.head == :(=) && length(expr.args) >= 2
            return Expr(expr.head, :VAR, normalize_expr(expr.args[2]))
        end
        # Recursively normalize children
        normalized_args = filter(!isnothing, [normalize_expr(arg) for arg in expr.args])
        return Expr(expr.head, normalized_args...)
    elseif expr isa Symbol
        # Keep keywords/operators, genericize variable names
        if expr in [
            :function,
            :if,
            :for,
            :while,
            :let,
            :try,
            :catch,
            :return,
            :+,
            :-,
            :*,
            :/,
            :&&,
            :||,
        ]
            return expr
        else
            return :VAR
        end
    elseif expr isa String
        return :STRING
    elseif expr isa Number
        return :NUMBER
    else
        return expr
    end
end

# Extract all functions from a file
function extract_functions(file_path::String)
    if !isfile(file_path)
        return []
    end

    try
        content = read(file_path, String)
        expr = Meta.parseall(content)
        functions = []
        extract_functions_recursive!(functions, expr, file_path)
        return functions
    catch e
        @warn "Failed to parse $file_path" exception = e
        return []
    end
end

function extract_functions_recursive!(functions, expr, file_path, start_line = 1)
    if expr isa Expr
        # Check if this is a function definition
        if expr.head in [:function, :(=)] && length(expr.args) >= 2
            func_sig = expr.args[1]
            func_body = length(expr.args) >= 2 ? expr.args[2] : nothing

            # Extract function name
            func_name = if func_sig isa Expr && func_sig.head == :call
                string(func_sig.args[1])
            elseif func_sig isa Symbol
                string(func_sig)
            else
                "anonymous"
            end

            # Count lines in function body
            func_str = string(expr)
            line_count = count('\n', func_str) + 1

            push!(
                functions,
                (
                    name = func_name,
                    expr = expr,
                    file = file_path,
                    line = start_line,
                    lines = line_count,
                    fingerprint = code_fingerprint(expr),
                ),
            )
        end

        # Recursively search for nested functions
        for arg in expr.args
            extract_functions_recursive!(functions, arg, file_path, start_line)
        end
    end
end

"""
    find_duplicates(directory::String = "src/"; threshold=0.95)

Find duplicate or highly similar code blocks in the codebase.
Returns a list of duplicate pairs with similarity scores.
"""
function find_duplicates(directory::String = "src/"; threshold = 0.95)
    # Find all Julia files
    files = String[]
    for (root, dirs, filenames) in walkdir(directory)
        for filename in filenames
            if endswith(filename, ".jl")
                push!(files, joinpath(root, filename))
            end
        end
    end

    # Extract all functions
    all_functions = []
    for file in files
        append!(all_functions, extract_functions(file))
    end

    println("📊 Analyzed $(length(files)) files, found $(length(all_functions)) functions\n")

    # Group by fingerprint (exact structural duplicates)
    fingerprint_groups = Dict{UInt64,Vector{Any}}()
    for func in all_functions
        if !haskey(fingerprint_groups, func.fingerprint)
            fingerprint_groups[func.fingerprint] = []
        end
        push!(fingerprint_groups[func.fingerprint], func)
    end

    # Report duplicates
    duplicates = []
    for (fp, group) in fingerprint_groups
        if length(group) > 1
            push!(duplicates, group)
        end
    end

    if isempty(duplicates)
        println("✓ No exact structural duplicates found!")
    else
        println("🔍 Found $(length(duplicates)) groups of duplicate code:\n")
        for (i, group) in enumerate(duplicates)
            println("Group $i: $(length(group)) instances")
            for func in group
                println(
                    "  • $(func.name) at $(func.file):$(func.line) ($(func.lines) lines)",
                )
            end
            println()
        end
    end

    return duplicates
end

"""
    analyze_codebase(directory::String = "src/")

Comprehensive code analysis: size, complexity, and potential issues.
"""
function analyze_codebase(directory::String = "src/")
    files = String[]
    for (root, dirs, filenames) in walkdir(directory)
        for filename in filenames
            if endswith(filename, ".jl")
                push!(files, joinpath(root, filename))
            end
        end
    end

    total_lines = 0
    total_functions = 0
    large_files = []
    large_functions = []

    println("📈 Code Analysis Report")
    println("="^70)
    println()

    for file in files
        lines = countlines(file)
        total_lines += lines

        functions = extract_functions(file)
        total_functions += length(functions)

        # Track large files
        if lines > 500
            push!(large_files, (file = file, lines = lines))
        end

        # Track large functions
        for func in functions
            if func.lines > 50
                push!(
                    large_functions,
                    (
                        name = func.name,
                        file = func.file,
                        line = func.line,
                        lines = func.lines,
                    ),
                )
            end
        end
    end

    println("📁 Files: $(length(files))")
    println("📝 Total lines: $total_lines")
    println("🔧 Total functions: $total_functions")
    println("📏 Average file size: $(round(total_lines / length(files), digits=1)) lines")
    println()

    if !isempty(large_files)
        println("⚠️  Large files (>500 lines):")
        sort!(large_files, by = x -> x.lines, rev = true)
        for (i, item) in enumerate(large_files[1:min(10, end)])
            rel_path = relpath(item.file, dirname(directory))
            println("  $i. $rel_path ($(item.lines) lines)")
        end
        println()
    end

    if !isempty(large_functions)
        println("⚠️  Large functions (>50 lines):")
        sort!(large_functions, by = x -> x.lines, rev = true)
        for (i, func) in enumerate(large_functions[1:min(10, end)])
            rel_path = relpath(func.file, dirname(directory))
            println("  $i. $(func.name) at $rel_path:$(func.line) ($(func.lines) lines)")
        end
        println()
    end

    return (
        total_files = length(files),
        total_lines = total_lines,
        total_functions = total_functions,
        large_files = large_files,
        large_functions = large_functions,
    )
end

"""
    find_similar_functions(directory::String = "src/"; min_similarity=0.7)

Find functions with similar structure that might benefit from refactoring.
"""
function find_similar_functions(directory::String = "src/"; min_similarity = 0.7)
    files = String[]
    for (root, dirs, filenames) in walkdir(directory)
        for filename in filenames
            if endswith(filename, ".jl")
                push!(files, joinpath(root, filename))
            end
        end
    end

    all_functions = []
    for file in files
        append!(all_functions, extract_functions(file))
    end

    similar_pairs = []

    # Compare all pairs of functions
    for i in eachindex(all_functions)
        for j = (i+1):lastindex(all_functions)
            func1 = all_functions[i]
            func2 = all_functions[j]

            # Calculate simple structural similarity
            similarity = structural_similarity(func1.expr, func2.expr)

            if similarity >= min_similarity && similarity < 1.0
                push!(
                    similar_pairs,
                    (func1 = func1, func2 = func2, similarity = similarity),
                )
            end
        end
    end

    if !isempty(similar_pairs)
        sort!(similar_pairs, by = x -> x.similarity, rev = true)
        println("🔄 Found $(length(similar_pairs)) pairs of similar functions:\n")
        for (i, pair) in enumerate(similar_pairs[1:min(20, end)])
            sim_pct = round(pair.similarity * 100, digits = 1)
            println("$i. $(sim_pct)% similar:")
            println(
                "   • $(pair.func1.name) at $(relpath(pair.func1.file, dirname(directory))):$(pair.func1.line)",
            )
            println(
                "   • $(pair.func2.name) at $(relpath(pair.func2.file, dirname(directory))):$(pair.func2.line)",
            )
            println()
        end
    else
        println("✓ No highly similar functions found (threshold: $(min_similarity*100)%)")
    end

    return similar_pairs
end

function structural_similarity(expr1, expr2)
    # Simple Jaccard similarity based on AST nodes
    nodes1 = collect_nodes(expr1)
    nodes2 = collect_nodes(expr2)

    if isempty(nodes1) && isempty(nodes2)
        return 1.0
    elseif isempty(nodes1) || isempty(nodes2)
        return 0.0
    end

    intersection = length(intersect(nodes1, nodes2))
    union_count = length(Base.union(nodes1, nodes2))

    return intersection / union_count
end

function collect_nodes(expr, nodes = String[])
    if expr isa Expr
        push!(nodes, string(expr.head))
        for arg in expr.args
            collect_nodes(arg, nodes)
        end
    elseif expr isa Symbol
        push!(nodes, string(expr))
    end
    return nodes
end

end # module

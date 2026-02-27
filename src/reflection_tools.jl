# ============================================================================
# Reflection-Based Code Navigation Tools
# ============================================================================
#
# Replacements for the former LSP tools, using Julia's built-in reflection
# (methods, functionloc, pathof, names) + server-side AST parsing.
# No VS Code or LanguageServer.jl dependency required.

"""
    extract_symbol_at_position(file_path, line, col) -> String

Read `file_path`, find the identifier at the given 1-indexed `line` and `col`.
Handles dotted names like `Base.sort`.
Returns an empty string if nothing is found.
"""
function extract_symbol_at_position(file_path::String, line::Int, col::Int)::String
    isfile(file_path) || return ""
    file_lines = try
        readlines(file_path)
    catch
        return ""
    end
    (line < 1 || line > length(file_lines)) && return ""
    text_line = file_lines[line]
    (col < 1 || col > length(text_line)) && return ""

    # Scan backwards to find start of identifier (alphanumeric, _, !, .)
    start_col = col
    while start_col > 1 && occursin(r"[A-Za-z0-9_!.]", string(text_line[start_col-1]))
        start_col -= 1
    end
    # Scan forwards to find end of identifier (include . for dotted names)
    end_col = col
    while end_col <= length(text_line) &&
        occursin(r"[A-Za-z0-9_!.]", string(text_line[end_col]))
        end_col += 1
    end

    sym = text_line[start_col:end_col-1]
    # Strip leading/trailing dots
    sym = strip(sym, '.')
    return sym
end

"""
    grep_project_for_definition(symbol::String) -> Vector{String}

Server-side fallback: grep `.jl` files under the project `src/` directory
for common definition patterns matching `symbol`.
Returns a vector of `"file:line"` strings.
"""
function grep_project_for_definition(symbol::String)::Vector{String}
    results = String[]
    isempty(symbol) && return results

    # Escape regex-special characters in the symbol name
    esc_sym = replace(symbol, r"([.+*?^${}()|[\]\\])" => s"\\\1")

    patterns = [
        Regex("^\\s*function\\s+$esc_sym\\b"),
        Regex("^\\s*$esc_sym\\s*\\(.*\\)\\s*="),
        Regex("^\\s*(mutable\\s+)?struct\\s+$esc_sym\\b"),
        Regex("^\\s*abstract\\s+type\\s+$esc_sym\\b"),
        Regex("^\\s*const\\s+$esc_sym\\b"),
        Regex("^\\s*macro\\s+$esc_sym\\b"),
    ]

    # Search in project src/ directory
    project_dir = get(ENV, "MCPREPL_PROJECT_DIR", pwd())
    src_dir = joinpath(project_dir, "src")
    isdir(src_dir) || return results

    for (root, dirs, files) in walkdir(src_dir)
        for file in files
            endswith(file, ".jl") || continue
            fpath = joinpath(root, file)
            try
                for (lineno, line) in enumerate(eachline(fpath))
                    for pat in patterns
                        if occursin(pat, line)
                            push!(results, "$fpath:$lineno")
                            break  # one match per line is enough
                        end
                    end
                end
            catch
                # skip unreadable files
            end
        end
    end

    return unique(results)
end

# --------------------------------------------------------------------------
# Tool: goto_definition
# --------------------------------------------------------------------------

goto_definition_tool = @mcp_tool(
    :goto_definition,
    "Find where a symbol is defined using Julia reflection. Provide the position where a symbol is USED/REFERENCED, and this returns the file path and position where that symbol is DEFINED. Uses `methods`/`functionloc`/`pathof` on the gate with a file-grep fallback.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "file_path" => Dict(
                "type" => "string",
                "description" => "Absolute path to the file where the symbol is referenced/used",
            ),
            "line" => Dict(
                "type" => "integer",
                "description" => "Line number where the symbol is referenced (1-indexed)",
            ),
            "column" => Dict(
                "type" => "integer",
                "description" => "Column number where the symbol is referenced (1-indexed)",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["file_path", "line", "column"],
    ),
    function (args)
        try
            file_path = get(args, "file_path", "")
            line = get(args, "line", 1)
            column = get(args, "column", 1)
            session = get(args, "session", "")

            if isempty(file_path)
                return "Error: file_path is required"
            end
            if !isfile(file_path)
                return "Error: File not found: $file_path"
            end

            symbol = extract_symbol_at_position(file_path, line, column)
            if isempty(symbol)
                return "Error: Could not extract symbol at $file_path:$line:$column"
            end

            # Try gate-side reflection first
            gate_results = String[]
            gate_available = GATE_MODE[] || GATE_CONN_MGR[] !== nothing

            if gate_available
                # Build gate code that resolves the symbol via reflection
                # Use a safe quoting strategy for the symbol
                safe_sym = replace(symbol, "\"" => "\\\"")
                gate_code = """
let _result = String[]
    _sym = try Core.eval(Main, Meta.parse("$safe_sym")) catch; nothing end
    if _sym isa Function
        for m in methods(_sym)
            f = Base.find_source_file(string(m.file))
            f !== nothing && isfile(f) && push!(_result, "\$(f):\$(m.line)")
        end
    elseif _sym isa Module
        p = pathof(_sym)
        p !== nothing && push!(_result, "\$(p):1")
    elseif _sym isa Type
        for m in methods(_sym)
            f = Base.find_source_file(string(m.file))
            f !== nothing && isfile(f) && (push!(_result, "\$(f):\$(m.line)"); break)
        end
    end
    isempty(_result) ? "NOT_FOUND" : join(unique(_result), "|||")
end
"""
                try
                    raw = if GATE_MODE[]
                        Base.invokelatest(
                            execute_via_gate,
                            gate_code;
                            quiet = false,
                            silent = true,
                            max_output = 6000,
                            session = session,
                        )
                    else
                        Base.invokelatest(
                            execute_repllike,
                            gate_code;
                            silent = true,
                            quiet = false,
                            max_output = 6000,
                            session = session,
                        )
                    end
                    raw_str = strip(string(raw))
                    # Strip surrounding quotes from string result
                    if startswith(raw_str, "\"") && endswith(raw_str, "\"")
                        raw_str = raw_str[2:end-1]
                    end
                    if raw_str != "NOT_FOUND" && !isempty(raw_str)
                        gate_results = filter(!isempty, split(raw_str, "|||"))
                    end
                catch e
                    @debug "goto_definition gate call failed" exception = e
                end
            end

            # Fallback: server-side grep
            if isempty(gate_results)
                grep_results = grep_project_for_definition(symbol)
                if !isempty(grep_results)
                    result = "Found $(length(grep_results)) definition(s) for `$symbol` (file search):\n"
                    for (i, loc) in enumerate(grep_results)
                        result *= "  $i. $loc\n"
                    end
                    return result
                end
                return "No definition found for `$symbol`"
            end

            result = "Found $(length(gate_results)) definition(s) for `$symbol`:\n"
            for (i, loc) in enumerate(gate_results)
                result *= "  $i. $loc\n"
            end
            return result

        catch e
            return "Error finding definition: $e"
        end
    end
)

# --------------------------------------------------------------------------
# Tool: document_symbols
# --------------------------------------------------------------------------

document_symbols_tool = @mcp_tool(
    :document_symbols,
    "List all symbols in a file using Julia AST parsing. Returns functions, structs, macros, and constants with their line numbers. No gate connection needed.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "file_path" => Dict(
                "type" => "string",
                "description" => "Absolute path to the file",
            ),
        ),
        "required" => ["file_path"],
    ),
    function (args)
        try
            file_path = get(args, "file_path", "")

            if isempty(file_path)
                return "Error: file_path is required"
            end
            if !isfile(file_path)
                return "Error: File not found: $file_path"
            end

            content = read(file_path, String)
            defs = extract_definitions(content, file_path)

            if isempty(defs)
                return "No symbols found in $file_path"
            end

            # Map def_type to a display kind
            kind_map = Dict(
                "function" => "Function",
                "struct" => "Type",
                "const" => "Constant",
                "tool" => "Tool",
            )

            result = "Found $(length(defs)) symbol(s) in $(basename(file_path)):\n"
            for (i, d) in enumerate(defs)
                kind = get(kind_map, get(d, "type", ""), "Unknown")
                name = get(d, "name", "?")
                sig = get(d, "signature", "")
                line_num = get(d, "start_line", 0)
                display_name = isempty(sig) ? name : sig
                result *= "  $i. [$kind] $display_name @ line $line_num\n"
            end
            return result

        catch e
            return "Error listing symbols: $e"
        end
    end
)

# --------------------------------------------------------------------------
# Tool: workspace_symbols
# --------------------------------------------------------------------------

workspace_symbols_tool = @mcp_tool(
    :workspace_symbols,
    "Search for symbols across loaded Julia modules by name. Uses `names()` on the gate to find matching functions, types, modules, and constants.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "query" => Dict(
                "type" => "string",
                "description" => "Search query for symbol names",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["query"],
    ),
    function (args)
        try
            query = get(args, "query", "")
            session = get(args, "session", "")

            if isempty(query)
                return "Error: query is required"
            end

            gate_available = GATE_MODE[] || GATE_CONN_MGR[] !== nothing
            if !gate_available
                return "Error: workspace_symbols requires a connected Julia session. No gate/session available."
            end

            safe_query = replace(query, "\"" => "\\\"")
            gate_code = """
let _results = String[]
    _query = lowercase("$safe_query")
    for mod in vcat(collect(values(Base.loaded_modules)), [Main])
        mod_name = string(nameof(mod))
        for sym_name in names(mod; all=false)
            sn = string(sym_name)
            startswith(sn, "#") && continue
            if occursin(_query, lowercase(sn))
                _kind = "Unknown"
                _loc = ""
                try
                    obj = getfield(mod, sym_name)
                    if obj isa Function
                        _kind = "Function"
                        try
                            ml = first(methods(obj))
                            f = Base.find_source_file(string(ml.file))
                            if f !== nothing && isfile(f)
                                _loc = " @ \$(f):\$(ml.line)"
                            end
                        catch; end
                    elseif obj isa Type
                        _kind = "Type"
                    elseif obj isa Module
                        _kind = "Module"
                        try
                            p = pathof(obj)
                            p !== nothing && (_loc = " @ \$(p):1")
                        catch; end
                    else
                        _kind = "Constant"
                    end
                catch; end
                push!(_results, "[\$(_kind)] \$(mod_name).\$(sn)\$(_loc)")
                length(_results) >= 50 && break
            end
        end
        length(_results) >= 50 && break
    end
    isempty(_results) ? "NO_MATCHES" : join(unique(_results), "|||")
end
"""
            raw = if GATE_MODE[]
                Base.invokelatest(
                    execute_via_gate,
                    gate_code;
                    quiet = false,
                    silent = true,
                    max_output = 6000,
                    session = session,
                )
            else
                Base.invokelatest(
                    execute_repllike,
                    gate_code;
                    silent = true,
                    quiet = false,
                    max_output = 6000,
                    session = session,
                )
            end

            raw_str = strip(string(raw))
            # Strip surrounding quotes from string result
            if startswith(raw_str, "\"") && endswith(raw_str, "\"")
                raw_str = raw_str[2:end-1]
            end
            if raw_str == "NO_MATCHES" || isempty(raw_str)
                return "No symbols matching `$query` found in loaded modules"
            end

            entries = filter(!isempty, split(raw_str, "|||"))
            result = "Found $(length(entries)) symbol(s) matching `$query`:\n"
            for (i, entry) in enumerate(entries)
                result *= "  $i. $entry\n"
            end
            return result

        catch e
            return "Error searching symbols: $e"
        end
    end
)

# ============================================================================
# Factory
# ============================================================================

"""
    create_reflection_tools() -> Vector{MCPTool}

Return the reflection-based code navigation tools (replacing former LSP tools).
"""
function create_reflection_tools()::Vector{MCPTool}
    return MCPTool[goto_definition_tool, document_symbols_tool, workspace_symbols_tool]
end

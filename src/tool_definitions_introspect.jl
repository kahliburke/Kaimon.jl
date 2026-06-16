# ─────────────────────────────────────────────────────────────────────────────
# Kaimon MCP tools · code introspection & analysis (search/type/profile/format/lint/…)  (split from tool_definitions.jl)
# ─────────────────────────────────────────────────────────────────────────────

investigate_tool = @mcp_tool(
    :investigate_environment,
    "Get current Julia environment info: pwd, active project, packages, dev packages, and Revise status.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => [],
    ),
    args -> begin
        try
            ses = get(args, "session", "")
            code = raw"""
            begin
                import Pkg
                import TOML

                io = IOBuffer()

                # Project info
                active_proj = Base.active_project()
                if active_proj !== nothing
                    try
                        pd = TOML.parsefile(active_proj)
                        name = get(pd, "name", basename(dirname(active_proj)))
                        ver = get(pd, "version", "")
                        print(io, "Project: $name")
                        !isempty(ver) && print(io, " v$ver")
                        println(io)
                    catch
                        println(io, "Project: $(basename(dirname(active_proj)))")
                    end
                    println(io, "Path: $(dirname(active_proj))")
                else
                    println(io, "Project: (none)")
                end
                println(io, "pwd: $(pwd())")

                # Dev packages only (the ones that matter for development)
                try
                    deps = Pkg.dependencies()
                    dev_pkgs = [(info.name, info.version, info.source)
                                for (_, info) in deps
                                if info.is_direct_dep && info.is_tracking_path]
                    sort!(dev_pkgs; by = first)
                    if !isempty(dev_pkgs)
                        println(io, "Dev packages:")
                        for (name, ver, src) in dev_pkgs
                            println(io, "  $name v$ver => $src")
                        end
                    end
                catch; end

                # Revise status (one line)
                revise = isdefined(Main, :Revise)
                println(io, "Revise: $(revise ? "active" : "not loaded")")

                String(take!(io))
            end
            """
            execute_repllike(
                code;
                description = "[Investigating environment]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error investigating environment: $e"
        end
    end
)

search_methods_tool = @mcp_tool(
    :search_methods,
    "Search for all methods of a function or methods matching a type signature.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "query" => Dict(
                "type" => "string",
                "description" => "Function name or type to search (e.g., 'println', 'String', 'Base.sort')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["query"],
    ),
    args -> begin
        try
            query = get(args, "query", "")
            ses = get(args, "session", "")
            if isempty(query)
                return "Error: query parameter is required"
            end
            code = """
            using InteractiveUtils
            target = $query
            if isa(target, Type)
                println("Methods with argument type \$target:")
                println("=" ^ 60)
                methodswith(target)
            else
                println("Methods for \$target:")
                println("=" ^ 60)
                methods(target)
            end
            """
            execute_repllike(
                code;
                description = "[Searching methods for: $query]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error searching methods: $e"
        end
    end
)

macro_expand_tool = @mcp_tool(
    :macro_expand,
    "Expand a macro to see the generated code.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "expression" => Dict(
                "type" => "string",
                "description" => "Macro expression to expand (e.g., '@time sleep(1)')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["expression"],
    ),
    args -> begin
        try
            expr = get(args, "expression", "")
            ses = get(args, "session", "")
            if isempty(expr)
                return "Error: expression parameter is required"
            end

            code = """
            using InteractiveUtils
            @macroexpand $expr
            """
            execute_repllike(
                code;
                description = "[Expanding macro: $expr]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error expanding macro: \$e"
        end
    end
)

"""
    _type_info_code(type_expr) -> String

Build the self-contained introspection code run in the gate session for
`type_info`. Handles `Union` and `UnionAll` types — where `supertype`,
`fieldnames`, and `subtypes` are undefined — in addition to ordinary `DataType`s,
so querying e.g. `Union{Int,String}` reports the members instead of throwing
`MethodError: no method matching supertype(::Union)`.
"""
function _type_info_code(type_expr::AbstractString)::String
    return """
    using InteractiveUtils
    T = $type_expr
    _buf = IOBuffer()
    print(_buf, "Type Information for: \$T\\n")
    print(_buf, "=" ^ 60, "\\n\\n")
    if T isa Union
        print(_buf, "Kind: Union type\\n\\nMembers:\\n")
        for t in Base.uniontypes(T)
            print(_buf, "  - \$t\\n")
        end
    elseif T isa UnionAll
        print(_buf, "Kind: UnionAll (parametric) type\\n")
        print(_buf, "Base type: \$(Base.unwrap_unionall(T))\\n")
    else
        print(_buf, "Abstract: ", isabstracttype(T), "\\n")
        print(_buf, "Primitive: ", isprimitivetype(T), "\\n")
        print(_buf, "Mutable: ", ismutabletype(T), "\\n\\n")
        print(_buf, "Supertype: ", supertype(T), "\\n")
        if !isabstracttype(T)
            print(_buf, "\\nFields:\\n")
            if fieldcount(T) > 0
                for (i, fname) in enumerate(fieldnames(T))
                    ftype = fieldtype(T, i)
                    print(_buf, "  \$i. \$fname :: \$ftype\\n")
                end
            else
                print(_buf, "  (no fields)\\n")
            end
        end
        print(_buf, "\\nDirect subtypes:\\n")
        subs = subtypes(T)
        if isempty(subs)
            print(_buf, "  (no direct subtypes)\\n")
        else
            for sub in subs
                print(_buf, "  - \$sub\\n")
            end
        end
    end
    String(take!(_buf))
    """
end

type_info_tool = @mcp_tool(
    :type_info,
    "Get type information: hierarchy, fields, parameters, and properties.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "type_expr" => Dict(
                "type" => "string",
                "description" => "Type expression to inspect (e.g., 'String', 'Vector{Int}', 'AbstractArray')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["type_expr"],
    ),
    args -> begin
        try
            type_expr = get(args, "type_expr", "")
            ses = get(args, "session", "")
            if isempty(type_expr)
                return "Error: type_expr parameter is required"
            end

            execute_repllike(
                _type_info_code(type_expr);
                description = "[Getting type info for: $type_expr]",
                quiet = false,
                show_prompt = false,
                session = ses,
            )
        catch e
            "Error getting type info: $e"
        end
    end
)

profile_tool = @mcp_tool(
    :profile_code,
    "Profile Julia code to identify performance bottlenecks.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "code" =>
                Dict("type" => "string", "description" => "Julia code to profile"),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["code"],
    ),
    args -> begin
        try
            code_to_profile = get(args, "code", "")
            ses = get(args, "session", "")
            if isempty(code_to_profile)
                return "Error: code parameter is required"
            end

            wrapper = """
            using Profile
            Profile.clear()
            @profile begin
                $code_to_profile
            end
            Profile.print(format=:flat, sortedby=:count)
            """
            execute_repllike(
                wrapper;
                description = "[Profiling code]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error profiling code: \$e"
        end
    end
)

list_names_tool = @mcp_tool(
    :list_names,
    "List all exported names in a module or package.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "module_name" => Dict(
                "type" => "string",
                "description" => "Module name (e.g., 'Base', 'Core', 'Main')",
            ),
            "all" => Dict(
                "type" => "boolean",
                "description" => "Include non-exported names (default: false)",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["module_name"],
    ),
    args -> begin
        try
            module_name = get(args, "module_name", "")
            show_all = get(args, "all", false)
            ses = get(args, "session", "")

            if isempty(module_name)
                return "Error: module_name parameter is required"
            end

            code = """
            mod = $module_name
            _buf = IOBuffer()
            print(_buf, "Names in \$mod" * (($show_all) ? " (all=true)" : " (exported only)") * ":\\n")
            print(_buf, "=" ^ 60, "\\n")
            name_list = names(mod, all=$show_all)
            for name in sort(name_list)
                print(_buf, "  ", name, "\\n")
            end
            print(_buf, "\\nTotal: ", length(name_list), " names\\n")
            String(take!(_buf))
            """
            execute_repllike(
                code;
                description = "[Listing names in: $module_name]",
                quiet = false,
                show_prompt = false,
                session = ses,
            )
        catch e
            "Error listing names: \$e"
        end
    end
)

code_lowered_tool = @mcp_tool(
    :code_lowered,
    "Show lowered (desugared) IR for a function.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "function_expr" => Dict(
                "type" => "string",
                "description" => "Function to inspect (e.g., 'sin', 'Base.sort')",
            ),
            "types" => Dict(
                "type" => "string",
                "description" => "Argument types as tuple (e.g., '(Float64,)', '(Int, Int)')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["function_expr", "types"],
    ),
    args -> code_introspection_tool(
        "code_lowered",
        "Getting lowered code for",
        args;
        session = get(args, "session", ""),
    )
)

code_typed_tool = @mcp_tool(
    :code_typed,
    "Show type-inferred code for a function (for debugging type stability).",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "function_expr" => Dict(
                "type" => "string",
                "description" => "Function to inspect (e.g., 'sin', 'Base.sort')",
            ),
            "types" => Dict(
                "type" => "string",
                "description" => "Argument types as tuple (e.g., '(Float64,)', '(Int, Int)')",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["function_expr", "types"],
    ),
    args -> code_introspection_tool(
        "code_typed",
        "Getting typed code for",
        args;
        session = get(args, "session", ""),
    )
)

# Optional formatting tool (requires JuliaFormatter.jl)
format_tool = @mcp_tool(
    :format_code,
    "Format Julia code using JuliaFormatter.jl.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "path" => Dict(
                "type" => "string",
                "description" => "File or directory path to format",
            ),
            "overwrite" => Dict(
                "type" => "boolean",
                "description" => "Overwrite files in place",
                "default" => true,
            ),
            "verbose" => Dict(
                "type" => "boolean",
                "description" => "Show formatting progress",
                "default" => true,
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["path"],
    ),
    function (args)
        try
            # Check if JuliaFormatter is available
            if !isdefined(Main, :JuliaFormatter)
                try
                    @eval Main using JuliaFormatter
                catch
                    return "Error: JuliaFormatter.jl is not installed. Install it with: using Pkg; Pkg.add(\"JuliaFormatter\")"
                end
            end

            path = get(args, "path", "")
            overwrite = get(args, "overwrite", true)
            verbose = get(args, "verbose", true)
            ses = get(args, "session", "")

            if isempty(path)
                return "Error: path parameter is required"
            end

            # Make path absolute
            abs_path = isabspath(path) ? path : joinpath(pwd(), path)

            if !ispath(abs_path)
                return "Error: Path does not exist: $abs_path"
            end

            code = """
            using JuliaFormatter

            # Read the file before formatting to detect changes
            before_content = read("$abs_path", String)

            # Format the file
            format_result = format("$abs_path"; overwrite=$overwrite, verbose=$verbose)

            # Read after to see if changes were made
            after_content = read("$abs_path", String)
            changes_made = before_content != after_content

            if changes_made
                println("✅ File was reformatted: $abs_path")
            elseif format_result
                println("ℹ️  File was already properly formatted: $abs_path")
            else
                println("⚠️  Formatting completed but check for errors: $abs_path")
            end

            changes_made || format_result
            """

            execute_repllike(
                code;
                description = "[Formatting code at: $abs_path]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error formatting code: $e"
        end
    end
)

# Optional linting tool (requires Aqua.jl)
lint_tool = @mcp_tool(
    :lint_package,
    "Run Aqua.jl quality assurance tests on a package.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "package_name" => Dict(
                "type" => "string",
                "description" => "Package name to test (defaults to current project)",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => [],
    ),
    function (args)
        try
            # Check if Aqua is available
            if !isdefined(Main, :Aqua)
                try
                    @eval Main using Aqua
                catch
                    return "Error: Aqua.jl is not installed. Install it with: using Pkg; Pkg.add(\"Aqua\")"
                end
            end

            pkg_name = get(args, "package_name", nothing)
            ses = get(args, "session", "")

            if pkg_name === nothing
                # Use current project
                code = """
                using Aqua
                # Get current project name
                project_file = Base.active_project()
                if project_file === nothing
                    println("❌ No active project found")
                else
                    using Pkg
                    proj = Pkg.TOML.parsefile(project_file)
                    pkg_name = get(proj, "name", nothing)
                    if pkg_name === nothing
                        println("❌ No package name found in Project.toml")
                    else
                        println("Running Aqua tests for package: \$pkg_name")
                        # Load the package
                        @eval using \$(Symbol(pkg_name))
                        # Run Aqua tests
                        Aqua.test_all(\$(Symbol(pkg_name)))
                        println("✅ All Aqua tests passed for \$pkg_name")
                    end
                end
                """
            else
                # Construct code with package name - interpolate at this level
                pkg_symbol = Symbol(pkg_name)
                code = """
                using Aqua
                @eval using $pkg_symbol
                println("Running Aqua tests for package: $pkg_name")
                Aqua.test_all($pkg_symbol)
                println("✅ All Aqua tests passed for $pkg_name")
                """
            end

            execute_repllike(
                code;
                description = "[Running Aqua quality tests]",
                quiet = false,
                session = ses,
            )
        catch e
            "Error running Aqua tests: $e"
        end
    end
)


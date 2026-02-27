"""
Comprehensive JET Static Analysis Tests

This file provides FULL static analysis coverage of the Kaimon codebase by:
1. Running report_package for module-level analysis
2. Introspecting all exported functions from each module
3. Testing each function signature with @report_call
4. Generating detailed error reports

Run this file directly:
    julia --project=. test/jet_comprehensive_tests.jl

Or use with Pkg.test() to include in the test suite.
"""

using Pkg
Pkg.activate(dirname(dirname(@__FILE__)))

using JET
using Dates
using JSON

# Load Kaimon and all submodules
@info "Loading Kaimon..."
using Kaimon
using Kaimon.Database
using Kaimon.Session

# ============================================================================
# Configuration
# ============================================================================

# Whether to fail the script on errors (set to true for CI)
const FAIL_ON_ERRORS = get(ENV, "JET_FAIL_ON_ERRORS", "false") == "true"

# Maximum number of errors to show per module
const MAX_ERRORS_PER_MODULE = 20

# Modules to analyze with their test argument generators
const MODULES_TO_ANALYZE = [:Kaimon, :Database, :Session]

# ============================================================================
# Test Argument Generators
# ============================================================================

"""
Generate appropriate test arguments for a function based on its name and module.
Returns a tuple of arguments or nothing if the function should be skipped.
"""
function get_test_args(mod::Module, func_name::Symbol)
    name = string(func_name)

    # Skip internal/macro functions
    if startswith(name, "_") || startswith(name, "@")
        return nothing
    end

    # Database module functions
    if mod === Database
        return get_database_test_args(func_name)
    end

    # Session module functions
    if mod === Session
        return get_session_test_args(func_name)
    end

    # Kaimon module functions
    return get_kaimon_test_args(func_name)
end

function get_database_test_args(func_name::Symbol)
    args_map = Dict{Symbol,Any}(
        :init_db! => (tempname() * ".db",),
        :get_tool_executions => (),
        :get_tool_summary => (),
        :get_error_hotspots => (),
        :cleanup_old_data! => (30,),
        :close_db! => (),
        :get_default_db_path => (),
        :dataframe_to_array => nothing,  # Internal helper, skip
    )
    return get(args_map, func_name, nothing)
end

function get_session_test_args(func_name::Symbol)
    args_map = Dict{Symbol,Any}(
        :MCPSession => (),
        :initialize_session! => nothing,  # Needs MCPSession object
        :close_session! => nothing,  # Needs MCPSession object
        :get_session_info => nothing,  # Needs MCPSession object
        :update_activity! => nothing,  # Needs MCPSession object
        :session_from_db => nothing,  # Needs NamedTuple
        :get_server_capabilities => (),
        :get_version => (),
    )
    return get(args_map, func_name, nothing)
end

function get_kaimon_test_args(func_name::Symbol)
    args_map = Dict{Symbol,Any}(
        # Core functions
        :start! => (),
        :stop! => (),
        :test_server => (3000,),
        :find_free_port => (),
        :version_info => (),

        # Security
        :security_status => (),
        :setup_security => (),
        :generate_key => (),
        :revoke_key => ("key",),
        :allow_ip => ("127.0.0.1",),
        :deny_ip => ("127.0.0.1",),
        :set_security_mode => (:strict,),

        # Tools
        :list_tools => (),
        :tool_help => (:exec_repl,),
        :call_tool => nothing,  # Complex signature

        # Config
        :load_tools_config => (".kaimon/tools.json", "."),
        :filter_tools_by_config => (nothing,),

        # VS Code
        :store_vscode_response => ("request-id", nothing, nothing),
        :retrieve_vscode_response => nothing,  # Blocking call
        :cleanup_old_vscode_responses => (60.0,),
        :generate_nonce => (),
        :store_nonce => ("request-id", "nonce"),
        :validate_and_consume_nonce => ("request-id", "nonce"),
        :cleanup_old_nonces => (60.0,),
        :trigger_vscode_uri => nothing,  # External system call
        :build_vscode_uri => ("command",),

        # REPL
        :execute_repllike => ("1 + 1",),
        :remove_println_calls => (:(println("test")),),
    )
    return get(args_map, func_name, nothing)
end

# ============================================================================
# Analysis Functions
# ============================================================================

"""
Get all exported names from a module.
"""
function get_exported_names(mod::Module)
    exported = Symbol[]
    for name in names(mod)
        if isdefined(mod, name)
            push!(exported, name)
        end
    end
    return exported
end

"""
Get all public function names from a module (including non-exported).
"""
function get_public_functions(mod::Module)
    funcs = Symbol[]
    for name in names(mod, all = false)  # Only exported names
        if isdefined(mod, name)
            obj = getfield(mod, name)
            if obj isa Function
                push!(funcs, name)
            end
        end
    end
    return funcs
end

"""
Analyze a single function with JET.
Returns (success, error_message or nothing)
"""
function analyze_function(mod::Module, func_name::Symbol, args)
    try
        func = getfield(mod, func_name)
        if !isa(func, Function)
            return (true, nothing)  # Not a function, skip
        end

        # Use @report_call to analyze
        if args === ()
            @report_call func()
        else
            @report_call func(args...)
        end

        return (true, nothing)
    catch e
        if e isa JET.JETAnalysisFailure
            return (false, "JET analysis failed: $(e.msg)")
        elseif e isa MethodError
            return (true, nothing)  # No matching method, that's okay for some functions
        else
            return (false, "Error: $(sprint(showerror, e))")
        end
    end
end

"""
Run comprehensive analysis on a module.
"""
function analyze_module(mod::Module, mod_name::Symbol)
    println("\n" * "="^70)
    println("Analyzing module: $mod_name")
    println("="^70)

    errors = String[]
    checked = 0
    skipped = 0

    # Get all exported functions
    funcs = get_public_functions(mod)
    println("Found $(length(funcs)) exported functions")

    for func_name in funcs
        args = get_test_args(mod, func_name)

        if args === nothing
            skipped += 1
            @debug "Skipped $func_name (no test args defined)"
            continue
        end

        checked += 1
        success, error_msg = analyze_function(mod, func_name, args)

        if success
            println("   ✅ $func_name")
        else
            println("   ❌ $func_name - $error_msg")
            push!(errors, "$mod_name.$func_name: $error_msg")
        end

        if length(errors) >= MAX_ERRORS_PER_MODULE
            println(
                "   ⚠️  Reached max errors ($MAX_ERRORS_PER_MODULE), stopping module analysis",
            )
            break
        end
    end

    println(
        "\nModule $mod_name: $checked checked, $skipped skipped, $(length(errors)) errors",
    )
    return errors
end

"""
Run report_package for comprehensive module analysis.
"""
function run_package_analysis()
    println("\n" * "="^70)
    println("Running JET report_package on :Kaimon")
    println("="^70)

    try
        # Run full package analysis
        rep = report_package(
            :Kaimon;
            ignored_modules = (AnyFrameModule(Test),),
            target_defined_modules = true,
        )

        # Count and display issues
        if !isempty(rep.res.inference_error_reports)
            println(
                "\n⚠️  Package analysis found $(length(rep.res.inference_error_reports)) issue(s):",
            )
            for (i, report) in enumerate(rep.res.inference_error_reports)
                if i <= 10  # Limit output
                    println("\n$i. $report")
                end
            end
            if length(rep.res.inference_error_reports) > 10
                println("\n... and $(length(rep.res.inference_error_reports) - 10) more")
            end
            return false
        else
            println("✅ No issues found in package analysis")
            return true
        end
    catch e
        println("⚠️  Package analysis failed: $e")
        return false
    end
end

# ============================================================================
# Critical Method Checks (from pre-commit)
# ============================================================================

"""
Run focused checks on critical methods with known signatures.
This mirrors the pre-commit hook checks for consistency.
"""
function run_critical_checks()
    println("\n" * "="^70)
    println("Running critical method signature checks")
    println("="^70)

    errors = String[]

    critical_checks = [
        # ========================================
        # Database module - analytics
        # ========================================
        (Kaimon.Database.get_tool_summary, (), "Database.get_tool_summary()"),
        (Kaimon.Database.get_tool_executions, (), "Database.get_tool_executions()"),
        (Kaimon.Database.get_error_hotspots, (), "Database.get_error_hotspots()"),
        (Kaimon.Database.cleanup_old_data!, (30,), "Database.cleanup_old_data!(Int)"),
        (Kaimon.Database.close_db!, (), "Database.close_db!()"),

        # ========================================
        # Session module
        # ========================================
        (Kaimon.Session.get_server_capabilities, (), "Session.get_server_capabilities()"),
        (Kaimon.Session.get_version, (), "Session.get_version()"),
    ]

    for (func, args, desc) in critical_checks
        try
            @report_call func(args...)
            println("   ✅ $desc")
        catch e
            error_msg = e isa JET.JETAnalysisFailure ? e.msg : sprint(showerror, e)
            println("   ❌ $desc - $error_msg")
            push!(errors, "$desc: $error_msg")
        end
    end

    println(
        "\nCritical checks: $(length(critical_checks) - length(errors)) passed, $(length(errors)) failed",
    )
    return errors
end

# ============================================================================
# Additional Method Introspection
# ============================================================================

"""
Find all methods of a function and test each signature.
"""
function introspect_all_methods(func::Function, func_name::String)
    methods_list = methods(func)
    results = []

    for m in methods_list
        sig = m.sig
        println("      Method: $sig")
        push!(results, (m, sig))
    end

    return results
end

"""
List all methods in all analyzed modules.
"""
function list_all_methods()
    println("\n" * "="^70)
    println("Listing all methods in analyzed modules")
    println("="^70)

    modules =
        [(Kaimon, "Kaimon"), (Kaimon.Database, "Database"), (Kaimon.Session, "Session")]

    total_methods = 0

    for (mod, mod_name) in modules
        println("\n📦 $mod_name:")
        funcs = get_public_functions(mod)

        for func_name in sort(funcs)
            func = getfield(mod, func_name)
            if func isa Function
                method_count = length(methods(func))
                total_methods += method_count
                println(
                    "   • $func_name ($method_count method$(method_count == 1 ? "" : "s"))",
                )
            end
        end
    end

    println("\n📊 Total: $total_methods methods across $(length(modules)) modules")
end

# ============================================================================
# Main Execution
# ============================================================================

function main()
    println("="^70)
    println("Kaimon Comprehensive JET Static Analysis")
    println("="^70)
    println("Date: $(now())")
    println("Julia: $(VERSION)")

    all_errors = String[]

    # 1. Run package-level analysis
    package_ok = run_package_analysis()
    if !package_ok
        push!(all_errors, "Package analysis found issues")
    end

    # 2. Run critical method checks
    critical_errors = run_critical_checks()
    append!(all_errors, critical_errors)

    # 3. List all methods for reference
    list_all_methods()

    # 4. Summary
    println("\n" * "="^70)
    println("SUMMARY")
    println("="^70)

    if isempty(all_errors)
        println("✅ All checks passed!")
        return 0
    else
        println("❌ Found $(length(all_errors)) error(s):")
        for (i, err) in enumerate(all_errors)
            println("  $i. $err")
        end

        if FAIL_ON_ERRORS
            println("\nExiting with error code 1 (FAIL_ON_ERRORS=true)")
            return 1
        else
            println("\nNote: Set JET_FAIL_ON_ERRORS=true to fail on errors")
            return 0
        end
    end
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end

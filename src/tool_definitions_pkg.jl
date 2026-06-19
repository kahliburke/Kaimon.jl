# ─────────────────────────────────────────────────────────────────────────────
# Kaimon MCP tools · packages, tests, extensions, stress test  (split from tool_definitions.jl)
# ─────────────────────────────────────────────────────────────────────────────

# Package management tools
pkg_add_tool = @mcp_tool(
    :pkg_add,
    "Add Julia packages to the current environment (modifies Project.toml).",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "packages" => Dict(
                "type" => "array",
                "description" => "Array of package names to add",
                "items" => Dict("type" => "string"),
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["packages"],
    ),
    args ->
        pkg_operation_tool("add", "Added", args; session = get(args, "session", ""))
)

pkg_rm_tool = @mcp_tool(
    :pkg_rm,
    "Remove Julia packages from the current environment.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "packages" => Dict(
                "type" => "array",
                "description" => "Array of package names to remove",
                "items" => Dict("type" => "string"),
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID from resources/list). Required when multiple sessions are connected.",
            ),
        ),
        "required" => ["packages"],
    ),
    args ->
        pkg_operation_tool("rm", "Removed", args; session = get(args, "session", ""))
)

"""
    _project_has_retest(project_path::String) -> Bool

Check whether a project has ReTest as a dependency by reading its TOML files.
Checks both `test/Project.toml` (test-specific deps) and `Project.toml` (extras).
"""
function _project_has_retest(project_path::String)::Bool
    for toml_path in [
        joinpath(project_path, "test", "Project.toml"),
        joinpath(project_path, "Project.toml"),
    ]
        isfile(toml_path) || continue
        try
            toml = TOML.parsefile(toml_path)
            for key in ("deps", "extras")
                haskey(get(toml, key, Dict()), "ReTest") && return true
            end
        catch
        end
    end
    return false
end

run_tests_tool = @mcp_tool(
    :run_tests,
    """Run tests and optionally generate coverage reports.

Spawns a subprocess with correct test environment. Streams results in real-time.
Pattern uses ReTest regex syntax to filter tests.

Provide either `project_path` (absolute path to the project) or `session`
(gate session key) to identify the project. If neither is given and only
one session is connected, that session's project is used.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "pattern" => Dict(
                "type" => "string",
                "description" => "Optional test regex to filter tests (ReTest pattern syntax, e.g., 'security' or 'generate'). Leave empty to run all tests.",
            ),
            "coverage" => Dict(
                "type" => "boolean",
                "description" => "Enable coverage collection and reporting (default: false)",
                "default" => false,
            ),
            "verbose" => Dict(
                "type" => "integer",
                "description" => "Enable verbose test output (default: false)",
                "default" => 1,
            ),
            "project_path" => Dict(
                "type" => "string",
                "description" => "Absolute path to the project directory (must contain Project.toml and test/runtests.jl). Use this instead of session if no gate session is running for the project.",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Session key (8-char ID). Used to resolve project path from a connected gate session.",
            ),
        ),
        "required" => [],
    ),
    function (args)
        pattern = get(args, "pattern", "")
        coverage_enabled = get(args, "coverage", false)
        verbose_arg = get(args, "verbose", 1)
        verbose = verbose_arg isa Int ? verbose_arg : parse(Int, verbose_arg)
        session = get(args, "session", "")
        explicit_path = get(args, "project_path", "")
        on_progress = get(args, "_on_progress", nothing)

        # Normalize pattern
        if pattern == ".*"
            pattern = ""
        end

        # Resolve project path: explicit path > session > single connected session
        project_path = if !isempty(explicit_path)
            isdir(explicit_path) || return "Error: project_path not found: $explicit_path"
            explicit_path
        else
            if !GATE_MODE[]
                return "Error: Provide project_path or start a gate session."
            end
            conn, err = _resolve_gate_conn(session)
            err !== nothing && return err
            conn.project_path
        end
        runtests_path = joinpath(project_path, "test", "runtests.jl")
        if !isfile(runtests_path)
            # Try parent directory (common when project_path is test/ subdir)
            parent = dirname(project_path)
            parent_runtests = joinpath(parent, "test", "runtests.jl")
            if isfile(parent_runtests)
                project_path = parent
                runtests_path = parent_runtests
            else
                return "Error: No test/runtests.jl found in $project_path. Create a test file first."
            end
        end

        on_progress !== nothing &&
            on_progress("Spawning test subprocess for $(basename(project_path))...")

        # Spawn ephemeral test subprocess
        run = spawn_test_run(project_path; pattern = pattern, verbose = verbose)

        # Push to TUI buffer so the Tests tab picks it up
        _push_test_update!(:update, run)

        # Poll for completion — timeout after 10 min to prevent hanging MCP calls
        deadline = time() + 600.0
        while run.status == RUN_RUNNING
            sleep(0.5)
            if on_progress !== nothing
                # total_pass/total_fail are only set when the top-level testset
                # finishes; during the run, accumulate from individual results.
                p = run.total_pass > 0 ? run.total_pass : sum((r.pass_count for r in run.results), init=0)
                f = run.total_fail > 0 ? run.total_fail : sum((r.fail_count for r in run.results), init=0)
                n_sets = length(run.results)
                on_progress(
                    "$p passed, $f failed ($n_sets testsets done)",
                )
            end
            if time() > deadline
                cancel_test_run!(run)
                return "Test run timed out after 10 minutes.\n\n$(format_test_summary(run))"
            end
        end

        # The runner marks status on TEST_RUNNER:DONE before the reader task
        # necessarily finishes parsing the final summary block.
        reader_deadline = time() + 5.0
        while !run.reader_done && time() < reader_deadline
            sleep(0.05)
        end

        # If the process has exited but only summary-table output was emitted,
        # parse the buffered raw output one last time before formatting.
        if run.process !== nothing
            try
                wait(run.process)
            catch
            end
        end
        _parse_raw_summary!(run)

        # Return focused summary (not raw output dump)
        return format_test_summary(run)
    end
)

extension_info_tool = @mcp_tool(
    :extension_info,
    """Get information about loaded Kaimon extensions and their tools.

No arguments: list all extensions with status and tool names.
With name: detailed view of one extension including per-tool documentation and parameter schemas.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "name" => Dict(
                "type" => "string",
                "description" => "Extension namespace to get details for. Omit to list all extensions.",
            ),
        ),
        "required" => [],
    ),
    args -> begin
        extensions = get_managed_extensions()
        conn_mgr = GATE_CONN_MGR[]
        name = get(args, "name", nothing)

        if name === nothing
            # List all extensions
            if isempty(extensions)
                return "No extensions configured."
            end

            lines = String[]
            for ext in extensions
                ns = ext.config.manifest.namespace
                desc = ext.config.manifest.description
                status_icon = ext.status == :running ? "●" :
                              ext.status == :crashed ? "●" :
                              "○"

                # Get tool names if connected
                tool_names = String[]
                if conn_mgr !== nothing
                    conn = _find_ext_connection(ext, conn_mgr)
                    if conn !== nothing && !isempty(conn.session_tools)
                        for tool in conn.session_tools
                            push!(tool_names, get(tool, "name", "?"))
                        end
                    end
                end

                line = "$status_icon $ns ($(ext.status))"
                !isempty(desc) && (line *= " — $desc")
                push!(lines, line)
                if !isempty(tool_names)
                    push!(lines, "  Tools: $(join(tool_names, ", "))")
                end
            end
            return join(lines, "\n")
        else
            # Detail view for a specific extension
            idx = findfirst(e -> e.config.manifest.namespace == name, extensions)
            if idx === nothing
                available = join([e.config.manifest.namespace for e in extensions], ", ")
                return "Error: No extension '$(name)' found. Available: $available"
            end

            ext = extensions[idx]
            manifest = ext.config.manifest
            entry = ext.config.entry

            # Status info
            status_icon = ext.status == :running ? "●" :
                          ext.status == :crashed ? "●" :
                          "○"
            pid_str = if ext.process !== nothing && Base.process_running(ext.process)
                string(getpid(ext.process))
            else
                "—"
            end
            uptime_str = ext.status == :running ? format_uptime(time() - ext.started_at) : "—"

            lines = String[]
            push!(lines, "$(manifest.namespace) — $(manifest.module_name)")
            push!(lines, "Status: $status_icon $(ext.status) (PID $pid_str, uptime $uptime_str)")
            !isempty(manifest.description) && push!(lines, "Description: $(manifest.description)")
            push!(lines, "Project: $(entry.project_path)")

            # Tool documentation
            conn = conn_mgr !== nothing ? _find_ext_connection(ext, conn_mgr) : nothing
            if conn !== nothing && !isempty(conn.session_tools)
                tools = conn.session_tools
                push!(lines, "")
                push!(lines, "Tools ($(length(tools))):")

                for tool in tools
                    tname = get(tool, "name", "unknown")
                    tdesc = get(tool, "description", "")
                    targs = get(tool, "arguments", Dict{String,Any}[])

                    # Build signature
                    param_names = String[]
                    for arg in targs
                        push!(param_names, get(arg, "name", "?"))
                    end
                    sig = isempty(param_names) ? "" : "($(join(param_names, ", ")))"

                    push!(lines, "")
                    push!(lines, "  $(manifest.namespace).$tname$sig")

                    # Description (first paragraph only for readability)
                    if !isempty(tdesc)
                        first_para = first(split(tdesc, "\n\n"))
                        push!(lines, "    $first_para")
                    end

                    # Parameters
                    if !isempty(targs)
                        push!(lines, "    Parameters:")
                        for arg in targs
                            arg_name = get(arg, "name", "?")
                            type_meta = get(arg, "type_meta", nothing)
                            arg_type = if type_meta isa Dict
                                get(type_meta, "julia_type", "Any")
                            elseif type_meta isa String
                                type_meta
                            else
                                "Any"
                            end
                            required = get(arg, "required", false)
                            req = required ? " (required)" : ""
                            push!(lines, "      $arg_name: $arg_type$req")
                        end
                    end
                end
            elseif conn !== nothing
                push!(lines, "\nTools: (none registered)")
            else
                push!(lines, "\nTools: waiting for gate connection...")
            end

            return join(lines, "\n")
        end
    end
)

manage_extension_tool = @mcp_tool(
    :manage_extension,
    """Manage a configured Kaimon extension's lifecycle — the same controls as the TUI Extensions tab.

Actions (target an extension by its namespace; use extension_info to list them):
- start / stop / restart — control the running process
- enable / disable — whether the extension may run (disable also stops it if running; persisted to extensions.json)
- enable_auto_start / disable_auto_start — whether it auto-starts with Kaimon (persisted)

Returns the extension's resulting {status, enabled, auto_start}.""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "name" => Dict("type" => "string", "description" => "Extension namespace (see extension_info)."),
            "action" => Dict(
                "type" => "string",
                "enum" => ["start", "stop", "restart", "enable", "disable",
                           "enable_auto_start", "disable_auto_start"],
                "description" => "Lifecycle action to apply.",
            ),
        ),
        "required" => ["name", "action"],
    ),
    args -> begin
        try
            name = String(get(args, "name", ""))
            action = String(get(args, "action", ""))
            exts = get_managed_extensions()
            idx = findfirst(e -> e.config.manifest.namespace == name, exts)
            if idx === nothing
                available = join([e.config.manifest.namespace for e in exts], ", ")
                return "Error: No extension '$name' found. Available: $available"
            end
            ext = exts[idx]
            if action == "start"
                ext.status == :stopped ||
                    return "Extension '$name' is already $(ext.status) (start only applies when stopped)."
                spawn_extension!(ext)
            elseif action == "stop"
                stop_extension!(ext)
            elseif action == "restart"
                restart_extension!(ext)
            elseif action == "enable"
                set_extension_config!(ext; enabled = true)
            elseif action == "disable"
                set_extension_config!(ext; enabled = false)
            elseif action == "enable_auto_start"
                set_extension_config!(ext; auto_start = true)
            elseif action == "disable_auto_start"
                set_extension_config!(ext; auto_start = false)
            else
                return "Error: unknown action '$action'. Use start|stop|restart|enable|disable|enable_auto_start|disable_auto_start."
            end
            JSON.json(Dict(
                "extension" => name,
                "action" => action,
                "status" => string(ext.status),
                "enabled" => ext.config.entry.enabled,
                "auto_start" => ext.config.entry.auto_start,
            ))
        catch e
            "Error managing extension: $(sprint(showerror, e))"
        end
    end
)

stress_test_tool = @mcp_tool(
    :stress_test,
    """Run a stress test by spawning concurrent simulated MCP agents.

Launches N agents that each execute the given Julia code via `ex`, or call an arbitrary
MCP gate tool. Returns per-agent results, timing stats, and success/failure counts.

Use the `scenario` parameter to select a pre-defined test pattern, or specify `tool`
and `tool_args` directly for a custom gate tool call.

# Examples

```julia
{"num_agents": 3, "code": "sleep(1); 42"}
{"num_agents": 10, "code": "sum(1:1000)", "stagger": 0.1}
{"num_agents": 5, "tool": "gatetooltest_jl.run_timed_op", "tool_args": {"steps": 5, "delay_ms": 200}}
{"num_agents": 5, "scenario": "timed_op (5 steps)", "session": "9b2d4532"}
```
""",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "code" => Dict(
                "type" => "string",
                "description" => "Julia code each agent executes via ex (default: \"sleep(1); 42\"). Ignored when `tool` is set.",
            ),
            "tool" => Dict(
                "type" => "string",
                "description" => "MCP tool name to call instead of ex (e.g. \"gatetooltest_jl.run_timed_op\"). Omit to use eval path.",
            ),
            "tool_args" => Dict(
                "type" => "object",
                "description" => "Arguments passed to the gate tool. Used when `tool` is set.",
            ),
            "scenario" => Dict(
                "type" => "string",
                "description" => "Pre-defined scenario name. Sets `tool` and `tool_args` automatically. Run with no args to list available scenarios.",
            ),
            "num_agents" => Dict(
                "type" => "integer",
                "description" => "Number of concurrent agents to spawn, 1-100 (default: 5)",
            ),
            "stagger" => Dict(
                "type" => "number",
                "description" => "Delay in seconds between agent launches (default: 0.0)",
            ),
            "timeout" => Dict(
                "type" => "integer",
                "description" => "Per-agent timeout in seconds (default: 30)",
            ),
            "session" => Dict(
                "type" => "string",
                "description" => "Target session key for eval path (auto-detects if one session connected). Gate tools route via namespace, not session key.",
            ),
        ),
        "required" => [],
    ),
    function (args)
        code = get(args, "code", "sleep(1); 42")
        tool_name = get(args, "tool", "")
        tool_args_val = get(args, "tool_args", nothing)
        tool_args_json = tool_args_val !== nothing ? JSON.json(tool_args_val) : "{}"
        scenario = get(args, "scenario", "")

        num_agents = get(args, "num_agents", 5)
        num_agents isa AbstractString && (num_agents = parse(Int, num_agents))
        stagger = get(args, "stagger", 0.0)
        stagger isa AbstractString && (stagger = parse(Float64, stagger))
        timeout = get(args, "timeout", 30)
        timeout isa AbstractString && (timeout = parse(Int, timeout))
        session = get(args, "session", "")

        on_progress = get(args, "_on_progress", nothing)

        # Resolve scenario preset
        if !isempty(scenario)
            idx = findfirst(s -> s.name == scenario, STRESS_SCENARIOS)
            if idx === nothing
                names = join([s.name for s in STRESS_SCENARIOS], "\n  ")
                return "ERROR: Unknown scenario '$(scenario)'. Available:\n  $names"
            end
            sc = STRESS_SCENARIOS[idx]
            tool_name = sc.tool
            tool_args_json = sc.args_json
            isempty(sc.code) || (code = sc.code)
        end

        # Default tool
        isempty(tool_name) && (tool_name = "ex")

        # Validate
        num_agents = clamp(num_agents, 1, 100)
        stagger = max(0.0, stagger)
        timeout = clamp(timeout, 1, 600)

        # Resolve session (used for ex eval path and for SUMMARY label)
        mgr = GATE_CONN_MGR[]
        if mgr === nothing
            return "ERROR: No ConnectionManager available. Is the TUI running with gate mode enabled?"
        end

        resolved_conn = nothing
        sess_key = if isempty(session)
            conns = connected_sessions(mgr)
            if length(conns) == 0
                return "ERROR: No REPL sessions connected. Start a gate in your Julia REPL:\n  using KaimonGate; KaimonGate.serve()"
            elseif length(conns) == 1
                resolved_conn = conns[1]
                short_key(conns[1])
            else
                # For gate tools (non-ex), session is not required — just use first
                if tool_name != "ex"
                    resolved_conn = conns[1]
                    short_key(conns[1])
                else
                    available = join(["$(short_key(c)) ($(c.name))" for c in conns], ", ")
                    return "ERROR: Multiple sessions connected. Specify `session` parameter. Available: $available"
                end
            end
        else
            conn = get_connection_by_key(mgr, session)
            if conn === nothing
                conns = connected_sessions(mgr)
                available = join(["$(short_key(c)) ($(c.name))" for c in conns], ", ")
                return "ERROR: No session matched '$(session)'. Available: $available"
            end
            resolved_conn = conn
            short_key(conn)
        end

        # Auto-prepend namespace for scenario/short tool names that lack a '.' prefix
        if tool_name != "ex" && !occursin('.', tool_name) && resolved_conn !== nothing
            ns = resolved_conn.namespace
            isempty(ns) || (tool_name = "$(ns).$(tool_name)")
        end

        port = GATE_PORT[]

        if on_progress !== nothing
            if tool_name == "ex"
                on_progress("Launching stress test: $num_agents agents, code=$(repr(code))")
            else
                on_progress("Launching stress test: $num_agents agents, tool=$tool_name")
            end
        end

        # Write script and spawn subprocess
        script_path = _write_stress_script()
        project_dir = pkgdir(@__MODULE__)
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project_dir $script_path $port $sess_key $code $num_agents $stagger $timeout $tool_name $tool_args_json`

        output_lines = String[]
        t_start = time()

        try
            process = open(cmd, "r")
            while !eof(process)
                line = readline(process; keep = false)
                isempty(line) && continue
                push!(output_lines, line)
                on_progress !== nothing && on_progress(line)
            end
            try
                wait(process)
            catch
            end
        catch e
            push!(output_lines, "ERROR agent=0 elapsed=0.0 message=$(sprint(showerror, e))")
        end

        total_wall_time = time() - t_start

        # Write results file
        result_file = _write_stress_results_to_file(
            output_lines,
            tool_name == "ex" ? code : tool_name,
            sess_key,
            num_agents,
            stagger,
            timeout,
        )

        # Parse and format summary
        agents = _parse_stress_results(output_lines)
        return _format_stress_summary(
            agents,
            code,
            sess_key,
            num_agents,
            Float64(stagger),
            timeout,
            total_wall_time,
            result_file;
            tool_name = tool_name,
            tool_args_json = tool_args_json,
        )
    end
)


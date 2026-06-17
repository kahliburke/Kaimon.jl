# ─────────────────────────────────────────────────────────────────────────────
# Kaimon · tool config/collection, start! + gate services  (relocated from Kaimon.jl; part of the Kaimon module)
# ─────────────────────────────────────────────────────────────────────────────

"""
    load_tools_config(config_path::String = ".kaimon/tools.json")

Load the tools configuration from .kaimon/tools.json.
Returns a Set of enabled tool names (as Symbols).

The configuration supports:
- Tool sets that can be enabled/disabled as groups
- Individual tool overrides that take precedence over tool set settings

If the config file doesn't exist, returns `nothing` to indicate all tools should be enabled.
"""
function load_tools_config(
    config_path::String = ".kaimon/tools.json",
    workspace_dir::String = pwd(),
)
    full_path = joinpath(workspace_dir, config_path)

    # If config doesn't exist, enable all tools (backward compatibility)
    if !isfile(full_path)
        return nothing
    end

    try
        config = JSON.parsefile(full_path; dicttype = Dict{String,Any})
        enabled_tools = Set{Symbol}()

        # First, process tool sets
        tool_sets = get(config, "tool_sets", Dict())
        for (set_name, set_config) in tool_sets
            if get(set_config, "enabled", false)
                tools = get(set_config, "tools", String[])
                for tool_name in tools
                    push!(enabled_tools, Symbol(tool_name))
                end
            end
        end

        # Then apply individual overrides
        individual_overrides = get(config, "individual_overrides", Dict())
        for (tool_name, enabled) in individual_overrides
            # Skip comment entries
            if startswith(tool_name, "_")
                continue
            end

            tool_sym = Symbol(tool_name)
            if enabled
                push!(enabled_tools, tool_sym)
            else
                delete!(enabled_tools, tool_sym)
            end
        end

        return enabled_tools
    catch e
        @warn "Error loading tools configuration from $full_path: $e. Enabling all tools."
        return nothing
    end
end

"""
    filter_tools_by_config(enabled_tools::Union{Set{Symbol},Nothing})

Filter tools from ALL_TOOLS based on the enabled tools set.
If enabled_tools is `nothing`, returns all tools (backward compatibility).
"""
function filter_tools_by_config(enabled_tools::Union{Set{Symbol},Nothing})
    if enabled_tools === nothing
        return ALL_TOOLS[]
    end

    return filter(tool -> tool.id in enabled_tools, ALL_TOOLS[])
end

"""
    collect_tools() -> Vector{MCPTool}

Assemble all MCP tools (core, reflection, Qdrant) into a single vector.
Used by both `start!()` and the TUI to build the tool list for the MCP server.
"""
function collect_tools()::Vector{MCPTool}
    reflection_tools = create_reflection_tools()
    qdrant_tools = create_qdrant_tools()

    return MCPTool[
        ping_tool,
        server_log_tool,
        tui_screenshot_tool,
        usage_instructions_tool,
        usage_quiz_tool,
        tool_help_tool,
        repl_tool,
        manage_repl_tool,
        connect_tcp_tool,
        start_session_tool,
        set_tty_tool,
        vscode_command_tool,
        list_vscode_commands_tool,
        investigate_tool,
        search_methods_tool,
        macro_expand_tool,
        type_info_tool,
        profile_tool,
        list_names_tool,
        code_lowered_tool,
        code_typed_tool,
        format_tool,
        lint_tool,
        navigate_to_file_tool,
        debug_exfiltrate_tool,
        debug_inspect_safehouse_tool,
        debug_clear_safehouse_tool,
        debug_ctrl_tool,
        debug_eval_tool,
        pkg_add_tool,
        pkg_rm_tool,
        run_tests_tool,
        stress_test_tool,
        extension_info_tool,
        check_eval_tool,
        cancel_eval_tool,
        list_jobs_tool,
        agent_open_tool,
        agent_send_tool,
        agent_run_tool,
        agent_interrupt_tool,
        agent_close_tool,
        agent_status_tool,
        agent_list_tool,
        agent_governor_status_tool,
        reflection_tools...,
        qdrant_tools...,
    ]
end


"""
    start!(; port=nothing, verbose=true, security_mode=nothing, julia_session_name="", workspace_dir=pwd())

Start the Kaimon MCP server.

# Arguments
- `port::Union{Int,Nothing}=nothing`: Server port. Use `0` for dynamic port assignment (finds first available port in 40000-49999). If `nothing`, uses port from configuration.
- `verbose::Bool=true`: Show startup messages
- `security_mode::Union{Symbol,Nothing}=nothing`: Override security mode (:strict, :relaxed, or :lax)
- `julia_session_name::String=""`: Name for this Julia session
- `workspace_dir::String=pwd()`: Project root directory

# Dynamic Port Assignment
Set `port=0` (or use `"port": 0` in config.json) to automatically find and use an available port.
The server will search ports 40000-49999 for the first free port. This higher range avoids conflicts with common services.

# Examples
```julia
# Use configured port from config.json
Kaimon.start!()

# Use specific port
Kaimon.start!(port=4000)

# Use dynamic port assignment
Kaimon.start!(port=0)

# Start with a custom name
Kaimon.start!(julia_session_name="data-processor")
```
"""
function start!(;
    port::Union{Int,Nothing} = nothing,
    verbose::Bool = true,
    security_mode::Union{Symbol,Nothing} = nothing,
    julia_session_name::String = "",
    workspace_dir::String = pwd(),
    session_uuid::Union{String,Nothing} = nothing,
    gate::Bool = true,
)
    SERVER[] !== nothing && stop!() # Stop existing server if running

    # Temporarily suppress Info logs during startup to avoid interfering with spinner
    old_logger = global_logger()
    global_logger(ConsoleLogger(stderr, Logging.Warn))

    # Start animated spinner for startup
    spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
    spinner_idx = Ref(1)
    spinner_active = Ref(true)
    status_msg = Ref("Starting Kaimon...")

    # Background task to animate spinner
    spinner_task = @async begin
        while spinner_active[]
            msg = status_msg[]
            # Magenta spinner, bold gray text
            print("\r\033[K\033[35m$(spinner[spinner_idx[]])\033[0m \033[1;90m$msg\033[0m")
            flush(stdout)
            spinner_idx[] = spinner_idx[] % length(spinner) + 1
            sleep(0.08)
        end
    end

    # Load or prompt for security configuration
    @debug "Loading config"
    security_config = load_global_config()

    if security_config === nothing
        # Stop spinner before launching wizard
        spinner_active[] = false
        wait(spinner_task)
        global_logger(old_logger)

        print("\r\033[K")  # Clear spinner line
        security_config = setup_wizard_tui()
        if security_config === nothing
            error("Security configuration required. Run Kaimon.setup() first.")
        end
    else
        @debug "Security config loaded successfully" port = security_config.port mode =
            security_config.mode
    end

    # Determine port: function arg overrides config
    actual_port = if port !== nothing
        if port == 0
            # Port 0 means find a free port dynamically
            @info "Finding available port dynamically"
            find_free_port()
        else
            @info "Using port from function argument" port = port
            port
        end
    else
        # Use port from global config
        config_port = security_config.port
        if config_port == 0
            # Port 0 in config means find a free port dynamically
            @info "Finding available port dynamically (from config)"
            find_free_port()
        else
            @debug "Using port from loaded config" port = config_port mode =
                (julia_session_name != "" ? "agent:$julia_session_name" : "normal")
            config_port
        end
    end

    # Override security mode if specified
    if security_mode !== nothing
        if !(security_mode in [:strict, :relaxed, :lax])
            # Stop spinner before showing error
            spinner_active[] = false
            wait(spinner_task)
            global_logger(old_logger)

            print("\r\033[K")  # Clear spinner line
            error("Invalid security_mode. Must be :strict, :relaxed, or :lax")
        end
        security_config = SecurityConfig(
            security_mode,
            security_config.api_keys,
            security_config.allowed_ips,
            security_config.port,
            security_config.created_at,
            security_config.editor,
            security_config.qdrant_prefix,
        )
    end

    # Update status message
    status_msg[] = "Starting Kaimon (security: $(security_config.mode))..."

    # Show security status if verbose
    if verbose
        printstyled("\n📡 Server Port: ", color = :cyan, bold = true)
        printstyled("$actual_port\n", color = :green, bold = true)
        println()
    end

    # Surface the unrestricted-project opt-in — it lets sessions start in ANY
    # directory with a Project.toml, bypassing the allow-list (#46). Safe in an
    # isolated container/VM, risky on a shared host, so never silent.
    if projects_allow_any()
        @warn "Project allow-list disabled (allow_any_project=true in projects.json) — sessions may start in any directory with a Project.toml"
    end

    all_tools = collect_tools()
    Kaimon.ALL_TOOLS[] = all_tools

    # Load tools configuration from workspace directory
    enabled_tools = load_tools_config(".kaimon/tools.json", workspace_dir)

    # Filter tools based on configuration
    active_tools = filter_tools_by_config(enabled_tools)

    # Show tool configuration status if verbose and config exists
    if verbose && enabled_tools !== nothing
        disabled_count = length(all_tools) - length(active_tools)
        if disabled_count > 0
            printstyled("🔧 Tools: ", color = :cyan, bold = true)
            println("$(length(active_tools)) enabled, $disabled_count disabled by config")
        end
    end

    # Initialize the analytics/job SQLite database. The TUI does this on its
    # first render tick; the headless/REPL path needs it too, otherwise every
    # DB op (tool-call analytics, background-job persistence) silently no-ops
    # because `Database.DB[]` stays `nothing` — which breaks the list_jobs /
    # cancel_eval tools headless. Idempotent (CREATE TABLE IF NOT EXISTS).
    try
        Database.init_db!(joinpath(kaimon_cache_dir(), "kaimon.db"))
    catch e
        @warn "Failed to initialize analytics database" exception = e
    end

    # Update status for server launch
    status_msg[] = "Starting Kaimon (launching server on port $actual_port)..."
    SERVER[] = start_mcp_server(
        active_tools,
        actual_port;
        verbose = verbose,
        security_config = security_config,
        session_uuid = session_uuid,
    )

    # Start gate services (connection manager, extensions, service endpoint)
    if gate
        status_msg[] = "Starting gate services..."
        _start_gate_services!()
    end

    # Stop the spinner and show completion
    spinner_active[] = false
    wait(spinner_task)  # Wait for spinner task to finish

    # Restore original logger
    global_logger(old_logger)

    # Green checkmark, dark blue text, the user's personality emoji, muted cyan port
    gate_info = gate ? ", gate" : ""
    pers = try; load_personality(); catch; "🐉"; end
    print(
        "\r\033[K\033[1;32m✓\033[0m \033[38;5;24mKaimon server started\033[0m \033[33m$pers\033[0m \033[90m(port $actual_port$gate_info)\033[0m\n",
    )
    flush(stdout)

    if isdefined(Base, :active_repl) && Base.active_repl !== nothing
        try
            set_prefix!(Base.active_repl)
            # Refresh the prompt to show the new prefix
            if isdefined(Base.active_repl, :mistate) && Base.active_repl.mistate !== nothing
                REPL.LineEdit.refresh_line(Base.active_repl.mistate)
            end
        catch e
            @debug "Failed to set REPL prefix" exception = e
        end
    else
        atreplinit(set_prefix!)
    end


    nothing
end

"""Start gate services without the TUI: connection manager, service endpoint, extensions."""
function _start_gate_services!()
    # Guard against double-start (e.g. start!() called twice, or before tui())
    if GATE_MODE[]
        @debug "Gate services already running, skipping"
        return
    end

    mgr = ConnectionManager()
    start!(mgr)
    register_sessions_changed_callback!(mgr)

    GATE_MODE[] = true
    GATE_CONN_MGR[] = mgr

    try
        start_service_endpoint!()
    catch e
        @warn "Failed to start service endpoint" exception = e
    end

    start_extensions!()

    # Reap leftover owned-agent processes from a prior Kaimon instance.
    try
        reap_orphan_agents!()
    catch e
        @warn "Failed to reap orphan agents" exception = e
    end

    # Periodic maintenance the TUI render loop would otherwise drive.
    _start_housekeeping!()

    # One-shot: bring the lexical (FTS5) index to parity with the vector index
    # (e.g. first boot after the 2.0 hybrid-search upgrade). The TUI path has its
    # own call in src/tui/lifecycle.jl since it bypasses this function.
    _spawn_fts_coverage_sync!()
    nothing
end

"""Stop gate services started by `_start_gate_services!`."""
function _stop_gate_services!()
    GATE_MODE[] || return

    _stop_housekeeping!()

    try
        stop_service_endpoint!()
    catch
    end

    stop_all_sessions!()
    stop_all_extensions!()
    try
        stop_all_agents!()
    catch
    end

    mgr = GATE_CONN_MGR[]
    GATE_MODE[] = false
    GATE_CONN_MGR[] = nothing

    if mgr !== nothing
        try
            stop!(mgr)
        catch
        end
    end
    nothing
end


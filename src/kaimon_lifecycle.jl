# ─────────────────────────────────────────────────────────────────────────────
# Kaimon · headless housekeeping, stop!, security key mgmt  (relocated from Kaimon.jl; part of the Kaimon module)
# ─────────────────────────────────────────────────────────────────────────────

# ── Headless housekeeping ─────────────────────────────────────────────────────
# The TUI render loop performs periodic maintenance every frame: reaping idle
# MCP sessions, monitoring/restarting crashed extensions + managed gate
# sessions, and re-syncing project indexes. Headless has no render loop, so this
# background task is the substitute. It self-disables whenever a TUI is driving
# (`TUI_MODEL[]` set) to avoid doing the same work twice.

const HOUSEKEEPING_INTERVAL_SECONDS = 10
const HOUSEKEEPING_TASK = Ref{Union{Task,Nothing}}(nothing)
const HOUSEKEEPING_STOP = Ref{Bool}(false)

"""
    _headless_sync_interval_seconds() -> Int

Seconds between periodic full index syncs (0 disables). `KAIMON_HEADLESS_SYNC_INTERVAL`
env var overrides; default is 600 (10 min).
"""
function _headless_sync_interval_seconds()
    v = get(ENV, "KAIMON_HEADLESS_SYNC_INTERVAL", "")
    if !isempty(v)
        n = tryparse(Int, v)
        n !== nothing && return max(0, n)
    end
    return 600
end

"""
    _sync_all_enabled_projects!()

Re-sync (or first-index) every enabled approved project and every connected
gate project's Qdrant collection. Shared by headless housekeeping and the TUI
startup path. Each project goes through `_auto_index_project!`, which guards
against concurrent runs and skips when search services are down.
"""
function _sync_all_enabled_projects!()
    seen = Set{String}()
    for entry in load_projects_config()
        entry.enabled || continue
        isdir(entry.project_path) || continue
        entry.project_path in seen && continue
        push!(seen, entry.project_path)
        _auto_index_project!(entry.project_path)
    end
    mgr = GATE_CONN_MGR[]
    if mgr !== nothing
        for conn in connected_sessions(mgr)
            p = conn.project_path
            (isempty(p) || p in seen) && continue
            isfile(joinpath(p, "Project.toml")) || continue
            push!(seen, p)
            _auto_index_project!(p)
        end
    end
    nothing
end

"""Start the headless housekeeping loop (idempotent; no-op if already running)."""
function _start_housekeeping!()
    if HOUSEKEEPING_TASK[] !== nothing && !istaskdone(HOUSEKEEPING_TASK[])
        return
    end
    # Persist housekeeping/index logs to the shared log file (idempotent — the
    # TUI opens this too). Without it, background logs vanish headless.
    _open_log_file!()

    HOUSEKEEPING_STOP[] = false
    sync_interval = _headless_sync_interval_seconds()

    HOUSEKEEPING_TASK[] = Threads.@spawn begin
        # Give gate sessions time to connect before the first index sync.
        for _ in 1:15
            HOUSEKEEPING_STOP[] && break
            sleep(1)
        end
        last_sync = time()
        if !HOUSEKEEPING_STOP[] && sync_interval > 0 && TUI_MODEL[] === nothing
            try
                _sync_all_enabled_projects!()
            catch e
                @debug "Housekeeping initial sync failed" exception = e
            end
        end

        while !HOUSEKEEPING_STOP[]
            for _ in 1:HOUSEKEEPING_INTERVAL_SECONDS
                HOUSEKEEPING_STOP[] && break
                sleep(1)
            end
            HOUSEKEEPING_STOP[] && break

            # A TUI render loop is driving — it does this work itself.
            TUI_MODEL[] === nothing || continue
            mgr = GATE_CONN_MGR[]
            mgr === nothing && continue

            try
                _reap_stale_sessions!(_any_live_owned_agents() ? 3600.0 : 300.0)
            catch e
                @debug "Housekeeping reap failed" exception = e
            end
            try
                _monitor_extensions!(mgr)
                _monitor_managed_sessions!(mgr)
            catch e
                @debug "Housekeeping monitor failed" exception = e
            end

            if sync_interval > 0 && time() - last_sync >= sync_interval
                last_sync = time()
                try
                    _sync_all_enabled_projects!()
                catch e
                    @debug "Housekeeping sync failed" exception = e
                end
            end
        end
    end
    nothing
end

"""Stop the headless housekeeping loop."""
function _stop_housekeeping!()
    HOUSEKEEPING_STOP[] = true
    HOUSEKEEPING_TASK[] = nothing
    nothing
end

function set_prefix!(repl)
    try
        mode = get_mainmode(repl)
        if mode !== nothing
            mode.prompt = REPL.contextual_prompt(repl, "✻ julia> ")
        end
    catch e
        @debug "Failed to set REPL prefix" exception = e
    end
end
function unset_prefix!(repl)
    try
        mode = get_mainmode(repl)
        if mode !== nothing
            mode.prompt = REPL.contextual_prompt(repl, REPL.JULIA_PROMPT)
        end
    catch e
        @debug "Failed to unset REPL prefix" exception = e
    end
end
function get_mainmode(repl)
    try
        if !isdefined(repl, :interface) || repl.interface === nothing
            return nothing
        end
        modes = filter(repl.interface.modes) do mode
            mode isa REPL.Prompt &&
                mode.prompt isa Function &&
                contains(mode.prompt(), "julia>")
        end
        return isempty(modes) ? nothing : only(modes)
    catch e
        @debug "Failed to get main REPL mode" exception = e
        return nothing
    end
end

function stop!()
    if SERVER[] !== nothing
        println("Stop existing server...")

        # Stop gate services if running headless
        _stop_gate_services!()

        stop_mcp_server(SERVER[])
        SERVER[] = nothing
        if isdefined(Base, :active_repl) && Base.active_repl !== nothing
            try
                unset_prefix!(Base.active_repl) # Reset the prompt prefix
            catch e
                @debug "Failed to reset REPL prefix" exception = e
            end
        end
    else
        println("No server running to stop.")
    end
end

"""
    _headless_wait_and_shutdown(port)

Block the headless server's main task until the operator presses Ctrl-Q (or
Ctrl-C), then tear down cleanly via `stop!()` and exit. Without this the process
only `wait(Condition())`s, so a Ctrl-C kills it without running teardown —
leaving gate/extension subprocesses and socket files behind.
"""
function _headless_wait_and_shutdown(port)
    printstyled("\n⏻ Headless server on port $port — press Ctrl-Q (or Ctrl-C) to shut down.\n";
                color = :light_black)
    flush(stdout)
    _wait_for_quit_key()
    printstyled("\nShutting down…\n"; color = :light_black)
    flush(stdout)
    try
        stop!()
    catch e
        @warn "Error during shutdown" exception = e
    end
    exit(0)
end

"""
    _wait_for_quit_key()

Block until the operator presses Ctrl-Q (0x11) or Ctrl-C (0x03). The terminal is
put in raw mode so both arrive as bytes (ISIG off) — that's what lets Ctrl-C run
our clean shutdown instead of killing the process. With no interactive TTY
(backgrounded/piped) there are no keys to read, so just wait for a signal.
"""
function _wait_for_quit_key()
    if !(stdin isa Base.TTY)
        try; wait(Condition()); catch; end
        return
    end
    term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", "dumb"), stdin, stdout, stderr)
    REPL.Terminals.raw!(term, true)
    try
        while true
            b = try
                read(stdin, UInt8)
            catch e
                e isa EOFError ? break : rethrow()
            end
            (b == 0x11 || b == 0x03) && break   # Ctrl-Q or Ctrl-C
        end
    finally
        try; REPL.Terminals.raw!(term, false); catch; end
    end
end

# ============================================================================
# Public Security Management Functions
# ============================================================================

"""
    security_status()

Display current security configuration.
"""
function security_status()
    config = load_global_config()
    if config === nothing
        printstyled("\n⚠️  No security configuration found\n", color = :yellow, bold = true)
        println("Run Kaimon.setup_security() to configure")
        println()
        return
    end
    show_security_status(config)
end

"""
    setup_security(; force::Bool=false)

Launch the security setup wizard.
"""
function setup_security(; force::Bool = false, mode::Symbol = :auto)
    if !force
        existing = load_global_config()
        if existing !== nothing
            println()
            printstyled(
                "Security configuration already exists (mode: $(existing.mode))\n",
                color = :green,
            )
            print("Reconfigure? [y/N]: ")
            response = strip(lowercase(readline()))
            if !(response == "y" || response == "yes")
                return existing
            end
        end
    end
    return setup_wizard_tui(; mode = mode)
end

"""
    generate_key()

Generate and add a new API key to the global configuration.
"""
function generate_key()
    config = load_global_config()
    config === nothing && error("No configuration found. Run Kaimon.setup_security() first.")
    new_key = generate_api_key()
    if update_global_config!(api_keys = vcat(config.api_keys, [new_key]))
        println("✅ Added new API key: $new_key")
        println("⚠️  Save this key securely - it won't be shown again!")
        return new_key
    else
        error("Failed to save configuration")
    end
end

"""
    revoke_key(key::String)

Revoke (remove) an API key from the global configuration.
"""
function revoke_key(key::String)
    config = load_global_config()
    if config === nothing
        error("No configuration found. Run Kaimon.setup_security() first.")
    end
    if !(key in config.api_keys)
        @warn "API key not found in configuration"
        return false
    end
    if update_global_config!(api_keys = filter(k -> k != key, config.api_keys))
        println("✅ Removed API key")
        return true
    else
        error("Failed to save configuration")
    end
end

"""
    allow_ip(ip::String)

Add an IP address to the global allowlist.
"""
function allow_ip(ip::String)
    config = load_global_config()
    if config === nothing
        error("No configuration found. Run Kaimon.setup_security() first.")
    end
    if ip in config.allowed_ips
        @warn "IP address already in allowlist"
        return false
    end
    if update_global_config!(allowed_ips = vcat(config.allowed_ips, [ip]))
        println("✅ Added IP address to allowlist: $ip")
        return true
    else
        error("Failed to save configuration")
    end
end

"""
    deny_ip(ip::String)

Remove an IP address from the global allowlist.
"""
function deny_ip(ip::String)
    config = load_global_config()
    if config === nothing
        error("No configuration found. Run Kaimon.setup_security() first.")
    end
    if !(ip in config.allowed_ips)
        @warn "IP address not found in allowlist"
        return false
    end
    if update_global_config!(allowed_ips = filter(i -> i != ip, config.allowed_ips))
        println("✅ Removed IP address from allowlist: $ip")
        return true
    else
        error("Failed to save configuration")
    end
end

"""
    set_security_mode(mode::Symbol)

Change the security mode (:strict, :relaxed, or :lax) in the global configuration.
"""
function set_security_mode(mode::Symbol)
    if !(mode in [:strict, :relaxed, :lax])
        error("Invalid security mode. Must be :strict, :relaxed, or :lax")
    end
    if update_global_config!(mode = mode)
        println("✅ Changed security mode to: $mode")
        return true
    else
        error("Failed to save configuration. Run Kaimon.setup_security() first.")
    end
end

"""
    call_tool(tool_id::Symbol, args::Dict)

Call an MCP tool directly from the REPL without hanging.

This helper function handles the two-parameter signature that most tools expect
(args and stream_channel), making it easier to call tools programmatically.

# Examples
```julia
Kaimon.call_tool(:exec_repl, Dict("expression" => "2 + 2"))
Kaimon.call_tool(:investigate_environment, Dict())
Kaimon.call_tool(:search_methods, Dict("query" => "println"))
```

# Available Tools
Call `list_tools()` to see all available tools and their descriptions.
"""
function call_tool(tool_id::Symbol, args::Dict)
    if SERVER[] === nothing
        error("MCP server is not running. Start it with Kaimon.start!()")
    end

    server = SERVER[]
    if !haskey(server.tools, tool_id)
        error("Tool :$tool_id not found. Call list_tools() to see available tools.")
    end

    tool = server.tools[tool_id]

    # Execute tool handler synchronously when called from REPL
    # This avoids deadlock when tools call execute_repllike
    try
        # Try calling with just args first (most common case)
        # If that fails with MethodError, try with streaming channel parameter
        result = try
            tool.handler(args)
        catch e
            if e isa MethodError && hasmethod(tool.handler, Tuple{typeof(args),typeof(nothing)})
                # Handler supports streaming, call with both parameters
                tool.handler(args, nothing)
            else
                rethrow(e)
            end
        end
        return result
    catch e
        rethrow(e)
    end
end

function call_tool(tool_id::Symbol, args::Pair{Symbol,String}...)
    return call_tool(tool_id, Dict([String(k) => v for (k, v) in args]))
end

"""
    list_tools()

List all available MCP tools with their names and descriptions.

Returns a dictionary mapping tool names to their descriptions.
"""
function list_tools()
    if SERVER[] === nothing
        error("MCP server is not running. Start it with Kaimon.start!()")
    end

    server = SERVER[]
    tools_info = Dict{Symbol,String}()

    for (id, tool) in server.tools
        tools_info[id] = tool.description
    end

    # Print formatted output
    println("\n📚 Available MCP Tools")
    println("="^70)
    println()

    for (name, desc) in sort(collect(tools_info))
        printstyled("  • ", name, "\n", color = :cyan, bold = true)
        # Print first line of description
        first_line = split(desc, "\n")[1]
        println("    ", first_line)
        println()
    end

    return tools_info
end

"""
    tool_help(tool_id::Symbol)
Get detailed help/documentation for a specific MCP tool.
"""
function tool_help(tool_id::Symbol; extended::Bool = false)
    if SERVER[] === nothing
        error("MCP server is not running. Start it with Kaimon.start!()")
    end

    server = SERVER[]
    if !haskey(server.tools, tool_id)
        error("Tool :$tool_id not found. Call list_tools() to see available tools.")
    end

    tool = server.tools[tool_id]

    println("\n📖 Help for MCP Tool :$tool_id")
    println("="^70)
    println()
    println(tool.description)
    println()

    # Try to load extended documentation if requested
    if extended
        extended_help_path =
            joinpath(dirname(dirname(@__FILE__)), "extended-help", "$(string(tool_id)).md")

        if isfile(extended_help_path)
            println("\n" * "="^70)
            println("Extended Documentation")
            println("="^70)
            println()
            println(read(extended_help_path, String))
        else
            println("(No extended documentation available for this tool)")
        end
    end

    return tool
end

function restart(; session::String = "")
    call_tool(:manage_repl, Dict("command" => "restart", "session" => session))
end
function shutdown(; session::String = "")
    call_tool(:manage_repl, Dict("command" => "shutdown", "session" => session))
end

"""
    _install_profile_hook!()

Spawn a background watcher that turns a trigger file into an in-process, **timed**
CPU profile of the whole host process. The host has no gate to `ex` into, so this
is how we attribute its CPU — and unlike wall-clock `sample`, `Profile` samples on
a timer and records full backtraces of every thread, so it catches the diffuse,
brief-but-frequent work that a wall-clock snapshot misses.

Usage from outside the process:

    echo 5 > ~/.cache/kaimon/profile_request    # profile for 5s (0.5–60, default 5)
    # ...wait the window...
    less ~/.cache/kaimon/profile_dump.txt        # flat report, hottest self-time first

Event-driven (FileWatching on the cache dir) — zero idle cost until triggered.
"""
function _install_profile_hook!()
    dir = kaimon_cache_dir()
    req = joinpath(dir, "profile_request")
    out = joinpath(dir, "profile_dump.txt")
    Threads.@spawn begin
        while true
            try
                # Wait (event-driven) for the trigger file to appear.
                if !isfile(req)
                    try; watch_folder(dir, 3600); catch; sleep(1.0); end
                    isfile(req) || continue
                end
                secs = clamp(something(tryparse(Float64, strip(read(req, String))),
                                       5.0), 0.5, 60.0)
                rm(req; force = true)
                Profile.clear()
                Profile.init(; n = 30_000_000, delay = 0.001)
                Profile.@profile sleep(secs)
                open(out, "w") do io
                    println(io, "# in-process CPU profile, ", secs, "s window, ",
                            Threads.nthreads(), " threads")
                    Base.invokelatest(Profile.print, io;
                        format = :flat, sortedby = :count, mincount = 5)
                end
                Profile.clear()
            catch e
                try; open(out, "w") do io
                    println(io, "profile hook error: ", sprint(showerror, e))
                end; catch; end
                sleep(1.0)
            end
        end
    end
    return nothing
end

function (@main)(ARGS)
    # Fire-and-forget: resolve the user's global environment in the background.
    # When Kaimon gains new deps, the global env manifest (where Kaimon is dev'd)
    # becomes stale — this ensures `using Kaimon` in startup.jl works next time.
    kaimon_dir = dirname(@__DIR__)
    julia = joinpath(Sys.BINDIR, "julia")
    cmd = `$julia --startup-file=no --project=$kaimon_dir -e "using Pkg; Pkg.resolve(io=devnull); Pkg.instantiate(io=devnull)"`
    run(pipeline(cmd; stdout=devnull, stderr=devnull); wait=false)

    cli_port = nothing
    theme = nothing
    headless = false
    use_revise = false

    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg in ("--port", "-p") && i < length(ARGS)
            i += 1
            cli_port = parse(Int, ARGS[i])
        elseif arg in ("--theme", "-t") && i < length(ARGS)
            i += 1
            theme = Symbol(ARGS[i])
        elseif arg in ("--revise", "-r")
            use_revise = true
        elseif arg == "--headless"
            headless = true
        elseif arg == "--reset-global-prompt"
            _set_global_install_dismissed(false)
            _set_gate_setup_version(0)
            println("Reset: Kaimon will re-check your gate setup on next start.")
            return
        elseif arg in ("--help", "-h")
            println("""
            Kaimon — persistent MCP server with terminal dashboard

            Usage: kaimon [options]

            Options:
              -p, --port PORT             MCP HTTP server port (default: 2828)
              -t, --theme NAME            Theme: kokaku, esper, motoko, neuromancer (default: kokaku)
              -r, --revise                Load Revise for live code reloading
              --headless                  Run without TUI (headless MCP server)
              --reset-global-prompt       Re-enable the "add to global env" prompt
              -h, --help                  Show this help""")
            return
        else
            println("Unknown argument: $arg")
            return
        end
        i += 1
    end

    # Resolve port: CLI arg > config.json > default 2828
    port = if cli_port !== nothing
        cli_port
    else
        cfg = try; load_global_config(); catch; nothing; end
        (cfg !== nothing && cfg.port != 0) ? cfg.port : 2828
    end

    # Load Revise if requested — as a weak dep it may not be in the app's
    # isolated environment, so temporarily add the user's shared env to LOAD_PATH.
    _Revise = nothing
    if use_revise
        shared_env = joinpath(homedir(), ".julia", "environments",
                              "v$(VERSION.major).$(VERSION.minor)")
        added_shared = false
        if isdir(shared_env) && shared_env ∉ Base.load_path()
            pushfirst!(LOAD_PATH, shared_env)
            added_shared = true
        end
        try
            _Revise = Base.require(Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise"))
            pkgid = Base.PkgId(@__MODULE__)
            pkgdata = Base.invokelatest(_Revise.watch_package, pkgid)
            if pkgdata !== nothing
                nfiles = Base.invokelatest(() -> length(_Revise.srcfiles(pkgdata)))
                @info "Revise tracking $nfiles source files for Kaimon"
            else
                @warn "Revise: watch_package returned nothing"
            end
        catch e
            _Revise = nothing
            @warn "Could not load Revise, continuing without it" exception = e
        end
        added_shared && popfirst!(LOAD_PATH)
    end

    # Load optional extensions
    try Main.eval(:(using PDFIO)) catch end

    # Diagnostic: file-triggered in-process CPU profiler (covers TUI + headless).
    try _install_profile_hook!() catch end

    if headless
        start!(; port = port)
        # Non-interactive: block on a quit key (Ctrl-Q / Ctrl-C) and shut down
        # cleanly via stop!() instead of being killed mid-flight. With `-i` we
        # fall through to the REPL and the user can call Kaimon.stop!() manually.
        if Base.JLOptions().isinteractive == 0
            _headless_wait_and_shutdown(port)
        end
    else
        # Offer a one-time, versioned setup update if the user's gate setup is
        # behind GATE_SETUP_VERSION (e.g. a legacy full-Kaimon global install or
        # startup snippet). Records the applied version so it isn't re-prompted.
        # First-time setup: launch the security wizard, which now includes the
        # gate auto-connect step. Existing users instead get the one-time gate
        # setup migration prompt (they won't re-run the wizard).
        has_config = load_global_config() !== nothing
        if !has_config
            result = setup_wizard_tui()
            result === nothing && return
        else
            _maybe_run_setup_update()
        end

        _revise_active = use_revise && _Revise !== nothing
        if _revise_active
            @info "Revise loaded — watching for file changes"
            Base.invokelatest(_start_revise_watcher!, _Revise)
        end

        tui(; port = port, theme_name = theme, revise_polling = _revise_active, revise_mod = _Revise)
    end
end


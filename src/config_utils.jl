# ============================================================================
# Configuration Utilities
#
# Shared helpers for reading/writing VS Code, Claude, and Gemini configs.
# Extracted from the old setup.jl; the interactive wizard UI now lives in
# setup_wizard_tui.jl.
# ============================================================================

using JSON

# ── VS Code workspace MCP config (.vscode/mcp.json) ─────────────────────────

function get_vscode_workspace_mcp_path()
    vscode_dir = joinpath(pwd(), ".vscode")
    return joinpath(vscode_dir, "mcp.json")
end

function read_vscode_mcp_config()
    mcp_path = get_vscode_workspace_mcp_path()

    if !isfile(mcp_path)
        return nothing
    end

    try
        content = read(mcp_path, String)
        return JSON.parse(content; dicttype = Dict)
    catch
        return nothing
    end
end

function write_vscode_mcp_config(config::Dict)
    mcp_path = get_vscode_workspace_mcp_path()
    vscode_dir = dirname(mcp_path)

    if !isdir(vscode_dir)
        mkdir(vscode_dir)
    end

    try
        content = JSON.json(config, 2)
        write(mcp_path, content)

        has_auth_header = false
        if haskey(config, "servers")
            for (name, server_config) in config["servers"]
                if haskey(server_config, "headers") &&
                   haskey(server_config["headers"], "Authorization")
                    has_auth_header = true
                    break
                end
            end
        end

        if has_auth_header && !Sys.iswindows()
            chmod(mcp_path, 0o600)
        end

        return true
    catch e
        @warn "Failed to write VS Code config" exception = e
        return false
    end
end

function check_vscode_status()
    config = read_vscode_mcp_config()

    if config === nothing
        return :not_configured
    end

    servers = get(config, "servers", Dict())

    for (name, server_config) in servers
        if contains(lowercase(string(name)), "julia")
            server_type = get(server_config, "type", "")
            if server_type == "http"
                return :configured_http
            elseif server_type == "stdio"
                return :configured_stdio
            else
                return :configured_unknown
            end
        end
    end

    return :not_configured
end

function add_vscode_mcp_server(_transport_type::String)
    security_config = load_security_config()

    if security_config === nothing
        @warn "No security configuration found. Run Kaimon.setup() first."
        return false
    end

    return Generate.create_vscode_config(
        pwd(),
        security_config.port,
        security_config.mode == :lax ? nothing :
        isempty(security_config.api_keys) ? nothing : first(security_config.api_keys),
    )
end

function remove_vscode_mcp_server()
    config = read_vscode_mcp_config()

    if config === nothing
        return true
    end

    servers = get(config, "servers", Dict())

    for name in collect(keys(servers))
        if contains(lowercase(string(name)), "julia")
            delete!(servers, name)
        end
    end

    config["servers"] = servers
    return write_vscode_mcp_config(config)
end

# ── Claude Code config (~/.claude.json) ──────────────────────────────────────

function get_claude_config_path()
    return expanduser("~/.claude.json")
end

function read_claude_config()
    config_path = get_claude_config_path()

    if !isfile(config_path)
        return nothing
    end

    try
        content = read(config_path, String)
        return JSON.parse(content; dicttype = Dict)
    catch
        return nothing
    end
end

function write_claude_config(config::Dict)
    config_path = get_claude_config_path()

    try
        content = JSON.json(config, 2)
        write(config_path, content)

        if !Sys.iswindows()
            chmod(config_path, 0o600)
        end

        return true
    catch e
        @warn "Failed to write Claude config" exception = e
        return false
    end
end

function add_claude_mcp_server(; api_key::Union{String,Nothing} = nothing)
    security_config = load_security_config()

    if security_config === nothing
        @warn "No security configuration found. Run Kaimon.setup() first."
        return false
    end

    port = security_config.port
    url = "http://localhost:$port"

    try
        repl_id = basename(pwd())

        if api_key !== nothing
            run(
                `claude mcp add kaimon $url --scope project --transport http -H "Authorization: Bearer $api_key" -H "X-Kaimon-Target: $repl_id"`,
            )
        else
            run(
                `claude mcp add kaimon $url --scope project --transport http -H "X-Kaimon-Target: $repl_id"`,
            )
        end
        return true
    catch e
        @warn "Failed to configure Claude MCP server" exception = e
        return false
    end
end

function remove_claude_mcp_server()
    try
        run(`claude mcp remove --scope project kaimon`)
        return true
    catch e
        if occursin("not found", string(e)) || occursin("does not exist", string(e))
            return true
        end
        @warn "Failed to remove Claude MCP server" exception = e
        return false
    end
end

# ── VS Code settings (.vscode/settings.json) ────────────────────────────────

function get_vscode_settings_path()
    vscode_dir = joinpath(pwd(), ".vscode")
    return joinpath(vscode_dir, "settings.json")
end

function read_vscode_settings()
    settings_path = get_vscode_settings_path()

    if !isfile(settings_path)
        return Dict()
    end

    try
        content = read(settings_path, String)
        lines = split(content, '\n')
        cleaned_lines = filter(line -> !startswith(strip(line), "//"), lines)
        cleaned_content = join(cleaned_lines, '\n')
        return JSON.parse(cleaned_content; dicttype = Dict)
    catch e
        @warn "Failed to read VS Code settings.json" exception = e
        return Dict()
    end
end

function write_vscode_settings(settings::Dict)
    settings_path = get_vscode_settings_path()
    vscode_dir = dirname(settings_path)

    if !isdir(vscode_dir)
        mkdir(vscode_dir)
    end

    try
        content = JSON.json(settings, 2)
        write(settings_path, content)
        return true
    catch e
        @warn "Failed to write VS Code settings.json" exception = e
        return false
    end
end

# ── Startup script helpers ───────────────────────────────────────────────────

function get_startup_script_path()
    return joinpath(pwd(), ".julia-startup.jl")
end

function has_startup_script()
    return isfile(get_startup_script_path())
end

function install_startup_script()
    startup_path = get_startup_script_path()
    return Generate.create_startup_script(dirname(startup_path))
end

function install_repl_script()
    return Generate.create_repl_script(pwd())
end

function install_env_file()
    security_config = load_security_config()
    port = security_config !== nothing ? security_config.port : 3000
    api_key = nothing
    if security_config !== nothing && !isempty(security_config.api_keys)
        api_key = first(security_config.api_keys)
    end
    return Generate.create_env_file(pwd(), port, api_key)
end

function install_claude_settings()
    security_config = load_security_config()
    port = security_config !== nothing ? security_config.port : 3000
    api_key = nothing
    if security_config !== nothing && !isempty(security_config.api_keys)
        api_key = first(security_config.api_keys)
    end
    return Generate.create_claude_env_settings(pwd(), port, api_key)
end

function configure_vscode_julia_args()
    settings = read_vscode_settings()
    load_arg = "--load=\${workspaceFolder}/.julia-startup.jl"

    if !haskey(settings, "julia.additionalArgs")
        settings["julia.additionalArgs"] = []
    end

    args = settings["julia.additionalArgs"]

    has_load_arg =
        any(arg -> contains(arg, "--load") && contains(arg, ".julia-startup.jl"), args)

    if !has_load_arg
        push!(args, load_arg)
        settings["julia.additionalArgs"] = args
        return write_vscode_settings(settings)
    end

    return true
end

function check_vscode_startup_configured()
    settings = read_vscode_settings()

    if !haskey(settings, "julia.additionalArgs")
        return false
    end

    args = settings["julia.additionalArgs"]
    return any(arg -> contains(arg, "--load") && contains(arg, ".julia-startup.jl"), args)
end

function check_vscode_extension_installed()
    ext_dir = vscode_extensions_dir()
    try
        entries = readdir(ext_dir)
        return any(entry -> startswith(entry, "Kaimon.vscode-remote-control"), entries)
    catch
        return false
    end
end

# ── Claude Code CLI status ───────────────────────────────────────────────────

function check_claude_status()
    try
        if !success(pipeline(`claude --version`, stdout = devnull, stderr = devnull))
            return :claude_not_found
        end
    catch
        return :claude_not_found
    end

    try
        output = read(`claude mcp list`, String)
        if contains(output, "kaimon")
            if contains(output, "http://localhost")
                return :configured_http
            elseif contains(output, "mcp-julia-adapter")
                return :configured_script
            else
                return :configured_unknown
            end
        else
            return :not_configured
        end
    catch
        return :not_configured
    end
end

# ── Gemini CLI config (~/.gemini/settings.json) ──────────────────────────────

function get_gemini_settings_path()
    homedir_path = expanduser("~")
    gemini_dir = joinpath(homedir_path, ".gemini")
    settings_path = joinpath(gemini_dir, "settings.json")
    return gemini_dir, settings_path
end

function read_gemini_settings()
    gemini_dir, settings_path = get_gemini_settings_path()

    if !isfile(settings_path)
        return Dict()
    end

    try
        content = read(settings_path, String)
        return JSON.parse(content; dicttype = Dict)
    catch
        return Dict()
    end
end

function write_gemini_settings(settings::Dict)
    gemini_dir, settings_path = get_gemini_settings_path()

    if !isdir(gemini_dir)
        mkdir(gemini_dir)
    end

    try
        content = JSON.json(settings, 2)
        write(settings_path, content)
        return true
    catch
        return false
    end
end

function check_gemini_status()
    try
        if !success(pipeline(`gemini --version`, stdout = devnull, stderr = devnull))
            return :gemini_not_found
        end
    catch
        return :gemini_not_found
    end

    settings = read_gemini_settings()
    mcp_servers = get(settings, "mcpServers", Dict())

    if haskey(mcp_servers, "kaimon")
        server_config = mcp_servers["kaimon"]
        if haskey(server_config, "url") &&
           contains(server_config["url"], "http://localhost")
            return :configured_http
        elseif haskey(server_config, "command")
            return :configured_script
        else
            return :configured_unknown
        end
    else
        return :not_configured
    end
end

function add_gemini_mcp_server(transport_type::String)
    security_config = load_security_config()

    if security_config === nothing
        @warn "No security configuration found. Run Kaimon.setup() first."
        return false
    end

    port = security_config.port

    settings = read_gemini_settings()

    if !haskey(settings, "mcpServers")
        settings["mcpServers"] = Dict()
    end

    if transport_type == "http"
        settings["mcpServers"]["kaimon"] = Dict("url" => "http://localhost:$port")
    elseif transport_type == "script"
        settings["mcpServers"]["kaimon"] =
            Dict("command" => "$(pkgdir(Kaimon))/mcp-julia-adapter")
    else
        return false
    end

    return write_gemini_settings(settings)
end

function remove_gemini_mcp_server()
    settings = read_gemini_settings()

    if haskey(settings, "mcpServers") && haskey(settings["mcpServers"], "kaimon")
        delete!(settings["mcpServers"], "kaimon")
        return write_gemini_settings(settings)
    end

    return true
end

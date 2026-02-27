# ============================================================================
# Generate Module - Config File Generators
# ============================================================================

"""
    Generate

Module for generating configuration files for Kaimon projects.

Provides functions to create startup scripts, REPL launchers, VS Code configs,
environment files, and Claude settings for AI agent integration.
"""
module Generate

using OteraEngine

# Export file generation functions used by config_utils.jl and setup_wizard_tui.jl
export create_startup_script, create_repl_script
export create_vscode_config, create_env_file, create_claude_env_settings
# Export the VS Code commands constant for testing
export VSCODE_ALLOWED_COMMANDS

"""
    load_vscode_allowed_commands()

Load the list of allowed VS Code commands from the template file.

This function reads the vscode-allowed-commands.txt file from the templates directory
and returns an array of command strings. Each line in the file represents one command.
"""
function load_vscode_allowed_commands()
    template_path = joinpath(@__DIR__, "..", "templates", "vscode-allowed-commands.txt")
    if !isfile(template_path)
        error("VS Code allowed commands template file not found at: $template_path")
    end

    # Read file and filter out empty lines
    commands = String[]
    for line in eachline(template_path)
        stripped = strip(line)
        if !isempty(stripped)
            push!(commands, stripped)
        end
    end

    return commands
end

# VS Code Remote Control allowed commands list
# This list is used in generated .vscode/settings.json files
# Commands are loaded from templates/vscode-allowed-commands.txt
const VSCODE_ALLOWED_COMMANDS = load_vscode_allowed_commands()

# ============================================================================
# Template Helper Functions
# ============================================================================

function render_template(template_name::String; kwargs...)
    template_path = abspath(joinpath(@__DIR__, "..", "templates", template_name * ".tmpl"))
    if !isfile(template_path)
        error("Template file not found: $template_path")
    end
    tmp = Template(template_path, config = Dict("autoescape" => false))
    tmp(init = Dict(kwargs))
end

function create_startup_script(project_path::String)
    println("📝 Creating Julia startup script...")

    startup_content = render_template("julia-startup.jl")

    startup_path = joinpath(project_path, ".julia-startup.jl")
    write(startup_path, startup_content)
    return true
end

function create_repl_script(project_path::String)
    println("🚀 Creating repl launcher script...")
    repl_content = """#!/usr/bin/env bash

# Start Julia REPL with Kaimon project and auto-load startup script
# This script launches Julia in the project and loads the startup script.

SCRIPT_DIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" && pwd )"

echo "Starting Julia REPL with Kaimon project..."
echo ""

exec julia -i --project="\$SCRIPT_DIR" --load="\$SCRIPT_DIR/.julia-startup.jl" "\$@"
"""

    repl_path = joinpath(project_path, "repl")
    write(repl_path, repl_content)

    # Make it executable on Unix-like systems
    if !Sys.iswindows()
        try
            chmod(repl_path, 0o755)
        catch
            # Silently fail if chmod isn't available
        end
    end

    return true
end

function create_env_file(
    project_path::String,
    port::Int,
    api_key::Union{String,Nothing} = nothing,
)
    println("🔐 Creating .env file...")

    repl_id = basename(project_path)
    env_content = render_template(
        "env";
        has_api_key = api_key !== nothing,
        api_key = api_key,
        port = port,
        repl_id = repl_id,
    )

    env_path = joinpath(project_path, ".env")
    write(env_path, env_content)

    return true
end

function create_claude_env_settings(
    project_path::String,
    port::Int,
    api_key::Union{String,Nothing} = nothing,
)
    println("🔐 Creating .claude/settings.local.json...")

    claude_dir = joinpath(project_path, ".claude")
    mkpath(claude_dir)

    repl_id = basename(project_path)
    settings_content = render_template(
        "claude-settings.local.json";
        has_api_key = api_key !== nothing,
        api_key = api_key,
        port = string(port),
        repl_id = repl_id,
    )

    settings_path = joinpath(claude_dir, "settings.local.json")
    write(settings_path, settings_content)

    return true
end

function create_vscode_config(
    project_path::String,
    port::Int,
    api_key::Union{String,Nothing} = nothing,
)
    println("⚙️  Creating VS Code MCP configuration...")

    vscode_dir = joinpath(project_path, ".vscode")
    mkpath(vscode_dir)

    repl_id = basename(project_path)
    mcp_content = render_template(
        "vscode-mcp.json";
        port = port,
        has_api_key = api_key !== nothing,
        api_key = api_key,
        repl_id = repl_id,
    )

    mcp_path = joinpath(vscode_dir, "mcp.json")
    write(mcp_path, mcp_content)

    return true
end

end # module Generate

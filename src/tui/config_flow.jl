# ── Config Flow: Begin ───────────────────────────────────────────────────────

function begin_onboarding!(m::KaimonModel)
    m.config_flow = FLOW_ONBOARD_PATH
    m.path_input = TextInput(text = string(pwd()), label = "Path: ", tick = m.tick)
    m.flow_selected = 1
    m.flow_modal_selected = :confirm
end

function begin_client_config!(m::KaimonModel)
    m.config_flow = FLOW_CLIENT_SELECT
    m.flow_selected = 1
    m.flow_modal_selected = :confirm
end

function begin_global_gate!(m::KaimonModel)
    m.client_target = :startup_jl
    m.flow_modal_selected = :confirm
    m.config_flow = FLOW_CLIENT_CONFIRM
end

# ── Config Flow: Input Handler ───────────────────────────────────────────────

const CLIENT_OPTIONS = [:claude, :gemini, :codex, :copilot, :vscode, :kilo, :cursor, :opencode]
const CLIENT_LABELS = [
    "Claude Code",
    "Gemini CLI",
    "OpenAI Codex",
    "GitHub Copilot",
    "VS Code / Copilot",
    "KiloCode",
    "Cursor",
    "OpenCode",
]
const CLIENT_LABEL = Dict(
    :claude    => "Claude Code",
    :gemini    => "Gemini CLI",
    :codex     => "OpenAI Codex",
    :copilot   => "GitHub Copilot",
    :vscode    => "VS Code / Copilot",
    :kilo      => "KiloCode",
    :cursor    => "Cursor",
    :opencode  => "OpenCode",
    :startup_jl => "Julia startup.jl (global gate)",
)

function handle_flow_input!(m::KaimonModel, evt::KeyEvent)
    flow = m.config_flow

    if flow == FLOW_ONBOARD_PATH
        @match evt.key begin
            :enter => begin
                m.onboard_path = Tachikoma.text(m.path_input)
                m.flow_modal_selected = :confirm
                m.config_flow = FLOW_ONBOARD_CONFIRM
            end
            :tab => _complete_path!(m.path_input)
            _ => handle_key!(m.path_input, evt)
        end
    elseif flow == FLOW_ONBOARD_CONFIRM
        @match evt.key begin
            :left || :right => begin
                m.flow_modal_selected =
                    m.flow_modal_selected == :cancel ? :confirm : :cancel
            end
            :enter => begin
                m.flow_modal_selected == :confirm ? execute_onboarding!(m) :
                (m.config_flow = FLOW_IDLE)
            end
            _ => nothing
        end
    elseif flow == FLOW_ONBOARD_RESULT
        m.config_flow = FLOW_IDLE
    elseif flow == FLOW_CLIENT_SELECT
        @match evt.key begin
            :up => (m.flow_selected = max(1, m.flow_selected - 1))
            :down => (m.flow_selected = min(length(CLIENT_OPTIONS), m.flow_selected + 1))
            :enter => begin
                m.client_target = CLIENT_OPTIONS[m.flow_selected]
                m.flow_modal_selected = :confirm
                m.config_flow = FLOW_CLIENT_CONFIRM
            end
            _ => nothing
        end
    elseif flow == FLOW_CLIENT_CONFIRM
        @match (evt.key, evt.char) begin
            (:enter, _) => execute_client_config!(m)

            (:char, 'r') => begin
                client_label = get(CLIENT_LABEL, m.client_target, "")
                configured =
                    any(p -> p.first == client_label && p.second, m.client_statuses)
                configured && remove_client_config!(m)
            end
            _ => nothing
        end
    elseif flow == FLOW_CLIENT_RESULT
        m.config_flow = FLOW_IDLE
        _refresh_client_status_async!(m)
    end
end

# ── Config Flow: Execution ───────────────────────────────────────────────────

function execute_onboarding!(m::KaimonModel)
    if m._render_mode
        m.flow_message = "(render mode — no files written)"
        m.flow_success = true
        m.config_flow = FLOW_ONBOARD_RESULT
        return
    end
    try
        path = rstrip(expanduser(m.onboard_path), ['/', '\\'])
        isdir(path) || mkpath(path)
        startup_file = joinpath(path, ".julia-startup.jl")
        write(startup_file, Generate.render_template("julia-startup.jl"))
        m.flow_message = "Created $(_short_path(startup_file))\n\nAdd to your project's startup:\n  include(\".julia-startup.jl\")"
        m.flow_success = true
    catch e
        m.flow_message = "Error: $(sprint(showerror, e))"
        m.flow_success = false
    end
    m.config_flow = FLOW_ONBOARD_RESULT
end

"""Get the first API key from security config, or `nothing` if lax/unconfigured."""
function _get_api_key()
    cfg = load_global_security_config()
    cfg === nothing && return nothing
    cfg.mode == :lax && return nothing
    isempty(cfg.api_keys) && return nothing
    return first(cfg.api_keys)
end

function execute_client_config!(m::KaimonModel)
    if m._render_mode
        m.flow_message = "(render mode — no files written)"
        m.flow_success = true
        m.config_flow = FLOW_CLIENT_RESULT
        return
    end
    try
        port = m.server_port
        api_key = _get_api_key()
        @match m.client_target begin
            :claude => _install_claude(m, port, api_key)
            :gemini => _install_gemini(m, port, api_key)
            :codex => _install_codex(m, port, api_key)
            :copilot => _install_copilot(m, port, api_key)
            :vscode => _install_vscode(m, port, api_key)
            :kilo => _install_kilo(m, port, api_key)
            :cursor => _install_cursor(m, port, api_key)
            :opencode => _install_opencode(m, port, api_key)
            :startup_jl => _install_startup_jl(m)
            _ => nothing
        end
    catch e
        m.flow_message = "Error: $(sprint(showerror, e))"
        m.flow_success = false
    end
    m.config_flow = FLOW_CLIENT_RESULT
end

function toggle_gate_mirror_repl!(m::KaimonModel)
    m._render_mode && return
    new_value = !m.gate_mirror_repl
    m.gate_mirror_repl = set_gate_mirror_repl_preference!(new_value)

    applied = 0
    total = 0
    if m.conn_mgr !== nothing
        conns = connected_sessions(m.conn_mgr)
        total = length(conns)
        for conn in conns
            set_mirror_repl!(conn, m.gate_mirror_repl) && (applied += 1)
        end
    end

    state = m.gate_mirror_repl ? "enabled" : "disabled"
    _push_log!(
        :info,
        "Host REPL mirroring $state (applied to $applied/$total connected gate sessions)",
    )
end

function remove_client_config!(m::KaimonModel)
    if m._render_mode
        m.flow_message = "(render mode — no files written)"
        m.flow_success = true
        m.config_flow = FLOW_CLIENT_RESULT
        return
    end
    try
        @match m.client_target begin
            :claude => _remove_claude(m)
            :gemini => _remove_gemini(m)
            :codex => _remove_codex(m)
            :copilot => _remove_copilot(m)
            :vscode => _remove_vscode(m)
            :kilo => _remove_kilo(m)
            :cursor => _remove_cursor(m)
            :opencode => _remove_opencode(m)
            :startup_jl => _remove_startup_jl(m)
            _ => nothing
        end
    catch e
        m.flow_message = "Error: $(sprint(showerror, e))"
        m.flow_success = false
    end
    m.config_flow = FLOW_CLIENT_RESULT
end

# ── Remove helpers ────────────────────────────────────────────────────────────

function _remove_claude(m::KaimonModel)
    for s in ("project", "user", "local")
        try read(pipeline(`claude mcp remove --scope $s kaimon`; stderr = devnull), String) catch end
    end
    m.flow_message = "Removed kaimon from Claude Code"
    m.flow_success = true
end

function _remove_gemini(m::KaimonModel)
    for s in ("project", "user")
        try read(pipeline(`gemini mcp remove --scope $s kaimon`; stderr = devnull), String) catch end
    end
    m.flow_message = "Removed kaimon from Gemini CLI"
    m.flow_success = true
end

function _remove_codex(m::KaimonModel)
    try
        read(pipeline(`codex mcp remove kaimon`; stderr = devnull), String)
    catch
    end
    _codex_env_remove!("MCPREPL_API_KEY")
    m.flow_message = "Removed kaimon from Codex CLI"
    m.flow_success = true
end

function _remove_copilot(m::KaimonModel)
    target_file = joinpath(homedir(), ".copilot", "mcp-config.json")
    _remove_server_from_json!(target_file, "mcpServers")
    m.flow_message = "Removed kaimon from\n$(_short_path(target_file))"
    m.flow_success = true
end

function _remove_vscode(m::KaimonModel)
    mcp_dir = if Sys.isapple()
        joinpath(homedir(), "Library", "Application Support", "Code", "User")
    elseif Sys.iswindows()
        joinpath(get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")), "Code", "User")
    else
        joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "Code", "User")
    end
    target_file = joinpath(mcp_dir, "mcp.json")
    _remove_server_from_json!(target_file, "servers")
    m.flow_message = "Removed kaimon from\n$(_short_path(target_file))"
    m.flow_success = true
end

function _remove_kilo(m::KaimonModel)
    target_file = joinpath(_kilo_settings_dir(), "mcp_settings.json")
    _remove_server_from_json!(target_file, "mcpServers")
    m.flow_message = "Removed kaimon from\n$(_short_path(target_file))"
    m.flow_success = true
end

const _STARTUP_MARKER = "# Kaimon Gate — auto-connect"

function _install_startup_jl(m::KaimonModel)
    startup_dir = joinpath(homedir(), ".julia", "config")
    isdir(startup_dir) || mkpath(startup_dir)
    startup_file = joinpath(startup_dir, "startup.jl")
    existing = isfile(startup_file) ? read(startup_file, String) : ""
    if occursin(_STARTUP_MARKER, existing)
        m.flow_message = "Gate snippet already present in\n$(_short_path(startup_file))"
    else
        open(startup_file, "a") do io
            write(io, "\n" * Generate.render_template("julia-startup.jl"))
        end
        m.flow_message = "Appended gate snippet to\n$(_short_path(startup_file))\n\nEvery new Julia session will now auto-connect to Kaimon."
    end
    m.flow_success = true
end

function _remove_startup_jl(m::KaimonModel)
    startup_file = joinpath(homedir(), ".julia", "config", "startup.jl")
    isfile(startup_file) || begin
        m.flow_message = "~/.julia/config/startup.jl not found"
        m.flow_success = false
        return
    end
    content = read(startup_file, String)
    # Remove the block from the marker line through the closing `end\n`
    pattern = Regex("\\n?" * _STARTUP_MARKER * ".*?end\\n?", "s")
    stripped = replace(content, pattern => "")
    if stripped == content
        m.flow_message = "Gate snippet not found in\n$(_short_path(startup_file))"
        m.flow_success = false
    else
        write(startup_file, stripped)
        m.flow_message = "Removed gate snippet from\n$(_short_path(startup_file))"
        m.flow_success = true
    end
end

"""Remove `kaimon` from a JSON config file under the given servers key."""
function _remove_server_from_json!(path::String, servers_key::String)
    isfile(path) || error("Config file not found: $path")
    data = JSON.parsefile(path)
    servers = get(data, servers_key, nothing)
    servers === nothing && error("No $servers_key section in $path")
    haskey(servers, "kaimon") || error("kaimon not found in $path")
    delete!(servers, "kaimon")
    data[servers_key] = servers
    write(path, _to_json(data))
end

"""Set or update `key=value` in `~/.codex/.env`, preserving other lines."""
function _codex_env_set!(key::String, value::String)
    env_file = joinpath(homedir(), ".codex", ".env")
    lines = isfile(env_file) ? readlines(env_file) : String[]
    # Remove any existing line for this key
    filter!(l -> !startswith(l, "$key="), lines)
    push!(lines, "$key=$value")
    write(env_file, join(lines, "\n") * "\n")
end

"""Remove `key` from `~/.codex/.env`, preserving other lines."""
function _codex_env_remove!(key::String)
    env_file = joinpath(homedir(), ".codex", ".env")
    isfile(env_file) || return
    lines = readlines(env_file)
    filter!(l -> !startswith(l, "$key="), lines)
    if isempty(lines)
        rm(env_file)
    else
        write(env_file, join(lines, "\n") * "\n")
    end
end

# ── Install helpers ───────────────────────────────────────────────────────────

function _install_claude(m::KaimonModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    scope = string(m.client_scope)
    for s in ("project", "user", "local")
        try read(pipeline(`claude mcp remove --scope $s kaimon`; stderr = devnull), String) catch end
    end
    args = `claude mcp add --transport http --scope $scope kaimon $url`
    if api_key !== nothing
        args = `$args -H "Authorization: Bearer $api_key"`
    end
    read(pipeline(args; stderr = stderr), String)
    m.flow_message = "Added kaimon to Claude Code\n(scope: $scope)"
    m.flow_success = true
end

function _install_vscode(m::KaimonModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    # VS Code user-level MCP config
    mcp_dir = if Sys.isapple()
        joinpath(homedir(), "Library", "Application Support", "Code", "User")
    elseif Sys.iswindows()
        joinpath(get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")), "Code", "User")
    else
        joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "Code", "User")
    end
    isdir(mcp_dir) || mkpath(mcp_dir)
    mcp_file = joinpath(mcp_dir, "mcp.json")

    # Merge with existing config to preserve other servers
    existing = if isfile(mcp_file)
        try
            JSON.parsefile(mcp_file)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    servers = get(existing, "servers", Dict{String,Any}())
    entry = Dict{String,Any}("type" => "http", "url" => url)
    if api_key !== nothing
        entry["headers"] = Dict{String,Any}("Authorization" => "Bearer $api_key")
    end
    servers["kaimon"] = entry
    existing["servers"] = servers
    write(mcp_file, _to_json(existing))
    m.flow_message = "Wrote $(_short_path(mcp_file))"
    m.flow_success = true
end

function _install_gemini(m::KaimonModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    scope = string(m.client_scope)
    for s in ("project", "user")
        try read(pipeline(`gemini mcp remove --scope $s kaimon`; stderr = devnull), String) catch end
    end
    args = `gemini mcp add --transport http --scope $scope kaimon $url`
    if api_key !== nothing
        args = `$args -H "Authorization: Bearer $api_key"`
    end
    read(pipeline(args; stderr = devnull), String)
    m.flow_message = "Added kaimon to Gemini CLI\n(scope: $scope)"
    m.flow_success = true
end

function _install_kilo(m::KaimonModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    kilo_dir = _kilo_settings_dir()
    isdir(kilo_dir) || mkpath(kilo_dir)
    target_file = joinpath(kilo_dir, "mcp_settings.json")

    # Merge with existing config to preserve other servers
    existing = if isfile(target_file)
        try
            JSON.parsefile(target_file)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    servers = get(existing, "mcpServers", Dict{String,Any}())
    entry = Dict{String,Any}("type" => "streamable-http", "url" => url)
    if api_key !== nothing
        entry["headers"] = Dict{String,Any}("Authorization" => "Bearer $api_key")
    end
    servers["kaimon"] = entry
    existing["mcpServers"] = servers
    write(target_file, _to_json(existing))
    m.flow_message = "Wrote $(_short_path(target_file))"
    m.flow_success = true
end

function _install_codex(m::KaimonModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    try
        read(pipeline(`codex mcp remove kaimon`; stderr = devnull), String)
    catch
    end
    args = if api_key !== nothing
        `codex mcp add --url $url --bearer-token-env-var MCPREPL_API_KEY kaimon`
    else
        `codex mcp add --url $url kaimon`
    end
    read(pipeline(args; stderr = devnull), String)
    if api_key !== nothing
        _codex_env_set!("MCPREPL_API_KEY", api_key)
    end
    m.flow_message = "Added kaimon to Codex CLI\n(~/.codex/config.toml)"
    m.flow_success = true
end

function _install_copilot(m::KaimonModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    copilot_dir = joinpath(homedir(), ".copilot")
    isdir(copilot_dir) || mkpath(copilot_dir)
    target_file = joinpath(copilot_dir, "mcp-config.json")

    # Merge with existing config to preserve other servers
    existing = if isfile(target_file)
        try
            JSON.parsefile(target_file)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    servers = get(existing, "mcpServers", Dict{String,Any}())
    entry = Dict{String,Any}("type" => "http", "url" => url)
    if api_key !== nothing
        entry["headers"] = Dict{String,Any}("Authorization" => "Bearer $api_key")
    end
    servers["kaimon"] = entry
    existing["mcpServers"] = servers
    write(target_file, _to_json(existing))
    m.flow_message = "Wrote $(_short_path(target_file))"
    m.flow_success = true
end

# ── Cursor ───────────────────────────────────────────────────────────────────

function _install_cursor(m::KaimonModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    cursor_dir = joinpath(homedir(), ".cursor")
    isdir(cursor_dir) || mkpath(cursor_dir)
    target_file = joinpath(cursor_dir, "mcp.json")

    # Merge with existing config to preserve other servers
    existing = if isfile(target_file)
        try
            JSON.parsefile(target_file)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    servers = get(existing, "mcpServers", Dict{String,Any}())
    entry = Dict{String,Any}("type" => "http", "url" => url)
    if api_key !== nothing
        entry["headers"] = Dict{String,Any}("Authorization" => "Bearer $api_key")
    end
    servers["kaimon"] = entry
    existing["mcpServers"] = servers
    write(target_file, _to_json(existing))
    m.flow_message = "Wrote $(_short_path(target_file))"
    m.flow_success = true
end

function _remove_cursor(m::KaimonModel)
    target_file = joinpath(homedir(), ".cursor", "mcp.json")
    _remove_server_from_json!(target_file, "mcpServers")
    m.flow_message = "Removed kaimon from\n$(_short_path(target_file))"
    m.flow_success = true
end

# ── OpenCode ──────────────────────────────────────────────────────────────────

function _install_opencode(m::KaimonModel, port::Int, api_key)
    url = "http://localhost:$port/mcp"
    opencode_dir = joinpath(homedir(), ".config", "opencode")
    isdir(opencode_dir) || mkpath(opencode_dir)
    target_file = joinpath(opencode_dir, "opencode.json")

    # Merge with existing config to preserve other servers
    existing = if isfile(target_file)
        try
            JSON.parsefile(target_file)
        catch
            Dict{String,Any}()
        end
    else
        Dict{String,Any}()
    end
    mcp_servers = get(existing, "mcp", Dict{String,Any}())
    entry = Dict{String,Any}(
        "type" => "remote",
        "url" => url,
        "enabled" => true
    )
    if api_key !== nothing
        entry["headers"] = Dict{String,Any}("Authorization" => "Bearer $api_key")
    end
    mcp_servers["kaimon"] = entry
    existing["mcp"] = mcp_servers
    write(target_file, _to_json(existing))
    m.flow_message = "Wrote $(_short_path(target_file))"
    m.flow_success = true
end

function _remove_opencode(m::KaimonModel)
    target_file = joinpath(homedir(), ".config", "opencode", "opencode.json")
    _remove_server_from_json!(target_file, "mcp")
    m.flow_message = "Removed kaimon from\n$(_short_path(target_file))"
    m.flow_success = true
end

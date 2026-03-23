# ── Config Flow: Begin ───────────────────────────────────────────────────────

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

function begin_project_add!(m::KaimonModel)
    m.config_flow = FLOW_PROJECT_ADD_PATH
    m.project_path_input = TextInput(text = string(pwd()), label = "Path: ", tick = m.tick)
    m.flow_modal_selected = :confirm
end

function begin_project_remove!(m::KaimonModel)
    isempty(m.project_entries) && return
    m.selected_project < 1 && return
    m.selected_project > length(m.project_entries) && return
    m.flow_modal_selected = :confirm
    m.config_flow = FLOW_PROJECT_REMOVE_CONFIRM
end

function begin_project_edit_launch!(m::KaimonModel)
    isempty(m.project_entries) && return
    m.selected_project < 1 && return
    m.selected_project > length(m.project_entries) && return
    lc = m.project_entries[m.selected_project].launch_config
    m.launch_config_inputs = Dict{Symbol,Any}(
        :threads => TextInput(text = lc.threads, label = "", tick = m.tick),
        :gcthreads => TextInput(text = lc.gcthreads, label = "", tick = m.tick),
        :heap_size_hint => TextInput(text = lc.heap_size_hint, label = "", tick = m.tick),
        :extra_flags => TextInput(text = join(lc.extra_flags, " "), label = "", tick = m.tick),
    )
    m.launch_config_selected = 1
    m.config_flow = FLOW_PROJECT_EDIT_LAUNCH
end

function begin_tcp_gate_add!(m::KaimonModel)
    m.tcp_gate_input = TextInput(text = "127.0.0.1:9876", label = "Host:Port: ", tick = m.tick)
    m.tcp_gate_name_input = TextInput(text = "", label = "Name: ", tick = m.tick)
    m.tcp_gate_token_input = TextInput(text = "", label = "Token: ", tick = m.tick)
    m.tcp_gate_stream_port_input = TextInput(text = "", label = "Stream: ", tick = m.tick)
    m._tcp_gate_field = 1
    m.config_flow = FLOW_TCP_GATE_ADD
end

function _execute_tcp_gate_add!(m::KaimonModel)
    addr = strip(Tachikoma.text(m.tcp_gate_input))
    name = strip(Tachikoma.text(m.tcp_gate_name_input))

    # Parse host:port
    parts = split(addr, ':')
    host = length(parts) >= 1 ? String(strip(parts[1])) : ""
    port = length(parts) >= 2 ? tryparse(Int, strip(parts[2])) : 9876
    if isempty(host) || port === nothing
        m.flow_message = "Invalid address: $addr"
        m.flow_success = false
        m.config_flow = FLOW_TCP_GATE_ADD_RESULT
        return
    end

    # Check for duplicates
    for e in m.tcp_gate_entries
        if e.host == host && e.port == port
            m.flow_message = "Already registered: $host:$port"
            m.flow_success = false
            m.config_flow = FLOW_TCP_GATE_ADD_RESULT
            return
        end
    end

    token = strip(Tachikoma.text(m.tcp_gate_token_input))
    sp_str = strip(Tachikoma.text(m.tcp_gate_stream_port_input))
    stream_port = isempty(sp_str) ? 0 : something(tryparse(Int, sp_str), 0)
    entry = TCPGateEntry(host, port, isempty(name) ? "$host:$port" : name, true, token, stream_port)
    push!(m.tcp_gate_entries, entry)
    save_tcp_gates_config(m.tcp_gate_entries)
    m.flow_message = "Added TCP gate: $(entry.name) ($host:$port)"
    m.flow_success = true
    m.config_flow = FLOW_TCP_GATE_ADD_RESULT
end

function _cycle_qdrant_prefix!(m::KaimonModel)
    current = get_collection_prefix()
    m.qdrant_prefix_input = TextInput(text = current, label = "Prefix: ", tick = m.tick)
    m.config_flow = FLOW_QDRANT_PREFIX
end

function _execute_qdrant_prefix!(m::KaimonModel)
    prefix = strip(Tachikoma.text(m.qdrant_prefix_input))
    set_collection_prefix!(prefix)

    # Persist to config
    try
        config = load_global_config()
        if config !== nothing
            new_config = KaimonConfig(
                config.mode, config.api_keys, config.allowed_ips,
                config.port, config.editor, prefix)
            save_global_config(new_config)
        end
    catch
    end

    if isempty(prefix)
        m.flow_message = "Qdrant prefix cleared (using default collection names)"
    else
        m.flow_message = "Qdrant prefix set to: $prefix"
    end
    m.flow_success = true
    m.config_flow = FLOW_QDRANT_PREFIX_RESULT
end

function _remove_tcp_gate!(m::KaimonModel)
    isempty(m.tcp_gate_entries) && return
    idx = m.selected_tcp_gate
    (idx < 1 || idx > length(m.tcp_gate_entries)) && return
    entry = m.tcp_gate_entries[idx]

    # Disconnect if connected
    if m.conn_mgr !== nothing
        sid = "tcp-$(entry.host)-$(entry.port)"
        lock(m.conn_mgr.lock) do
            ci = findfirst(c -> c.session_id == sid, m.conn_mgr.connections)
            if ci !== nothing
                disconnect!(m.conn_mgr.connections[ci])
                deleteat!(m.conn_mgr.connections, ci)
            end
        end
    end

    deleteat!(m.tcp_gate_entries, idx)
    save_tcp_gates_config(m.tcp_gate_entries)
    m.selected_tcp_gate = clamp(m.selected_tcp_gate, 1, max(1, length(m.tcp_gate_entries)))
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

    if flow == FLOW_CLIENT_SELECT
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

    elseif flow == FLOW_PROJECT_ADD_PATH
        @match evt.key begin
            :enter => begin
                m.onboard_path = Tachikoma.text(m.project_path_input)
                m.flow_modal_selected = :confirm
                m.config_flow = FLOW_PROJECT_ADD_CONFIRM
            end
            :tab => _complete_path!(m.project_path_input)
            _ => handle_key!(m.project_path_input, evt)
        end
    elseif flow == FLOW_PROJECT_ADD_CONFIRM
        @match evt.key begin
            :left || :right => begin
                m.flow_modal_selected =
                    m.flow_modal_selected == :cancel ? :confirm : :cancel
            end
            :enter => begin
                m.flow_modal_selected == :confirm ? execute_project_add!(m) :
                (m.config_flow = FLOW_IDLE)
            end
            _ => nothing
        end
    elseif flow == FLOW_PROJECT_ADD_RESULT
        m.config_flow = FLOW_IDLE
    elseif flow == FLOW_PROJECT_REMOVE_CONFIRM
        @match evt.key begin
            :left || :right => begin
                m.flow_modal_selected =
                    m.flow_modal_selected == :cancel ? :confirm : :cancel
            end
            :enter => begin
                m.flow_modal_selected == :confirm ? execute_project_remove!(m) :
                (m.config_flow = FLOW_IDLE)
            end
            _ => nothing
        end
    elseif flow == FLOW_PROJECT_REMOVE_RESULT
        m.config_flow = FLOW_IDLE

    elseif flow == FLOW_TCP_GATE_ADD
        field = m._tcp_gate_field
        n_fields = 4
        if evt.key == :tab
            m._tcp_gate_field = mod1(field + 1, n_fields)
        elseif evt.key == :backtab
            m._tcp_gate_field = mod1(field - 1, n_fields)
        elseif evt.key == :enter && field == n_fields
            _execute_tcp_gate_add!(m)
        elseif evt.key == :enter
            m._tcp_gate_field = mod1(field + 1, n_fields)
        else
            input = (m.tcp_gate_input, m.tcp_gate_name_input, m.tcp_gate_token_input, m.tcp_gate_stream_port_input)[field]
            input !== nothing && handle_key!(input, evt)
        end
    elseif flow == FLOW_TCP_GATE_ADD_RESULT
        m.config_flow = FLOW_IDLE

    elseif flow == FLOW_QDRANT_PREFIX
        if evt.key == :enter
            _execute_qdrant_prefix!(m)
        else
            m.qdrant_prefix_input !== nothing && handle_key!(m.qdrant_prefix_input, evt)
        end
    elseif flow == FLOW_QDRANT_PREFIX_RESULT
        m.config_flow = FLOW_IDLE

    elseif flow == FLOW_PROJECT_EDIT_LAUNCH
        field_keys = [:threads, :gcthreads, :heap_size_hint, :extra_flags]
        active_key = field_keys[m.launch_config_selected]
        active_input = m.launch_config_inputs[active_key]
        @match evt.key begin
            :up => (m.launch_config_selected = max(1, m.launch_config_selected - 1))
            :down => (m.launch_config_selected = min(4, m.launch_config_selected + 1))
            :enter => execute_project_edit_launch!(m)
            _ => begin
                active_input.tick = m.tick
                handle_key!(active_input, evt)
            end
        end
    end
end

# ── Config Flow: Execution ───────────────────────────────────────────────────

"""Get the first API key from global config, or `nothing` if lax/unconfigured."""
function _get_api_key()
    cfg = load_global_config()
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

function execute_project_add!(m::KaimonModel)
    if m._render_mode
        m.flow_message = "(render mode — no files written)"
        m.flow_success = true
        m.config_flow = FLOW_PROJECT_ADD_RESULT
        return
    end
    try
        path = normalize_path(m.onboard_path)
        isdir(path) || error("Directory does not exist: $path")
        isfile(joinpath(path, "Project.toml")) ||
            error("No Project.toml found in $path")

        norm_path = path

        # Check if already in list
        entries = load_projects_config()
        for entry in entries
            entry_norm = normalize_path(entry.project_path)
            if entry_norm == norm_path
                m.flow_message = "Project already in allowed list"
                m.flow_success = false
                m.config_flow = FLOW_PROJECT_ADD_RESULT
                return
            end
        end

        push!(entries, ProjectEntry(norm_path, true))
        save_projects_config(entries)
        m.project_entries = entries
        m.flow_message = "Added $(_short_path(norm_path)) to allowed projects"
        m.flow_success = true
    catch e
        m.flow_message = "Error: $(sprint(showerror, e))"
        m.flow_success = false
    end
    m.config_flow = FLOW_PROJECT_ADD_RESULT
end

function execute_project_remove!(m::KaimonModel)
    if m._render_mode
        m.flow_message = "(render mode — no files written)"
        m.flow_success = true
        m.config_flow = FLOW_PROJECT_REMOVE_RESULT
        return
    end
    try
        idx = m.selected_project
        entries = load_projects_config()
        if idx < 1 || idx > length(entries)
            m.flow_message = "No project selected"
            m.flow_success = false
            m.config_flow = FLOW_PROJECT_REMOVE_RESULT
            return
        end

        removed = entries[idx]
        deleteat!(entries, idx)
        save_projects_config(entries)
        m.project_entries = entries
        m.selected_project = min(m.selected_project, length(entries))
        m.flow_message = "Removed $(_short_path(removed.project_path)) from allowed projects"
        m.flow_success = true
    catch e
        m.flow_message = "Error: $(sprint(showerror, e))"
        m.flow_success = false
    end
    m.config_flow = FLOW_PROJECT_REMOVE_RESULT
end

function execute_project_edit_launch!(m::KaimonModel)
    if m._render_mode
        m.config_flow = FLOW_IDLE
        return
    end
    try
        idx = m.selected_project
        entries = load_projects_config()
        if idx < 1 || idx > length(entries)
            m.config_flow = FLOW_IDLE
            return
        end

        threads = strip(Tachikoma.text(m.launch_config_inputs[:threads]))
        gcthreads = strip(Tachikoma.text(m.launch_config_inputs[:gcthreads]))
        heap = strip(Tachikoma.text(m.launch_config_inputs[:heap_size_hint]))
        extra_raw = strip(Tachikoma.text(m.launch_config_inputs[:extra_flags]))
        extra = isempty(extra_raw) ? String[] : String.(split(extra_raw))

        lc = LaunchConfig(threads, gcthreads, heap, extra)
        old = entries[idx]
        entries[idx] = ProjectEntry(old.project_path, old.enabled, lc)
        save_projects_config(entries)
        m.project_entries = entries
    catch e
        _push_log!(:error, "Failed to save launch config: $(sprint(showerror, e))")
    end
    m.config_flow = FLOW_IDLE
end

function cycle_editor!(m::KaimonModel)
    m._render_mode && return
    idx = findfirst(==(m.editor), EDITOR_OPTIONS)
    next_idx = idx === nothing ? 1 : mod1(idx + 1, length(EDITOR_OPTIONS))
    m.editor = EDITOR_OPTIONS[next_idx]

    # Persist to global config
    cfg = load_global_config()
    if cfg !== nothing
        new_cfg = SecurityConfig(
            cfg.mode, cfg.api_keys, cfg.allowed_ips, cfg.port,
            cfg.created_at, m.editor,
        )
        save_global_config(new_cfg)
    end
    _push_log!(:info, "Editor set to $(m.editor)")
end

function toggle_gate_mirror_repl!(m::KaimonModel)
    m._render_mode && return
    new_value = !m.gate_mirror_repl
    m.gate_mirror_repl = set_gate_mirror_repl_preference!(new_value)

    session_prefs = load_session_prefs()
    applied = 0
    total = 0
    if m.conn_mgr !== nothing
        for conn in connected_sessions(m.conn_mgr)
            total += 1
            # Per-session override takes precedence over global toggle
            override = resolve_session_pref(session_prefs, conn.project_path, :mirror_repl)
            target = override !== nothing ? override : m.gate_mirror_repl
            set_mirror_repl!(conn, target) && (applied += 1)
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

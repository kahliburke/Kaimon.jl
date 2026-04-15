# ── View ──────────────────────────────────────────────────────────────────────

# ── Tab color generation from theme ──────────────────────────────────────────

function _rgb_to_hsl(r::Float64, g::Float64, b::Float64)
    cmax = max(r, g, b)
    cmin = min(r, g, b)
    delta = cmax - cmin
    l = (cmax + cmin) / 2.0
    if delta < 1e-6
        return (0.0, 0.0, l)
    end
    s = delta / (1.0 - abs(2.0 * l - 1.0))
    h = if cmax == r
        60.0 * mod((g - b) / delta, 6.0)
    elseif cmax == g
        60.0 * ((b - r) / delta + 2.0)
    else
        60.0 * ((r - g) / delta + 4.0)
    end
    (h, s, l)
end

function _hsl_to_rgb(h::Float64, s::Float64, l::Float64)
    c = (1.0 - abs(2.0 * l - 1.0)) * s
    x = c * (1.0 - abs(mod(h / 60.0, 2.0) - 1.0))
    m = l - c / 2.0
    r1, g1, b1 = if h < 60; (c, x, 0.0)
    elseif h < 120; (x, c, 0.0)
    elseif h < 180; (0.0, c, x)
    elseif h < 240; (0.0, x, c)
    elseif h < 300; (x, 0.0, c)
    else; (c, 0.0, x)
    end
    (r1 + m, g1 + m, b1 + m)
end

"""Generate 9 distinct tab colors by rotating hue from the theme's accent color."""
function _generate_tab_colors(th)
    accent = to_rgb(th.accent)
    r, g, b = Float64(accent.r) / 255, Float64(accent.g) / 255, Float64(accent.b) / 255
    h, s, l = _rgb_to_hsl(r, g, b)
    # Keep saturation and lightness, rotate hue evenly across 9 tabs
    colors = Style[]
    for i in 0:8
        hi = mod(h + i * 40.0, 360.0)  # 40° apart = good separation
        ri, gi, bi = _hsl_to_rgb(hi, s, clamp(l, 0.4, 0.7))
        push!(colors, Style(fg=ColorRGB(
            round(UInt8, ri * 255),
            round(UInt8, gi * 255),
            round(UInt8, bi * 255),
        )))
    end
    colors
end

"""Write a sequence of (text, style) pairs at (x, y), advancing x after each."""
function _write_spans!(buf::Buffer, x::Int, y::Int, parts)
    cx = x
    for (text, style) in parts
        set_string!(buf, cx, y, text, style)
        cx += length(text)
    end
end

"""
    file_link_style(path::String; line::Int=0) -> Style

Return accent/underline style with an OSC 8 hyperlink to the configured editor,
or dim style if no URL can be constructed.
"""
function file_link_style(path::String; line::Int=0)
    url = editor_file_url(path; line=line)
    if isempty(url)
        return tstyle(:text_dim, italic = true)
    else
        return tstyle(:accent, italic = true, underline = true, hyperlink = url)
    end
end

function Tachikoma.view(m::KaimonModel, f::Frame)
    m.tick += 1
    _advance_ecg!(m)
    _check_code_stale!(m)
    buf = f.buffer

    # Shutdown overlay — render one frame showing the message, then quit
    if m.shutting_down
        _dim_area!(buf, f.area)
        w = 36
        h = 5
        rect = center(f.area, w, h)
        block = Block(
            title = "Shutting Down",
            border_style = tstyle(:warning, bold = true),
            title_style = tstyle(:warning, bold = true),
            box = BOX_HEAVY,
        )
        inner = render(block, rect, buf)
        if inner.width >= 4
            for row = inner.y:bottom(inner)
                for col = inner.x:right(inner)
                    set_char!(buf, col, row, ' ', Style(bg=Tachikoma.theme().bg))
                end
            end
            si = mod1(m.tick ÷ 2, length(SPINNER_BRAILLE))
            set_string!(
                buf,
                inner.x + 2,
                inner.y + 1,
                "$(SPINNER_BRAILLE[si]) Stopping server...",
                tstyle(:warning),
            )
        end
        m.quit = true
        return
    end

    # Drain captured log messages into the model each frame
    _drain_log_buffer!(m.server_log)

    # Drain activity events (tool calls from MCPServer hook)
    _drain_activity_buffer!(m.activity_feed)

    # Drain tool call results for Activity tab inspection
    n_new_calls = _drain_tool_results!(m.tool_results)
    m.total_tool_calls += n_new_calls

    # Sync health gauge timestamps from thread-safe Refs
    if _LAST_TOOL_SUCCESS[] > m.last_tool_success
        m.last_tool_success = _LAST_TOOL_SUCCESS[]
    end
    if _LAST_TOOL_ERROR[] > m.last_tool_error
        m.last_tool_error = _LAST_TOOL_ERROR[]
    end

    # Drain in-flight tool call events — track selected ID to detect index shifts
    _prev_sel_id =
        if m.selected_inflight > 0 && m.selected_inflight <= length(m.inflight_calls)
            m.inflight_calls[m.selected_inflight].id
        else
            -1
        end
    _drain_inflight_buffer!(m.inflight_calls)
    # Fix selected_inflight if deleteat! shifted indices under us
    if _prev_sel_id > 0
        new_idx = findfirst(x -> x.id == _prev_sel_id, m.inflight_calls)
        m.selected_inflight = new_idx === nothing ? 0 : new_idx
    end

    # Drain streaming REPL output from gate SUB sockets
    if m.conn_mgr !== nothing && !m._render_mode
        for msg in drain_stream_messages!(m.conn_mgr)
            if msg.channel == "files_changed"
                m._reindex_pending[msg.data] = time()
                if !haskey(m._reindex_first_seen, msg.data)
                    m._reindex_first_seen[msg.data] = time()
                end
            elseif msg.channel in ("eval_complete", "eval_error")
                # Async eval lifecycle messages — log but don't push to activity feed
                # (the tool handler already pushes tool_start/tool_done events)
                status = msg.channel == "eval_complete" ? "completed" : "error"
                _push_log!(:info, "Gate eval $status ($(msg.session_name))")
            elseif msg.channel == "breakpoint_hit"
                Base.invokelatest(_handle_breakpoint_hit!, m, msg)
            elseif msg.channel == "breakpoint_resumed"
                Base.invokelatest(_handle_breakpoint_resumed!, m)
            elseif msg.channel == "debug_eval"
                Base.invokelatest(_handle_debug_eval_pub!, m, msg)
            else
                kind = msg.channel == "stderr" ? :stderr : :stdout
                push!(
                    m.activity_feed,
                    ActivityEvent(now(), kind, "", msg.session_name, msg.data, true),
                )
            end
        end
        while length(m.activity_feed) > 2000
            popfirst!(m.activity_feed)
        end
        _process_pending_reindexes!(m)

        # Poll for agent debug continue/abort consent requests
        Base.invokelatest(_poll_debug_consent!, m)

        # Auto-index gate projects on first connect
        for conn in connected_sessions(m.conn_mgr)
            sid = conn.session_id
            if !isempty(sid) &&
               sid ∉ m._auto_indexed_sessions &&
               !isempty(conn.project_path)
                push!(m._auto_indexed_sessions, sid)
                _auto_index_on_connect!(conn.project_path, m._render_mode)
            end
        end
    end

    # Reap stale MCP agent sessions every ~30s.
    # Sessions with no activity for 5 minutes are closed and removed.
    if time() - m._last_reap_time > 30.0
        _reap_stale_sessions!(300.0)  # 5 min threshold
        m._last_reap_time = time()
    end

    # Monitor managed extensions and sessions (check health, auto-restart crashed ones)
    if !m._render_mode && m.tick % 30 == 0  # ~1 Hz at 30 fps
        _monitor_extensions!(m.conn_mgr)
        _monitor_managed_sessions!(m.conn_mgr)
    end

    # Deferred server start — kick off on first frame so the TUI is already
    # rendering and can report startup status in the Server tab.
    if !m.server_started && !m._render_mode
        m.server_started = true

        # Initialize analytics database before server starts
        _push_log!(:info, "Initializing database...")
        try
            db_path = joinpath(kaimon_cache_dir(), "kaimon.db")
            Database.init_db!(db_path)
            m.db_initialized = true
            _push_log!(:info, "Database ready at $db_path")
        catch e
            _push_log!(:warning, "Database init failed: $(sprint(showerror, e))")
        end

        _push_log!(:info, "Starting MCP server on port $(m.server_port)...")
        let port = m.server_port
            spawn_task!(m._task_queue, :mcp_server_started) do
                try
                    security_config = load_global_config()
                    tools = collect_tools()
                    server = start_mcp_server(
                        tools,
                        port;
                        verbose = false,
                        security_config = security_config,
                    )
                    (success=true, server=server, tools=tools, port=port)
                catch e
                    (success=false, error_msg=sprint(showerror, e))
                end
            end
        end
    end

    # Track tool call rate for sparkline (calls per frame, last 120 frames ≈ 2 min)
    push!(m.tool_call_history, Float64(n_new_calls))
    length(m.tool_call_history) > 120 && popfirst!(m.tool_call_history)

    # ── Layout: outer frame → tab bar | content | status bar ──
    # Kanji style reflects system state — breathes when active, red on errors.
    n_conns_k = m.conn_mgr !== nothing ? length(connected_sessions(m.conn_mgr)) : 0
    has_inflight = !isempty(m.inflight_calls)
    has_error = m.debug_state == :paused
    kanji_style = if has_error
        Style(
            fg = color_lerp(
                ColorRGB(0xcc, 0x22, 0x22),
                ColorRGB(0xff, 0x55, 0x44),
                breathe(m.tick; period = 30),
            ),
            bold = true,
        )
    elseif has_inflight
        Style(
            fg = color_lerp(
                ColorRGB(0x44, 0x88, 0xcc),
                ColorRGB(0x66, 0xcc, 0xff),
                breathe(m.tick; period = 40),
            ),
            bold = true,
        )
    elseif n_conns_k > 0
        Style(
            fg = color_lerp(
                ColorRGB(0x33, 0x88, 0x55),
                ColorRGB(0x55, 0xbb, 0x77),
                breathe(m.tick; period = 90),
            ),
            bold = true,
        )
    else
        tstyle(:title, bold = true)
    end

    title_style = if m._code_stale
        Style(
            fg = color_lerp(
                ColorRGB(0x99, 0x44, 0xdd),  # deep purple
                ColorRGB(0xcc, 0x77, 0xff),  # light purple
                breathe(m.tick; period = 45),
            ),
            bold = true,
        )
    else
        tstyle(:title, bold = true)
    end

    outer = Block(
        title = "Kaimon",
        border_style = tstyle(:border),
        title_style = title_style,
        title_right = "開門",
        title_right_style = kanji_style,
        title_padding = 2,
    )
    main = render(outer, f.area, buf)
    main.width < 4 && return

    rows = tsplit(Layout(Vertical, [Fixed(tab_height(m.tab_bar.tab_style.decoration)), Fill(), Fixed(1)]), main)
    length(rows) < 3 && return
    tab_area = rows[1]
    content_area = rows[2]
    status_area = rows[3]

    # ── Tab bar ──
    # Dynamic label styles (Debug tab changes color when paused)
    debug_style = m.debug_state == :paused ? tstyle(:error, bold = true) : tstyle(:text)
    m.tab_bar.labels[7] = [Span("7", tstyle(:warning)), Span(" Debug", debug_style)]

    # Sync tab bar active/inactive styles with theme (in case theme changed)
    th = Tachikoma.theme()
    th_accent = th.accent
    if m._tab_theme_accent != th_accent
        m._tab_theme_accent = th_accent
        ts = m.tab_bar.tab_style
        m.tab_bar.tab_style = TabBarStyle(
            decoration = ts.decoration,
            active = tstyle(:accent, bold=true),
            inactive = tstyle(:text_dim),
            separator = ts.separator,
            overflow_char = ts.overflow_char,
            overflow_style = ts.overflow_style,
            tab_colors = ts.tab_colors,
        )
    end

    render(m.tab_bar, tab_area, buf)

    # ── Drain cross-thread buffers every frame (regardless of active tab) ──
    _drain_stress_output!(m)
    _drain_test_updates!(m.test_runs)

    # ── Content by tab ──
    @match m.tab_bar.active begin
        $TAB_SERVER => view_server(m, content_area, f)
        $TAB_SESSIONS => view_sessions(m, content_area, buf)
        $TAB_ACTIVITY => begin
            view_activity(m, content_area, buf)
            m.activity_filter_open && _view_activity_filter(m, content_area, buf)
        end
        $TAB_SEARCH => view_search(m, content_area, buf)
        $TAB_TESTS => begin
            # Follow mode: always snap to newest run
            if (m.test_follow || m.selected_test_run == 0) && !isempty(m.test_runs)
                m.selected_test_run = length(m.test_runs)
            end
            view_tests(m, content_area, buf)
        end
        $TAB_CONFIG => view_config(m, content_area, buf)
        $TAB_DEBUG => Base.invokelatest(view_debug, m, content_area, buf)
        $TAB_EXTENSIONS => view_extensions(m, content_area, buf)
        $TAB_ADVANCED => view_advanced(m, content_area, buf)
        _ => nothing
    end

    # ── Status bar ──
    n_sessions, n_exts = if m.conn_mgr !== nothing
        conns = connected_sessions(m.conn_mgr)
        ns = count(c -> c.spawned_by != "extension", conns)
        ne = count(c -> c.spawned_by == "extension", conns)
        (ns, ne)
    else
        (0, 0)
    end
    n_agents = lock(STANDALONE_SESSIONS_LOCK) do
        count(s -> s.state == Session.INITIALIZED, values(STANDALONE_SESSIONS))
    end
    uptime = format_uptime(time() - m.start_time)

    si = mod1(m.tick ÷ 3, length(SPINNER_BRAILLE))
    server_status = if m.server_running
        "localhost:$(m.server_port)"
    elseif !m.server_started
        "starting…"
    else
        "stopped"
    end

    render(
        StatusBar(
            left = [
                Span(" $(SPINNER_BRAILLE[si]) ", tstyle(:accent)),
                Span(
                    "Server: $server_status",
                    tstyle(
                        m.server_running ? :success : m.server_started ? :error : :warning,
                    ),
                ),
                Span("  $(DOT) ", tstyle(:border)),
                Span("$(n_sessions) sessions", tstyle(:primary)),
                Span("  $(DOT) ", tstyle(:border)),
                Span("$(n_exts) exts", tstyle(:primary)),
                Span("  $(DOT) ", tstyle(:border)),
                Span("$(n_agents) agents", tstyle(:secondary)),
            ],
            right = [
                Span("⏱ $(uptime) ", tstyle(:text_dim)),
                Span(" tab:focus [q]uit ", tstyle(:text_dim)),
            ],
        ),
        status_area,
        buf,
    )

    # Backtrace viewer overlay (full-screen ScrollPane with trace)
    if m.backtrace_viewer !== nothing
        _dim_area!(buf, f.area)
        margin = 2
        overlay = Rect(
            f.area.x + margin,
            f.area.y + margin,
            f.area.width - 2 * margin,
            f.area.height - 2 * margin,
        )
        render(m.backtrace_viewer, overlay, buf)
    end

    # Backtrace modal (collecting or timeout)
    if m.backtrace_modal !== nothing
        m.backtrace_modal.tick = m.tick
        render(m.backtrace_modal, f.area, buf)
    end

    # Quit confirmation modal
    if m.quit_confirm
        if m.quit_confirm_modal === nothing
            m.quit_confirm_modal = Modal(
                title = "Quit Kaimon?",
                message = "This will stop the MCP server\nand disconnect all sessions.",
                confirm_label = "Quit",
                cancel_label = "Cancel",
                selected = :confirm,
            )
        end
        m.quit_confirm_modal.tick = m.tick
        render(m.quit_confirm_modal, f.area, buf)
    end

    # Capture text snapshot every ~1s (every 30 frames at 30fps) for the screenshot tool
    if m.tick % 30 == 0
        try
            TUI_LAST_FRAME[] = buffer_to_text(buf, f.area)
        catch
        end
    end
end

# ── Server Tab ────────────────────────────────────────────────────────────────

function view_server(m::KaimonModel, area::Rect, f::Frame)
    buf = f.buffer
    rows = split_layout(m.server_layout, area)
    length(rows) < 2 && return
    render_resize_handles!(buf, m.server_layout)

    # ── Top: Server status panel ──
    status_block = Block(
        title = "Server Status",
        border_style = _pane_border(m, TAB_SERVER, 1),
        title_style = _pane_title(m, TAB_SERVER, 1),
    )
    si = render(status_block, rows[1], buf)
    if si.width >= 4
        y = si.y
        x = si.x + 1
        sep = " · "
        dim = tstyle(:text_dim)
        txt = tstyle(:text)

        status_icon = m.server_running ? "●" : m.server_started ? "○" : "◌"
        status_text = m.server_running ? "running" : m.server_started ? "stopped" : "starting…"
        status_style = m.server_running ? tstyle(:success) : tstyle(:error)
        n_conns = m.conn_mgr !== nothing ? count(c -> c.spawned_by != "extension", connected_sessions(m.conn_mgr)) : 0

        # Row 1: status + port + uptime
        _write_spans!(buf, x, y, [
            (status_icon * " ", status_style),
            ("MCP Server", txt),
            (sep, dim),
            (":", dim), (string(m.server_port), txt),
            (sep, dim),
            (status_text, status_style),
            (sep, dim),
            ("⏱ ", dim), (format_uptime(time() - m.start_time), txt),
        ])
        y += 1

        # Row 2: gate + tools
        _write_spans!(buf, x, y, [
            ("Gate: ", dim), ("$n_conns sessions", txt),
            (sep, dim),
            ("Tool Calls: ", dim), (string(m.total_tool_calls), txt),
        ])
    end

    # ── Bottom: Server log (ScrollPane) ──
    wrap_hint = m.log_word_wrap ? "wrap:on" : "wrap:off"
    _ensure_log_pane!(m)
    pane = m.log_pane::ScrollPane
    follow_hint = pane.following ? "[F]ollow:on" : "[F]ollow:off"
    pane.block = Block(
        title = "Server Log ($(length(m.server_log))) [$wrap_hint] $follow_hint",
        border_style = _pane_border(m, TAB_SERVER, 2),
        title_style = _pane_title(m, TAB_SERVER, 2),
    )
    m._log_pane_width = rows[2].width - 2   # -2 for border
    _sync_log_pane!(m, m._log_pane_width)
    render(pane, rows[2], buf)
end

# ── Client Status Detection ──────────────────────────────────────────────────

"""Check if any of the given files contain "kaimon"."""
function _detect_in_files(paths::String...)
    for p in paths
        isfile(p) || continue
        try
            occursin("kaimon", read(p, String)) && return true
        catch
        end
    end
    return false
end

function _dict_has_julia_repl_server(x)::Bool
    if x isa AbstractDict
        if haskey(x, "mcpServers")
            servers = x["mcpServers"]
            if servers isa AbstractDict
                for k in keys(servers)
                    occursin("kaimon", lowercase(string(k))) && return true
                end
            end
        end
        for v in values(x)
            _dict_has_julia_repl_server(v) && return true
        end
    elseif x isa AbstractVector
        for v in x
            _dict_has_julia_repl_server(v) && return true
        end
    end
    return false
end

function _detect_claude_configured()::Bool
    # Check CLI first (most authoritative).
    if Sys.which("claude") !== nothing
        try
            out = read(pipeline(`claude mcp list`; stderr = devnull), String)
            for ln in split(out, '\n')
                s = strip(lowercase(ln))
                startswith(s, "kaimon:") && return true
            end
            return false
        catch
            # Fall through to file checks if CLI invocation fails.
        end
    end

    # Fallback: file-based detection.
    paths = (
        joinpath(homedir(), ".claude", "settings.json"),
        joinpath(homedir(), ".claude", "settings.local.json"),
        joinpath(pwd(), ".mcp.json"),
        joinpath(pwd(), ".claude", "settings.local.json"),
    )
    for p in paths
        isfile(p) || continue
        try
            cfg = JSON.parsefile(p)
            _dict_has_julia_repl_server(cfg) && return true
        catch
        end
        try
            occursin("kaimon", read(p, String)) && return true
        catch
        end
    end
    return false
end

# Client detection runs as independent async tasks via Tachikoma TaskQueue.
# Each check spawns separately so fast file checks return immediately
# while slower CLI checks (e.g. `claude mcp list`) don't block anything.

function _refresh_client_status_async!(m::KaimonModel)
    m._render_mode && return
    q = m._task_queue

    # Remove any stale entries that no longer correspond to a tracked client
    filter!(p -> p.first in CLIENT_LABELS, m.client_statuses)

    # Claude Code — may shell out to `claude mcp list`, so gets its own task
    spawn_task!(q, :client_status) do
        "Claude Code" => _detect_claude_configured()
    end

    # Gemini
    spawn_task!(q, :client_status) do
        "Gemini CLI" => _detect_in_files(
            joinpath(homedir(), ".gemini", "settings.json"),
            joinpath(pwd(), ".gemini", "settings.json"),
        )
    end

    # Antigravity
    spawn_task!(q, :client_status) do
        "Antigravity" => _detect_in_files(
            joinpath(homedir(), ".gemini", "antigravity", "mcp_config.json"),
        )
    end

    # Codex
    spawn_task!(q, :client_status) do
        "OpenAI Codex" => _detect_in_files(joinpath(homedir(), ".codex", "config.toml"))
    end

    # Copilot
    spawn_task!(q, :client_status) do
        "GitHub Copilot" =>
            _detect_in_files(joinpath(homedir(), ".copilot", "mcp-config.json"))
    end

    # VS Code
    vscode_user_dir = if Sys.isapple()
        joinpath(homedir(), "Library", "Application Support", "Code", "User")
    elseif Sys.iswindows()
        joinpath(get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")), "Code", "User")
    else
        joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "Code", "User")
    end
    spawn_task!(q, :client_status) do
        "VS Code" => _detect_in_files(
            joinpath(vscode_user_dir, "mcp.json"),
            joinpath(pwd(), ".vscode", "mcp.json"),
        )
    end

    # KiloCode
    spawn_task!(q, :client_status) do
        "KiloCode" => _detect_in_files(joinpath(_kilo_settings_dir(), "mcp_settings.json"))
    end

    # Cursor
    spawn_task!(q, :client_status) do
        "Cursor" => _detect_in_files(
            joinpath(homedir(), ".cursor", "mcp.json"),
        )
    end

    # OpenCode
    spawn_task!(q, :client_status) do
        "OpenCode" => _detect_in_files(
            joinpath(homedir(), ".config", "opencode", "opencode.json"),
        )
    end

end

function _detect_startup_jl_configured()::Bool
    startup_file = joinpath(homedir(), ".julia", "config", "startup.jl")
    isfile(startup_file) || return false
    try
        occursin(_STARTUP_MARKER, read(startup_file, String))
    catch
        false
    end
end

# ── Helpers ───────────────────────────────────────────────────────────────────

function format_uptime(seconds::Float64)
    s = round(Int, seconds)
    if s < 60
        return "$(s)s"
    elseif s < 3600
        return "$(s ÷ 60)m $(s % 60)s"
    else
        h = s ÷ 3600
        m = (s % 3600) ÷ 60
        return "$(h)h $(m)m"
    end
end

function _complete_path!(input::TextInput)
    partial = expanduser(Tachikoma.text(input))
    isempty(partial) && return

    dir, prefix = if isdir(partial) && endswith(partial, '/')
        (partial, "")
    else
        (dirname(partial), basename(partial))
    end

    isdir(dir) || return
    entries = try
        filter(readdir(dir)) do name
            startswith(name, prefix) && isdir(joinpath(dir, name))
        end
    catch
        return
    end

    if length(entries) == 1
        completed = joinpath(dir, entries[1]) * "/"
        # Collapse home dir back to ~ if original used it
        if startswith(Tachikoma.text(input), "~")
            completed = replace(completed, homedir() => "~"; count = 1)
        end
        Tachikoma.set_text!(input, completed)
    elseif length(entries) > 1
        # Complete common prefix
        common = entries[1]
        for e in entries[2:end]
            i = 0
            for (a, b) in zip(common, e)
                a == b || break
                i += 1
            end
            common = common[1:i]
        end
        if length(common) > length(prefix)
            completed = joinpath(dir, common)
            if startswith(Tachikoma.text(input), "~")
                completed = replace(completed, homedir() => "~"; count = 1)
            end
            Tachikoma.set_text!(input, completed)
        end
    end
end

"""
    _complete_relative_dir!(input::TextInput, project_root::String)

Tab-complete directory names relative to `project_root` within a comma-separated
TextInput. Completes the last entry (after the last comma). Only suggests
directories, not files.
"""
function _complete_relative_dir!(input::TextInput, project_root::String)
    isempty(project_root) && return
    text = Tachikoma.text(input)

    # Find the last comma-separated entry to complete
    last_comma = findlast(',', text)
    prefix_before = last_comma !== nothing ? text[1:last_comma] * " " : ""
    partial = last_comma !== nothing ? strip(text[last_comma+1:end]) : strip(text)

    # Resolve relative to project root
    if isempty(partial)
        search_dir = project_root
        search_prefix = ""
    else
        # Could be a partial path like "src/co" → dir="src", prefix="co"
        full = joinpath(project_root, partial)
        if isdir(full)
            search_dir = full
            search_prefix = ""
            # Add trailing / to partial for display
            partial = endswith(partial, '/') ? partial : partial * "/"
        else
            search_dir = joinpath(project_root, dirname(partial))
            search_prefix = basename(partial)
        end
    end

    isdir(search_dir) || return

    entries = try
        filter(readdir(search_dir)) do name
            startswith(name, search_prefix) &&
            !startswith(name, ".") &&
            isdir(joinpath(search_dir, name))
        end
    catch
        return
    end

    if length(entries) == 1
        rel = if isempty(partial) || endswith(partial, '/')
            partial * entries[1]
        else
            joinpath(dirname(partial), entries[1])
        end
        Tachikoma.set_text!(input, prefix_before * rel)
    elseif length(entries) > 1
        # Complete common prefix
        common = entries[1]
        for e in entries[2:end]
            i = 0
            for (a, b) in zip(common, e)
                a == b || break
                i += 1
            end
            common = common[1:i]
        end
        if length(common) > length(search_prefix)
            rel = if isempty(partial) || endswith(partial, '/')
                partial * common
            else
                joinpath(dirname(partial), common)
            end
            Tachikoma.set_text!(input, prefix_before * rel)
        end
    end
end

"""KiloCode settings directory inside VS Code's globalStorage."""
function _kilo_settings_dir()
    gs = if Sys.isapple()
        joinpath(homedir(), "Library", "Application Support", "Code", "User", "globalStorage")
    elseif Sys.iswindows()
        joinpath(
            get(ENV, "APPDATA", joinpath(homedir(), "AppData", "Roaming")),
            "Code",
            "User",
            "globalStorage",
        )
    else
        joinpath(
            get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")),
            "Code",
            "User",
            "globalStorage",
        )
    end
    joinpath(gs, "kilocode.kilo-code", "settings")
end

function _short_path(path::AbstractString)
    home = homedir()
    if startswith(path, home)
        return "~" * path[length(home)+1:end]
    end
    return path
end

function _time_ago(dt::DateTime)
    diff = now() - dt
    secs = round(Int, Dates.value(diff) / 1000)
    if secs < 60
        return "$(secs)s ago"
    elseif secs < 3600
        return "$(secs ÷ 60)m ago"
    else
        return "$(secs ÷ 3600)h $(secs % 3600 ÷ 60)m ago"
    end
end

# ── Session Reaping ───────────────────────────────────────────────────────────

"""Remove MCP agent sessions that have been idle longer than `max_idle_secs`."""
function _reap_stale_sessions!(max_idle_secs::Float64)
    cutoff = now() - Dates.Second(round(Int, max_idle_secs))
    reaped = lock(STANDALONE_SESSIONS_LOCK) do
        stale = String[]
        for (sid, sess) in STANDALONE_SESSIONS
            if sess.last_activity < cutoff
                push!(stale, sid)
            end
        end
        for sid in stale
            try
                close_session!(STANDALONE_SESSIONS[sid])
            catch
            end
            delete!(STANDALONE_SESSIONS, sid)
        end
        stale
    end
    # Also prune the persistence file so it doesn't grow unbounded
    if !isempty(reaped)
        try
            persisted = load_persisted_sessions()
            for sid in reaped
                delete!(persisted, sid)
            end
            save_persisted_sessions(persisted)
        catch
        end
    end
end


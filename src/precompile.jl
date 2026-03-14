# ── Precompilation workload ───────────────────────────────────────────────────
# Renders each TUI tab into a headless buffer during precompilation so that
# first-frame latency is eliminated at runtime.  Uses _render_mode to skip
# all real I/O (network, filesystem, ZMQ, etc.).

using PrecompileTools

@compile_workload begin
    # Headless buffer (typical terminal size)
    rect = Rect(1, 1, 120, 40)
    buf = Buffer(rect)
    frame = Frame(buf, rect, GraphicsRegion[], PixelSnapshot[])

    # Minimal render-mode model with mock data to exercise rendering paths
    now_dt = Dates.now()
    mock_logs = [
        ServerLogEntry(now_dt, :info, "Server started on port 2828"),
        ServerLogEntry(now_dt, :warn, "Test warning message"),
        ServerLogEntry(now_dt, :error, "Test error message"),
    ]
    mock_activity = [
        ActivityEvent(now_dt, :tool_start, "ex", "main", "testing", false),
        ActivityEvent(now_dt, :tool_done, "ex", "main", "12ms", false),
    ]
    mock_tool_history = Float64[0.0, 1.0, 2.0, 1.0, 0.0, 3.0, 2.0, 1.0]

    m = KaimonModel(
        _render_mode = true,
        server_running = true,
        server_started = true,
        server_port = 2828,
        start_time = time(),
        server_log = mock_logs,
        activity_feed = mock_activity,
        tool_call_history = mock_tool_history,
        total_tool_calls = 42,
    )

    # Render each tab to compile all view_* methods
    for tab in 1:9
        m.active_tab = tab
        buf = Buffer(rect)
        frame = Frame(buf, rect, GraphicsRegion[], PixelSnapshot[])
        try
            Tachikoma.view(m, frame)
        catch
        end
    end

    # Compile update! dispatch for common event types
    for c in ('j', 'k', '1', '2', '\t')
        try
            Tachikoma.update!(m, KeyEvent(c))
        catch
        end
    end
    for sym in (:up, :down, :enter, :escape)
        try
            Tachikoma.update!(m, KeyEvent(sym))
        catch
        end
    end
end

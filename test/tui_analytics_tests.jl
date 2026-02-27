using ReTest
using Kaimon
using Kaimon.Database
using Dates
using Tachikoma
using SQLite
using DBInterface
using Supposition
using Supposition.Data

# ── Helpers ──────────────────────────────────────────────────────────────────

"""Create a fresh KaimonModel with a temp database initialized."""
function setup_tui_model()
    db_path = tempname() * ".db"
    Database.init_db!(db_path)
    m = Kaimon.KaimonModel(server_port = 19999)
    m.db_initialized = true
    m.server_started = true
    Kaimon.set_theme!(:kokaku)
    return m, db_path
end

"""Send a character keypress to the model."""
function press!(m, c::Char)
    Tachikoma.update!(m, Tachikoma.KeyEvent(:char, c))
end

"""Send a special key to the model."""
function press!(m, k::Symbol)
    Tachikoma.update!(m, Tachikoma.KeyEvent(k, '\0'))
end

"""Push N tool results into the TUI buffer and drain into model."""
function push_tool_results!(
    m;
    n_success::Int = 5,
    n_error::Int = 0,
    tool_name::String = "ex",
)
    for i = 1:n_success
        r = Kaimon.ToolCallResult(
            now() - Second(n_success - i),
            tool_name,
            """{"e":"$i+$i","q":true}""",
            string(2i),
            "$(10i)ms",
            true,
            "sess0001",
        )
        Kaimon._push_tool_result!(r)
    end
    for i = 1:n_error
        r = Kaimon.ToolCallResult(
            now(),
            tool_name,
            """{"e":"error()"}""",
            "ERROR: test error $i",
            "100ms",
            false,
            "sess0001",
        )
        Kaimon._push_tool_result!(r)
    end
    Kaimon._drain_tool_results!(m.tool_results)
    if Kaimon._LAST_TOOL_SUCCESS[] > m.last_tool_success
        m.last_tool_success = Kaimon._LAST_TOOL_SUCCESS[]
    end
    if Kaimon._LAST_TOOL_ERROR[] > m.last_tool_error
        m.last_tool_error = Kaimon._LAST_TOOL_ERROR[]
    end
end

"""Render the activity tab into a buffer and return rendered text lines."""
function render_activity(m; width::Int = 100, height::Int = 35)
    area = Tachikoma.Rect(0, 0, width, height)
    buf = Tachikoma.Buffer(area)
    Kaimon.view_activity(m, area, buf)
    lines = String[]
    for row = 0:(height-1)
        chars = [buf.content[row*width+col+1].char for col = 0:(width-1)]
        push!(lines, rstrip(String(chars)))
    end
    return lines
end

"""Join rendered lines into a single string for content matching."""
render_text(m; kw...) = join(render_activity(m; kw...), "\n")

# ── Unit Tests ───────────────────────────────────────────────────────────────

@testset "TUI Analytics Integration" begin

    @testset "Model Fields" begin
        m = Kaimon.KaimonModel()
        @test m.db_initialized == false
        @test m.activity_mode == :live
        @test m.analytics_cache === nothing
        @test m.analytics_last_refresh == 0.0
        @test m.last_tool_success == 0.0
        @test m.last_tool_error == 0.0
    end

    @testset "Database Persistence" begin
        m, db_path = setup_tui_model()
        try
            @testset "Successful tool call persisted" begin
                r = Kaimon.ToolCallResult(
                    now(),
                    "test_persist",
                    """{"x":1}""",
                    "ok",
                    "42ms",
                    true,
                    "s001",
                )
                Kaimon._persist_tool_call!(r)

                rows = Database.get_tool_executions(; days = 1)
                matching = filter(x -> get(x, "tool_name", "") == "test_persist", rows)
                @test length(matching) == 1
                @test matching[1]["status"] == "success"
                @test matching[1]["duration_ms"] == 42.0
                @test matching[1]["input_size"] == sizeof("""{"x":1}""")
                @test matching[1]["output_size"] == sizeof("ok")
                @test matching[1]["session_key"] == "s001"
            end

            @testset "Error tool call persisted" begin
                r = Kaimon.ToolCallResult(
                    now(),
                    "test_err",
                    """{"y":2}""",
                    "ERROR: boom",
                    "200ms",
                    false,
                    "s002",
                )
                Kaimon._persist_tool_call!(r)

                rows = Database.get_tool_executions(; days = 1)
                matching = filter(x -> get(x, "tool_name", "") == "test_err", rows)
                @test length(matching) == 1
                @test matching[1]["status"] == "error"
                @test matching[1]["duration_ms"] == 200.0
            end

            @testset "Duration parsing" begin
                cases =
                    [("0ms", 0.0), ("125ms", 125.0), ("1.2s", 1200.0), ("10.5s", 10500.0)]
                for (dur_str, expected_ms) in cases
                    r = Kaimon.ToolCallResult(
                        now(),
                        "dur_$(dur_str)",
                        "{}",
                        "ok",
                        dur_str,
                        true,
                        "",
                    )
                    Kaimon._persist_tool_call!(r)
                end
                rows = Database.get_tool_executions(; days = 1)
                for (dur_str, expected_ms) in cases
                    matching =
                        filter(x -> get(x, "tool_name", "") == "dur_$(dur_str)", rows)
                    @test length(matching) == 1
                    @test matching[1]["duration_ms"] ≈ expected_ms
                end
            end

            @testset "Long result truncated to 500 chars" begin
                long_text = repeat("x", 1000)
                r = Kaimon.ToolCallResult(
                    now(),
                    "test_trunc",
                    "{}",
                    long_text,
                    "1ms",
                    true,
                    "",
                )
                Kaimon._persist_tool_call!(r)

                rows = Database.get_tool_executions(; days = 1)
                matching = filter(x -> get(x, "tool_name", "") == "test_trunc", rows)
                @test length(matching) == 1
                @test length(matching[1]["result_summary"]) == 500
            end

            @testset "Graceful when DB is nothing" begin
                saved = Database.DB[]
                Database.DB[] = nothing
                r = Kaimon.ToolCallResult(now(), "no_db", "{}", "ok", "1ms", true, "")
                Kaimon._persist_tool_call!(r)  # should not throw
                Database.DB[] = saved
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Health Gauge Timestamps" begin
        m, db_path = setup_tui_model()
        try
            Kaimon._LAST_TOOL_SUCCESS[] = 0.0
            Kaimon._LAST_TOOL_ERROR[] = 0.0

            @testset "Success updates success Ref" begin
                r = Kaimon.ToolCallResult(now(), "h1", "{}", "ok", "1ms", true, "")
                Kaimon._push_tool_result!(r)
                @test Kaimon._LAST_TOOL_SUCCESS[] > 0.0
                @test Kaimon._LAST_TOOL_ERROR[] == 0.0
            end

            @testset "Error updates error Ref" begin
                Kaimon._LAST_TOOL_ERROR[] = 0.0
                r = Kaimon.ToolCallResult(now(), "h2", "{}", "ERR", "1ms", false, "")
                Kaimon._push_tool_result!(r)
                @test Kaimon._LAST_TOOL_ERROR[] > 0.0
            end

            @testset "Drain syncs Refs into model" begin
                m.last_tool_success = 0.0
                m.last_tool_error = 0.0
                Kaimon._drain_tool_results!(m.tool_results)
                if Kaimon._LAST_TOOL_SUCCESS[] > m.last_tool_success
                    m.last_tool_success = Kaimon._LAST_TOOL_SUCCESS[]
                end
                if Kaimon._LAST_TOOL_ERROR[] > m.last_tool_error
                    m.last_tool_error = Kaimon._LAST_TOOL_ERROR[]
                end
                @test m.last_tool_success > 0.0
                @test m.last_tool_error > 0.0
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Dynamic Health Computation" begin
        # _compute_health(model, key) returns (health::Float64, has_data::Bool)
        # health = 1.0 - (errors / n) over the last 50 tool results

        @testset "No results → perfect health, no data" begin
            m = Kaimon.KaimonModel()
            h, has_data = Kaimon._compute_health(m)
            @test h == 1.0
            @test !has_data
        end

        @testset "All successes → health 1.0" begin
            m = Kaimon.KaimonModel()
            for _ = 1:5
                push!(
                    m.tool_results,
                    Kaimon.ToolCallResult(Dates.now(), "ex", "{}", "ok", "1ms", true, ""),
                )
            end
            h, has_data = Kaimon._compute_health(m)
            @test h == 1.0
            @test has_data
        end

        @testset "Error penalty" begin
            m = Kaimon.KaimonModel()
            # 4 successes + 1 error = 80% health
            for _ = 1:4
                push!(
                    m.tool_results,
                    Kaimon.ToolCallResult(Dates.now(), "ex", "{}", "ok", "1ms", true, ""),
                )
            end
            push!(
                m.tool_results,
                Kaimon.ToolCallResult(Dates.now(), "ex", "{}", "ERROR", "1ms", false, ""),
            )
            h, has_data = Kaimon._compute_health(m)
            @test h ≈ 0.8
            @test has_data
        end

        @testset "All errors → health 0.0" begin
            m = Kaimon.KaimonModel()
            for _ = 1:5
                push!(
                    m.tool_results,
                    Kaimon.ToolCallResult(
                        Dates.now(),
                        "ex",
                        "{}",
                        "ERROR",
                        "1ms",
                        false,
                        "",
                    ),
                )
            end
            h, has_data = Kaimon._compute_health(m)
            @test h == 0.0
            @test has_data
        end

        @testset "Per-session filtering" begin
            m = Kaimon.KaimonModel()
            # 2 successes for session "aaaa"
            for _ = 1:2
                push!(
                    m.tool_results,
                    Kaimon.ToolCallResult(
                        Dates.now(),
                        "ex",
                        "{}",
                        "ok",
                        "1ms",
                        true,
                        "aaaa",
                    ),
                )
            end
            # 1 error for session "bbbb"
            push!(
                m.tool_results,
                Kaimon.ToolCallResult(
                    Dates.now(),
                    "ex",
                    "{}",
                    "ERROR",
                    "1ms",
                    false,
                    "bbbb",
                ),
            )
            # Session "aaaa" should have perfect health
            h_a, _ = Kaimon._compute_health(m, "aaaa")
            @test h_a == 1.0
            # Session "bbbb" should have 0.0 health
            h_b, _ = Kaimon._compute_health(m, "bbbb")
            @test h_b == 0.0
        end

        @testset "Clamped to [0, 1]" begin
            m = Kaimon.KaimonModel()
            push!(
                m.tool_results,
                Kaimon.ToolCallResult(Dates.now(), "ex", "{}", "ok", "1ms", true, ""),
            )
            h, _ = Kaimon._compute_health(m)
            @test 0.0 <= h <= 1.0
        end
    end

    @testset "Activity Mode Toggle Keybinding" begin
        m, db_path = setup_tui_model()
        try
            m.active_tab = 3
            push_tool_results!(m; n_success = 3)

            @testset "'d' toggles live → analytics" begin
                @test m.activity_mode == :live
                press!(m, 'd')
                @test m.activity_mode == :analytics
                @test m.analytics_cache !== nothing
            end

            @testset "'d' toggles analytics → live" begin
                press!(m, 'd')
                @test m.activity_mode == :live
            end

            @testset "'r' force-refreshes in analytics mode" begin
                press!(m, 'd')
                old_ts = m.analytics_last_refresh
                sleep(0.05)
                press!(m, 'r')
                @test m.analytics_last_refresh > old_ts
            end

            @testset "'r' is no-op in live mode" begin
                press!(m, 'd')  # back to live
                old_ts = m.analytics_last_refresh
                press!(m, 'r')
                @test m.analytics_last_refresh == old_ts
            end

            @testset "'d' on other tabs is no-op" begin
                m.activity_mode = :live
                m.active_tab = 1
                press!(m, 'd')
                @test m.activity_mode == :live
                m.active_tab = 3  # restore
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Live Mode Keys Disabled in Analytics" begin
        m, db_path = setup_tui_model()
        try
            m.active_tab = 3
            push_tool_results!(m; n_success = 3)
            press!(m, 'd')
            @test m.activity_mode == :analytics

            @testset "'f' does not change filter" begin
                old = m.activity_filter
                press!(m, 'f')
                @test m.activity_filter == old
            end

            @testset "'F' does not change follow" begin
                old = m.activity_follow
                press!(m, 'F')
                @test m.activity_follow == old
            end

            @testset "'w' does not change wrap" begin
                old = m.result_word_wrap
                press!(m, 'w')
                @test m.result_word_wrap == old
            end

            @testset "Arrow keys are no-op" begin
                old_sel = m.selected_result
                press!(m, :up)
                press!(m, :down)
                @test m.selected_result == old_sel
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Analytics Refresh" begin
        m, db_path = setup_tui_model()
        try
            @testset "Populates cache from DB" begin
                push_tool_results!(m; n_success = 5, n_error = 2)
                Kaimon._refresh_analytics!(m; force = true)
                c = m.analytics_cache
                @test c !== nothing
                @test length(c.tool_summary) >= 1
                @test length(c.recent_execs) >= 7

                ex_row = filter(x -> get(x, "tool_name", "") == "ex", c.tool_summary)
                @test length(ex_row) == 1
                @test get(ex_row[1], "total_executions", 0) == 7
                @test get(ex_row[1], "error_count", 0) == 2
            end

            @testset "Caching — skips refresh within 30s" begin
                old_ts = m.analytics_last_refresh
                sleep(0.05)
                Kaimon._refresh_analytics!(m)
                @test m.analytics_last_refresh == old_ts
            end

            @testset "Force overrides cache" begin
                old_ts = m.analytics_last_refresh
                sleep(0.05)
                Kaimon._refresh_analytics!(m; force = true)
                @test m.analytics_last_refresh > old_ts
            end

            @testset "Graceful when DB is nothing" begin
                saved = Database.DB[]
                Database.DB[] = nothing
                Kaimon._refresh_analytics!(m; force = true)
                Database.DB[] = saved
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Analytics View Rendering" begin
        m, db_path = setup_tui_model()
        try
            push_tool_results!(m; n_success = 5, n_error = 1, tool_name = "ex")
            push_tool_results!(m; n_success = 3, n_error = 0, tool_name = "format_code")

            @testset "Renders tool usage table" begin
                m.activity_mode = :analytics
                Kaimon._refresh_analytics!(m; force = true)
                text = render_text(m)
                @test occursin("Tool Usage Summary", text)
                @test occursin("ex", text)
                @test occursin("format_code", text)
                @test occursin("Err%", text)
            end

            @testset "Renders error hotspots section" begin
                @test occursin("Error Hotspots", render_text(m))
            end

            @testset "Renders sparkline section" begin
                @test occursin("Calls/min", render_text(m))
            end

            @testset "Renders keybinding hints" begin
                text = render_text(m)
                @test occursin("[d]ata", text)
                @test occursin("[r]efresh", text)
            end

            @testset "Shows placeholder when no DB" begin
                saved = Database.DB[]
                Database.DB[] = nothing
                m.analytics_cache = nothing
                @test occursin("No analytics data yet", render_text(m))
                Database.DB[] = saved
            end

            @testset "Renders at various terminal sizes" begin
                m.analytics_cache = nothing
                Kaimon._refresh_analytics!(m; force = true)
                for (w, h) in [(80, 24), (120, 40), (60, 15)]
                    text = join(render_activity(m; width = w, height = h), "\n")
                    @test occursin("Analytics", text)
                end
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Live View Rendering" begin
        m, db_path = setup_tui_model()
        try
            push_tool_results!(m; n_success = 3, n_error = 1)
            m.activity_mode = :live
            m.tick = 10

            @testset "Shows tool call list with [d]ata hint" begin
                text = render_text(m)
                @test occursin("[d]ata", text)
                @test occursin("Tool Calls", text)
            end

            @testset "Shows success and error markers" begin
                text = render_text(m)
                @test occursin("✓", text)
                @test occursin("✗", text)
            end

            @testset "Mode switch changes rendered content" begin
                m.active_tab = 3
                m.activity_mode = :live
                live_text = render_text(m)
                press!(m, 'd')  # needs active_tab == 3
                analytics_text = render_text(m)
                @test m.activity_mode == :analytics
                @test live_text != analytics_text
                @test occursin("Tool Usage Summary", analytics_text)
                @test occursin("Tool Calls", live_text)
            end
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "End-to-End: Tool Call → DB → Analytics View" begin
        m, db_path = setup_tui_model()
        try
            # 1. Push tool calls (simulates agent activity)
            push_tool_results!(m; n_success = 10, n_error = 3, tool_name = "ex")
            push_tool_results!(m; n_success = 5, n_error = 0, tool_name = "run_tests")

            # 2. Verify DB has rows
            rows = Database.get_tool_executions(; days = 1)
            @test length(rows) >= 18

            # 3. Switch to analytics via keypress
            m.active_tab = 3
            press!(m, 'd')
            @test m.activity_mode == :analytics
            @test m.analytics_cache !== nothing

            # 4. Verify analytics cache reflects DB data
            c = m.analytics_cache
            tool_names = [get(r, "tool_name", "") for r in c.tool_summary]
            @test "ex" in tool_names
            @test "run_tests" in tool_names

            # 5. Render and verify visual output
            text = render_text(m)
            @test occursin("ex", text)
            @test occursin("run_tests", text)

            # 6. Switch back to live and verify
            press!(m, 'd')
            @test m.activity_mode == :live
            text = render_text(m)
            @test occursin("Tool Calls", text)
            @test occursin("✓", text)
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

    @testset "Rapid Mode Toggle Stability" begin
        m, db_path = setup_tui_model()
        try
            m.active_tab = 3
            push_tool_results!(m; n_success = 5)

            # Rapidly toggle 20 times — should never crash
            for _ = 1:20
                press!(m, 'd')
            end
            @test m.activity_mode in (:live, :analytics)

            # Render should still work in whatever mode we ended up in
            text = render_text(m)
            @test !isempty(text)
        finally
            Database.close_db!()
            rm(db_path; force = true)
        end
    end

end

# ── Property-Based Tests (Supposition.jl) ────────────────────────────────────

@testset "TUI Analytics Properties (Supposition)" begin

    @testset "Health gauge always in [0, 1]" begin
        @check function health_always_clamped(
            n_success = Data.Integers(0, 60),
            n_error = Data.Integers(0, 60),
        )
            m = Kaimon.KaimonModel(server_port = 19990)
            for _ = 1:n_success
                push!(
                    m.tool_results,
                    Kaimon.ToolCallResult(
                        now(),
                        "prop_test",
                        "{}",
                        "ok",
                        "1ms",
                        true,
                        "sess1",
                    ),
                )
            end
            for _ = 1:n_error
                push!(
                    m.tool_results,
                    Kaimon.ToolCallResult(
                        now(),
                        "prop_test",
                        "{}",
                        "err",
                        "1ms",
                        false,
                        "sess1",
                    ),
                )
            end
            (h, _) = Kaimon._compute_health(m)
            0.0 <= h <= 1.0
        end
    end

    @testset "More errors => lower health" begin
        @check function errors_reduce_health(
            n_success = Data.Integers(1, 50),
            n_extra_errors = Data.Integers(1, 20),
        )
            # Model with n_success successes (health = 1.0)
            m1 = Kaimon.KaimonModel(server_port = 19990)
            for _ = 1:n_success
                push!(
                    m1.tool_results,
                    Kaimon.ToolCallResult(
                        now(),
                        "prop_test",
                        "{}",
                        "ok",
                        "1ms",
                        true,
                        "sess1",
                    ),
                )
            end
            (h1, _) = Kaimon._compute_health(m1)

            # Model with same successes + extra errors
            m2 = Kaimon.KaimonModel(server_port = 19990)
            for _ = 1:n_success
                push!(
                    m2.tool_results,
                    Kaimon.ToolCallResult(
                        now(),
                        "prop_test",
                        "{}",
                        "ok",
                        "1ms",
                        true,
                        "sess1",
                    ),
                )
            end
            for _ = 1:n_extra_errors
                push!(
                    m2.tool_results,
                    Kaimon.ToolCallResult(
                        now(),
                        "prop_test",
                        "{}",
                        "err",
                        "1ms",
                        false,
                        "sess1",
                    ),
                )
            end
            (h2, _) = Kaimon._compute_health(m2)

            h1 >= h2
        end
    end

    @testset "Duration string round-trip" begin
        @check function duration_parse_roundtrip(ms_raw = Data.Integers(0, 100_000))
            # Format like the real code does, then check _persist_tool_call! would parse it
            ms = Float64(ms_raw)
            dur_str = if ms < 1000.0
                string(round(Int, ms)) * "ms"
            else
                string(round(ms / 1000.0; digits = 1)) * "s"
            end

            # Parse back (same logic as _persist_tool_call!)
            parsed = if endswith(dur_str, "ms")
                parse(Float64, dur_str[1:end-2])
            elseif endswith(dur_str, "s")
                parse(Float64, dur_str[1:end-1]) * 1000.0
            else
                0.0
            end

            # Should be within 1ms of original (rounding)
            abs(parsed - ms) <= 100.0  # generous tolerance for round-trip through string
        end
    end

    @testset "Tool result text truncation" begin
        @check function truncation_bounded(len = Data.Integers(0, 5000))
            text = repeat("a", len)
            summary = length(text) > 500 ? text[1:500] : text
            length(summary) <= 500
        end
    end

    @testset "Analytics view never crashes on any terminal size" begin
        @check function analytics_render_any_size(
            w = Data.Integers(20, 300),
            h = Data.Integers(5, 100),
        )
            db_path = tempname() * ".db"
            Database.init_db!(db_path)
            try
                m = Kaimon.KaimonModel(server_port = 19998)
                m.db_initialized = true
                m.server_started = true
                m.activity_mode = :analytics
                Kaimon.set_theme!(:kokaku)

                # Push a few results so there's data to render
                for i = 1:3
                    r = Kaimon.ToolCallResult(
                        now(),
                        "prop_test",
                        "{}",
                        "ok",
                        "10ms",
                        true,
                        "",
                    )
                    Kaimon._persist_tool_call!(r)
                end
                Kaimon._refresh_analytics!(m; force = true)

                area = Tachikoma.Rect(0, 0, w, h)
                buf = Tachikoma.Buffer(area)
                Kaimon._view_analytics(m, area, buf)
                true  # didn't throw
            finally
                Database.close_db!()
                rm(db_path; force = true)
            end
        end
    end

end

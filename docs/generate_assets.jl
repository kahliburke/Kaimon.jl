# ═══════════════════════════════════════════════════════════════════════
# generate_assets.jl — Render Kaimon.jl doc assets (GIFs, SVGs)
#
# Produces scripted TUI recordings demonstrating setup and usage.
# Uses a hash-based cache so only changed renders are re-generated.
#
# Usage:
#   julia --project=docs docs/generate_assets.jl [flags]
#
# Flags:
#   --force    Regenerate everything (ignore cache)
# ═══════════════════════════════════════════════════════════════════════

using Kaimon
using Tachikoma
using SHA
using JSON3
using Dates
using Random

import Kaimon:
    KaimonModel,
    ConnectionManager,
    REPLConnection,
    ServerLogEntry,
    ToolCallResult,
    ToolCallRecord,
    ActivityEvent,
    SetupWizardModel,
    TestRun,
    TestResult,
    TestFailure,
    RUN_PASSED,
    RUN_FAILED,
    TEST_PASS,
    TEST_FAIL

import Tachikoma:
    record_app,
    enable_gif,
    export_gif_from_snapshots,
    load_tach,
    export_svg,
    discover_mono_fonts,
    EventScript,
    key,
    pause,
    seq,
    rep,
    chars,
    set_theme!

set_theme!(:kokaku)

const ASSETS_DIR = joinpath(@__DIR__, "src", "assets")
const CACHE_FILE = joinpath(@__DIR__, ".render_cache.json")

# ═══════════════════════════════════════════════════════════════════════
# Render cache
# ═══════════════════════════════════════════════════════════════════════

function load_cache()::Dict{String,String}
    isfile(CACHE_FILE) || return Dict{String,String}()
    try
        JSON3.read(read(CACHE_FILE, String), Dict{String,String})
    catch
        Dict{String,String}()
    end
end

function save_cache!(cache::Dict{String,String})
    open(CACHE_FILE, "w") do io
        JSON3.pretty(io, cache)
    end
end

function file_sha256(path::String)::String
    isfile(path) ? bytes2hex(sha256(read(path))) : ""
end

function should_render(cache, key, source_hash, tach_path)
    cached = get(cache, key, nothing)
    cached === nothing && return true
    parts = split(cached, ':')
    length(parts) != 2 && return true
    cached_parts = parts
    cached_parts[1] != source_hash && return true
    file_sha256(tach_path) != cached_parts[2] && return true
    false
end

function update_cache!(cache, key, source_hash, tach_path)
    cache[key] = "$(source_hash):$(file_sha256(tach_path))"
end

# ═══════════════════════════════════════════════════════════════════════
# Font discovery
# ═══════════════════════════════════════════════════════════════════════

function _find_font()
    fonts = discover_mono_fonts()
    for name in ["MesloLGL Nerd Font Mono", "JetBrains Mono", "MesloLGS NF", "Menlo"]
        norm = lowercase(replace(name, " " => ""))
        idx = findfirst(f -> occursin(norm, lowercase(replace(f.name, " " => ""))), fonts)
        idx !== nothing && return fonts[idx].path
    end
    isempty(fonts) ? "" : fonts[1].path
end

# ═══════════════════════════════════════════════════════════════════════
# Export: .tach → .svg + .gif
# ═══════════════════════════════════════════════════════════════════════

function export_formats(tach_file::String; gif::Bool = true)
    w, h, cells, timestamps, sixels = load_tach(tach_file)
    base = replace(tach_file, r"\.tach$" => "")
    font_path = _find_font()

    svg_file = base * ".svg"
    export_svg(svg_file, w, h, cells, timestamps; font_path)
    println("    → $(basename(svg_file))")

    if gif
        try
            enable_gif()
            gif_file = base * ".gif"
            Base.invokelatest(
                export_gif_from_snapshots,
                gif_file,
                w,
                h,
                cells,
                timestamps;
                pixel_snapshots = sixels,
                font_path,
                cell_w = 10,
                cell_h = 20,
                font_size = 16,
            )
            println("    → $(basename(gif_file))")
        catch e
            @warn "GIF export skipped" exception = (e, catch_backtrace())
        end
    end
end

# ═══════════════════════════════════════════════════════════════════════
# Mock model factories
# ═══════════════════════════════════════════════════════════════════════

"Build a mock REPLConnection in :connected state."
function _mock_conn(;
    session_id::String,
    display_name::String,
    project_path::String,
    julia_version::String = "1.12.5",
    pid::Int = 0,
    tool_call_count::Int = 0,
    tools::Vector{Dict{String,Any}} = Dict{String,Any}[],
)
    conn = REPLConnection(;
        session_id,
        name = display_name,
        display_name,
        project_path,
        julia_version,
        pid,
        session_tools = tools,
    )
    conn.status = :connected
    conn.tool_call_count = tool_call_count
    conn
end

"Build a ServerLogEntry."
_log(level::Symbol, msg::String; ago_s::Int = 0) =
    ServerLogEntry(now() - Second(ago_s), level, msg)

"Build a ToolCallResult."
function _result(
    tool::String,
    args::String,
    result::String;
    ago_s::Int = 0,
    success::Bool = true,
    dur::String = "42ms",
    skey::String = "abcd1234",
)
    ToolCallResult(now() - Second(ago_s), tool, args, result, dur, success, skey)
end

"Build an ActivityEvent."
function _activity(
    kind::Symbol,
    tool::String,
    session::String;
    ago_s::Int = 0,
    data::String = "",
    success::Bool = true,
)
    ActivityEvent(now() - Second(ago_s), kind, tool, session, data, success)
end

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_wizard — setup wizard: mode select → intro → ack → security → key
# ═══════════════════════════════════════════════════════════════════════

function _build_wizard_model()
    SetupWizardModel(_render_mode = true)
end

# "I UNDERSTAND THE RISKS" — each spacebar auto-types one character
const _ACK_LEN = length("I UNDERSTAND THE RISKS")

const EVENTS_WIZARD = EventScript(
    pause(2.0),                              # linger on mode select
    (0.0, key(:right)),                      # browse → GENTLE
    pause(0.5),
    (0.0, key(:right)),                      # browse → L33T
    pause(0.5),
    (0.0, key(:left)),                       # back → STANDARD
    pause(0.5),
    (0.0, key(:enter)),                      # select STANDARD → intro animation
    pause(3.0),                              # let the dragon breathe
    (0.0, key('x')),                         # skip intro → acknowledge phase
    pause(0.3),
    rep(key(' '), _ACK_LEN; gap = 0.07),    # spacebar auto-types the ack phrase
    pause(0.8),                              # → security mode
    rep(key(:down), 2; gap = 0.3),          # navigate to lax
    pause(0.5),
    rep(key(:up), 1; gap = 0.3),            # back to relaxed
    pause(0.6),
    (0.0, key(:enter)),                      # select relaxed → port
    pause(0.5),
    (0.0, key(:enter)),                      # accept default port → api key gen
    pause(2.0),                              # show the generated key
    (0.0, key(:enter)),                      # advance → quick-or-advanced
    pause(1.5),                              # linger on final screen
)

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_overview — navigate tabs showing the full TUI
# ═══════════════════════════════════════════════════════════════════════

function _build_overview_model()
    Random.seed!(42)
    conn1 = _mock_conn(;
        session_id = "abcd1234efgh5678",
        display_name = "Kaimon",
        project_path = "/Users/kburke/.julia/dev/Kaimon",
        pid = 41000,
        tool_call_count = 57,
        tools = [
            Dict("name" => "ex", "arguments" => [Dict("name" => "e"), Dict("name" => "q")]),
            Dict("name" => "run_tests", "arguments" => [Dict("name" => "pattern")]),
            Dict("name" => "goto_definition", "arguments" => [Dict("name" => "file_path")]),
        ],
    )
    conn2 = _mock_conn(;
        session_id = "efgh5678ijkl9012",
        display_name = "Tachikoma",
        project_path = "/Users/kburke/devel/Tachikoma.jl",
        pid = 38500,
        tool_call_count = 112,
    )

    mgr = ConnectionManager()
    push!(mgr.connections, conn1, conn2)

    tool_history = zeros(120)
    for i = 80:110
        tool_history[i] = rand() * 3
    end
    for i = 111:120
        tool_history[i] = rand() * 8 + 2
    end

    logs = [
        _log(:info, "Kaimon MCP server started on port 2828"; ago_s = 120),
        _log(:info, "Gate connected: Kaimon (pid=41000)"; ago_s = 90),
        _log(:info, "Gate connected: Tachikoma (pid=38500)"; ago_s = 85),
        _log(:info, "Tool call: ex (Kaimon)"; ago_s = 30),
        _log(:info, "Tool call: run_tests (Kaimon)"; ago_s = 15),
        _log(:info, "Tool call: ex (Tachikoma)"; ago_s = 5),
    ]

    results = [
        _result("ex", "{\"e\":\"1+1\"}", "2"; ago_s = 30, dur = "12ms"),
        _result(
            "run_tests",
            "{\"pattern\":\"\"}",
            "✓ 47 tests passed";
            ago_s = 15,
            dur = "4.2s",
        ),
        _result("ex", "{\"e\":\"sin(π/4)\"}", "0.7071"; ago_s = 5, dur = "8ms"),
    ]

    activity = [
        _activity(:tool_start, "ex", "Kaimon"; ago_s = 30),
        _activity(:tool_done, "ex", "Kaimon"; ago_s = 30, data = "12ms"),
        _activity(:tool_start, "run_tests", "Kaimon"; ago_s = 15),
        _activity(:tool_done, "run_tests", "Kaimon"; ago_s = 15, data = "4.2s"),
        _activity(:tool_start, "ex", "Tachikoma"; ago_s = 5),
        _activity(:tool_done, "ex", "Tachikoma"; ago_s = 5, data = "8ms"),
    ]

    KaimonModel(
        _render_mode = true,
        conn_mgr = mgr,
        server_running = true,
        server_started = true,
        server_port = 2828,
        total_tool_calls = 169,
        tool_call_history = tool_history,
        server_log = logs,
        tool_results = results,
        activity_feed = activity,
        selected_connection = 1,
        client_statuses = [
            "Claude Code" => true,
            "VS Code / Copilot" => false,
        ],
    )
end

const EVENTS_OVERVIEW = EventScript(
    pause(1.5),
    (0.0, key('2')),      # → Sessions tab
    pause(1.8),
    (0.0, key('3')),      # → Activity tab
    pause(1.8),
    (0.0, key('6')),      # → Config tab
    pause(2.0),
    (0.0, key('1')),      # → back to Server tab
    pause(1.5),
)

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_sessions — sessions tab with detail pane scrolling
# ═══════════════════════════════════════════════════════════════════════

function _build_sessions_model()
    tools_kaimon = [
        Dict("name" => "ex", "arguments" => [Dict("name" => "e"), Dict("name" => "q")]),
        Dict("name" => "run_tests", "arguments" => [Dict("name" => "pattern")]),
        Dict(
            "name" => "goto_definition",
            "arguments" => [Dict("name" => "file_path"), Dict("name" => "line")],
        ),
        Dict("name" => "document_symbols", "arguments" => [Dict("name" => "file_path")]),
        Dict("name" => "profile_code", "arguments" => [Dict("name" => "code")]),
        Dict("name" => "format_code", "arguments" => [Dict("name" => "path")]),
    ]

    conn1 = _mock_conn(;
        session_id = "abcd1234efgh5678",
        display_name = "Kaimon",
        project_path = "/Users/kburke/.julia/dev/Kaimon",
        pid = 41000,
        tool_call_count = 57,
        tools = tools_kaimon,
    )

    # Seed some healthy tool results
    results = [
        _result(
            "ex",
            "{\"e\":\"1+1\"}",
            "2";
            ago_s = 60 - i,
            dur = "$(10+i)ms",
            skey = "abcd1234",
        ) for i = 1:20
    ]
    # One error in the mix
    results[8] = _result(
        "ex",
        "{\"e\":\"error()\"}",
        "ERROR: ...";
        ago_s = 40,
        success = false,
        skey = "abcd1234",
    )

    # Warm up the ECG trace a bit
    ecg = fill(0.5, 240)

    mgr = ConnectionManager()
    push!(mgr.connections, conn1)

    KaimonModel(
        _render_mode = true,
        active_tab = 2,          # start on Sessions
        conn_mgr = mgr,
        server_running = true,
        server_started = true,
        total_tool_calls = 57,
        tool_results = results,
        selected_connection = 1,
        ecg_trace = ecg,
    )
end

const EVENTS_SESSIONS = EventScript(
    pause(1.5),
    # Focus to detail pane (Tab key cycles pane focus)
    (0.0, key(:tab)),
    (0.0, key(:tab)),
    pause(0.5),
    # Scroll detail pane down
    rep(key(:down), 4; gap = 0.15),
    pause(0.8),
    rep(key(:down), 3; gap = 0.15),
    pause(1.0),
    # Scroll back up
    rep(key(:up), 7; gap = 0.1),
    pause(1.5),
)

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_config — config tab showing client install flow
# ═══════════════════════════════════════════════════════════════════════

function _build_config_model()
    KaimonModel(
        _render_mode = true,
        active_tab = 6,            # start on Config tab
        server_running = true,
        server_started = true,
        server_port = 2828,
        client_statuses = [
            "Claude Code" => false,
            "VS Code / Copilot" => false,
        ],
        focused_pane = Dict(1 => 2, 2 => 1, 3 => 1, 4 => 1, 5 => 1, 6 => 2, 7 => 2),
    )
end

const EVENTS_CONFIG = EventScript(
    pause(1.2),
    (0.0, key('i')),                    # open client select list
    pause(0.8),
    rep(key(:down), 2; gap = 0.25),     # navigate to Gemini CLI
    pause(0.6),
    (0.0, key(:enter)),                 # advance to confirm modal
    pause(1.2),
    # linger on the confirm screen, then cancel (no real install)
    (0.0, key(:right)),                 # move to Cancel button
    pause(0.8),
    (0.0, key(:enter)),                 # cancel — back to idle
    pause(0.8),
    # Show client list again for Claude Code
    (0.0, key('i')),                    # re-open client select
    pause(0.5),
    # Navigate back up to Claude Code (index 1, already selected)
    (0.0, key(:up)),
    (0.0, key(:up)),
    pause(0.6),
    (0.0, key(:enter)),                 # advance to Claude confirm modal
    pause(1.5),
    # Leave the confirm modal visible — don't actually execute
)

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_startup_global — Config tab → client list → Julia startup.jl
# ═══════════════════════════════════════════════════════════════════════

function _build_startup_global_model()
    KaimonModel(
        _render_mode = true,
        active_tab = 6,
        server_running = true,
        server_started = true,
        server_port = 2828,
        client_statuses = [
            "Claude Code" => false,
            "VS Code / Copilot" => false,
        ],
        focused_pane = Dict(1 => 2, 2 => 1, 3 => 1, 4 => 1, 5 => 1, 6 => 2, 7 => 2),
    )
end

# Global gate is accessed via 'g' key on the Config tab (separate from MCP client list)
const EVENTS_STARTUP_GLOBAL = EventScript(
    pause(1.0),
    (0.0, key('g')),                        # open global gate confirm directly
    pause(2.5),                             # linger — show what the confirm says
    (0.0, key(:right)),                     # move to Cancel (no real write)
    pause(0.5),
    (0.0, key(:enter)),                     # cancel
    pause(0.8),
)

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_startup_project — Config tab → onboarding path input → confirm
# ═══════════════════════════════════════════════════════════════════════

function _build_startup_project_model()
    KaimonModel(
        _render_mode = true,
        active_tab = 6,
        server_running = true,
        server_started = true,
        server_port = 2828,
        client_statuses = [
            "Claude Code" => false,
            "VS Code / Copilot" => false,
        ],
        focused_pane = Dict(1 => 2, 2 => 1, 3 => 1, 4 => 1, 5 => 1, 6 => 2, 7 => 2),
    )
end

const EVENTS_STARTUP_PROJECT = EventScript(
    pause(1.0),
    (0.0, key('o')),                        # open onboarding path input
    pause(1.8),                             # show the pre-filled path
    (0.0, key(:enter)),                     # accept path → confirm modal
    pause(2.0),                             # linger on confirm
    (0.0, key(:right)),                     # move to Cancel (no real write)
    pause(0.5),
    (0.0, key(:enter)),                     # cancel
    pause(0.8),
)

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_search — Search tab with indexed collection and results
# ═══════════════════════════════════════════════════════════════════════

function _build_search_model()
    results = [
        Dict(
            "score" => 0.91,
            "payload" => Dict(
                "file" => "/Users/kburke/.julia/dev/Kaimon/src/gate.jl",
                "name" => "serve",
                "start_line" => 1293,
                "end_line" => 1310,
                "type" => "definition",
                "signature" => "serve(; session_id, force, tools, namespace, allow_mirror, allow_restart)",
                "text" => "function serve(;\n    session_id = nothing,\n    force = false,\n    tools = GateTool[],\n    ...\n)",
            ),
        ),
        Dict(
            "score" => 0.84,
            "payload" => Dict(
                "file" => "/Users/kburke/.julia/dev/Kaimon/src/gate.jl",
                "name" => "GateTool",
                "start_line" => 210,
                "end_line" => 230,
                "type" => "definition",
                "signature" => "GateTool(name, fn; description, schema)",
                "text" => "struct GateTool\n    name::String\n    fn::Any\n    ...\nend",
            ),
        ),
        Dict(
            "score" => 0.76,
            "payload" => Dict(
                "file" => "/Users/kburke/.julia/dev/Kaimon/src/gate_client.jl",
                "name" => "_dispatch_tool",
                "start_line" => 88,
                "end_line" => 112,
                "type" => "definition",
                "signature" => "_dispatch_tool(conn, name, args)",
                "text" => "function _dispatch_tool(conn::REPLConnection, name::String, args::Dict)",
            ),
        ),
        Dict(
            "score" => 0.71,
            "payload" => Dict(
                "file" => "/Users/kburke/.julia/dev/Kaimon/src/MCPServer.jl",
                "name" => "_handle_tool_call",
                "start_line" => 445,
                "end_line" => 480,
                "type" => "definition",
                "signature" => "_handle_tool_call(ctx, name, arguments)",
                "text" => "function _handle_tool_call(ctx, name::String, arguments::Dict)",
            ),
        ),
    ]

    KaimonModel(
        _render_mode = true,
        active_tab = 4,   # Search tab
        server_running = true,
        server_started = true,
        search_qdrant_up = true,
        search_collections = ["Kaimon", "Tachikoma"],
        search_collection_count = 2,
        search_selected_collection = 1,
        search_results = results,
    )
end

const EVENTS_SEARCH = EventScript(
    pause(1.5),
    (0.0, key(:tab)),                       # focus query pane
    pause(0.5),
    (0.0, key(:enter)),                     # start editing query
    pause(0.3),
    chars("connect REPL to server"; pace = 0.06),
    pause(1.0),
    (0.0, key(:enter)),                     # submit search
    pause(1.5),
    (0.0, key(:tab)),                       # focus results pane
    pause(0.5),
    rep(key(:down), 3; gap = 0.3),          # scroll through results
    pause(1.5),
)

# ═══════════════════════════════════════════════════════════════════════
# Render helpers
# ═══════════════════════════════════════════════════════════════════════

struct DemoSpec
    id::String
    model_fn::Function
    events::EventScript
    width::Int
    height::Int
    frames::Int
    fps::Int
end

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_search_config — Search tab → [o] model config overlay
# ═══════════════════════════════════════════════════════════════════════

function _build_search_config_model()
    models = [
        (name = "nomic-embed-text",              dims = 768,  ctx = 512,  installed = true),
        (name = "qwen3-embedding:0.6b",          dims = 1024, ctx = 8192, installed = true),
        (name = "qwen3-embedding:4b",            dims = 2560, ctx = 8192, installed = false),
        (name = "qwen3-embedding:8b",            dims = 4096, ctx = 8192, installed = false),
        (name = "qwen3-embedding",               dims = 4096, ctx = 8192, installed = false),
        (name = "snowflake-arctic-embed:latest", dims = 1024, ctx = 512,  installed = false),
    ]
    KaimonModel(
        _render_mode = true,
        active_tab = 4,
        server_running = true,
        server_started = true,
        search_qdrant_up = true,
        search_ollama_up = true,
        search_model_available = true,
        search_collections = ["Kaimon"],
        search_collection_count = 1,
        search_selected_collection = 1,
        search_embedding_model = "qwen3-embedding:0.6b",
        search_config_open = true,
        search_config_selected = 2,   # qwen3-embedding:0.6b
        search_config_models = models,
    )
end

const EVENTS_SEARCH_CONFIG = EventScript(
    pause(1.5),
    rep(key(:down), 2; gap = 0.35),       # scroll down to larger models
    pause(1.0),
    rep(key(:up), 1; gap = 0.35),          # back up
    pause(1.5),
    (0.0, key(:escape)),                    # close overlay
    pause(0.8),
)

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_activity — Activity tab with tool call history + detail
# ═══════════════════════════════════════════════════════════════════════

function _build_activity_model()
    results = [
        _result("ex",             "{\"e\":\"1+1\"}",                "2";          ago_s=5,   dur="8ms",   skey="abcd1234"),
        _result("run_tests",      "{\"pattern\":\"gate\"}",         "✓ 23 passed"; ago_s=18,  dur="3.1s",  skey="abcd1234"),
        _result("goto_definition","{\"file_path\":\"gate.jl\",\"line\":88}", "gate.jl:88"; ago_s=30, dur="14ms", skey="abcd1234"),
        _result("ex",             "{\"e\":\"sin(π/4)\"}",           "0.7071";     ago_s=42,  dur="11ms",  skey="abcd1234"),
        _result("document_symbols","{\"file_path\":\"src/gate.jl\"}","[serve, GateTool, ...]"; ago_s=60, dur="22ms", skey="abcd1234"),
        _result("ex",             "{\"e\":\"error(\\\"oops\\\")\"}","ERROR: oops"; ago_s=75, dur="5ms", skey="abcd1234", success=false),
        _result("format_code",    "{\"path\":\"src/\"}",            "Formatted 12 files"; ago_s=90, dur="1.4s", skey="abcd1234"),
    ]

    activity = [
        _activity(:tool_start, "ex",              "Kaimon"; ago_s=5),
        _activity(:tool_done,  "ex",              "Kaimon"; ago_s=5,  data="8ms"),
        _activity(:tool_start, "run_tests",       "Kaimon"; ago_s=18),
        _activity(:tool_done,  "run_tests",       "Kaimon"; ago_s=18, data="3.1s"),
        _activity(:tool_start, "goto_definition", "Kaimon"; ago_s=30),
        _activity(:tool_done,  "goto_definition", "Kaimon"; ago_s=30, data="14ms"),
        _activity(:tool_start, "ex",              "Kaimon"; ago_s=42),
        _activity(:tool_done,  "ex",              "Kaimon"; ago_s=42, data="11ms"),
        _activity(:tool_start, "ex",              "Kaimon"; ago_s=75),
        _activity(:tool_done,  "ex",              "Kaimon"; ago_s=75, data="5ms", success=false),
    ]

    tool_history = zeros(120)
    for i in 90:110; tool_history[i] = rand() * 2; end
    for i in 111:120; tool_history[i] = rand() * 5 + 1; end

    mgr = ConnectionManager()
    conn = _mock_conn(; session_id="abcd1234efgh5678", display_name="Kaimon",
                       project_path="/Users/kburke/.julia/dev/Kaimon", pid=41000,
                       tool_call_count=169)
    push!(mgr.connections, conn)

    KaimonModel(
        _render_mode = true,
        active_tab = 3,
        conn_mgr = mgr,
        server_running = true,
        server_started = true,
        total_tool_calls = 169,
        tool_call_history = tool_history,
        tool_results = results,
        activity_feed = activity,
        selected_result = 1,
        activity_follow = false,
    )
end

const EVENTS_ACTIVITY = EventScript(
    pause(1.5),
    rep(key(:down), 3; gap = 0.3),      # scroll through tool calls
    pause(0.8),
    (0.0, key(:tab)),                    # focus detail pane
    pause(0.5),
    rep(key(:down), 4; gap = 0.2),      # scroll detail output
    pause(1.0),
    rep(key(:up), 4; gap = 0.15),       # scroll back up
    pause(0.8),
    (0.0, key(:tab)),                    # back to list
    pause(0.5),
    rep(key(:down), 2; gap = 0.3),      # show error entry
    pause(1.5),
)

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_tests — Tests tab with a passed and a failed run
# ═══════════════════════════════════════════════════════════════════════

function _build_tests_model()
    run1 = TestRun(; id=1, project_path="/Users/kburke/.julia/dev/Kaimon")
    run1.status      = RUN_PASSED
    run1.finished_at = now() - Second(30)
    run1.started_at  = run1.finished_at - Second(4)
    run1.total_pass  = 47
    run1.total_tests = 47
    run1.results = [
        TestResult("KaimonTests",    TEST_PASS, 47, 0, 0, 47, 0),
        TestResult("Gate tests",     TEST_PASS, 18, 0, 0, 18, 1),
        TestResult("MCP tests",      TEST_PASS, 12, 0, 0, 12, 1),
        TestResult("Search tests",   TEST_PASS,  9, 0, 0,  9, 1),
        TestResult("Config tests",   TEST_PASS,  8, 0, 0,  8, 1),
    ]

    run2 = TestRun(; id=2, project_path="/Users/kburke/.julia/dev/Kaimon", pattern="gate")
    run2.status      = RUN_FAILED
    run2.finished_at = now() - Second(5)
    run2.started_at  = run2.finished_at - Second(2)
    run2.total_pass  = 16
    run2.total_fail  = 2
    run2.total_tests = 18
    run2.results = [
        TestResult("Gate tests", TEST_FAIL, 16, 2, 0, 18, 0),
        TestResult("serve()",    TEST_FAIL, 12, 1, 0, 13, 1),
        TestResult("reconnect",  TEST_FAIL,  4, 1, 0,  5, 1),
    ]
    run2.failures = [
        TestFailure(
            "test/gate_tests.jl", 88,
            "conn.status == :connected",
            "Evaluated: :timeout == :connected",
            "serve()",
            "  [1] test_gate_serve at test/gate_tests.jl:88",
        ),
        TestFailure(
            "test/gate_tests.jl", 142,
            "length(mgr.connections) == 1",
            "Evaluated: 0 == 1",
            "reconnect",
            "  [1] test_reconnect at test/gate_tests.jl:142",
        ),
    ]
    run2.raw_output = [
        "Testing KaimonTests (pattern: gate)",
        "  Gate tests: ",
        "    ✗ serve(): Test Failed at test/gate_tests.jl:88",
        "      Expression: conn.status == :connected",
        "      Evaluated:  :timeout == :connected",
        "    ✗ reconnect: Test Failed at test/gate_tests.jl:142",
        "      Expression: length(mgr.connections) == 1",
        "      Evaluated:  0 == 1",
        "  16 passed, 2 failed in 2.1s",
    ]

    KaimonModel(
        _render_mode = true,
        active_tab = 5,
        server_running = true,
        server_started = true,
        test_runs = [run1, run2],
        selected_test_run = 2,    # show the failed run selected
        test_follow = false,
    )
end

const EVENTS_TESTS = EventScript(
    pause(1.5),
    (0.0, key(:up)),                     # select passing run
    pause(1.0),
    (0.0, key(:down)),                   # back to failing run
    pause(0.8),
    (0.0, key(:tab)),                    # focus detail pane
    pause(0.5),
    rep(key(:down), 3; gap = 0.25),     # scroll through failures
    pause(1.2),
    (0.0, key('o')),                     # switch to raw output view
    pause(0.8),
    rep(key(:down), 3; gap = 0.2),      # scroll output
    pause(1.2),
)

# ═══════════════════════════════════════════════════════════════════════
# Demo: kaimon_collection_manager — Search [m] collection manager overlay
# ═══════════════════════════════════════════════════════════════════════

function _build_collection_manager_model()
    entries = [
        (
            label       = "Kaimon",
            project_path = "/Users/kburke/.julia/dev/Kaimon",
            collection  = "kaimon",
            session_id  = "abcd1234",
            status      = :connected,
        ),
        (
            label       = "Tachikoma",
            project_path = "/Users/kburke/devel/Tachikoma.jl",
            collection  = "tachikoma",
            session_id  = "efgh5678",
            status      = :connected,
        ),
        (
            label       = "EvaCopy (external)",
            project_path = "/Users/kburke/devel/EvaCopy",
            collection  = "evacopy",
            session_id  = "",
            status      = :external,
        ),
    ]

    KaimonModel(
        _render_mode = true,
        active_tab = 4,
        server_running = true,
        server_started = true,
        search_qdrant_up = true,
        search_ollama_up = true,
        search_model_available = true,
        search_collections = ["kaimon", "tachikoma", "evacopy"],
        search_collection_count = 3,
        search_selected_collection = 1,
        search_embedding_model = "qwen3-embedding:0.6b",
        search_manage_open = true,
        search_manage_selected = 1,
        search_manage_entries = entries,
        search_manage_stale = Dict("kaimon" => 3, "tachikoma" => 0, "evacopy" => 0),
    )
end

const EVENTS_COLLECTION_MANAGER = EventScript(
    pause(1.5),
    rep(key(:down), 2; gap = 0.4),      # navigate entries
    pause(1.0),
    rep(key(:up), 1; gap = 0.4),        # back to Kaimon
    pause(0.8),
    (0.0, key(:escape)),                 # close
    pause(0.8),
)

const DEMOS = [
    DemoSpec("kaimon_wizard",              _build_wizard_model,             EVENTS_WIZARD,              130, 34, 230, 15),
    DemoSpec("kaimon_overview",            _build_overview_model,           EVENTS_OVERVIEW,            130, 34, 180, 15),
    DemoSpec("kaimon_sessions",            _build_sessions_model,           EVENTS_SESSIONS,            130, 34, 135, 15),
    DemoSpec("kaimon_activity",            _build_activity_model,           EVENTS_ACTIVITY,            130, 34, 150, 15),
    DemoSpec("kaimon_tests",               _build_tests_model,              EVENTS_TESTS,               130, 34, 140, 15),
    DemoSpec("kaimon_config",              _build_config_model,             EVENTS_CONFIG,              130, 34, 150, 15),
    DemoSpec("kaimon_startup_global",      _build_startup_global_model,     EVENTS_STARTUP_GLOBAL,      130, 34,  80, 15),
    DemoSpec("kaimon_startup_project",     _build_startup_project_model,    EVENTS_STARTUP_PROJECT,     130, 34, 115, 15),
    DemoSpec("kaimon_search",              _build_search_model,             EVENTS_SEARCH,              130, 34, 160, 15),
    DemoSpec("kaimon_search_config",       _build_search_config_model,      EVENTS_SEARCH_CONFIG,       130, 34,  75, 15),
    DemoSpec("kaimon_collection_manager",  _build_collection_manager_model, EVENTS_COLLECTION_MANAGER,  130, 34,  90, 15),
]

function render_demo(spec::DemoSpec, cache::Dict{String,String}; force::Bool = false)
    tach_file = joinpath(ASSETS_DIR, "$(spec.id).tach")

    # Source hash: hash this file so any edit re-renders
    src_hash = bytes2hex(sha256(read(@__FILE__, String)))

    if !force && !should_render(cache, spec.id, src_hash, tach_file)
        println("  $(spec.id): up to date (skipped)")
        return
    end

    println("  $(spec.id): rendering $(spec.frames) frames $(spec.width)×$(spec.height)…")

    try
        model = spec.model_fn()
        events = spec.events(spec.fps)
        record_app(
            model,
            tach_file;
            width = spec.width,
            height = spec.height,
            frames = spec.frames,
            fps = spec.fps,
            events = events,
        )
        println("    → $(basename(tach_file))")
        export_formats(tach_file)
        update_cache!(cache, spec.id, src_hash, tach_file)
    catch e
        @error "Failed to render $(spec.id)" exception = (e, catch_backtrace())
    end
end

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

function main()
    force = "--force" in ARGS

    mkpath(ASSETS_DIR)
    cache = load_cache()

    println("="^60)
    println("Generating Kaimon.jl doc assets")
    force && println("  (--force: regenerating all)")
    println("="^60)
    println()

    for spec in DEMOS
        render_demo(spec, cache; force)
    end

    save_cache!(cache)

    println()
    println("Assets in $(ASSETS_DIR)")
    println("="^60)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

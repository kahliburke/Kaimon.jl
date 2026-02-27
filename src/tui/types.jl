# ── TUI Types & Model ────────────────────────────────────────────────────────

struct ServerLogEntry
    timestamp::DateTime
    level::Symbol      # :debug, :info, :warn, :error
    message::String
end

struct ActivityEvent
    timestamp::DateTime
    kind::Symbol         # :tool_start, :tool_done, :stdout, :stderr
    tool_name::String    # tool name for tool events, "" for stream
    session_name::String # gate session name
    data::String         # output text for stream, time_str for tool_done
    success::Bool        # meaningful only for :tool_done
end

# ── Tool Call Results (inspectable) ──────────────────────────────────────
# Full tool call records with args + output for the Activity tab detail panel.

struct ToolCallResult
    timestamp::DateTime
    tool_name::String
    args_json::String      # JSON-encoded tool arguments
    result_text::String    # full result returned by tool handler
    duration_str::String   # "125ms" or "1.2s"
    success::Bool
    session_key::String    # 8-char short key for session routing ("" if none)
end

# ── In-Flight Tool Calls (live progress) ─────────────────────────────────────
# Tracks tool calls that are currently executing, displayed at the top of the
# Activity tab with a live elapsed timer.

mutable struct InFlightToolCall
    id::Int                  # unique monotonic ID for pairing start/done
    timestamp::Float64       # time() when started (for elapsed calculation)
    timestamp_dt::DateTime   # DateTime for display
    tool_name::String
    args_json::String
    session_key::String
    last_progress::String    # most recent progress message
    progress_lines::Vector{String}  # all progress lines for detail view
end

# ── Data types ────────────────────────────────────────────────────────────────

struct ToolCallRecord
    timestamp::DateTime
    tool_name::String
    session_name::String     # which REPL handled it
    agent_id::String         # which agent sent it
    duration_ms::Int
    success::Bool
end

# Modal flow states
@enum ConfigFlow begin
    FLOW_IDLE
    # Project onboarding (always project-scoped)
    FLOW_ONBOARD_PATH          # TextInput for project path
    FLOW_ONBOARD_CONFIRM       # Modal confirmation
    FLOW_ONBOARD_RESULT        # Success/failure feedback
    # MCP client / system config
    FLOW_CLIENT_SELECT         # Choose client
    FLOW_CLIENT_CONFIRM        # Modal confirmation
    FLOW_CLIENT_RESULT         # Success/failure feedback
end

# Stress test state machine
@enum StressState STRESS_IDLE STRESS_RUNNING STRESS_COMPLETE STRESS_ERROR

# ── Model ─────────────────────────────────────────────────────────────────────

@kwdef mutable struct KaimonModel <: Model
    quit::Bool = false
    shutting_down::Bool = false
    tick::Int = 0

    # Tabs: 1=Server, 2=Sessions, 3=Activity, 4=Config
    active_tab::Int = 1

    # REPL connections (managed by ConnectionManager)
    conn_mgr::Union{ConnectionManager,Nothing} = nothing
    selected_connection::Int = 1
    sessions_detail_scroll::Int = 0     # vertical scroll offset for the detail pane
    sessions_detail_max_scroll::Int = 0 # updated each frame by view_sessions
    _sessions_detail_area::Rect = Rect() # cached for mouse hit-testing

    # Session tab layouts (resizable)
    sessions_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(45), Fill()])
    sessions_left_layout::ResizableLayout = ResizableLayout(Vertical, [Fill(), Percent(40)])

    # Server tab layout (resizable)
    server_layout::ResizableLayout = ResizableLayout(Vertical, [Fixed(9), Fill()])

    # Config tab layouts (resizable)
    config_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(50), Fill()])
    config_left_layout::ResizableLayout = ResizableLayout(Vertical, [Fixed(8), Fill()])

    # Activity feed — unified timeline of tool calls + streaming output
    activity_feed::Vector{ActivityEvent} = ActivityEvent[]
    recent_tool_calls::Vector{ToolCallRecord} = ToolCallRecord[]
    tool_call_history::Vector{Float64} = zeros(120)  # calls per second, last 2 min

    # Tool call results — inspectable from Activity tab
    tool_results::Vector{ToolCallResult} = ToolCallResult[]
    selected_result::Int = 0       # 0 = none, 1+ = index into tool_results (newest-first)
    result_scroll::Int = 0         # vertical scroll in detail panel
    activity_layout::ResizableLayout = ResizableLayout(Vertical, [Percent(35), Fill()])
    activity_filter::String = ""   # "" = all, or session_key to filter by
    result_word_wrap::Bool = true   # word wrap in detail panel
    detail_paragraph::Union{Paragraph,Nothing} = nothing  # cached for scroll state
    _detail_for_result::Int = -1   # which selected_result the paragraph was built for
    _activity_list_widget::Union{SelectableList,Nothing} = nothing  # cached for mouse handling
    _activity_list_offset::Int = 0          # scroll offset of the SelectableList
    _activity_detail_area::Rect = Rect()   # cached inner area of detail pane

    # In-flight tool calls — currently executing, shown at top of Activity list
    inflight_calls::Vector{InFlightToolCall} = InFlightToolCall[]
    selected_inflight::Int = 0     # 0 = none selected, 1+ = index into inflight_calls (newest-first)
    activity_follow::Bool = true   # follow mode: auto-select newest entry each frame

    # Server state
    server_port::Int = 2828
    server_running::Bool = false
    server_started::Bool = false   # true once we've attempted to start
    mcp_server::Any = nothing      # MCPServer reference
    server_log::Vector{ServerLogEntry} = ServerLogEntry[]

    # Status
    total_tool_calls::Int = 0
    start_time::Float64 = time()

    # Config flow state machine
    config_flow::ConfigFlow = FLOW_IDLE
    path_input::Any = nothing              # TextInput widget, created on demand
    flow_selected::Int = 1                 # Selection index in flow lists
    flow_modal_selected::Symbol = :cancel  # For Modal confirm/cancel

    # Onboarding state
    onboard_path::String = ""

    # Client config state
    client_target::Symbol = :claude
    gate_mirror_repl::Bool = false

    # Flow result
    flow_message::String = ""
    flow_success::Bool = false

    # Client detection (populated async on tab switch)
    client_statuses::Vector{Pair{String,Bool}} = Pair{String,Bool}[]

    # Async task queue (Tachikoma pattern)
    _task_queue::TaskQueue = TaskQueue()

    # Database & analytics
    db_initialized::Bool = false
    activity_mode::Symbol = :live    # :live (current view) or :analytics (DB summary)
    analytics_cache::Any = nothing   # cached query results (NamedTuple or nothing)
    analytics_last_refresh::Float64 = 0.0

    # Dynamic health gauge timestamps
    last_tool_success::Float64 = 0.0    # time() of last successful tool call
    last_tool_error::Float64 = 0.0      # time() of last failed tool call

    # ECG heartbeat trace
    ecg_trace::Vector{Float64} = fill(0.5, 240)  # rolling Y-values, scrolls left each tick
    ecg_pending_blips::Int = 0                    # queued QRS complexes waiting to fire
    ecg_inject_countdown::Int = 0                 # countdown within current QRS injection
    ecg_last_ping_seen::DateTime = DateTime(0)    # latest last_ping we've consumed

    # Session reaping (wall-clock based, fps-independent)
    _last_reap_time::Float64 = time()

    # Background reindex: project_path → timestamp of last files_changed notification
    _reindex_pending::Dict{String,Float64} = Dict{String,Float64}()
    _reindex_first_seen::Dict{String,Float64} = Dict{String,Float64}()

    # Auto-index: tracks sessions that have already been auto-indexed on connect
    _auto_indexed_sessions::Set{String} = Set{String}()

    # Tab bar area for mouse click detection
    _tab_bar_area::Rect = Rect()
    _tab_visible_range::UnitRange{Int} = 1:7  # which tabs are currently rendered (for mouse hit + overflow)

    # Server log scroll pane
    log_pane::Union{ScrollPane,Nothing} = nothing
    log_word_wrap::Bool = false
    _log_pane_synced::Int = 0   # number of server_log entries already pushed to pane

    # Pane focus — which pane has keyboard focus on each tab
    # Tab 1: 1=status, 2=log | Tab 2: 1=gates, 2=agents, 3=detail
    # Tab 3: 1=list, 2=detail | Tab 4: 1=server, 2=actions, 3=clients
    # Tab 5: 1=form, 2=output | Tab 6: 1=runs list, 2=results
    focused_pane::Dict{Int,Int} =
        Dict(1 => 2, 2 => 1, 3 => 1, 4 => 1, 5 => 1, 6 => 1, 7 => 2)

    # ── Tests tab (tab 6) ──
    test_runs::Vector{TestRun} = TestRun[]
    selected_test_run::Int = 0             # 0 = none, 1+ = index into test_runs
    tests_layout::ResizableLayout = ResizableLayout(Horizontal, [Percent(35), Fill()])
    test_view_mode::Symbol = :results      # :results or :output (raw)
    test_follow::Bool = true               # follow mode: auto-select newest run
    test_output_pane::Union{ScrollPane,Nothing} = nothing
    _test_output_synced::Int = 0           # raw_output lines pushed to scroll pane
    test_tree_view::Union{TreeView,Nothing} = nothing
    _test_tree_synced::Int = 0             # raw_output length when tree was last built
    test_session_picker_open::Bool = false
    test_session_picker_items::Vector{@NamedTuple{label::String, project_path::String}} =
        @NamedTuple{label::String, project_path::String}[]
    test_session_picker_selected::Int = 1
    test_status_msg::String = ""           # shown in the empty-runs pane on error

    # ── Advanced tab (stress test) ──
    stress_state::StressState = STRESS_IDLE
    stress_code::String = "sleep(3); 42"
    stress_agents::String = "5"
    stress_stagger::String = "0.0"
    stress_timeout::String = "30"
    stress_session_idx::Int = 1         # selected session index
    stress_field_idx::Int = 1           # which form field has focus (1-6, 6=Run)
    stress_editing::Bool = false        # true when a form field is in edit mode
    stress_code_area::Any = nothing     # TextArea widget, created on demand
    stress_output::Vector{String} = String[]
    stress_output_lock::ReentrantLock = ReentrantLock()
    stress_scroll_pane::Union{ScrollPane,Nothing} = nothing
    stress_horde_scroll::Int = 0        # vertical scroll offset for agent horde
    stress_process::Any = nothing       # process handle for kill
    stress_result_file::String = ""     # path to written results
    advanced_layout::ResizableLayout = ResizableLayout(Vertical, [Fixed(14), Fill()])

    # ── Search tab (tab 7) ──
    search_layout::ResizableLayout =
        ResizableLayout(Vertical, [Fixed(11), Fixed(3), Fill()])
    search_qdrant_up::Bool = false
    search_ollama_up::Bool = false
    search_model_available::Bool = false
    search_collection_count::Int = 0
    search_health_last_check::Float64 = 0.0
    search_collections::Vector{String} = String[]
    search_selected_collection::Int = 1
    search_query_input::Any = nothing       # TextInput, created lazily
    search_query_editing::Bool = false
    search_results::Vector{Dict} = Dict[]
    search_results_pane::Union{ScrollPane,Nothing} = nothing
    search_chunk_type::String = "all"       # "all" / "definitions" / "windows"
    search_result_count::Int = 10
    search_embedding_model::String = "qwen3-embedding:0.6b"

    # ── Search config panel ──
    search_config_open::Bool = false
    search_config_confirm::Bool = false                # reindex confirmation sub-state
    search_config_selected::Int = 1                    # cursor in model list
    search_config_models::Vector{
        @NamedTuple{name::String, dims::Int, ctx::Int, installed::Bool}
    } = @NamedTuple{name::String, dims::Int, ctx::Int, installed::Bool}[]
    search_config_col_info::Dict = Dict()              # cached collection_info result
    search_config_reindex_paths::Vector{Pair{String,String}} = Pair{String,String}[]  # project_path => collection pairs to reindex
    search_dimension_mismatch::Bool = false             # auto-detected dimension mismatch
    search_delete_confirm::Bool = false                 # delete confirmation state
    search_detail_open::Bool = false                    # collection detail overlay open
    search_detail_info::Dict = Dict()                   # cached collection_info for detail view
    search_detail_index_state::Dict = Dict()            # cached index state for detail view
    search_detail_project_path::String = ""             # resolved project path for detail view

    # ── Collection Manager modal ──
    search_manage_open::Bool = false
    search_manage_selected::Int = 1
    search_manage_entries::Vector{
        @NamedTuple{
            label::String,
            project_path::String,
            collection::String,
            session_id::String,
            status::Symbol,
        }
    } = @NamedTuple{
        label::String,
        project_path::String,
        collection::String,
        session_id::String,
        status::Symbol,
    }[]
    search_manage_col_info::Dict{String,Dict} = Dict{String,Dict}()       # collection → Qdrant info
    search_manage_stale::Dict{String,Int} = Dict{String,Int}()            # collection → stale file count
    search_manage_op_status::Dict{String,String} = Dict{String,String}()  # collection → "Indexing..." etc.
    search_manage_confirm::Symbol = :none  # :none, :delete, :reindex

    # Collection Manager: add external project flow
    search_manage_adding::Bool = false
    search_manage_add_phase::Int = 1     # 1=path input, 2=edit config before confirm
    search_manage_path_input::Any = nothing  # TextInput
    search_manage_configuring::Bool = false
    search_manage_config_field::Int = 1  # 1=dirs, 2=exts
    search_manage_config_dirs::String = ""
    search_manage_config_exts::String = ""
    search_manage_config_path::String = ""   # project path being configured (add flow)
    search_manage_detected::@NamedTuple{
        type::String,
        dirs::Vector{String},
        extensions::Vector{String},
    } = (type = "", dirs = String[], extensions = String[])

    # ── Code staleness (Revise reload) ──
    _code_stale::Bool = false
    _code_last_check::Float64 = 0.0
    _code_last_revise::Float64 = time()  # treat startup as "fresh"
    _restart_requested::Bool = false      # unused, kept for struct stability
    _render_mode::Bool = false            # true during asset generation — disables all side effects
end

# Number of focusable panes per tab
# Tab order: 1=Server 2=Sessions 3=Activity 4=Search 5=Tests 6=Config 7=Advanced
const _PANE_COUNTS = Dict(1 => 2, 2 => 3, 3 => 2, 4 => 3, 5 => 2, 6 => 3, 7 => 3)

"""Return the border style for a pane — highlighted if focused."""
function _pane_border(m::KaimonModel, tab::Int, pane::Int)
    focused = get(m.focused_pane, tab, 1) == pane
    focused ? tstyle(:accent) : tstyle(:border)
end

"""Return the title style for a pane — highlighted if focused."""
function _pane_title(m::KaimonModel, tab::Int, pane::Int)
    focused = get(m.focused_pane, tab, 1) == pane
    focused ? tstyle(:accent, bold = true) : tstyle(:text_dim)
end

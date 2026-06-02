using Test
using KaimonGate

# ── Helpers ───────────────────────────────────────────────────────────────────

"""Save and restore global Refs around a test block."""
function with_gate_state(f;
    mode=nothing, token=nothing, tools=nothing,
    running=nothing, stream_endpoint=nothing
)
    orig_mode     = KaimonGate._MODE[]
    orig_token    = KaimonGate._AUTH_TOKEN[]
    orig_tools    = KaimonGate._SESSION_TOOLS[]
    orig_running  = KaimonGate._RUNNING[]
    orig_endpoint = KaimonGate._STREAM_ENDPOINT[]
    try
        mode             !== nothing && (KaimonGate._MODE[]            = mode)
        token            !== nothing && (KaimonGate._AUTH_TOKEN[]      = token)
        tools            !== nothing && (KaimonGate._SESSION_TOOLS[]   = tools)
        running          !== nothing && (KaimonGate._RUNNING[]         = running)
        stream_endpoint  !== nothing && (KaimonGate._STREAM_ENDPOINT[] = stream_endpoint)
        f()
    finally
        KaimonGate._MODE[]            = orig_mode
        KaimonGate._AUTH_TOKEN[]      = orig_token
        KaimonGate._SESSION_TOOLS[]   = orig_tools
        KaimonGate._RUNNING[]         = orig_running
        KaimonGate._STREAM_ENDPOINT[] = orig_endpoint
    end
end

# ── :ping → :pong ────────────────────────────────────────────────────────────
# Adapted from Kaimon gate_async_tests "pong includes stream_endpoint"

@testset ":ping → :pong" begin
    with_gate_state(mode=:ipc, token="", stream_endpoint="ipc:///tmp/test-stream.sock") do
        resp = KaimonGate.handle_message((type=:ping,))
        @test resp.type == :pong
        @test haskey(resp, :pid)
        @test resp.pid == getpid()
        @test haskey(resp, :julia_version)
        @test haskey(resp, :stream_endpoint)
        @test resp.stream_endpoint == "ipc:///tmp/test-stream.sock"
    end
end

# ── :list_tools ───────────────────────────────────────────────────────────────

@testset ":list_tools" begin
    tool = KaimonGate.GateTool("probe", (x::String) -> x)
    with_gate_state(tools=[tool]) do
        resp = KaimonGate.handle_message((type=:list_tools,))
        @test resp.type == :tools
        @test length(resp.tools) == 1
        @test resp.tools[1]["name"] == "probe"
    end
end

# ── :tool_call_async: unknown tool → :error ───────────────────────────────────
# Adapted from Kaimon gate_async_tests "unknown tool returns :error"

@testset ":tool_call_async unknown tool" begin
    with_gate_state(tools=KaimonGate.GateTool[]) do
        resp = KaimonGate.handle_message((
            type=:tool_call_async,
            name="no_such_tool",
            arguments=Dict{String,Any}(),
            request_id="req-unknown",
        ))
        @test resp.type == :error
        @test occursin("Unknown session tool", resp.message)
    end
end

# ── :tool_call_async: known tool → :accepted ─────────────────────────────────
# Adapted from Kaimon gate_async_tests "known tool returns :accepted with matching request_id"

@testset ":tool_call_async known tool" begin
    tool = KaimonGate.GateTool("noop_tool", (msg::String) -> msg)
    with_gate_state(tools=[tool]) do
        rid = "req-accepted-42"
        resp = KaimonGate.handle_message((
            type=:tool_call_async,
            name="noop_tool",
            arguments=Dict{String,Any}("msg" => "hello"),
            request_id=rid,
        ))
        @test resp.type == :accepted
        @test resp.request_id == rid
    end
end

# ── TCP auth: IPC mode skips auth ─────────────────────────────────────────────
# Adapted from Kaimon gate_async_tests "IPC mode skips auth"

@testset "TCP auth: IPC skips auth" begin
    with_gate_state(mode=:ipc, token="secret123") do
        resp = KaimonGate.handle_message((type=:ping,))
        @test resp.type == :pong
    end
end

# ── TCP auth: TCP with empty token skips auth ─────────────────────────────────

@testset "TCP auth: TCP with empty token skips" begin
    with_gate_state(mode=:tcp, token="") do
        resp = KaimonGate.handle_message((type=:ping,))
        @test resp.type == :pong
    end
end

# ── TCP auth: missing token → rejected ───────────────────────────────────────
# Adapted from Kaimon gate_async_tests "TCP mode rejects missing token"

@testset "TCP auth: missing token rejected" begin
    with_gate_state(mode=:tcp, token="secret123") do
        resp = KaimonGate.handle_message((type=:ping,))
        @test resp.type == :error
        @test occursin("Authentication", resp.message)
    end
end

# ── TCP auth: correct token accepted ─────────────────────────────────────────
# Adapted from Kaimon gate_async_tests "TCP mode accepts correct token"

@testset "TCP auth: correct token accepted" begin
    with_gate_state(mode=:tcp, token="secret123") do
        resp = KaimonGate.handle_message((type=:ping, token="secret123"))
        @test resp.type == :pong
    end
end

# ── :shutdown ─────────────────────────────────────────────────────────────────

@testset ":shutdown" begin
    # Shutdown sets _SHUTTING_DOWN and _RUNNING; restore both
    orig_shutting = KaimonGate._SHUTTING_DOWN[]
    orig_running  = KaimonGate._RUNNING[]
    try
        resp = KaimonGate.handle_message((type=:shutdown,))
        @test resp.type == :ok
        @test occursin("shutting down", resp.message)
        @test KaimonGate._SHUTTING_DOWN[] == true
        @test KaimonGate._RUNNING[] == false
    finally
        KaimonGate._SHUTTING_DOWN[] = orig_shutting
        KaimonGate._RUNNING[]       = orig_running
    end
end

# ── restart() guards ──────────────────────────────────────────────────────────
# Adapted from Kaimon gate_async_tests "Gate.restart guards"

@testset "restart() guards" begin
    orig_running = KaimonGate._RUNNING[]
    orig_restart = KaimonGate._ALLOW_RESTART[]
    try
        KaimonGate._RUNNING[] = false
        @test_throws ErrorException KaimonGate.restart()

        KaimonGate._RUNNING[]       = true
        KaimonGate._ALLOW_RESTART[] = false
        @test_throws ErrorException KaimonGate.restart()
    finally
        KaimonGate._RUNNING[]       = orig_running
        KaimonGate._ALLOW_RESTART[] = orig_restart
    end
end

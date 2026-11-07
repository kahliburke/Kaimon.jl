using Test
using KaimonGate

# ── Helpers ───────────────────────────────────────────────────────────────────

"""
Run `f` against a synthetic gate session, without binding any socket.

This used to save and restore five module Refs by hand — the same bookkeeping `_cleanup` had
to do, and just as easy to get out of step. It now builds a `GateSession`, runs the block and
puts back whatever was there. The Refs it still sets alongside are the fields whose call sites
have not moved onto the session yet.
"""
function with_gate_state(f;
    mode=nothing, token=nothing, tools=nothing,
    running=nothing, stream_endpoint=nothing
)
    KG = KaimonGate
    orig_session = KG._SESSION[]
    try
        # Every field this fixture supplies is a session field, so the constructor is the
        # whole setup and putting the old session back is the whole restore.
        KG._SESSION[] = KG.GateSession(;
            mode            = something(mode, :ipc),
            auth_token      = something(token, ""),
            tools           = something(tools, KG.GateTool[]),
            running         = something(running, false),
            stream_endpoint = something(stream_endpoint, ""),
        )
        f()
    finally
        KG._SESSION[] = orig_session
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
        @test resp.machine == KaimonGate.machine_id()
    end
end

@testset "machine_id names the kernel and is stable" begin
    id = KaimonGate.machine_id()
    @test startswith(id, string(Sys.KERNEL, ":")) && length(id) > length(string(Sys.KERNEL)) + 1
    @test KaimonGate.machine_id() == id
    # Computed afresh, it is the same: a client compares it with its own.
    KaimonGate._MACHINE_ID[] = ""
    @test KaimonGate.machine_id() == id
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

# ── agent_id threading (built-in vs external caller identification) ────────────

@testset ":tool_call threads agent_id → current_agent_id()" begin
    tool = KaimonGate.GateTool(
        "whoami",
        (marker::String) -> "$marker:" * something(KaimonGate.current_agent_id(), "NONE"),
    )
    with_gate_state(tools=[tool]) do
        r = KaimonGate.handle_message((
            type=:tool_call,
            name="whoami",
            arguments=Dict{String,Any}("marker" => "x"),
            caller="s1",
            agent_id="agent-7",
        ))
        @test r.type == :result && r.value == "x:agent-7"
        # A call with no agent_id field (external client) → current_agent_id() is nothing.
        r2 = KaimonGate.handle_message((
            type=:tool_call,
            name="whoami",
            arguments=Dict{String,Any}("marker" => "x"),
            caller="s1",
        ))
        @test r2.value == "x:NONE"
    end
end

@testset "current_agent_id outside dispatch" begin
    @test KaimonGate.current_agent_id() === nothing
    task_local_storage(:gate_agent_id, "agent-9") do
        @test KaimonGate.current_agent_id() == "agent-9"
    end
    task_local_storage(:gate_agent_id, "") do
        @test KaimonGate.current_agent_id() === nothing
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
    # Both flags :shutdown touches now live on the session, so with_gate_state dropping it
    # is the whole restore — there is nothing left to save by hand.
    with_gate_state(running=true) do
        resp = KaimonGate.handle_message((type=:shutdown,))
        @test resp.type == :ok
        @test occursin("shutting down", resp.message)
        @test KaimonGate._shutting_down() == true
        @test KaimonGate._running() == false
    end
end

# ── restart() guards ──────────────────────────────────────────────────────────
# Adapted from Kaimon gate_async_tests "Gate.restart guards"

@testset "restart() guards" begin
    # Both guards read the session now. Setting allow_restart anywhere else would let
    # restart() through, and it does not throw on the way out — it execs.
    orig_session = KaimonGate._SESSION[]
    try
        KaimonGate._SESSION[] = nothing          # no session at all ⇒ not running
        @test_throws ErrorException KaimonGate.restart()

        KaimonGate._SESSION[] =
            KaimonGate.GateSession(; running = true, allow_restart = false)
        @test_throws ErrorException KaimonGate.restart()
    finally
        KaimonGate._SESSION[] = orig_session
    end
end

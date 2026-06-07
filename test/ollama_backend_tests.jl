using ReTest
using Kaimon
using Kaimon: _map_ollama_chunk, _OllamaTurnAcc, _ollama_tools_spec, _bare_tool,
              AGENT_SELF_TOOLS, OllamaBackend, OllamaHandle, backend_start,
              backend_status, backend_pid, backend_session_id
const ACP = Kaimon.ACP

@testset "Ollama: _bare_tool" begin
    @test _bare_tool("mcp__kaimon__slate_add_cell") == "slate_add_cell"
    @test _bare_tool("ex") == "ex"
    @test _bare_tool("mcp__other_server__foo") == "foo"
end

@testset "Ollama: _map_ollama_chunk" begin
    acc = _OllamaTurnAcc()

    # text delta → streamed AgentMessageChunk(delta=true), accumulated
    evs = _map_ollama_chunk(Dict("message" => Dict("content" => "Hel"), "done" => false), acc)
    @test length(evs) == 1
    @test evs[1] isa ACP.AgentMessageChunk
    @test evs[1].delta === true
    @test evs[1].content.text == "Hel"
    _map_ollama_chunk(Dict("message" => Dict("content" => "lo"), "done" => false), acc)
    @test acc.assistant == "Hello"
    @test isempty(acc.toolcalls)

    # tool_calls fold into the accumulator (no event emitted for them)
    tc = Dict("function" => Dict("name" => "ex", "arguments" => Dict("e" => "6*7")))
    evs2 = _map_ollama_chunk(Dict("message" => Dict("content" => "", "tool_calls" => [tc])), acc)
    @test isempty(evs2)
    @test length(acc.toolcalls) == 1
    @test acc.toolcalls[1]["function"]["name"] == "ex"

    # done → usage captured, flagged done
    _map_ollama_chunk(Dict("message" => Dict("content" => ""), "done" => true,
                           "prompt_eval_count" => 11, "eval_count" => 5), acc)
    @test acc.done
    @test acc.usage.input_tokens == 11
    @test acc.usage.output_tokens == 5
    @test acc.usage.cost_usd == 0.0

    # thinking → AgentThoughtChunk
    acc2 = _OllamaTurnAcc()
    evs3 = _map_ollama_chunk(Dict("message" => Dict("thinking" => "hmm", "content" => "")), acc2)
    @test length(evs3) == 1 && evs3[1] isa ACP.AgentThoughtChunk
end

@testset "Ollama: tool-spec build + filter" begin
    tools = [
        (name = Symbol("ex"), description = "eval", parameters = Dict("type" => "object",
            "properties" => Dict("e" => Dict("type" => "string")))),
        (name = Symbol("slate_add_cell"), description = "add", parameters = Dict("type" => "object")),
        (name = Symbol("agent_open"), description = "spawn", parameters = Dict("type" => "object")),
    ]

    # default: AGENT_SELF_TOOLS filtered (recursion guard), rest kept
    spec = _ollama_tools_spec(tools, String[], copy(AGENT_SELF_TOOLS))
    names = [f["function"]["name"] for f in spec]
    @test "ex" in names
    @test "slate_add_cell" in names
    @test !("agent_open" in names)            # blocked
    @test all(f -> f["type"] == "function", spec)
    exspec = first(f for f in spec if f["function"]["name"] == "ex")
    @test haskey(exspec["function"]["parameters"], "properties")

    # allow-list narrows to just those (bare or prefixed both match)
    only_ex = _ollama_tools_spec(tools, ["mcp__kaimon__ex"], copy(AGENT_SELF_TOOLS))
    @test [f["function"]["name"] for f in only_ex] == ["ex"]

    # the `lab` preset is ["mcp__kaimon"] — a SERVER PREFIX that must match every
    # Kaimon tool (claude --allowedTools semantics), still minus the self-tools.
    lab = _ollama_tools_spec(tools, ["mcp__kaimon"], copy(AGENT_SELF_TOOLS))
    labnames = [f["function"]["name"] for f in lab]
    @test "ex" in labnames && "slate_add_cell" in labnames
    @test !("agent_open" in labnames)        # recursion guard survives the prefix allow
end

@testset "Ollama: handle is process-less" begin
    b = OllamaBackend(; model = "qwen2.5-coder", system_prompt = "hi")
    h = backend_start(b; cwd = mktempdir(), agent_id = "test-ollama-$(rand(UInt16))")
    try
        @test backend_status(h) == :alive
        @test backend_pid(h) === nothing          # no subprocess
        @test backend_session_id(h) == ""         # no vendor transcript
        @test h.messages[1]["role"] == "system"   # system prompt seeded
        @test Kaimon.current_turn(h) == 0
    finally
        Kaimon.backend_close(h)
    end
    @test backend_status(h) == :dead
end

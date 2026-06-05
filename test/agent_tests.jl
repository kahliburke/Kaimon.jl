using ReTest
using Kaimon

# Replay a sequence of stream-JSON objects through the mapper, collecting every emitted
# ACP event (mirrors what _start_reader! does line-by-line). Shares one session_id Ref.
function _agent_map_seq(objs)
    sid = Ref("")
    tool_blocks = Dict{Int,String}()
    evs = Kaimon.ACP.AgentEvent[]
    for o in objs
        append!(evs, Kaimon._map_claude_event(o, sid, tool_blocks))
    end
    evs
end

@testset "Agent session: ACP + ClaudeBackend mapping" begin

    @testset "envelope: delta flag on text/thought chunks" begin
        ACP = Kaimon.ACP
        # default = a complete, authoritative block
        e = ACP.AgentMessageChunk(ACP.TextBlock("hi"))
        @test e.delta == false
        env = ACP.envelope(e, 3)
        @test env.kind == :assistant_text
        @test env.turn == 3
        @test env.data["delta"] == false
        @test env.data["content"]["text"] == "hi"

        # explicit incremental chunk
        d = ACP.AgentMessageChunk(ACP.TextBlock("to"), true)
        @test d.delta == true
        @test ACP.envelope(d, 3).data["delta"] == true

        # thoughts carry delta the same way
        th = ACP.AgentThoughtChunk(ACP.TextBlock("hmm"), true)
        tenv = ACP.envelope(th, 1)
        @test tenv.kind == :thought
        @test tenv.data["delta"] == true
        @test ACP.AgentThoughtChunk(ACP.TextBlock("x")).delta == false
    end

    @testset "envelope: image content round-trips" begin
        ACP = Kaimon.ACP
        img = ACP.AgentMessageChunk(ACP.ImageBlock("BASE64", "image/png"))
        d = ACP.envelope(img, 1).data["content"]
        @test d["type"] == "image"
        @test d["data"] == "BASE64"
        @test d["mimeType"] == "image/png"
    end

    @testset "map complete assistant/user/result events" begin
        ACP = Kaimon.ACP
        sid = Ref("")
        # system → captures session id, emits nothing
        @test isempty(Kaimon._map_claude_event(
            Dict("type" => "system", "session_id" => "sess-1"), sid))
        @test sid[] == "sess-1"

        # assistant: text + thinking + tool_use (all complete → delta=false)
        evs = Kaimon._map_claude_event(Dict(
                "type" => "assistant",
                "message" => Dict("content" => [
                    Dict("type" => "text", "text" => "hello"),
                    Dict("type" => "thinking", "thinking" => "reasoning"),
                    Dict("type" => "tool_use", "id" => "tu1", "name" => "Read",
                         "input" => Dict("file" => "a.jl")),
                ])), sid)
        @test length(evs) == 3
        @test evs[1] isa ACP.AgentMessageChunk && evs[1].delta == false && evs[1].content.text == "hello"
        @test evs[2] isa ACP.AgentThoughtChunk && evs[2].delta == false && evs[2].content.text == "reasoning"
        @test evs[3] isa ACP.ToolCallStarted && evs[3].call.tool_call_id == "tu1" && evs[3].call.kind == :read

        # user tool_result → ToolCallUpdated (completed)
        uevs = Kaimon._map_claude_event(Dict(
                "type" => "user",
                "message" => Dict("content" => [
                    Dict("type" => "tool_result", "tool_use_id" => "tu1",
                         "is_error" => false, "content" => "ok"),
                ])), sid)
        @test length(uevs) == 1
        @test uevs[1] isa ACP.ToolCallUpdated && uevs[1].update.status == :completed

        # result → TurnEnded with usage/cost
        revs = Kaimon._map_claude_event(Dict(
                "type" => "result", "stop_reason" => "end_turn", "total_cost_usd" => 0.02,
                "usage" => Dict("input_tokens" => 100, "output_tokens" => 50)), sid)
        @test length(revs) == 1
        @test revs[1] isa ACP.TurnEnded && revs[1].stop_reason == :end_turn
        @test revs[1].usage.cost_usd == 0.02
        @test revs[1].usage.input_tokens == 100
    end

    @testset "map partial-message stream (token deltas)" begin
        ACP = Kaimon.ACP
        # Synthetic --include-partial-messages sequence:
        # content_block_start (text) → N text_delta → content_block_stop → complete assistant
        chunks = ["The", " two-state", " paramagnet"]
        seq = Any[
            Dict("type" => "stream_event",
                 "event" => Dict("type" => "content_block_start", "index" => 0,
                                 "content_block" => Dict("type" => "text", "text" => ""))),
        ]
        for c in chunks
            push!(seq, Dict("type" => "stream_event",
                "event" => Dict("type" => "content_block_delta", "index" => 0,
                                "delta" => Dict("type" => "text_delta", "text" => c))))
        end
        push!(seq, Dict("type" => "stream_event",
            "event" => Dict("type" => "content_block_stop", "index" => 0)))
        full = join(chunks)
        push!(seq, Dict("type" => "assistant",
            "message" => Dict("content" => [Dict("type" => "text", "text" => full)])))

        evs = _agent_map_seq(seq)
        deltas = [e for e in evs if e isa ACP.AgentMessageChunk && e.delta]
        finals = [e for e in evs if e isa ACP.AgentMessageChunk && !e.delta]

        # start/stop emit nothing; only the deltas + one complete block reach the bus
        @test length(evs) == length(chunks) + 1
        @test length(deltas) == length(chunks)   # acceptance: ≥2 deltas before the final
        @test length(finals) == 1
        # order preserved, and concat(deltas) == authoritative final text
        @test [d.content.text for d in deltas] == chunks
        @test join(d.content.text for d in deltas) == finals[1].content.text == full
    end

    @testset "map thinking deltas" begin
        ACP = Kaimon.ACP
        ev = Kaimon._map_claude_event(Dict("type" => "stream_event",
                "event" => Dict("type" => "content_block_delta", "index" => 0,
                                "delta" => Dict("type" => "thinking_delta",
                                                "thinking" => "because"))), Ref(""))
        @test length(ev) == 1
        @test ev[1] isa ACP.AgentThoughtChunk && ev[1].delta == true && ev[1].content.text == "because"
    end

    @testset "map tool-use input streaming" begin
        ACP = Kaimon.ACP
        # content_block_start(tool_use) → N input_json_delta → content_block_stop →
        # complete assistant tool_use (the cell's code typing in live, then authoritative)
        frags = ["{\"code\":\"", "plot(x)", "\"}"]
        seq = Any[
            Dict("type" => "stream_event",
                 "event" => Dict("type" => "content_block_start", "index" => 1,
                                 "content_block" => Dict("type" => "tool_use",
                                     "id" => "toolu_1", "name" => "slate_add_cell"))),
        ]
        for f in frags
            push!(seq, Dict("type" => "stream_event",
                "event" => Dict("type" => "content_block_delta", "index" => 1,
                                "delta" => Dict("type" => "input_json_delta", "partial_json" => f))))
        end
        push!(seq, Dict("type" => "stream_event",
            "event" => Dict("type" => "content_block_stop", "index" => 1)))
        push!(seq, Dict("type" => "assistant",
            "message" => Dict("content" => [
                Dict("type" => "tool_use", "id" => "toolu_1", "name" => "slate_add_cell",
                     "input" => Dict("code" => "plot(x)"))])))

        evs = _agent_map_seq(seq)
        # 1) the call is announced up front, before its args finish
        @test evs[1] isa ACP.ToolCallStarted
        @test evs[1].call.tool_call_id == "toolu_1"
        @test evs[1].call.status == :in_progress
        @test evs[1].call.raw_input === nothing
        # 2) input streams as ordered fragments addressed to the call
        ideltas = [e for e in evs if e isa ACP.ToolInputDelta]
        @test length(ideltas) == length(frags)
        @test all(d -> d.tool_call_id == "toolu_1", ideltas)
        @test [d.partial_json for d in ideltas] == frags
        @test join(d.partial_json for d in ideltas) == "{\"code\":\"plot(x)\"}"
        # 3) the final message attaches authoritative input as an UPDATE, not a 2nd start
        @test evs[end] isa ACP.ToolCallUpdated
        @test evs[end].update.tool_call_id == "toolu_1"
        @test evs[end].update.raw_input == Dict("code" => "plot(x)")
        @test count(e -> e isa ACP.ToolCallStarted, evs) == 1
        # envelope shape
        env = ACP.envelope(ideltas[1], 2)
        @test env.kind == :tool_input_delta
        @test env.data["toolCallId"] == "toolu_1"
        @test env.data["partialJson"] == frags[1]
    end

    @testset "ClaudeBackend: stream flag toggles --include-partial-messages" begin
        on  = Kaimon._claude_args(Kaimon.ClaudeBackend(; stream = true), ".")
        off = Kaimon._claude_args(Kaimon.ClaudeBackend(; stream = false), ".")
        @test "--include-partial-messages" in on
        @test !("--include-partial-messages" in off)
        # streaming is on by default
        @test "--include-partial-messages" in Kaimon._claude_args(Kaimon.ClaudeBackend(), ".")
    end

    @testset "image downscale (tool-result PNG)" begin
        PF = Kaimon.PNGFiles
        B64 = Kaimon.Base64
        C = Kaimon.RGBA{Kaimon.N0f8}
        # a wide 80×2000 PNG (long edge 2000, over the default 1568 cap)
        wide = [C(0.3, 0.6, 0.9, 1) for _ in 1:80, _ in 1:2000]
        io = IOBuffer(); PF.save(io, wide); b64 = B64.base64encode(take!(io))

        # default cap 1568 → box factor cld(2000,1568)=2 → long edge halved to 1000
        out = Kaimon._downscale_png_b64(b64, 1568)
        @test out != b64
        dec = PF.load(IOBuffer(B64.base64decode(out)))
        @test maximum(size(dec)) == 1000
        @test maximum(size(dec)) <= 1568

        # already within bound → byte-identical passthrough
        small = [C(0.1, 0.1, 0.1, 1) for _ in 1:50, _ in 1:50]
        io2 = IOBuffer(); PF.save(io2, small); sb64 = B64.base64encode(take!(io2))
        @test Kaimon._downscale_png_b64(sb64, 1568) == sb64

        # max_edge ≤ 0 disables; garbage never throws (returns input)
        @test Kaimon._downscale_png_b64(b64, 0) == b64
        @test Kaimon._downscale_png_b64("not-a-png", 100) == "not-a-png"

        # config reader returns a positive default
        @test Kaimon._agent_image_max_edge() isa Int && Kaimon._agent_image_max_edge() > 0
    end
end

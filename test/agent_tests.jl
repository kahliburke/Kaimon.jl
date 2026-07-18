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

        # result → TurnEnded with usage; cost is WIP/zeroed (claude's reported
        # total_cost_usd is ignored for now — see _claude_usage)
        revs = Kaimon._map_claude_event(Dict(
                "type" => "result", "stop_reason" => "end_turn", "total_cost_usd" => 0.02,
                "usage" => Dict("input_tokens" => 100, "output_tokens" => 50)), sid)
        @test length(revs) == 1
        @test revs[1] isa ACP.TurnEnded && revs[1].stop_reason == :end_turn
        @test revs[1].usage.cost_usd == 0.0   # zeroed regardless of reported cost
        @test revs[1].usage.input_tokens == 100
    end

    @testset "failed result surfaces AgentError + :refusal" begin
        ACP = Kaimon.ACP
        sid = Ref("")
        # An errored turn (e.g. API overloaded) must surface the CLI's error detail as an
        # AgentError before the terminal TurnEnded, so observers/governor can classify it.
        evs = Kaimon._map_claude_event(Dict(
                "type" => "result", "is_error" => true,
                "subtype" => "error_during_execution",
                "result" => "API Error: 429 overloaded_error",
                "usage" => Dict("input_tokens" => 10, "output_tokens" => 0)), sid)
        @test length(evs) == 2
        @test evs[1] isa ACP.AgentError
        @test occursin("overloaded", evs[1].message)
        @test evs[1].data["subtype"] == "error_during_execution"
        @test evs[1].data["is_error"] === true
        @test evs[2] isa ACP.TurnEnded && evs[2].stop_reason == :refusal
        @test evs[2].usage.input_tokens == 10   # usage still captured on failure

        # No error text → falls back to subtype for the message; clean turn → no AgentError.
        ev2 = Kaimon._map_claude_event(Dict(
                "type" => "result", "is_error" => true, "subtype" => "error_max_turns"), sid)
        @test ev2[1] isa ACP.AgentError && occursin("error_max_turns", ev2[1].message)
        ok = Kaimon._map_claude_event(Dict("type" => "result", "is_error" => false), sid)
        @test length(ok) == 1 && ok[1] isa ACP.TurnEnded && ok[1].stop_reason == :end_turn
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
        # 3) the final message re-emits the call as an authoritative tool_use carrying
        #    the full parsed input — the second tool_use for the id (replace by id)
        @test evs[end] isa ACP.ToolCallStarted
        @test evs[end].call.tool_call_id == "toolu_1"
        @test evs[end].call.raw_input == Dict("code" => "plot(x)")
        @test count(e -> e isa ACP.ToolCallStarted, evs) == 2   # announce + authoritative
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

    @testset "_spawn_argv wraps Windows shim scripts, not native exes" begin
        args = ["--model", "sonnet", "--add-dir", "C:\\a b"]
        # Windows npm shim (.cmd) → launched via cmd.exe /d /c (CreateProcess can't exec it).
        cmd = Kaimon._spawn_argv(["C:\\npm\\claude.cmd", args...], true)
        @test cmd[1:4] == ["cmd.exe", "/d", "/c", "C:\\npm\\claude.cmd"]
        @test cmd[5:end] == args                                  # original argv preserved after
        # .bat treated the same; .ps1 → PowerShell -File.
        @test Kaimon._spawn_argv(["x.bat"], true)[1:3] == ["cmd.exe", "/d", "/c"]
        @test Kaimon._spawn_argv(["x.ps1"], true)[1:5] ==
              ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
        # Native .exe on Windows → run as-is (no wrapper).
        @test Kaimon._spawn_argv(["C:\\bin\\claude.exe", args...], true) == ["C:\\bin\\claude.exe", args...]
        # Non-Windows → never wrapped, even for a .cmd-looking name.
        @test Kaimon._spawn_argv(["/usr/bin/claude", args...], false) == ["/usr/bin/claude", args...]
        @test Kaimon._spawn_argv(["weird.cmd"], false) == ["weird.cmd"]
        @test Kaimon._spawn_argv(String[], true) == String[]      # empty argv is a no-op
    end

    @testset "agent spawn error is sanitized (never leaks the environment)" begin
        # A real failed spawn raises an IOError whose text embeds `setenv(cmd, env)` — the
        # whole process environment, API keys included. The surfaced error must not contain it.
        leaky = Base.IOError(
            "could not spawn setenv(`claude -p`, [\"ANTHROPIC_API_KEY=sk-secret-XYZ\", " *
            "\"PATH=/x\"]): no such file or directory (ENOENT)", Base.UV_ENOENT)

        for win in (false, true)
            err = Kaimon._agent_spawn_error(leaky, ["claude", "-p"]; iswin = win)
            @test err isa ErrorException
            msg = sprint(showerror, err)
            @test occursin("claude", msg)              # names the CLI that failed
            @test !occursin("sk-secret-XYZ", msg)      # never the secret value
            @test !occursin("ANTHROPIC_API_KEY", msg)  # nor any env at all
        end

        # Windows ENOENT points the user at the npm-shim / native-install remedy.
        win_msg = sprint(showerror, Kaimon._agent_spawn_error(leaky, ["claude"]; iswin = true))
        @test occursin("install", lowercase(win_msg))
        # Non-Windows ENOENT gives a PATH hint, not the Windows shim spiel.
        nix_msg = sprint(showerror, Kaimon._agent_spawn_error(leaky, ["claude"]; iswin = false))
        @test occursin("PATH", nix_msg)

        # A non-ENOENT spawn failure still never leaks the env.
        other = Base.IOError(
            "could not spawn setenv(`claude`, [\"ANTHROPIC_API_KEY=sk-x\"])", Base.UV_EACCES)
        om = sprint(showerror, Kaimon._agent_spawn_error(other, ["claude"]; iswin = false))
        @test !occursin("sk-x", om)
        @test occursin("claude", om)
    end

    @testset "Utils.launch_argv resolves bare CLI names via which" begin
        U = Kaimon.Utils
        # Bare name → resolved by `which` to a .cmd shim → launched through cmd.exe.
        @test U.launch_argv(["claude", "mcp", "list"]; iswin = true,
            which = _ -> "C:\\npm\\claude.cmd") ==
            ["cmd.exe", "/d", "/c", "C:\\npm\\claude.cmd", "mcp", "list"]
        # Resolves to a native .exe → run the resolved path unwrapped.
        @test U.launch_argv(["claude"]; iswin = true, which = _ -> "C:\\bin\\claude.exe") ==
            ["C:\\bin\\claude.exe"]
        # .ps1 shim → PowerShell -File.
        @test U.launch_argv(["x"]; iswin = true, which = _ -> "C:\\x.ps1")[1:5] ==
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
        # Not found on PATH → keep the bare name (run() then errors/handled as before).
        @test U.launch_argv(["nope", "a"]; iswin = true, which = _ -> nothing) == ["nope", "a"]
        # Non-Windows → never touched, regardless of what which would return.
        @test U.launch_argv(["claude", "x"]; iswin = false, which = _ -> "C:\\claude.cmd") ==
            ["claude", "x"]
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

    @testset "MCP tool-result image content blocks" begin
        PF = Kaimon.PNGFiles
        B64 = Kaimon.Base64
        C = Kaimon.RGBA{Kaimon.N0f8}
        KG = Kaimon.KaimonGate
        png(img) = (io = IOBuffer(); PF.save(io, img); take!(io))

        # image_result builds a sentinel-tagged envelope; bytes round-trip
        small = [C(0.2, 0.4, 0.8, 1) for _ in 1:40, _ in 1:60]   # 40×60, within any cap
        sbytes = png(small)
        env = KG.image_result(sbytes; text = "hello plot")
        @test startswith(env, KG.MCP_CONTENT_SENTINEL)
        # Kaimon.image_result delegates to the same envelope
        @test Kaimon.image_result(sbytes; text = "hello plot") == env

        # _build_tool_content: plain text stays a single text block, no error
        c, e = Kaimon._build_tool_content("just text")
        @test e == false
        @test length(c) == 1 && c[1]["type"] == "text" && c[1]["text"] == "just text"

        # envelope with text + image → ordered [text, image]; small image passes through
        c, e = Kaimon._build_tool_content(env)
        @test e == false
        @test length(c) == 2
        @test c[1]["type"] == "text" && c[1]["text"] == "hello plot"
        @test c[2]["type"] == "image" && c[2]["mimeType"] == "image/png"
        dec = PF.load(IOBuffer(B64.base64decode(c[2]["data"])))
        @test size(dec) == (40, 60)   # within cap → not resized

        # image-only envelope (no text) → single image block
        c, e = Kaimon._build_tool_content(KG.image_result(sbytes))
        @test length(c) == 1 && c[1]["type"] == "image"

        # an oversized image is downscaled at egress (the cost lever): default cap 1024
        wide = [C(0.3, 0.6, 0.9, 1) for _ in 1:80, _ in 1:2000]   # long edge 2000
        c, e = Kaimon._build_tool_content(KG.image_result(png(wide)))
        big = PF.load(IOBuffer(B64.base64decode(c[1]["data"])))
        @test maximum(size(big)) <= Kaimon._tool_image_max_edge()
        @test maximum(size(big)) == 1000   # cld(2000,1024)=2 → halved

        # isError flag rides through the envelope
        errenv = KG.MCP_CONTENT_SENTINEL *
                 "{\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}"
        c, e = Kaimon._build_tool_content(errenv)
        @test e == true && c[1]["text"] == "boom"

        # malformed envelope never drops the result — falls back to text
        bad = KG.MCP_CONTENT_SENTINEL * "not json{"
        c, e = Kaimon._build_tool_content(bad)
        @test e == false && length(c) == 1 && c[1]["type"] == "text" && c[1]["text"] == bad

        # text with embedded quotes/newlines survives JSON escaping
        c, _ = Kaimon._build_tool_content(KG.image_result(sbytes; text = "a\"b\nc"))
        @test c[1]["text"] == "a\"b\nc"

        # log-safe stand-in: envelopes collapse, plain text is untouched
        @test startswith(Kaimon._tool_result_log_text(env), "[MCP rich content")
        @test Kaimon._tool_result_log_text("plain") == "plain"

        # config reader: positive Int default
        @test Kaimon._tool_image_max_edge() isa Int && Kaimon._tool_image_max_edge() > 0
    end

    @testset "control_response + cancel mapping (interrupt path)" begin
        ACP = Kaimon.ACP
        # an error ack is surfaced as an AgentError (so a rejected interrupt is visible)
        e = Kaimon._map_claude_event(Dict("type" => "control_response",
                "response" => Dict("subtype" => "error", "request_id" => "int-1",
                                   "error" => "not interruptible")), Ref(""))
        @test length(e) == 1
        @test e[1] isa ACP.AgentError && occursin("not interruptible", e[1].message)
        # a success ack needs no user-facing event
        @test isempty(Kaimon._map_claude_event(Dict("type" => "control_response",
            "response" => Dict("subtype" => "success", "request_id" => "int-2")), Ref("")))
        # a cancelled turn surfaces as result{stopReason: cancelled}
        r = Kaimon._map_claude_event(Dict("type" => "result", "stop_reason" => "cancelled"), Ref(""))
        @test r[1] isa ACP.TurnEnded && r[1].stop_reason == :cancelled
    end
end

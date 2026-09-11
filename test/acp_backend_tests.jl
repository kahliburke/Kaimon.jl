using ReTest
using HTTP
using JSON
using Kaimon
using Kaimon: _parse_acp_model, _map_acp_update, _pick_permission,
              _content_block, _locations, _tool_content, _acp_session_config,
              ACP_AGENTS, ACP_PREFIX, ACPClientBackend, _acp_decide, acp_bridge_decide
const ACP = Kaimon.ACP

@testset "ACP: _parse_acp_model" begin
    @test _parse_acp_model("acp:opencode") == (["opencode", "acp"], "")
    # The model half keeps its own separators: opencode's ids are provider/model.
    @test _parse_acp_model("acp:opencode:opencode/minimax-m3") ==
          (["opencode", "acp"], "opencode/minimax-m3")
    @test _parse_acp_model("acp:gemini:gemini-3-flash")[1] == ["gemini", "--experimental-acp"]
    @test_throws ArgumentError _parse_acp_model("acp:nosuchagent")
end

@testset "ACP: content blocks" begin
    @test _content_block(Dict("type" => "text", "text" => "hi")) == ACP.TextBlock("hi")
    img = _content_block(Dict("type" => "image", "data" => "AAA", "mimeType" => "image/png"))
    @test img isa ACP.ImageBlock && img.mime_type == "image/png"

    locs = _locations([Dict("path" => "/a.jl", "line" => 3), Dict("path" => "/b.jl"), "junk"])
    @test [(l.path, l.line) for l in locs] == [("/a.jl", 3), ("/b.jl", nothing)]

    tc = _tool_content([Dict("type" => "content", "content" => Dict("type" => "text", "text" => "ok")),
                        Dict("type" => "diff", "path" => "/x.jl", "oldText" => "a", "newText" => "b")])
    @test length(tc) == 2 && tc[1] isa ACP.ContentToolContent && tc[2] isa ACP.DiffToolContent
    @test tc[2].new_text == "b"
end

@testset "ACP: _map_acp_update" begin
    thought = _map_acp_update(Dict("sessionUpdate" => "agent_thought_chunk",
                                   "content" => Dict("type" => "text", "text" => "hmm")))
    @test length(thought) == 1 && thought[1] isa ACP.AgentThoughtChunk
    @test thought[1].content == ACP.TextBlock("hmm") && thought[1].delta

    msg = _map_acp_update(Dict("sessionUpdate" => "agent_message_chunk",
                               "content" => Dict("type" => "text", "text" => "42")))
    @test msg[1] isa ACP.AgentMessageChunk && msg[1].content == ACP.TextBlock("42")

    started = _map_acp_update(Dict("sessionUpdate" => "tool_call", "toolCallId" => "c1",
                                   "title" => "read", "kind" => "read", "status" => "pending",
                                   "locations" => [Dict("path" => "/f.jl")],
                                   "rawInput" => Dict("filePath" => "/f.jl")))
    @test started[1] isa ACP.ToolCallStarted
    call = started[1].call
    @test (call.tool_call_id, call.title, call.kind, call.status) == ("c1", "read", :read, :pending)
    @test call.locations[1].path == "/f.jl"

    # An update carries only the fields it changes; absent ones stay `nothing`
    # so a renderer can tell "unchanged" from "cleared".
    upd = _map_acp_update(Dict("sessionUpdate" => "tool_call_update",
                               "toolCallId" => "c1", "status" => "completed"))
    @test upd[1] isa ACP.ToolCallUpdated
    @test upd[1].update.status === :completed
    @test upd[1].update.title === nothing && upd[1].update.kind === nothing

    # An unrecognised kind falls back to :other rather than throwing.
    @test _map_acp_update(Dict("sessionUpdate" => "tool_call", "toolCallId" => "c",
                               "kind" => "telepathy"))[1].call.kind === :other

    plan = _map_acp_update(Dict("sessionUpdate" => "plan",
                                "entries" => [Dict("content" => "step", "priority" => "high",
                                                   "status" => "in_progress")]))
    @test plan[1] isa ACP.PlanUpdated
    @test (plan[1].entries[1].priority, plan[1].entries[1].status) == (:high, :in_progress)

    # Updates with no AgentEvent counterpart are dropped, not reported as errors.
    @test isempty(_map_acp_update(Dict("sessionUpdate" => "available_commands_update")))
    # Anything genuinely unknown must surface, or a mapping gap stays invisible.
    unknown = _map_acp_update(Dict("sessionUpdate" => "brand_new_thing"))
    @test length(unknown) == 1 && unknown[1] isa ACP.AgentError
    @test occursin("brand_new_thing", unknown[1].message)
end

@testset "ACP: usage" begin
    # Real per-turn split comes back on the session/prompt response. Reasoning
    # tokens bill like output, so they land there.
    u = Kaimon._acp_turn_usage(Dict("inputTokens" => 133, "outputTokens" => 7,
                                    "thoughtTokens" => 30, "cachedReadTokens" => 10638,
                                    "totalTokens" => 10808), 0.0042)
    @test u.input_tokens == 133
    @test u.output_tokens == 37
    @test u.cache_read_tokens == 10638
    @test u.cost_usd == 0.0042

    # No usage object at all: cost alone still counts, and nothing at all is nothing.
    @test Kaimon._acp_turn_usage(nothing, 0.01).cost_usd == 0.01
    @test Kaimon._acp_turn_usage(nothing, nothing) === nothing

    # usage_update must NOT become an event: the relay sums both UsageUpdated and
    # TurnEnded into one total, and its token figure is cumulative context, so
    # emitting it would over-count every turn.
    @test isempty(_map_acp_update(Dict("sessionUpdate" => "usage_update", "used" => 10712,
                                       "cost" => Dict("amount" => 0.0042))))
end

@testset "ACP: _pick_permission" begin
    opts = [Dict("optionId" => "b", "kind" => "reject_once"),
            Dict("optionId" => "a", "kind" => "allow_once")]
    @test _pick_permission(opts) == "a"                       # prefers a one-shot allow
    @test _pick_permission([Dict("optionId" => "z", "kind" => "weird")]) == "z"
    @test _pick_permission([]) === nothing
    @test _pick_permission(nothing) === nothing
end

@testset "ACP: bridge policy" begin
    # The point of routing decisions to Julia: entries arrive in three forms and
    # only this matcher understands them. An exact-match Set in JS blocks none.
    guarded = ACPClientBackend(; disallowed_tools = ["mcp__kaimon__agent_open"])
    @test _acp_decide(guarded, "mcp__kaimon__agent_open")["allow"] === false
    @test _acp_decide(guarded, "agent_open")["allow"] === false          # bare form
    @test _acp_decide(guarded, "kaimon_agent_open")["allow"] === false   # opencode's spelling
    @test _acp_decide(guarded, "read")["allow"] === true
    # A merely similar-looking name from elsewhere is not the guarded tool.
    @test _acp_decide(guarded, "kaimonx_agent_open")["allow"] === true

    # Server-prefix form blocks every tool from that server.
    walled = ACPClientBackend(; disallowed_tools = ["mcp__kaimon"])
    @test _acp_decide(walled, "mcp__kaimon__ex")["allow"] === false
    @test _acp_decide(walled, "write")["allow"] === true

    # The guard outranks the most permissive preset.
    @test _acp_decide(ACPClientBackend(; permission = "bypass",
                                       disallowed_tools = ["write"]), "write")["allow"] === false

    open_presets = ["default", "lab", "bypass"]
    @test all(p -> _acp_decide(ACPClientBackend(; permission = p, disallowed_tools = String[]),
                               "write")["allow"] === true, open_presets)

    # `auto` has no classifier reachable over ACP, so it refuses mutating tools
    # rather than silently behaving like `default`.
    auto = ACPClientBackend(; permission = "auto", disallowed_tools = String[])
    @test _acp_decide(auto, "write")["allow"] === false
    @test _acp_decide(auto, "read")["allow"] === true

    # An agent we can't identify gets nothing.
    @test acp_bridge_decide("no-such-agent", "read", nothing)["allow"] === false
end

@testset "ACP: bridge tokens" begin
    tok = Kaimon._acp_register_token!("agent-tok")
    @test !isempty(tok) && Kaimon._acp_token("agent-tok") == tok
    # Distinct per agent, so one agent's token can't vote for another.
    @test Kaimon._acp_register_token!("agent-other") != tok
    Kaimon._acp_forget_token!("agent-tok")
    @test Kaimon._acp_token("agent-tok") == ""
    @test Kaimon._acp_token("never-registered") == ""
    Kaimon._acp_forget_token!("agent-other")
end

@testset "ACP: per-session config" begin
    plugdir = mktempdir()
    write(joinpath(plugdir, "bridge.js"), "export const X = async () => ({})")
    write(joinpath(plugdir, "notes.md"), "not a plugin")

    b = ACPClientBackend(; model = "opencode/minimax-m3", plugin_dir = plugdir)
    dir = _acp_session_config(b, mktempdir())
    cfg = read(joinpath(dir, "opencode", "opencode.json"), String)
    @test occursin("opencode/minimax-m3", cfg)

    # `plugin/` singular — `plugins/` is what the docs say and loads nothing.
    @test readdir(joinpath(dir, "opencode", "plugin")) == ["bridge.js"]

    # No model → no key at all, so the agent keeps its own default.
    dir2 = _acp_session_config(ACPClientBackend(), mktempdir())
    @test !occursin("\"model\"", read(joinpath(dir2, "opencode", "opencode.json"), String))
    @test !isdir(joinpath(dir2, "opencode", "plugin"))
end

@testset "ACP: _acp_tool_matches" begin
    # A server prefix must not swallow the agent's own tools. This is the case
    # `_tool_name_matches` gets wrong for ACP: it would match every bare name.
    @test Kaimon._acp_tool_matches("mcp__kaimon__ex", "mcp__kaimon")
    @test !Kaimon._acp_tool_matches("write", "mcp__kaimon")
    @test !Kaimon._acp_tool_matches("read", "mcp__kaimon")

    # Qualified and bare forms of the same tool both match a qualified entry.
    @test Kaimon._acp_tool_matches("mcp__kaimon__ex", "mcp__kaimon__ex")
    @test Kaimon._acp_tool_matches("ex", "mcp__kaimon__ex")
    @test Kaimon._acp_tool_matches("mcp__kaimon__ex", "ex")

    # A different server's tool of the same name is still that tool.
    @test Kaimon._acp_tool_matches("mcp__other__ex", "ex")
    @test !Kaimon._acp_tool_matches("mcp__other__ex", "mcp__kaimon")

    # opencode spells an MCP tool `<server>_<tool>`, so the claude-style entries
    # in AGENT_SELF_TOOLS have to match that spelling too — otherwise the
    # recursion guard misses and an agent can spawn agents. Measured naming.
    @test Kaimon._acp_tool_matches("kaimon_agent_open", "mcp__kaimon__agent_open")
    @test Kaimon._acp_tool_matches("kaimon_agent_open", "mcp__kaimon")
    @test Kaimon._acp_tool_matches("kaimon_ping", "mcp__kaimon")
    @test !Kaimon._acp_tool_matches("kaimon_ping", "mcp__kaimon__agent_open")
    @test all(t -> Kaimon._acp_tool_matches(replace(t, "mcp__kaimon__" => "kaimon_"), t),
              Kaimon.AGENT_SELF_TOOLS)

    # Native names match natively, and near-misses don't.
    @test Kaimon._acp_tool_matches("write", "write")
    @test !Kaimon._acp_tool_matches("writefile", "write")
end

@testset "ACP: bridge HTTP route" begin
    # The route runs before the security gate (the plugin holds no API key), so
    # its own credential check is the only thing standing in front of a yes/no on
    # tool execution. Exercise it over real HTTP rather than trusting the wiring.
    server = Kaimon.start_mcp_server(Kaimon.MCPTool[], 0; verbose = false)
    port = server.port
    url = "http://127.0.0.1:$port/agent/permission"
    body = JSON.json(Dict("tool" => "read", "args" => nothing))
    post(hdrs) = JSON.parse(String(HTTP.post(url, hdrs, body; status_exception = false).body))
    try
        tok = Kaimon._acp_register_token!("http-agent")

        # No credential, wrong credential, and another agent's credential all fail
        # the same way — and fail closed, not open.
        Kaimon._acp_register_token!("other-agent")
        bad = [post([]),
               post(["X-Kaimon-Agent-Id" => "http-agent", "X-Kaimon-Bridge-Token" => "nope"]),
               post(["X-Kaimon-Agent-Id" => "http-agent",
                     "X-Kaimon-Bridge-Token" => Kaimon._acp_token("other-agent")])]
        @test all(v -> v["allow"] === false && v["why"] == "bad bridge credential", bad)

        # Right credential, but the agent has no live session: still no.
        ok = post(["X-Kaimon-Agent-Id" => "http-agent", "X-Kaimon-Bridge-Token" => tok])
        @test ok["allow"] === false && ok["why"] == "unknown agent"

        # A malformed body must not take the handler (or the server) down.
        junk = JSON.parse(String(HTTP.post(url,
            ["X-Kaimon-Agent-Id" => "http-agent", "X-Kaimon-Bridge-Token" => tok],
            "not json"; status_exception = false).body))
        @test junk["allow"] === false
    finally
        Kaimon._acp_forget_token!("http-agent")
        Kaimon._acp_forget_token!("other-agent")
        close(server.server)
    end
end

@testset "ACP: authoritative replay" begin
    # ACP streams deltas only. agent_run's waiter, the JSONL log and the TUI ring
    # buffer all read the non-delta copy and skip deltas, so the backend has to
    # synthesize one or the reply is invisible to every one of them.
    evs = Kaimon._authoritative_events("y = 42.", "let me think")
    @test length(evs) == 2
    @test evs[1] isa ACP.AgentThoughtChunk && evs[1].delta === false
    @test evs[2] isa ACP.AgentMessageChunk && evs[2].delta === false
    @test evs[2].content == ACP.TextBlock("y = 42.")

    # A turn with no reasoning emits only the message, and vice versa.
    @test length(Kaimon._authoritative_events("hi", "")) == 1
    @test Kaimon._authoritative_events("", "thought")[1] isa ACP.AgentThoughtChunk

    # Whitespace-only is nothing worth replaying — an empty authoritative chunk
    # would litter the log with bare markers.
    @test isempty(Kaimon._authoritative_events("", ""))
    @test isempty(Kaimon._authoritative_events("  \n ", "\t"))
end

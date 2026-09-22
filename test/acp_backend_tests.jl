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
    # An option whose kind we don't recognise is not picked. Choosing it meant granting
    # whatever it happened to mean.
    @test _pick_permission([Dict("optionId" => "z", "kind" => "weird")]) === nothing
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

@testset "ACP: a specialist allowlist outranks its preset" begin
    # The whole point of the two fields. Merged into one, a `lab` specialist carried
    # `mcp__kaimon` it never asked for and every Kaimon tool was in its world.
    spec = ACPClientBackend(; permission = "lab",
                            allowed_tools = ["mcp__kaimon__slate_dbg_step"],
                            preset_tools = ["mcp__kaimon", "fs/read_text_file"])
    @test _acp_decide(spec, "mcp__kaimon__slate_dbg_step")["allow"] === true
    @test _acp_decide(spec, "mcp__kaimon__slate_dbg_read")["allow"] === false
    @test _acp_decide(spec, "fs/read_text_file")["allow"] === false

    # With no allowlist of its own, the preset's allowances are what the agent gets.
    plain = ACPClientBackend(; permission = "lab", preset_tools = ["mcp__kaimon", "fs/read_text_file"])
    @test _acp_decide(plain, "mcp__kaimon__slate_dbg_read")["allow"] === true
    @test _acp_decide(plain, "fs/read_text_file")["allow"] === true

    # A preset allowance widens a preset that would otherwise refuse.
    strict = ACPClientBackend(; permission = "auto", disallowed_tools = String[],
                              preset_tools = ["write"])
    @test _acp_decide(strict, "write")["allow"] === true
    @test _acp_decide(strict, "bash")["allow"] === false
end

@testset "ACP: policy at the MCP boundary" begin
    # A caller that is not a Kaimon-owned agent is not judged here at all — the human's own
    # MCP session must keep working.
    @test Kaimon.agent_tool_refusal("", "ex") === nothing
    @test Kaimon.agent_tool_refusal("no-such-agent", "ex") === nothing

    # An extension tool answers to both `ns.verb` and `ns_verb`. Allowlists use the underscore
    # spelling, so a caller using the dotted one must still match — refusing it turned every
    # allowed verb into a denial the moment the canonical name was used.
    @test Kaimon._acp_tool_matches("mcp__kaimon__" * replace("slate_dbg.dbg_frame", '.' => '_'),
                                   "slate_dbg_dbg_frame")
    @test !Kaimon._acp_tool_matches("mcp__kaimon__slate_dbg.dbg_frame", "slate_dbg_dbg_frame")

    # Both doors ask through one function, and it takes the arguments as a required third one:
    # the streaming door once asked without them, so the path half of the policy applied to only
    # one of the two. A default here is what let that happen silently.
    @test Kaimon._refuse_tool_for_session(nothing, "ex", Dict()) === nothing
    @test !hasmethod(Kaimon._refuse_tool_for_session, Tuple{Nothing,String})

    resp = Kaimon._tool_refusal_response(Dict("id" => 7), "ex", "not in this agent's allowlist")
    body = JSON.parse(String(resp.body))
    @test body["id"] == 7
    @test body["result"]["isError"] === true          # a tool error, not a protocol error
    @test occursin("ex refused", body["result"]["content"][1]["text"])
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

@testset "ACP: a deny list written in CLI names matches what ACP reports" begin
    # The two sides use different conventions: a deny list names the CLI's tools the way the CLI
    # does, and an ACP agent reports its own in lower case. An exact compare made every entry in
    # AGENT_NATIVE_FILE_TOOLS miss, so the deny half of `notebook` and `specialist` enforced nothing.
    @test all(t -> Kaimon._acp_tool_matches(lowercase(t), t), Kaimon.AGENT_NATIVE_FILE_TOOLS)
    @test Kaimon._acp_tool_matches("read", "Read")
    @test Kaimon._acp_tool_matches("BASH", "Bash")
    # Case folding must not make different tools equal.
    @test !Kaimon._acp_tool_matches("read", "Write")
end

@testset "ACP: a refusal is put to the person" begin
    # The hook is how the owner of an agent supplies a human. Kaimon spawns agents and does not
    # know where anyone is looking, so without one there is nobody to ask and the answer is no.
    old = Kaimon._PERMISSION_ASK[]
    try
        ask(tool, why = "denied by policy") = Kaimon._permission_answer("a1", tool, why)

        Kaimon.set_permission_ask!(nothing)
        @test ask("Bash", "denied by policy")[1] === :deny

        Kaimon.set_permission_ask!((aid, tool, why) -> :allow)
        @test ask("Bash", "denied by policy")[1] === :allow

        Kaimon.set_permission_ask!((aid, tool, why) -> :deny)
        @test ask("Bash", "denied by policy")[1] === :deny

        # Anything that is not a clear yes is a no: a hook that times out into a default, or
        # invents an answer, must not be able to widen a policy. `:always` is in here because
        # remembering is the owner's business — saying it here grants nothing.
        denied = map((:maybe, :always, :ALLOW, nothing, 1, true)) do bad
            Kaimon.set_permission_ask!((aid, tool, why) -> bad)
            ask("Bash", "why")[1]
        end
        @test all(==(:deny), denied)

        # Spelling the yes as a string is still a yes; `Symbol` takes both.
        Kaimon.set_permission_ask!((aid, tool, why) -> "allow")
        @test ask("Bash", "why")[1] === :allow

        # A hook that throws denies, and says so rather than failing silently.
        Kaimon.set_permission_ask!((aid, tool, why) -> error("the panel is gone"))
        d, err = ask("Bash", "why")
        @test d === :deny && occursin("the panel is gone", err)

        # No memory here. "Always" is a statement about a role or a project, and an agent id is
        # neither, so the hook is asked every time and decides for itself what to remember.
        asked = Ref(0)
        Kaimon.set_permission_ask!((aid, tool, why) -> (asked[] += 1; :allow))
        @test ask("WebFetch", "why")[1] === :allow
        @test ask("WebFetch", "why")[1] === :allow
        @test asked[] == 2

        # What it is asked ABOUT is the tool and the reason, so an owner can key consent on either.
        seen = Ref(("", "", ""))
        Kaimon.set_permission_ask!((aid, tool, why) -> (seen[] = (aid, tool, why); :allow))
        ask("WebFetch", "denied by policy: WebFetch")[1]
        @test seen[] == ("a1", "WebFetch", "denied by policy: WebFetch")

        # An agent with no id cannot be attributed a decision, so it is not asked for one.
        @test Kaimon._permission_answer("", "Bash", "w")[1] === :deny
    finally
        Kaimon.set_permission_ask!(old)
    end
end

@testset "ACP: _denied_tool" begin
    function b(p)
        mode, allow, deny, _ = Kaimon._permission_preset(p)
        Kaimon.ACPClientBackend(; argv = ["true"], permission = p,
                                disallowed_tools = deny, preset_tools = allow)
    end
    tc(; title = "", kind = "") = Dict{String,Any}("title" => title, "kind" => kind)

    # A preset with no deny list reaches none of this, whatever the call looks like.
    for p in ("default", "lab", "auto", "bypass")
        @test isempty(Kaimon._permission_preset(p)[3])
        @test Kaimon._denied_tool(b(p), tc(title = "Read src/x.jl", kind = "read")) === nothing
    end

    # `notebook` and `specialist` deny the CLI's own file and shell tools. The title names one.
    for p in ("notebook", "specialist")
        @test Kaimon._denied_tool(b(p), tc(title = "Read src/x.jl", kind = "read")) !== nothing
        @test Kaimon._denied_tool(b(p), tc(title = "Bash", kind = "execute")) !== nothing
        # No usable title: the category is what every agent reports the same way.
        @test Kaimon._denied_tool(b(p), tc(kind = "execute")) !== nothing
        @test Kaimon._denied_tool(b(p), tc(kind = "edit")) !== nothing
        # A kind no denied tool stands for is not refused by accident.
        @test Kaimon._denied_tool(b(p), tc(kind = "think")) === nothing
        @test Kaimon._denied_tool(b(p), tc()) === nothing
        # An MCP call is decided at the MCP door, where the real name is known. Refusing one here on
        # its category would deny `notebook` the very tools it allows.
        @test Kaimon._denied_tool(b(p), tc(title = "mcp__kaimon__slate_read", kind = "read")) === nothing
        @test Kaimon._denied_tool(b(p), tc(title = "slate.read", kind = "read")) === nothing
    end
end

@testset "ACP: session/new hands the agent its own deny list" begin
    # The ask-time check cannot see a read the agent never asks about, so the list goes to the
    # agent as well. claude-agent-acp spreads `_meta.claudeCode.options` into its SDK query.
    for p in ("notebook", "specialist")
        b = ACPClientBackend(; argv = ["true"], permission = p,
                             disallowed_tools = Kaimon._permission_preset(p)[3])
        m = Kaimon._acp_session_meta(b)
        deny = m["_meta"]["claudeCode"]["options"]["disallowedTools"]
        @test "Read" in deny && "Bash" in deny
        @test Set(deny) == Set(Kaimon.AGENT_NATIVE_FILE_TOOLS)
    end
    # Nothing to say, nothing sent: a preset with no deny list must not start naming tools.
    for p in ("lab", "auto", "bypass")
        b = ACPClientBackend(; argv = ["true"], permission = p,
                             disallowed_tools = Kaimon._permission_preset(p)[3])
        @test isempty(Kaimon._acp_session_meta(b))
    end
    # The recursion guard is a deny list too, and it travels the same way.
    b = ACPClientBackend(; argv = ["true"])
    @test haskey(Kaimon._acp_session_meta(b), "_meta")
end

@testset "ACP: the bounded presets load no settings of their own" begin
    opts(p; deny = Kaimon._permission_preset(p)[3]) =
        get(get(get(Kaimon._acp_session_meta(
            ACPClientBackend(; argv = ["true"], permission = p, disallowed_tools = deny)),
            "_meta", Dict()), "claudeCode", Dict()), "options", Dict())

    # A deny list names tools. The MCP servers the machine's settings declare are not tools we can
    # name, and calls to them never reach Kaimon — so the two presets that claim to bound the
    # toolset load no settings at all.
    for p in ("notebook", "specialist")
        @test opts(p)["settingSources"] == String[]
        @test opts(p)["strictMcpConfig"] === true
    end
    # Every other preset keeps the agent's own settings, CLAUDE.md included.
    for p in ("lab", "auto", "bypass", "default")
        @test !haskey(opts(p; deny = ["mcp__kaimon__agent_open"]), "settingSources")
        @test !haskey(opts(p; deny = ["mcp__kaimon__agent_open"]), "strictMcpConfig")
    end
    # The recursion guard still travels for all of them.
    @test opts("lab"; deny = ["mcp__kaimon__agent_open"])["disallowedTools"] == ["mcp__kaimon__agent_open"]
end

@testset "ACP: the tool-path lookaside evicts its oldest, not all of it" begin
    seen, order = Dict{String,Vector{String}}(), String[]
    for i in 1:6
        Kaimon._remember_path!(seen, order, "t$i", ["/w/$i.jl"]; cap = 4)
    end
    # The cap holds and the NEWEST survive. Emptying at the cap took the paths of calls that had
    # not been asked about yet, and a permission request that finds no path is allowed — so the
    # workspace boundary lapsed for everything in flight, once per cap.
    @test length(seen) == 4 && length(order) == 4
    @test !haskey(seen, "t1") && !haskey(seen, "t2")
    @test seen["t6"] == ["/w/6.jl"] && seen["t3"] == ["/w/3.jl"]

    # Re-recording an id updates it in place: a tool_call_update follows its tool_call, and
    # counting the same call twice would evict a live entry early.
    Kaimon._remember_path!(seen, order, "t6", ["/w/6b.jl"]; cap = 4)
    @test length(order) == 4 && seen["t6"] == ["/w/6b.jl"]
    @test count(==("t6"), order) == 1
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

    # The CLI's own subagent spawner is in the guard under both names it has gone by. Without it
    # the guard covered only the route through Kaimon, and an agent denied every file tool still
    # had `Agent` to spawn one that was not.
    @test all(t -> t in Kaimon.AGENT_SELF_TOOLS, ("Agent", "Task", "Workflow"))
    @test Kaimon._acp_tool_matches("Agent", "Agent")
    @test Kaimon._acp_tool_matches("agent", "Agent")     # whatever case the agent reports it in
    @test !Kaimon._acp_tool_matches("agent_open", "Agent")
    # Skill is left out on purpose: it is how a project packages its own workflows, and a caller
    # who wants it closed says so. Asserted so removing it from the list is a decision, not a drift.
    @test !("Skill" in Kaimon.AGENT_SELF_TOOLS)

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

# ── against a fake agent ──────────────────────────────────────────────────────────────────────
# These exercise what the CLIENT does when an agent misbehaves, which is the whole subject of the
# reader-task change and is unreachable with a real agent: you cannot ask opencode to read a named
# pipe on command, or to race a permission prompt against an update.
include("acp_fake_agent.jl")

const _HAVE_NODE = try; success(`node --version`); catch; false; end

# The FIFO case needs more than one OS thread, and fails by WEDGING rather than by failing: the
# blocking handler stalls the only thread, nothing else is scheduled, and the process then
# survives SIGTERM so even a `timeout` wrapper leaves it behind. Measured on this suite:
#
#   -t 1     (1 default, 0 interactive, 1 OS thread)   hangs
#   default  (1 default, 1 interactive, 2 OS threads)  passes
#   -t 1,1   (1 default, 1 interactive, 2 OS threads)  passes
#   -t 2     (2 default, 1 interactive, 3 OS threads)  passes
#
# The hub spawns Kaimon with no `--threads`, so it is the `default` row. Skip rather than wedge if
# someone runs the suite under `-t 1`, since a hang is the least informative way to learn this.
const _OS_THREADS = Threads.nthreads() + Threads.nthreads(:interactive)

if !_HAVE_NODE
    @info "skipping ACP fake-agent tests: node not on PATH"
elseif _OS_THREADS < 2
    @info "skipping ACP fake-agent tests: need >1 OS thread, have $_OS_THREADS (try -t 1,1)"
else
@testset "ACP: a blocking client request does not stall the stream" begin
    # A slow client request must not stop the reader, or the update after it never arrives and every
    # call in flight times out.
    #
    # The block is a permission hook that sleeps, NOT a read of a FIFO. A FIFO blocks inside the
    # `open` syscall, where the thread never reaches a GC safepoint, so the next collection waits
    # for a world that cannot stop and the whole test process wedges past SIGTERM. That is the
    # hazard `_acp_require_regular_file` now refuses outright (see below); reproducing it here only
    # ever risked the suite. A sleeping hook blocks the handler just as well and yields.
    released = Channel{Nothing}(1)
    Kaimon.set_permission_ask!((aid, tool, why) -> (take!(released); :deny))
    try
        with_fake_agent(cwd = mktempdir(), steps = Any[
                Dict("request" => Dict("method" => "session/request_permission",
                                       "params" => Dict("sessionId" => "fake-session",
                                                        "toolCall" => Dict("toolCallId" => "tc1",
                                                                           "rawInput" => Dict("path" => "/etc/passwd")),
                                                        "options" => Any[Dict("optionId" => "n",
                                                                              "name" => "Reject",
                                                                              "kind" => "reject_once")]))),
                Dict("send" => Dict("jsonrpc" => "2.0", "method" => "session/update",
                                    "params" => Dict("sessionId" => "fake-session",
                                                     "update" => Dict("sessionUpdate" => "agent_message_chunk",
                                                                      "content" => Dict("type" => "text",
                                                                                        "text" => "still here"))))),
            ]) do h
            # The update must arrive while the permission handler is still parked in the hook. A
            # handler on the reader task would block it, so this event could not be processed at
            # all: "it was merely fast" is not an available explanation.
            evs = drain_events(h; n = 2, timeout = 8.0)
            @test any(e -> e isa ACP.AgentMessageChunk, evs)
        end
    finally
        put!(released, nothing)              # let the parked handler finish
        Kaimon.set_permission_ask!(nothing)
    end
end

@testset "ACP: a path that would block forever is refused, not opened" begin
    # `open` on a FIFO blocks in the syscall, and a thread parked there never reaches a GC
    # safepoint — so the next collection waits for a world that cannot stop and the HOST wedges.
    # Handling the request off the reader task saves the connection and cannot save the process.
    # The check is a `stat`, so it cannot block on the thing it is inspecting.
    dir = mktempdir()
    regular = joinpath(dir, "ok.txt")
    write(regular, "hello")
    @test Kaimon._acp_require_regular_file(regular) == regular

    @test_throws ArgumentError Kaimon._acp_require_regular_file(joinpath(dir, "nope.txt"))
    @test_throws ArgumentError Kaimon._acp_require_regular_file(dir)          # a directory
    if !Sys.iswindows()
        fifo = joinpath(dir, "pipe")
        run(`mkfifo $fifo`)
        # No `open` anywhere in this assertion, which is the whole point.
        @test_throws ArgumentError Kaimon._acp_require_regular_file(fifo)
        @test isfifo(stat(fifo))                                             # still there, untouched
    end
end

@testset "ACP: a permission prompt keeps its place in the stream" begin
    # Regression for the ordering bug the spawn fix introduced: emitted from the spawned half, a
    # PermissionRequested could be overtaken by updates the reader kept consuming.
    with_fake_agent(steps = Any[
            Dict("request" => Dict("method" => "session/request_permission",
                                   "params" => Dict("sessionId" => "fake-session",
                                                    "toolCall" => Dict("toolCallId" => "tc1"),
                                                    "options" => Any[Dict("optionId" => "y",
                                                                          "name" => "Allow",
                                                                          "kind" => "allow_once")]))),
            Dict("send" => Dict("jsonrpc" => "2.0", "method" => "session/update",
                                "params" => Dict("sessionId" => "fake-session",
                                                 "update" => Dict("sessionUpdate" => "agent_message_chunk",
                                                                  "content" => Dict("type" => "text",
                                                                                    "text" => "after"))))),
        ]) do h
        evs = drain_events(h; n = 2, timeout = 8.0)
        ip = findfirst(e -> e isa ACP.PermissionRequested, evs)
        ic = findfirst(e -> e isa ACP.AgentMessageChunk, evs)
        @test ip !== nothing && ic !== nothing
        @test ip < ic
    end
end

@testset "ACP: a malformed permission payload does not kill the reader" begin
    with_fake_agent(steps = Any[
            # `options` a string rather than an array: the announce must survive it.
            Dict("request" => Dict("method" => "session/request_permission",
                                   "params" => Dict("sessionId" => "fake-session",
                                                    "options" => "not-an-array"))),
            Dict("send" => Dict("jsonrpc" => "2.0", "method" => "session/update",
                                "params" => Dict("sessionId" => "fake-session",
                                                 "update" => Dict("sessionUpdate" => "agent_message_chunk",
                                                                  "content" => Dict("type" => "text",
                                                                                    "text" => "alive"))))),
        ]) do h
        evs = drain_events(h; n = 3, timeout = 8.0)
        @test any(e -> e isa ACP.AgentMessageChunk, evs)
    end
end

@testset "ACP: the handshake reply is kept" begin
    caps = Dict("_meta" => Dict("claudeCode" => Dict("promptQueueing" => true)),
                "sessionCapabilities" => Dict("fork" => true))
    with_fake_agent(caps = caps) do h
        @test Kaimon.acp_queues_prompts(h)
        @test get(Kaimon.acp_capabilities(h), "protocolVersion", nothing) == 1
        @test get(get(Kaimon.acp_capabilities(h), "session", Dict()), "sessionId", "") == "fake-session"
    end
    with_fake_agent(caps = Dict{String,Any}()) do h
        @test !Kaimon.acp_queues_prompts(h)   # absent capability is not queueing
    end
end

@testset "ACP: a reply whose caller gave up does not kill the reader" begin
    # `_rpc_call!` closes its reply channel when the call times out, and the entry can still be in
    # `pending` when the reply lands. A `put!` on the closed channel is not scoped to the line that
    # raised it: it leaves the read loop, so one late reply declared the agent dead while its
    # process was healthy and released every other call in flight.
    with_fake_agent(steps = Any[
            Dict("send" => Dict("jsonrpc" => "2.0", "id" => 99_999, "result" => Dict())),
            Dict("send" => Dict("jsonrpc" => "2.0", "method" => "session/update",
                                "params" => Dict("sessionId" => "fake-session",
                                                 "update" => Dict("sessionUpdate" => "agent_message_chunk",
                                                                  "content" => Dict("type" => "text",
                                                                                    "text" => "after"))))),
        ]) do h
        stale = Channel{Any}(1)
        close(stale)
        lock(h.lk) do; h.pending[99_999] = stale; end
        drain_events(h; n = 20, timeout = 1.5)          # clear the handshake run of the script
        Kaimon.backend_send(h, "go")                    # runs the script again, now with the entry in
        # TurnStarted, the chunk, its authoritative replay, TurnEnded.
        evs = drain_events(h; n = 4, timeout = 6.0)
        @test !istaskdone(h.reader)
        @test Kaimon.backend_status(h) === :alive
        # The update AFTER the stale reply still arrived, so the reader kept going rather than
        # merely surviving with the loop broken.
        @test any(e -> e isa ACP.AgentMessageChunk && e.content isa ACP.TextBlock &&
                       occursin("after", e.content.text), evs)
        @test !any(e -> e isa ACP.AgentError && occursin("reader crashed", e.message), evs)
    end
end

@testset "ACP: the workspace boundary holds at whichever door the tool uses" begin
    # Both `tools/call` doors ask `_refuse_tool_for_session`. The streaming one used to ask without
    # the arguments, which left the name check running and the path check not — for `ex`,
    # `run_tests`, `grep_code`, `start_session` and every extension tool, since those are exactly
    # the ones that stream.
    ws = mktempdir()
    mkpath(joinpath(ws, "sub"))
    with_fake_agent(cwd = ws) do h
        aid = h.agent_id
        s = Kaimon.AgentSession(aid, h.backend, h, h.cwd, "acp:fake", :alive,
                                Task(() -> nothing), time(), time(), ACP.Usage(),
                                Any[], String[], String[], ReentrantLock())
        lock(Kaimon.AGENT_SESSIONS_LOCK) do; Kaimon.AGENT_SESSIONS[aid] = s; end
        try
            @test Kaimon.agent_tool_refusal(aid, "grep_code", Dict("path" => "sub")) === nothing
            for outside in ("/etc", joinpath(ws, "..", "elsewhere"))
                why = Kaimon.agent_tool_refusal(aid, "grep_code", Dict("path" => outside))
                @test why !== nothing && occursin("outside this agent's workspace", why)
            end
            # A `cwd` argument is a path too, whatever the tool calls it.
            @test Kaimon.agent_tool_refusal(aid, "start_session", Dict("cwd" => "/etc")) !== nothing
            # Without the arguments there is nothing to confine, which is the shape of the bug.
            @test Kaimon.agent_tool_refusal(aid, "grep_code") === nothing
        finally
            lock(Kaimon.AGENT_SESSIONS_LOCK) do; delete!(Kaimon.AGENT_SESSIONS, aid); end
        end
    end
end

@testset "ACP: a preset that cannot reach native tools says so at spawn" begin
    # The fake agent is neither opencode nor an agent publishing the `claudeCode` extension, so
    # `notebook` binds its own Read and Bash nowhere. Silence there read as configured.
    with_fake_agent(permission = "notebook") do h
        gap = Kaimon._acp_enforcement_gap(h)
        @test gap !== nothing
        @test occursin("deny list", gap)
        # Emitted during the handshake, so it is already on the channel.
        evs = drain_events(h; n = 1, timeout = 4.0)
        @test any(e -> e isa ACP.AgentError && occursin("bridge plugin", e.message), evs)
    end
    # An agent that publishes the extension read the deny list handed to `session/new`.
    with_fake_agent(permission = "notebook",
                    caps = Dict("_meta" => Dict("claudeCode" => Dict()))) do h
        @test Kaimon._acp_enforcement_gap(h) === nothing
    end
    # `default` denies nothing native beyond the stock recursion guard, so there is no claim to
    # qualify and no notice — otherwise every spawn carries one and it stops being read.
    with_fake_agent(permission = "default") do h
        @test Kaimon._acp_enforcement_gap(h) === nothing
    end
    # A caller who named a native tool themselves asked for the same thing a preset does.
    with_fake_agent(permission = "default",
                    disallowed_tools = vcat(Kaimon.AGENT_SELF_TOOLS, "Bash")) do h
        gap = Kaimon._acp_enforcement_gap(h)
        @test gap !== nothing && occursin("Bash", gap)
    end
end
end  # _HAVE_NODE

@testset "ACP: workspace containment compares path components" begin
    # A string-prefix test reads a sibling whose name merely starts with the root as inside it.
    @test Kaimon._path_within("/ws", "/ws")
    @test Kaimon._path_within("/ws", "/ws/src/a.jl")
    @test !Kaimon._path_within("/ws", "/ws-evil/secret")
    @test !Kaimon._path_within("/ws", "/other")
    # A shorter path cannot contain the root.
    @test !Kaimon._path_within("/ws/src", "/ws")

    # Componentwise so the separator is whatever the platform uses. On Windows a check written
    # against "/" matches nothing, which refuses every in-workspace path rather than admitting a
    # wrong one — a boundary that denies everything is still a broken boundary.
    if Sys.iswindows()
        @test Kaimon._path_within("C:\\ws", "C:\\ws\\src\\a.jl")
        @test !Kaimon._path_within("C:\\ws", "C:\\ws-evil\\a.jl")
        @test Kaimon._path_within("C:\\WS", "C:\\ws\\a.jl")   # case-insensitive filenames
    end

    # End to end through the real resolution, with a workspace on disk.
    mktempdir() do ws
        mkpath(joinpath(ws, "sub"))
        write(joinpath(ws, "sub", "f.jl"), "x")
        @test Kaimon._confine_to(ws, "sub/f.jl") == realpath(joinpath(ws, "sub", "f.jl"))
        # A file that does not exist yet still resolves, since writing one is legitimate.
        @test Kaimon._confine_to(ws, "sub/new.jl") == joinpath(realpath(ws), "sub", "new.jl")
        @test_throws ArgumentError Kaimon._confine_to(ws, "../outside.jl")
        @test_throws ArgumentError Kaimon._confine_to(ws, "/etc/passwd")
        @test_throws ArgumentError Kaimon._confine_to(ws, "")
        # A symlink inside the workspace pointing out of it is resolved before the check, so it
        # cannot be used as a step outside.
        if !Sys.iswindows()
            link = joinpath(ws, "escape")
            symlink("/etc", link)
            @test_throws ArgumentError Kaimon._confine_to(ws, "escape/passwd")
        end
    end
end

@testset "ACP: a working directory is a path" begin
    # A tool naming a `cwd` outside the workspace would otherwise pass a check that only looks
    # for keys spelled "path".
    paths(d) = Kaimon._tool_call_paths(Dict{String,Any}("rawInput" => d))
    @test paths(Dict("cwd" => "/tmp")) == ["/tmp"]
    @test paths(Dict("directory" => "/tmp")) == ["/tmp"]
    @test paths(Dict("dir" => "/tmp")) == ["/tmp"]
    @test paths(Dict("file_path" => "a.jl")) == ["a.jl"]
    @test paths(Dict("notebook_path" => "n.jl")) == ["n.jl"]
    @test sort(paths(Dict("edits" => ["a.jl", "b.jl"], "command" => "ls"))) == String[]
    @test sort(paths(Dict("paths" => ["a.jl", "b.jl"]))) == ["a.jl", "b.jl"]
    # A shell command is not a path and is not treated as one; see agent_tool_refusal.
    @test paths(Dict("command" => "cat /etc/passwd")) == String[]
end

@testset "ACP: the read cap refuses rather than guessing a size" begin
    # `filesize` reports 0 for a missing file rather than throwing, so that case surfaces from the
    # read itself. What matters is that it raises instead of yielding an empty string.
    @test_throws Exception Kaimon._acp_read_capped(joinpath(mktempdir(), "nope.txt"))
    mktempdir() do d
        f = joinpath(d, "small.txt")
        write(f, "hello")
        @test Kaimon._acp_read_capped(f) == "hello"
    end
    # A size that cannot be determined is a cap that cannot be enforced, so `_acp_read_capped`
    # refuses. Hard to provoke portably (it needs `filesize` itself to fail), so the contract is
    # recorded here rather than exercised: what it must not do is treat the failure as 0 bytes and
    # read on, which admitted exactly the files the cap exists for.
    @test Kaimon.ACP_READ_CAP == 8 * 1024 * 1024
end

@testset "ACP: a spawn that fails names the agent's sign-in methods" begin
    # `initialize` succeeds for an agent nobody is logged into; `session/new` is where it shows up,
    # worded by the agent, and that wording need not mention logging in at all.
    boom = ErrorException("ACP session/new failed: tier ineligible")

    # Nothing advertised: the agent's own error is passed through untouched.
    @test Kaimon._acp_auth_hint(Dict{String,Any}(), boom) === boom

    caps = Dict{String,Any}("authMethods" => Any[
        Dict("id" => "oauth-personal", "name" => "Log in with Google"),
        Dict("id" => "gemini-api-key", "name" => "Use Gemini API key"),
    ])
    msg = sprint(showerror, Kaimon._acp_auth_hint(caps, boom))
    @test occursin("tier ineligible", msg)          # the agent's own words are kept
    @test occursin("oauth-personal (Log in with Google)", msg)
    @test occursin("gemini-api-key", msg)
    @test occursin("does not log agents in", msg)

    # A malformed entry must not cost the rest of the list, or the whole hint.
    mixed = Dict{String,Any}("authMethods" => Any["junk", Dict("id" => "vertex-ai")])
    @test occursin("vertex-ai", sprint(showerror, Kaimon._acp_auth_hint(mixed, boom)))
    # Nothing usable in it at all falls back to the agent's error.
    @test Kaimon._acp_auth_hint(Dict{String,Any}("authMethods" => Any["junk"]), boom) === boom
end

@testset "ACP: an MCP call is left to the MCP door in both its spellings" begin
    # `_denied_tool` judges a native call and must not judge an MCP one, whose real name is known
    # elsewhere. opencode names Kaimon's tools `kaimon_<tool>`, which carries none of the
    # punctuation a `mcp__kaimon__<tool>` name does — so a `read`-category Kaimon call fell through
    # to the category check, where `read` maps onto `Read`, which `notebook` denies.
    deny = copy(Kaimon.AGENT_NATIVE_FILE_TOOLS)
    b = ACPClientBackend(; permission = "notebook", disallowed_tools = deny)
    @test Kaimon._denied_tool(b, Dict("title" => "kaimon_grep_code", "kind" => "read")) === nothing
    @test Kaimon._denied_tool(b, Dict("title" => "mcp__kaimon__grep_code", "kind" => "read")) === nothing
    # The native tools it exists to refuse still are, by title and by category.
    @test Kaimon._denied_tool(b, Dict("title" => "Read src/a.jl", "kind" => "read")) !== nothing
    @test Kaimon._denied_tool(b, Dict("title" => "Terminal", "kind" => "execute")) !== nothing
end

@testset "ACP: a token figure cannot decide what the turn did" begin
    # `Int(x)` is the strict reading, and this runs while `TurnEnded` is being built — so a
    # fractional or non-numeric count throws into the handler that reports a turn as FAILED, and a
    # completed turn comes out as a refusal over a number nothing depends on.
    @test Kaimon._token_count(12) == 12
    @test Kaimon._token_count(12.0) == 12
    @test Kaimon._token_count(12.7) == 13
    @test Kaimon._token_count("12") == 12
    @test Kaimon._token_count("lots") == 0
    @test Kaimon._token_count(nothing) == 0
    @test Kaimon._token_count(NaN) == 0
    u = Kaimon._acp_turn_usage(Dict("inputTokens" => 10.0, "outputTokens" => 2,
                                    "thoughtTokens" => "3", "cachedReadTokens" => nothing), 0.5)
    @test u.input_tokens == 10
    @test u.output_tokens == 5          # output + reasoning, which bills like output
    @test u.cache_read_tokens == 0
    @test u.cost_usd == 0.5
end

@testset "ACP: a generated config keeps the user's providers and not their MCP servers" begin
    # The generated file replaces the user's, since XDG_CONFIG_HOME points at it. `provider` says
    # how to reach a model and grants no tool, and without it `model` can only name something
    # opencode ships with — a locally served model becomes unselectable. `mcp` is the opposite: an
    # inherited server is one Kaimon did not attach, so its calls carry no agent id and no preset
    # reaches them.
    home = mktempdir()
    mkpath(joinpath(home, "opencode"))
    write(joinpath(home, "opencode", "opencode.json"), JSON.json(Dict(
        "provider" => Dict("ollama" => Dict("npm" => "@ai-sdk/openai-compatible")),
        "mcp" => Dict("kaimon" => Dict("type" => "remote", "url" => "http://localhost:2828/mcp")),
        "theme" => "tokyonight")))
    cfg = withenv("XDG_CONFIG_HOME" => home) do
        dir = _acp_session_config(ACPClientBackend(; model = "ollama/qwen2.5:14b"), mktempdir())
        JSON.parse(read(joinpath(dir, "opencode", "opencode.json"), String))
    end
    @test haskey(get(cfg, "provider", Dict()), "ollama")
    @test cfg["model"] == "ollama/qwen2.5:14b"
    @test !haskey(cfg, "mcp")
    @test !haskey(cfg, "theme")   # nothing else rides along by accident

    # No user config at all is not an error, it is the common case.
    empty_home = mktempdir()
    cfg2 = withenv("XDG_CONFIG_HOME" => empty_home) do
        dir = _acp_session_config(ACPClientBackend(), mktempdir())
        JSON.parse(read(joinpath(dir, "opencode", "opencode.json"), String))
    end
    @test !haskey(cfg2, "provider")
end

@testset "ACP: only the agent whose config was generated gets it" begin
    # `XDG_CONFIG_HOME` points at the generated directory, so generating one for an agent that
    # reads a different layout replaced its own settings directory with an empty one.
    dir = _acp_session_config(ACPClientBackend(; argv = ["gemini", "--experimental-acp"],
                                              model = "gemini-3-flash"), mktempdir())
    @test !isdir(joinpath(dir, "opencode"))
    @test isempty(readdir(dir))
end

@testset "credentials come from the OS entropy source and compare in constant time" begin
    # Seedability is the one property a credential must not have, so these must not come from the
    # default task-local generator.
    a, b = Kaimon.secret_bytes(32), Kaimon.secret_bytes(32)
    @test length(a) == 32 && a != b
    k1, k2 = Kaimon.generate_api_key(), Kaimon.generate_api_key()
    @test startswith(k1, "kaimon_") && length(k1) == length("kaimon_") + 40 && k1 != k2

    @test Kaimon.secrets_equal("abc", "abc")
    @test !Kaimon.secrets_equal("abc", "abd")
    @test !Kaimon.secrets_equal("abc", "abcd")      # length differs
    @test !Kaimon.secrets_equal("", "a")
    @test Kaimon.secrets_equal("", "")
    # Equal-length mismatches must not short-circuit on the first differing byte; the result is
    # all that is observable from here, so this pins the contract rather than the timing.
    @test !Kaimon.secrets_equal("a" * "x"^31, "a" * "y"^31)
end

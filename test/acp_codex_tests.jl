using ReTest, Kaimon, JSON

@testset "ACP: Codex inherited MCP isolation" begin
    # User alias, project alias, and an exact collision. None has an owning-agent header.
    inherited = Dict(n => Dict{String,Any}("url" => "http://localhost:2828/mcp")
                     for n in ("Kaimon", "project_alias", "kaimon"))
    b = Kaimon.ACPClientBackend(; argv = ["codex-acp"], permission = "notebook",
        preset_tools = ["mcp__kaimon"], mcp_servers = Any[Dict(
            "name" => "kaimon", "type" => "http", "url" => "http://localhost:2828/mcp",
            "headers" => Any[Dict("name" => "X-Kaimon-Agent-Id", "value" => "codex-test")])])
    cfg = Dict("model" => "keep-model", "model_reasoning_effort" => "high",
               "mcp_servers" => Dict("env_alias" => Dict("url" => "http://localhost:2828/mcp")),
               "mcp_servers.dotted_alias.enabled" => true)
    env = Dict("CODEX_HOME" => "/existing/login/home", "CODEX_CONFIG" => JSON.json(cfg),
               "DISABLE_MCP_CONFIG_FILTERING" => "false", "OPENAI_API_KEY" => "fixture-key")
    original = copy(env)
    servers = Kaimon._codex_acp_setup!(env, b, pwd(); discover = (_, _, _) -> collect(keys(inherited)))
    overrides = JSON.parse(env["CODEX_CONFIG"])
    for name in ("Kaimon", "project_alias", "kaimon", "env_alias", "dotted_alias")
        @test overrides["mcp_servers.$name.enabled"] === false
    end
    @test !haskey(overrides, "mcp_servers")
    @test overrides["model"] == cfg["model"]
    @test overrides["model_reasoning_effort"] == "high"
    @test env["CODEX_HOME"] == original["CODEX_HOME"]
    @test env["OPENAI_API_KEY"] == original["OPENAI_API_KEY"]
    @test env["DISABLE_MCP_CONFIG_FILTERING"] == original["DISABLE_MCP_CONFIG_FILTERING"]
    @test length(servers) == 1
    @test occursin(r"^kaimon_owned_[0-9a-f]{16}$", servers[1]["name"])
    @test !(servers[1]["name"] in keys(inherited))
    @test servers[1]["headers"] == b.mcp_servers[1]["headers"]
    @test overrides["mcp_servers.$(servers[1]["name"])"]["http_headers"]["X-Kaimon-Agent-Id"] == "codex-test"
    @test b.mcp_servers[1]["name"] == "kaimon"  # backend config is not mutated

    # Replay the adapter's deep merge + conflict filtering: the only enabled connection is tagged.
    effective = deepcopy(inherited)
    for (key, value) in overrides
        startswith(key, "mcp_servers.") || continue
        parts = split(key, '.')
        name = parts[2]
        if length(parts) == 3
            get!(effective, name, Dict{String,Any}())["enabled"] = value
        else
            effective[name] = value
        end
    end
    enabled = [s for s in values(effective) if get(s, "enabled", true)]
    @test length(enabled) == 1
    @test enabled[1]["http_headers"]["X-Kaimon-Agent-Id"] == "codex-test"
    # Disjoint dotted server overrides have the same result in either insertion order.
    @test !haskey(overrides, "mcp_servers")
    @test all(k -> startswith(k, "mcp_servers.") ?
        length(split(k, '.')) == (overrides[k] isa AbstractDict ? 2 : 3) : true, keys(overrides))

    # Dispatch under the identity on that connection. A denied open must never reach a launcher;
    # a permitted Slate tool must still reach its handler. No model or child process is involved.
    aid = "codex-test"
    session = (; id = "codex-mcp-test")
    calls = String[]
    schema = Dict{String,Any}("type" => "object", "properties" => Dict())
    tools = Dict(Symbol(n) => Kaimon.MCPTool(Symbol(n), n, n, n, schema,
                    _ -> (push!(calls, n); "ok")) for n in ("agent_open", "slate.run"))
    names = Dict(t.name => id for (id, t) in tools)
    owned = Kaimon.AgentSession(aid, b, OnlyTestHandle(), pwd(), "acp:codex", :alive,
        Task(() -> nothing), time(), time(), Kaimon.ACP.Usage(), Any[], String[], String[], ReentrantLock())
    lock(Kaimon.AGENT_SESSIONS_LOCK) do; Kaimon.AGENT_SESSIONS[aid] = owned; end
    Kaimon._set_session_agent_id!(session.id, aid)
    try
        for (name, denied) in (("agent_open", true), ("slate.run", false))
            req = Dict("jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
                       "params" => Dict("name" => name, "arguments" => Dict()))
            body = JSON.parse(String(Kaimon._rpc_tools_call(req, tools, names, session).body))
            @test get(body["result"], "isError", false) === denied
        end
        @test calls == ["slate.run"]
        for tool in ("mcp.Kaimon.agent_open", "mcp.$(servers[1]["name"]).agent_open")
            @test Kaimon._acp_decide(b, tool)["allow"] === false
        end
    finally
        lock(Kaimon.AGENT_SESSIONS_LOCK) do; delete!(Kaimon.AGENT_SESSIONS, aid); end
        lock(Kaimon._SESSION_AGENT_ID_LOCK) do; delete!(Kaimon._SESSION_AGENT_ID, session.id); end
    end

    @test_throws ErrorException Kaimon._codex_acp_setup!(copy(original), b, pwd();
        discover = (_, _, _) -> error("cannot read configuration"))
    @test_throws ErrorException Kaimon._codex_acp_setup!(Dict("CODEX_CONFIG" => "[]"), b, pwd())
    @test_throws ErrorException Kaimon._codex_acp_setup!(copy(original), b, pwd();
        discover = (_, _, _) -> ["unsafe.name"])
    @test Kaimon._acp_codex(["/some/path/codex-acp.cmd"])
    @test !Kaimon._acp_codex(["claude-agent-acp"])
end

if _HAVE_NODE
@testset "ACP: Codex config discovery reads layers and fails closed" begin
    fixture = joinpath(@__DIR__, "fixtures", "codex_acp_config.cjs")
    argv = ["node", fixture]
    @test Set(Kaimon._codex_mcp_names(argv, pwd(), copy(ENV))) ==
          Set(["Kaimon", "kaimon", "project_alias"])
    @test_throws TaskFailedException Kaimon._codex_mcp_names(
        ["node", "-e", "process.exit(1)", "--"], pwd(), copy(ENV))

    if !Sys.iswindows()
        # Name the node executable like the adapter so this goes through backend_start's
        # real Codex branch, including subprocess discovery, env setup and session/new.
        mktempdir() do dir
            executable = joinpath(dir, "codex-acp")
            symlink(Sys.which("node"), executable)
            b = Kaimon.ACPClientBackend(; argv = [executable, fixture],
                mcp_servers = Any[Dict("name" => "kaimon", "type" => "http",
                    "url" => "http://tagged/mcp", "headers" => Any[
                        Dict("name" => "X-Kaimon-Agent-Id", "value" => "fixture-agent")])])
            withenv("CODEX_HOME" => dir, "CODEX_CONFIG" => "{\"model\":\"keep\"}") do
                h = Kaimon.backend_start(b; cwd = pwd(), agent_id = "fixture-agent")
                try
                    captured = h.caps["session"]["fixture"]
                    @test captured["home"] == dir
                    @test captured["config"]["model"] == "keep"
                    @test isempty(captured["servers"]) # adapter filtering never sees our connection
                    for name in ("Kaimon", "kaimon", "project_alias")
                        @test captured["config"]["mcp_servers.$name.enabled"] === false
                    end
                    key = only(k for k in keys(captured["config"]) if startswith(k, "mcp_servers.kaimon_owned_"))
                    server = captured["config"][key]
                    @test server["enabled"] === true
                    @test server["http_headers"]["X-Kaimon-Agent-Id"] == "fixture-agent"
                    @test ENV["CODEX_CONFIG"] == "{\"model\":\"keep\"}"
                finally
                    Kaimon.backend_close(h)
                end
            end
        end
    end
end
end

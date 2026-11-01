using ReTest
using Kaimon
using HTTP
using JSON

@testset "Per-agent tokens" begin
    @testset "registry" begin
        a = Kaimon.register_agent_token!("tok-reg-a")
        b = Kaimon.register_agent_token!("tok-reg-b")
        @test length(a) == 64 && a != b
        @test Kaimon.agent_token("tok-reg-a") == a
        @test Kaimon.agent_for_token(a) == "tok-reg-a"
        @test Kaimon.agent_for_token(b) == "tok-reg-b"
        @test Kaimon.agent_for_token("") == ""
        @test Kaimon.agent_for_token("not-a-token") == ""
        @test Kaimon.register_agent_token!("tok-reg-a") != a   # re-registering replaces it
        @test Kaimon.agent_for_token(a) == ""
        Kaimon.revoke_agent_token!("tok-reg-a")
        Kaimon.revoke_agent_token!("tok-reg-b")
        @test Kaimon.agent_token("tok-reg-a") == "" && Kaimon.agent_for_token(b) == ""
    end

    @testset "display state: fingerprint, last call" begin
        tok = Kaimon.register_agent_token!("tok-disp")
        fp = Kaimon.agent_token_fingerprint("tok-disp")
        @test occursin(r"^[0-9a-f]{6}$", fp) && !occursin(fp, tok)   # identifies, reveals nothing
        @test Kaimon.agent_last_call("tok-disp") === nothing
        Kaimon.note_agent_call!("tok-disp")
        @test Kaimon.agent_last_call("tok-disp") isa Float64
        Kaimon.revoke_agent_token!("tok-disp")
        @test Kaimon.agent_token_fingerprint("tok-disp") == ""
        @test Kaimon.agent_last_call("tok-disp") === nothing
        Kaimon.note_agent_call!("tok-disp")   # a revoked agent is not brought back
        @test Kaimon.agent_last_call("tok-disp") === nothing
    end

    @testset "agent configs carry the agent's token, not the global key or an id header" begin
        mktempdir() do cache
            withenv("XDG_CACHE_HOME" => cache, "XDG_CONFIG_HOME" => joinpath(cache, "config")) do
                old = Kaimon.MCP_SERVER_PORT[]
                try
                    Kaimon.MCP_SERVER_PORT[] = 12345
                    @test_throws ErrorException Kaimon._agent_mcp_config("tok-cfg")   # no token
                    @test_throws ErrorException Kaimon._acp_mcp_servers("tok-cfg")
                    tok = Kaimon.register_agent_token!("tok-cfg")

                    p = Kaimon._agent_mcp_config("tok-cfg")
                    k = JSON.parse(read(p, String))["mcpServers"]["kaimon"]
                    @test occursin("12345", k["url"])
                    @test k["headers"] == Dict("Authorization" => "Bearer $tok")

                    s = only(Kaimon._acp_mcp_servers("tok-cfg"))
                    @test s["headers"] == Any[Dict("name" => "Authorization", "value" => "Bearer $tok")]
                finally
                    Kaimon.revoke_agent_token!("tok-cfg")
                    Kaimon.MCP_SERVER_PORT[] = old
                end
            end
        end
    end

    @testset "a spawn that fails leaves no token behind" begin
        @test_throws ErrorException Kaimon.agent_open(; cwd = ".", id = "tok-failed-open", only = true,
                                                      mcp_config = "/tmp/never-used.json")
        @test Kaimon.agent_token("tok-failed-open") == ""
    end

    @testset "server: the token authenticates and identifies; the header does neither" begin
        api_key = Kaimon.generate_api_key()
        security = Kaimon.SecurityConfig(:strict, [api_key], ["127.0.0.1", "::1"])
        echo = Kaimon.@mcp_tool(:tok_echo, "Echo", Kaimon.text_parameter("message", "m"),
                                args -> get(args, "message", ""))
        server = Kaimon.start_mcp_server([echo], 0; verbose = false, security_config = security)
        url = "http://127.0.0.1:$(server.port)/mcp"
        post(body, bearer; sid = nothing, extra = Pair{String,String}[]) = HTTP.post(url,
            vcat(["Content-Type" => "application/json", "Accept" => "application/json, text/event-stream",
                  "Authorization" => "Bearer $bearer"],
                 sid === nothing ? Pair{String,String}[] : ["Mcp-Session-Id" => sid], extra),
            JSON.json(body); status_exception = false)
        init = Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
                    "params" => Dict("protocolVersion" => "2025-11-25", "capabilities" => Dict(),
                                     "clientInfo" => Dict("name" => "tok-test", "version" => "0")))
        list = Dict("jsonrpc" => "2.0", "id" => 2, "method" => "tools/list")
        a = Kaimon.register_agent_token!("tok-srv-a")
        b = Kaimon.register_agent_token!("tok-srv-b")
        try
            @test Kaimon.ACTIVE_SECURITY_MODE[] === :strict
            r = post(init, a)
            @test r.status == 200
            sid = HTTP.header(r, "Mcp-Session-Id")
            @test Kaimon._session_agent_id(sid) == "tok-srv-a"
            @test sid in Kaimon._agent_session_ids("tok-srv-a")
            @test Kaimon.agent_last_call("tok-srv-a") isa Float64

            # The global key with an agent-id header binds nothing: identity needs the token.
            r = post(init, api_key; extra = ["X-Kaimon-Agent-Id" => "tok-srv-b"])
            @test r.status == 200
            @test Kaimon._session_agent_id(HTTP.header(r, "Mcp-Session-Id")) == ""

            # Another agent's token cannot take over a session that belongs to an agent.
            before = Kaimon.recent_auth_refusals().total
            @test post(list, b; sid).status == 403
            refused = Kaimon.recent_auth_refusals()
            @test refused.total == before + 1
            @test last(refused.refusals).reason == "session belongs to another agent"
            @test last(refused.refusals).status == 403
            @test Kaimon._session_agent_id(sid) == "tok-srv-a"

            # A revoked token, or one Kaimon never minted, is refused at the gate.
            Kaimon.revoke_agent_token!("tok-srv-a")
            @test post(list, a; sid).status == 401
            @test post(init, "0123456789abcdef"^4).status == 401
            @test last(Kaimon.recent_auth_refusals().refusals).reason == "invalid API key or agent token"
        finally
            Kaimon.revoke_agent_token!("tok-srv-a")
            Kaimon.revoke_agent_token!("tok-srv-b")
            Kaimon.stop_mcp_server(server)
        end
    end
end

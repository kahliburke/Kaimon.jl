using ReTest

using Kaimon
using Kaimon.Session
using Kaimon.Session: UNINITIALIZED, INITIALIZING, INITIALIZED, CLOSED

@testset "Session Management" begin
    @testset "Session Creation" begin
        session = MCPSession()

        @test session.state == UNINITIALIZED
        @test !isempty(session.id)
        @test isempty(session.protocol_version)
        @test isempty(session.client_info)
        @test session.initialized_at === nothing
        @test session.closed_at === nothing
        @test !isempty(session.server_capabilities)
    end

    @testset "elicitation capability gate is optimistic on empty caps" begin
        # Advertised elicitation → attempt.
        @test Kaimon._caps_may_elicit(Dict{String,Any}("elicitation" => Dict(), "roots" => Dict()))
        # Empty / unknown caps → attempt anyway (capless reconnect sessions still support it).
        @test Kaimon._caps_may_elicit(Dict{String,Any}())
        @test Kaimon._caps_may_elicit(nothing)
        # Non-empty caps that explicitly omit elicitation → the only real "no".
        @test !Kaimon._caps_may_elicit(Dict{String,Any}("roots" => Dict()))
    end

    @testset "capless session borrows the latest known client caps" begin
        mktempdir() do cache
            withenv("XDG_CACHE_HOME" => cache) do
                mkpath(joinpath(cache, "kaimon"))
                Kaimon.save_persisted_sessions(Dict{String,Dict}(
                    "capped" => Dict("created_at" => "2026-07-02T10:00:00",
                        "last_seen" => "2026-07-02T12:00:00",
                        "client_capabilities" => Dict("elicitation" => Dict(), "roots" => Dict()),
                        "client_info" => Dict("name" => "claude-code")),
                    "capless" => Dict("created_at" => "2026-07-02T11:00:00",
                        "last_seen" => "2026-07-02T11:30:00", "workspace_root" => "/x"),
                ))
                # A fresh (capless) session inherits the most-recent client's caps.
                s = MCPSession()
                @test isempty(s.client_capabilities)
                Kaimon._borrow_recent_caps!(s)
                @test haskey(s.client_capabilities, "elicitation")
                # A session that already advertised caps is left untouched.
                s2 = MCPSession()
                s2.client_capabilities = Dict{String,Any}("roots" => Dict())
                Kaimon._borrow_recent_caps!(s2)
                @test !haskey(s2.client_capabilities, "elicitation")
            end
        end
    end

    @testset "project path falls back to persisted workspace root" begin
        mktempdir() do cache
            withenv("XDG_CACHE_HOME" => cache) do
                mkpath(joinpath(cache, "kaimon"))
                caller = "test-caller-$(rand(UInt32))"
                Kaimon.save_persisted_sessions(Dict{String,Dict}(
                    caller => Dict("created_at" => "2026-07-03T10:00:00",
                        "last_seen" => "2026-07-03T10:00:00",
                        "workspace_root" => "/some/proj")))
                # No in-memory workspace root and no bound gate for this caller → the
                # resolver must fall back to the caller's OWN persisted workspace root
                # (not "", which would scope grep_code/search_code to the server cwd).
                task_local_storage(:mcp_caller, caller) do
                    @test Kaimon._last_session_project_path() == "/some/proj"
                end
            end
        end
    end

    @testset "persisted gate project is recorded and preferred for reassociation" begin
        mktempdir() do cache
            withenv("XDG_CACHE_HOME" => cache) do
                mkpath(joinpath(cache, "kaimon"))
                caller = "bind-caller-$(rand(UInt32))"
                # Nothing recorded yet.
                @test Kaimon._persisted_session_project(caller) === nothing
                # Binding to a gate records the RESOLVED project (reliable, non-SSE).
                Kaimon._persist_session_project!(caller, "/home/dev/KaimonSlate.jl")
                @test Kaimon._persisted_session_project(caller) == "/home/dev/KaimonSlate.jl"
                # Empty project is ignored (no spurious overwrite/entry).
                Kaimon._persist_session_project!(caller, "")
                @test Kaimon._persisted_session_project(caller) == "/home/dev/KaimonSlate.jl"
                # On reconnect, resolution prefers the gate project over a broader
                # workspace root — it's the project the agent actually worked in.
                Kaimon.save_persisted_sessions(Dict{String,Dict}(
                    caller => Dict("created_at" => "2026-07-04T10:00:00",
                        "last_seen" => "2026-07-04T10:00:00",
                        "workspace_root" => "/home/dev",
                        "project_path" => "/home/dev/KaimonSlate.jl")))
                task_local_storage(:mcp_caller, caller) do
                    @test Kaimon._last_session_project_path() == "/home/dev/KaimonSlate.jl"
                end
            end
        end
    end

    @testset "short_key is unique per session (no TCP 8-char collision)" begin
        # UUID-style ids → first 8 chars.
        @test Kaimon.short_key("477cca57deadbeef") == "477cca57"
        @test Kaimon.short_key("aaaaaaaa") == "aaaaaaaa"
        # TCP ids → the FULL id, so distinct ports stay distinct. A raw session_id[1:8]
        # truncation would collapse both to "tcp-127." and merge their ECG/health —
        # the duplicated-heartbeat bug across local TCP (KaimonSlate) sessions.
        a = Kaimon.short_key("tcp-127.0.0.1-9100")
        b = Kaimon.short_key("tcp-127.0.0.1-9102")
        @test a == "tcp-127.0.0.1-9100"
        @test a != b
        @test first("tcp-127.0.0.1-9100", 8) == first("tcp-127.0.0.1-9102", 8)  # the trap
    end

    @testset "agent-id: session map + header extraction" begin
        sid = "sess-$(rand(UInt32))"
        @test Kaimon._session_agent_id(sid) == ""
        Kaimon._set_session_agent_id!(sid, "agent-abcd")
        @test Kaimon._session_agent_id(sid) == "agent-abcd"
        # Empty inputs are ignored (no clobber, no spurious entry).
        Kaimon._set_session_agent_id!(sid, "")
        @test Kaimon._session_agent_id(sid) == "agent-abcd"
        Kaimon._set_session_agent_id!("", "x")
        @test Kaimon._session_agent_id("") == ""
        # Header extraction is case-insensitive; "" when absent.
        with = (headers = ["Content-Type" => "application/json", "X-Kaimon-Agent-Id" => "aid-1"],)
        none = (headers = ["Content-Type" => "application/json"],)
        @test Kaimon.extract_agent_id(with) == "aid-1"
        @test Kaimon.extract_agent_id(none) == ""
    end

    @testset "agent-id: generated MCP config carries the header" begin
        mktempdir() do cache
            withenv(
                "XDG_CACHE_HOME" => cache,
                "XDG_CONFIG_HOME" => joinpath(cache, "config"),
            ) do
                old = Kaimon.MCP_SERVER_PORT[]
                try
                    Kaimon.MCP_SERVER_PORT[] = 0
                    @test Kaimon._agent_mcp_config("aid-x") === nothing  # no port → no config
                    Kaimon.MCP_SERVER_PORT[] = 12345
                    p = Kaimon._agent_mcp_config("aid-x")
                    @test p !== nothing && isfile(p)
                    k = Kaimon.JSON.parse(read(p, String))["mcpServers"]["kaimon"]
                    @test occursin("12345", k["url"])
                    @test k["headers"]["X-Kaimon-Agent-Id"] == "aid-x"
                finally
                    Kaimon.MCP_SERVER_PORT[] = old
                end
            end
        end
    end

    @testset "Session Initialization - Success" begin
        session = MCPSession()

        params = Dict{String,Any}(
            "protocolVersion" => "2024-11-05",
            "capabilities" => Dict{String,Any}("tools" => Dict()),
            "clientInfo" =>
                Dict{String,Any}("name" => "test-client", "version" => "1.0.0"),
        )

        result = initialize_session!(session, params)

        @test session.state == INITIALIZED
        @test session.protocol_version == "2024-11-05"
        @test session.initialized_at !== nothing
        @test haskey(session.client_info, "name")
        @test session.client_info["name"] == "test-client"

        @test haskey(result, "protocolVersion")
        @test haskey(result, "capabilities")
        @test haskey(result, "serverInfo")
        @test result["serverInfo"]["name"] == "Kaimon"
    end

    @testset "Session Initialization - Unsupported Version" begin
        session = MCPSession()

        params = Dict{String,Any}(
            "protocolVersion" => "2023-01-01",
            "capabilities" => Dict{String,Any}(),
            "clientInfo" => Dict{String,Any}(),
        )

        @test_throws ErrorException initialize_session!(session, params)
        @test session.state == UNINITIALIZED  # Should rollback on error
    end

    @testset "Session Initialization - Missing Protocol Version" begin
        session = MCPSession()

        params = Dict{String,Any}(
            "capabilities" => Dict{String,Any}(),
            "clientInfo" => Dict{String,Any}(),
        )

        @test_throws ErrorException initialize_session!(session, params)
        @test session.state == UNINITIALIZED
    end

    @testset "Session Initialization - Already Initialized" begin
        session = MCPSession()

        params = Dict{String,Any}(
            "protocolVersion" => "2024-11-05",
            "capabilities" => Dict{String,Any}(),
            "clientInfo" => Dict{String,Any}(),
        )

        initialize_session!(session, params)
        @test session.state == INITIALIZED

        # Try to initialize again
        @test_throws ErrorException initialize_session!(session, params)
    end

    @testset "Session Close" begin
        session = MCPSession()

        params = Dict{String,Any}(
            "protocolVersion" => "2024-11-05",
            "capabilities" => Dict{String,Any}(),
            "clientInfo" => Dict{String,Any}(),
        )

        initialize_session!(session, params)
        @test session.state == INITIALIZED

        close_session!(session)
        @test session.state == CLOSED
        @test session.closed_at !== nothing

        # Closing again should be idempotent (just warn)
        close_session!(session)
        @test session.state == CLOSED
    end

    @testset "Session Info" begin
        session = MCPSession()

        info = get_session_info(session)
        @test haskey(info, "id")
        @test haskey(info, "state")
        @test haskey(info, "protocol_version")
        @test info["state"] == "UNINITIALIZED"

        params = Dict{String,Any}(
            "protocolVersion" => "2024-11-05",
            "capabilities" => Dict{String,Any}(),
            "clientInfo" => Dict{String,Any}("name" => "test-client"),
        )

        initialize_session!(session, params)

        info = get_session_info(session)
        @test info["state"] == "INITIALIZED"
        @test info["protocol_version"] == "2024-11-05"
        @test haskey(info, "uptime")
        @test info["uptime"] !== nothing
    end

    @testset "Server Capabilities" begin
        caps = Session.get_server_capabilities()

        @test haskey(caps, "tools")
        @test haskey(caps, "prompts")
        @test haskey(caps, "resources")
        @test haskey(caps, "logging")
    end

    @testset "Session Lifecycle" begin
        session = MCPSession()
        created_time = session.created_at

        # Should start uninitialized
        @test session.state == UNINITIALIZED

        # Initialize
        params = Dict{String,Any}(
            "protocolVersion" => "2024-11-05",
            "capabilities" => Dict{String,Any}("tools" => Dict()),
            "clientInfo" => Dict{String,Any}("name" => "client"),
        )

        initialize_session!(session, params)
        @test session.state == INITIALIZED
        @test session.initialized_at >= created_time

        # Close
        close_session!(session)
        @test session.state == CLOSED
        @test session.closed_at >= session.initialized_at
    end
end

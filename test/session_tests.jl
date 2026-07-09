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

    @testset "server→client request delivery tolerates session-id splits" begin
        schema = Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}())
        mkmsg() = Dict{String,Any}("jsonrpc" => "2.0", "id" => "rid-$(rand(UInt32))",
            "method" => "elicitation/create")

        # Isolate _SESSION_OUTBOX so the any-open-stream fallback below only sees the
        # streams each sub-test registers (not a real client's live stream).
        saved = lock(Kaimon._SESSION_OUTBOX_LOCK) do
            s = copy(Kaimon._SESSION_OUTBOX)
            empty!(Kaimon._SESSION_OUTBOX)
            s
        end
        try
            # 1. Exact-id match → lands in that session's own receive stream.
            @testset "exact-id outbox" begin
                sid = "sess-$(rand(UInt32))"
                ch = Kaimon._register_session_stream!(sid)
                try
                    msg = mkmsg()
                    @test Kaimon._deliver_to_client!(sid, msg, nothing)
                    @test isready(ch) && take!(ch)["id"] == msg["id"]
                finally
                    Kaimon._unregister_session_stream!(sid, ch)
                end
            end

            # 2. THE FIX: the caller's id has no stream, but another receive stream is
            #    open — Claude Code POSTs tool calls under one (persisted) id while its
            #    live GET receive stream is under another. Deliver to the open stream
            #    instead of silently no-op'ing (the "immediate no-answer" symptom).
            @testset "mismatched-id falls back to an open stream" begin
                get_sid = "getstream-$(rand(UInt32))"
                post_sid = "postcaller-$(rand(UInt32))"   # different id, no stream
                ch = Kaimon._register_session_stream!(get_sid)
                try
                    msg = mkmsg()
                    @test Kaimon._deliver_to_client!(post_sid, msg, nothing)
                    @test isready(ch) && take!(ch)["id"] == msg["id"]
                finally
                    Kaimon._unregister_session_stream!(get_sid, ch)
                end
            end

            # 3. No open receive stream at all → the in-flight tool-call SSE writer is
            #    the last resort (best-effort for a client that keeps no GET stream).
            @testset "writer is the last resort" begin
                captured = Ref{Any}(nothing)
                writer = m -> (captured[] = m; true)
                msg = mkmsg()
                @test Kaimon._deliver_to_client!("nobody-$(rand(UInt32))", msg, writer)
                @test captured[] !== nothing && captured[]["id"] == msg["id"]
            end

            # 4. No stream and no writer → undeliverable (caller maps this to :timeout).
            @testset "no channel → false" begin
                @test !Kaimon._deliver_to_client!("nobody-$(rand(UInt32))", mkmsg(), nothing)
            end

            # Integration: request_elicitation delivers to the caller's stream and
            # returns the routed reply.
            @testset "request_elicitation round-trip via the caller's stream" begin
                sid = "elicit-$(rand(UInt32))"
                ch = Kaimon._register_session_stream!(sid)
                try
                    client = @async begin
                        while !isready(ch)
                            sleep(0.005)
                        end
                        req = take!(ch)
                        Kaimon._route_server_response!(Dict{String,Any}(
                            "jsonrpc" => "2.0", "id" => req["id"],
                            "result" => Dict{String,Any}("action" => "accept",
                                "content" => Dict{String,Any}("remember" => false))))
                    end
                    res = Kaimon.request_elicitation(sid, "approve?", schema; timeout = 5.0)
                    wait(client)
                    @test res isa AbstractDict && res["action"] == "accept"
                finally
                    Kaimon._unregister_session_stream!(sid, ch)
                end
            end
        finally
            lock(Kaimon._SESSION_OUTBOX_LOCK) do
                empty!(Kaimon._SESSION_OUTBOX)
                merge!(Kaimon._SESSION_OUTBOX, saved)
            end
        end
    end

    @testset "list-changed notifications re-deliver on every re-queue (seq cursor)" begin
        m = "notifications/test-lc-$(rand(UInt32))"
        sid = "notif-sid-$(rand(UInt32))"
        mk() = Dict{String,Any}("jsonrpc" => "2.0", "method" => m)

        # Queue once → a fresh session sees it, and the global seq advanced.
        s0 = Kaimon._NOTIF_SEQ[]
        Kaimon._queue_notification!(mk())
        @test Kaimon._NOTIF_SEQ[] > s0
        @test any(n -> n["method"] == m, Kaimon._flush_notifications_for_session!(sid))

        # Same session, no re-queue → cursor advanced past it, so it is NOT resent.
        # (This is what replaces re-sending the same board entry every poll tick.)
        @test !any(n -> n["method"] == m, Kaimon._flush_notifications_for_session!(sid))

        # Re-queue (the extension restarted) → fresh, higher seq → delivered AGAIN.
        # The old method-name dedup suppressed this for the stream's whole life,
        # which is exactly what forced a manual /mcp reconnect.
        Kaimon._queue_notification!(mk())
        @test any(n -> n["method"] == m, Kaimon._flush_notifications_for_session!(sid))

        # The board keeps ONE entry per method (latest), not one per re-queue.
        @test haskey(Kaimon._PENDING_NOTIFICATIONS, m)

        # A different session has its own cursor → still sees the pending change.
        sid2 = "notif-sid2-$(rand(UInt32))"
        @test any(n -> n["method"] == m, Kaimon._flush_notifications_for_session!(sid2))

        # Empty sid is anonymous (no stable cursor) → never delivered.
        @test isempty(Kaimon._flush_notifications_for_session!(""))
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

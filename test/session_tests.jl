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

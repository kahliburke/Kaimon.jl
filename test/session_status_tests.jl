using ReTest
using Kaimon

# Import the SessionStatus module
include(joinpath(dirname(@__DIR__), "src", "session_status.jl"))
using .SessionStatus

@testset "Session Status Module" begin

    @testset "Status Constants" begin
        # Verify all Julia session status constants exist
        @test READY == "ready"
        @test DOWN == "down"
        @test RESTARTING == "restarting"
        @test STOPPED == "stopped"
        @test REPLACED == "replaced"

        # Verify MCP session status constants
        @test ACTIVE == "active"
        @test INACTIVE == "inactive"
    end

    @testset "Valid Status Sets" begin
        # Julia session statuses
        @test READY in VALID_JULIA_STATUSES
        @test DOWN in VALID_JULIA_STATUSES
        @test RESTARTING in VALID_JULIA_STATUSES
        @test STOPPED in VALID_JULIA_STATUSES
        @test REPLACED in VALID_JULIA_STATUSES
        @test length(VALID_JULIA_STATUSES) == 5

        # MCP session statuses
        @test ACTIVE in VALID_MCP_STATUSES
        @test INACTIVE in VALID_MCP_STATUSES
        @test length(VALID_MCP_STATUSES) == 2

        # Invalid statuses should not be in valid sets
        @test !("disconnected" in VALID_JULIA_STATUSES)
        @test !("reconnecting" in VALID_JULIA_STATUSES)
        @test !("unknown" in VALID_JULIA_STATUSES)
    end

    @testset "Buffering Status Set" begin
        # Statuses that should buffer requests
        @test DOWN in BUFFERING_STATUSES
        @test RESTARTING in BUFFERING_STATUSES
        @test length(BUFFERING_STATUSES) == 2

        # Statuses that should NOT buffer
        @test !(READY in BUFFERING_STATUSES)
        @test !(STOPPED in BUFFERING_STATUSES)
        @test !(REPLACED in BUFFERING_STATUSES)
    end

    @testset "Terminal Status Set" begin
        # Terminal statuses - session won't recover
        @test STOPPED in TERMINAL_STATUSES
        @test REPLACED in TERMINAL_STATUSES
        @test length(TERMINAL_STATUSES) == 2

        # Non-terminal statuses
        @test !(READY in TERMINAL_STATUSES)
        @test !(DOWN in TERMINAL_STATUSES)
        @test !(RESTARTING in TERMINAL_STATUSES)
    end

    @testset "should_buffer Helper" begin
        # Should buffer for DOWN and RESTARTING
        @test should_buffer(DOWN) == true
        @test should_buffer(RESTARTING) == true

        # Should NOT buffer for terminal or ready states
        @test should_buffer(READY) == false
        @test should_buffer(STOPPED) == false
        @test should_buffer(REPLACED) == false
    end

    @testset "is_terminal Helper" begin
        # Terminal states
        @test is_terminal(STOPPED) == true
        @test is_terminal(REPLACED) == true

        # Non-terminal states
        @test is_terminal(READY) == false
        @test is_terminal(DOWN) == false
        @test is_terminal(RESTARTING) == false
    end

    @testset "is_active Helper" begin
        # Active states (session exists and may process requests)
        @test is_active(READY) == true
        @test is_active(DOWN) == true
        @test is_active(RESTARTING) == true

        # Inactive/terminal states
        @test is_active(STOPPED) == false
        @test is_active(REPLACED) == false
    end

    @testset "Validation Functions" begin
        # Valid Julia statuses should pass
        @test (validate_julia_status(READY); true)
        @test (validate_julia_status(DOWN); true)
        @test (validate_julia_status(RESTARTING); true)
        @test (validate_julia_status(STOPPED); true)
        @test (validate_julia_status(REPLACED); true)

        # Invalid Julia statuses should throw
        @test_throws Exception validate_julia_status("disconnected")
        @test_throws Exception validate_julia_status("reconnecting")
        @test_throws Exception validate_julia_status("unknown")
        @test_throws Exception validate_julia_status("invalid")
        @test_throws Exception validate_julia_status("")

        # Valid MCP statuses should pass
        @test (validate_mcp_status(ACTIVE); true)
        @test (validate_mcp_status(INACTIVE); true)

        # Invalid MCP statuses should throw
        @test_throws Exception validate_mcp_status("ready")
        @test_throws Exception validate_mcp_status("closed")
        @test_throws Exception validate_mcp_status("")
    end

    @testset "State Transition Logic" begin
        # Test state transition decision making
        # This tests the logic that should be used in the server

        # Function to determine what to do with a request based on status
        function request_action(status::String)
            if status == READY
                return :forward
            elseif should_buffer(status)
                return :buffer
            elseif is_terminal(status)
                return :reject
            else
                # Unknown status - be conservative, buffer
                return :buffer
            end
        end

        # Ready -> forward immediately
        @test request_action(READY) == :forward

        # Down/Restarting -> buffer for replay
        @test request_action(DOWN) == :buffer
        @test request_action(RESTARTING) == :buffer

        # Terminal states -> reject with error
        @test request_action(STOPPED) == :reject
        @test request_action(REPLACED) == :reject
    end

    @testset "Status Transition Sequences" begin
        # Test valid state transition sequences

        # Normal startup sequence
        startup_sequence = [READY]
        @test all(s -> s in VALID_JULIA_STATUSES, startup_sequence)

        # Heartbeat timeout sequence
        heartbeat_sequence = [READY, DOWN, READY]
        @test all(s -> s in VALID_JULIA_STATUSES, heartbeat_sequence)

        # Restart sequence
        restart_sequence = [READY, RESTARTING, READY]
        @test all(s -> s in VALID_JULIA_STATUSES, restart_sequence)

        # Replacement sequence (old session)
        replacement_sequence = [READY, REPLACED]
        @test all(s -> s in VALID_JULIA_STATUSES, replacement_sequence)

        # Shutdown sequence
        shutdown_sequence = [READY, STOPPED]
        @test all(s -> s in VALID_JULIA_STATUSES, shutdown_sequence)
    end
end

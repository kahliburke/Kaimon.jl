using ReTest
using Kaimon
using Kaimon: MCPTool

_call_tool_saved_xdg = get(ENV, "XDG_CONFIG_HOME", nothing)

@testset "call_tool Function Tests" begin
    # Setup - clean test directory
    test_dir = mktempdir()
    original_dir = try
        pwd()
    catch
        # If pwd() fails (directory was deleted), use home directory
        homedir()
    end

    try
        cd(test_dir)

        # Point config dir to a temp location so we don't touch the real config,
        # and pre-create a config so start!() doesn't launch the TUI wizard
        # (the wizard requires a TTY which isn't available in CI).
        test_port = 13100  # Use unique port to avoid conflicts
        ENV["XDG_CONFIG_HOME"] = mktempdir()
        Kaimon.save_global_config(Kaimon.KaimonConfig(
            :lax, String[], ["127.0.0.1", "::1"], test_port, round(Int64, time()), "vscode", "",
        ))

        @testset "call_tool with Symbol" begin
            # Start server for testing
            Kaimon.start!(; verbose = false, port = test_port)

            try
                # Test symbol-based call
                result = Kaimon.call_tool(:investigate_environment, Dict())
                @test result isa String
                @test !isempty(result)

                # Test with parameters - use a tool that doesn't require a gate session
                result2 = Kaimon.call_tool(:tool_help, Dict("tool_name" => "ping"))
                @test result2 isa String
                @test contains(result2, "ping") || contains(result2, "Ping")

                # Test error handling - nonexistent tool
                @test_throws ErrorException Kaimon.call_tool(:nonexistent_tool, Dict())

            finally
                Kaimon.stop!()
            end
        end

        @testset "call_tool Handler Signatures" begin
            Kaimon.start!(; verbose = false, port = test_port + 1)

            try
                # Test tool with args signature
                result = Kaimon.call_tool(:ex, Dict("e" => "2 + 2", "s" => true))
                @test result isa String

                # Test tool with (args) only signature
                result2 = Kaimon.call_tool(:search_methods, Dict("query" => "println"))
                @test result2 isa String

            finally
                Kaimon.stop!()
            end
        end

        @testset "call_tool Error Cases" begin
            # Test without server running
            @test_throws ErrorException Kaimon.call_tool(:ex, Dict())

            Kaimon.start!(; verbose = false, port = test_port + 2)

            try
                # Test missing required parameters
                result = Kaimon.call_tool(:search_methods, Dict())
                @test contains(result, "Error") || contains(result, "required")

            finally
                Kaimon.stop!()
            end
        end

    finally
        cd(original_dir)
        # Restore XDG_CONFIG_HOME
        if _call_tool_saved_xdg === nothing
            delete!(ENV, "XDG_CONFIG_HOME")
        else
            ENV["XDG_CONFIG_HOME"] = _call_tool_saved_xdg
        end
    end
end

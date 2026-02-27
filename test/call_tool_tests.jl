using ReTest
using Kaimon
using Kaimon: MCPTool

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

        # Setup security configuration for testing with unique port
        api_key = Kaimon.generate_api_key()
        test_port = 13100  # Use unique port to avoid conflicts
        config = Kaimon.SecurityConfig(:relaxed, [api_key], ["127.0.0.1"], test_port)
        Kaimon.save_security_config(config, test_dir)

        @testset "call_tool with Symbol" begin
            # Start server for testing
            Kaimon.start!(; verbose = false, port = test_port)

            try
                # Test symbol-based call
                result = Kaimon.call_tool(:investigate_environment, Dict())
                @test result isa String
                @test !isempty(result)

                # Test with parameters - use a function with few methods to avoid long output
                result2 = Kaimon.call_tool(:search_methods, Dict("query" => "iseven"))
                @test result2 isa String
                @test contains(result2, "Methods") || contains(result2, "methods")

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
    end
end

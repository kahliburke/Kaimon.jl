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
            # Start server for testing on an ephemeral port (call_tool runs
            # in-process, so the port value doesn't matter — 0 avoids collisions).
            Kaimon.start!(; verbose = false, port = 0)

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
            Kaimon.start!(; verbose = false, port = 0)

            try
                # Test tool with args signature
                result = Kaimon.call_tool(:ex, Dict("e" => "2 + 2", "s" => true))
                @test result isa String

                # Omitting `e` must return a CLEAR ERROR, not silently run an empty eval
                # (regression: the ex handler read only `e`, so a call that put the code
                # under `code` — or omitted it — ran nothing: success, no result, bare
                # `agent>`). Passing `code` gets a targeted hint.
                result_code = Kaimon.call_tool(:ex, Dict("code" => "2 + 2", "s" => true))
                @test occursin("requires the Julia code in the `e`", result_code)
                @test occursin("`code`", result_code)   # calls out the common slip
                result_nocode = Kaimon.call_tool(:ex, Dict("q" => false, "s" => true))
                @test occursin("requires the Julia code in the `e`", result_nocode)

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

            Kaimon.start!(; verbose = false, port = 0)

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

# Pure unit test (no server) for the ex code-argument resolver: the code MUST be `e`;
# a missing `e` returns a clear error (with a targeted hint when `code` was used), so
# the handler never silently dispatches an empty eval.
@testset "ex code arg (requires `e`)" begin
    @test Kaimon._ex_code_or_error(Dict("e" => "1 + 1")) == ("1 + 1", nothing)

    code, err = Kaimon._ex_code_or_error(Dict("code" => "2 + 2"))
    @test code === nothing
    @test occursin("requires the Julia code in the `e`", err)
    @test occursin("`code`", err)   # calls out the common slip

    code2, err2 = Kaimon._ex_code_or_error(Dict())
    @test code2 === nothing
    @test occursin("requires the Julia code in the `e`", err2)
    @test !occursin("`code`", err2)  # no hint when `code` wasn't the mistake
end

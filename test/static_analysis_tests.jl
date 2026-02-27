"""
Static Analysis Tests

Uses JET.jl to catch errors at "compile time" including:
- Undefined variable references
- Missing exports
- Type instabilities
- Method errors

Run this before commits to catch issues like missing exports from modules.
"""

using ReTest
using JET
using Kaimon

@testset "Static Analysis" begin
    @testset "Module Loading" begin
        # Test that all modules load without UndefVarError
        @test_call report_call = true begin
            using Kaimon
        end
    end

    @testset "Session Module Exports" begin
        # Verify all expected exports exist
        @test_call report_call = true begin
            include("../src/session.jl")
            Kaimon.Session.update_activity!
        end
    end

    @testset "Top-level Module Analysis" begin
        # Run JET analysis on the entire Kaimon module
        # This catches undefined variables, type issues, etc.
        rep = report_package(:Kaimon, ignored_modules = (AnyFrameModule(Test),))

        # Filter out known acceptable issues
        issues = filter(rep.res.inference_error_reports) do report
            # Ignore errors from test files
            !any(sf -> occursin("test/", string(sf.file)), report.vst)
        end

        if !isempty(issues)
            println("\n❌ Static analysis found issues:")
            for (i, issue) in enumerate(issues)
                println("\n$i. ", issue)
            end
        end

        @test isempty(issues)
    end

    @testset "Export Consistency Check" begin
        # Test MCPServer module dependencies
        @testset "MCPServer Dependencies" begin
            using Kaimon.MCPServer

            @test isdefined(Kaimon.MCPServer, :Session)
            @test isdefined(Kaimon.MCPServer, :MCPSession)
        end
    end
end

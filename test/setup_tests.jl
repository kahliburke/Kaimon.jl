using ReTest
using Kaimon
using JSON

# Helper to create and save a security config for tests
function _setup_security_config(mode::Symbol, port::Int, dir::String)
    config = Kaimon.SecurityConfig(mode, String[], ["127.0.0.1", "::1"], port)
    Kaimon.save_security_config(config, dir)
    return config
end

@testset "Setup Tests" begin
    # Create a temporary directory for testing
    temp_dir = mktempdir()

    try
        @testset "VS Code Configuration" begin
            # Change to temp directory
            original_dir = pwd()
            cd(temp_dir)

            try
                # Test 1: Check status when no config exists
                @test Kaimon.check_vscode_status() == :not_configured

                # Test 2: Get path for non-existent config
                mcp_path = Kaimon.get_vscode_workspace_mcp_path()
                @test endswith(mcp_path, ".vscode/mcp.json")
                @test !isfile(mcp_path)

                # Test 3: Create security config first (required for add_vscode_mcp_server)
                _setup_security_config(:lax, 3000, temp_dir)

                # Test 4: Add HTTP transport
                @test Kaimon.add_vscode_mcp_server("http") == true
                @test isfile(mcp_path)

                # Test 5: Verify config was created correctly
                config = Kaimon.read_vscode_mcp_config()
                @test config !== nothing
                @test haskey(config, "servers")
                @test haskey(config["servers"], "kaimon")
                @test config["servers"]["kaimon"]["type"] == "http"
                @test config["servers"]["kaimon"]["url"] == "http://localhost:3000"

                # Test 6: Check status after configuration
                @test Kaimon.check_vscode_status() == :configured_http

                # Test 7: Update security config to different port
                _setup_security_config(:lax, 4000, temp_dir)
                @test Kaimon.add_vscode_mcp_server("http") == true
                config = Kaimon.read_vscode_mcp_config()
                @test config["servers"]["kaimon"]["url"] == "http://localhost:4000"

                # Test 8: Remove configuration
                @test Kaimon.remove_vscode_mcp_server() == true
                config = Kaimon.read_vscode_mcp_config()
                @test !haskey(config["servers"], "kaimon")
                @test Kaimon.check_vscode_status() == :not_configured

                # Test 9: Remove when already removed (idempotent)
                @test Kaimon.remove_vscode_mcp_server() == true

            finally
                cd(original_dir)
            end
        end

        @testset "Config File Handling" begin
            cd(temp_dir)
            original_dir = pwd()

            try
                # Create a fresh temp directory for this test
                test_subdir = joinpath(temp_dir, "config_test")
                mkdir(test_subdir)
                cd(test_subdir)

                # Test 1: Read non-existent config
                @test Kaimon.read_vscode_mcp_config() === nothing

                # Test 2: Create security config, then write and read vscode config
                _setup_security_config(:lax, 5000, test_subdir)
                Kaimon.add_vscode_mcp_server("http")
                config = Kaimon.read_vscode_mcp_config()
                @test config !== nothing
                @test haskey(config, "servers")

                # Test 3: Verify .vscode directory was created
                @test isdir(joinpath(test_subdir, ".vscode"))

            finally
                cd(original_dir)
            end
        end

        @testset "Port Configuration" begin
            cd(temp_dir)
            original_dir = pwd()

            try
                # Clean any existing config
                vscode_dir = joinpath(temp_dir, ".vscode")
                if isdir(vscode_dir)
                    rm(vscode_dir, recursive = true)
                end

                # Test different port numbers
                test_ports = [3000, 3003, 8080, 9000]

                for port in test_ports
                    _setup_security_config(:lax, port, temp_dir)
                    Kaimon.add_vscode_mcp_server("http")
                    config = Kaimon.read_vscode_mcp_config()
                    @test config["servers"]["kaimon"]["url"] == "http://localhost:$port"
                end

            finally
                cd(original_dir)
            end
        end

        @testset "VS Code Settings.json Management" begin
            original_dir = pwd()
            cd(temp_dir)

            try
                settings_path = Kaimon.get_vscode_settings_path()

                # Test 1: Read non-existent settings
                settings = Kaimon.read_vscode_settings()
                @test settings isa Dict
                @test isempty(settings)

                # Test 2: Write settings
                test_settings = Dict("test.key" => "value")
                @test Kaimon.write_vscode_settings(test_settings) == true
                @test isfile(settings_path)

                # Test 3: Read back settings
                settings = Kaimon.read_vscode_settings()
                @test haskey(settings, "test.key")
                @test settings["test.key"] == "value"

                # Test 4: Configure julia.additionalArgs (empty settings)
                rm(joinpath(temp_dir, ".vscode"), recursive = true)
                @test Kaimon.configure_vscode_julia_args() == true
                settings = Kaimon.read_vscode_settings()
                @test haskey(settings, "julia.additionalArgs")
                @test length(settings["julia.additionalArgs"]) == 1
                @test contains(settings["julia.additionalArgs"][1], "--load")
                @test contains(settings["julia.additionalArgs"][1], ".julia-startup.jl")

                # Test 5: Check startup configured
                @test Kaimon.check_vscode_startup_configured() == true

                # Test 6: Configure julia.additionalArgs (existing args)
                existing_settings =
                    Dict("julia.additionalArgs" => ["--project", "--threads=4"])
                Kaimon.write_vscode_settings(existing_settings)
                @test Kaimon.configure_vscode_julia_args() == true
                settings = Kaimon.read_vscode_settings()
                @test length(settings["julia.additionalArgs"]) == 3
                @test "--project" in settings["julia.additionalArgs"]
                @test "--threads=4" in settings["julia.additionalArgs"]
                @test any(
                    arg -> contains(arg, "--load") && contains(arg, ".julia-startup.jl"),
                    settings["julia.additionalArgs"],
                )

                # Test 7: Don't duplicate startup arg
                @test Kaimon.configure_vscode_julia_args() == true
                settings = Kaimon.read_vscode_settings()
                @test length(settings["julia.additionalArgs"]) == 3  # Should still be 3

            finally
                cd(original_dir)
            end
        end

        @testset "Julia Startup Script Management" begin
            original_dir = pwd()
            cd(temp_dir)

            try
                startup_path = Kaimon.get_startup_script_path()

                # Test 1: Check non-existent startup script
                @test Kaimon.has_startup_script() == false

                # Test 2: Create security config first (install_startup_script reads from it)
                _setup_security_config(:lax, 3000, temp_dir)

                # Test 3: Install startup script
                @test Kaimon.install_startup_script() == true
                @test isfile(startup_path)

                # Test 4: Verify script content
                content = read(startup_path, String)
                @test contains(content, "using Kaimon")
                @test contains(content, "Gate.serve")

                # Test 5: Check has startup script
                @test Kaimon.has_startup_script() == true

            finally
                cd(original_dir)
            end
        end

    finally
        # Cleanup: remove temp directory
        rm(temp_dir, recursive = true, force = true)
    end
end

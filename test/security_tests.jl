using ReTest
using Kaimon
using HTTP
using JSON

@testset "Security Tests" begin
    # Setup - clean test directory
    test_dir = mktempdir()
    original_dir = pwd()

    try
        cd(test_dir)

        @testset "API Key Generation" begin
            key = Kaimon.generate_api_key()
            @test startswith(key, "kaimon_")
            @test length(key) == 47  # "kaimon_" (7 chars) + 40 hex chars
            @test occursin(r"^kaimon_[0-9a-f]{40}$", key)

            # Keys should be unique
            key2 = Kaimon.generate_api_key()
            @test key != key2
        end

        @testset "API Key Validation" begin
            valid_key = Kaimon.generate_api_key()
            invalid_key = "invalid_key_123"

            # Strict mode
            config_strict = Kaimon.SecurityConfig(:strict, [valid_key], ["127.0.0.1"])
            @test Kaimon.validate_api_key(valid_key, config_strict)
            @test !Kaimon.validate_api_key(invalid_key, config_strict)
            @test !Kaimon.validate_api_key("", config_strict)

            # Relaxed mode
            config_relaxed = Kaimon.SecurityConfig(:relaxed, [valid_key], ["127.0.0.1"])
            @test Kaimon.validate_api_key(valid_key, config_relaxed)
            @test !Kaimon.validate_api_key(invalid_key, config_relaxed)

            # Lax mode (no key required)
            config_lax = Kaimon.SecurityConfig(:lax, String[], ["127.0.0.1"])
            @test Kaimon.validate_api_key("", config_lax)
            @test Kaimon.validate_api_key("anything", config_lax)
        end

        @testset "IP Validation" begin
            config_strict =
                Kaimon.SecurityConfig(:strict, ["key"], ["127.0.0.1", "192.168.1.1"])
            @test Kaimon.validate_ip("127.0.0.1", config_strict)
            @test Kaimon.validate_ip("192.168.1.1", config_strict)
            @test !Kaimon.validate_ip("10.0.0.1", config_strict)

            # Relaxed mode (any IP)
            config_relaxed = Kaimon.SecurityConfig(:relaxed, ["key"], ["127.0.0.1"])
            @test Kaimon.validate_ip("127.0.0.1", config_relaxed)
            @test Kaimon.validate_ip("10.0.0.1", config_relaxed)
            @test Kaimon.validate_ip("8.8.8.8", config_relaxed)

            # Lax mode (localhost only)
            config_lax = Kaimon.SecurityConfig(:lax, String[], String[])
            @test Kaimon.validate_ip("127.0.0.1", config_lax)
            @test Kaimon.validate_ip("::1", config_lax)
            @test Kaimon.validate_ip("localhost", config_lax)
            @test !Kaimon.validate_ip("192.168.1.1", config_lax)
        end

        @testset "SecurityConfig Construction" begin
            # Convenience constructor defaults
            config = Kaimon.SecurityConfig(:lax, String[], ["127.0.0.1", "::1"], 3000)
            @test config.mode == :lax
            @test length(config.api_keys) == 0
            @test "127.0.0.1" in config.allowed_ips
            @test config.port == 3000
            @test config.editor == "vscode"  # default

            # With custom editor
            config2 = Kaimon.SecurityConfig(:strict, ["key"], ["127.0.0.1"], 0, "cursor")
            @test config2.editor == "cursor"
        end

        @testset "Server Authentication" begin
            # Create security config
            test_port = 13100
            api_key = Kaimon.generate_api_key()
            security_config =
                Kaimon.SecurityConfig(:strict, [api_key], ["127.0.0.1", "::1"])

            # Create simple test tool
            test_tool = Kaimon.@mcp_tool(
                :test_echo,
                "Echo back input",
                Kaimon.text_parameter("message", "Message to echo"),
                args -> get(args, "message", "")
            )

            # Start server with security
            server = Kaimon.start_mcp_server(
                [test_tool],
                test_port;
                verbose = false,
                security_config = security_config,
            )

            # Give server plenty of time to start and stabilize
            sleep(3.0)

            # Wait for server to be ready with robust retry logic
            # Use valid auth from the start to avoid connection resets
            server_ready = false
            last_error = nothing
            for attempt = 1:40
                try
                    # Make a simple POST request with valid auth to test connectivity
                    test_body = JSON.json(
                        Dict("jsonrpc" => "2.0", "id" => 0, "method" => "tools/list"),
                    )
                    response = HTTP.post(
                        "http://localhost:$test_port/",
                        [
                            "Content-Type" => "application/json",
                            "Authorization" => "Bearer $api_key",
                        ],
                        test_body;
                        status_exception = false,
                        readtimeout = 5,
                        retry = false,
                        connect_timeout = 5,
                    )
                    # Any response (even error) means server is ready
                    if response.status >= 100
                        server_ready = true
                        break
                    end
                catch e
                    last_error = e
                    sleep(0.5)
                end
            end

            if !server_ready
                @error "Server did not become ready after 20 seconds" last_error
            end
            @test server_ready

            # Now run the actual authentication tests
            request_body = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "test_echo",
                        "arguments" => Dict("message" => "hello"),
                    ),
                ),
            )

            # Test 1: No API key - should fail with 401
            response = HTTP.post(
                "http://localhost:$test_port/",
                ["Content-Type" => "application/json"],
                request_body;
                status_exception = false,
                readtimeout = 10,
                retry = false,
            )

            @test response.status == 401  # Unauthorized
            body = JSON.parse(String(response.body))
            @test contains(body["error"], "Unauthorized")

            # Test 2: Invalid API key - should fail with 403
            response = HTTP.post(
                "http://localhost:$test_port/",
                [
                    "Content-Type" => "application/json",
                    "Authorization" => "Bearer invalid_key",
                ],
                request_body;
                status_exception = false,
                readtimeout = 10,
                retry = false,
            )

            @test response.status == 403  # Forbidden
            body = JSON.parse(String(response.body))
            @test contains(body["error"], "Forbidden")

            # Test 3: Valid API key - should succeed with 200
            response = HTTP.post(
                "http://localhost:$test_port/",
                [
                    "Content-Type" => "application/json",
                    "Authorization" => "Bearer $api_key",
                ],
                request_body;
                status_exception = false,
                readtimeout = 10,
                retry = false,
            )

            @test response.status == 200
            body = JSON.parse(String(response.body))
            @test haskey(body, "result")
            @test body["result"]["content"][1]["text"] == "hello"

            # Clean up
            Kaimon.stop_mcp_server(server)
            sleep(0.2)
        end

    finally
        cd(original_dir)
        rm(test_dir; recursive = true, force = true)
    end
end

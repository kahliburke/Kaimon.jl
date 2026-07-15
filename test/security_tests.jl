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

        @testset "OAuth Not Implemented" begin
            # We run no OAuth authorization server; only the path predicate that
            # `_stream_oauth` uses to short-circuit these paths to 404 remains.
            for p in (
                "/.well-known/oauth-authorization-server",
                "/.well-known/oauth-authorization-server/mcp",  # RFC 8414 suffix
                "/.well-known/oauth-protected-resource",
                "/.well-known/openid-configuration",  # OIDC discovery
                "/register",   # root dynamic client registration
                "/authorize",
                "/token",
                "/oauth/register",
                "/oauth/authorize",
                "/oauth/token",
            )
                @test Kaimon._is_public_oauth_path(p)
            end
            @test Kaimon._is_public_oauth_path("/oauth/authorize?redirect_uri=x&state=y")
            @test !Kaimon._is_public_oauth_path("/mcp")
            @test !Kaimon._is_public_oauth_path("/oauth/other")
            @test !Kaimon._is_public_oauth_path("/tokenize")  # exact match, no over-reach

            # Regression guard: the anonymous auto-mint machinery must NOT exist —
            # a token endpoint or a "gate accepts a self-minted token" helper would
            # silently bypass strict/relaxed mode. If you reintroduce OAuth, do it
            # with real consent + PKCE, not an auto-mint (see mcp_rpc_methods.jl).
            @test !isdefined(Kaimon, :_oauth_token_response)
            @test !isdefined(Kaimon, :_is_issued_oauth_token)
            @test !isdefined(Kaimon, :_oauth_authorize_response)
            @test !isdefined(Kaimon, :_oauth_metadata_response)
        end

        @testset "Server Authentication" begin
            # Create security config
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

            # Start server with security on an OS-assigned ephemeral port (0) to
            # avoid fixed-port collisions across runs; read the actual port back.
            server = Kaimon.start_mcp_server(
                [test_tool],
                0;
                verbose = false,
                security_config = security_config,
            )
            test_port = server.port

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
                        request_timeout = 5,
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
                request_timeout = 10,
                retry = false,
            )

            @test response.status == 401  # Unauthorized
            # RFC 6750 challenge so an OAuth client can begin discovery, and a
            # string-typed `error` a strict OAuth client can parse (not a
            # JSON-RPC error object).
            @test !isempty(HTTP.header(response, "WWW-Authenticate"))
            body = JSON.parse(String(response.body))
            @test body["error"] == "invalid_token"

            # Test 2: Invalid API key - 401 (RFC 6750: invalid_token), so the
            # client re-authenticates rather than treating it as a hard forbid.
            response = HTTP.post(
                "http://localhost:$test_port/",
                [
                    "Content-Type" => "application/json",
                    "Authorization" => "Bearer invalid_key",
                ],
                request_body;
                status_exception = false,
                request_timeout = 10,
                retry = false,
            )

            @test response.status == 401
            @test !isempty(HTTP.header(response, "WWW-Authenticate"))
            body = JSON.parse(String(response.body))
            @test body["error"] == "invalid_token"

            # Test 3: Valid API key - should succeed with 200
            response = HTTP.post(
                "http://localhost:$test_port/",
                [
                    "Content-Type" => "application/json",
                    "Authorization" => "Bearer $api_key",
                ],
                request_body;
                status_exception = false,
                request_timeout = 10,
                retry = false,
            )

            @test response.status == 200
            body = JSON.parse(String(response.body))
            @test haskey(body, "result")
            @test body["result"]["content"][1]["text"] == "hello"

            # ── OAuth is not advertised, and nothing can be self-minted ──────
            # Discovery endpoints return a clean 404 (RFC 8414 "no metadata"),
            # unauthenticated, even in strict mode — so a client's OAuth probe
            # concludes "no OAuth here" and falls back to its API-key bearer.
            for path in (
                "/.well-known/oauth-authorization-server",
                "/.well-known/oauth-protected-resource",
            )
                r = HTTP.get(
                    "http://localhost:$test_port$path";
                    status_exception = false,
                    retry = false,
                )
                @test r.status == 404
            end

            # The token endpoint mints nothing — a client cannot self-authorize.
            tok_resp = HTTP.post(
                "http://localhost:$test_port/oauth/token",
                ["Content-Type" => "application/x-www-form-urlencoded"],
                "grant_type=authorization_code&code=abc";
                status_exception = false,
                retry = false,
            )
            @test tok_resp.status == 404

            # SECURITY: a fabricated `access_*` bearer (the shape a minting flow
            # would have produced) is rejected — no strict-mode bypass.
            response = HTTP.post(
                "http://localhost:$test_port/",
                [
                    "Content-Type" => "application/json",
                    "Authorization" => "Bearer access_fabricated_deadbeef",
                ],
                request_body;
                status_exception = false,
                request_timeout = 10,
                retry = false,
            )
            @test response.status == 401  # not accepted

            # Clean up
            Kaimon.stop_mcp_server(server)
            sleep(0.2)
        end

        @testset "OAuth Not Advertised in Lax Mode" begin
            # In lax mode there is nothing to authenticate, so no OAuth is
            # advertised — discovery endpoints 404 (which is how a client learns
            # the server needs no auth).
            lax_config = Kaimon.SecurityConfig(:lax, String[], ["127.0.0.1", "::1"])
            noop_tool = Kaimon.@mcp_tool(
                :noop,
                "noop",
                Kaimon.text_parameter("x", "x"),
                args -> "ok"
            )
            server = Kaimon.start_mcp_server(
                [noop_tool],
                0;
                verbose = false,
                security_config = lax_config,
            )
            test_port = server.port
            try
                ready = false
                for _ = 1:40
                    try
                        r = HTTP.get(
                            "http://localhost:$test_port/.well-known/oauth-authorization-server";
                            status_exception = false,
                            retry = false,
                            connect_timeout = 5,
                        )
                        if r.status >= 100
                            ready = true
                            break
                        end
                    catch
                        sleep(0.5)
                    end
                end
                @test ready

                r = HTTP.get(
                    "http://localhost:$test_port/.well-known/oauth-authorization-server";
                    status_exception = false,
                    retry = false,
                )
                @test r.status == 404
            finally
                Kaimon.stop_mcp_server(server)
                sleep(0.2)
            end
        end

    finally
        cd(original_dir)
        rm(test_dir; recursive = true, force = true)
    end
end

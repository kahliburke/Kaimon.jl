using ReTest
using Kaimon
using Kaimon: MCPTool
using HTTP
using JSON

# Simple test tool
test_tool =
    @mcp_tool :test_tool "Test tool" Kaimon.text_parameter("input", "Test input") args ->
        "test output"

resources_tools = [test_tool]

@testset "Resources and Prompts Methods" begin
    @testset "MCPServer: resources/list" begin
        test_port = 13100
        server = Kaimon.start_mcp_server(resources_tools, test_port)
        sleep(0.1)

        try
            request_body =
                JSON.json(Dict("jsonrpc" => "2.0", "id" => 1, "method" => "resources/list"))

            response = HTTP.post(
                "http://localhost:$test_port/",
                ["Content-Type" => "application/json"],
                request_body;
                status_exception = false,
            )

            @test response.status == 200

            body = String(response.body)
            json_response = JSON.parse(body)

            @test haskey(json_response, "jsonrpc")
            @test json_response["jsonrpc"] == "2.0"
            @test haskey(json_response, "id")
            @test json_response["id"] == 1
            @test haskey(json_response, "result")
            @test haskey(json_response["result"], "resources")
            @test json_response["result"]["resources"] isa Array
            @test isempty(json_response["result"]["resources"])

        finally
            Kaimon.stop_mcp_server(server)
            sleep(0.1)
        end
    end

    @testset "MCPServer: resources/templates/list" begin
        test_port = 13101
        server = Kaimon.start_mcp_server(resources_tools, test_port)
        sleep(0.1)

        try
            request_body = JSON.json(
                Dict("jsonrpc" => "2.0", "id" => 2, "method" => "resources/templates/list"),
            )

            response = HTTP.post(
                "http://localhost:$test_port/",
                ["Content-Type" => "application/json"],
                request_body;
                status_exception = false,
            )

            @test response.status == 200

            body = String(response.body)
            json_response = JSON.parse(body)

            @test haskey(json_response, "jsonrpc")
            @test json_response["jsonrpc"] == "2.0"
            @test haskey(json_response, "id")
            @test json_response["id"] == 2
            @test haskey(json_response, "result")
            @test haskey(json_response["result"], "resourceTemplates")
            @test json_response["result"]["resourceTemplates"] isa Array
            @test isempty(json_response["result"]["resourceTemplates"])

        finally
            Kaimon.stop_mcp_server(server)
            sleep(0.1)
        end
    end

    @testset "MCPServer: prompts/list" begin
        test_port = 13102
        server = Kaimon.start_mcp_server(resources_tools, test_port)
        sleep(0.1)

        try
            request_body =
                JSON.json(Dict("jsonrpc" => "2.0", "id" => 3, "method" => "prompts/list"))

            response = HTTP.post(
                "http://localhost:$test_port/",
                ["Content-Type" => "application/json"],
                request_body;
                status_exception = false,
            )

            @test response.status == 200

            body = String(response.body)
            json_response = JSON.parse(body)

            @test haskey(json_response, "jsonrpc")
            @test json_response["jsonrpc"] == "2.0"
            @test haskey(json_response, "id")
            @test json_response["id"] == 3
            @test haskey(json_response, "result")
            @test haskey(json_response["result"], "prompts")
            @test json_response["result"]["prompts"] isa Array

        finally
            Kaimon.stop_mcp_server(server)
            sleep(0.1)
        end
    end
end

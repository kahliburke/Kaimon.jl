using ReTest, Kaimon, TOML

@testset "Codex installer: native HTTP configuration" begin
    for api_key in (nothing, raw"fixture-key-with-\"quotes\"-$-and-λ")
        mktempdir() do home
            withenv("CODEX_HOME" => joinpath(home, "custom"), "PATH" => "") do
                m = Kaimon.KaimonModel()
                Kaimon._install_codex(m, 2828, api_key)
                path = joinpath(home, "custom", "config.toml")
                @test m.flow_success
                @test Kaimon._codex_configured()
                @test occursin("Codex CLI / VS Code", m.flow_message)
                entry = TOML.parsefile(path)["mcp_servers"]["kaimon"]
                @test entry["url"] == "http://localhost:2828/mcp"
                @test entry["enabled"] === true
                @test !haskey(entry, "command") && !haskey(entry, "args")
                if api_key === nothing
                    @test !haskey(entry, "http_headers")
                else
                    @test entry["http_headers"]["Authorization"] == "Bearer $api_key"
                end
                Sys.iswindows() || @test filemode(path) & 0o777 == 0o600
                first_write = read(path, String)
                Kaimon._install_codex(m, 2828, api_key)
                @test read(path, String) == first_write
            end
        end
    end
    withenv("CODEX_HOME" => "") do
        @test Kaimon._codex_config_path() == joinpath(homedir(), ".codex", "config.toml")
    end
end

@testset "Codex installer: migrate bridge and preserve settings and login" begin
    mktempdir() do home
        withenv("CODEX_HOME" => home, "PATH" => "") do
            path = joinpath(home, "config.toml")
            config = Dict{String,Any}(
                "model" => "keep-model", "approval_policy" => "on-request",
                "model_reasoning_effort" => "high", "developer_instructions" => "Keep λ and \"quotes\".",
                "projects" => Dict("/my/project" => Dict("trust_level" => "trusted")),
                "mcp_servers" => Dict{String,Any}(
                    "other" => Dict("command" => "keep-command", "args" => ["keep-arg"]),
                    "Kaimon" => Dict{String,Any}(
                        "command" => "npx", "args" => ["-y", "mcp-remote", "http://localhost:1234/mcp"],
                        "env" => Dict("MCPREPL_API_KEY" => "old-key"),
                        "env_vars" => ["OLD_VAR"], "cwd" => "/old/bridge", "enabled" => false,
                        "enabled_tools" => ["ping", "ex"], "tool_timeout_sec" => 180,
                        "http_headers" => Dict("authorization" => "old-auth", "X-Custom" => "keep"),
                        "bearer_token_env_var" => "OLD_TOKEN",
                        "http_headers_helper" => "old-auth-helper",
                        "env_http_headers" => Dict("Authorization" => "OLD_TOKEN", "X-Tenant" => "TENANT"))))
            open(io -> TOML.print(io, config), path, "w")
            # These files belong to the user's login and other connections, not this installer.
            auth = "{\"fixture_login\":\"keep-this\"}\n"
            env = "MCPREPL_API_KEY=shared-fixture\nOTHER_KEY=keep-this\n"
            write(joinpath(home, "auth.json"), auth)
            write(joinpath(home, ".env"), env)
            m = Kaimon.KaimonModel()
            Kaimon._install_codex(m, 3456, "new-key")
            @test Kaimon._codex_configured()
            updated = TOML.parsefile(path)
            for key in ("model", "approval_policy", "model_reasoning_effort", "developer_instructions", "projects")
                @test updated[key] == config[key]
            end
            @test Set(keys(updated["mcp_servers"])) == Set(["Kaimon", "other"])
            @test updated["mcp_servers"]["other"] == config["mcp_servers"]["other"]
            entry = updated["mcp_servers"]["Kaimon"]
            @test entry["url"] == "http://localhost:3456/mcp"
            @test entry["enabled"] === true
            @test entry["enabled_tools"] == ["ping", "ex"]
            @test entry["tool_timeout_sec"] == 180
            @test entry["http_headers"] == Dict("Authorization" => "Bearer new-key", "X-Custom" => "keep")
            @test entry["env_http_headers"] == Dict("X-Tenant" => "TENANT")
            @test all(k -> !haskey(entry, k), ("command", "args", "env", "env_vars", "cwd",
                                              "bearer_token_env_var", "http_headers_helper"))
            # Reconfiguring a native connection for lax mode must remove stale auth too.
            Kaimon._install_codex(m, 3456, nothing)
            @test TOML.parsefile(path)["mcp_servers"]["Kaimon"]["http_headers"] == Dict("X-Custom" => "keep")
            Kaimon._remove_codex(m)
            @test !Kaimon._codex_configured()
            expected = deepcopy(config)
            delete!(expected["mcp_servers"], "Kaimon")
            @test TOML.parsefile(path) == expected
            @test read(joinpath(home, "auth.json"), String) == auth
            @test read(joinpath(home, ".env"), String) == env
            Kaimon._remove_codex(m)  # idempotent removal
            @test TOML.parsefile(path) == expected
        end
    end
end

@testset "Codex installer: invalid or ambiguous configuration stays untouched" begin
    for original in ("model = [broken", "mcp_servers = 3\n",
                     "[mcp_servers.kaimon]\nurl = 'http://one/mcp'\n[mcp_servers.Kaimon]\nurl = 'http://two/mcp'\n")
        mktempdir() do home
            withenv("CODEX_HOME" => home) do
                path = joinpath(home, "config.toml")
                write(path, original)
                m = Kaimon.KaimonModel()
                @test_throws Exception Kaimon._install_codex(m, 2828, "fixture-key")
                @test read(path, String) == original
                @test_throws Exception Kaimon._remove_codex(m)
                @test read(path, String) == original
            end
        end
    end
    mktempdir() do home
        withenv("CODEX_HOME" => home) do
            Kaimon._remove_codex(Kaimon.KaimonModel())
            @test !isfile(joinpath(home, "config.toml"))
            @test !Kaimon._codex_configured()
            write(joinpath(home, "config.toml"), "developer_instructions = 'Use kaimon tools'\n")
            @test !Kaimon._codex_configured()  # mention in an unrelated setting is not a connection
            write(joinpath(home, "config.toml"), "mcp_servers = [broken")
            @test !Kaimon._codex_configured()
        end
    end
end

if !Sys.iswindows()
@testset "Codex installer: retain a symlinked configuration" begin
    mktempdir() do home
        target = joinpath(home, "shared.toml")
        write(target, "model = 'keep-model'\n")
        codex_home = joinpath(home, "codex")
        mkpath(codex_home)
        path = joinpath(codex_home, "config.toml")
        symlink(target, path)
        withenv("CODEX_HOME" => codex_home) do
            Kaimon._install_codex(Kaimon.KaimonModel(), 2828, "fixture-key")
            @test islink(path) && realpath(path) == realpath(target)
            @test TOML.parsefile(target)["model"] == "keep-model"
            @test TOML.parsefile(target)["mcp_servers"]["kaimon"]["url"] == "http://localhost:2828/mcp"
        end
    end
end
end

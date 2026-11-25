using ReTest
using Kaimon

@testset "setup defaults, for installers" begin
    KS = Kaimon
    dir = mktempdir()
    # A stand-in for the claude command: it records what it is asked, and knows no Kaimon until added.
    log = joinpath(dir, "claude.log")
    claude = joinpath(dir, "claude")
    write(claude, """
        #!/bin/sh
        echo "\$@" >> $log
        [ "\$1 \$2" = "mcp get" ] && ! grep -q "mcp add" $log && exit 1
        exit 0
        """)
    chmod(claude, 0o755)
    pulled = String[]
    installs = Ref(0)
    run_it(; kw...) = KS.setup_defaults!(; io = devnull, pull = (url, m) -> (push!(pulled, m); true),
                                          install_qdrant = () -> (installs[] += 1), claude, kw...)
    try
        withenv("KAIMON_CONFIG_DIR" => joinpath(dir, "config"), "KAIMON_CACHE_DIR" => joinpath(dir, "cache"),
                "KAIMON_QDRANT_URL" => nothing, "OLLAMA_HOST" => nothing, "KAIMON_OLLAMA_URL" => nothing) do
            said = run_it(; port = 2900, embedding_model = "qwen3-embedding:4b")
            cfg = KS.load_global_config()
            @test cfg.mode === :lax && isempty(cfg.api_keys) && cfg.allowed_ips == ["127.0.0.1", "::1"] && cfg.port == 2900
            @test KS._get_gate_setup_version() == KS.GATE_SETUP_VERSION
            search = KS.load_search_config()
            @test search["embedding_model"] == "qwen3-embedding:4b" && search["embedding"]["backend"] == "ollama"
            @test pulled == ["qwen3-embedding:4b"]
            @test installs[] == (KS.managed_qdrant_installed() ? 0 : 1)
            @test occursin("mcp add --scope user --transport http kaimon http://localhost:2900/mcp", read(log, String))
            @test any(startswith("Settings: lax"), said) && any(startswith("Claude Code: connected at"), said)

            # Again: nothing set is changed, and Claude Code is found connected.
            KS._set_gate_setup_version(0)
            said = run_it(; port = 3000, embedding_model = "other")
            @test KS.load_global_config().port == 2900 && KS.load_search_config()["embedding_model"] == "qwen3-embedding:4b"
            @test KS._get_gate_setup_version() == 0
            @test count("mcp add", read(log, String)) == 1 && "Claude Code: connected" in said
            @test "Settings: kept ($(KS.get_global_config_path()))" in said

            # A Kaimon that takes keys leaves Claude Code to its own setup; no claude, nothing to connect.
            KS.save_global_config(KS.KaimonConfig(:strict, ["k"], ["127.0.0.1"], 2900))
            @test any(startswith("Claude Code: Kaimon takes a key"), run_it())
            @test "Claude Code: not installed" in run_it(; claude = "")
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end

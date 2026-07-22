using ReTest
using Kaimon
using TOML

@testset "Version Info Tests" begin
    @testset "version_info() returns valid format" begin
        version = Kaimon.version_info()

        # Should not return error states
        @test version != "unknown"
        @test version != "git-error"

        # Should return one of the valid formats:
        # - Short git hash (7 chars)
        # - Short git hash with -dirty suffix
        # - Version from Project.toml (v0.3.0 format)

        if occursin(r"^[0-9a-f]{7}(-dirty)?$", version)
            # Git commit hash format
            @test length(version) >= 7
            @test length(version) <= 13  # 7 chars + "-dirty"
        elseif startswith(version, "v")
            # Project.toml version format
            @test occursin(r"^v\d+\.\d+\.\d+", version)
        else
            error("Unexpected version format: $version")
        end
    end

    @testset "version_info() reads from Project.toml" begin
        # Simulate installed package scenario by testing the fallback logic
        pkg_dir = pkgdir(Kaimon)
        project_file = joinpath(pkg_dir, "Project.toml")

        # Project.toml should exist
        @test isfile(project_file)

        # Should have version field
        project = TOML.parsefile(project_file)
        @test haskey(project, "version")
        @test project["version"] isa String
        @test occursin(r"^\d+\.\d+\.\d+", project["version"])
    end

    @testset "version_info() handles git repo" begin
        pkg_dir = pkgdir(Kaimon)
        git_dir = joinpath(pkg_dir, ".git")

        if isdir(git_dir)
            # If this is a git repo (dev package), should return git hash
            version = Kaimon.version_info()

            # Should be a valid git short hash (7 hex chars) or include -dirty
            @test occursin(r"^[0-9a-f]{7}(-dirty)?$", version) || startswith(version, "v")
        else
            # If not a git repo (installed package), should return version from Project.toml
            version = Kaimon.version_info()
            @test startswith(version, "v")
        end
    end

    @testset "version_info() consistency" begin
        # Multiple calls should return the same value
        v1 = Kaimon.version_info()
        v2 = Kaimon.version_info()
        @test v1 == v2

        # Should be non-empty
        @test !isempty(v1)
    end

    @testset "PACKAGE_VERSION constant" begin
        pv = Kaimon.PACKAGE_VERSION
        @test pv isa String
        @test !isempty(pv)

        # Should be a valid semver string
        @test occursin(r"^\d+\.\d+\.\d+", pv)

        # Should be a plausible Kaimon version (may differ from Project.toml
        # if precompile cache is stale, which is exactly what the version
        # mismatch check is designed to catch)
        @test VersionNumber(pv) >= v"1.0.0"
    end

    @testset "Version mismatch detection" begin
        # protocol mismatch warnings should only fire once per session (via _VERSION_WARNED)
        warned = Kaimon._VERSION_WARNED
        original = copy(warned)
        try
            empty!(warned)
            # Simulate: after adding a session_id, it shouldn't warn again
            push!(warned, "test-session-123")
            @test "test-session-123" in warned

            # Calling again with same session_id should be a no-op
            # (we can't easily test the full warning path without a ConnectionManager,
            #  but we can verify the dedup set works)
            push!(warned, "test-session-123")
            @test length(filter(==("test-session-123"), collect(warned))) == 1
        finally
            empty!(warned)
            union!(warned, original)
        end
    end

    @testset "Gate pong includes kaimon_version" begin
        # Verify the pong handler includes kaimon_version (structural test).
        # The gate lives in the KaimonGate package, split across gate_*.jl files.
        srcdir = joinpath(pkgdir(Kaimon.KaimonGate), "src")
        gate_src = join(
            (read(joinpath(srcdir, f), String)
             for f in readdir(srcdir) if startswith(f, "gate") && endswith(f, ".jl")),
            "\n",
        )
        @test occursin("kaimon_version", gate_src)
    end

    @testset "MCP server uses PACKAGE_VERSION" begin
        # Verify the MCP server uses PACKAGE_VERSION instead of a hardcoded version.
        # The server is split across MCPServer.jl + mcp_*.jl (the initialize handler
        # that stamps the version now lives in mcp_rpc_methods.jl).
        srcdir = joinpath(pkgdir(Kaimon), "src")
        mcp_src = join(
            (read(joinpath(srcdir, f), String)
             for f in readdir(srcdir) if startswith(f, "mcp") || f == "MCPServer.jl"),
            "\n",
        )
        @test occursin("PACKAGE_VERSION", mcp_src)
        @test !occursin("\"0.4.0\"", mcp_src)
    end

    @testset "Global KaimonGate version detection" begin
        mktempdir() do dir
            mpath = joinpath(dir, "Manifest.toml")

            # Absent manifest → nothing.
            @test Kaimon._global_kaimongate_version(mpath) === nothing

            # Format 2.0, registry-tracked (no `path`) → (version, is_dev=false).
            write(mpath, """
            manifest_format = "2.0"
            [[deps.KaimonGate]]
            uuid = "5ee84a8c-75bd-412f-a7b8-4e6463aa635f"
            version = "1.0.1"
            """)
            info = Kaimon._global_kaimongate_version(mpath)
            @test info !== nothing
            @test info.version == v"1.0.1"
            @test info.is_dev == false

            # Format 2.0, dev/path install → is_dev=true (never treated as stale).
            write(mpath, """
            manifest_format = "2.0"
            [[deps.KaimonGate]]
            path = "/somewhere/lib/KaimonGate"
            uuid = "5ee84a8c-75bd-412f-a7b8-4e6463aa635f"
            version = "1.1.0"
            """)
            info = Kaimon._global_kaimongate_version(mpath)
            @test info !== nothing
            @test info.is_dev == true

            # Older flat manifest layout (package tables at top level).
            write(mpath, """
            [[KaimonGate]]
            uuid = "5ee84a8c-75bd-412f-a7b8-4e6463aa635f"
            version = "1.0.0"
            """)
            info = Kaimon._global_kaimongate_version(mpath)
            @test info !== nothing
            @test info.version == v"1.0.0"

            # KaimonGate absent from a populated manifest → nothing.
            write(mpath, """
            manifest_format = "2.0"
            [[deps.SomethingElse]]
            uuid = "00000000-0000-0000-0000-000000000000"
            version = "1.2.3"
            """)
            @test Kaimon._global_kaimongate_version(mpath) === nothing

            # Unparseable manifest → nothing (not a throw).
            write(mpath, "this is not valid toml = = =")
            @test Kaimon._global_kaimongate_version(mpath) === nothing
        end
    end

    @testset "Gate upgrade dismissal preference" begin
        # Isolate config writes to a temp dir so we never touch the user's real config.
        mktempdir() do cfg
            withenv("XDG_CONFIG_HOME" => cfg, "APPDATA" => cfg) do
                @test Kaimon._get_gate_upgrade_dismissed_version() == ""  # default
                @test Kaimon._set_gate_upgrade_dismissed_version("1.1.0")
                @test Kaimon._get_gate_upgrade_dismissed_version() == "1.1.0"
                # Clearing (as `--reset-global-prompt` does) restores the default.
                @test Kaimon._set_gate_upgrade_dismissed_version("")
                @test Kaimon._get_gate_upgrade_dismissed_version() == ""
            end
        end
    end

    @testset "Gate upgrade prompt is a no-op without a TTY" begin
        # The test runner's stdin isn't a TTY, so the prompt must return quietly
        # without prompting, updating, or writing any dismissal.
        mktempdir() do cfg
            withenv("XDG_CONFIG_HOME" => cfg, "APPDATA" => cfg) do
                @test Kaimon._maybe_run_gate_upgrade() === nothing
                @test Kaimon._get_gate_upgrade_dismissed_version() == ""
            end
        end
    end
end

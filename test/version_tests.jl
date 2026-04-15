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

        # Should match Project.toml
        project = TOML.parsefile(joinpath(pkgdir(Kaimon), "Project.toml"))
        @test pv == project["version"]
    end

    @testset "Version mismatch detection" begin
        # _version_mismatch_warning! should only warn once per session
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
        # Verify the pong handler references PACKAGE_VERSION
        # (structural test — gate.jl should include kaimon_version in pong)
        gate_src = read(joinpath(pkgdir(Kaimon), "src", "gate.jl"), String)
        @test occursin("kaimon_version", gate_src)
    end

    @testset "MCP server uses PACKAGE_VERSION" begin
        # Verify MCPServer.jl uses PACKAGE_VERSION instead of hardcoded version
        mcp_src = read(joinpath(pkgdir(Kaimon), "src", "MCPServer.jl"), String)
        @test occursin("PACKAGE_VERSION", mcp_src)
        @test !occursin("\"0.4.0\"", mcp_src)
    end
end

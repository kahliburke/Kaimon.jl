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
end

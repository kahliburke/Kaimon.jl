# Tests for the project allow-list and the `allow_any_project` opt-in (#46).

using ReTest
using Kaimon

@testset "Project allow-list + allow_any_project (#46)" begin
    mktempdir() do tmp
        old = get(ENV, "XDG_CONFIG_HOME", nothing)
        ENV["XDG_CONFIG_HOME"] = tmp
        try
            Kaimon.kaimon_config_dir()                  # ensure <tmp>/kaimon exists
            pjson = Kaimon.get_projects_config_path()

            allowed = mktempdir(); write(joinpath(allowed, "Project.toml"), "name = \"X\"\n")
            other   = mktempdir(); write(joinpath(other, "Project.toml"), "name = \"Y\"\n")

            # Without the flag: only the listed, enabled project is allowed.
            write(pjson, """{"projects":[{"project_path":"$allowed","enabled":true}]}""")
            @test Kaimon.projects_allow_any() == false
            @test Kaimon.is_project_allowed(allowed)
            @test !Kaimon.is_project_allowed(other)

            # With the flag: any path is allowed (the allow-list is bypassed).
            write(pjson, """{"allow_any_project":true,"projects":[]}""")
            @test Kaimon.projects_allow_any() == true
            @test Kaimon.is_project_allowed(other)
            @test Kaimon.is_project_allowed("/nonexistent/whatever")

            # Explicit false behaves like absent.
            write(pjson, """{"allow_any_project":false,"projects":[]}""")
            @test Kaimon.projects_allow_any() == false
            @test !Kaimon.is_project_allowed(other)
        finally
            old === nothing ? delete!(ENV, "XDG_CONFIG_HOME") : (ENV["XDG_CONFIG_HOME"] = old)
        end
    end
end

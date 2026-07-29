# Tests for the project allow-list and the `allow_any_project` opt-in (#46),
# and the per-project launch config incl. custom system images (#69).

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

@testset "Launch config: custom sysimage / julia binary (#69)" begin
    K = Kaimon
    flagof(cmd, name) = something(findfirst(a -> startswith(a, name), cmd), 0)

    @testset "command construction" begin
        proj = mktempdir()
        img = joinpath(proj, "custom.so"); write(img, "x")

        # Default: host Julia, no sysimage, startup.jl suppressed.
        cmd = K._build_julia_cmd(K.LaunchConfig(), "boot()"; project = proj)
        @test cmd[1] == joinpath(Sys.BINDIR, "julia")
        @test !any(a -> startswith(a, "--sysimage"), cmd)
        @test "--startup-file=no" in cmd

        # A relative sysimage resolves against the project root, so a repo can name the
        # image its own build script produces.
        lc = K.LaunchConfig("", "", "", String[], "custom.so", "", true)
        cmd = K._build_julia_cmd(lc, "boot()"; project = proj)
        @test "--sysimage=$(abspath(img))" in cmd
        @test "--startup-file=yes" in cmd
        @test !("--startup-file=no" in cmd)
        # The sysimage must precede the boot script, or `using` in it misses the baked code
        @test flagof(cmd, "--sysimage") < flagof(cmd, "-e")

        # Absolute paths and ~ are honored as-is.
        abs_img = joinpath(mktempdir(), "abs.so"); write(abs_img, "x")
        cmd = K._build_julia_cmd(K.LaunchConfig("", "", "", String[], abs_img, "", false),
                                 "boot()"; project = proj)
        @test "--sysimage=$abs_img" in cmd

        # A configured-but-missing image degrades to the default rather than failing the spawn.
        cmd = K._build_julia_cmd(K.LaunchConfig("", "", "", String[], "gone.so", "", false),
                                 "boot()"; project = proj)
        @test !any(a -> startswith(a, "--sysimage"), cmd)

        # A custom binary (possibly a wrapper script) replaces the host Julia.
        cmd = K._build_julia_cmd(K.LaunchConfig("", "", "", String[], "", "/opt/jl/run", false),
                                 "boot()"; project = proj)
        @test cmd[1] == "/opt/jl/run"
    end

    @testset "kaimon.toml [launch] + projects.json overlay" begin
        proj = mktempdir()
        write(joinpath(proj, "custom.so"), "x")
        write(joinpath(proj, "kaimon.toml"), """
        [launch]
        sysimage = "custom.so"
        threads = "4"
        startup_file = true
        """)

        toml_lc = K.load_toml_launch_config(proj)
        @test toml_lc !== nothing
        @test toml_lc.sysimage == "custom.so"
        @test toml_lc.threads == "4"
        @test toml_lc.startup_file

        # No [launch] section / no file → nothing (so the default config applies).
        @test K.load_toml_launch_config(mktempdir()) === nothing

        # The user's entry wins field-wise; unset fields fall through to the repo's defaults.
        user = K.LaunchConfig("8", "", "", String[], "", "", false)
        merged = K.merge_launch_config(toml_lc, user)
        @test merged.threads == "8"          # user override
        @test merged.sysimage == "custom.so" # repo default survives
        @test merged.startup_file

        old = get(ENV, "XDG_CONFIG_HOME", nothing)
        ENV["XDG_CONFIG_HOME"] = mktempdir()
        try
            K.kaimon_config_dir()
            write(K.get_projects_config_path(),
                  """{"projects":[{"project_path":"$proj","enabled":true,
                     "launch_config":{"threads":"8"}}]}""")
            # Nested JSON objects parse as JSON.Object, not Dict — an `isa Dict` guard
            # silently drops every launch config / session pref read back from disk.
            @test K.load_projects_config()[1].launch_config.threads == "8"
            write(K.get_projects_config_path(),
                  """{"projects":[{"project_path":"$proj","enabled":true,
                     "launch_config":{"threads":"8"}}],
                     "session_prefs":{"$proj":{"allow_restart":false,"mirror_repl":true}}}""")
            prefs = K.load_session_prefs()
            @test K.resolve_session_pref(prefs, proj, :allow_restart) === false
            @test K.resolve_session_pref(prefs, proj, :mirror_repl) === true

            eff = K._resolve_launch_config(proj)
            @test eff.threads == "8"
            @test eff.sysimage == "custom.so"
            cmd = K._build_julia_cmd(eff, "boot()"; project = proj)
            @test "--sysimage=$(abspath(joinpath(proj, "custom.so")))" in cmd
            @test "-t" in cmd && cmd[flagof(cmd, "-t") + 1] == "8"
        finally
            old === nothing ? delete!(ENV, "XDG_CONFIG_HOME") : (ENV["XDG_CONFIG_HOME"] = old)
        end
    end

    @testset "round-trip + summary" begin
        lc = K.LaunchConfig("4", "2", "8G", ["--inline=no"], "img.so", "/opt/jl/run", true)
        d = K._project_entry_to_dict(K.ProjectEntry("/p", true, lc))["launch_config"]
        back = K._parse_launch_config(d)
        @test back.sysimage == "img.so"
        @test back.julia_bin == "/opt/jl/run"
        @test back.startup_file
        @test back.extra_flags == ["--inline=no"]

        # Old configs (written before these fields existed) still load.
        @test K._parse_launch_config(Dict("threads" => "4")).sysimage == ""
        @test K._parse_launch_config(Dict("threads" => "4")).startup_file == false

        s = K.launch_config_summary(lc)
        @test occursin("-J img.so", s)
        @test occursin("run", s)
        @test occursin("--startup-file=yes", s)
    end
end

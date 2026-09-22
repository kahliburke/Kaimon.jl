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

@testset "Launch config: portable julia_version (#91)" begin
    K = Kaimon

    @testset "a version request designates a version" begin
        # An exact patch matches only itself.
        @test K.julia_version_matches("1.12.6", v"1.12.6")
        @test !K.julia_version_matches("1.12.6", v"1.12.7")
        @test !K.julia_version_matches("1.12.6", v"1.13.6")

        # A series matches any patch in it, so a project can pin the minor it supports
        # without naming a patch that ages out.
        @test K.julia_version_matches("1.12", v"1.12.0")
        @test K.julia_version_matches("1.12", v"1.12.7")
        @test !K.julia_version_matches("1.12", v"1.13.0")

        # "1.12" must stay a series: `tryparse(VersionNumber, "1.12")` yields 1.12.0, which
        # would silently turn a series request into an exact-patch one.
        @test K.julia_version_matches("1.12", v"1.12.7")

        # Junk designates nothing rather than throwing.
        for bad in ("", "1", "abc", "1.x", "1.12.x", "1.12.6.4")
            @test !K.julia_version_matches(bad, VERSION)
        end
    end

    @testset "installed versions come from juliaup's own state file" begin
        depot = mktempdir()
        # juliaup records a BinaryPath per install because the layout is platform-specific
        # (on macOS the binary sits inside an .app bundle), so honor it rather than guessing.
        # Versions no host will ever be. `resolve_julia_binary` matches the RUNNING Julia before
        # juliaup, which is the point of the assertions below — so a fixture using a real series
        # tests one thing on a host inside that series and another everywhere else.
        bin986 = joinpath(depot, "julia-1.98.6", "nested", "bin", "julia")
        bin1990 = joinpath(depot, "julia-1.99.0", "nested", "bin", "julia")
        for b in (bin986, bin1990)
            mkpath(dirname(b))
            write(b, "")
        end
        write(joinpath(depot, "juliaup.json"), """
        {
          "Default": "release",
          "InstalledVersions": {
            "1.98.6+0.x": {"Path": "./julia-1.98.6", "BinaryPath": "./julia-1.98.6/nested/bin/julia"},
            "1.99.0+0.x": {"Path": "./julia-1.99.0", "BinaryPath": "./julia-1.99.0/nested/bin/julia"},
            "9.9.9+0.x": {"Path": "./gone", "BinaryPath": "./gone/bin/julia"}
          }
        }
        """)

        old = get(ENV, "JULIAUP_DEPOT_PATH", nothing)
        try
            ENV["JULIAUP_DEPOT_PATH"] = depot
            @test K.juliaup_dir() == depot

            found = K.juliaup_installed_julias()
            # An install whose recorded binary is gone is not offered as available.
            @test length(found) == 2
            # Newest first, so a series request takes the newest patch in it.
            @test first(found)[1] == v"1.99.0"
            @test Dict(found)[v"1.98.6"] == bin986

            @test K.resolve_julia_binary("1.98.6") == bin986
            @test K.resolve_julia_binary("1.99") == bin1990
            # Not installed → nothing, so the caller can decide whether to offer an install.
            @test K.resolve_julia_binary("1.97.4") === nothing

            # The running Julia is matched before juliaup, so a project asking for the
            # version already in use needs no juliaup at all.
            host = joinpath(Sys.BINDIR, "julia")
            @test K.resolve_julia_binary(string(VERSION)) == host
            @test K.resolve_julia_binary("$(VERSION.major).$(VERSION.minor)") == host

            # No state file at all → nothing installed, no error.
            ENV["JULIAUP_DEPOT_PATH"] = mktempdir()
            @test isempty(K.juliaup_installed_julias())
            @test K.resolve_julia_binary("1.98.6") === nothing
        finally
            old === nothing ? delete!(ENV, "JULIAUP_DEPOT_PATH") : (ENV["JULIAUP_DEPOT_PATH"] = old)
        end
    end

    @testset "binary precedence: julia_bin > julia_version > host Julia" begin
        depot = mktempdir()
        # A version no host will ever be: the running Julia is matched ahead of juliaup, so a
        # fixture naming a real version passes or fails depending on which Julia runs the suite.
        bin986 = joinpath(depot, "julia-1.98.6", "bin", "julia")
        mkpath(dirname(bin986))
        write(bin986, "")
        write(joinpath(depot, "juliaup.json"), """
        {"InstalledVersions": {"1.98.6+0.x": {"Path": "./julia-1.98.6"}}}
        """)

        old = get(ENV, "JULIAUP_DEPOT_PATH", nothing)
        try
            ENV["JULIAUP_DEPOT_PATH"] = depot
            host = joinpath(Sys.BINDIR, "julia")
            lc(; bin = "", ver = "") =
                K.LaunchConfig("", "", "", String[], "", bin, false, ver)

            # With no BinaryPath recorded, the conventional layout is used.
            @test K.resolve_julia_binary("1.98.6") == bin986

            @test K._launch_julia_exe(lc()) == host
            @test K._launch_julia_exe(lc(ver = "1.98.6")) == bin986
            # julia_bin is the escape hatch, so it outranks a julia_version that juliaup
            # could otherwise satisfy.
            @test K._launch_julia_exe(lc(bin = "/opt/jl/run", ver = "1.98.6")) == "/opt/jl/run"
            # A requested version that isn't installed falls back to the host Julia rather
            # than failing the spawn; the substitution is logged, not silent.
            @test K._launch_julia_exe(lc(ver = "1.97.4")) == host

            # The resolved binary is what the spawned session actually runs.
            cmd = K._build_julia_cmd(lc(ver = "1.98.6"), "boot()"; project = mktempdir())
            @test cmd[1] == bin986
        finally
            old === nothing ? delete!(ENV, "JULIAUP_DEPOT_PATH") : (ENV["JULIAUP_DEPOT_PATH"] = old)
        end
    end

    @testset "julia_version is portable config: TOML, JSON and overlay" begin
        # The point of the field: a repo can check this in, where an absolute julia_bin would
        # only work on its author's machine.
        proj = mktempdir()
        write(joinpath(proj, "kaimon.toml"), """
        [launch]
        julia_version = "1.12.6"
        threads = "4"
        """)
        toml_lc = K.load_toml_launch_config(proj)
        @test toml_lc !== nothing
        @test toml_lc.julia_version == "1.12.6"

        # Round-trips through projects.json.
        lc = K.LaunchConfig("", "", "", String[], "", "", false, "1.12.6")
        d = K._project_entry_to_dict(K.ProjectEntry("/p", true, lc))["launch_config"]
        @test d["julia_version"] == "1.12.6"
        @test K._parse_launch_config(d).julia_version == "1.12.6"

        # A bare `julia_version = 1.12` in TOML parses as a float; keep it readable instead
        # of throwing, and let resolution reject it.
        @test K._parse_launch_config(Dict("julia_version" => 1.12)).julia_version == "1.12"

        # Configs written before the field existed still load.
        @test K._parse_launch_config(Dict("threads" => "4")).julia_version == ""
        @test K.LaunchConfig("4", "", "", String[]).julia_version == ""
        @test K.LaunchConfig("4", "", "", String[], "", "", false).julia_version == ""

        # The user's projects.json entry overrides the repo's checked-in request.
        merged = K.merge_launch_config(toml_lc, K.LaunchConfig("", "", "", String[], "", "", false, "1.13.0"))
        @test merged.julia_version == "1.13.0"
        @test merged.threads == "4"
        # Left unset, the repo's request stands.
        @test K.merge_launch_config(toml_lc, K.LaunchConfig()).julia_version == "1.12.6"

        @test occursin("julia 1.12.6", K.launch_config_summary(lc))
    end

    @testset "the install offer only fires when there is something to install" begin
        proj = mktempdir()
        write(joinpath(proj, "Project.toml"), "name = \"P\"\n")

        # No version requested → nothing to offer.
        @test K._maybe_offer_julia_install(proj) === nothing

        # A version that resolves (the running Julia) → nothing to offer.
        write(joinpath(proj, "kaimon.toml"), """
        [launch]
        julia_version = "$(VERSION.major).$(VERSION.minor)"
        """)
        @test K._maybe_offer_julia_install(proj) === nothing

        # An unresolvable version, but julia_bin set → julia_bin wins, so nothing to offer.
        write(joinpath(proj, "kaimon.toml"), """
        [launch]
        julia_version = "1.11.4"
        julia_bin = "/opt/jl/run"
        """)
        @test K._maybe_offer_julia_install(proj) === nothing

        # Unresolvable with no julia_bin: there IS something to offer, but with no MCP caller
        # to prompt there is no consent to be had, so it proceeds rather than blocking.
        write(joinpath(proj, "kaimon.toml"), """
        [launch]
        julia_version = "1.11.4"
        """)
        @test K._maybe_offer_julia_install(proj) === nothing

        # Downloading a Julia is never automatic — an install needs juliaup AND consent.
        @test K.install_julia_version("")[1] == false
    end

    @testset "an undeliverable prompt is not reported as a timeout" begin
        # A prompt that could not be delivered and a prompt the user ignored are different
        # facts. Collapsing them tells someone to approve a dialog that was never displayed,
        # which is advice they cannot act on.
        schema = Dict{String,Any}("type" => "object", "properties" => Dict{String,Any}())
        # No MCP caller and no receive stream here, so delivery cannot succeed.
        @test K.request_elicitation("no-such-session-id", "hi", schema; timeout = 0.1) ===
              :undeliverable

        # A caller-less call (REPL/self, as here) has nobody to prompt, which is distinct
        # again from having a caller whose channel is closed.
        @test K._elicit_julia_install("1.11.4", "/tmp/p") === :unsupported
    end
end

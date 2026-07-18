# Extension manager tests — orphan-process identification for the Windows reaper.
#
# Windows has no /proc, no readable per-process environment, and no pgrep/kill, so
# `_kill_orphan_extension_processes_windows!` identifies our own extension processes by
# matching markers in their command line. Julia escapes embedded quotes when it builds the
# Windows CreateProcess string (namespace="x" → namespace=\"x\"), so the matcher must see
# the escaped form — these tests reproduce that exact form via `escape_microsoft_c_args`,
# the same routine Julia's `run` uses on Windows.

using ReTest
using Kaimon
using Logging, LoggingExtras

# A value whose show throws, for the log-formatter robustness test below.
struct _ExplodingShow end
Base.show(io::IO, ::_ExplodingShow) = error("show blew up")

@testset "extension orphan cmdline matching" begin
    # Boot script as `_build_extension_script` emits it (the identifying bits).
    boot(ns) = "using Kaimon\nKaimon.KaimonGate.serve(tools=tools, namespace=$(repr(ns)), " *
               "force=true, allow_mirror=false, allow_restart=false, spawned_by=\"extension\")"
    # The Windows command line as CreateProcess stores it (quotes escaped as \").
    winext(ns; project = "C:\\Users\\kb\\dev\\KaimonSlate.jl") =
        Base.escape_microsoft_c_args("C:\\julia\\bin\\julia.exe", "-t", "auto",
            "--startup-file=no", "--project=$project", "-e", boot(ns))

    slate = winext("slate")
    @test Kaimon._extension_cmdline_matches(slate, "slate")      # our slate extension → reap
    @test !Kaimon._extension_cmdline_matches(slate, "todo")      # a different namespace
    @test !Kaimon._extension_cmdline_matches(slate, "sla")       # prefix must not match (closing \")
    @test !Kaimon._extension_cmdline_matches(slate, "slate2")    # nor a superstring namespace

    # A plain julia process (user REPL, script) is never one of ours.
    plain = Base.escape_microsoft_c_args("julia.exe", "--project=C:\\proj", "-e", "1+1")
    @test !Kaimon._extension_cmdline_matches(plain, "slate")

    # A normal spawned SESSION gate (spawned_by defaults to "user", no "extension" marker)
    # for the very same project must NOT be reaped as an extension orphan.
    sess = Base.escape_microsoft_c_args("julia.exe", "--project=C:\\Users\\kb\\dev\\KaimonSlate.jl",
        "-e", "using Kaimon; Kaimon.KaimonGate.serve(namespace=\"kaimonslate\")")
    @test !Kaimon._extension_cmdline_matches(sess, "kaimonslate")

    @test !Kaimon._extension_cmdline_matches("", "slate")        # empty command line
end

@testset "extension startup timeout is generous + configurable" begin
    # Default must comfortably exceed a cold first-run precompile (minutes), so a slow
    # start isn't killed and force-restarted mid-precompile.
    withenv("KAIMON_EXTENSION_STARTUP_TIMEOUT" => nothing) do
        @test Kaimon._extension_startup_timeout() >= 120.0
    end
    # Explicit override honored; junk / non-positive fall back to the default.
    withenv("KAIMON_EXTENSION_STARTUP_TIMEOUT" => "45") do
        @test Kaimon._extension_startup_timeout() == 45.0
    end
    withenv("KAIMON_EXTENSION_STARTUP_TIMEOUT" => "0") do
        @test Kaimon._extension_startup_timeout() >= 120.0
    end
    withenv("KAIMON_EXTENSION_STARTUP_TIMEOUT" => "notanumber") do
        @test Kaimon._extension_startup_timeout() >= 120.0
    end
end

@testset "extension log formatter keeps structured kwargs" begin
    # Log through the exact sink the extension boot script installs, so the test
    # covers the real FormatLogger → _format_extension_log path.
    fmt(f) = begin
        buf = IOBuffer()
        with_logger(f, FormatLogger(Kaimon._format_extension_log, buf))
        String(take!(buf))
    end

    # Plain message: level + message on one line, no kwarg lines.
    out = fmt(() -> @info "extension ready")
    @test occursin("Info] extension ready", out)
    @test !occursin(" = ", out)

    # Structured kwargs each get their own indented line.
    out = fmt(() -> @warn "request failed" url = "http://x" n = 3)
    @test occursin("Warn] request failed", out)
    @test occursin("url = \"http://x\"", out)
    @test occursin("n = 3", out)

    # exception=err renders the error message, not a repr of the struct.
    out = fmt(() -> @error "boom" exception = ErrorException("the actual reason"))
    @test occursin("the actual reason", out)

    # exception=(err, backtrace) — the standard idiom — renders message + stack trace.
    err, bt = try
        error("deep failure")
    catch e
        e, catch_backtrace()
    end
    out = fmt(() -> @error "task died" exception = (err, bt))
    @test occursin("deep failure", out)
    @test occursin("Stacktrace:", out)

    # Multi-line values stay under their kwarg (continuation lines indented).
    out = fmt(() -> @info "multi" text = "line1\nline2")
    @test occursin("line1\\n", out) || occursin("line1\n  line2", out)

    # A value whose show throws must not take down the logger.
    out = fmt(() -> @warn "bad value" v = _ExplodingShow())
    @test occursin("Warn] bad value", out)
    @test occursin("error rendering value", out)

    # Huge values are capped so one kwarg can't bloat the log file.
    out = fmt(() -> @info "big" blob = "x"^100_000)
    @test sizeof(out) < 10_000
    @test occursin("⋯", out)
end

@testset "rescan_extensions! reconciles the registry without bouncing the rest" begin
    # Isolate config so we write a THROWAWAY extensions.json, never the real one.
    withenv("XDG_CONFIG_HOME" => mktempdir()) do
        # A minimal on-disk extension; auto_start=false so rescan never spawns a proc.
        make_ext = function (ns)
            dir = mktempdir()
            write(joinpath(dir, "kaimon.toml"),
                "[extension]\nnamespace = \"$ns\"\nmodule = \"Mod_$ns\"\n" *
                "tools_function = \"get_tools\"\n")
            dir
        end
        a = make_ext("rescan_a")
        b = make_ext("rescan_b")
        reg(paths...) = Kaimon.save_extensions_config(
            [Kaimon.ExtensionEntry(p, true, false) for p in paths])
        live() = [e.config.manifest.namespace for e in Kaimon.get_managed_extensions()]

        # Snapshot/clear the shared registry (empty in this subprocess, but be safe).
        saved = lock(Kaimon.MANAGED_EXTENSIONS_LOCK) do
            s = copy(Kaimon.MANAGED_EXTENSIONS)
            empty!(Kaimon.MANAGED_EXTENSIONS)
            s
        end
        try
            # Register A → picked up as ADDED.
            reg(a)
            r1 = Kaimon.rescan_extensions!()
            @test Set(r1.added) == Set(["rescan_a"])
            @test isempty(r1.removed) && isempty(r1.kept)
            @test "rescan_a" in live()

            # No disk change → A is KEPT (not re-added, not bounced).
            r2 = Kaimon.rescan_extensions!()
            @test isempty(r2.added) && isempty(r2.removed)
            @test Set(r2.kept) == Set(["rescan_a"])

            # Add B → B added, A kept (the whole point: existing ones aren't disturbed).
            reg(a, b)
            r3 = Kaimon.rescan_extensions!()
            @test Set(r3.added) == Set(["rescan_b"])
            @test Set(r3.kept) == Set(["rescan_a"])
            @test isempty(r3.removed)

            # Drop A from disk → A removed (and stopped), B kept.
            reg(b)
            r4 = Kaimon.rescan_extensions!()
            @test Set(r4.removed) == Set(["rescan_a"])
            @test Set(r4.kept) == Set(["rescan_b"])
            @test live() == ["rescan_b"]
        finally
            lock(Kaimon.MANAGED_EXTENSIONS_LOCK) do
                empty!(Kaimon.MANAGED_EXTENSIONS)
                append!(Kaimon.MANAGED_EXTENSIONS, saved)
            end
            rm(a; recursive = true, force = true)
            rm(b; recursive = true, force = true)
        end
    end
end

@testset "extensions.json watch reconciles only after seeding, on change" begin
    withenv("XDG_CONFIG_HOME" => mktempdir()) do
        dir = mktempdir()
        write(joinpath(dir, "kaimon.toml"),
            "[extension]\nnamespace = \"watch_x\"\nmodule = \"M\"\ntools_function = \"t\"\n")
        live() = [e.config.manifest.namespace for e in Kaimon.get_managed_extensions()]

        saved = lock(Kaimon.MANAGED_EXTENSIONS_LOCK) do
            s = copy(Kaimon.MANAGED_EXTENSIONS)
            empty!(Kaimon.MANAGED_EXTENSIONS)
            s
        end
        saved_mt = Kaimon._ext_registry_mtime[]
        try
            # Not seeded → dormant: never reconciles, even with a registry on disk.
            Kaimon._ext_registry_mtime[] = nothing
            Kaimon.save_extensions_config([Kaimon.ExtensionEntry(dir, true, false)])
            @test Kaimon._rescan_registry_if_changed!() == false
            @test isempty(live())

            # Seed to the pre-edit state (here: as if loaded when no file existed), then a
            # real change → reconcile picks up the new extension.
            Kaimon._ext_registry_mtime[] = 0.0
            @test Kaimon._rescan_registry_if_changed!() == true
            @test "watch_x" in live()

            # No further change → no reconcile.
            @test Kaimon._rescan_registry_if_changed!() == false
        finally
            Kaimon._ext_registry_mtime[] = saved_mt
            lock(Kaimon.MANAGED_EXTENSIONS_LOCK) do
                empty!(Kaimon.MANAGED_EXTENSIONS)
                append!(Kaimon.MANAGED_EXTENSIONS, saved)
            end
            rm(dir; recursive = true, force = true)
        end
    end
end

@testset "extension gate advertise probe (timeout diagnostic)" begin
    dir = mktempdir()
    @test !Kaimon._extension_gate_advertised(dir)              # empty → nothing advertised
    # A normal (user) session gate must not count as an extension advertising.
    write(joinpath(dir, "u.json"), "{\"spawned_by\": \"user\", \"mode\": \"tcp\"}")
    @test !Kaimon._extension_gate_advertised(dir)
    # An extension gate's metadata → detected.
    write(joinpath(dir, "e.json"), "{\"spawned_by\": \"extension\", \"mode\": \"tcp\"}")
    @test Kaimon._extension_gate_advertised(dir)
    @test !Kaimon._extension_gate_advertised(joinpath(dir, "nope"))   # missing dir → false
    rm(dir; recursive = true)
end

@testset "managed extension runtime environment" begin
    # A registry/app-installed extension package lives in a manifest-less,
    # write-protected depot dir; a dev checkout carries its own manifest. Kaimon
    # picks the launch --project accordingly (see `_ensure_extension_runtime_project`).

    sound = mktempdir()      # dev-checkout shape: Project.toml + Manifest.toml
    write(joinpath(sound, "Project.toml"), "name = \"Ext\"\nuuid = \"$(Base.UUID(1))\"\n")
    write(joinpath(sound, "Manifest.toml"), "manifest_format = \"2.0\"\n")

    bare = mktempdir()       # registry/app shape: Project.toml, NO manifest
    write(joinpath(bare, "Project.toml"), "name = \"Ext\"\nuuid = \"$(Base.UUID(1))\"\n")

    empty = mktempdir()      # not even a Project.toml

    # _project_has_manifest: only the sound checkout qualifies.
    @test Kaimon._project_has_manifest(sound)
    @test !Kaimon._project_has_manifest(bare)
    @test !Kaimon._project_has_manifest(empty)

    # A sound checkout is launched AS-IS — no managed env is built for it.
    @test Kaimon._ensure_extension_runtime_project(sound, "ext_sound") == sound

    # The managed env dir is under the depot, namespaced (never inside the read-only pkgdir).
    envdir = Kaimon._extension_env_dir("ext_ns")
    @test occursin(joinpath("environments", "kaimon-ext", "ext_ns"), envdir)
    @test startswith(envdir, first(DEPOT_PATH))

    # Fingerprint distinguishes a source-changed / relocated package (so a stale managed
    # env rebuilds) but is stable for an unchanged one.
    fp1 = Kaimon._extension_env_fingerprint(bare)
    @test fp1 == Kaimon._extension_env_fingerprint(bare)          # stable
    @test occursin(abspath(bare), fp1)                           # path is part of identity
    other = mktempdir()
    write(joinpath(other, "Project.toml"), "name = \"Ext\"\n")
    @test fp1 != Kaimon._extension_env_fingerprint(other)         # different path → different id

    for d in (sound, bare, empty, other)
        rm(d; recursive = true, force = true)
    end
end

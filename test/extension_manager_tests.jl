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

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

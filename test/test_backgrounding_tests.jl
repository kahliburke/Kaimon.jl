using ReTest
using Kaimon
using Kaimon.Database
using Dates
using SQLite
using DBInterface

# Auto-backgrounding of long test runs: duration estimation from history, the promotion
# threshold, and the live-run registry that a backgrounded run's handle resolves against.
@testset "Test Backgrounding" begin

    # Record a completed run straight into the analytics DB, the same shape
    # `_persist_test_run!` writes.
    function record!(; project, pattern = "", coverage = false, duration_ms,
                     status = "passed")
        Database.record_test_run!(
            (project_path = project, started_at = "2026-08-21 10:00:00",
             finished_at = "2026-08-21 10:01:00", status = status, pattern = pattern,
             total_pass = 1, total_fail = 0, total_error = 0, total_tests = 1,
             duration_ms = duration_ms, summary = "", coverage = coverage),
            NamedTuple[], NamedTuple[])
    end

    @testset "Duration formatting" begin
        @test Kaimon.format_duration(0) == "0s"
        @test Kaimon.format_duration(45) == "45s"
        @test Kaimon.format_duration(60) == "1m"
        @test Kaimon.format_duration(150) == "2m30s"
        @test Kaimon.format_duration(-5) == "0s"      # clamped, never negative
    end

    @testset "Median resists a single outlier" begin
        @test Kaimon._median([2.0]) == 2.0
        @test Kaimon._median([3.0, 1.0, 2.0]) == 2.0
        @test Kaimon._median([4.0, 1.0, 2.0, 3.0]) == 2.5
        # The reason it's a median: one hung run must not drag the estimate up.
        @test Kaimon._median([10.0, 11.0, 12.0, 10.0, 9000.0]) == 11.0
    end

    @testset "Threshold resolution" begin
        withenv("KAIMON_TEST_PROMOTE_AFTER" => "45") do
            @test Kaimon.test_promote_after() == 45.0
        end
        # <= 0 disables backgrounding entirely, matching the eval threshold's convention.
        withenv("KAIMON_TEST_PROMOTE_AFTER" => "0") do
            @test Kaimon.test_promote_after() == Inf
        end
        withenv("KAIMON_TEST_PROMOTE_AFTER" => "-1") do
            @test Kaimon.test_promote_after() == Inf
        end
        withenv("KAIMON_TEST_PROMOTE_AFTER" => nothing) do
            @test Kaimon.test_promote_after() == 30.0   # preference default
        end
    end

    @testset "Estimation keys on the exact invocation" begin
        Database.init_db!(tempname() * ".db")
        proj = "/tmp/estproj"

        @test Kaimon.estimate_test_duration(proj, "", false) === nothing

        # Full suite: slow.
        record!(project = proj, pattern = "", duration_ms = 300_000.0)
        record!(project = proj, pattern = "", duration_ms = 320_000.0)
        @test Kaimon.estimate_test_duration(proj, "", false) ≈ 310.0

        # A subset of the SAME project is fast. It must not inherit the full suite's
        # estimate — that mis-prediction is the whole reason the key is exact.
        @test Kaimon.estimate_test_duration(proj, "Fast Subset", false) === nothing
        record!(project = proj, pattern = "Fast Subset", duration_ms = 12_000.0)
        @test Kaimon.estimate_test_duration(proj, "Fast Subset", false) ≈ 12.0
        @test Kaimon.estimate_test_duration(proj, "", false) ≈ 310.0   # unchanged

        # Coverage is a different invocation, not a variant of the same one.
        @test Kaimon.estimate_test_duration(proj, "", true) === nothing
        record!(project = proj, pattern = "", coverage = true, duration_ms = 900_000.0)
        @test Kaimon.estimate_test_duration(proj, "", true) ≈ 900.0
        @test Kaimon.estimate_test_duration(proj, "", false) ≈ 310.0

        # Another project is unrelated.
        @test Kaimon.estimate_test_duration("/tmp/otherproj", "", false) === nothing
    end

    @testset "Cancelled and zero-duration runs are excluded" begin
        Database.init_db!(tempname() * ".db")
        proj = "/tmp/cancelproj"
        # A cancelled run's duration says nothing about how long the suite takes.
        record!(project = proj, pattern = "", duration_ms = 5.0, status = "cancelled")
        record!(project = proj, pattern = "", duration_ms = 0.0, status = "passed")
        @test Kaimon.estimate_test_duration(proj, "", false) === nothing

        record!(project = proj, pattern = "", duration_ms = 40_000.0, status = "failed")
        @test Kaimon.estimate_test_duration(proj, "", false) ≈ 40.0   # failed still counts
    end

    @testset "Only the most recent runs count" begin
        Database.init_db!(tempname() * ".db")
        proj = "/tmp/windowproj"
        for _ in 1:8
            record!(project = proj, pattern = "", duration_ms = 10_000.0)
        end
        @test length(Database.get_test_run_durations(proj, "", false)) == 5
    end

    @testset "coverage column is added to a pre-existing database" begin
        # A DB created before the column existed must gain it rather than erroring.
        path = tempname() * ".db"
        db = SQLite.DB(path)
        DBInterface.execute(db, """CREATE TABLE test_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT, project_path TEXT NOT NULL,
            started_at DATETIME NOT NULL, finished_at DATETIME, status TEXT NOT NULL,
            pattern TEXT DEFAULT '', total_pass INTEGER DEFAULT 0, total_fail INTEGER DEFAULT 0,
            total_error INTEGER DEFAULT 0, total_tests INTEGER DEFAULT 0,
            duration_ms REAL DEFAULT 0, summary TEXT DEFAULT '')""")
        SQLite.close(db)

        Database.init_db!(path)
        record!(project = "/tmp/migrated", pattern = "", duration_ms = 7_000.0)
        @test Kaimon.estimate_test_duration("/tmp/migrated", "", false) ≈ 7.0

        # Idempotent: re-initialising the same DB must not fail on a duplicate column.
        Database.init_db!(path)
        @test Kaimon.estimate_test_duration("/tmp/migrated", "", false) ≈ 7.0
    end

    @testset "Live-run registry" begin
        r1 = Kaimon.TestRun(; id = 90001, project_path = "/tmp/p", pattern = "x")
        Kaimon._register_live_run!(r1)
        @test Kaimon.get_live_test_run(90001) === r1
        @test Kaimon.get_live_test_run(90002) === nothing
        @test any(r -> r.id == 90001, Kaimon.running_test_runs())

        # A finished run stays resolvable — the agent collects its result afterwards.
        r1.status = Kaimon.RUN_PASSED
        @test Kaimon.get_live_test_run(90001) === r1
        @test !any(r -> r.id == 90001, Kaimon.running_test_runs())
    end

    @testset "Cancelling actually kills the subprocess" begin
        # A suite that would run for two minutes, so there's a real process to kill and the
        # test can't pass by the run simply finishing first.
        dir = mktempdir()
        mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "Project.toml"),
              "name = \"SlowPkg\"\nuuid = \"6a1b2c3d-0000-4000-8000-000000000001\"\nversion = \"0.1.0\"\n")
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "SlowPkg.jl"), "module SlowPkg\nend\n")
        write(joinpath(dir, "test", "runtests.jl"), "sleep(120)\n")

        run = Kaimon.spawn_test_run(dir)
        try
            # Wait for the subprocess to actually exist before killing it.
            t0 = time()
            while run.process === nothing && time() - t0 < 30
                sleep(0.1)
            end
            @test run.process !== nothing
            @test run.status == Kaimon.RUN_RUNNING
            @test Kaimon.find_running_test_run(dir, "", false) === run

            Kaimon.cancel_test_run!(run)
            @test run.status == Kaimon.RUN_CANCELLED

            # The process must actually be gone, not just marked cancelled.
            t1 = time()
            while process_running(run.process) && time() - t1 < 30
                sleep(0.1)
            end
            @test !process_running(run.process)

            # A cancelled run leaves the in-flight set, so it no longer blocks a re-run.
            @test Kaimon.find_running_test_run(dir, "", false) === nothing
        finally
            run.process !== nothing && process_running(run.process) && kill(run.process)
        end
    end

    @testset "An identical in-flight run is matched, a different one isn't" begin
        a = Kaimon.TestRun(; id = 91001, project_path = "/tmp/dup", pattern = "", coverage = false)
        Kaimon._register_live_run!(a)
        @test Kaimon.find_running_test_run("/tmp/dup", "", false) === a
        # Different invocations are genuinely different work.
        @test Kaimon.find_running_test_run("/tmp/dup", "Subset", false) === nothing
        @test Kaimon.find_running_test_run("/tmp/dup", "", true) === nothing
        @test Kaimon.find_running_test_run("/tmp/other", "", false) === nothing
        a.status = Kaimon.RUN_PASSED
        @test Kaimon.find_running_test_run("/tmp/dup", "", false) === nothing
    end

    @testset "Runs on one project are serialised by default" begin
        @test Kaimon.test_concurrency() == 1
        withenv("KAIMON_TEST_CONCURRENCY" => "3") do
            @test Kaimon.test_concurrency() == 3
        end
        withenv("KAIMON_TEST_CONCURRENCY" => "0") do
            @test Kaimon.test_concurrency() == 1   # never below one
        end

        proj = "/tmp/serialproj"
        a = Kaimon.TestRun(; id = 92001, project_path = proj, pattern = "Alpha")
        Kaimon._register_live_run!(a)
        @test length(Kaimon.project_test_runs(proj)) == 1
        # A *different* pattern on the same project still counts against the limit — this
        # is the case exact-match dedup misses, and the one that corrupts shared state.
        @test Kaimon.find_running_test_run(proj, "Beta", false) === nothing
        @test length(Kaimon.project_test_runs(proj)) >= Kaimon.test_concurrency()

        b = Kaimon.TestRun(; id = 92002, project_path = proj, pattern = "Beta")
        Kaimon._register_live_run!(b)
        @test length(Kaimon.project_test_runs(proj)) == 2

        # Other projects are unaffected — serialisation is per project, not global.
        @test isempty(Kaimon.project_test_runs("/tmp/unrelatedproj"))

        a.status = Kaimon.RUN_PASSED
        b.status = Kaimon.RUN_CANCELLED
        @test isempty(Kaimon.project_test_runs(proj))
    end

    @testset "Collecting a run whose process never exits is bounded" begin
        # A suite that leaks a daemon hands its stdout to a grandchild that outlives it, so
        # the pipe never hits EOF and the process never looks done. The runner's DONE line
        # has already given us status and results, so collecting must format what it has
        # rather than blocking forever — this hung `check_tests` indefinitely in practice.
        proc = open(`sleep 300`, "r")
        try
            r = Kaimon.TestRun(; id = 93001, project_path = mktempdir(), pattern = "")
            r.process = proc
            r.status = Kaimon.RUN_PASSED
            r.reader_done = false              # reader still blocked on the open pipe

            t0 = time()
            out = Kaimon._finish_and_format(r, r.project_path, "", false, false)
            elapsed = time() - t0

            # Two bounded waits of 5s each, so ~10s worst case; anything near 30s is a hang.
            @test elapsed < 20
            @test out isa String
            @test !isempty(out)
        finally
            process_running(proc) && kill(proc)
        end
    end

    @testset "Status labels read as words, not enum names" begin
        @test Kaimon.test_status_label(Kaimon.RUN_PASSED) == "passed"
        @test Kaimon.test_status_label(Kaimon.RUN_FAILED) == "failed"
        @test Kaimon.test_status_label(Kaimon.RUN_ERROR) == "error"
        @test Kaimon.test_status_label(Kaimon.RUN_CANCELLED) == "cancelled"
        @test Kaimon.test_status_label(Kaimon.RUN_RUNNING) == "running"
    end

    @testset "TestRun carries coverage for estimation" begin
        r = Kaimon.TestRun(; id = 1, project_path = "/tmp/p", pattern = "", coverage = true)
        @test r.coverage
        @test !Kaimon.TestRun(; id = 2).coverage
    end
end

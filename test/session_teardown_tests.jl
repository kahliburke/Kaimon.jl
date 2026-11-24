using ReTest
using Kaimon

# Tearing down a managed session releases everything it held: the process is reaped (not left a
# zombie), its terminal's master is closed, and its records are dropped — whether it exits on its
# own, is stopped, or is shut down while its gate does not answer (#105).

const _ST = Kaimon

# A process that has been reaped no longer answers kill(pid, 0); a zombie still does.
_st_exists(pid) = ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0

@testset "Session teardown" begin
    if Sys.iswindows()
        @test_skip true
    else
        @testset "the exit monitor reaps a session that exits and closes its terminal" begin
            ms = _ST.ManagedSession(mktempdir())
            pty = _ST.Tachikoma.pty_spawn(["true"])
            pid = pty.child_pid
            ms.pty = pty
            ms.status = :running
            _ST._watch_session_exit!(ms, pty, nothing; poll = 0.05)
            @test ms.pty === nothing
            @test ms.status == :crashed
            @test any(startswith("Process exited"), ms.error_log)
            @test pty.master_fd == -1
            @test !_st_exists(pid)
        end

        @testset "a session whose terminal reader stops is reported as such and stopped" begin
            ms = _ST.ManagedSession(mktempdir())
            pty = Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
                _ST.Tachikoma.pty_spawn(["sh", "-c", "sleep 0.2; echo output; exec sleep 30"])
            end
            pid = pty.child_pid
            ms.pty = pty
            ms.status = :running
            close(pty.output)   # the reader fails on its next chunk while the process runs on
            _ST._watch_session_exit!(ms, pty, nothing; poll = 0.05)
            @test ms.status == :crashed
            @test any(startswith("Terminal reader stopped while the process was running"), ms.error_log)
            @test ms.pty === nothing
            @test !_st_exists(pid)
        end

        @testset "exactly one of the monitor and stop_session! closes the terminal" begin
            ms = _ST.ManagedSession(mktempdir())
            pty = _ST.Tachikoma.pty_spawn(["sleep", "30"])
            pid = pty.child_pid
            ms.pty = pty
            ms.status = :running
            @test _ST._take_pty!(ms, :some_other_pty) === nothing   # a PTY that is no longer the session's
            @test ms.pty === pty
            _ST.stop_session!(ms)
            @test ms.pty === nothing
            @test _ST._take_pty!(ms, pty) === nothing               # the monitor finds nothing left to close
            @test !_st_exists(pid)
        end

        @testset "shutdown of a stalled session stops its process and drops its records" begin
            mgr = _ST.ConnectionManager(sock_dir = mktempdir())
            ms = _ST.ManagedSession(mktempdir())
            pty = _ST.Tachikoma.pty_spawn(["sleep", "30"])
            pid = pty.child_pid
            ms.pty = pty
            ms.status = :running
            # Not yet linked to its session key, so it is found by pid.
            conn = _ST.REPLConnection(session_id = "teardown-test", endpoint = "ipc:///tmp/teardown-test.sock",
                                      spawned_by = "agent", pid = Int(pid))
            conn.status = :stalled
            lock(_ST.MANAGED_SESSIONS_LOCK) do; push!(_ST.MANAGED_SESSIONS, ms); end
            push!(mgr.connections, conn)
            try
                @test _ST.managed_session_for(conn) === ms
                @test _ST.shutdown_session!(mgr, conn) === :stalled
                @test !_st_exists(pid)
                @test ms.pty === nothing
                @test !(ms in _ST.MANAGED_SESSIONS)
                @test !(conn in mgr.connections)
            finally
                lock(_ST.MANAGED_SESSIONS_LOCK) do; filter!(m -> m !== ms, _ST.MANAGED_SESSIONS); end
                _st_exists(pid) && ccall(:kill, Cint, (Cint, Cint), pid, 9)
            end
        end
    end

    @testset "a timeout on a session that just started says it may still be loading" begin
        conn = _ST.REPLConnection(session_id = "timeout-test", endpoint = "ipc:///tmp/timeout-test.sock",
                                  spawned_by = "agent", pid = 999_999)
        @test _ST._caller_timeout_message(conn, 10.0) == "Caller timeout after 10.0s"   # not one Kaimon started
        ms = _ST.ManagedSession(mktempdir())
        ms.session_key = _ST.short_key(conn)
        ms.started_at = time() - 5
        lock(_ST.MANAGED_SESSIONS_LOCK) do; push!(_ST.MANAGED_SESSIONS, ms); end
        try
            @test occursin("started 5s ago", _ST._caller_timeout_message(conn, 10.0))
            ms.started_at = time() - 3600
            @test _ST._caller_timeout_message(conn, 10.0) == "Caller timeout after 10.0s"
        finally
            lock(_ST.MANAGED_SESSIONS_LOCK) do; filter!(m -> m !== ms, _ST.MANAGED_SESSIONS); end
        end
    end
end

using ReTest
using Kaimon

# A spawned session's startup: its gate is matched by process, a gate that connects after the
# startup limit is still used, a process that never connects is stopped, a gate that matches
# nothing is logged with the reason, and a requested shutdown is not reported as a crash.

const _SS = Kaimon

_ss_conn(id, proj, pid; spawned_by = "agent") = (c = _SS.REPLConnection(
    session_id = "tcp-127.0.0.1-$id", endpoint = "tcp://127.0.0.1:$id",
    name = "s$id", project_path = proj, spawned_by = spawned_by, pid = pid);
    c.status = :connected; c)

function _ss_waiting(proj, proc; started_ago = 0.0, limit = 120.0, status = :starting)
    ms = _SS.ManagedSession(proj)
    ms.process = proc
    ms.status = status
    ms.started_at = time() - started_ago
    ms.connect_by = ms.started_at + limit
    return ms
end

function _ss_with_sessions(f, sessions...)
    lock(_SS.MANAGED_SESSIONS_LOCK) do; append!(_SS.MANAGED_SESSIONS, sessions); end
    try
        f()
    finally
        lock(_SS.MANAGED_SESSIONS_LOCK) do
            filter!(m -> !any(s -> s === m, sessions), _SS.MANAGED_SESSIONS)
        end
        for s in sessions
            p = s.process
            p !== nothing && Base.process_running(p) && kill(p)
        end
    end
end

_ss_mgr(conns...) = (m = _SS.ConnectionManager(sock_dir = mktempdir()); append!(m.connections, conns); m)

@testset "Session startup" begin
    proj = _SS.normalize_path(mktempdir())
    write(joinpath(proj, "Project.toml"), "name = \"StartupTest\"\n")

    @testset "startup limit setting" begin
        cfg = mktempdir()
        withenv("KAIMON_CONFIG_DIR" => cfg, "KAIMON_SESSION_STARTUP_TIMEOUT" => nothing) do
            @test _SS.session_startup_timeout() == 120.0
            write(joinpath(cfg, "config.json"), """{"session_startup_timeout": 300}""")
            @test _SS.session_startup_timeout() == 300.0
            withenv("KAIMON_SESSION_STARTUP_TIMEOUT" => "45") do
                @test _SS.session_startup_timeout() == 45.0
            end
            withenv("KAIMON_SESSION_STARTUP_TIMEOUT" => "-1") do
                @test _SS.session_startup_timeout() == 300.0
            end
        end
    end

    @testset "a gate that connects after the limit is still matched" begin
        ms = _ss_waiting(proj, run(`sleep 30`; wait = false); started_ago = 130.0)
        _ss_with_sessions(ms) do
            mgr = _ss_mgr()
            _SS._monitor_managed_sessions!(mgr)
            @test ms.status == :timed_out
            @test Base.process_running(ms.process)
            conn = _ss_conn(9801, proj, Int(getpid(ms.process)))
            push!(mgr.connections, conn)
            _SS._monitor_managed_sessions!(mgr)
            @test ms.status == :running
            @test ms.session_key == _SS.short_key(conn)
        end
    end

    @testset "a process that never connects is stopped" begin
        withenv("KAIMON_SESSION_STARTUP_TIMEOUT" => "10") do
            ms = _ss_waiting(proj, run(`sleep 30`; wait = false); started_ago = 30.0, limit = 10.0,
                             status = :timed_out)
            proc = ms.process
            _ss_with_sessions(ms) do
                _SS._monitor_managed_sessions!(_ss_mgr())
                @test ms.status == :stopped
                @test !Base.process_running(proc)
            end
        end
    end

    @testset "the process id matches a gate whatever started it" begin
        ms = _ss_waiting(proj, run(`sleep 30`; wait = false))
        _ss_with_sessions(ms) do
            # A startup file may serve the gate first, so it reports a user start.
            conn = _ss_conn(9802, proj, Int(getpid(ms.process)); spawned_by = "user")
            _SS._monitor_managed_sessions!(_ss_mgr(conn))
            @test ms.status == :running
            @test ms.session_key == _SS.short_key(conn)
        end
    end

    @testset "an agent-spawned gate that matches nothing is logged once, with the reason" begin
        other = _SS.normalize_path(mktempdir())
        ms = _ss_waiting(proj, run(`sleep 30`; wait = false))
        ms.name = "waiting"
        _ss_with_sessions(ms) do
            stray = _ss_conn(9803, other, 1)
            @test occursin("'waiting' has pid $(getpid(ms.process)) and project $proj",
                           _SS._unmatched_gate_reason(stray, [ms]))
            @test _SS._unmatched_gate_reason(stray, _SS.ManagedSession[]) ==
                  "no session is waiting for a gate"
            _SS._monitor_managed_sessions!(_ss_mgr(stray))
            @test ms.status == :starting
            @test _SS.short_key(stray) in _SS._UNMATCHED_GATES_LOGGED
            # Forgotten once the gate is gone, so the set does not grow.
            _SS._monitor_managed_sessions!(_ss_mgr())
            @test !(_SS.short_key(stray) in _SS._UNMATCHED_GATES_LOGGED)
        end
    end

    @testset "start_session waits again for a session that is still starting" begin
        cfg = mktempdir()
        withenv("KAIMON_CONFIG_DIR" => cfg) do
            _SS.allow_project!(proj)
            ms = _ss_waiting(proj, run(`sleep 30`; wait = false); started_ago = 130.0,
                             status = :timed_out)
            _ss_with_sessions(ms) do
                mgr = _ss_mgr()
                old_mgr = _SS.GATE_CONN_MGR[]
                _SS.GATE_CONN_MGR[] = mgr
                try
                    t = @async _SS.start_session_tool.handler(Dict("project_path" => proj))
                    timedwait(() -> ms.status == :starting || istaskdone(t), 5.0)
                    @test ms.status == :starting
                    @test lock(() -> count(m -> m === ms, _SS.MANAGED_SESSIONS), _SS.MANAGED_SESSIONS_LOCK) == 1
                    conn = _ss_conn(9804, proj, Int(getpid(ms.process)))
                    lock(() -> push!(mgr.connections, conn), mgr.lock)
                    r = fetch(t)
                    @test occursin("Session started. Session key: $(_SS.short_key(conn))", r)
                finally
                    _SS.GATE_CONN_MGR[] = old_mgr
                end
            end
        end
    end

    if !Sys.iswindows()
        @testset "a requested shutdown is not taken for a crash" begin
            ms = _SS.ManagedSession(mktempdir())
            pty = _SS.Tachikoma.pty_spawn(["true"])
            ms.pty = pty
            ms.status = :stopping
            _SS._watch_session_exit!(ms, pty, nothing; poll = 0.05)
            @test ms.status == :stopping
            @test isempty(ms.error_log)
        end
    end
end

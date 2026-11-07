"""
    TCP Stale Session Tests (GitHub #35)

Reproduces the bug where a gate restart on the same REQ port but different
PUB port leaves the client's SUB socket pointing at the dead PUB endpoint.
Health check pings succeed (REQ port works), but `ex` hangs forever because
the SUB socket never receives eval_complete messages.

Usage:
    julia --project test/tcp_stale_session_tests.jl
"""

using ReTest
using ZMQ
using Serialization
using Dates

using Kaimon

# ─────────────────────────────────────────────────────────────────────────────
# Mock gate — a minimal ROUTER + PUB server that responds to :ping and
# :eval_async, speaking protocol v2: requests arrive as [identity, corr_id,
# payload]; replies echo [identity, corr_id, payload] so the client DEALER can
# demultiplex (mirrors KaimonGate's real ROUTER loop).
# ─────────────────────────────────────────────────────────────────────────────

mutable struct MockGate
    ctx::ZMQ.Context
    router::ZMQ.Socket   # ROUTER socket (like the gate's main socket)
    pub::ZMQ.Socket      # PUB socket (like the gate's stream socket)
    rep_port::Int
    pub_port::Int
    running::Bool
    task::Union{Task,Nothing}
    instance_id::String  # unique per gate instance
end

"""Start a mock gate on fixed REQ port, ephemeral PUB port."""
function start_mock_gate(req_port::Int; pub_port::Int=0)
    ctx = Context()
    router = Socket(ctx, ROUTER)
    router.rcvtimeo = 1000
    router.sndtimeo = 1000
    router.linger = 0
    bind(router, "tcp://127.0.0.1:$req_port")

    pub = Socket(ctx, PUB)
    pub.sndhwm = 0
    pub.linger = 0
    bind(pub, "tcp://127.0.0.1:$pub_port")
    pub_endpoint = rstrip(ZMQ._get_last_endpoint(pub), '\0')
    m = match(r":(\d+)$", pub_endpoint)
    actual_pub_port = parse(Int, m.captures[1])

    gate = MockGate(ctx, router, pub, req_port, actual_pub_port, true, nothing,
                    string(Base.UUID(rand(UInt128))))

    gate.task = Threads.@spawn _run_mock_gate(gate)
    return gate
end

# recv a full multipart message [identity, corr_id, payload] (rcvtimeo-bounded).
function _mock_recv_parts(sock::ZMQ.Socket)
    parts = Vector{UInt8}[recv(sock, Vector{UInt8})]
    while sock.rcvmore
        push!(parts, recv(sock, Vector{UInt8}))
    end
    return parts
end

function _run_mock_gate(gate::MockGate)
    while gate.running
        parts = try
            _mock_recv_parts(gate.router)
        catch
            continue
        end
        length(parts) >= 3 || continue
        identity = parts[1]
        corr_id = parts[2]
        payload = parts[end]

        send_reply = resp -> begin
            io = IOBuffer()
            Serialization.serialize(io, resp)
            try
                send(gate.router, identity; more = true)
                send(gate.router, corr_id; more = true)
                send(gate.router, take!(io))
            catch
            end
        end

        msg = try
            Serialization.deserialize(IOBuffer(payload))
        catch
            send_reply((type = :error, message = "deserialize failed"))
            continue
        end

        resp = if get(msg, :type, nothing) == :ping
            (
                type = :pong,
                pid = getpid(),
                uptime = 42.0,
                julia_version = string(VERSION),
                kaimon_version = "test",
                project_path = @__DIR__,
                tools = [],
                namespace = "",
                stream_endpoint = "tcp://127.0.0.1:$(gate.pub_port)",
                allow_restart = false,
                allow_mirror = false,
                mirror_repl = false,
                instance_id = gate.instance_id,
            )
        elseif get(msg, :type, nothing) == :eval_async
            rid = get(msg, :request_id, "")
            # Publish eval_complete on the PUB socket after a short delay
            Threads.@spawn begin
                sleep(0.1)
                _mock_publish(gate, rid, "42")
            end
            (type = :accepted, request_id = rid)
        else
            (type = :error, message = "unknown request type: $(get(msg, :type, nothing))")
        end

        send_reply(resp)
    end
end

"""Publish an eval_complete message on the mock gate's PUB socket."""
function _mock_publish(gate::MockGate, request_id::String, result_str::String)
    io = IOBuffer()
    Serialization.serialize(io, (
        channel = "eval_complete",
        request_id = request_id,
        data = result_str,
        mime = "text/plain",
    ))
    try
        send(gate.pub, take!(io))
    catch
    end
end

function stop_mock_gate!(gate::MockGate)
    gate.running = false
    # Wait for task to finish (it polls with 1s recv timeout)
    if gate.task !== nothing
        try; wait(gate.task); catch; end
    end
    try; close(gate.router); catch; end
    try; close(gate.pub); catch; end
    try; close(gate.ctx); catch; end
end

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

# Use a high port unlikely to conflict
const TEST_REQ_PORT = 39_876

@testset "TCP Stale Session (#35)" begin

    @testset "stream_endpoint not updated when gate restarts" begin
        # Phase 1: Start gate, connect, verify stream works
        gate1 = start_mock_gate(TEST_REQ_PORT)
        sleep(0.3)  # let gate bind

        mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
        try
            conn = Kaimon.connect_tcp!(mgr, "127.0.0.1", TEST_REQ_PORT)
            @test conn.status == :connected
            @test conn.sub_socket !== nothing
            old_stream = conn.stream_endpoint
            @test old_stream == "tcp://127.0.0.1:$(gate1.pub_port)"
            old_sub = conn.sub_socket

            # Phase 2: Kill gate1, start gate2 on same REQ port (different PUB port)
            stop_mock_gate!(gate1)
            sleep(0.5)  # let ZMQ clean up

            gate2 = start_mock_gate(TEST_REQ_PORT)
            sleep(0.3)
            @test gate2.pub_port != gate1.pub_port  # ephemeral port should differ

            try
                # Phase 3: Simulate a health check pong from the new gate
                pong = Kaimon.ping(conn)
                # REQ socket needs reconnection after gate restart
                if pong === nothing
                    # Rebuild the DEALER request channel (gate2 is on the same port)
                    lock(conn.req_lock) do
                        if conn.req_channel !== nothing
                            Kaimon._close_request_channel!(conn.req_channel)
                        end
                        conn.req_channel = Kaimon.RequestChannel(conn.zmq_context, conn.endpoint)
                    end
                    conn.status = :connected
                    pong = Kaimon.ping(conn)
                end
                @test pong !== nothing

                # The pong from gate2 reports the NEW stream_endpoint
                new_stream_from_pong = string(get(pong, :stream_endpoint, ""))
                @test new_stream_from_pong == "tcp://127.0.0.1:$(gate2.pub_port)"
                @test new_stream_from_pong != old_stream

                # Phase 4: Process the pong through _process_health_result!
                # This is what the health check loop does
                to_remove = Kaimon.REPLConnection[]
                Kaimon._process_health_result!(mgr, conn, pong, to_remove)

                # FIX: The SUB socket should be reconnected to the new PUB port
                # when _process_health_result! detects a stream_endpoint change.
                @test conn.stream_endpoint == "tcp://127.0.0.1:$(gate2.pub_port)"
                @test conn.sub_socket !== old_sub  # replaced with new socket
                @test conn.sub_socket !== nothing

            finally
                stop_mock_gate!(gate2)
            end
        finally
            # Clean up connection manager
            lock(mgr.lock) do
                for c in mgr.connections
                    Kaimon.disconnect!(c)
                end
            end
        end
    end

    @testset "_process_health_result! should detect stream_endpoint mismatch" begin
        # Unit test: directly test the pong handler with a mismatched stream_endpoint
        mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
        conn = Kaimon.REPLConnection(
            session_id = "tcp-127.0.0.1-99999",
            endpoint = "tcp://127.0.0.1:99999",
            stream_endpoint = "tcp://127.0.0.1:44444",  # old PUB port
            spawned_by = "user",
        )
        # Simulate having an existing SUB socket (stale, connected to old PUB)
        stale_ctx = Context()
        stale_sub = Socket(stale_ctx, SUB)
        stale_sub.linger = 0
        conn.sub_socket = stale_sub
        conn.status = :connected

        # Simulate a pong from a restarted gate with a different stream_endpoint
        pong = (
            type = :pong,
            pid = getpid(),
            uptime = 10.0,
            julia_version = string(VERSION),
            kaimon_version = "test",
            project_path = @__DIR__,
            tools = [],
            namespace = "",
            stream_endpoint = "tcp://127.0.0.1:55555",  # NEW PUB port
            allow_restart = false,
            allow_mirror = false,
            mirror_repl = false,
        )

        to_remove = Kaimon.REPLConnection[]
        Kaimon._process_health_result!(mgr, conn, pong, to_remove)

        # FIX: stream_endpoint should be updated to the new value
        @test conn.stream_endpoint == "tcp://127.0.0.1:55555"
        # FIX: sub_socket should have been replaced
        @test conn.sub_socket !== stale_sub
        @test conn.sub_socket !== nothing

        # Clean up
        try; close(stale_sub); catch; end
        try; close(stale_ctx); catch; end
    end

    @testset "eval hangs when SUB points to dead PUB port" begin
        # Start gate, connect, then restart gate on same REQ port.
        # Attempt an eval — it should time out because SUB is stale.
        gate1 = start_mock_gate(TEST_REQ_PORT)
        sleep(0.3)

        mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
        try
            conn = Kaimon.connect_tcp!(mgr, "127.0.0.1", TEST_REQ_PORT)
            @test conn.status == :connected

            # Verify eval works with gate1
            rid1 = "eval-test-$(rand(UInt16))"
            resp1 = Kaimon._req_send_recv(conn,
                (type = :eval_async, code = "1+1", request_id = rid1);
                caller_timeout = 5.0)
            @test resp1.ok
            @test get(resp1.response, :type, nothing) == :accepted

            # Drain the PUB result from gate1
            sleep(0.3)
            Kaimon.drain_stream_messages!(mgr)

            # Restart: kill gate1, start gate2
            stop_mock_gate!(gate1)
            sleep(0.5)

            gate2 = start_mock_gate(TEST_REQ_PORT)
            sleep(0.3)

            try
                # Rebuild the DEALER request channel to gate2
                lock(conn.req_lock) do
                    if conn.req_channel !== nothing
                        Kaimon._close_request_channel!(conn.req_channel)
                    end
                    conn.req_channel = Kaimon.RequestChannel(conn.zmq_context, conn.endpoint)
                end
                conn.status = :connected

                # Process a health pong (simulates the health checker)
                pong = Kaimon.ping(conn)
                @test pong !== nothing
                to_remove = Kaimon.REPLConnection[]
                Kaimon._process_health_result!(mgr, conn, pong, to_remove)

                # Allow ZMQ SUB subscription to propagate (slow joiner)
                sleep(0.3)

                # Now send an eval to gate2, with a pre-created inbox
                # (mirroring what eval_remote_async does internally)
                rid2 = "eval-test-$(rand(UInt16))"
                inbox = Channel{Any}(Inf)
                lock(conn._eval_inboxes_lock) do
                    conn._eval_inboxes[rid2] = inbox
                end

                resp2 = Kaimon._req_send_recv(conn,
                    (type = :eval_async, code = "2+2", request_id = rid2);
                    caller_timeout = 5.0)
                @test resp2.ok
                @test get(resp2.response, :type, nothing) == :accepted

                # FIX: after the health pong reconnects the SUB socket, the eval result
                # should arrive from gate2's PUB port. The mock gate uses a plain PUB, so
                # there is a slow-joiner race — it may publish before our newly-reconnected
                # SUB's subscription reaches it, dropping THAT result. A single send + fixed
                # sleep is flaky under load; instead poll (draining each round) and re-issue
                # the eval until a result lands on the reconnected SUB.
                got = false
                deadline = time() + 8.0
                while !got && time() < deadline
                    for _ = 1:10
                        Kaimon.drain_stream_messages!(mgr)
                        if isready(inbox)
                            got = true
                            break
                        end
                        sleep(0.05)
                    end
                    got || Kaimon._req_send_recv(conn,
                        (type = :eval_async, code = "2+2", request_id = rid2);
                        caller_timeout = 2.0)
                end
                @test got  # eval result arrives via the reconnected SUB socket

                # Clean up inbox
                lock(conn._eval_inboxes_lock) do
                    delete!(conn._eval_inboxes, rid2)
                end

            finally
                stop_mock_gate!(gate2)
            end
        finally
            lock(mgr.lock) do
                for c in mgr.connections
                    Kaimon.disconnect!(c)
                end
            end
        end
    end

end

# ─────────────────────────────────────────────────────────────────────────────
# Stale TCP PID + localhost reaping (STALE_TCP_SESSION_ISSUES.md)
# ─────────────────────────────────────────────────────────────────────────────

"""Return a PID that is guaranteed dead (a short process we wait on, then reap)."""
function _dead_pid()
    proc = open(`sleep 0.01`)
    pid = Int(getpid(proc))   # getpid returns Int32 on some platforms; pid field is Int
    wait(proc)  # reap — process is now gone (not a zombie)
    return pid
end

@testset "TCP PID refresh + localhost reaping" begin

    @testset "host helpers" begin
        @test Kaimon._is_local_host("127.0.0.1")
        @test Kaimon._is_local_host("::1")
        @test Kaimon._is_local_host("localhost")
        @test Kaimon._is_local_host("")
        @test Kaimon._is_local_host("127.0.1.1")        # whole 127/8 is loopback
        @test !Kaimon._is_local_host("10.0.0.5")
        @test !Kaimon._is_local_host("example.com")

        @test Kaimon._endpoint_host("tcp://127.0.0.1:9100") == "127.0.0.1"
        @test Kaimon._endpoint_host("tcp://[::1]:9100") == "::1"   # bracketed IPv6
        @test Kaimon._endpoint_host("tcp://example.com:9100") == "example.com"
        @test Kaimon._endpoint_host("ipc:///tmp/x.sock") == ""

        local_tcp = Kaimon.REPLConnection(
            session_id = "tcp-127.0.0.1-9100", endpoint = "tcp://127.0.0.1:9100", spawned_by = "user")
        remote_tcp = Kaimon.REPLConnection(
            session_id = "tcp-10.0.0.5-9100", endpoint = "tcp://10.0.0.5:9100", spawned_by = "user")
        @test Kaimon._is_local_tcp(local_tcp)
        @test !Kaimon._is_local_tcp(remote_tcp)
    end

    @testset "backtrace signals only a known local pid" begin
        # Each of these must return before kill(2): a remote pid names another machine's process,
        # and pid 0 would signal this process's whole group.
        remote_tcp = Kaimon.REPLConnection(
            session_id = "tcp-10.0.0.5-9100", endpoint = "tcp://10.0.0.5:9100",
            spawned_by = "user", pid = Int(getpid()))
        no_pid = Kaimon.REPLConnection(
            session_id = "no-pid", endpoint = "ipc:///tmp/no-pid.sock", spawned_by = "user", pid = 0)
        for conn in (remote_tcp, no_pid)
            t = time()
            @test Kaimon.trigger_backtrace(conn) === nothing
            @test time() - t < 1   # returned up front, not after polling for a backtrace file
        end
    end

    @testset "Bug 1: PID refreshed from pong (port reuse)" begin
        mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
        # conn carries a stale (dead predecessor's) PID; a fresh pong reports the
        # live worker's getpid() — conn.pid must adopt it.
        conn = Kaimon.REPLConnection(
            session_id = "tcp-127.0.0.1-9100", endpoint = "tcp://127.0.0.1:9100",
            spawned_by = "user", pid = 11111)
        conn.status = :connected
        pong = (
            type = :pong, pid = getpid(), uptime = 1.0, julia_version = string(VERSION),
            kaimon_version = "test", project_path = @__DIR__, tools = [], namespace = "",
            stream_endpoint = "", allow_restart = false, allow_mirror = false, mirror_repl = false,
        )
        Kaimon._process_health_result!(mgr, conn, pong, Kaimon.REPLConnection[])
        @test conn.pid == getpid()   # adopted the live PID, not the stale 11111
    end

    @testset "Bug 2: dead localhost TCP reaped; remote/unknown kept" begin
        mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
        dpid = _dead_pid()
        @test !Kaimon._is_pid_alive(dpid)

        # Localhost TCP with a known-dead PID → reaped (pushed to to_remove).
        c_local = Kaimon.REPLConnection(
            session_id = "tcp-127.0.0.1-9201", endpoint = "tcp://127.0.0.1:9201",
            spawned_by = "user", pid = dpid)
        c_local.status = :connected
        to_remove = Kaimon.REPLConnection[]
        Kaimon._process_health_result!(mgr, c_local, nothing, to_remove)
        @test c_local in to_remove

        # Remote TCP with the same dead PID → NOT reaped (its PID is on another
        # machine); stays :stalled.
        c_remote = Kaimon.REPLConnection(
            session_id = "tcp-10.0.0.5-9202", endpoint = "tcp://10.0.0.5:9202",
            spawned_by = "user", pid = dpid)
        c_remote.status = :connected
        to_remove2 = Kaimon.REPLConnection[]
        Kaimon._process_health_result!(mgr, c_remote, nothing, to_remove2)
        @test isempty(to_remove2)
        @test c_remote.status == :stalled

        # Localhost TCP with unknown PID (0, never ponged) → NOT reaped; can't
        # verify liveness, so it must not be torn down.
        c_unknown = Kaimon.REPLConnection(
            session_id = "tcp-127.0.0.1-9203", endpoint = "tcp://127.0.0.1:9203",
            spawned_by = "user", pid = 0)
        c_unknown.status = :connected
        to_remove3 = Kaimon.REPLConnection[]
        Kaimon._process_health_result!(mgr, c_unknown, nothing, to_remove3)
        @test isempty(to_remove3)
        @test c_unknown.status == :stalled
    end

    @testset "_resolve_gate_conn allow_stalled" begin
        # A stalled session is rejected by default but reachable with allow_stalled
        # so manage_repl can force-evict it.
        mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
        conn = Kaimon.REPLConnection(
            session_id = "tcp-127.0.0.1-9300", endpoint = "tcp://127.0.0.1:9300",
            name = "stalledsess", spawned_by = "user", pid = 22222)
        conn.status = :stalled
        lock(mgr.lock) do
            push!(mgr.connections, conn)
        end
        key = Kaimon.short_key(conn)
        old_mgr = Kaimon.GATE_CONN_MGR[]
        Kaimon.GATE_CONN_MGR[] = mgr
        try
            c1, err1 = Kaimon._resolve_gate_conn(key)
            @test c1 === nothing            # default: stalled rejected
            @test err1 !== nothing
            @test occursin("stalled", err1)

            c2, err2 = Kaimon._resolve_gate_conn(key; allow_stalled = true)
            @test err2 === nothing          # allow_stalled: reachable
            @test c2 === conn
        finally
            Kaimon.GATE_CONN_MGR[] = old_mgr
        end
    end

    @testset "extension runtimes are not addressable sessions" begin
        # An extension (e.g. Slate) connects as a gate session but is NOT a REPL:
        # agents must not auto-bind to it, resolve it via ses=, or eval in it. The
        # resolver primitives exclude it by default; only the extension-management
        # machinery opts in via include_extensions=true.
        proj = "/tmp/KaimonSlate.jl"
        mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
        ext = Kaimon.REPLConnection(
            session_id = "tcp-127.0.0.1-9400", endpoint = "tcp://127.0.0.1:9400",
            name = "slate", namespace = "slate", project_path = proj,
            spawned_by = "extension", pid = 40000)
        ext.status = :connected
        lock(mgr.lock) do
            push!(mgr.connections, ext)
        end
        ekey = Kaimon.short_key(ext)

        # Predicates classify provenance.
        @test Kaimon.is_extension(ext)
        @test !Kaimon.is_agent_spawned(ext)

        # connected_sessions / get_connection_by_key hide the extension by default…
        @test isempty(Kaimon.connected_sessions(mgr))
        @test Kaimon.get_connection_by_key(mgr, ekey) === nothing
        # …but the extension machinery can still reach it explicitly.
        @test Kaimon.connected_sessions(mgr; include_extensions = true) == [ext]
        @test Kaimon.get_connection_by_key(mgr, ekey; include_extensions = true) === ext

        # An extension's own TUI panel is that machinery: its ctx.eval must reach the extension.
        # (This connection has no live channel, so the eval itself reports "not connected".)
        pctx = Kaimon.ExtPanelContext(ekey, mgr, "slate", proj, 0, Dict{Symbol,Any}(), identity, identity)
        r = Kaimon.ext_panel_eval(pctx, "1")
        @test r.stderr != "Error: extension session not found"
        @test occursin("Gate not connected", string(r.exception))
        @test occursin("Gate not connected", Kaimon.ext_panel_request(pctx, "x"))

        old_mgr = Kaimon.GATE_CONN_MGR[]
        Kaimon.GATE_CONN_MGR[] = mgr
        try
            # The reported bug: an agent whose workspace root is the extension's own
            # project must NOT be auto-bound to the extension connection.
            caller = "caller-ext-test"
            sess = Kaimon.Session.MCPSession()
            sess.id = caller
            lock(Kaimon.STANDALONE_SESSIONS_LOCK) do
                Kaimon.STANDALONE_SESSIONS[caller] = sess
            end
            try
                Kaimon._bind_caller_to_project!(caller, proj)
                @test sess.target_julia_session_id === nothing   # not bound to the ext

                # A real REPL for the same project IS a valid bind target.
                repl = Kaimon.REPLConnection(
                    session_id = "tcp-127.0.0.1-9401", endpoint = "tcp://127.0.0.1:9401",
                    name = "slate-repl", project_path = proj, spawned_by = "user", pid = 40001)
                repl.status = :connected
                lock(mgr.lock) do
                    push!(mgr.connections, repl)
                end
                Kaimon._bind_caller_to_project!(caller, proj)
                @test sess.target_julia_session_id == Kaimon.short_key(repl)
            finally
                lock(Kaimon.STANDALONE_SESSIONS_LOCK) do
                    delete!(Kaimon.STANDALONE_SESSIONS, caller)
                end
            end

            # Explicitly targeting the extension key yields a teaching error, not a
            # generic "no match": it names the extension and points at start_session.
            c, err = Kaimon._resolve_gate_conn(ekey)
            @test c === nothing
            @test err !== nothing
            @test occursin("extension", err)
            @test occursin("start_session", err)
        finally
            Kaimon.GATE_CONN_MGR[] = old_mgr
        end
    end

end

# ─────────────────────────────────────────────────────────────────────────────
# Windows path: a gate on a platform without ZMQ IPC (Windows) is coerced to a
# local TCP bind. It must still ADVERTISE itself for file discovery — write session
# metadata with mode=tcp + a tcp://127.0.0.1:<port> endpoint — so the server finds
# and connects it exactly like an IPC session. Before the fix the coerced gate wrote
# no metadata and was never discovered, so extension/session startup timed out.
#
# We flip `KaimonGate._NO_IPC_TRANSPORT` on this POSIX host to drive the same
# coerce-and-advertise branch Windows takes, start a real local TCP gate, and run the
# actual discover → connect → health-check → eval flow the server uses.
# ─────────────────────────────────────────────────────────────────────────────

@testset "Windows-coerced local TCP gate is discovered via file (#41)" begin
    KG = Kaimon.KaimonGate
    if KG._running()
        @info "Skipping — a gate is already running in this process"
        @test_skip false
    else
        mktempdir() do cache
            withenv("XDG_CACHE_HOME" => cache) do
                orig_no_ipc = KG._NO_IPC_TRANSPORT[]
                KG._NO_IPC_TRANSPORT[] = true    # simulate Windows: no IPC transport
                sid = "slate-ext-$(bytes2hex(rand(UInt8, 4)))"
                mgr = Kaimon.ConnectionManager(sock_dir = KG.sock_dir())
                try
                    # Boot the extension's gate the way its subprocess does: a default
                    # (IPC-requested) serve, namespaced "slate", with a tool. On the
                    # simulated-Windows host this is coerced to a local TCP bind.
                    KG._serve(name = "KaimonSlate", session_id = sid, force = true,
                              mode = :ipc, host = "127.0.0.1", port = 0,
                              namespace = "slate", spawned_by = "extension",
                              tools = [KG.GateTool("noop", a -> "ok")])
                    sleep(0.3)

                    @test KG._mode() == :tcp                    # coerced IPC → TCP
                    @test KG._local_tcp_coerced()               # flagged local (so restart re-coerces, not pins :tcp)

                    # The fix: it advertised discovery metadata despite being TCP.
                    metafile = joinpath(KG.sock_dir(), "$sid.json")
                    @test isfile(metafile)
                    metatxt = read(metafile, String)
                    @test occursin("\"mode\": \"tcp\"", metatxt)
                    @test occursin("tcp://127.0.0.1:", metatxt)
                    @test occursin("\"spawned_by\": \"extension\"", metatxt)

                    # Discovery half: the server scans the dir and builds a connection for
                    # the local, unregistered TCP gate (a remote/registered one is skipped).
                    new_conns = Kaimon.discover_sessions(mgr)
                    idx = findfirst(c -> c.session_id == sid, new_conns)
                    @test idx !== nothing
                    conn = new_conns[idx]
                    @test startswith(conn.endpoint, "tcp://127.0.0.1:")
                    @test conn.spawned_by == "extension"

                    # Connect + health-check, exactly as the watcher / health loop do.
                    Kaimon.connect!(mgr, conn)
                    @test conn.status == :connected
                    lock(mgr.lock) do
                        push!(mgr.connections, conn)
                    end

                    pong = Kaimon.ping(conn)
                    @test pong !== nothing
                    @test string(get(pong, :namespace, "")) == "slate"

                    # The extension monitor matches on conn.namespace — prove the health
                    # path sets it (this is what flips the extension to :running).
                    Kaimon._process_health_result!(mgr, conn, pong, Kaimon.REPLConnection[])
                    @test conn.namespace == "slate"

                    # And it's a live, usable gate: an eval round-trips through it. The gate's
                    # XPUB is a slow joiner, so poll (draining each round) and re-issue until
                    # the result lands on the freshly-connected SUB.
                    rid = "disc-eval-$(rand(UInt16))"
                    inbox = Channel{Any}(Inf)
                    lock(conn._eval_inboxes_lock) do
                        conn._eval_inboxes[rid] = inbox
                    end
                    resp = Kaimon._req_send_recv(conn,
                        (type = :eval_async, code = "6*7", request_id = rid);
                        caller_timeout = 5.0)
                    @test resp.ok

                    got = false
                    deadline = time() + 8.0
                    while !got && time() < deadline
                        for _ = 1:10
                            Kaimon.drain_stream_messages!(mgr)
                            if isready(inbox)
                                got = true
                                break
                            end
                            sleep(0.05)
                        end
                        got || Kaimon._req_send_recv(conn,
                            (type = :eval_async, code = "6*7", request_id = rid);
                            caller_timeout = 2.0)
                    end
                    @test got   # discovered gate answered an eval

                    lock(conn._eval_inboxes_lock) do
                        delete!(conn._eval_inboxes, rid)
                    end
                finally
                    lock(mgr.lock) do
                        for c in mgr.connections
                            Kaimon.disconnect!(c)
                        end
                    end
                    KG._NO_IPC_TRANSPORT[] = orig_no_ipc
                    KG.stop()
                    sleep(0.1)
                end
            end
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Local TCP discovery must not FLAP an already-connected session. connect_tcp!
# writes a `tcp-HOST-PORT.json` reconnection-cache file; discover_sessions now
# connects local unregistered TCP gates (#50), so it must skip that cache file
# when the session is already tracked — else it reconnects + replaces the live
# connection every sweep (the KaimonSlate-worker flap).
# ─────────────────────────────────────────────────────────────────────────────

@testset "tracked local TCP session is not re-discovered (flap regression)" begin
    dir = mktempdir()
    function write_tcp_meta(port, name)
        meta = Dict{String,Any}(
            "session_id" => "tcp-127.0.0.1-$port", "name" => name, "pid" => getpid(),
            "mode" => "tcp", "endpoint" => "tcp://127.0.0.1:$port",
            "stream_endpoint" => "tcp://127.0.0.1:$(port + 1)", "spawned_by" => "user",
            "project_path" => @__DIR__, "julia_version" => string(VERSION))
        open(joinpath(dir, "tcp-127.0.0.1-$port.json"), "w") do io
            Kaimon.JSON.print(io, meta)
        end
    end
    write_tcp_meta(9100, "worker-tracked")   # already connected
    write_tcp_meta(9200, "worker-new")       # never seen

    mgr = Kaimon.ConnectionManager(sock_dir = dir)
    lock(mgr.lock) do
        push!(mgr.connections, Kaimon.REPLConnection(
            session_id = "tcp-127.0.0.1-9100", endpoint = "tcp://127.0.0.1:9100",
            name = "worker-tracked", spawned_by = "user", pid = Int(getpid())))
    end

    ids = [c.session_id for c in Kaimon.discover_sessions(mgr)]
    @test !("tcp-127.0.0.1-9100" in ids)   # already tracked → skipped (no reconnect/flap)
    @test "tcp-127.0.0.1-9200" in ids       # untracked local TCP → still discovered
    rm(dir; recursive = true)
end

@testset "A restarted gate takes its namespace back" begin
    mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
    conn(id, pid, ns, status) = (c = Kaimon.REPLConnection(session_id = id, endpoint = "ipc:///tmp/$id.sock",
                                                             spawned_by = "user", pid = Int(pid));
                                 c.namespace = ns; c.status = status; c)
    # The session it replaces, its process gone but not reaped yet, gives the namespace up.
    old = conn("old-gate", _dead_pid(), "kb", :connected)
    bystander = conn("other-gate", getpid(), "other", :connected)
    new = conn("new-gate", getpid(), "kb", :connecting)
    lock(mgr.lock) do
        append!(mgr.connections, [old, bystander, new])
    end
    @test Kaimon._resolve_namespace!(new, mgr) == "kb"
    @test !(old in mgr.connections) && bystander in mgr.connections && old.status == :disconnected
    # A live session of the namespace keeps it: another one still gets a suffix.
    new.status = :connected
    another = conn("another-gate", getpid(), "kb", :connecting)
    lock(mgr.lock) do
        push!(mgr.connections, another)
    end
    @test Kaimon._resolve_namespace!(another, mgr) == "kb_2" && new in mgr.connections
end

@testset "A loopback gate on another machine is not judged by PID" begin
    # An SSH tunnel, a container's port-forward and WSL1's loopback shared with Windows all put
    # another machine's gate at 127.0.0.1. Its PID names a process this machine cannot see.
    here = Kaimon.KaimonGate.machine_id()
    elsewhere = "WINNT:another-host"
    dpid = _dead_pid()
    tcp(port, machine; ns = "") = (c = Kaimon.REPLConnection(session_id = "tcp-127.0.0.1-$port",
            endpoint = "tcp://127.0.0.1:$port", spawned_by = "user", pid = dpid, machine = machine);
        c.namespace = ns; c.status = :connected; c)

    other, same, unreported = tcp(9401, elsewhere), tcp(9402, here), tcp(9403, "")
    @test !Kaimon._is_local_tcp(other) && !Kaimon._process_gone(other)
    @test Kaimon._is_local_tcp(same) && Kaimon._process_gone(same)
    @test Kaimon._is_local_tcp(unreported)          # a gate too old to say: judged by its address
    @test Kaimon.trigger_backtrace(other) === nothing

    # A missed pong leaves it stalled; the same machine's dead PID is reaped.
    mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
    to_remove = Kaimon.REPLConnection[]
    Kaimon._process_health_result!(mgr, other, nothing, to_remove)
    Kaimon._process_health_result!(mgr, same, nothing, to_remove)
    @test to_remove == [same] && other.status == :stalled

    # A newcomer of the namespace does not take it from a session it cannot see die.
    mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
    old, new = tcp(9411, elsewhere; ns = "demo"), tcp(9412, elsewhere; ns = "demo")
    lock(mgr.lock) do; append!(mgr.connections, [old, new]); end
    @test Kaimon._resolve_namespace!(new, mgr) == "demo_2" && old in mgr.connections

    # The pong supplies the identity, and the session file keeps it for the stale-session sweep.
    sock_dir = mktempdir()
    mgr = Kaimon.ConnectionManager(sock_dir = sock_dir)
    c = tcp(9421, "")
    write(joinpath(sock_dir, "$(c.session_id).json"),
          """{"session_id": "$(c.session_id)", "mode": "tcp", "endpoint": "$(c.endpoint)", "pid": $dpid}""")
    pong = (type = :pong, pid = dpid, machine = elsewhere, uptime = 1.0, julia_version = string(VERSION),
            kaimon_version = "test", project_path = "", tools = [], namespace = "", stream_endpoint = "",
            allow_restart = false, allow_mirror = false, mirror_repl = false)
    Kaimon._process_health_result!(mgr, c, pong, Kaimon.REPLConnection[])
    @test c.machine == elsewhere
    @test Kaimon.JSON.parsefile(joinpath(sock_dir, "$(c.session_id).json"))["machine"] == elsewhere
    Kaimon.cleanup_stale_sessions!(sock_dir)
    @test isfile(joinpath(sock_dir, "$(c.session_id).json"))   # kept: its PID is not this machine's
end

@testset "A reconnected session is not charged with its predecessor's failed ping" begin
    # Dropped and reconnected, a session keeps its id. The ping still out for the dropped object
    # fails, and must not reach the new one: with a PID this machine cannot see alive, that one
    # failure removes it, and every reconnect after it the same way.
    mgr = Kaimon.ConnectionManager(sock_dir = mktempdir())
    tcp() = (c = Kaimon.REPLConnection(session_id = "tcp-127.0.0.1-9431", endpoint = "tcp://127.0.0.1:9431",
                                       spawned_by = "user", pid = _dead_pid()); c.status = :connected; c)
    dropped, reconnected = tcp(), tcp()
    lock(mgr.lock) do; push!(mgr.connections, reconnected); end
    failed = Threads.@spawn nothing
    wait(failed)
    pending = IdDict{Kaimon.REPLConnection,Task}(dropped => failed)

    @test isempty(Kaimon._health_sweep!(mgr, pending))
    @test reconnected in mgr.connections && reconnected.status == :connected
    @test !haskey(pending, dropped) && haskey(pending, reconnected)   # pinged in its own right

    # Its own failed ping still removes it: its PID is dead, on this machine by its address.
    wait(pending[reconnected])
    @test Kaimon._health_sweep!(mgr, pending) == [reconnected]
    @test !(reconnected in mgr.connections) && !haskey(pending, reconnected)
end

@testset "Tool calls wait for a gate that is connecting" begin
    c = Kaimon.REPLConnection(session_id = "slow-gate", endpoint = "ipc:///tmp/slow-gate.sock", spawned_by = "user")
    c.status = :connecting
    @async (sleep(0.3); c.status = :disconnected)
    t = time()
    @test !Kaimon._gate_callable(c; wait_s = 5)            # gave up when it failed, not after the wait
    @test time() - t < 2
    c.status = :stalled                                     # stalled, but with no request channel to send on
    @test !Kaimon._gate_callable(c; wait_s = 0)
    @test occursin("status=stalled", Kaimon._call_session_tool(c, "t", Dict()))

    # Stalled with a channel: a busy gate is sent the call, one whose process exited is not.
    c.req_channel = Kaimon.RequestChannel(
        Kaimon.ZMQ.Socket(Kaimon.ZMQ.DEALER), "ipc:///kaimon-test-unused",
        Channel{Tuple{UInt64,Vector{UInt8}}}(1), Dict{UInt64,Channel{Any}}(), ReentrantLock(),
        Threads.Atomic{UInt64}(0), nothing, nothing, Ref(true), nothing, ReentrantLock(), Threads.Event(true), Threads.Event(true))
    c.pid = getpid()
    @test Kaimon._gate_callable(c; wait_s = 0)
    c.pid = _dead_pid()
    @test !Kaimon._gate_callable(c; wait_s = 0)
end

@testset "The TCP Gates panel follows tcp_gates.json" begin
    # The gate poller connects whatever the file lists, so the panel must show what it lists,
    # including entries written by another process while the TUI runs.
    withenv("XDG_CONFIG_HOME" => mktempdir()) do
        entry(port) = Kaimon.TCPGateEntry("127.0.0.1", port, "g$port", true, "", 0)
        Kaimon.save_tcp_gates_config([entry(9501)])
        Kaimon._TCP_GATES_MTIME[] = -1.0
        m = Kaimon.KaimonModel()
        Kaimon._sync_tcp_gate_entries!(m)
        @test [e.port for e in m.tcp_gate_entries] == [9501]

        Kaimon.save_tcp_gates_config([entry(9501), entry(9502)])
        path = Kaimon.get_tcp_gates_config_path()
        later = Int64(floor(mtime(path))) + 5          # a later mtime, whatever the file system's grain
        ccall(:utime, Cint, (Cstring, Ptr{Int64}), path, Int64[later, later])
        Kaimon._sync_tcp_gate_entries!(m)
        @test [e.port for e in m.tcp_gate_entries] == [9501, 9502]

        rm(path)
        Kaimon._sync_tcp_gate_entries!(m)
        @test isempty(m.tcp_gate_entries)
    end
end

@testset "Gates on the Windows side of WSL are discovered, never judged by PID" begin
    # Under WSL1, Windows gates write their session files to the Windows user's directory and
    # listen on the loopback Linux shares. Their PIDs cannot be looked up from Linux.
    sock, win = mktempdir(), mktempdir()
    dpid = _dead_pid()
    meta(id, mode) = """{"session_id": "$id", "name": "julia", "mode": "$mode", "pid": $dpid,
        "endpoint": "tcp://127.0.0.1:9601", "stream_endpoint": "", "project_path": "/c/demo",
        "julia_version": "1.13.0", "spawned_by": "user"}"""
    write(joinpath(win, "win-gate.json"), meta("win-gate", "tcp"))
    write(joinpath(win, "win-ipc.json"), meta("win-ipc", "ipc"))   # a Windows socket is no use here
    withenv("KAIMON_WINDOWS_SOCK_DIR" => win, "XDG_CONFIG_HOME" => mktempdir()) do
        Kaimon._WINDOWS_SOCK_DIR[] = nothing
        try
            found = Kaimon.discover_sessions(Kaimon.ConnectionManager(sock_dir = sock))
            @test [c.session_id for c in found] == ["win-gate"]
            c = only(found)
            @test !Kaimon._is_local_tcp(c) && !Kaimon._process_gone(c)
            @test isfile(joinpath(win, "win-gate.json"))           # read, never cleaned up from here
            rm(joinpath(win, "win-gate.json"))                      # what the gate does as it exits
            @test Kaimon._process_gone(c)
        finally
            Kaimon._WINDOWS_SOCK_DIR[] = nothing
        end
    end
    withenv("KAIMON_WINDOWS_SOCK_DIR" => "off") do
        Kaimon._WINDOWS_SOCK_DIR[] = nothing
        @test Kaimon._windows_sock_dir() == ""
        Kaimon._WINDOWS_SOCK_DIR[] = nothing
    end
end

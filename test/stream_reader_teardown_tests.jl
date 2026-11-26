using ReTest
using ZMQ
using Kaimon

# Closing a connection's SUB socket closes Kaimon's watchers on its fd first (#115). FileWatching
# shares one watcher per fd number, so a watcher left open on the closed fd would be handed to the
# next file opened with that number (another session's SUB socket, or a PTY master).

const _SR = Kaimon

_sr_fd_watched(fd) = ccall(:jl_uv_unix_fd_is_watched, Int32, (RawFD, Ptr{Cvoid}, Ptr{Cvoid}),
                           fd, C_NULL, Base.eventloop()) == 1

function _sr_until(f; timeout = 5.0)
    deadline = time() + timeout
    while !f() && time() < deadline
        sleep(0.02)
    end
    return f()
end

# A connection whose SUB socket is subscribed to a local PUB over IPC.
function _sr_conn(ctx)
    endpoint = "ipc://" * joinpath(mktempdir(), "pub.sock")
    pub = Socket(ctx, PUB)
    pub.linger = 0
    bind(pub, endpoint)
    sub = Socket(ctx, SUB)
    sub.linger = 0
    sub.rcvtimeo = 0
    subscribe(sub, "")
    connect(sub, endpoint)
    conn = _SR.REPLConnection(session_id = "sub-teardown-$(rand(UInt32))", endpoint = "ipc:///nonexistent",
                              stream_endpoint = endpoint)
    conn.sub_socket = sub
    conn.status = :connected
    return conn, pub, sub
end

@testset "Stream reader teardown" begin
    if Sys.iswindows()
        @test_skip true
    else
        @testset "disconnect! ends a parked stream reader and leaves its fd unwatched" begin
            ctx = Context()
            conn, pub, sub = _sr_conn(ctx)
            mgr = _SR.ConnectionManager(sock_dir = mktempdir())
            mgr.running = true
            fd = Base.fd(sub)
            reader = Threads.@spawn _SR._sub_reader(mgr, conn)
            try
                @test _sr_until(() -> length(conn.sub_watchers) == 1)
                sleep(0.1)   # let the reader park in wait
                @test _sr_fd_watched(fd)
                _SR.disconnect!(conn)
                @test _sr_until(() -> istaskdone(reader); timeout = 2.0)
                @test isempty(conn.sub_watchers)
                @test conn.sub_socket === nothing
                @test !_sr_fd_watched(fd)
            finally
                mgr.running = false
                close(pub)
                close(ctx)
            end
        end

        @testset "a recreated SUB socket is watched, and the old one released" begin
            ctx = Context()
            conn, pub, sub = _sr_conn(ctx)
            mgr = _SR.ConnectionManager(sock_dir = mktempdir())
            mgr.running = true
            old_fd = Base.fd(sub)
            reader = Threads.@spawn _SR._sub_reader(mgr, conn)
            try
                @test _sr_until(() -> length(conn.sub_watchers) == 1)
                sleep(0.1)
                _SR._close_sub_socket!(conn)   # what the health task does before reconnecting
                @test !_sr_fd_watched(old_fd)
                new_sub = Socket(ctx, SUB)
                new_sub.linger = 0
                subscribe(new_sub, "")
                connect(new_sub, conn.stream_endpoint)
                lock(conn.req_lock) do; conn.sub_socket = new_sub; end
                @test _sr_until(() -> length(conn.sub_watchers) == 1 && _sr_fd_watched(Base.fd(new_sub)))
                @test !istaskdone(reader)
            finally
                mgr.running = false
                _SR.disconnect!(conn)
                _sr_until(() -> istaskdone(reader); timeout = 2.0)
                close(pub)
                close(ctx)
            end
        end

        @testset "no watcher is made on a socket that is not the connection's open SUB" begin
            ctx = Context()
            conn, pub, sub = _sr_conn(ctx)
            other = Socket(ctx, SUB)
            try
                @test _SR._watch_sub!(conn, other) === nothing
                w = _SR._watch_sub!(conn, sub)
                @test w !== nothing && length(conn.sub_watchers) == 1
                _SR._unwatch_sub!(conn, w)
                @test isempty(conn.sub_watchers)
                _SR._close_sub_socket!(conn)
                @test _SR._watch_sub!(conn, sub) === nothing   # closed
            finally
                close(other)
                close(pub)
                close(ctx)
            end
        end

        @testset "wait_stream_messages! leaves no watcher behind" begin
            ctx = Context()
            conn, pub, sub = _sr_conn(ctx)
            mgr = _SR.ConnectionManager(sock_dir = mktempdir())
            push!(mgr.connections, conn)
            try
                _SR.wait_stream_messages!(mgr; idle_timeout = 0.05)
                @test isempty(conn.sub_watchers)
            finally
                _SR.disconnect!(conn)
                close(pub)
                close(ctx)
            end
        end
    end
end

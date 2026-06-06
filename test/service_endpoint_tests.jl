using ReTest
using Kaimon

const ZMQt = Kaimon.ZMQ

@testset "Service endpoint (ROUTER concurrency rework)" begin
    @testset "_is_agent_turn gates only agent_run" begin
        @test Kaimon._is_agent_turn((type = :tool_call, tool_name = :agent_run, args = Dict()))
        @test !Kaimon._is_agent_turn((type = :tool_call, tool_name = :qdrant_search, args = Dict()))
        @test !Kaimon._is_agent_turn((type = :tool_call, tool_name = :agent_send, args = Dict()))
        @test !Kaimon._is_agent_turn((type = :list_tools,))
    end

    @testset "multipart framing round-trips REQ↔ROUTER" begin
        # Hermetic: private context + temp ipc path, never touches the live service socket.
        dir = mktempdir()
        path = joinpath(dir, "svc-test.sock")
        ctx = ZMQt.Context()
        router = ZMQt.Socket(ctx, ZMQt.ROUTER); router.rcvtimeo = 2000; router.linger = 0
        ZMQt.bind(router, "ipc://$path")
        req = ZMQt.Socket(ctx, ZMQt.REQ); req.rcvtimeo = 2000; req.linger = 0
        ZMQt.connect(req, "ipc://$path")
        try
            # REQ → ROUTER: arrives as [identity, empty-delimiter, payload]
            ZMQt.send(req, Vector{UInt8}("ping"))
            parts = Kaimon._recv_multipart(router)
            @test length(parts) == 3
            @test isempty(parts[2])                       # the REQ empty delimiter
            @test String(parts[end]) == "ping"
            # ROUTER → REQ: echo back with the same identity envelope
            Kaimon._send_multipart(router, Vector{UInt8}[parts[1], UInt8[], Vector{UInt8}("pong")])
            @test String(ZMQt.recv(req, Vector{UInt8})) == "pong"
        finally
            close(req); close(router); close(ctx)
        end
    end

    @testset "two REQ clients are routed back by identity" begin
        dir = mktempdir()
        path = joinpath(dir, "svc-multi.sock")
        ctx = ZMQt.Context()
        router = ZMQt.Socket(ctx, ZMQt.ROUTER); router.rcvtimeo = 2000; router.linger = 0
        ZMQt.bind(router, "ipc://$path")
        a = ZMQt.Socket(ctx, ZMQt.REQ); a.rcvtimeo = 2000; a.linger = 0; ZMQt.connect(a, "ipc://$path")
        b = ZMQt.Socket(ctx, ZMQt.REQ); b.rcvtimeo = 2000; b.linger = 0; ZMQt.connect(b, "ipc://$path")
        try
            ZMQt.send(a, Vector{UInt8}("A"))
            ZMQt.send(b, Vector{UInt8}("B"))
            # Receive both (order not guaranteed), reply each to its own identity.
            replies = Dict{String,Vector{UInt8}}()
            for _ in 1:2
                p = Kaimon._recv_multipart(router)
                tag = String(p[end])                      # "A" or "B"
                replies[tag] = p[1]
                Kaimon._send_multipart(router, Vector{UInt8}[p[1], UInt8[], Vector{UInt8}("re:" * tag)])
            end
            @test replies["A"] != replies["B"]            # distinct ROUTER identities
            @test String(ZMQt.recv(a, Vector{UInt8})) == "re:A"
            @test String(ZMQt.recv(b, Vector{UInt8})) == "re:B"
        finally
            close(a); close(b); close(router); close(ctx)
        end
    end
end

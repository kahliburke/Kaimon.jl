using Test
using KaimonGate
using ZMQ

const KG = KaimonGate

# ── Pure helpers (no sockets) ──────────────────────────────────────────────────

@testset "CURVE keygen + Z85" begin
    pub, sec = KG.curve_keypair()
    @test length(pub) == 40
    @test length(sec) == 40
    @test pub != sec

    # public derives deterministically from secret
    @test KG.curve_public(sec) == pub

    # _z85_encode round-trips a 32-byte binary key back to its Z85 form
    bin = Vector{UInt8}(undef, 32)
    GC.@preserve bin begin
        p = ZMQ.lib.zmq_z85_decode(bin, pointer(codeunits(pub * "\0")))
        @test p != C_NULL
    end
    @test KG._z85_encode(bin) == pub

    @test_throws ErrorException KG._z85_encode(UInt8[1, 2, 3])  # wrong length
end

@testset "Key persistence" begin
    mktempdir() do dir
        withenv("XDG_CACHE_HOME" => dir) do
            pub1, sec1 = KG._load_or_create_server_keypair()
            @test length(pub1) == 40
            # second call returns the SAME persisted keypair
            pub2, sec2 = KG._load_or_create_server_keypair()
            @test (pub1, sec1) == (pub2, sec2)
            # the key file exists and is owner-only
            keyfile = joinpath(dir, "curve", "server.key")
            @test isfile(keyfile)
            if !Sys.iswindows()
                @test (stat(keyfile).mode & 0o777) == 0o600
            end
            # client keypair is distinct from the server's
            cpub, _ = KG._load_or_create_client_keypair()
            @test cpub != pub1
        end
    end
end

@testset "TOFU server pinning" begin
    mktempdir() do dir
        withenv("XDG_CACHE_HOME" => dir) do
            pub, _ = KG.curve_keypair()
            @test KG._pinned_server("h", 9000) === nothing
            @test KG.pin_server!("h", 9000, pub) == :pinned
            @test KG._pinned_server("h", 9000) == pub
            @test KG.pin_server!("h", 9000, pub) == :ok          # same key
            other, _ = KG.curve_keypair()
            @test KG.pin_server!("h", 9000, other) == :mismatch  # MITM signal
        end
    end
end

@testset "Client allow-list" begin
    mktempdir() do dir
        withenv("XDG_CACHE_HOME" => dir) do
            pub, _ = KG.curve_keypair()
            @test isempty(KG._authorized_clients())
            @test KG.authorize_client!(pub) == :added
            @test pub in KG._authorized_clients()
            @test KG.authorize_client!(pub) == :already
        end
    end
end

# ── Live transport (raw sockets — exercises make_curve_* + ZAP) ────────────────

if KG._RUNNING[]
    @warn "A gate is already running — skipping CURVE transport tests."
    @testset "CURVE transport (skipped — gate already running)" begin
        @test_skip true
    end
else

# Echo loop tolerant of the rcvtimeo so it survives until the socket closes.
function _echo_loop(rep)
    @async while true
        try
            msg = ZMQ.recv(rep, Vector{UInt8})
            ZMQ.send(rep, msg)
        catch e
            e isa ZMQ.TimeoutError && continue
            break   # socket closed
        end
    end
end

@testset "CURVE round-trip + server auth" begin
    spub, ssec = KG.curve_keypair()
    ctx = ZMQ.Context()
    rep = ZMQ.Socket(ctx, ZMQ.REP); rep.rcvtimeo = 1000; rep.linger = 0
    KG.make_curve_server!(rep, ssec)
    ZMQ.bind(rep, "tcp://127.0.0.1:0")
    endpoint = rstrip(ZMQ._get_last_endpoint(rep), '\0')
    server = _echo_loop(rep)

    try
        # good client (correct server pubkey) → encrypted round-trip works
        cpub, csec = KG.curve_keypair()
        req = ZMQ.Socket(ctx, ZMQ.REQ); req.rcvtimeo = 3000; req.linger = 0
        KG.make_curve_client!(req, spub, cpub, csec)
        ZMQ.connect(req, endpoint)
        ZMQ.send(req, "hello")
        @test String(ZMQ.recv(req, Vector{UInt8})) == "hello"
        ZMQ.close(req)

        # wrong server key → handshake fails, no reply ever arrives
        wrongpub, _ = KG.curve_keypair()
        bcpub, bcsec = KG.curve_keypair()
        bad = ZMQ.Socket(ctx, ZMQ.REQ); bad.rcvtimeo = 1200; bad.linger = 0
        KG.make_curve_client!(bad, wrongpub, bcpub, bcsec)
        ZMQ.connect(bad, endpoint)
        ZMQ.send(bad, "hello")
        @test_throws ZMQ.TimeoutError ZMQ.recv(bad, Vector{UInt8})
        ZMQ.close(bad)
    finally
        ZMQ.close(rep)
        ZMQ.close(ctx)
        sleep(0.05)
    end
end

@testset "ZAP allow-list (mutual auth)" begin
    spub, ssec = KG.curve_keypair()
    good_pub, good_sec = KG.curve_keypair()
    other_pub, other_sec = KG.curve_keypair()

    mktempdir() do dir
        withenv("XDG_CACHE_HOME" => dir) do
            prev_running = KG._RUNNING[]
            KG._RUNNING[] = true                       # let the handler loop run
            KG.authorize_client!(good_pub)             # only this client is allowed
            ctx = ZMQ.Context()
            KG._start_zap_handler!(ctx; allow_any = false)
            rep = ZMQ.Socket(ctx, ZMQ.REP); rep.rcvtimeo = 1000; rep.linger = 0
            KG.make_curve_server!(rep, ssec)
            KG._setsockopt_str(rep, KG._ZMQ_ZAP_DOMAIN, KG._ZAP_DOMAIN)  # consult ZAP
            ZMQ.bind(rep, "tcp://127.0.0.1:0")
            endpoint = rstrip(ZMQ._get_last_endpoint(rep), '\0')
            server = _echo_loop(rep)

            try
                # allowed client → connects
                req = ZMQ.Socket(ctx, ZMQ.REQ); req.rcvtimeo = 3000; req.linger = 0
                KG.make_curve_client!(req, spub, good_pub, good_sec)
                ZMQ.connect(req, endpoint)
                ZMQ.send(req, "ok")
                @test String(ZMQ.recv(req, Vector{UInt8})) == "ok"
                ZMQ.close(req)

                # client off the allow-list → ZAP denies, no reply
                bad = ZMQ.Socket(ctx, ZMQ.REQ); bad.rcvtimeo = 1200; bad.linger = 0
                KG.make_curve_client!(bad, spub, other_pub, other_sec)
                ZMQ.connect(bad, endpoint)
                ZMQ.send(bad, "nope")
                @test_throws ZMQ.TimeoutError ZMQ.recv(bad, Vector{UInt8})
                ZMQ.close(bad)
            finally
                ZMQ.close(rep)
                KG._RUNNING[] = false          # stop the ZAP handler loop
                sleep(0.4)                     # let it close its socket
                ZMQ.close(ctx)
                KG._RUNNING[] = prev_running
            end
        end
    end
end

end  # if !_RUNNING[]

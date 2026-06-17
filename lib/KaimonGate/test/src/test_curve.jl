using Test
using KaimonGate
using ZMQ
using Serialization

const KG = KaimonGate

"""Serialize a request to a REQ socket and return the deserialized reply."""
function _zmq_req(sock, msg)
    buf = IOBuffer()
    Serialization.serialize(buf, msg)
    ZMQ.send(sock, ZMQ.Message(take!(buf)))
    Serialization.deserialize(IOBuffer(ZMQ.recv(sock)))
end

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
            # the key file exists and is owner-only. _gate_cache_dir appends
            # "kaimon" under XDG_CACHE_HOME (consistent with the Kaimon server),
            # so the curve store lives at $XDG/kaimon/curve. (#42/#45)
            keyfile = joinpath(dir, "kaimon", "curve", "server.key")
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

            # known_servers lists every pin; unpin_server! removes by host:port
            pub2, _ = KG.curve_keypair()
            @test KG.pin_server!("h2", 9100, pub2) == :pinned
            servers = Dict(KG.known_servers())
            @test servers["h:9000"] == pub
            @test servers["h2:9100"] == pub2
            @test KG.unpin_server!("h:9000") == :removed
            @test KG._pinned_server("h", 9000) === nothing
            @test KG._pinned_server("h2", 9100) == pub2   # other pin untouched
            @test KG.unpin_server!("h:9000") == :absent   # already gone
        end
    end
end

@testset "verify_server_key_via_ssh (reconcile via stub fetch)" begin
    mktempdir() do dir
        withenv("XDG_CACHE_HOME" => dir) do
            good, _ = KG.curve_keypair()
            other, _ = KG.curve_keypair()
            getgood(_t, _p) = good
            getother(_t, _p) = other

            # no prior pin → :pinned (bootstrap)
            r1 = KG.verify_server_key_via_ssh("h", 9000; fetch = getgood)
            @test r1.status == :pinned
            @test r1.old_pin === nothing
            @test KG._pinned_server("h", 9000) == good

            # same key → :ok (verified)
            r2 = KG.verify_server_key_via_ssh("h", 9000; fetch = getgood)
            @test r2.status == :ok

            # different key, repin=false → :changed, pin untouched
            r3 = KG.verify_server_key_via_ssh("h", 9000; fetch = getother)
            @test r3.status == :changed
            @test r3.old_pin == good
            @test r3.key == other
            @test KG._pinned_server("h", 9000) == good

            # repin=true → adopts the new key
            r4 = KG.verify_server_key_via_ssh("h", 9000; fetch = getother, repin = true)
            @test r4.status == :changed
            @test KG._pinned_server("h", 9000) == other

            # malformed key → :error, pin untouched
            r5 = KG.verify_server_key_via_ssh("h", 9000; fetch = (_t, _p) -> "tooshort")
            @test r5.status == :error
            @test KG._pinned_server("h", 9000) == other

            # fetch throws (ssh failure) → :error
            r6 = KG.verify_server_key_via_ssh("h", 9001; fetch = (_t, _p) -> error("ssh failed"))
            @test r6.status == :error
            @test KG._pinned_server("h", 9001) === nothing
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

            # authorized_clients() lists (sorted); revoke_client! removes one
            pub2, _ = KG.curve_keypair()
            @test KG.authorize_client!(pub2) == :added
            listed = KG.authorized_clients()
            @test listed == sort([pub, pub2])
            @test KG.revoke_client!(pub) == :removed
            @test pub ∉ KG._authorized_clients()
            @test pub2 in KG._authorized_clients()   # other key untouched
            @test KG.revoke_client!(pub) == :absent  # already gone
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

@testset "ZAP live re-read (authorize/revoke without restart)" begin
    spub, ssec = KG.curve_keypair()
    cpub, csec = KG.curve_keypair()

    mktempdir() do dir
        withenv("XDG_CACHE_HOME" => dir) do
            prev_running = KG._RUNNING[]
            KG._RUNNING[] = true
            ctx = ZMQ.Context()
            KG._start_zap_handler!(ctx; allow_any = false)   # empty allow-list at start
            rep = ZMQ.Socket(ctx, ZMQ.REP); rep.rcvtimeo = 1000; rep.linger = 0
            KG.make_curve_server!(rep, ssec)
            KG._setsockopt_str(rep, KG._ZMQ_ZAP_DOMAIN, KG._ZAP_DOMAIN)
            ZMQ.bind(rep, "tcp://127.0.0.1:0")
            endpoint = rstrip(ZMQ._get_last_endpoint(rep), '\0')
            server = _echo_loop(rep)

            try
                # not yet authorized → denied
                r1 = ZMQ.Socket(ctx, ZMQ.REQ); r1.rcvtimeo = 1200; r1.linger = 0
                KG.make_curve_client!(r1, spub, cpub, csec)
                ZMQ.connect(r1, endpoint); ZMQ.send(r1, "x")
                @test_throws ZMQ.TimeoutError ZMQ.recv(r1, Vector{UInt8})
                ZMQ.close(r1)

                # authorize WITHOUT restarting the handler → next handshake allowed
                @test KG.authorize_client!(cpub) == :added
                r2 = ZMQ.Socket(ctx, ZMQ.REQ); r2.rcvtimeo = 3000; r2.linger = 0
                KG.make_curve_client!(r2, spub, cpub, csec)
                ZMQ.connect(r2, endpoint); ZMQ.send(r2, "ok")
                @test String(ZMQ.recv(r2, Vector{UInt8})) == "ok"
                ZMQ.close(r2)

                # revoke WITHOUT restarting the handler → next handshake denied
                @test KG.revoke_client!(cpub) == :removed
                r3 = ZMQ.Socket(ctx, ZMQ.REQ); r3.rcvtimeo = 1200; r3.linger = 0
                KG.make_curve_client!(r3, spub, cpub, csec)
                ZMQ.connect(r3, endpoint); ZMQ.send(r3, "nope")
                @test_throws ZMQ.TimeoutError ZMQ.recv(r3, Vector{UInt8})
                ZMQ.close(r3)
            finally
                ZMQ.close(rep)
                KG._RUNNING[] = false
                sleep(0.4)
                ZMQ.close(ctx)
                KG._RUNNING[] = prev_running
            end
        end
    end
end

@testset "serve(curve=true) + publish/subscribe (allow_any)" begin
    Sys.iswindows() && (@test_skip true; return)
    mktempdir() do dir
        withenv("XDG_CACHE_HOME" => dir) do
            sid = "test-curve-$(bytes2hex(rand(UInt8, 4)))"
            KG._serve(name = "curve", session_id = sid, force = true, mode = :tcp,
                      host = "127.0.0.1", port = 0, curve = true, allow_any = true)
            sleep(0.25)
            try
                @test KG._RUNNING[]
                @test KG._CURVE_ENABLED[]
                spub = KG._CURVE_SERVER_PUBLIC[]
                @test length(spub) == 40

                rep_endpoint = rstrip(ZMQ._get_last_endpoint(KG._GATE_SOCKET[]), '\0')
                pub_endpoint = KG._STREAM_ENDPOINT[]
                ctx = ZMQ.Context()

                # CURVE client (correct server key, ephemeral client key) → pong
                cpub, csec = KG.curve_keypair()
                req = ZMQ.Socket(ctx, ZMQ.REQ); req.rcvtimeo = 3000; req.linger = 0
                KG.make_curve_client!(req, spub, cpub, csec)
                ZMQ.connect(req, rep_endpoint)
                resp = _zmq_req(req, (type = :ping,))
                @test resp.type == :pong
                @test resp.server_pubkey == spub
                ZMQ.close(req)

                # publish → subscribe over the encrypted PUB (2-frame [topic,payload])
                sub = KG.subscribe(pub_endpoint; topic = "tui:", serverkey = spub, ctx = ctx)
                sub.rcvtimeo = 3000
                sleep(0.25)   # SUB handshake (slow joiner)
                KG.publish("tui:demo", (frame = 1, txt = "hi"))
                parts = ZMQ.recv_multipart(sub, Vector{UInt8})
                @test String(parts[1]) == "tui:demo"
                payload = Serialization.deserialize(IOBuffer(parts[2]))
                @test payload.txt == "hi"
                ZMQ.close(sub)
                ZMQ.close(ctx)
            finally
                KG.stop(); sleep(0.2)
            end
        end
    end
end

@testset "serve(curve=true) allow-list (fail-closed + enroll)" begin
    Sys.iswindows() && (@test_skip true; return)
    mktempdir() do dir
        withenv("XDG_CACHE_HOME" => dir) do
            cpub, csec = KG.curve_keypair()

            # fail-closed: client not enrolled → ZAP denies → no pong
            sid1 = "test-fc-$(bytes2hex(rand(UInt8, 4)))"
            KG._serve(name = "fc", session_id = sid1, force = true, mode = :tcp,
                      host = "127.0.0.1", port = 0, curve = true, allow_any = false)
            sleep(0.25)
            ep1 = rstrip(ZMQ._get_last_endpoint(KG._GATE_SOCKET[]), '\0')
            spub = KG._CURVE_SERVER_PUBLIC[]
            ctx = ZMQ.Context()
            req = ZMQ.Socket(ctx, ZMQ.REQ); req.rcvtimeo = 1200; req.linger = 0
            KG.make_curve_client!(req, spub, cpub, csec)
            ZMQ.connect(req, ep1)
            ZMQ.send(req, "x")
            @test_throws ZMQ.TimeoutError ZMQ.recv(req, Vector{UInt8})
            ZMQ.close(req)
            KG.stop(); sleep(0.2)

            # enrolled: same client key on the allow-list → pong
            sid2 = "test-al-$(bytes2hex(rand(UInt8, 4)))"
            KG._serve(name = "al", session_id = sid2, force = true, mode = :tcp,
                      host = "127.0.0.1", port = 0, curve = true, allow_any = false,
                      allowed_clients = [cpub])
            sleep(0.25)
            ep2 = rstrip(ZMQ._get_last_endpoint(KG._GATE_SOCKET[]), '\0')
            spub2 = KG._CURVE_SERVER_PUBLIC[]
            req2 = ZMQ.Socket(ctx, ZMQ.REQ); req2.rcvtimeo = 3000; req2.linger = 0
            KG.make_curve_client!(req2, spub2, cpub, csec)
            ZMQ.connect(req2, ep2)
            resp = _zmq_req(req2, (type = :ping,))
            @test resp.type == :pong
            ZMQ.close(req2)
            ZMQ.close(ctx)
            KG.stop(); sleep(0.2)
        end
    end
end

end  # if !_RUNNING[]

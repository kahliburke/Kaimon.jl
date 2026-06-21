using Test
using KaimonGate
using ZMQ
using Serialization

# ── Guard: skip all integration tests if a gate is already running ────────────

if KaimonGate._RUNNING[]
    @warn "A gate is already running — skipping ZMQ integration tests to avoid conflicts."
    @testset "ZMQ integration (skipped — gate already running)" begin
        @test_skip true
    end
else

# ── Helpers ───────────────────────────────────────────────────────────────────

"""Send a serialized request to a ZMQ REQ socket and return the deserialized response."""
function zmq_req(sock, msg)
    buf = IOBuffer()
    Serialization.serialize(buf, msg)
    ZMQ.send(sock, ZMQ.Message(take!(buf)))
    raw = ZMQ.recv(sock)
    Serialization.deserialize(IOBuffer(raw))
end

# ── IPC gate lifecycle ─────────────────────────────────────────────────────────

@testset "IPC gate lifecycle" begin
    if Sys.iswindows()
        @test_skip true
    else
        session_id = "test-ipc-$(bytes2hex(rand(UInt8, 4)))"
    KaimonGate._serve(name="test", session_id=session_id, force=true)
    sleep(0.15)   # let sockets bind

    @test KaimonGate._RUNNING[]

    sock_dir  = KaimonGate.sock_dir()
    rep_path  = joinpath(sock_dir, "$session_id.sock")

    ctx = ZMQ.Context()
    req = ZMQ.Socket(ctx, ZMQ.REQ)
    req.rcvtimeo = 5_000
    req.linger   = 0
    ZMQ.connect(req, "ipc://$rep_path")

    try
        resp = zmq_req(req, (type=:ping,))
        @test resp.type == :pong
        @test resp.pid == getpid()
        @test !isempty(resp.stream_endpoint)
    finally
        ZMQ.close(req)
        ZMQ.close(ctx)
        KaimonGate.stop()
        sleep(0.1)
    end

    @test !KaimonGate._RUNNING[]
    end # if Sys.iswindows()
end

# ── Async tool progress + result ──────────────────────────────────────────────
# Adapted from Kaimon gate_async_tests "Gate async integration: progress + result"

@testset "Async tool progress + result" begin
    tool = KaimonGate.GateTool("counted_op", function(n::Int)
        for i in 1:n
            KaimonGate.progress("step $i of $n")
        end
        return "done:$n"
    end)

    session_id = "test-async-$(bytes2hex(rand(UInt8, 4)))"
    if Sys.iswindows()
        KaimonGate._serve(
            name = "test",
            session_id = session_id,
            force = true,
            tools = [tool],
            mode = :tcp,
            host = "127.0.0.1",
            port = 0,
        )
    else
        KaimonGate._serve(name = "test", session_id = session_id, force = true, tools = [tool])
    end
    sleep(0.15)

    ctx = ZMQ.Context()
    req = ZMQ.Socket(ctx, ZMQ.REQ)
    sub = ZMQ.Socket(ctx, ZMQ.SUB)

    if Sys.iswindows()
        rep_path = rstrip(ZMQ._get_last_endpoint(KaimonGate._GATE_SOCKET[]), '\0')
        pub_path = KaimonGate._STREAM_ENDPOINT[]
    else
        sock_dir = KaimonGate.sock_dir()
        rep_path = "ipc://" * joinpath(sock_dir, "$session_id.sock")
        pub_path = "ipc://" * joinpath(sock_dir, "$session_id-stream.sock")
    end
    req.rcvtimeo = 5_000
    sub.rcvtimeo = 5_000
    req.linger = 0
    sub.linger = 0
    ZMQ.connect(req, rep_path)
    ZMQ.connect(sub, pub_path)
    ZMQ.subscribe(sub, "")
    sleep(0.1)   # let SUB handshake before tool runs

    try
        rid = "int-$(bytes2hex(rand(UInt8, 4)))"
        ack = zmq_req(req, (
            type=:tool_call_async,
            name="counted_op",
            arguments=Dict{String,Any}("n" => 3),
            request_id=rid,
        ))
        @test ack.type == :accepted
        @test ack.request_id == rid

        progress_msgs = String[]
        result_str    = nothing

        for _ in 1:30
            raw = ZMQ.recv(sub)
            msg = Serialization.deserialize(IOBuffer(raw))
            get(msg, :request_id, "") == rid || continue
            ch   = string(get(msg, :channel, ""))
            data = string(get(msg, :data, ""))
            if ch == "tool_progress"
                push!(progress_msgs, data)
            elseif ch == "tool_complete"
                result_str = data
                break
            elseif ch == "tool_error"
                error("Unexpected tool_error: $data")
            end
        end

        @test progress_msgs == ["step 1 of 3", "step 2 of 3", "step 3 of 3"]
        @test result_str == "done:3"

    finally
        ZMQ.close(req)
        ZMQ.close(sub)
        ZMQ.close(ctx)
        KaimonGate.stop()
        sleep(0.1)
    end
end

# ── TCP ephemeral port + auth ─────────────────────────────────────────────────
# Adapted from Kaimon gate_async_tests "Gate TCP ephemeral port + auth"

@testset "TCP ephemeral port + auth" begin
    token = "test_token_$(bytes2hex(rand(UInt8, 8)))"
    session_id = "test-tcp-$(bytes2hex(rand(UInt8, 4)))"

    KaimonGate._AUTH_TOKEN[] = token
    KaimonGate._serve(
        name="test-tcp",
        session_id=session_id,
        force=true,
        mode=:tcp,
        host="127.0.0.1",
        port=0,
    )
    sleep(0.2)

    @test KaimonGate._RUNNING[]
    @test KaimonGate._MODE[] == :tcp
    sock = KaimonGate._GATE_SOCKET[]
    @test sock !== nothing
    rep_endpoint = rstrip(ZMQ._get_last_endpoint(sock), '\0')
    @test startswith(rep_endpoint, "tcp://")
    @test !isempty(KaimonGate._STREAM_ENDPOINT[])
    @test startswith(KaimonGate._STREAM_ENDPOINT[], "tcp://")

    ctx = ZMQ.Context()
    req = ZMQ.Socket(ctx, ZMQ.REQ)
    req.rcvtimeo = 3_000
    req.linger   = 0
    ZMQ.connect(req, rep_endpoint)

    try
        # No token → rejected
        resp = zmq_req(req, (type=:ping,))
        @test resp.type == :error

        # Fresh socket (REQ/REP state machine)
        ZMQ.close(req)
        req = ZMQ.Socket(ctx, ZMQ.REQ)
        req.rcvtimeo = 3_000
        req.linger   = 0
        ZMQ.connect(req, rep_endpoint)

        # Correct token → pong with stream_endpoint
        resp = zmq_req(req, (type=:ping, token=token))
        @test resp.type == :pong
        @test haskey(resp, :stream_endpoint)
        @test startswith(resp.stream_endpoint, "tcp://")

    finally
        ZMQ.close(req)
        ZMQ.close(ctx)
        KaimonGate.stop()
        sleep(0.1)
    end

    @test !KaimonGate._RUNNING[]
    @test isempty(KaimonGate._AUTH_TOKEN[])
end

# ── discoverable flag: serve without advertising in the discovery registry ─────
# `discoverable=false` serves a normal IPC gate but writes NO <session_id>.json metadata, so
# the TUI / MCP server won't list it (used by embedded/private gates like TachiRei atoms).

@testset "discoverable flag (metadata registration)" begin
    if Sys.iswindows()
        @test_skip true
    else
        sock_dir = KaimonGate.sock_dir()

        # discoverable=false → gate runs, but no metadata file is written
        sid_hidden  = "test-hidden-$(bytes2hex(rand(UInt8, 4)))"
        meta_hidden = joinpath(sock_dir, "$sid_hidden.json")
        rm(meta_hidden; force=true)
        KaimonGate._serve(name="test", session_id=sid_hidden, force=true, discoverable=false)
        sleep(0.15)
        try
            @test KaimonGate._RUNNING[]
            @test !isfile(meta_hidden)            # not advertised
        finally
            KaimonGate.stop(); sleep(0.1)
            rm(meta_hidden; force=true)
        end

        # default (discoverable=true) → metadata file IS written
        sid_seen  = "test-seen-$(bytes2hex(rand(UInt8, 4)))"
        meta_seen = joinpath(sock_dir, "$sid_seen.json")
        rm(meta_seen; force=true)
        KaimonGate._serve(name="test", session_id=sid_seen, force=true)
        sleep(0.15)
        try
            @test isfile(meta_seen)               # advertised by default
        finally
            KaimonGate.stop(); sleep(0.1)
            rm(meta_seen; force=true)
        end
    end
end

@testset "metadata JSON escapes backslashes" begin
    @test KaimonGate._json_value(raw"K:\Dev\proj") == "\"K:\\\\Dev\\\\proj\""
    mktempdir() do tmp
        old_xdg = get(ENV, "XDG_CACHE_HOME", nothing)
        ENV["XDG_CACHE_HOME"] = tmp
        try
            sid = "json-escape-test"
            meta_path = KaimonGate.write_metadata(
                sid, "test", "tcp://127.0.0.1:1", "tcp://127.0.0.1:2"; mode = :tcp,
            )
            content = read(meta_path, String)
            proj = dirname(Base.active_project())
            if occursin('\\', proj)
                @test occursin(replace(proj, "\\" => "\\\\"), content)
            end
            # Must be valid JSON (stdlib has no JSON dep; use a minimal round-trip check).
            m = match(r"\"project_path\": \"(.*)\"", content)
            @test m !== nothing
            @test m.captures[1] == replace(proj, "\\" => "\\\\")
        finally
            if old_xdg === nothing
                delete!(ENV, "XDG_CACHE_HOME")
            else
                ENV["XDG_CACHE_HOME"] = old_xdg
            end
        end
    end
end

end  # if !_RUNNING[]

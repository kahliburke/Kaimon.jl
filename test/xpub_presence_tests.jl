# Integration test for the XPUB stream socket + subscriber presence/count.
#
# The gate's stream socket is an XPUB (wire-compatible with SUB clients) owned by
# a single broadcaster task that interleaves publishing with recv'ing
# subscription events. With XPUB_VERBOSER it counts subscribers per topic and
# fires on_stream_subscribe/unsubscribe callbacks on 0->1 / 1->0 transitions.
#
# This runs a gate + raw SUB clients together in a multithreaded subprocess and
# asserts: per-topic counts track joins (incl. 2 subs on one topic), presence
# callbacks fire, a SUB-all client still receives published frames (wire-compat),
# and clean closes decrement counts + fire last-leave callbacks. Clean exit +
# the XPUB_OK marker means all assertions held.

using ReTest
using Kaimon

@testset "XPUB stream presence" begin
    proj = pkgdir(Kaimon)
    @test proj !== nothing

    script = raw"""
        using Kaimon
        const KG = Kaimon.KaimonGate
        const ZMQ = Kaimon.ZMQ

        # Short base dir: IPC socket paths must fit the ~104-char Unix sun_path limit.
        shortbase = Sys.iswindows() ? tempdir() : "/tmp"
        mktempdir(shortbase) do dir
            ENV["XDG_CACHE_HOME"] = dir
            joined = String[]; left = String[]
            KG.on_stream_subscribe(t -> push!(joined, t))
            KG.on_stream_unsubscribe(t -> push!(left, t))

            if Sys.iswindows()
                KG.serve(force = true, mode = :tcp, host = "127.0.0.1", port = 0)
            else
                KG.serve(force = true)
            end
            ep = KG._STREAM_ENDPOINT[]
            @assert !isempty(ep) "no stream endpoint"

            ctx = ZMQ.Context()
            mksub(topic) = begin
                s = ZMQ.Socket(ctx, ZMQ.SUB); ZMQ.subscribe(s, topic); ZMQ.connect(s, ep); s
            end
            wait_count(topic, want; secs = 5) = begin
                t0 = time()
                while time() - t0 < secs
                    KG.stream_subscriber_count(topic) == want && return true
                    sleep(0.05)
                end
                false
            end

            # 1. two SUBs on tui:a (VERBOSER counts both), one on tui:b
            a1 = mksub("tui:a"); a2 = mksub("tui:a"); b1 = mksub("tui:b")
            @assert wait_count("tui:a", 2) "tui:a=$(KG.stream_subscriber_count("tui:a"))"
            @assert wait_count("tui:b", 1) "tui:b=$(KG.stream_subscriber_count("tui:b"))"
            @assert KG.stream_subscribed("tui:a")
            @assert !KG.stream_subscribed("tui:nope")
            @assert "tui:a" in joined && "tui:b" in joined "joined=$joined"
            @assert Set(["tui:a","tui:b"]) ⊆ Set(KG.stream_topics())

            # 2. wire-compat: a SUB-all client still receives a publish [topic,payload]
            allsub = ZMQ.Socket(ctx, ZMQ.SUB); ZMQ.subscribe(allsub, ""); ZMQ.connect(allsub, ep)
            sleep(0.4)  # slow joiner
            KG.publish("tui:a", (hello = 1,))
            got = false; t0 = time()
            while time() - t0 < 5
                if (allsub.events & ZMQ.POLLIN) != 0
                    ZMQ.recv(allsub, Vector{UInt8}); got = true; break
                end
                sleep(0.05)
            end
            @assert got "SUB-all did not receive publish (wire-compat broken)"

            # 3. clean close -> counts drop, last-leave callback fires
            close(a1)
            @assert wait_count("tui:a", 1) "after 1 close tui:a=$(KG.stream_subscriber_count("tui:a"))"
            close(a2)
            @assert wait_count("tui:a", 0) "after 2 close tui:a=$(KG.stream_subscriber_count("tui:a"))"
            @assert "tui:a" in left "left=$left"

            close(b1); close(allsub); close(ctx)
            println("XPUB_OK")
            try; KG.stop(); catch; end
        end
    """
    path, io = mktemp()
    write(io, script)
    close(io)

    out = IOBuffer()
    cmd = pipeline(`$(Base.julia_cmd()) --project=$proj -t4 $path`; stdout = out, stderr = out)
    proc = run(cmd; wait = false)
    wait(proc)
    output = String(take!(out))

    if !success(proc) || !occursin("XPUB_OK", output)
        @info "xpub presence subprocess output" output
    end
    @test success(proc)
    @test occursin("XPUB_OK", output)
    rm(path; force = true)
end

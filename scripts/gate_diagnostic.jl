using ZMQ
using Serialization

"""
    gate_diagnostic(sock_file::String; timeout_ms=5000)

Diagnostic tool for testing Kaimon gate connectivity from a separate Julia process.
Runs a series of checks against a gate's ZMQ REP socket and reports results.

# Usage (from a Julia REPL that is NOT the gate):
    include("scripts/gate_diagnostic.jl")
    gate_diagnostic("path/to/session.sock")

Or auto-detect the only running session:
    gate_diagnostic()
"""
function gate_diagnostic(sock_file::String = ""; timeout_ms::Int = 5000)

    sock_dir = joinpath(
        Sys.iswindows() ?
        joinpath(
            get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local")),
            "Kaimon",
        ) : joinpath(homedir(), ".cache", "kaimon"),
        "sock",
    )

    # Auto-detect socket if not specified
    if isempty(sock_file)
        socks =
            filter(f -> endswith(f, ".sock") && !contains(f, "-stream"), readdir(sock_dir))
        if isempty(socks)
            println("ERROR: No .sock files found in $sock_dir")
            return
        elseif length(socks) == 1
            sock_file = joinpath(sock_dir, socks[1])
            println("Auto-detected socket: $sock_file")
        else
            println("Multiple sockets found — specify one:")
            for s in socks
                println("  $s")
            end
            return
        end
    elseif !isabspath(sock_file)
        sock_file = joinpath(sock_dir, sock_file)
    end

    endpoint = "ipc://$sock_file"

    println()
    println("="^60)
    println("Kaimon Gate Diagnostic")
    println("="^60)
    println("Socket: $sock_file")
    println("Exists: $(ispath(sock_file))")
    println()

    if !ispath(sock_file)
        println("ERROR: Socket file does not exist.")
        # Check for metadata
        meta_file = replace(sock_file, ".sock" => ".json")
        if isfile(meta_file)
            println("Metadata file exists: $meta_file")
            println("Contents:")
            println(read(meta_file, String))
        end
        return
    end

    # Check metadata file
    meta_file = replace(sock_file, ".sock" => ".json")
    if isfile(meta_file)
        println("--- Metadata ---")
        println(read(meta_file, String))
        println()
    end

    ctx = ZMQ.Context()

    function _send_recv(socket, request; label = "request")
        # Serialize and send
        io = IOBuffer()
        Serialization.serialize(io, request)
        ZMQ.send(socket, ZMQ.Message(take!(io)))
        println("  Sent $label, waiting for response...")

        # Receive with timeout
        raw = ZMQ.recv(socket)
        response = Serialization.deserialize(IOBuffer(raw))
        return response
    end

    # ── Test 1: Ping ──
    println("--- Test 1: Ping ---")
    try
        s = ZMQ.Socket(ctx, ZMQ.REQ)
        s.rcvtimeo = timeout_ms
        s.sndtimeo = timeout_ms
        ZMQ.connect(s, endpoint)

        response = _send_recv(s, (type = :ping,); label = "ping")
        println("  Response: $response")

        if response isa NamedTuple && get(response, :type, :unknown) == :pong
            println("  ✅ Ping OK")
            println("     PID: $(get(response, :pid, "?"))")
            println("     Julia: $(get(response, :julia_version, "?"))")
            println("     Project: $(get(response, :project_path, "?"))")
            uptime = get(response, :uptime, 0.0)
            mins = round(Int, uptime / 60)
            println("     Uptime: $(mins)m")
        else
            println("  ❌ Unexpected response type")
        end

        ZMQ.close(s)
    catch e
        if e isa ZMQ.TimeoutError
            println("  ❌ TIMEOUT — gate is not responding")
            println("     The message loop may have died or the socket is in a bad state.")
        else
            println("  ❌ Error: $(sprint(showerror, e))")
        end
        println()
        println("Skipping remaining tests (gate unresponsive).")
        ZMQ.close(ctx)
        return
    end
    println()

    # ── Test 2: Simple eval ──
    println("--- Test 2: Eval '1 + 1' ---")
    try
        s = ZMQ.Socket(ctx, ZMQ.REQ)
        s.rcvtimeo = timeout_ms
        s.sndtimeo = timeout_ms
        ZMQ.connect(s, endpoint)

        response = _send_recv(s, (type = :eval, code = "1 + 1"); label = "eval")

        if response isa NamedTuple
            vr = get(response, :value_repr, "")
            exc = get(response, :exception, nothing)
            so = get(response, :stdout, "")
            se = get(response, :stderr, "")

            if exc !== nothing
                println("  ❌ Exception: $exc")
            elseif vr == "2"
                println("  ✅ Eval OK — value_repr = \"$vr\"")
            else
                println("  ⚠️  Eval returned unexpected value_repr = $(repr(vr))")
            end
            !isempty(so) && println("     stdout: $(repr(so))")
            !isempty(se) && println("     stderr: $(repr(se))")
        else
            println("  ❌ Unexpected response: $response")
        end

        ZMQ.close(s)
    catch e
        if e isa ZMQ.TimeoutError
            println("  ❌ TIMEOUT — eval not completing")
            println(
                "     call_on_backend may be deadlocked, or redirect_stdout is hanging.",
            )
        else
            println("  ❌ Error: $(sprint(showerror, e))")
        end
    end
    println()

    # ── Test 3: Eval with stdout ──
    println("--- Test 3: Eval with stdout (println) ---")
    try
        s = ZMQ.Socket(ctx, ZMQ.REQ)
        s.rcvtimeo = timeout_ms
        s.sndtimeo = timeout_ms
        ZMQ.connect(s, endpoint)

        response = _send_recv(
            s,
            (type = :eval, code = "println(\"gate_diag_test\"); 42");
            label = "eval+println",
        )

        if response isa NamedTuple
            vr = get(response, :value_repr, "")
            exc = get(response, :exception, nothing)
            so = get(response, :stdout, "")

            if exc !== nothing
                println("  ❌ Exception: $exc")
            elseif contains(so, "gate_diag_test") && vr == "42"
                println("  ✅ stdout capture OK")
                println("     stdout: $(repr(so))")
                println("     value_repr: $(repr(vr))")
            elseif vr == "42" && !contains(so, "gate_diag_test")
                println("  ⚠️  Eval OK but stdout NOT captured")
                println("     stdout: $(repr(so))")
                println("     redirect_stdout may not be working on this platform.")
            else
                println("  ⚠️  Unexpected result")
                println("     value_repr: $(repr(vr))")
                println("     stdout: $(repr(so))")
            end
        else
            println("  ❌ Unexpected response: $response")
        end

        ZMQ.close(s)
    catch e
        if e isa ZMQ.TimeoutError
            println("  ❌ TIMEOUT")
        else
            println("  ❌ Error: $(sprint(showerror, e))")
        end
    end
    println()

    # ── Test 4: Get options ──
    println("--- Test 4: Get gate options ---")
    try
        s = ZMQ.Socket(ctx, ZMQ.REQ)
        s.rcvtimeo = timeout_ms
        s.sndtimeo = timeout_ms
        ZMQ.connect(s, endpoint)

        response = _send_recv(s, (type = :get_options,); label = "get_options")
        println("  Response: $response")
        println("  ✅ Options retrieved")

        ZMQ.close(s)
    catch e
        if e isa ZMQ.TimeoutError
            println("  ❌ TIMEOUT")
        else
            println("  ❌ Error: $(sprint(showerror, e))")
        end
    end
    println()

    println("="^60)
    println("Diagnostic complete.")
    println("="^60)

    ZMQ.close(ctx)
    return nothing
end

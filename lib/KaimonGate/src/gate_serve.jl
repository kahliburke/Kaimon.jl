# ─────────────────────────────────────────────────────────────────────────────
# KaimonGate · serve / stop / restart lifecycle  (split from gate.jl; part of the KaimonGate module)
# ─────────────────────────────────────────────────────────────────────────────

# ── Public API ────────────────────────────────────────────────────────────────

"""
    serve(; session_id=nothing, force=false, tools=GateTool[], namespace="", allow_mirror=true, allow_restart=true)

Start the eval gate. Binds a ZMQ REP socket on an IPC endpoint and
listens for eval requests from the Kaimon TUI server.

Non-blocking — returns immediately. The gate runs in a background task.
The session name is derived automatically from the active project path.

Skips registration for non-interactive processes (no TTY). Use `force=true`
to override the TTY check.

# Arguments
- `session_id::Union{String,Nothing}`: Reuse a session ID (e.g. after exec restart)
- `force::Bool`: Skip the TTY gate (for non-interactive processes that want a gate)
- `tools::Vector{GateTool}`: Session-scoped tools to expose via MCP
- `namespace::String`: Stable prefix for tool names. Auto-derived from project basename
  if empty. Use explicit namespaces for multi-instance workflows:
  ```julia
  serve(tools=tools, namespace="todo_dev")    # branch A
  serve(tools=tools, namespace="todo_main")   # branch B
  ```
- `mode::Symbol`: Transport mode — `:ipc` (default, local Unix socket) or
  `:tcp` (network-accessible, for remote debugging).
- `host::String`: Bind address for TCP mode (default `"127.0.0.1"`, localhost only).
  Use `"0.0.0.0"` to accept connections from remote machines (no auth — use with care).
- `port::Int`: Port for TCP mode (default `0` = ephemeral, ZMQ picks a free port).
  Both REP and PUB sockets support this. Use a fixed port for predictable endpoints.
- `discoverable::Bool`: Whether to advertise this gate in the local discovery registry
  (default `true`). When `false`, the gate serves normally but writes no metadata file, so
  the Kaimon TUI / MCP server won't list it or import its tools — for embedded/private gates
  that clients reach via explicit endpoints (e.g. TachiRei atoms, reached on demand by id).
  IPC only; TCP gates are never file-discovered (they're connected via `connect_tcp!`).

# Example
```julia
using KaimonGate
KaimonGate.serve()

# With custom tools
KaimonGate.serve(tools=[GateTool("send_key", my_key_handler)])

# TCP mode for remote debugging (e.g. from a model server)
KaimonGate.serve(mode=:tcp, port=9876, force=true)
```

# Environment variables
These override the keyword defaults when set:
- `KAIMON_GATE_MODE`: `"ipc"` or `"tcp"` (default: `"ipc"`)
- `KAIMON_GATE_HOST`: Bind address for TCP (default: `"127.0.0.1"`)
- `KAIMON_GATE_PORT`: Port for TCP (default: `"0"` = ephemeral)
- `KAIMON_GATE_STREAM_PORT`: PUB stream port for TCP (default: `"0"` = ephemeral).
  Use a fixed port when tunneling so the client can connect to a known port.
"""
function serve(;
    session_id::Union{String,Nothing} = nothing,
    force::Union{Bool,Nothing} = nothing,
    tools::Vector{GateTool} = GateTool[],
    namespace::String = "",
    allow_mirror::Bool = true,
    allow_restart::Bool = true,
    spawned_by::String = "user",
    on_shutdown::Any = nothing,
    infiltrator::Bool = true,
    mode::Union{Symbol,Nothing} = nothing,
    host::Union{String,Nothing} = nothing,
    port::Union{Int,Nothing} = nothing,
    stream_port::Union{Int,Nothing} = nothing,
    curve::Union{Bool,Nothing} = nothing,
    server_secret::Union{String,Nothing} = nothing,
    allow_any::Union{Bool,Nothing} = nothing,
    allowed_clients::Union{Vector{String},Nothing} = nothing,
    discoverable::Bool = true,
)
    # Resolve defaults: explicit kwargs > env vars > kaimon.toml [gate] > defaults
    toml = _load_gate_config()

    if mode === nothing
        env_mode = get(ENV, "KAIMON_GATE_MODE", "")
        has_env_port = haskey(ENV, "KAIMON_GATE_PORT") || haskey(ENV, "KAIMON_GATE_STREAM_PORT")
        toml_mode = get(toml, "mode", "")
        has_toml_port = haskey(toml, "port") || haskey(toml, "stream_port")
        mode = if !isempty(env_mode)
            Symbol(env_mode)
        elseif has_env_port
            :tcp
        elseif toml_mode == "tcp" || has_toml_port
            :tcp
        else
            :ipc
        end
    end
    if host === nothing
        env_host = get(ENV, "KAIMON_GATE_HOST", "")
        host = !isempty(env_host) ? env_host :
            get(toml, "host", "127.0.0.1")
    end
    if port === nothing
        env_port = get(ENV, "KAIMON_GATE_PORT", "")
        port = !isempty(env_port) ? parse(Int, env_port) :
            Int(get(toml, "port", 0))
    end
    if stream_port === nothing
        env_sp = get(ENV, "KAIMON_GATE_STREAM_PORT", "")
        stream_port = !isempty(env_sp) ? parse(Int, env_sp) :
            Int(get(toml, "stream_port", 0))
    end
    if force === nothing
        force = Bool(get(toml, "force", false))
    end
    # CURVE (opt-in TCP encryption + auth). server_secret defaults to nothing here
    # and is resolved (env > persisted keypair) inside _resolve_server_keypair.
    _truthy(s) = lowercase(strip(s)) in ("1", "true", "yes", "on")
    if curve === nothing
        env_curve = get(ENV, "KAIMON_GATE_CURVE", "")
        curve = !isempty(env_curve) ? _truthy(env_curve) : Bool(get(toml, "curve", false))
    end
    if allow_any === nothing
        env_aa = get(ENV, "KAIMON_GATE_CURVE_ALLOW_ANY", "")
        allow_any = !isempty(env_aa) ? _truthy(env_aa) : Bool(get(toml, "curve_allow_any", false))
    end
    if allowed_clients === nothing
        env_allow = get(ENV, "KAIMON_GATE_CURVE_ALLOW", "")
        allowed_clients = isempty(env_allow) ? String[] :
            String[String(strip(x)) for x in split(env_allow, ",") if !isempty(strip(x))]
    end

    mode in (:ipc, :tcp) || throw(ArgumentError("mode must be :ipc or :tcp, got :$mode"))
    _serve(;
        name = basename(dirname(something(Base.active_project(), "julia"))),
        session_id,
        force,
        tools,
        namespace,
        allow_mirror,
        allow_restart,
        spawned_by,
        on_shutdown,
        infiltrator,
        mode,
        host,
        port,
        stream_port,
        curve,
        server_secret,
        allow_any,
        allowed_clients,
        discoverable,
    )
end

function _serve(;
    name::String,
    session_id::Union{String,Nothing},
    force::Bool = false,
    tools::Vector{GateTool} = GateTool[],
    namespace::String = "",
    allow_mirror::Bool = true,
    allow_restart::Bool = true,
    spawned_by::String = "user",
    on_shutdown::Any = nothing,
    infiltrator::Bool = true,
    mode::Symbol = :ipc,
    host::String = "127.0.0.1",
    port::Int = 9876,
    stream_port::Int = 0,
    curve::Bool = false,
    server_secret::Union{String,Nothing} = nothing,
    allow_any::Bool = false,
    allowed_clients::Vector{String} = String[],
    discoverable::Bool = true,
)
    # Capture original argv for restart replay (once, on first call)
    _capture_original_argv()

    # Interactive gate: skip scripts, -e commands, precompilation, workers, etc.
    # TCP mode always forces — it's designed for non-interactive processes (model servers).
    if !force && mode != :tcp && !isinteractive()
        @debug "Skipping gate: non-interactive session"
        return nothing
    end

    # A gate the caller asked to be LOCAL (IPC). On Windows we bind it over TCP (no IPC
    # transport), but it stays a local, tokenless, file-discoverable gate — as opposed to
    # an EXPLICIT `mode=:tcp`, which is a remote gate connected via `connect_tcp!` and not
    # file-advertised. Captured before the coercion below so the metadata gate can tell
    # the two apart.
    local_gate = (mode === :ipc)

    # ZMQ has no IPC transport on Windows (`bind` throws "Protocol not supported"). Coerce
    # IPC → TCP for the actual bind, AFTER the interactive-skip check above so skip
    # semantics are unchanged. The ephemeral TCP port is recorded in the session metadata,
    # so discovery/reconnect works the same as an IPC socket path does elsewhere.
    # `_NO_IPC_TRANSPORT` is the platform flag (overridable in tests).
    if _NO_IPC_TRANSPORT[] && mode === :ipc
        @debug "KaimonGate: IPC unsupported on Windows — binding TCP instead"
        mode = :tcp
    end
    # Remember whether this TCP gate is a coerced-local one (vs an explicit remote gate),
    # so restart can reproduce the coercion instead of pinning it to mode=:tcp (which would
    # drop discovery metadata and orphan the restarted session).
    _LOCAL_TCP_COERCED[] = local_gate && mode === :tcp

    # Restart gate: if KAIMON_RESTART_SESSION is set the current process was
    # launched by _exec_restart.  Any serve() call — whether from startup.jl,
    # app code (force=true), or our injected -e fallback — picks up the
    # session_id so the TUI can reconnect to the same session.
    if session_id === nothing
        restart_sid = get(ENV, "KAIMON_RESTART_SESSION", "")
        if !isempty(restart_sid)
            session_id = pop!(ENV, "KAIMON_RESTART_SESSION")
        end
    end

    # Auto-derive namespace from project basename if not specified
    if isempty(namespace)
        project = something(Base.active_project(), "julia")
        namespace = lowercase(replace(basename(dirname(project)), r"[^a-zA-Z0-9]" => "_"))
    end

    if _RUNNING[]
        if session_id !== nothing && session_id != _SESSION_ID[]
            # Restart with a specific session_id (e.g. _exec_restart) —
            # stop the gate started by startup.jl and continue below
            # to rebind with the requested session_id.
            old_task = _GATE_TASK[]
            _cleanup()
            # Wait for old message loop task to finish so its `finally`
            # block doesn't race with the new gate we're about to create.
            if old_task !== nothing && !istaskdone(old_task)
                try
                    wait(old_task)
                catch
                end
            end
        elseif !isempty(tools)
            # Gate already running — replace tools; the TUI health checker
            # picks up changes via pong and sends tools/list_changed.
            _SESSION_TOOLS[] = tools
            _SESSION_NAMESPACE[] = namespace
            if !allow_mirror
                _ALLOW_MIRROR[] = false
                _MIRROR_REPL[] = false
            end
            @info "Registered $(length(tools)) tool(s) on running gate (session=$(_SESSION_ID[]))"
            return _SESSION_ID[]
        else
            # Same session already running (e.g. startup.jl created the gate,
            # then our injected -e fallback fires).  Update mutable options so
            # allow_mirror / allow_restart from the original session are
            # restored; namespace is auto-derived so it will match already.
            _ALLOW_MIRROR[] = allow_mirror
            _ALLOW_RESTART[] = allow_restart
            return _SESSION_ID[]
        end
    end

    # Store session tools and namespace
    _SESSION_TOOLS[] = tools
    _SESSION_NAMESPACE[] = namespace
    _ALLOW_MIRROR[] = allow_mirror
    _ALLOW_RESTART[] = allow_restart
    _ON_SHUTDOWN[] = on_shutdown

    # Ensure socket directory exists
    sock_dir()  # ensure it exists (mkpath is inside)

    # Generate or reuse session ID
    sid = session_id !== nothing ? session_id : string(Base.UUID(rand(UInt128)))
    _SESSION_ID[] = sid
    _START_TIME[] = time()
    _MIRROR_REPL[] = if allow_mirror
        try
            _MIRROR_PREF_PROVIDER[]()
        catch
            false
        end
    else
        false
    end

    # Create ZMQ context and sockets. The request socket is a ROUTER (protocol
    # v2): a single client DEALER multiplexes concurrent requests onto it, demuxed
    # by correlation id. Replaces the old REP, which forced strict request/reply
    # alternation and drove per-request ephemeral REQ churn on the client.
    ctx = Context()
    # libzmq background I/O threads (default 1) — set before any socket is created.
    # More can raise throughput when one I/O thread saturates (KAIMON_ZMQ_IO_THREADS).
    let n = tryparse(Int, get(ENV, "KAIMON_ZMQ_IO_THREADS", ""))
        n === nothing || n < 1 || (try; ctx.io_threads = n; catch; end)
    end
    socket = _zmq_socket(ctx, ROUTER)
    _GATE_CONTEXT[] = ctx
    _GATE_SOCKET[] = socket
    _MODE[] = mode

    # Set auth token for TCP mode.
    # Priority: KAIMON_GATE_TOKEN env var > host-provided token > none.
    # Standalone there's no host token, so the gate is open unless the env var is
    # set; full Kaimon injects a token derived from its security config via
    # set_auth_token_provider!.
    if mode == :tcp
        env_token = get(ENV, "KAIMON_GATE_TOKEN", "")
        if !isempty(env_token)
            _AUTH_TOKEN[] = env_token
        else
            # Host-provided token (Kaimon derives it from its security config).
            # Standalone the default provider returns "" — no auth, same as :lax.
            try
                tok = Base.invokelatest(_AUTH_TOKEN_PROVIDER[])
                isempty(tok) || (_AUTH_TOKEN[] = tok)
            catch
                # No provider/config — no auth (same as lax)
            end
        end
    end

    # Initial receive timeout so the owner loop cycles back to drain _GATE_OUTBOX
    # (worker replies) and re-check _RUNNING. message_loop then adapts this per
    # iteration (short while replies are in flight, long when idle) — see
    # _GATE_RCVTIMEO_BUSY/_IDLE; the flat 200ms here was the input drag-lag.
    # linger=0: close() returns immediately without blocking to drain.
    socket.rcvtimeo = _GATE_RCVTIMEO_IDLE[]
    socket.linger = 0

    # CURVE (opt-in, TCP only): make the REP socket a CURVE server. Unless
    # allow_any, also start a ZAP handler (one per context, covers PUB too) and
    # set ZAP_DOMAIN so libzmq enforces the client allow-list (fail-closed: an
    # empty authorized_clients list rejects everyone). Apply before bind.
    if mode == :tcp && curve
        spub, ssec = _resolve_server_keypair(server_secret)
        _CURVE_SERVER_SECRET[] = ssec
        _CURVE_SERVER_PUBLIC[] = spub
        _CURVE_ENABLED[] = true
        _CURVE_ALLOW_ANY[] = allow_any
        for ck in allowed_clients
            isempty(ck) || authorize_client!(ck)
        end
        allow_any || _start_zap_handler!(ctx; allow_any = false)
        make_curve_server!(socket, ssec)
        allow_any || _setsockopt_str(socket, _ZMQ_ZAP_DOMAIN, _ZAP_DOMAIN)
    end

    # Bind endpoint — IPC (local socket file) or TCP (network port)
    # TCP mode supports port=0 for ephemeral port assignment (ZMQ picks a free port).
    if mode == :tcp
        bind(socket, "tcp://$(host):$(port)")
        endpoint = rstrip(ZMQ._get_last_endpoint(socket), '\0')
        # Store resolved TCP settings for restart replay
        _TCP_HOST[] = host
        m = match(r":(\d+)$", endpoint)
        _TCP_PORT[] = m !== nothing ? parse(Int, m.captures[1]) : port
    else
        sock_path = joinpath(sock_dir(),"$(sid).sock")
        endpoint = "ipc://$(sock_path)"
        bind(socket, endpoint)
    end

    # Create XPUB socket for streaming stdout/stderr to TUI. XPUB is wire-
    # compatible with SUB clients but also delivers subscription events, which the
    # broadcaster turns into per-topic presence (see _stream_broadcaster).
    # sndhwm=0: unlimited send buffer — never drop messages under load.
    # linger=0: close() returns immediately.
    # rcvtimeo=0: non-blocking subscription recv (the owner polls events first).
    pub_socket = _zmq_socket(ctx, XPUB)
    pub_socket.sndhwm = 0
    pub_socket.linger = 0
    pub_socket.rcvtimeo = 0
    # XPUB_VERBOSER: deliver EVERY subscribe/unsubscribe (not just 0->1/1->0) so
    # we can count subscribers per topic.
    _setsockopt_int(pub_socket, _ZMQ_XPUB_VERBOSER, 1)
    # TCP keepalive: detect dead viewers so libzmq emits their unsubscribe and the
    # count self-corrects on ungraceful disconnects (IPC detects peer-close already).
    if mode == :tcp
        _setsockopt_int(pub_socket, _ZMQ_TCP_KEEPALIVE, 1)
        _setsockopt_int(pub_socket, _ZMQ_TCP_KEEPALIVE_IDLE, 30)
        _setsockopt_int(pub_socket, _ZMQ_TCP_KEEPALIVE_INTVL, 5)
        _setsockopt_int(pub_socket, _ZMQ_TCP_KEEPALIVE_CNT, 3)
    end
    # CURVE: same server treatment as the REP socket (ZAP handler already running).
    if mode == :tcp && curve
        make_curve_server!(pub_socket, _CURVE_SERVER_SECRET[])
        _CURVE_ALLOW_ANY[] || _setsockopt_str(pub_socket, _ZMQ_ZAP_DOMAIN, _ZAP_DOMAIN)
    end
    if mode == :tcp
        bind(pub_socket, "tcp://$(host):$(stream_port)")
        stream_endpoint = rstrip(ZMQ._get_last_endpoint(pub_socket), '\0')
        m = match(r":(\d+)$", stream_endpoint)
        _TCP_STREAM_PORT[] = m !== nothing ? parse(Int, m.captures[1]) : stream_port
    else
        stream_endpoint = "ipc://$(joinpath(sock_dir(),"$(sid)-stream.sock"))"
        bind(pub_socket, stream_endpoint)
    end
    _STREAM_SOCKET[] = pub_socket
    _STREAM_ENDPOINT[] = stream_endpoint

    # Write metadata file for session discovery. Written for every LOCAL gate: real IPC
    # gates, and Windows gates that were coerced IPC → TCP (`local_gate`) — the server
    # finds those by file and connects to the recorded `tcp://127.0.0.1:<port>` exactly as
    # it would an IPC socket path (see `discover_sessions`). Without this a Windows gate
    # advertises nothing and is never discovered — the extension/session startup then times
    # out. An EXPLICIT `mode=:tcp` gate is remote (connected via connect_tcp!) and writes no
    # file. `discoverable=false` serves the gate but keeps it out of the registry entirely
    # (embedded/private gates reached via explicit endpoints).
    if discoverable && (mode != :tcp || local_gate)
        mpath = write_metadata(sid, name, endpoint, stream_endpoint; spawned_by, mode)
        # Diagnostic (visible in an extension's own log): confirms serve() reached the
        # advertise step and WHERE it wrote — so a "never connected" failure can be split
        # into "gate never advertised" vs "advertised but the server didn't discover it".
        @info "Kaimon gate advertised for discovery at $endpoint (mode=$mode, metadata: $mpath)"
    end

    # Register cleanup
    atexit(() -> stop())

    # Start message loop on an interactive thread so it stays scheduled even
    # when the main thread is busy executing REPL code.
    # Async handlers (eval_async, tool_call_async) use Threads.@spawn to run
    # on the default thread pool, keeping this interactive thread free to
    # answer pings during CPU-intensive operations.
    _RUNNING[] = true
    # Broadcaster owns the XPUB stream socket (send + subscription recv). Runs on
    # :interactive so it stays scheduled alongside the message loop.
    _STREAM_TASK[] = Threads.@spawn :interactive begin
        try
            _stream_broadcaster(pub_socket)
        catch e
            @debug "Stream broadcaster exited" exception = e
        end
    end
    local this_task
    this_task = _GATE_TASK[] = Threads.@spawn :interactive begin
        try
            message_loop(socket)
        catch e
            @debug "Gate task exited" exception = e
        finally
            if _SHUTTING_DOWN[]
                # Remote shutdown: run optional cleanup hook, then exit
                _SHUTTING_DOWN[] = false
                hook = _ON_SHUTDOWN[]
                if hook !== nothing
                    try
                        ch = Channel{Nothing}(1)
                        @async begin
                            try
                                Base.invokelatest(hook)
                            catch e
                                @debug "on_shutdown hook error" exception = e
                            finally
                                put!(ch, nothing)
                            end
                        end
                        # Wait up to 5s for the hook to complete
                        timer = Timer(5.0)
                        @async begin
                            wait(timer)
                            isready(ch) || put!(ch, nothing)
                        end
                        take!(ch)
                        close(timer)
                    catch
                    end
                end
                _cleanup()
                exit(0)
            end
            # Otherwise don't call _cleanup() here — stop() owns cleanup
            # via atexit. With Threads.@spawn :interactive, this finally
            # block can race with stop() during Julia shutdown, causing
            # double-cleanup of ZMQ resources and intermittent segfaults.
        end
    end

    _start_revise_watcher()

    # Install Infiltrator hook if available — makes @infiltrate route through
    # the gate's breakpoint protocol instead of opening an interactive prompt.
    if infiltrator
        try
            _install_infiltrator_hook!()
        catch
            # Infiltrator not loaded yet — will be picked up by package callback below.
        end
        # Register a package-load callback so the hook installs as soon as Infiltrator
        # gets loaded (e.g. via `using GateToolTest` from the REPL).
        push!(Base.package_callbacks, function (pkgid)
            _RUNNING[] || return
            _INFILTRATOR_HOOKED[] && return
            _INFILTRATOR_DISABLED[] && return
            pkgid.name == "Infiltrator" || return
            try
                _install_infiltrator_hook!()
            catch
            end
        end)
    end

    # Override Profile peek report to write to a file instead of stderr.
    # When SIGINFO/SIGUSR1 fires, the C runtime prints a small message to
    # stderr, but the bulk profile output goes through this Julia function.
    # Writing to a file avoids filling the PTY buffer and deadlocking.
    _install_peek_report_override(sid)

    emoticon = try
        _PERSONALITY_PROVIDER[]()
    catch
        "⚡"
    end
    print("  $emoticon ")
    printstyled("Kaimon gate "; color = :green, bold = true)
    printstyled("connected"; color = :green)
    printstyled(" ($name)\n"; color = :light_black)
    let (kg_ver, kg_dir) = _build_info()
        printstyled("  KaimonGate v$kg_ver"; color = :light_black)
        kg_dir === nothing || printstyled(" — $kg_dir"; color = :light_black)
        # Under the full Kaimon CLI, the host injects its own version via the
        # provider hook. Surface it only when it differs from KaimonGate's own
        # (standalone they're the same, so nothing extra is shown).
        host_ver = try
            string(Base.invokelatest(_VERSION_PROVIDER[]))
        catch
            kg_ver
        end
        host_ver == kg_ver || printstyled(" (Kaimon v$host_ver)"; color = :light_black)
        print("\n")
    end
    if mode == :tcp
        printstyled("  TCP mode: "; color = :light_black)
        printstyled("$endpoint"; color = :cyan)
        printstyled(" (PUB: $stream_endpoint)\n"; color = :light_black)
        if !isempty(_AUTH_TOKEN[])
            printstyled("  Auth token: "; color = :light_black)
            printstyled("$(_AUTH_TOKEN[])\n"; color = :yellow)
        else
            printstyled("  Auth: "; color = :light_black)
            printstyled("none (lax mode)\n"; color = :yellow)
        end
        if _CURVE_ENABLED[]
            printstyled("  🔒 CURVE: "; color = :light_black)
            printstyled("on"; color = :green)
            printstyled(_CURVE_ALLOW_ANY[] ? " (pin-only)" : " (allow-list)";
                        color = :light_black)
            printstyled("\n  Server key: "; color = :light_black)
            printstyled("$(_CURVE_SERVER_PUBLIC[])\n"; color = :cyan)
        end
    end
    if _MIRROR_REPL[]
        printstyled("  host REPL mirroring enabled\n"; color = :light_black)
    end

    return sid
end

"""
    stop()

Stop the eval gate, clean up socket and metadata files.
"""
function stop()
    if !_RUNNING[]
        return
    end

    _RUNNING[] = false

    # Wait for task to finish
    task = _GATE_TASK[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end

    _cleanup()
    # Restore Infiltrator's normal prompt so @infiltrate works locally after
    # stop() instead of routing to the now-dead gate and hanging (#34).
    try
        uninstall_infiltrator_hook!()
    catch
    end
    printstyled("  Kaimon gate "; color = :yellow, bold = true)
    printstyled("disconnected\n"; color = :yellow)
end

"""
    restart()

Restart the Julia session, preserving the Kaimon session ID so the TUI
reconnects automatically.  Equivalent to what the agent's `manage_repl` tool
does, but callable directly from your REPL.

Uses `execvp` to replace the current process image — same PID, fresh Julia
state.  Your startup.jl runs again and `KaimonGate.serve()` reconnects with the
same session key.
"""
function restart()
    _RUNNING[] || error("Gate is not running")
    _ALLOW_RESTART[] || error("Restart is disabled for this session (allow_restart=false)")
    sid  = _SESSION_ID[]
    name = basename(dirname(something(Base.active_project(), "julia")))
    proj = dirname(something(Base.active_project(), "."))

    # Tell the message-loop's finally block to skip cleanup — we handle it here.
    _RESTARTING[] = true
    _RUNNING[] = false

    # Wait for the message-loop task to exit before tearing down sockets,
    # same as stop() does.
    task = _GATE_TASK[]
    if task !== nothing && !istaskdone(task)
        try
            wait(task)
        catch
        end
    end

    _RESTARTING[] = false
    # Best-effort cleanup — never let a teardown hiccup abort the restart.
    try
        _cleanup()
    catch e
        @warn "Restart cleanup failed; proceeding to exec anyway" exception = (e, catch_backtrace())
    end
    _exec_restart(name, sid, proj)
end

function _cleanup()
    # Restore the original stdout/stderr (uninstall the capture mux) so a stopped
    # gate leaves the process's streams as it found them.
    _restore_capture!()
    # Stop Revise watcher
    watcher = _REVISE_WATCHER_TASK[]
    if watcher !== nothing && !istaskdone(watcher)
        try
            # Wake the blocked wait so the task can exit
            if isdefined(Main, :Revise)
                Base.notify(Main.Revise.revision_event)
            end
        catch
        end
    end
    _REVISE_WATCHER_TASK[] = nothing

    # Stop the stream broadcaster and wait for it to release the XPUB BEFORE any
    # socket close below — a concurrent close+recv corrupts the heap (#51 class).
    # It exits once _RUNNING is false (set by every caller before _cleanup).
    stask = _STREAM_TASK[]
    if stask !== nothing && !istaskdone(stask)
        # The broadcaster now BLOCKS on the outbox (event-driven, no spin), so a
        # bare _RUNNING=false won't wake it — nudge with the wake sentinel so its
        # `take!` returns and it observes the flag (else we'd wait a full sub-poll
        # interval for the liveness tick).
        try; put!(_STREAM_OUTBOX, _STREAM_WAKE); catch; end
        try; wait(stask); catch; end
    end
    _STREAM_TASK[] = nothing

    # IPC mode: don't explicitly close ZMQ sockets/context — GC finalizers handle
    # it. Explicit close during atexit was causing intermittent segfaults in LLVM's
    # JIT compiler on Julia 1.12.5.
    # TCP mode: must close explicitly so the port is released immediately. Without
    # this, restarting a TCP gate on the same port fails until GC runs. This is safe
    # because TCP stop is user-initiated (not atexit).
    if _MODE[] == :tcp
        for sock in (_GATE_SOCKET, _STREAM_SOCKET, _SERVICE_SOCKET, _ZAP_SOCKET)
            s = sock[]
            if s !== nothing
                try; close(s); catch; end
            end
        end
        ctx = _GATE_CONTEXT[]
        if ctx !== nothing
            try; close(ctx); catch; end
        end
    end
    # Drain any undelivered worker replies and reset the worker counter so a
    # restart (same process, fresh serve()) starts with an empty channel.
    while isready(_GATE_OUTBOX)
        try; take!(_GATE_OUTBOX); catch; break; end
    end
    Threads.atomic_xchg!(_GATE_INFLIGHT, 0)

    # Drain leftover stream publishes and clear presence state (the broadcaster
    # has already stopped above) so a same-process restart starts clean.
    while isready(_STREAM_OUTBOX)
        try; take!(_STREAM_OUTBOX); catch; break; end
    end
    lock(_STREAM_SUBS_LOCK) do
        empty!(_STREAM_SUBS)
        empty!(_ON_STREAM_SUBSCRIBE)
        empty!(_ON_STREAM_UNSUBSCRIBE)
    end

    _ZAP_SOCKET[] = nothing
    _ZAP_TASK[] = nothing
    _CURVE_ENABLED[] = false
    _CURVE_ALLOW_ANY[] = false
    _CURVE_SERVER_SECRET[] = ""
    _CURVE_SERVER_PUBLIC[] = ""
    _GATE_SOCKET[] = nothing
    _STREAM_SOCKET[] = nothing
    _STREAM_ENDPOINT[] = ""
    _AUTH_TOKEN[] = ""
    _PING_COUNT[] = 0
    _MSG_COUNT[] = 0
    _LAST_PING_TIME[] = 0.0
    _SERVICE_SOCKET[] = nothing
    _GATE_CONTEXT[] = nothing

    # Remove files
    cleanup_files(_SESSION_ID[])

    _GATE_TASK[] = nothing
    _RUNNING[] = false
    _RESTARTING[] = false
    _SHUTTING_DOWN[] = false
    _MIRROR_REPL[] = false
    _ALLOW_MIRROR[] = true
    _ALLOW_RESTART[] = true
    _SESSION_TOOLS[] = GateTool[]
    _SESSION_NAMESPACE[] = ""
    _MODE[] = :ipc
    _LOCAL_TCP_COERCED[] = false
    _ON_SHUTDOWN[] = nothing
end

"""
    status()

Print current gate status.
"""
function status()
    if _RUNNING[]
        uptime = time() - _START_TIME[]
        mins = round(Int, uptime / 60)
        sock = _GATE_SOCKET[]
        rep_ep = sock !== nothing ? rstrip(ZMQ._get_last_endpoint(sock), '\0') : "unknown"
        println("Gate: running")
        println("  Session:   $(_SESSION_ID[])")
        println("  Namespace: $(_SESSION_NAMESPACE[])")
        println("  Uptime:    $(mins)m")
        println("  PID:       $(getpid())")
        println("  ROUTER:    $rep_ep")
        println("  PUB:       $(_STREAM_ENDPOINT[])")
        println("  Mirror:    $(_MIRROR_REPL[])")
        println("  Tools:     $(length(_SESSION_TOOLS[]))")
        println("  Pings:     $(_PING_COUNT[])$(  _LAST_PING_TIME[] > 0 ? " (last $(round(Int, time() - _LAST_PING_TIME[]))s ago)" : "")")
        println("  Messages:  $(_MSG_COUNT[])")
        if _MODE[] == :tcp
            auth = isempty(_AUTH_TOKEN[]) ? "none (lax)" : "token"
            println("  Auth:      $auth")
        end
    else
        println("Gate: not running")
    end
end

"""
    KaimonGate.progress(message::String)

Send a progress update from a long-running GateTool handler. The message is
streamed to the MCP client as an SSE progress notification.

Only works when called from within a GateTool handler invoked via the async
path. No-op otherwise.
"""
# Track last stderr output length for \r overwrite
const _STDERR_LAST_LEN = Ref{Int}(0)
const _STDERR_LAST_KIND = Ref{Symbol}(:none)  # :progress, :stash, :none

function _stderr_overwrite!(line::String, kind::Symbol)
    # If same kind as last output, overwrite with \r; otherwise newline first
    if _STDERR_LAST_KIND[] == kind && _STDERR_LAST_LEN[] > 0
        print(stderr, "\r")
        # Clear previous line if new one is shorter
        if length(line) < _STDERR_LAST_LEN[]
            print(stderr, " " ^ _STDERR_LAST_LEN[])
            print(stderr, "\r")
        end
    elseif _STDERR_LAST_KIND[] != :none && _STDERR_LAST_LEN[] > 0
        println(stderr)  # newline to preserve previous different-kind output
    end
    print(stderr, line)
    flush(stderr)
    _STDERR_LAST_LEN[] = length(line)
    _STDERR_LAST_KIND[] = kind
end

"""Finish the current stderr overwrite line (newline + reset)."""
function _stderr_finish!()
    if _STDERR_LAST_LEN[] > 0
        println(stderr)
        _STDERR_LAST_LEN[] = 0
        _STDERR_LAST_KIND[] = :none
    end
end

"""
    progress(message::String)

Stream a real-time progress update to the agent from inside a running eval or
`GateTool` handler. The message is delivered as an MCP `notifications/progress`
event (and echoed in the host REPL), which also keeps long-running HTTP requests
from timing out.

Only has an effect while running inside a gate request (it keys off the current
request via task-local storage); outside one it's a no-op.

```julia
function analyze(passes::Int)
    for i in 1:passes
        KaimonGate.progress("pass \$i/\$passes complete")
        # ...
    end
end
```
"""
function progress(message::String)
    rid = get(task_local_storage(), :gate_request_id, nothing)
    rid === nothing && return
    _publish_stream("tool_progress", message; request_id = string(rid))
    try
        ts = Dates.format(Dates.now(), "HH:MM:SS")
        line = "[$ts] ⏳ $message"
        _stderr_overwrite!(line, :progress)
    catch
    end
end

"""
    current_caller() -> Union{String,Nothing}

Identity of the agent that invoked the currently-running `GateTool` handler:
the caller's MCP session id (`Mcp-Session-Id`), threaded through the gate as the
request's `:caller` field and scoped to the dispatch via task-local storage.

Returns `nothing` when there is no caller (a self/nested call, or code run
outside a tool dispatch). Mirrors the `:gate_request_id` idiom used by
[`progress`](@ref)/[`is_cancelled`](@ref).

A tool can use this to key per-agent state (e.g. KaimonSlate's cooperative-edit
lock) to the implicit caller session rather than a model-threaded token.
"""
current_caller() = let v = get(task_local_storage(), :gate_caller, ""); isempty(v) ? nothing : v end


# ─────────────────────────────────────────────────────────────────────────────
# KaimonGate · metadata · handle_message dispatch · ROUTER message loop  (split from gate.jl; part of the KaimonGate module)
# ─────────────────────────────────────────────────────────────────────────────

# ── Metadata ──────────────────────────────────────────────────────────────────

function _json_value(v)
    v isa Bool && return v ? "true" : "false"
    v isa Number && return string(v)
    # Proper JSON string escaping (via KaimonGate's dependency-free `_json_str`). CRITICAL
    # on Windows: `project_path` is like `C:\Users\…`, and unescaped backslashes make the
    # metadata invalid JSON — the client's `JSON.parsefile` then throws and the session is
    # silently never discovered.
    return _json_str(string(v))
end

function write_metadata(
    session_id::AbstractString,
    name::AbstractString,
    endpoint::AbstractString,
    stream_endpoint::AbstractString = "";
    spawned_by::AbstractString = "user",
    mode::Symbol = :ipc,
)
    meta_path = joinpath(sock_dir(),"$(session_id).json")
    meta = Dict{String,Any}(
        "session_id" => session_id,
        "name" => name,
        "pid" => getpid(),
        "julia_version" => string(VERSION),
        "project_path" => dirname(Base.active_project()),
        "endpoint" => endpoint,
        "stream_endpoint" => stream_endpoint,
        "started_at" => string(now()),
        "spawned_by" => spawned_by,
        "mode" => string(mode),
    )
    open(meta_path, "w") do io
        # Simple JSON without dependency — just key-value pairs
        print(io, "{\n")
        pairs = collect(meta)
        for (i, (k, v)) in enumerate(pairs)
            print(io, "  \"$k\": $(_json_value(v))")
            i < length(pairs) && print(io, ",")
            print(io, "\n")
        end
        print(io, "}\n")
    end

    return meta_path
end

function cleanup_files(session_id::String)
    # Always clean up the metadata JSON. Socket files only exist in IPC mode.
    for ext in [".sock", "-stream.sock", ".json"]
        path = joinpath(sock_dir(),"$(session_id)$(ext)")
        isfile(path) && rm(path; force = true)
    end
end

# ── Message loop ──────────────────────────────────────────────────────────────

"""
Serialize a result NamedTuple to bytes for PUB transport.
"""
function _serialize_result(result)::String
    io = IOBuffer()
    serialize(io, result)
    return String(take!(io))
end

# Convert a NUL-terminated UTF-16 (wide) string at `p` into a Julia String. Windows APIs
# (GetCommandLineW / CommandLineToArgvW) return wide strings; `transcode` does UTF-16→UTF-8.
function _utf16_ptr_to_string(p::Ptr{UInt16})
    p == C_NULL && return ""
    len = 0
    while unsafe_load(p, len + 1) != 0x0000
        len += 1
    end
    units = Vector{UInt16}(undef, len)
    @inbounds for i in 1:len
        units[i] = unsafe_load(p, i)
    end
    return transcode(String, units)
end

"""
    _capture_original_argv()

Capture the original process argv once, for replay on restart.
"""
function _capture_original_argv()
    !isempty(_ORIGINAL_ARGV[]) && return
    try
        if Sys.isapple()
            argc_ptr = ccall(:_NSGetArgc, Ptr{Cint}, ())
            argv_ptr = ccall(:_NSGetArgv, Ptr{Ptr{Ptr{UInt8}}}, ())
            argc = unsafe_load(argc_ptr)
            argv_p = unsafe_load(argv_ptr)
            _ORIGINAL_ARGV[] = [unsafe_string(unsafe_load(argv_p, i)) for i = 1:argc]
        elseif Sys.islinux()
            parts = split(read("/proc/self/cmdline", String), '\0'; keepempty = false)
            _ORIGINAL_ARGV[] = String.(parts)
        elseif Sys.iswindows()
            # No argc/argv globals on Windows — recover argv from the OS command line via
            # GetCommandLineW → CommandLineToArgvW (which the C runtime itself uses). Without
            # this _ORIGINAL_ARGV stays empty and restart loses the launch flags + can't detect
            # an app/-e launch, falling back to a reconstructed command.
            p_cmd = ccall((:GetCommandLineW, "kernel32"), Ptr{UInt16}, ())
            argc = Ref{Cint}(0)
            p_argv = ccall((:CommandLineToArgvW, "shell32"), Ptr{Ptr{UInt16}},
                           (Ptr{UInt16}, Ptr{Cint}), p_cmd, argc)
            if p_argv != C_NULL
                try
                    _ORIGINAL_ARGV[] =
                        String[_utf16_ptr_to_string(unsafe_load(p_argv, i)) for i in 1:argc[]]
                finally
                    ccall((:LocalFree, "kernel32"), Ptr{Cvoid}, (Ptr{Cvoid},), p_argv)
                end
            end
        end
    catch e
        @debug "Failed to capture original argv" exception = e
    end
end

"""
    _should_replay_argv()

Check if the original process was started with user-provided code that should
be replayed on restart: a `-e` command (not our own restart code) or a script file.
"""
function _should_replay_argv()
    argv = _ORIGINAL_ARGV[]
    isempty(argv) && return false
    # Check for -e flag with user code
    for (i, arg) in enumerate(argv)
        if arg == "-e" && i < length(argv)
            code = argv[i+1]
            # Our restart serve() pattern → not user code
            occursin("Gate.serve(session_id=", code) && return false
            return true
        end
    end
    # Check for script file (positional arg that's a file path, not a flag)
    # Skip argv[1] (julia binary). Look for first non-flag argument.
    for i = 2:length(argv)
        arg = argv[i]
        startswith(arg, "-") && continue
        # Previous arg was a flag expecting a value (e.g. -C native, -J sysimg, --project=...)
        i > 1 && argv[i-1] in ("-C", "-J", "--project", "-t") && continue
        # This is a positional argument — likely a script file
        isfile(arg) && return true
    end
    return false
end

"""
    _base_julia_args() -> Vector{String}

Return the Julia binary + original launch flags, stripping only the arguments
that `_exec_restart` will inject itself: `-e`/`--eval` (+ value), `--project`
(+ value), and `-i`.  Everything else — `-t`, `--heap-size-hint`, `--gcthreads`,
`-O`, custom sysimage flags, etc. — is preserved verbatim from `_ORIGINAL_ARGV[]`.

Falls back to `Base.julia_cmd().exec` if `_ORIGINAL_ARGV[]` was not captured
(non-macOS/non-Linux or capture failed).
"""
function _base_julia_args()::Vector{String}
    orig = _ORIGINAL_ARGV[]
    isempty(orig) && return Base.julia_cmd().exec

    # Flags that take a separate value and should be combined into one token
    # (e.g. `-t 4,2` → `-t4,2`) to avoid the value being misinterpreted as a
    # positional script argument on restart.
    _VALUE_FLAGS = Set(["-t", "--threads", "-C", "--cpu-target",
                        "-J", "--sysimage", "-O", "--optimize",
                        "-L", "--load",
                        "--gcthreads", "--heap-size-hint"])

    result = [orig[1]]   # preserve exact Julia binary path
    i = 2
    while i <= length(orig)
        arg = orig[i]
        # Strip flags whose values we inject ourselves
        if arg in ("-e", "--eval", "--project")
            i += 2   # skip flag + separate value
            continue
        end
        if startswith(arg, "--eval=") || startswith(arg, "--project=")
            i += 1   # skip combined form
            continue
        end
        # Strip bare -i (we add our own); leave e.g. --inline alone
        if arg == "-i"
            i += 1
            continue
        end
        # Combine short flags with their separate value into one token
        # so the value isn't mistaken for a positional arg on restart
        if arg in _VALUE_FLAGS && i < length(orig) && !startswith(orig[i+1], "-")
            if startswith(arg, "--")
                push!(result, "$(arg)=$(orig[i+1])")
            else
                push!(result, "$(arg)$(orig[i+1])")
            end
            i += 2
            continue
        end
        push!(result, arg)
        i += 1
    end
    return result
end

"""
    _exec_restart(name, session_id, project_path)

Replace the current process with a fresh Julia via `execvp`. Same PID, same
terminal, fresh Julia state. The `-i` flag keeps the REPL interactive.
"""
# The `mode=:tcp, host, port, …` kwargs to replay on restart so the gate rebinds the SAME
# endpoint a client is connected to. Only for an EXPLICIT remote TCP gate. A gate coerced
# IPC→TCP on Windows (`coerced`) must instead restart as a plain :ipc gate (empty kwargs)
# so it re-coerces, binds a fresh ephemeral port, and re-writes discovery metadata — else
# the restarted gate advertises nothing and is never rediscovered (orphaned session).
function _restart_tcp_kwargs(mode::Symbol, coerced::Bool, host::AbstractString,
                             port::Integer, stream_port::Integer,
                             curve_enabled::Bool, curve_allow_any::Bool)
    (mode == :tcp && !coerced) || return ""
    base = ", mode=:tcp, host=$(repr(String(host))), port=$port, stream_port=$stream_port"
    # CURVE: replay the flag; the server secret + allow-list persist on disk (curve/ dir)
    # so the gate rebinds with the same identity.
    curve_kw = curve_enabled ?
        ", curve=true" * (curve_allow_any ? ", allow_any=true" : "") : ""
    return base * curve_kw
end

function _exec_restart(name::String, session_id::String, project_path::String)
    # Signal to all serve() callers in the new process (startup.jl, app code,
    # or our injected -e fallback) that this is a restart and they should
    # reuse this session_id so the TUI reconnects to the same session.
    ENV["KAIMON_RESTART_SESSION"] = session_id

    args = if _should_replay_argv()
        # Replay original argv exactly — the app code (e.g. GateToolTest.run()
        # or bin/kaimon) will call serve(force=true) itself; the env var carries
        # the session_id through. Don't inject -i: it would initialize a REPL
        # backend that conflicts with TUI terminal handling.
        copy(_ORIGINAL_ARGV[])
    else
        # Plain REPL session — reconstruct from the original argv, preserving
        # all launch flags (-t, --heap-size-hint, --gcthreads, -O, etc.), then
        # inject our own --project / -i / -e serve(...).
        julia_args = _base_julia_args()
        ns      = _SESSION_NAMESPACE[]
        mirror  = _ALLOW_MIRROR[]
        restart = _ALLOW_RESTART[]
        mode    = _MODE[]
        ns_kwarg      = isempty(ns) ? "" : ", namespace=$(repr(ns))"
        mirror_kwarg  = mirror  ? "" : ", allow_mirror=false"
        restart_kwarg = restart ? "" : ", allow_restart=false"
        tcp_kwargs = _restart_tcp_kwargs(mode, _LOCAL_TCP_COERCED[], _TCP_HOST[],
            _TCP_PORT[], _TCP_STREAM_PORT[], _CURVE_ENABLED[], _CURVE_ALLOW_ANY[])
        # The injected -e code runs after startup.jl.  If startup.jl already
        # called serve() and picked up KAIMON_RESTART_SESSION, the gate
        # will already be running with the correct session_id; our serve() call
        # becomes a no-op that updates mutable options (mirror, restart flag).
        # If startup.jl didn't call serve, this creates the gate from scratch.
        serve_args = "session_id=$(repr(session_id))$ns_kwarg$mirror_kwarg$restart_kwarg$tcp_kwargs"
        serve_code = _RESTART_CODE_BUILDER[](serve_args)
        vcat(julia_args, ["--project=$project_path", "-i", "-e", serve_code])
    end

    # Restore terminal state and stdio fds before execvp. Tachikoma's
    # with_terminal() has the TUI in alt screen/raw mode and stdout/stderr
    # redirected to pipes. prepare_for_exec!() restores everything at the
    # OS fd level so the new process gets clean TTY IO.
    # Use the host-injected Tachikoma hook; nothing when running standalone.
    try
        T = _TACHIKOMA[]
        if T !== nothing
            if isdefined(T, :prepare_for_exec!)
                Base.invokelatest(getfield(T, :prepare_for_exec!))
            end
        end
    catch
    end

    # Clear the terminal so the restarted session starts with a clean screen.
    # prepare_for_exec!() has already restored the TTY to cooked mode.
    print(stdout, "\e[H\e[2J")
    flush(stdout)

    # execvp replaces the process image — same PID, same terminal
    argv = map(String, args)

    # Windows has no execvp (a process can't replace its own image). Spawn a fresh,
    # DETACHED instance with the same argv and exit — it re-registers under the same
    # session_id (KAIMON_RESTART_SESSION, set above, is inherited), so the client
    # reconnects through the session metadata. New PID, but discover_sessions already
    # handles a session_id whose PID changed on restart.
    if Sys.iswindows()
        try
            run(detach(Cmd(argv)); wait = false)
        catch e
            @error "Windows restart: spawn failed" exception = e
        end
        exit(0)
    end

    ptrs = Ptr{UInt8}[pointer(s) for s in argv]
    push!(ptrs, Ptr{UInt8}(0))  # NULL terminator
    GC.@preserve argv ccall(:execvp, Cint, (Cstring, Ptr{Ptr{UInt8}}), argv[1], ptrs)

    # If we reach here, execvp failed — fall back to exit
    @error "execvp failed, falling back to exit" errno = Base.Libc.errno()
    exit(1)
end

function handle_message(request::NamedTuple)
    # TCP auth: reject unauthenticated requests when a token is set
    if _MODE[] == :tcp && !isempty(_AUTH_TOKEN[])
        token = get(request, :token, "")
        if token != _AUTH_TOKEN[]
            return (type = :error, message = "Authentication required")
        end
    end

    msg_type = get(request, :type, :unknown)
    _MSG_COUNT[] += 1

    if msg_type == :eval
        code = get(request, :code, "")
        display_code = get(request, :display_code, code)
        result = gate_eval(code; display_code = display_code)
        return result
    elseif msg_type == :eval_async
        code = get(request, :code, "")
        display_code = get(request, :display_code, code)
        request_id = get(request, :request_id, "")
        main_thread = get(request, :main_thread, false)
        # Run eval on a spawned thread so the interactive message loop stays
        # responsive to pings during CPU-intensive evals.
        # When main_thread=true, spawn on :interactive so gate_eval routes
        # through REPL.call_on_backend (thread 1) — required for GLMakie/GLFW.
        function _do_async_eval()
            try
                task_local_storage(:gate_request_id, request_id)
                result = gate_eval(code; display_code = display_code)
                try
                    serialized = _serialize_result(result)
                    # Cache result so TUI can retrieve it after a restart
                    lock(_COMPLETED_RESULTS_LOCK) do
                        _COMPLETED_RESULTS[request_id] = Vector{UInt8}(serialized)
                        # Trim to max size
                        while length(_COMPLETED_RESULTS) > _COMPLETED_RESULTS_MAX
                            delete!(_COMPLETED_RESULTS, first(keys(_COMPLETED_RESULTS)))
                        end
                    end
                    _stderr_finish!()  # finalize any \r-overwritten progress/stash lines
                    _publish_stream("eval_complete", serialized; request_id)
                catch pub_err
                    # Serialization of result failed — send a plain-text fallback
                    @error "Failed to serialize eval result" exception = pub_err
                    fallback = (
                        stdout = "",
                        stderr = "",
                        value_repr = "(result could not be serialized: $(sprint(showerror, pub_err)))",
                        exception = nothing,
                        backtrace = nothing,
                    )
                    _publish_stream("eval_complete", _serialize_result(fallback); request_id)
                end
            catch e
                error_result = (
                    stdout = "",
                    stderr = "",
                    value_repr = "",
                    exception = sprint(showerror, e, catch_backtrace()),
                    backtrace = nothing,
                )
                _publish_stream("eval_error", _serialize_result(error_result); request_id)
            end
        end
        if main_thread
            Threads.@spawn :interactive _do_async_eval()
        else
            Threads.@spawn _do_async_eval()
        end
        return (type = :accepted, request_id = request_id)
    elseif msg_type == :set_option
        key = string(get(request, :key, ""))
        value = get(request, :value, nothing)
        return _set_option!(key, value)
    elseif msg_type == :get_options
        return _current_options()
    elseif msg_type == :set_tty
        path = string(get(request, :path, ""))
        isempty(path) && return (type = :error, message = "path required")
        return set_tty!(path)
    elseif msg_type == :ping
        _PING_COUNT[] += 1
        _LAST_PING_TIME[] = time()
        _kv = try; _VERSION_PROVIDER[](); catch; "unknown"; end
        return (
            type = :pong,
            pid = getpid(),
            uptime = time() - _START_TIME[],
            julia_version = string(VERSION),
            protocol_version = PROTOCOL_VERSION,
            kaimon_version = _kv,
            project_path = dirname(Base.active_project()),
            label = get(ENV, "KAIMON_SESSION_LABEL", ""),   # client-provided display label (e.g. a notebook filename)
            tools = [_reflect_tool(t) for t in _SESSION_TOOLS[]],
            namespace = _SESSION_NAMESPACE[],
            allow_restart = _ALLOW_RESTART[],
            allow_mirror = _ALLOW_MIRROR[],
            mirror_repl = _MIRROR_REPL[],
            stream_endpoint = _STREAM_ENDPOINT[],
            server_pubkey = _CURVE_SERVER_PUBLIC[],
        )
    elseif msg_type == :tool_call
        tool_name = string(get(request, :name, ""))
        raw_args = get(request, :arguments, Dict{String,Any}())
        # Convert to Dict{String,Any} whether args come as NamedTuple or Dict
        tool_args = if raw_args isa Dict
            Dict{String,Any}(string(k) => v for (k, v) in raw_args)
        else
            Dict{String,Any}(string(k) => v for (k, v) in pairs(raw_args))
        end
        idx = findfirst(t -> t.name == tool_name, _SESSION_TOOLS[])
        if idx === nothing
            return (type = :error, message = "Unknown session tool: $tool_name")
        end
        tool = _SESSION_TOOLS[][idx]
        # Caller identity = the invoking agent's Mcp-Session-Id (empty for a
        # self/nested call). MUST use the SCOPED task_local_storage(key, val) do…
        # form: this sync path may run on the long-lived message-loop task, so a
        # bare 2-arg setter would leak the caller into the next request handled on
        # that task. Scoping clears it on return. current_caller() reads :gate_caller.
        caller = string(get(request, :caller, ""))
        agent_id = string(get(request, :agent_id, ""))
        try
            result = task_local_storage(:gate_caller, caller) do
                task_local_storage(:gate_agent_id, agent_id) do
                    _dispatch_tool_call(tool.handler, tool_args)
                end
            end
            return (type = :result, value = result)
        catch e
            return (type = :error, message = sprint(showerror, e))
        end
    elseif msg_type == :tool_call_async
        tool_name = string(get(request, :name, ""))
        raw_args = get(request, :arguments, Dict{String,Any}())
        tool_args = if raw_args isa Dict
            Dict{String,Any}(string(k) => v for (k, v) in raw_args)
        else
            Dict{String,Any}(string(k) => v for (k, v) in pairs(raw_args))
        end
        request_id = string(get(request, :request_id, ""))

        idx = findfirst(t -> t.name == tool_name, _SESSION_TOOLS[])
        if idx === nothing
            return (type = :error, message = "Unknown session tool: $tool_name")
        end
        tool = _SESSION_TOOLS[][idx]
        # Caller identity = the invoking agent's Mcp-Session-Id (read before the
        # spawn so the captured `request` value is used). This path spawns a fresh
        # task per call, so the bare 2-arg setter below is already naturally scoped.
        caller = string(get(request, :caller, ""))
        agent_id = string(get(request, :agent_id, ""))

        # Run tool handler on a default-pool thread so the interactive message
        # loop stays responsive to pings during CPU-intensive tool calls.
        Threads.@spawn begin
            try
                # Make progress function available via task-local storage
                task_local_storage(:gate_request_id, request_id)
                task_local_storage(:gate_progress, true)
                task_local_storage(:gate_caller, caller)
                task_local_storage(:gate_agent_id, agent_id)

                result = _dispatch_tool_call(tool.handler, tool_args; tool_name = tool.name)
                _stderr_finish!()
                _publish_stream("tool_complete", string(result); request_id)
            catch e
                # A parameter mismatch is a usage mistake, not a runtime fault — publish the
                # concise explanation alone. Genuine errors keep their backtrace for debugging.
                _publish_stream(
                    "tool_error",
                    e isa ToolArgumentError ? e.msg : sprint(showerror, e, catch_backtrace());
                    request_id,
                )
            end
        end

        return (type = :accepted, request_id = request_id)
    elseif msg_type == :list_tools
        tool_meta = [_reflect_tool(t) for t in _SESSION_TOOLS[]]
        return (type = :tools, tools = tool_meta)
    elseif msg_type == :shutdown
        _SHUTTING_DOWN[] = true
        _RUNNING[] = false
        return (type = :ok, message = "shutting down")
    elseif msg_type == :restart
        # Save metadata before cleanup
        old_name = string(get(request, :name, "julia"))
        old_session_id = _SESSION_ID[]
        old_project = dirname(Base.active_project())

        # Signal the message-loop task's `finally` block to skip _cleanup().
        # We need the ZMQ sockets to stay open for ~0.3 s so the :ok reply
        # above actually reaches the client before we tear down the process.
        _RESTARTING[] = true
        _RUNNING[] = false

        @async begin
            sleep(0.3)  # Let ZMQ reply flush through IPC buffer
            _RESTARTING[] = false
            # Cleanup is BEST-EFFORT: a teardown hiccup (e.g. the broadcaster
            # wait under a busy/loaded process) must NOT abort the restart —
            # otherwise we'd drop the user to a shell instead of relaunching.
            # Always proceed to exec; _exec_restart has its own execvp fallback.
            try
                _cleanup()  # Close sockets, remove metadata files
            catch e
                @warn "Restart cleanup failed; proceeding to exec anyway" exception = (e, catch_backtrace())
            end
            try
                _exec_restart(old_name, old_session_id, old_project)
            catch e
                # execvp setup failed before the process could be replaced. Do NOT
                # exit(1) — that drops to a shell. Leave the (now gate-less) REPL
                # alive so the user can recover (e.g. call serve() again).
                @error "Restart exec failed; session left running without a gate — call KaimonGate.serve() to recover" exception = (e, catch_backtrace())
            end
        end

        return (type = :ok, message = "restarting via exec")
    # ── Debug Protocol ──────────────────────────────────────────────────────
    elseif msg_type == :debug_status
        paused = _DEBUG_PAUSED[]
        if paused !== nothing
            return (type = :debug_status, is_paused = true, paused...)
        else
            return (type = :debug_status, is_paused = false)
        end

    elseif msg_type == :debug_eval
        eval_ch = _DEBUG_EVAL_CH[]
        eval_ch === nothing &&
            return (type = :error, message = "Not paused at a breakpoint")
        code = string(get(request, :code, ""))
        result_ch = Channel{Any}(1)
        put!(eval_ch, code => result_ch)
        result = take!(result_ch)
        # Publish so TUI can show agent evals in console
        src = get(request, :source, :agent)
        _publish_stream("debug_eval", _serialize_result((source = src, code = code, result = result)))
        return (type = :debug_eval_result, result = result)

    elseif msg_type == :debug_continue
        resume_ch = _DEBUG_RESUME_CH[]
        resume_ch === nothing &&
            return (type = :error, message = "Not paused at a breakpoint")
        put!(resume_ch, :continue)
        return (type = :ok, message = "Execution resumed")

    elseif msg_type == :get_job_result
        eid = string(get(request, :eval_id, ""))
        cached = lock(_COMPLETED_RESULTS_LOCK) do
            get(_COMPLETED_RESULTS, eid, nothing)
        end
        if cached !== nothing
            return (type = :job_result, eval_id = eid, data = String(cached))
        else
            return (type = :not_found, eval_id = eid)
        end

    elseif msg_type == :cancel_job
        eid = string(get(request, :eval_id, ""))
        if !isempty(eid)
            cancel_job!(eid)
            return (type = :ok, message = "Job $eid marked for cancellation")
        end
        return (type = :error, message = "Missing eval_id")

    else
        return (type = :error, message = "unknown request type: $msg_type")
    end
end

# ── Multipart framing (ZMQ.jl 1.5 has no multipart helper) ────────────────────
# A DEALER→ROUTER message arrives as [identity, corr_id, payload]; the reply is
# sent with the same identity envelope and corr_id echoed back. recv the first
# frame (bounded by rcvtimeo), then the rest atomically while `rcvmore`.
function _recv_multipart(sock::ZMQ.Socket)
    parts = Vector{UInt8}[_zmq_recv(sock)]   # may throw ZMQ.TimeoutError
    while sock.rcvmore
        push!(parts, _zmq_recv(sock))
    end
    return parts
end

function _send_multipart(sock::ZMQ.Socket, parts::Vector{Vector{UInt8}})
    n = length(parts)
    for (i, p) in enumerate(parts)
        send(sock, p; more = (i < n))
    end
end

# Drain whatever replies are ready onto the ROUTER (owner-only socket access).
function _drain_gate_outbox!(socket::ZMQ.Socket)
    while isready(_GATE_OUTBOX)
        (identity, corr_id, reply) = take!(_GATE_OUTBOX)
        try
            _send_multipart(socket, Vector{UInt8}[identity, corr_id, reply])
        catch
            # ROUTER drops replies to vanished peers (timed-out/gone clients) —
            # expected; nothing else can be done with this reply.
            _RUNNING[] || break
        end
    end
end

# Run one request to completion on its own task and hand the reply to the outbox.
# Never touches the socket. invokelatest so handle_message (and the session tools
# it calls) runs in the latest world age — required for tools whose types were
# defined after the gate loop started.
function _serve_request(identity::Vector{UInt8}, corr_id::Vector{UInt8}, request)
    reply = try
        Base.invokelatest(handle_message, request)
    catch e
        (type = :error, message = sprint(showerror, e))
    end
    io = IOBuffer()
    serialize(io, reply)
    put!(_GATE_OUTBOX, (identity, corr_id, take!(io)))
    Threads.atomic_sub!(_GATE_INFLIGHT, 1)
    return nothing
end

function message_loop(socket::ZMQ.Socket)
    # Adaptive recv timeout: short while a worker reply may be pending (so it
    # flushes within a few ms), long when idle (so the gate doesn't busy-poll).
    # Tracked so we only call setsockopt on an actual transition. -1 forces the
    # first apply. See _GATE_RCVTIMEO_BUSY/_IDLE for why (the 200ms drag-lag fix).
    cur_rcvtimeo = -1
    while _RUNNING[]
        try
            # 1. flush any ready worker replies first (owner-only socket access)
            _drain_gate_outbox!(socket)

            # 2. backpressure: at the worker cap, let the outbox drain before
            #    accepting more. Pending requests stay queued in the ROUTER.
            if _GATE_INFLIGHT[] >= _GATE_MAX_WORKERS[]
                sleep(0.005)
                continue
            end

            # 2b. pick recv timeout: poll fast while a reply may be in flight (a
            #     worker running, or one already queued between drain and now),
            #     else wait long. Owner-only socket access, so setsockopt is safe.
            want_rcvtimeo = (_GATE_INFLIGHT[] > 0 || isready(_GATE_OUTBOX)) ?
                            _GATE_RCVTIMEO_BUSY[] : _GATE_RCVTIMEO_IDLE[]
            if want_rcvtimeo != cur_rcvtimeo
                socket.rcvtimeo = want_rcvtimeo
                cur_rcvtimeo = want_rcvtimeo
            end

            # 3. recv one request — [identity, corr_id, payload] (bounded by rcvtimeo)
            parts = _recv_multipart(socket)
            length(parts) >= 3 || continue
            identity = parts[1]
            corr_id = parts[2]
            payload = parts[end]

            request = try
                deserialize(IOBuffer(payload))
            catch
                io = IOBuffer()
                serialize(io, (type = :error, message = "malformed request"))
                put!(_GATE_OUTBOX, (identity, corr_id, take!(io)))
                continue
            end

            # 4. hand off to a worker — DO NOT run inline (a slow sync eval or a
            #    blocked debug_eval must not stall intake / pings).
            Threads.atomic_add!(_GATE_INFLIGHT, 1)
            Threads.@spawn _serve_request(identity, corr_id, request)
        catch e
            if !_RUNNING[]
                break  # Clean shutdown
            end
            # Timeout is expected — just loop to check _RUNNING and drain outbox.
            if e isa ZMQ.TimeoutError
                continue
            end
            if e isa ZMQ.StateError || e isa EOFError
                break
            end
            @debug "Gate message loop error" exception = e
        end
    end

    # Final bounded drain so in-flight replies (notably the :shutdown / :restart
    # :ok that the client is still waiting on) get flushed before teardown. The
    # :restart handler then sleeps 0.3s before execvp, so the reply lands.
    deadline = time() + 1.0
    while (isready(_GATE_OUTBOX) || _GATE_INFLIGHT[] > 0) && time() < deadline
        try
            _drain_gate_outbox!(socket)
        catch
            break
        end
        sleep(0.005)
    end
end


# ─────────────────────────────────────────────────────────────────────────────
# KaimonGate · reverse service client · kaimon.toml [gate] config  (split from gate.jl; part of the KaimonGate module)
# ─────────────────────────────────────────────────────────────────────────────

# ── Service Client (reverse channel to Kaimon server) ─────────────────────────
# Extensions call KaimonGate.call_tool(name, args) to invoke any registered Kaimon
# MCP tool. This is the reverse of the existing gate protocol: instead of
# Kaimon calling into the gate, the gate calls back into Kaimon.

# Legacy ref: per-call sockets are used now (below), but cleanup still nils this.
const _SERVICE_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)

# Windows has no ipc:// transport, so the service endpoint (a per-Kaimon-instance
# singleton) uses a fixed TCP loopback port there — the direct analog of the single
# fixed `kaimon-service.sock` path on Unix. Kaimon's `start_service_endpoint!` binds
# this same port. (#41)
const _SERVICE_TCP_PORT = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_SERVICE_TCP_PORT", "")), 9877))

# Per-call REQ recv timeout (ms). Must exceed the worst case admission-wait +
# slowest-tool timeout (agent_run defaults to 600s and is caller-settable). Kept
# finite on purpose — an infinite timeout blocks forever if the server dies
# mid-recv (e.g. an /mcp reconnect); a finite one lets a dead server be noticed.
# A per-call socket can't wedge, so on timeout we just fail that one call cleanly.
const _SERVICE_RCV_TIMEOUT_MS = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_SERVICE_RCV_TIMEOUT_MS", "")), 660_000))

"""
    _service_request(request::NamedTuple) -> Any

Send a request to the Kaimon service endpoint and return the response value.

Each call uses its OWN short-lived REQ socket (create → connect → send → recv →
close). The server is a ROUTER, so concurrent `call_tool`s from one gate session
run in parallel — no shared socket, no lock — and a per-call socket can never
wedge: the strict REQ send/recv FSM starts fresh every call. Supersedes the old
single shared REQ + lock (+ reset-on-throw) design.
"""
function _service_request(request)
    ctx = _GATE_CONTEXT[]
    ctx === nothing && error("Kaimon service endpoint not available (no ZMQ context).")

    # Unix: ipc:// socket file (presence-checkable). Windows: fixed TCP loopback port
    # (no file to check — unavailability surfaces as a send/recv timeout below). (#41)
    if Sys.iswindows()
        endpoint = "tcp://127.0.0.1:$(_SERVICE_TCP_PORT[])"
    else
        sock_path = joinpath(sock_dir(), "kaimon-service.sock")
        ispath(sock_path) || error("Kaimon service endpoint not available. Is the Kaimon TUI running?")
        endpoint = "ipc://$(sock_path)"
    end

    sock = _zmq_socket(ctx, REQ)
    sock.rcvtimeo = _SERVICE_RCV_TIMEOUT_MS[]
    sock.sndtimeo = 5000   # 5s send timeout
    sock.linger = 0
    connect(sock, endpoint)
    try
        io = IOBuffer()
        serialize(io, request)
        send(sock, take!(io))
        raw = _zmq_recv(sock)
        response = deserialize(IOBuffer(raw))

        status = if hasproperty(response, :status)
            response.status
        elseif response isa Dict
            get(response, :status, :error)
        else
            :error
        end

        if status == :error
            msg = if hasproperty(response, :message)
                response.message
            elseif response isa Dict
                get(response, :message, "unknown error")
            else
                "unknown error"
            end
            error("Kaimon service error: $msg")
        end

        return response.value
    finally
        close(sock)   # fresh socket per call — nothing to reset/wedge
    end
end

"""
    KaimonGate.call_tool(tool_name::Symbol, args::Dict{String,Any}) -> Any

Call a Kaimon MCP tool from within a gate session. The request is sent over
a dedicated ZMQ REQ socket to the Kaimon server's service endpoint, which
looks up the tool in its registry and calls the handler.

This gives extensions access to all of Kaimon's registered tools — Qdrant
search, Ollama embeddings, code indexing, etc. — without bundling their
own clients.

# Example
```julia
# From a gate tool handler:
result = KaimonGate.call_tool(:qdrant_search_code, Dict{String,Any}(
    "query" => "function that handles HTTP routing",
    "limit" => "5",
))

# List collections
collections = KaimonGate.call_tool(:qdrant_list_collections, Dict{String,Any}())
```
"""
function call_tool(tool_name::Symbol, args::Dict{String,Any} = Dict{String,Any}())
    _service_request((type = :tool_call, tool_name = tool_name, args = args))
end

"""
    KaimonGate.list_tools() -> Vector{NamedTuple}

Discover all MCP tools registered on the Kaimon server.
Returns a vector of `(name, description, parameters)` tuples.

# Example
```julia
tools = KaimonGate.list_tools()
for t in tools
    println(t.name, " — ", first(split(t.description, '\\n')))
end
```
"""
function list_tools()
    _service_request((type = :list_tools,))
end

# ── kaimon.toml [gate] section support ─────────────────────────────────────────

"""
    _load_gate_config() -> Dict{String,Any}

Read the `[gate]` section from `kaimon.toml` in the active project root.
Returns an empty Dict if the file doesn't exist or has no `[gate]` section.
"""
function _load_gate_config()
    project = Base.active_project()
    project === nothing && return Dict{String,Any}()
    toml_path = joinpath(dirname(project), "kaimon.toml")
    if !isfile(toml_path)
        @debug "kaimon.toml not found" toml_path
        return Dict{String,Any}()
    end
    try
        data = TOML.parsefile(toml_path)
        gate = get(data, "gate", Dict{String,Any}())
        !isempty(gate) && @debug "Loaded kaimon.toml [gate]" gate
        return gate
    catch e
        @warn "Failed to parse kaimon.toml" toml_path exception=e
        return Dict{String,Any}()
    end
end

"""
    _auto_serve!()

Auto-start the gate if environment variables or kaimon.toml `[gate]` section
indicate TCP mode.

Invoked by the host package (Kaimon) from its `__init__`. A standalone
`using KaimonGate` session does **not** auto-start — call [`serve`](@ref)
explicitly (it still reads env vars / `kaimon.toml` for its settings).

Configuration priority: env vars > kaimon.toml > defaults.
"""
function _auto_serve!()
    _RUNNING[] && return  # already running

    # Merge kaimon.toml [gate] config with env var overrides
    toml = _load_gate_config()
    toml_mode = get(toml, "mode", "")
    toml_port = get(toml, "port", nothing)
    toml_stream_port = get(toml, "stream_port", nothing)
    toml_host = get(toml, "host", "")
    toml_force = Bool(get(toml, "force", false))

    env_mode = get(ENV, "KAIMON_GATE_MODE", "")
    has_env_port = haskey(ENV, "KAIMON_GATE_PORT") || haskey(ENV, "KAIMON_GATE_STREAM_PORT")

    # Determine effective mode
    mode = if !isempty(env_mode)
        Symbol(env_mode)
    elseif has_env_port
        :tcp
    elseif toml_mode == "tcp"
        :tcp
    elseif toml_port !== nothing || toml_stream_port !== nothing
        :tcp
    else
        return  # no auto-start configured
    end

    mode == :tcp || return  # only auto-start for TCP mode

    # Resolve parameters (env > toml > defaults)
    host = let h = get(ENV, "KAIMON_GATE_HOST", "")
        !isempty(h) ? h : !isempty(toml_host) ? toml_host : "127.0.0.1"
    end
    port = let p = get(ENV, "KAIMON_GATE_PORT", "")
        !isempty(p) ? parse(Int, p) : toml_port !== nothing ? Int(toml_port) : 0
    end
    stream_port = let sp = get(ENV, "KAIMON_GATE_STREAM_PORT", "")
        !isempty(sp) ? parse(Int, sp) : toml_stream_port !== nothing ? Int(toml_stream_port) : 0
    end
    force = toml_force || has_env_port || !isempty(env_mode)

    try
        serve(; mode, host, port, stream_port, force)
    catch e
        @warn "Gate auto-start failed" exception=e
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# gate_curve.jl — CURVE (Curve25519) encryption + authentication for the TCP gate
#
# ZMQ's CURVE mechanism gives encryption AND authentication on a tcp:// socket via
# four socket options — no TLS/cert machinery. This file is the whole wrapper
# surface: keygen, the setsockopt helpers (ZMQ.jl's property API does NOT expose
# the CURVE/ZAP options — see ZMQ sockopts.jl `sockprops` — so we go through the
# low-level `ZMQ.lib.zmq_setsockopt`), key persistence, TOFU server pinning, the
# client allow-list, and the ZAP authorization handler.
#
# `include`d into the KaimonGate module after gate.jl (shares its globals:
# `_gate_cache_dir`, `_RUNNING`). CURVE is opt-in (`serve(...; curve=true)`); the
# plain :tcp and :ipc paths are untouched.
# ═══════════════════════════════════════════════════════════════════════════════

# ── ZMQ option ids (ZMTP ABI — fixed; mirrors ZMQ/src/bindings.jl :750-766) ────
const _ZMQ_CURVE_SERVER    = 47
const _ZMQ_CURVE_PUBLICKEY = 48
const _ZMQ_CURVE_SECRETKEY = 49
const _ZMQ_CURVE_SERVERKEY = 50
const _ZMQ_ZAP_DOMAIN      = 55

# The well-known inproc endpoint libzmq calls for authentication (RFC 27 / ZAP).
# NOTE: it is "zeromq.zap.01", not "zmq.zap.01".
const _ZAP_ENDPOINT = "inproc://zeromq.zap.01"
const _ZAP_DOMAIN   = "kaimon"

# CURVE server state (set in serve() when curve=true) + ZAP handler handles.
const _CURVE_SERVER_SECRET = Ref{String}("")
const _CURVE_SERVER_PUBLIC = Ref{String}("")
const _CURVE_ENABLED   = Ref{Bool}(false)   # remembered for restart replay
const _CURVE_ALLOW_ANY = Ref{Bool}(false)   # remembered for restart replay
const _ZAP_SOCKET = Ref{Union{ZMQ.Socket,Nothing}}(nothing)
const _ZAP_TASK   = Ref{Union{Task,Nothing}}(nothing)

# ── Low-level setsockopt helpers ──────────────────────────────────────────────

function _curve_error(ctx::AbstractString)
    en = ZMQ.lib.zmq_errno()
    msg = unsafe_string(ZMQ.lib.zmq_strerror(en))
    error("CURVE: $ctx failed: $msg (errno=$en)")
end

"""Set an integer (Cint) socket option via the low-level binding."""
function _setsockopt_int(sock::ZMQ.Socket, opt::Integer, v::Integer)
    rc = ZMQ.lib.zmq_setsockopt(sock, Cint(opt), Ref{Cint}(v), sizeof(Cint))
    rc == 0 || _curve_error("setsockopt int opt=$opt")
    return nothing
end

"""Set a string socket option (CURVE keys are 40-char Z85; ZAP domain is ascii).
Length is passed WITHOUT a NUL terminator (40 for a Z85 key)."""
function _setsockopt_str(sock::ZMQ.Socket, opt::Integer, s::AbstractString)
    bytes = codeunits(String(s))
    GC.@preserve bytes begin
        rc = ZMQ.lib.zmq_setsockopt(sock, Cint(opt), pointer(bytes), length(bytes))
        rc == 0 || _curve_error("setsockopt str opt=$opt")
    end
    return nothing
end

# ── Keygen ────────────────────────────────────────────────────────────────────

"""
    curve_keypair() -> (public::String, secret::String)

Generate a fresh CURVE keypair as Z85 strings (40 chars each). Requires libzmq
built with libsodium/tweetnacl (it is, in the ZMQ_jll we ship).
"""
function curve_keypair()
    pub = Vector{UInt8}(undef, 41)   # 40 Z85 chars + NUL
    sec = Vector{UInt8}(undef, 41)
    rc = ZMQ.lib.zmq_curve_keypair(pub, sec)
    rc == 0 || _curve_error("zmq_curve_keypair (is libzmq built with libsodium?)")
    return (unsafe_string(pointer(pub)), unsafe_string(pointer(sec)))
end

"""Derive the Z85 public key for a Z85 secret key."""
function curve_public(secret::AbstractString)
    sec = codeunits(String(secret))
    pub = Vector{UInt8}(undef, 41)
    GC.@preserve sec begin
        rc = ZMQ.lib.zmq_curve_public(pub, pointer(sec))
        rc == 0 || _curve_error("zmq_curve_public")
    end
    return unsafe_string(pointer(pub))
end

"""Z85-encode a 32-byte binary key (e.g. the client key from a ZAP request) to its
40-char Z85 string, for comparison against the allow-list."""
function _z85_encode(bin::AbstractVector{UInt8})
    length(bin) == 32 || error("CURVE: expected 32-byte key, got $(length(bin))")
    dest = Vector{UInt8}(undef, 41)   # 32*5/4 + 1
    src = collect(UInt8, bin)
    GC.@preserve dest src begin
        p = ZMQ.lib.zmq_z85_encode(dest, pointer(src), length(src))
        p == C_NULL && _curve_error("zmq_z85_encode")
    end
    return unsafe_string(pointer(dest))
end

# ── Apply CURVE role to a socket (BEFORE bind/connect) ─────────────────────────

"""Make `sock` a CURVE server holding `secret` (Z85). Call before `bind`."""
function make_curve_server!(sock::ZMQ.Socket, secret::AbstractString)
    _setsockopt_int(sock, _ZMQ_CURVE_SERVER, 1)
    _setsockopt_str(sock, _ZMQ_CURVE_SECRETKEY, secret)
    return nothing
end

"""Make `sock` a CURVE client pinned to `server_pub`, presenting its own keypair.
Call before `connect`. Ephemeral client keys are fine unless a ZAP allow-list is
in force, in which case the client pubkey must be enrolled."""
function make_curve_client!(sock::ZMQ.Socket, server_pub::AbstractString,
                            client_pub::AbstractString, client_sec::AbstractString)
    _setsockopt_str(sock, _ZMQ_CURVE_SERVERKEY, server_pub)
    _setsockopt_str(sock, _ZMQ_CURVE_PUBLICKEY, client_pub)
    _setsockopt_str(sock, _ZMQ_CURVE_SECRETKEY, client_sec)
    return nothing
end

# ── Key persistence ───────────────────────────────────────────────────────────

"""Directory holding CURVE key material + trust stores. Honors XDG_CACHE_HOME at
runtime (mirrors `_gate_cache_dir`/`sock_dir`)."""
function _curve_dir()
    d = joinpath(_gate_cache_dir(), "curve")
    mkpath(d)
    return d
end

# Keypair file format: two lines, "public\nsecret", mode 0600.
function _read_keypair(path::String)
    isfile(path) || return nothing
    lines = filter(!isempty, strip.(readlines(path)))
    length(lines) >= 2 || return nothing
    return (String(lines[1]), String(lines[2]))
end

function _write_keypair(path::String, public::AbstractString, secret::AbstractString)
    open(path, "w") do io
        println(io, public)
        println(io, secret)
    end
    try; chmod(path, 0o600); catch; end
    return nothing
end

"""Load the persisted keypair named `name` (e.g. "server", "client") from the
curve dir, generating and persisting one on first use. Returns `(public, secret)`."""
function _load_or_create_keypair(name::String)
    path = joinpath(_curve_dir(), "$(name).key")
    kp = _read_keypair(path)
    kp === nothing || return kp
    public, secret = curve_keypair()
    _write_keypair(path, public, secret)
    return (public, secret)
end

_load_or_create_server_keypair() = _load_or_create_keypair("server")
_load_or_create_client_keypair() = _load_or_create_keypair("client")

"""Resolve the server's CURVE secret for serve(): explicit kwarg/env wins, else
the persisted server keypair (generate-once). Returns `(public, secret)`."""
function _resolve_server_keypair(secret::Union{String,Nothing})
    if secret !== nothing && !isempty(secret)
        return (curve_public(secret), String(secret))
    end
    env = get(ENV, "KAIMON_GATE_CURVE_SECRET", "")
    if !isempty(env)
        return (curve_public(env), env)
    end
    return _load_or_create_server_keypair()
end

# ── TOFU server pinning (client side) — SSH known_hosts style ──────────────────
# File: <curve_dir>/known_servers, lines "host:port pubkey".

function _pinned_server(host::AbstractString, port::Integer)
    f = joinpath(_curve_dir(), "known_servers")
    isfile(f) || return nothing
    key = "$(host):$(port)"
    for line in eachline(f)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        parts = split(s)
        length(parts) >= 2 && String(parts[1]) == key && return String(parts[2])
    end
    return nothing
end

"""Pin `pubkey` for `host:port`. Returns `:pinned` (new), `:ok` (already matches),
or `:mismatch` (a DIFFERENT key is pinned — possible MITM; caller decides)."""
function pin_server!(host::AbstractString, port::Integer, pubkey::AbstractString)
    existing = _pinned_server(host, port)
    if existing !== nothing
        return existing == pubkey ? :ok : :mismatch
    end
    f = joinpath(_curve_dir(), "known_servers")
    open(f, "a") do io
        println(io, "$(host):$(port) $(pubkey)")
    end
    return :pinned
end

"""List every TOFU pin as `(host:port, pubkey)` tuples, in file order."""
function known_servers()
    f = joinpath(_curve_dir(), "known_servers")
    out = Tuple{String,String}[]
    isfile(f) || return out
    for line in eachline(f)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        parts = split(s)
        length(parts) >= 2 && push!(out, (String(parts[1]), String(parts[2])))
    end
    return out
end

"""Remove the TOFU pin for `hostport` (the `host:port` key as listed by
`known_servers`). Returns `:removed` or `:absent`. Comments/blank lines are
preserved."""
function unpin_server!(hostport::AbstractString)
    f = joinpath(_curve_dir(), "known_servers")
    isfile(f) || return :absent
    kept = String[]
    removed = false
    for line in eachline(f)
        s = strip(line)
        if !isempty(s) && !startswith(s, "#")
            parts = split(s)
            if !isempty(parts) && String(parts[1]) == String(hostport)
                removed = true
                continue
            end
        end
        push!(kept, line)
    end
    removed || return :absent
    open(f, "w") do io
        for l in kept
            println(io, l)
        end
    end
    return :removed
end

"""Fetch a remote gate's CURVE server *public* key over SSH (assumes passwordless
SSH to `ssh_target`). Reads only the first line of the keypair file (`head -n1`),
so the remote *secret* never crosses the wire. Returns the trimmed Z85 string, or
throws on an SSH/IO error."""
function _fetch_server_pubkey_ssh(ssh_target::AbstractString, remote_key_path::AbstractString)
    cmd = `ssh -o BatchMode=yes -o ConnectTimeout=10 $ssh_target head -n1 $remote_key_path`
    out = IOBuffer()
    err = IOBuffer()
    try
        run(pipeline(cmd; stdout = out, stderr = err))
    catch
        # Surface ssh's own stderr (e.g. "Connection refused", "Permission
        # denied (publickey)") rather than the opaque Process repr.
        reason = strip(String(take!(err)))
        error(isempty(reason) ? "ssh to $ssh_target failed" : reason)
    end
    return strip(String(take!(out)))
end

"""
    verify_server_key_via_ssh(host, port; ssh_target=host,
        remote_key_path="~/.cache/kaimon/curve/server.key", repin=false,
        fetch=_fetch_server_pubkey_ssh) -> NamedTuple

**Soy-free mode** — the antidote to TOFU (Trust On First Use): instead of taking
the first key you see on faith, you bring your own verified one over an already-
authenticated channel. (You don't bring tofu to the BBQ; you bring the steak.)

Reconcile a remote gate's authoritative CURVE server key (fetched out-of-band over
SSH) with the local TOFU pin for `host:port`. This both **bootstraps** trust
without a blind first-use and **detects key changes** — which CURVE cannot do
in-band, since a wrong pinned key just fails the handshake silently.

Because the CURVE server key is *server-authenticating* (the client must encrypt
to it; there is no bearer secret handed over), bootstrapping the pin over the
already-authenticated SSH channel collapses trust to "do you trust SSH to this
host?" — closing the TOFU first-use MITM gap entirely.

Returns `(; status, key, old_pin, ssh_target, message)` where `status` is:
- `:pinned`  — no prior pin; the fetched key is now pinned (bootstrap)
- `:ok`      — fetched key matches the existing pin (verified)
- `:changed` — fetched key DIFFERS from the pin (rotation or MITM); the pin is
               replaced only when `repin=true`
- `:error`   — SSH/parse failure (see `message`); the pin is left untouched

`fetch(ssh_target, remote_key_path) -> String` is injectable for testing.
"""
function verify_server_key_via_ssh(host::AbstractString, port::Integer;
        ssh_target::AbstractString = String(host),
        remote_key_path::AbstractString = "~/.cache/kaimon/curve/server.key",
        repin::Bool = false,
        fetch::Function = _fetch_server_pubkey_ssh)
    old_pin = _pinned_server(host, port)
    key = try
        String(fetch(ssh_target, remote_key_path))
    catch e
        return (; status = :error, key = "", old_pin,
                  ssh_target = String(ssh_target), message = sprint(showerror, e))
    end
    if length(key) != 40
        return (; status = :error, key = "", old_pin, ssh_target = String(ssh_target),
                  message = "expected a 40-char Z85 key, got $(length(key)) chars")
    end
    if old_pin === nothing
        pin_server!(host, port, key)
        return (; status = :pinned, key, old_pin, ssh_target = String(ssh_target), message = "")
    elseif old_pin == key
        return (; status = :ok, key, old_pin, ssh_target = String(ssh_target), message = "")
    else
        if repin
            unpin_server!("$(host):$(port)")
            pin_server!(host, port, key)
        end
        return (; status = :changed, key, old_pin, ssh_target = String(ssh_target), message = "")
    end
end

# ── Client allow-list (server side) — SSH authorized_keys style ────────────────
# File: <curve_dir>/authorized_clients, one Z85 client pubkey per line.

function _authorized_clients()
    f = joinpath(_curve_dir(), "authorized_clients")
    s = Set{String}()
    isfile(f) || return s
    for line in eachline(f)
        t = strip(line)
        (isempty(t) || startswith(t, "#")) && continue
        push!(s, String(first(split(t))))
    end
    return s
end

"""Add `pubkey` (Z85 client public key) to the allow-list. Returns `:added` or
`:already`."""
function authorize_client!(pubkey::AbstractString)
    pubkey in _authorized_clients() && return :already
    f = joinpath(_curve_dir(), "authorized_clients")
    open(f, "a") do io
        println(io, pubkey)
    end
    return :added
end

"""Sorted list of authorized client public keys (Z85) on the allow-list."""
authorized_clients() = sort!(collect(_authorized_clients()))

"""Remove `pubkey` from the client allow-list. Returns `:removed` or `:absent`.
Comments/blank lines are preserved."""
function revoke_client!(pubkey::AbstractString)
    f = joinpath(_curve_dir(), "authorized_clients")
    isfile(f) || return :absent
    kept = String[]
    removed = false
    for line in eachline(f)
        t = strip(line)
        if !isempty(t) && !startswith(t, "#") && String(first(split(t))) == String(pubkey)
            removed = true
            continue
        end
        push!(kept, line)
    end
    removed || return :absent
    open(f, "w") do io
        for l in kept
            println(io, l)
        end
    end
    return :removed
end

# ── ZAP authorization handler ──────────────────────────────────────────────────
# libzmq routes each CURVE handshake to a REP socket bound (same context) at
# _ZAP_ENDPOINT. We reply 200 (allow) / 400 (deny) based on the client's pubkey.
# One handler per context covers every socket that sets ZAP_DOMAIN.

# ZAP 1.0 request frames: version, request_id, domain, address, identity,
# mechanism, credentials...  For CURVE the single credentials frame is the
# client's 32 raw key bytes.
function _handle_zap_request(zap::ZMQ.Socket, frames::Vector{Vector{UInt8}},
                             allow::Set{String}, allow_any::Bool)
    length(frames) >= 7 || return
    request_id = frames[2]
    client_key = frames[7]
    ok = allow_any
    if !ok
        client_z85 = try
            _z85_encode(client_key)
        catch
            ""
        end
        ok = client_z85 in allow
    end
    reply = Any[
        "1.0",                       # version
        request_id,                  # echo request id
        ok ? "200" : "400",          # status code
        ok ? "OK" : "denied",        # status text
        "",                          # user id
        "",                          # metadata
    ]
    ZMQ.send_multipart(zap, reply)
    return nothing
end

"""
    _start_zap_handler!(ctx; allow_any=false) -> Task

Bind a ZAP REP handler on `ctx` and service authentication requests until the
gate stops. With `allow_any=true` every CURVE client is accepted (posture A —
encryption + server pinning only); otherwise only clients whose pubkey is in the
allow-list (`authorized_clients`) are accepted, empty list ⇒ fail-closed.

The allow-list is re-read from disk on **every handshake** (handshakes are rare),
so `authorize_client!`/`revoke_client!` take effect live — no gate restart. Note
ZAP only gates *new* handshakes: a revoked client that is already connected stays
connected until it (re)connects (ZMQ exposes no per-peer disconnect).

Must be started BEFORE the CURVE-server sockets bind.
"""
function _start_zap_handler!(ctx::ZMQ.Context; allow_any::Bool=false)
    zap = ZMQ.Socket(ctx, ZMQ.REP)
    ZMQ.bind(zap, _ZAP_ENDPOINT)
    zap.rcvtimeo = 250
    zap.linger = 0
    _ZAP_SOCKET[] = zap
    _ZAP_TASK[] = Threads.@spawn :interactive begin
        try
            while _RUNNING[]
                frames = try
                    ZMQ.recv_multipart(zap, Vector{UInt8})
                catch e
                    e isa ZMQ.TimeoutError && continue   # re-check _RUNNING
                    _RUNNING[] || break
                    @debug "ZAP recv error" exception = e
                    continue
                end
                try
                    # Re-read the allow-list each handshake so authorize/revoke
                    # apply without restarting the gate (handshakes are rare).
                    allow = allow_any ? Set{String}() : _authorized_clients()
                    _handle_zap_request(zap, frames, allow, allow_any)
                catch e
                    @debug "ZAP handler error" exception = e
                end
            end
        finally
            try; close(zap); catch; end
            _ZAP_SOCKET[] = nothing
        end
    end
    return _ZAP_TASK[]
end

# ── Public subscriber helper (CURVE-aware) ─────────────────────────────────────

"""
    subscribe(endpoint; topic="", serverkey=nothing, clientkey=nothing, ctx=Context()) -> ZMQ.Socket

Open a SUB socket connected to a gate PUB `endpoint` (`tcp://…` or `ipc://…`),
filtering on `topic` (prefix-matched against the first frame). For a non-Kaimon
consumer (e.g. a TachiRei ghost) to observe a `publish`ed stream.

If `serverkey` (Z85 server public key) is given, the socket is CURVE-secured and
pinned to that server, presenting `clientkey=(public, secret)` if supplied — a
per-ghost key that must be enrolled in the server's allow-list — otherwise an
ephemeral keypair (which only works under `allow_any`). The caller `recv`s framed
messages (`publish` sends 2-frame `[topic, payload]`) and `close`s when done.
"""
function subscribe(endpoint::AbstractString; topic::AbstractString = "",
                   serverkey::Union{AbstractString,Nothing} = nothing,
                   clientkey::Union{Tuple,Nothing} = nothing,
                   ctx::ZMQ.Context = ZMQ.Context())
    sub = ZMQ.Socket(ctx, ZMQ.SUB)
    sub.rcvhwm = 0
    sub.linger = 0
    if serverkey !== nothing
        cpub, csec = clientkey === nothing ? curve_keypair() :
                     (String(clientkey[1]), String(clientkey[2]))
        make_curve_client!(sub, serverkey, cpub, csec)
    end
    ZMQ.subscribe(sub, topic)
    ZMQ.connect(sub, endpoint)
    return sub
end

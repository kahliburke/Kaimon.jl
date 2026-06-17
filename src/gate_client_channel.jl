# (Kaimon gate client — split into gate_client_*.jl files; this one loads FIRST)
# ═══════════════════════════════════════════════════════════════════════════════
# Gate Client — TUI-side connection manager for REPL gate sockets
#
# Discovers gate sockets in ~/.cache/kaimon/sock/, connects via ZMQ REQ,
# sends eval requests, handles reconnection and health checks.
# ═══════════════════════════════════════════════════════════════════════════════

# ZMQ, Serialization, Dates, JSON are available from the Kaimon module scope.

# Thread-safe recv: uses recv(sock, Vector{UInt8}) which avoids creating
# Message objects with finalizers. See gate.jl header comment for rationale.
function _zmq_recv(sock::ZMQ.Socket)::Vector{UInt8}
    return recv(sock, Vector{UInt8})
end

# Thread-safe socket *construction*. ZMQ.jl appends every new Socket to its
# Context's `sockets::Vector{WeakRef}` with an UNLOCKED `push!` (ZMQ.jl
# socket.jl). Kaimon still constructs sockets on the shared `mgr.zmq_context`
# from several threads at once — parallel connects (DEALER + SUB per connection),
# health pings, the event PUB — so those `push!`es can still race. A racing push!
# reallocates the backing Memory and frees the old buffer while GC scans that
# WeakRef array → use-after-free surfacing as `gc_sweep_pool` heap corruption.
# One process-wide lock around construction closes the window. (Protocol v2
# retired the per-request ephemeral REQ that drove this at request rate; the
# remaining per-connection construction is rare but still guarded here.)
const _ZMQ_SOCKET_LOCK = ReentrantLock()

# ZMQ.jl appends a WeakRef to `ctx.sockets` on every Socket construction and NEVER
# removes it on close, so under connection churn that array grows without bound
# (it exists only so close(ctx) can shut live sockets before zmq_ctx_term). While
# we hold the construction lock — which serializes every push! onto this context,
# since all construction here goes through `_zmq_socket` — compact away the
# already-dead (GC-collected) entries so the array stays ~live-socket-sized.
# Only `value === nothing` weakrefs are dropped, so no live socket is ever
# removed and close(ctx) still sees every live one. Best-effort + guarded: it
# reaches one ZMQ.jl internal (`getfield(ctx, :sockets)`), and only runs while
# the lock is held (so it can't race a concurrent push!; close(ctx) on a context
# only happens at shutdown/reap, when no construction is in flight on it).
function _prune_dead_ctx_sockets!(ctx::ZMQ.Context)
    sk = try
        getfield(ctx, :sockets)
    catch
        return nothing
    end
    sk isa AbstractVector || return nothing
    length(sk) < 64 && return nothing      # only pay the O(n) pass once it's grown
    filter!(w -> (w isa WeakRef ? w.value !== nothing : true), sk)
    return nothing
end

_zmq_socket(ctx::ZMQ.Context, typ) = lock(_ZMQ_SOCKET_LOCK) do
    _prune_dead_ctx_sockets!(ctx)
    Socket(ctx, typ)
end

# ── Request channel (protocol v2: persistent DEALER, correlation-id muxed) ──────
# One DEALER per connection replaces the old per-request ephemeral REQ. Creating
# a fresh REQ for every request grew ZMQ's per-Context `sockets::Vector{WeakRef}`
# without bound (ZMQ.jl never removes a socket's weakref on close) and raced
# socket construction across threads — the source of the intermittent
# `gc_sweep_pool` heap corruption. The DEALER is created ONCE in connect!; all
# requests multiplex over it, demuxed by an 8-byte correlation id the gate echoes
# back. Strict ownership: exactly one task (the sender) `send`s and one task (the
# reader) `recv`s the socket — no other code touches it.
#
# Wire framing — client→gate: [corr_id (8 bytes), payload]; gate→client (ROUTER
# strips its identity frame): [corr_id, reply].
mutable struct RequestChannel
    dealer::ZMQ.Socket
    endpoint::String
    send_q::Channel{Tuple{UInt64,Vector{UInt8}}}  # (corr_id, payload) → sender task
    pending::Dict{UInt64,Channel{Any}}            # corr_id → reply inbox
    pending_lock::ReentrantLock
    counter::Threads.Atomic{UInt64}               # corr_id minting
    reader::Union{Task,Nothing}
    sender::Union{Task,Nothing}
    alive::Ref{Bool}
end

# corr_id ↔ 8 bytes (little-endian, explicit so it's arch-independent on the
# wire — though the gate treats the id as opaque bytes and only echoes it back).
function _corr_bytes(id::UInt64)
    b = Vector{UInt8}(undef, 8)
    @inbounds for i in 1:8
        b[i] = (id >> (8 * (i - 1))) % UInt8
    end
    return b
end
function _corr_from_bytes(b::AbstractVector{UInt8})
    id = UInt64(0)
    @inbounds for i in 1:8
        id |= UInt64(b[i]) << (8 * (i - 1))
    end
    return id
end

# Deliver a reply to its waiting caller; drop replies for unknown/timed-out
# correlation ids (the caller already gave up and unregistered).
function _rc_route_reply!(rc::RequestChannel, corr_id::UInt64, payload::Vector{UInt8})
    inbox = lock(rc.pending_lock) do
        get(rc.pending, corr_id, nothing)
    end
    inbox === nothing && return
    try
        put!(inbox, payload)
    catch
        # inbox closed (caller timed out / disconnected) — drop
    end
    return nothing
end

# Sole writer of the DEALER. Drains the send queue until it's closed.
function _rc_sender(rc::RequestChannel)
    try
        for (corr_id, payload) in rc.send_q
            rc.alive[] || break
            try
                send(rc.dealer, _corr_bytes(corr_id); more = true)
                send(rc.dealer, payload)
            catch e
                # Send failed — fail this caller fast instead of leaving it to
                # time out; the rest of the queue continues.
                _rc_route_reply!(rc, corr_id, UInt8[])  # empty → caller sees deser error
                @debug "RequestChannel send failed" exception = e
            end
        end
    catch
        # send_q closed during shutdown — exit
    end
end

# Sole reader of the DEALER. Owns the socket's close so no other task closes it
# out from under an in-flight recv (the classic ZMQ use-after-free).
function _rc_reader(rc::RequestChannel)
    sock = rc.dealer
    try
        while rc.alive[]
            local corr_b
            try
                corr_b = _zmq_recv(sock)          # corr_id frame (rcvtimeo-bounded)
            catch e
                e isa ZMQ.TimeoutError && continue
                rc.alive[] || break
                (e isa ZMQ.StateError || e isa EOFError) && break
                sleep(0.01)
                continue
            end
            payload = UInt8[]
            try
                if sock.rcvmore
                    payload = _zmq_recv(sock)
                    while sock.rcvmore                # drain any unexpected extra frames
                        _zmq_recv(sock)
                    end
                end
            catch
                continue
            end
            length(corr_b) == 8 || continue
            _rc_route_reply!(rc, _corr_from_bytes(corr_b), payload)
        end
    finally
        # The owning task closes the socket — never disconnect!/another task.
        try
            close(sock)
        catch
        end
    end
end

"""Build a DEALER request channel on `ctx`, connected to `endpoint`, and start
its reader+sender tasks. `curve!` applies CURVE to the socket once before connect
(a no-op for plain IPC/TCP)."""
function RequestChannel(ctx::ZMQ.Context, endpoint::String; curve!::Function = identity)
    dealer = _zmq_socket(ctx, DEALER)
    dealer.linger = 0       # don't block close; drop unsent on a dead peer
    dealer.rcvtimeo = 200   # reader poll cadence so it can notice alive=false
    dealer.sndtimeo = 2000  # bound a send on a full buffer
    dealer.sndhwm = 1000    # cap queued-to-dead-peer growth
    curve!(dealer)          # CURVE applied ONCE per connection (not per request)
    connect(dealer, endpoint)
    rc = RequestChannel(
        dealer,
        endpoint,
        Channel{Tuple{UInt64,Vector{UInt8}}}(Inf),
        Dict{UInt64,Channel{Any}}(),
        ReentrantLock(),
        Threads.Atomic{UInt64}(0),
        nothing,
        nothing,
        Ref(true),
    )
    rc.sender = Threads.@spawn _rc_sender(rc)
    rc.reader = Threads.@spawn _rc_reader(rc)
    return rc
end

"""Tear down a request channel: stop the reader/sender, fail every pending caller
so they return immediately instead of waiting out their timeout, and let the
reader close the DEALER. Safe to call more than once."""
function _close_request_channel!(rc::RequestChannel)
    rc.alive[] = false
    try
        close(rc.send_q)   # unblocks the sender's `for … in send_q`
    catch
    end
    lock(rc.pending_lock) do
        for (_, inbox) in rc.pending
            try
                close(inbox)
            catch
            end
        end
        empty!(rc.pending)
    end
    # Wait briefly for the reader to notice (rcvtimeo ~200ms) and close the
    # DEALER itself — its owning task must be the one to close it.
    rd = rc.reader
    if rd !== nothing
        deadline = time() + 1.0
        while !istaskdone(rd) && time() < deadline
            sleep(0.02)
        end
    end
    return nothing
end


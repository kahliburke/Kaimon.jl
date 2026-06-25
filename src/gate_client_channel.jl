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

# ── Deserialization probe (heap-corruption forensics) ──────────────────────────
# `Serialization.deserialize` is the only heap-unsafe operation in our code: a
# malformed / version-skewed wire payload makes it read a bogus length and
# allocate/write via the system malloc, corrupting the heap (surfaces LATER as an
# `_xzm_xzone_malloc_freelist` SIGTRAP in an unrelated alloc — the latent crash).
# This wrapper does NOT make deserialize safe; it gates obviously-bad frames and
# captures evidence so the next occurrence names the culprit instead of vanishing.
#
# - Refuses (throws) frames larger than the sanity cap before touching deserialize.
# - On any deserialize failure, logs the label + length + first bytes (hex) — the
#   call-site catch blocks otherwise swallow this and we lose the payload.
# - `KAIMON_TRACE_DESERIALIZE=1` pre-logs every payload's (label,len,head) BEFORE
#   deserializing, so after a crash the last line names the offending payload.
const _DESER_MAX_BYTES = Ref{Int}(
    something(tryparse(Int, get(ENV, "KAIMON_MAX_DESERIALIZE_BYTES", "")), 64 * 1024 * 1024))
_deser_trace() = get(ENV, "KAIMON_TRACE_DESERIALIZE", "") in ("1", "true", "yes", "on")

_hexhead(bytes::AbstractVector{UInt8}, n::Int = 32) =
    join((string(b; base = 16, pad = 2) for b in @view bytes[1:min(n, length(bytes))]), "")

function _safe_deserialize(raw::AbstractVector{UInt8}; label::AbstractString = "")
    n = length(raw)
    if n > _DESER_MAX_BYTES[]
        @warn "Refusing oversized deserialize payload (likely a corrupt/torn frame)" label len=n cap=_DESER_MAX_BYTES[] head=_hexhead(raw)
        error("deserialize payload too large: $n bytes (cap $(_DESER_MAX_BYTES[])) [$label]")
    end
    _deser_trace() && @info "deserialize" label len=n head=_hexhead(raw)
    try
        return deserialize(IOBuffer(raw))
    catch e
        # Lean log (no backtrace) — the payload head + error type is the evidence,
        # and some callers fall back to treating `data` as a plain string normally.
        @warn "deserialize failed — captured payload for forensics" label len=n head=_hexhead(raw) err=sprint(showerror, e)
        rethrow(e)
    end
end
# Accept anything Vector{UInt8}-convertible (callers pass String data / SubArrays).
_safe_deserialize(raw; label::AbstractString = "") = _safe_deserialize(Vector{UInt8}(raw); label = label)

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
#
# Prune on EVERY construction once the array is non-trivial (not just past a large
# threshold). Reconnect churn (each cycle closes a DEALER+SUB) otherwise piled up
# ~50 dead weakrefs and the array kept growing — 25 reconnects → 53 entries, which
# is exactly the gc_sweep_pool setup: a `push!` that has to reallocate the backing
# buffer while GC is scanning the WeakRef array → use-after-free. Keeping it
# ≈ live-socket count (the filter! drops the GC-collected dead ones each time)
# minimizes how often that buffer reallocates AND shrinks the scanned array. The
# pass is O(n) over a now-small n, so it's cheap to run every time.
const _CTX_SOCKETS_PRUNE_MIN = 4
function _prune_dead_ctx_sockets!(ctx::ZMQ.Context)
    sk = try
        getfield(ctx, :sockets)
    catch
        return nothing
    end
    sk isa AbstractVector || return nothing
    length(sk) < _CTX_SOCKETS_PRUNE_MIN && return nothing  # skip trivially small arrays
    filter!(w -> (w isa WeakRef ? w.value !== nothing : true), sk)
    return nothing
end

_zmq_socket(ctx::ZMQ.Context, typ) = lock(_ZMQ_SOCKET_LOCK) do
    _prune_dead_ctx_sockets!(ctx)
    Socket(ctx, typ)
end

# Close a socket AND remove its OWN WeakRef from the owning context's `sockets`
# array — so no dead entry is ever left behind (the lazy prune above is only a
# backstop for sockets closed elsewhere, e.g. a GC finalizer or close(ctx)).
# ZMQ.jl push!es a WeakRef per Socket at construction but never removes it on
# close (that array exists only so close(ctx) can reap live sockets before
# zmq_ctx_term; WeakRefs keep it from pinning sockets alive). So `close(sock)`
# alone leaks the wrapper, and under churn the array grows until its backing
# buffer reallocates WHILE GC scans it → the gc_sweep_pool use-after-free. We hold
# a live ref to `sock` here, so its weakref is findable by identity (`w.value ===
# sock`) and dropped precisely — no waiting for GC. Under _ZMQ_SOCKET_LOCK so it
# can't race a push! (construction) or another close; callers keep whatever
# socket-level lock (req_lock / sock_lock / event_pub_lock) already guards this
# socket's recv/send. ALWAYS prefer this over a bare `close(sock)` on a context
# socket. Lock order is always {socket lock} → _ZMQ_SOCKET_LOCK (construction only
# takes the latter), so no deadlock.
function _zmq_close!(sock::ZMQ.Socket)
    ctx = try getfield(sock, :context) catch; nothing end
    lock(_ZMQ_SOCKET_LOCK) do
        try; close(sock); catch; end
        ctx === nothing && return
        sk = try getfield(ctx, :sockets) catch; return end
        sk isa AbstractVector || return
        filter!(w -> (w isa WeakRef ? (w.value !== nothing && w.value !== sock) : true), sk)
    end
    return nothing
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
    reader_fdw::Union{FileWatching.FDWatcher,Nothing}  # persistent watcher on the DEALER fd (reader-owned)
    # libzmq sockets are NOT thread-safe across concurrent ops. The sender (send)
    # and reader (getsockopt EVENTS + recv) run on different default-pool threads
    # and touch this one DEALER — without serialization that races inside libzmq and
    # corrupts the heap (latent gc_sweep_pool SIGSEGV under load). This mutex makes
    # all socket access mutually exclusive AND supplies the full memory barrier
    # libzmq requires to use a socket from more than one thread. wait(fdw) parks
    # OUTSIDE the lock (it's a libuv fd poll, not a socket op).
    sock_lock::ReentrantLock
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

# Skip-sentinel enqueued by `_await_inbox`'s deadline timer to wake a blocked
# `take!` WITHOUT closing the channel (closing would abort a still-live stream).
const _INBOX_TIMEOUT = :__kaimon_inbox_timeout__

"""
    _await_inbox(inbox::Channel, deadline::Float64) -> item | nothing

Block for the next item from a reply/stream `inbox`, up to absolute `deadline`
(`time()` seconds). Returns the item, or `nothing` on deadline or a closed inbox
(disconnect/teardown).

Event-driven replacement for the old `isready`+`sleep` busy-poll: it parks on
`take!` (zero CPU) and is woken only by a real `put!`, by `close(inbox)`
(disconnect), or by the deadline timer. The timer enqueues a skip-sentinel rather
than closing, so it is **non-destructive and lossless** — a live stream inbox
keeps its buffered messages and stays open across many `_await_inbox` calls. Real
messages return immediately (the `isready` fast path also avoids a timer when
items are already buffered), preserving stream latency.
"""
function _await_inbox(inbox::Channel, deadline::Float64)
    isready(inbox) && return take!(inbox)            # fast path: already buffered
    remaining = deadline - time()
    remaining > 0 || return nothing
    timer = Timer(_ -> (try; put!(inbox, _INBOX_TIMEOUT); catch; end), remaining)
    try
        v = take!(inbox)
        return v === _INBOX_TIMEOUT ? nothing : v
    catch
        return nothing                               # inbox closed → disconnect/teardown
    finally
        close(timer)
    end
end

# Sole writer of the DEALER. Drains the send queue until it's closed.
function _rc_sender(rc::RequestChannel)
    try
        for (corr_id, payload) in rc.send_q
            rc.alive[] || break
            try
                lock(rc.sock_lock) do
                    send(rc.dealer, _corr_bytes(corr_id); more = true)
                    send(rc.dealer, payload)
                end
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

# Read EVENTS under the socket lock (getsockopt must not race the sender's send()).
_rc_pollin(rc, sock) = lock(rc.sock_lock) do
    try (sock.events & ZMQ.POLLIN) != 0 catch; false end
end

# Sole reader of the DEALER. Owns the socket's close so no other task closes it
# out from under an in-flight recv (the classic ZMQ use-after-free).
function _rc_reader(rc::RequestChannel)
    sock = rc.dealer
    fd = try Cint(sock.fd) catch; Cint(-1) end  # stable for the socket's lifetime
    # ONE persistent FDWatcher for the socket's whole life. `poll_fd` constructed
    # AND closed a fresh _FDWatcher on every wake — at N connected gates × 5Hz that
    # was continuous watcher create/close churn + the scheduler load it generated
    # (a measurable slice of idle host CPU). Here we build the watcher once and
    # block on it; disconnect closes it (see _close_request_channel!), which wakes
    # the wait immediately so teardown no longer waits out a poll timeout. The
    # reader is the sole owner/closer of the socket, so watching its own fd is
    # safe (#51).
    fdw = nothing
    if fd >= 0
        fdw = try FileWatching.FDWatcher(RawFD(fd), true, false) catch; nothing end
        rc.reader_fdw = fdw
    end
    try
        while rc.alive[]
            # Park (event-driven, zero idle CPU) on the watcher until the DEALER is
            # readable, or it's closed on disconnect. When NOT readable we always
            # wait — this is the guard against a busy spin. ALL socket touches
            # (EVENTS read, recv) go under sock_lock so they never race the sender's
            # send() on another thread (libzmq sockets aren't thread-safe);
            # wait(fdw) stays OUTSIDE the lock (it's a libuv fd poll, not a socket op).
            if fdw !== nothing && !_rc_pollin(rc, sock)
                try
                    wait(fdw)
                catch
                    # watcher closed (disconnect/teardown) or fd invalid
                end
                rc.alive[] || break
                _rc_pollin(rc, sock) || continue
            end
            # Recv ONE reply (corr_id + payload) under the lock. Readable ⇒ recv
            # won't block; a spurious wake costs at most one rcvtimeo before TimeoutError.
            msg = lock(rc.sock_lock) do
                local corr_b
                try
                    corr_b = _zmq_recv(sock)
                catch e
                    e isa ZMQ.TimeoutError && return :none
                    (e isa ZMQ.StateError || e isa EOFError) && return :dead
                    return :none
                end
                payload = UInt8[]
                try
                    if sock.rcvmore
                        payload = _zmq_recv(sock)
                        while sock.rcvmore                # drain any extra frames
                            _zmq_recv(sock)
                        end
                    end
                catch
                    return :none
                end
                return (corr_b, payload)
            end
            msg === :dead && break
            msg === :none && continue
            corr_b, payload = msg
            length(corr_b) == 8 && _rc_route_reply!(rc, _corr_from_bytes(corr_b), payload)
        end
    finally
        rc.reader_fdw = nothing
        fdw === nothing || (try; close(fdw); catch; end)
        # The owning task closes the socket — never disconnect!/another task. Take
        # sock_lock so a send() in flight on the sender thread can't race the close;
        # _zmq_close! also drops the socket's weakref from ctx.sockets.
        lock(rc.sock_lock) do
            _zmq_close!(sock)
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
        nothing,   # reader_fdw — created by _rc_reader
        ReentrantLock(),  # sock_lock — serializes DEALER access across sender/reader threads
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
    # Wake the reader if it's parked on its persistent FDWatcher — closing the
    # watcher makes its `wait` return, so the reader observes alive=false and tears
    # down immediately instead of waiting out a poll timeout.
    let fdw = rc.reader_fdw
        fdw === nothing || (try; close(fdw); catch; end)
    end
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


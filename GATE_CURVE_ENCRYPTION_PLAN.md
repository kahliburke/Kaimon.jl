# Gate CURVE Encryption — Plan

**Branch:** `gate-curve-encryption-20` (on top of `agent-session-service-20`)
**Status:** plan for review — no code written yet.
**Driver:** TachiRei.jl locks in *"Transport: TCP + CURVE from v1"* (encrypted +
authenticated). TachiRei is **glue** over Kaimon's gate, not a rebuild — so CURVE
belongs in Kaimon's existing TCP gate transport. TachiRei then inherits an
encrypted link for free.

---

## 1. Scope

CURVE applies **only to the TCP gate transport** (cross-machine). It does *not*
touch:
- The **IPC service endpoint** (`src/service_endpoint.jl`, ROUTER over `ipc://`) —
  local-only, no network exposure.
- IPC gate mode (`ipc://` REP/PUB) — local socket files, OS permissions already
  gate access.

The two ends that go encrypted:

| End | File | Sockets |
|---|---|---|
| **Gate (server)** | `lib/KaimonGate/src/gate.jl` `serve()` | REP (`:2136`), PUB stream (`:2185`) |
| **Client** | `src/gate_client.jl` `connect_tcp!` | REQ (`:881`), SUB (`:793`/`:892`), health-check REQ (`:995`) / SUB (`:1852`) |

---

## 2. What CURVE gives us (and what ZAP is)

**CURVE** (ZMTP's elliptic-curve mechanism, libsodium under the hood) provides
two things on a ZMQ socket:

1. **Encryption** of all traffic on the wire.
2. **Server authentication** — the client sets the server's public key
   (`CURVE_SERVERKEY`) before connecting; if the server doesn't hold the matching
   secret key, the handshake fails. This is what prevents MITM / impersonation.
   It is *our* "server pinning" (TOFU, SSH-host-key style — see §6).

**Key fact:** CURVE has **no in-band key exchange**. The client must already know
the server's public key before `connect`. There is no "accept and trust on first
handshake" at the protocol level — TOFU for us means *obtaining* the key
out-of-band once (cache file / banner / registration) and reusing it.

### ZAP — the ZeroMQ Authentication Protocol (RFC 27)

CURVE alone encrypts and lets the *client* authenticate the *server*. It does
**not**, by itself, let the *server* decide *which clients* may connect — any
client that completes a valid CURVE handshake is accepted. To restrict clients,
ZMQ uses **ZAP**:

- When a socket has `CURVE_SERVER=1`, libzmq, on each inbound handshake, sends an
  **authentication request** over an in-process socket bound at
  `inproc://zeromq.zap.01`.
- You run a **ZAP handler** — a normal REP socket on that endpoint, on a task in
  your own process. It receives the request frames (mechanism, domain, address,
  identity, and **the client's public key** for CURVE) and replies `200` (allow)
  or `400` (deny).
- **No ZAP handler bound** → libzmq allows any client that completes the CURVE
  handshake (encryption + server-auth only; no client allow-list).
- **ZAP handler bound** → you enforce an allow-list of client public keys (or any
  policy you like).

So the two client-authorization postures are:

| Posture | Encryption | Server auth (client pins server) | Client auth (server checks client) | Code |
|---|---|---|---|---|
| **A. Pin server, open clients** | ✅ | ✅ | ❌ (keep existing app-layer token) | small |
| **B. Allow-list via ZAP** | ✅ | ✅ | ✅ (client pubkey on allow-list) | + ZAP handler task + list mgmt + client-key distribution |

**Decision (Kahli): posture B for v1 — mutual auth.** The stronger security
statement is worth it and the cost is small. The ZAP handler itself is ~30–40
lines (a REP loop on `inproc://zeromq.zap.01` checking the client pubkey against a
`Set{String}`); the only real added work over A is *persistent client keys* + an
*allow-list source*, both cheap (§5). We still retain the existing `_AUTH_TOKEN`
app-layer check (`gate.jl:2141`) as defense-in-depth.

**Default when `curve=true`: fail-closed** — the allow-list is enforced and an
empty list means nobody connects. An `allow_any=true` flag opts back into posture
A (encryption + server pinning only) for testing / open mode.

---

## 3. ZMQ.jl API reality

ZMQ.jl (`yNY0H`) exposes the **raw** CURVE primitives but **no high-level
property accessors** (`sockprops` in `sockopts.jl:116` has no `curve_*` entries —
so `socket.curve_server = true` does **not** work). We set options via the raw
bindings:

- Constants (in `ZMQ.lib` / bindings): `ZMQ_CURVE_SERVER=47`,
  `ZMQ_CURVE_PUBLICKEY=48`, `ZMQ_CURVE_SECRETKEY=49`, `ZMQ_CURVE_SERVERKEY=50`,
  `ZMQ_ZAP_DOMAIN=55`, `ZMQ_MECHANISM=43`.
- Keygen: `zmq_curve_keypair(pub, sec)` → two 40-char **Z85** strings (41 bytes
  incl. NUL). Also `zmq_curve_public`, `zmq_z85_encode/decode`.

**Almost all of this is lightweight wrapper functions** — a single new
`lib/KaimonGate/src/gate_curve.jl` (`include`d into KaimonGate) holds the whole
surface. The only thing that *isn't* a function is threading the optional
`server_key` through existing connect signatures (§7) — mechanical edits, ~6
sites.

```julia
# crypto / socket (each wraps zmq_setsockopt with error checks; set BEFORE bind/connect)
_curve_keypair() -> (public::String, secret::String)   # zmq_curve_keypair, Z85 (40 bytes, no NUL)
_set_curve_server!(sock, secret_z85)                   # CURVE_SERVER=1 + CURVE_SECRETKEY
_set_curve_client!(sock, server_pub, pub, secret)      # CURVE_SERVERKEY + PUBLICKEY + SECRETKEY

# keystore (read/generate-once under ~/.cache/kaimon/curve/, 0600 on secrets)
_load_or_create_server_keypair() -> (public, secret)
_load_or_create_client_keypair() -> (public, secret)

# trust: TOFU server pinning + client allow-list (plain JSON files)
_pin_server!(host, port, pubkey) / _pinned_server(host, port) -> Union{String,Nothing}
_authorized_clients() -> Set{String}  / authorize_client!(pubkey)

# ZAP authorization handler (server side) — REP loop on inproc://zeromq.zap.01
_start_zap_handler!(ctx; allow_any::Bool) -> Task   # 200 if pubkey ∈ allow-list (or allow_any), else 400
```

The client side lives in `src/gate_client.jl`; it calls these KaimonGate helpers
(KaimonGate is a dep) so there's no duplicated FFI.

---

## 4. Activation model (decision: opt-in, default-on for rei)

Plain `:tcp` stays **byte-for-byte unchanged** (backward compat). CURVE is a new
opt-in:

- **Gate:** `serve(...; mode=:tcp, curve::Bool=false, ...)` (or `mode=:tcp_curve`).
  When on: generate/load the server keypair, set CURVE-server on REP + PUB before
  bind, print the server pubkey in the connect banner, write it to the session's
  cache JSON.
- **Client:** `connect_tcp!(mgr, host, port; server_key::Union{String,Nothing}=nothing, ...)`.
  When `server_key` is set (or discovered via TOFU store): generate an ephemeral
  client keypair, set CURVE-client on REQ + SUB before connect.
- **TachiRei:** always passes `curve=true` / a pinned `server_key` — rei is
  encrypted by default.

This keeps the blast radius to "new optional params + new code paths," with no
risk to the existing local-IPC and plain-TCP flows.

---

## 5. Key & trust storage

- **Server keypair:** `~/.cache/kaimon/curve/server_secret.key` (0600) +
  `server_public.key`. Generated on first `curve=true` serve, reused after.
  Runtime resolution (function, not const) — mirror `_gate_cache_dir()`.
- **Client keypair (persistent — required for B):** one keypair per Kaimon cache
  dir at `~/.cache/kaimon/curve/client_{public,secret}.key`, auto-generated once,
  so its pubkey is stable enough for a server to list.
- **Allow-list (server, B):** `~/.cache/kaimon/curve/authorized_clients.json` — an
  array of authorized client pubkeys, SSH-`authorized_keys` style. Pre-seedable;
  `authorize_client!(pubkey)` appends. Enforced when `curve=true` unless
  `allow_any=true`. Empty list = fail-closed (nobody connects).
- **Pinned server keys (TOFU):** `~/.cache/kaimon/curve/known_servers.json`
  mapping `host:port` → server pubkey. First connect: if no pin and a key was
  supplied/printed, store it; subsequent connects compare and **refuse on
  mismatch** (warn loudly — possible MITM), SSH-style.

---

## 6. TOFU flow (how the client gets the server key)

Because CURVE needs the key up front, "trust on first use" = obtaining it once
out-of-band:

1. **Local Kaimon-spawned gates:** the gate writes its pubkey into the session
   cache JSON; the parent reads it directly. Zero user friction.
2. **Manual / remote (`connect_tcp` tool, REST, registration):** the server
   pubkey is printed in the gate's connect banner; user supplies it once via the
   tool arg / `tcp_gates.json` `server_key` field. Pin stored thereafter.

---

## 7. Plumbing touch-points

- `serve()` signature + banner + session-cache JSON (add `curve`, `server_key`).
- `connect_tcp!` signature (`src/gate_client.jl:730`) + the four sockets.
- `connect_tcp_tool` (`src/tool_definitions.jl:592`) — add optional `server_key`.
- `/api/connect_tcp` REST (`src/MCPServer.jl:1801`) — accept `server_key`.
- `tcp_gates.json` schema — add `server_key` field; `_poll_tcp_gates!` passes it.
- `connect_tcp_to_active_manager` (`src/Kaimon.jl:1470`) — thread `server_key`.

All additive/optional → existing registrations keep working (plain TCP).

---

## 8. Tests (`test/` — extend gate / service tests)

1. **Round-trip:** CURVE gate + CURVE client exchange an eval/tool call over
   `tcp://127.0.0.1:0`; assert success.
2. **Server-auth:** client with **wrong** `server_key` fails to handshake
   (bounded by rcvtimeo, not a hang).
3. **No-leak / interop:** plain `:tcp` gate ↔ plain client still works (CURVE off
   path untouched); a CURVE client cannot talk to a plain gate and vice-versa.
4. **TOFU:** second connect with a mismatched pinned key is refused.
5. **ZAP allow-list:** client key off the allow-list → handshake denied (`400`);
   client on the list → allowed; `allow_any=true` → allowed regardless.

---

## 9. Build order

1. `gate_curve.jl` — crypto + keystore + TOFU + allow-list wrappers (§3, §5) +
   unit test for keygen/Z85 and the JSON stores.
2. Server side in `serve()` (REP + PUB CURVE-server), ZAP handler start, banner +
   cache JSON (§4 gate half, §2 fail-closed default).
3. Client side in `connect_tcp!` (4 sockets, persistent client key) + TOFU store
   (§4 client half, §6).
4. Tests: round-trip, server-auth, plain-TCP-unaffected, TOFU, ZAP allow-list
   (§8.1–8.5).
5. Plumbing: tool / REST / `tcp_gates.json` / registration (§7) — thread
   `server_key`.

---

## 10. Decisions (all settled)

- **Posture B** — mutual auth, fail-closed, `allow_any` escape hatch.
- **`curve=true` bool**, orthogonal to `mode`.
- **Persistent client keys.**
- **Demo topology: one keypair PER ghost** (rei agent feedback,
  `TachiRei.jl/docs/kaimon-curve-transport-plan.md`). Each rei is individually
  enrolled in the allow-list with its own keypair → per-ghost identity +
  individual revocation. The ZAP allow-list already supports this (a `Set` of
  client pubkeys); TachiRei owns per-ghost enrollment. So the client-side helpers
  (`subscribe`, `connect_tcp!`) must accept a **caller-supplied keypair**, not
  only an ephemeral one.

## 11. Part 2 — Observe channel API (required by TachiRei)

TachiRei publishes a TUI buffer snapshot on attach, then per-frame diffs, so
remote ghosts see the live screen. The gate already owns the PUB socket +
`_publish_stream` but exposes no public broadcast/subscribe API. Add both
(additive; the existing single-blob stdout/stderr/eval format is untouched):

- **`publish(topic, payload)`** — public wrapper broadcasting on the gate PUB
  socket. For prefix-filterable observe channels, publish as a **2-frame
  multipart `[topic, payload]`** (so a SUB can `subscribe(sub, "tui:")` and filter
  server-side) — either an opt-in multipart path in `_publish_stream` or a small
  dedicated send in `publish`. Keep the single-blob format for the existing
  stdout/stderr/eval streams so the Kaimon client (`drain_stream_messages!`) is
  unchanged.
- **`subscribe(endpoint; topic="", serverkey=nothing, clientkey=nothing, ctx)`**
  — CURVE-aware SUB helper for a non-Kaimon ghost: if `serverkey` given, secure
  with `make_curve_client!` (using `clientkey` if supplied — per-ghost key — else
  ephemeral), `subscribe(topic)`, `connect`. Mirrors the Kaimon client's existing
  SUB setup, packaged + CURVE-aware.
- Export `publish`, `subscribe` from KaimonGate.

## 12. Status

- **Step 1 — DONE, COMMITTED, TESTED.** `gate_curve.jl` (keygen, Z85, setsockopt
  helpers, keystore, TOFU pinning, allow-list, ZAP handler) + `test_curve.jl`.
  Confirmed the shipped libzmq has CURVE/libsodium support. (commit `bffa77f`)
- **Step 2 (server `serve()`) — DONE, auto-tested.** `serve(; curve, server_secret,
  allow_any, allowed_clients)` (env/toml resolution); CURVE-server on REP+PUB
  before bind; ZAP handler started unless `allow_any` (fail-closed); banner prints
  the server pubkey; pong carries `server_pubkey`; restart-replay carries
  `curve`/`allow_any`; `_cleanup` tears down ZAP + resets CURVE state.
- **Step 3 (client `connect_tcp!`) — DONE, compiles/loads.** `REPLConnection`
  gains `server_pubkey`; `connect_tcp!(; server_key)` resolves arg > env > pinned
  (TOFU); CURVE applied to REQ + both SUB sites via `_apply_curve_client!`
  (persistent client key); TOFU-pin after a successful pong. Plumbed through
  `connect_tcp` tool, `/api/connect_tcp` REST, `connect_tcp_to_active_manager`,
  and `tcp_gates.json` (`server_key` field).
- **Part 2 (observe channel) — DONE, auto-tested.** `publish(topic, payload)`
  (2-frame multipart) + CURVE-aware `subscribe(...)`; the Kaimon client's
  `drain_stream_messages!` skips multipart observe broadcasts via `rcvmore`.
- **Auto-test status:** KaimonGate suite 188/188 (incl. serve(curve=true) e2e,
  fail-closed/enroll allow-list, publish/subscribe over encrypted PUB); main
  Kaimon package compiles + loads clean.
- **Remaining: manual end-to-end** — a real CURVE gate ↔ the Kaimon TUI client,
  and a TachiRei ghost subscribing — before commit of steps 2/3/Part 2.

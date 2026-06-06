# Concurrent service channel + global API rate governor — SPEC

**Status:** spec for implementation. Authored by the Seaworthy side (Claude), 2026-06-05.
**Motivation:** Seaworthy is migrating its crew off `claude -p` onto Kaimon agent
sessions (`agent_open`/`agent_run` over `KaimonGate.call_tool`). That works per-call,
but two things block running a real *multi-agent mission* on the agent transport:

1. **The service channel serializes.** Every `call_tool` (and thus every crew agent
   turn) funnels through one REQ socket on the client and one REP loop on the server —
   so the crew's parallel quarters-thinking runs one-at-a-time.
2. **No API rate governance.** Once concurrency is unlocked, N crew turns will hammer
   the Anthropic API and trip per-account rate limits (429 / overloaded). We need
   backpressure and an adaptive rate that **self-tunes from observed errors**.

These are **one subsystem**: the worker pool that gives concurrency is also where
admission control (backpressure + rate) must live. Build them together — concurrency
first with the governor bolted on later leaves a window where a mission can 429-storm.

The external contract (`KaimonGate.call_tool(name, args) -> result`) must stay
**byte-identical** so Seaworthy's `_invoke_agent`/`_agent_run!` need no changes.

---

## 1. Current state (grounding)

**Client** — `lib/KaimonGate/src/gate.jl`:
- `_SERVICE_SOCKET` (`:2763`): a single shared ZMQ **REQ** socket, `_SERVICE_LOCK`
  (`:2764`) a ReentrantLock.
- `_connect_service!` (`:2773`): REQ → `ipc://…/kaimon-service.sock`,
  `rcvtimeo` raised (was 30s — the wedge fix), `sndtimeo=5000`, `linger=0`.
- `_service_request` (`:2793`): `lock(_SERVICE_LOCK) do … send; _zmq_recv … end`.
  Now resets `_SERVICE_SOCKET[]=nothing` on any send/recv exception (the wedge fix).
- `call_tool` (`:2856`): `_service_request((type=:tool_call, tool_name, args))`.
- **Serializes:** the lock + single REQ socket → all `call_tool` in a session are
  strictly one-at-a-time.

**Server** — `src/service_endpoint.jl`:
- `start_service_endpoint!` (`:29`): a single ZMQ **REP** socket (`:37`),
  `rcvtimeo=1000` (so the loop can poll `_SERVICE_RUNNING`), one `@async` loop (`:47`).
- Loop (`:48–74`): `recv → _dispatch_service(request) → send`. The handler runs
  **inline** (`:52`), so a 47s `agent_run` blocks the whole loop, and REP cannot `recv`
  the next request until it `send`s the current reply.
- **Serializes:** REP is strict send/recv; inline handler makes a slow turn block intake.

**Why central:** API limits are per-account and the agents are shared across consumers
(crew, Slate, direct). Only the Kaimon server sees *all* turns, their `usage`
(`AgentSession.usage` from `TurnEnded`), and their errors — so the governor must live
here, not in any one consumer.

**Constraint that shapes the design:** each agent is a `claude` **subprocess**; the API
call happens *inside* it. Kaimon governs by (a) how many turns it admits concurrently
and (b) reacting to rate errors the subprocesses surface (`AgentError` events / failed
turns) — not by intercepting the HTTP call.

---

## 2. Target architecture

```
                          ┌─────────────────── Kaimon server process ───────────────────┐
 session A (REQ)─┐        │  ROUTER ──recv──► dispatch ──► [admission: GOVERNOR] ──► worker│
 session A (REQ)─┼──ipc──►│    ▲                                   │ (concurrency+rate)    │
 session B (REQ)─┘        │    └──────────── outbox ◄──reply───────┘  handler(args)        │
                          │                          (usage/errors feed the governor)       │
                          └──────────────────────────────────────────────────────────────┘
```

- **Client:** per-call (or pooled) REQ sockets → no shared-socket serialization.
- **Server:** ROUTER + single socket-owner task + bounded worker pool.
- **Governor:** admission control in front of each worker — concurrency cap (backpressure)
  + adaptive token/request rate (AIMD on errors) + per-turn retry/backoff + token budget.

---

## 3. Server — `service_endpoint.jl` rework

Replace the REP socket + inline loop with a ROUTER socket, one owner task, and a worker
pool. **Only the owner task touches the socket** (ZMQ sockets aren't thread-safe; even
with `@async` cooperative tasks, do not `send`/`recv` the same socket from two tasks).

```julia
sock = Socket(ctx, ROUTER)
sock.rcvtimeo = 200          # poll cadence for _SERVICE_RUNNING
sock.sndtimeo = 5000
sock.linger   = 0
bind(sock, endpoint)

const _OUTBOX = Channel{Tuple{Vector{UInt8}, Vector{UInt8}}}(Inf)  # (identity, reply-bytes)

# Owner task: the ONLY toucher of `sock`. Interleaves recv (new requests) and
# draining the outbox (worker replies) so a slow handler never blocks intake.
@async begin
    while _SERVICE_RUNNING[]
        # 1. drain any ready replies (non-blocking)
        while isready(_OUTBOX)
            (identity, reply) = take!(_OUTBOX)
            send_multipart(sock, [identity, UInt8[], reply])   # ROUTER envelope
        end
        # 2. try to receive one request (rcvtimeo bounds the wait)
        msg = try recv_multipart(sock) catch e; _is_timeout(e) ? nothing : rethrow() end
        msg === nothing && continue
        identity, _empty, payload = msg            # ROUTER strips/needs the identity frame
        request = deserialize(IOBuffer(payload))
        # 3. hand off to a worker through the governor; DO NOT run inline.
        @async _serve_one(identity, request)       # _serve_one acquires admission, runs handler, push!(_OUTBOX, …)
    end
end
```

```julia
function _serve_one(identity, request)
    reply = try
        Governor.with_admission(request) do            # blocks until a slot+rate token is free
            response = Base.invokelatest(_dispatch_service, request)   # may retry inside on rate error
            (status = :ok, value = response.value)      # keep existing response shape
        end
    catch e
        (status = :error, message = sprint(showerror, e))
    end
    io = IOBuffer(); serialize(io, reply); put!(_OUTBOX, (identity, take!(io)))
end
```

Notes:
- `recv_multipart`/`send_multipart` = read/write the ROUTER `[identity, empty, payload]`
  frames (ZMQ.jl: loop `recv` while `sock.rcvmore`, or use the multipart helpers).
- The owner task **never** runs a handler — handlers run in `@async` workers, so a 47s
  turn doesn't stall intake. Workers return replies only via `_OUTBOX`.
- Keep the `(status, value|message)` response shape the client already parses
  (`gate.jl:2808–2829`) so the client side is unchanged.

---

## 4. Client — `gate.jl` `_service_request`

Drop the single shared socket + global lock. Each `call_tool` uses its **own** REQ
socket (per-call create/connect/recv/close, or a small checked-out pool). REQ↔ROUTER is
fine and a per-call socket is inherently concurrent *and* never wedges (fresh state every
time — supersedes the manual reset).

```julia
function _service_request(request)
    sock = Socket(_GATE_CONTEXT[], REQ)
    sock.rcvtimeo = SERVICE_RCV_TIMEOUT_MS[]   # ≥ max(admission wait + slowest turn); see §6
    sock.sndtimeo = 5000; sock.linger = 0
    connect(sock, "ipc://$(joinpath(sock_dir(),"kaimon-service.sock"))")
    try
        io = IOBuffer(); serialize(io, request); send(sock, take!(io))
        response = deserialize(IOBuffer(_zmq_recv(sock)))
        response.status == :error && error("Kaimon service error: $(response.message)")
        return response.value
    finally
        close(sock)
    end
end
```

- If per-call socket churn is a concern under load, use a small **pool** (checkout/return,
  grow to a cap) instead — but per-call is the simplest correct version and the ipc
  connect cost is negligible next to a multi-second turn.
- A pool size cap also acts as a *client-side* concurrency ceiling; the *authoritative*
  ceiling is the server governor (§5).

---

## 5. The governor (new — e.g. `src/rate_governor.jl`)

Central admission control every agent turn passes through. Three coupled controls + token
accounting. State behind one lock (or a dedicated task owning it).

### 5.1 Concurrency cap (backpressure)
- A semaphore of `max_concurrency` (default below). `with_admission` acquires before the
  handler, releases after. When full it **blocks** — backpressure flows back through the
  ROUTER worker → the client's pending `recv` → the crew waits. **Block, never drop.**

### 5.2 Adaptive request/token rate — AIMD
- A token bucket: capacity `B`, refill `R` tokens/sec. Each turn acquires 1 (or
  `est_tokens`, see 5.4) before dispatch; blocks if empty.
- `R` is **adaptive (AIMD)**:
  - **On a rate-limit signal** (see §5.3): `R = max(R_min, R * 0.5)` and **pause**
    refills for `retry_after` (if known) else a base cooldown. Multiplicative decrease.
  - **On a clean window** (no rate error for `recover_interval`): `R = min(R_max,
    R + R_step)`. Additive increase.
- This self-tunes to the account's true limit without us hard-coding it.

### 5.3 Detecting rate-limit signals
The handler runs a `claude` subprocess; a 429/overloaded surfaces as an `AgentError`
event or a failed turn. The governor needs a classifier:
- `is_rate_limited(err)`: match `AgentError.message`/turn output for `429`,
  `rate_limit`, `overloaded`, `rate_limit_error`, Anthropic `type: "overloaded_error"`,
  etc. **Please confirm the exact strings the `claude` CLI emits and pin them here.**
- If the CLI exposes `retry-after` / `anthropic-ratelimit-*` headers anywhere in its
  output/events, parse and honor them (sets the pause duration + can seed `R`).

### 5.4 Per-turn retry/backoff
- A turn classified rate-limited retries with **exponential backoff + jitter**
  (`base=1s`, `×2`, `cap=60s`, honor `retry_after` if present), up to `max_retries`
  (default 4). Only after exhausting does it surface as an error to the caller.
- Retries re-acquire admission (so a backed-off turn doesn't hold a slot while sleeping).

### 5.5 Token-budget accounting
- Feed `TurnEnded.usage` (input/output tokens) back into the governor to track a
  **tokens-per-minute** budget (the real Anthropic limit), not just requests/min. If the
  rolling tokens/min approaches `token_budget`, throttle admission (treat like an empty
  bucket). Use observed `usage` to refine `est_tokens` per model for 5.2 pre-admission.

### 5.6 Config (env, with defaults; mirror `ARIADNE_OLLAMA_CONCURRENCY` style)
| Var | Default | Meaning |
|---|---|---|
| `KAIMON_AGENT_MAX_CONCURRENCY` | 4 | in-flight turns ceiling (backpressure) |
| `KAIMON_AGENT_RATE_RPS` | 2.0 | initial/refill request rate `R` |
| `KAIMON_AGENT_RATE_MAX` | 8.0 | `R_max` ceiling for AIMD recovery |
| `KAIMON_AGENT_RATE_MIN` | 0.25 | `R_min` floor |
| `KAIMON_AGENT_TOKENS_PER_MIN` | (account-dependent) | token budget; 0 = disabled |
| `KAIMON_AGENT_MAX_RETRIES` | 4 | per-turn rate-error retries |
| `KAIMON_AGENT_RECOVER_INTERVAL_S` | 20 | clean window before additive increase |

Keep defaults conservative; AIMD will discover the real ceiling.

---

## 6. Backpressure ↔ client timeout interaction

A `call_tool` now waits for **admission + turn**. So the client REQ `rcvtimeo` must
exceed the worst case (admission wait + slowest turn + retries). Options:
- Set `SERVICE_RCV_TIMEOUT_MS` generously (e.g. ≥ 660s, covering `agent_run`'s 600s + slack), or
- have the server send an early `:accepted` ack and stream the result later (bigger; not
  needed for v1).
For v1: generous client `rcvtimeo` + the per-call socket (which can't wedge). A turn that
truly exceeds it fails that one call cleanly (fresh socket next time).

---

## 7. Observability (cheap, high-value)
Expose governor state for a Console/TUI readout and debugging — a tool, e.g.
`agent_governor_status() -> Dict`: `in_flight`, `max_concurrency`, current `R`,
`tokens_per_min` (rolling), `throttled` (bool), `recent_rate_errors`, `queue_depth`.
Seaworthy will surface this in the Console so the Captain can watch backpressure live.

---

## 8. Sign-off tests
1. **Concurrency restored:** fire K simultaneous `call_tool` agent turns from one session;
   confirm they overlap (wall-clock ≈ slowest, not sum) up to `max_concurrency`.
2. **Backpressure blocks, not drops:** with `max_concurrency=2`, fire 6; confirm all 6
   complete, ≤2 ever in flight, none error.
3. **Adaptive rate on 429:** force/observe a rate-limit error; confirm `R` drops, refills
   pause for `retry_after`, the turn retries+succeeds, and `R` recovers over a clean window.
4. **Token budget:** with a low `KAIMON_AGENT_TOKENS_PER_MIN`, confirm admission throttles
   as rolling tokens/min approaches it.
5. **Long turn still clean:** the prior sign-off (a >30s `agent_run` returns + the socket
   survives) still holds.
6. **Contract unchanged:** `call_tool(name,args)` return shape identical; Seaworthy's
   `_agent_run!` works untouched.

---

## 9. Out of scope (Seaworthy side, noted for completeness)
- Seaworthy must treat a long admission wait as normal (a hail that blocks is *not* a
  failure) — already true (synchronous `call_tool`).
- Seaworthy will add a Console readout of `agent_governor_status()` (its own work).
- The per-mission `improvement_rounds`/round budgets remain a *second*, coarser cap on
  total work; the governor is the fine-grained API-rate layer beneath it.

---

## 10. §5.3 — RESOLVED (Kaimon side), with build-order revision

Traced the rate-limit signal through the Kaimon agent backend. **The signal the
governor's `is_rate_limited(err)` needs is not currently available — it is discarded
before it ever becomes an event.** Findings (authoritative, from the code):

1. **It's the Claude Code CLI, not an ACP bridge.** `_claude_args` (`src/agent_backend.jl:88`)
   spawns `claude -p --input-format stream-json --output-format stream-json --verbose`.
   Events are the Claude Code stream-json schema (`system`/`assistant`/`user`/`stream_event`/
   `result`/`control_response`), parsed in `_map_claude_event`.
2. **stderr → log file, never parsed.** `open(pipeline(cmd; stderr = log_io), "r+")`
   (`agent_backend.jl:135`): CLI error text lands only in `~/.cache/kaimon/agents/<id>.log`,
   invisible to the event stream.
3. **The `result` handler keeps only `stop_reason`/`is_error`/`usage`, drops the body**
   (`agent_backend.jl:322–328`). The CLI's `result` carries `subtype`
   (`error_during_execution`/`error_max_turns`/…), `is_error`, and a `result` text field —
   none are read. The CLI emits no top-level `stop_reason`, so **every** errored turn
   collapses to `TurnEnded(:refusal, usage)` with **no message**.
4. **`AgentError` is never emitted for API errors** — only for stream-json parse failures
   (`:153`), reader-task crashes (`:161`), and `control_response`/interrupt errors (`:335`).
   A 429/overloaded is none of these.
5. **`retry-after` / `anthropic-ratelimit-*` headers are unavailable.** The CLI doesn't
   surface HTTP headers in stream-json, and it **retries transient 429s internally** — it
   only emits a failed `result` once it has *given up*, by which point the headers are gone.

**Prerequisite work item (new):** before §5.2/§5.3/§5.4 can function, change
`_map_claude_event`'s `result` branch (`agent_backend.jl:322`) to capture `subtype` +
`is_error` + the `result`/error text into `TurnEnded` (add a field) or a parallel
`AgentError`; optionally tail the stderr log on `is_error` to recover the API error string
(`overloaded_error`, `rate_limit_error`, `429`).

**Consequences for §5.4:** Kaimon retry would stack on the CLI's own internal 429 retry
(double-backoff), and is not cheap — the turn is already over when the failed `result`
arrives, so "retry" = re-sending the user turn via `backend_send`, a full turn re-do
(re-burns input tokens, may re-run tool calls). And because the CLI swallows transient
429s, the signal Kaimon mostly observes is **latency** (turns get slower), not discrete
error events.

**Build-order revision — re-tier the governor by grounding:**
- **Phase 1 (fully grounded, ship first):** §3 ROUTER/worker pool, §4 per-call REQ client,
  §5.1 concurrency-cap backpressure, **§5.5 token budget** — `TurnEnded.usage` *is*
  reliably captured (`_claude_usage`, `agent_backend.jl:324`) and `UsageUpdated` streams
  running usage. Concurrency cap + token budget are the primary, dependable levers.
- **Phase 2 (gated on the error-capture prerequisite above):** §5.2/§5.3/§5.4 AIMD-on-error
  + retry/backoff, and §7 `agent_governor_status` observability. Treat as refinements, not
  the centerpiece.

**Agreed scope for a first run (Seaworthy ↔ Kaimon, 2026-06-05):** Phase 1 alone unblocks
a real multi-agent mission. Two items stay on Kaimon's side but **do not block a run**:
- **§7 `agent_governor_status`** (observability readout) — until it lands, Seaworthy
  watches backpressure *via timing* (turn latency) rather than a live readout.
- **The latency-AIMD layer (§5.2/§5.3/§5.4, §10)** — Phase 2. A mission runs on the
  concurrency cap + token budget without it; AIMD is a self-tuning refinement layered on
  later (and, per §10, the signal it needs is mostly latency, not discrete error events).

**§3 technical notes:**
- The worker pool is cooperative `@async`, not parallel — correct for I/O-bound turns (they
  `wait`/yield and overlap), but a CPU-bound handler (local embedding, the image downscale
  at `:366`, profiling) won't yield and will stall the owner task + all workers. Note it, or
  `Threads.@spawn` those handlers.
- `@async _serve_one` per request spawns unbounded parked workers under flood (backpressure
  reaches the client only via the delayed reply). Consider gating the ROUTER `recv` on
  in-flight count to bound the server-side queue.
- `send_multipart`/`recv_multipart` aren't exported by all ZMQ.jl versions — loop `recv`
  while `sock.rcvmore` if so.

---

*Grounding:* client `lib/KaimonGate/src/gate.jl` (`_SERVICE_SOCKET` `:2763`,
`_connect_service!` `:2773`, `_service_request` `:2793`, `call_tool` `:2856`); server
`src/service_endpoint.jl` (`start_service_endpoint!` `:29`, REP socket `:37`, serial loop
`:47–74`, inline `_dispatch_service` `:52`); usage source `AgentSession.usage` /
`ACP.TurnEnded` in `src/agent_session.jl` + `src/agent_acp_types.jl`.

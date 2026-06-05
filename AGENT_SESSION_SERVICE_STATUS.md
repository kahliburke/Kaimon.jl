# Agent Session Service — build status & integration handoff

**For:** the agent/dev building the first *consumer* of Kaimon's agent service.
**As of:** 2026-06-04. Branch `agent-session-service-20` (off `http2-and-tcp-reaper-20`).
**Companion to:** `AGENT_SESSION_SERVICE_PLAN.md` (the design). This doc = what's
actually built + the contract you code against.

---

## TL;DR

Kaimon now owns AI **agent sessions**: it spawns/owns a headless `claude`, normalizes
its output into a vendor-neutral event model, and streams those events on the gate
event bus. You drive it with six MCP tools and consume one event channel. **M1
(runtime) + M2 (gate surface) are built and unit-verified.** Not yet done: **M3**
(pointing the agent's MCP back at Kaimon, so it can call your extension's tools) and
the TUI monitor tab. A real end-to-end `claude` spawn hasn't been smoke-tested yet
(only the event mapper, with synthetic input).

**What this means for you right now:** you can open an agent, send turns, and render
the streamed assistant text / tool calls / cost. The agent can *think and chat* but
**cannot yet call back into Kaimon tools** (`slate.*`, `ex`, …) — that's M3.

---

## Key architecture decisions (so you don't re-litigate them)

1. **100% Julia, no Node in the runtime.** We drive `claude -p` stream-JSON directly
   over pipes and map its events ourselves. We deliberately did **not** use the ACP
   node adapter — Claude has no native ACP agent, and since we own both ends an ACP
   wire hop buys nothing. We *do* model our internal types on the **ACP update model**
   (so a future `ACPClientBackend` for Gemini/Codex is purely additive).
2. **Auth = the host's own `claude` login (subscription).** Kaimon never touches
   credentials; the spawned `claude` uses its stored OAuth. The user must be logged in
   (`claude` CLI). No API keys in v1.
3. **Cost model (post-June-15, 2026):** agent usage draws the separate **Agent SDK
   monthly credit** ($200 on Max 20×), metered at API-list rates. So **cost is tracked
   per session** from turn `result` events and surfaced in `agent_status`. Default
   model is the cheap `claude-sonnet-4-6`. Images in tool results are the biggest
   credit burner.
4. **The `AgentBackend` seam is thin.** Everything above it (tools, the `agent:<id>`
   stream, the event envelope, lifecycle) is vendor-neutral. Only `ClaudeBackend`
   knows about `claude`.

---

## Public surface — six MCP tools

All registered as Kaimon MCP tools (callable by the user's Claude Code, and by
extensions via the service endpoint). Returns are JSON strings.

| Tool | Args | Returns |
|---|---|---|
| `agent_open` | `cwd` (req), `model="claude-sonnet-4-6"`, `permission_mode="acceptEdits"`, `allowed_tools=[]`, `mcp_config=null`, `id=null` | `{"agent_id": "<id>"}` — spawns & owns the process |
| `agent_send` | `agent_id` (req), `text` (req) | `{"turn": <n>}` — writes a user turn; events stream on `agent:<id>` |
| `agent_interrupt` | `agent_id` | `{"interrupted": bool}` — best-effort cancel of in-flight turn |
| `agent_close` | `agent_id` | `{"closed": bool}` — kills process, frees registry |
| `agent_status` | `agent_id` | `{status, model, cwd, turn, last_activity, session_id, transcript, usage}` |
| `agent_list` | — | `{"agents": [ …status… ]}` |

- `id` may be caller-supplied (e.g. key the agent to your notebook id) or auto-generated.
- `mcp_config` (a path to an `--mcp-config` JSON) is the **M3** hook — omit for now.
- `permission_mode` ∈ `default | acceptEdits | plan | bypassPermissions`.
- `usage` = `{inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, costUsd}`,
  accumulated across all turns (running session cost).

---

## Event stream — channel `agent:<agent_id>`

Every agent event is published on **Kaimon's global event bus** (the same one
extensions already subscribe to: `ipc://<sock_dir>/kaimon-events.sock`, topic =
channel name). Each message is a `{kind, turn, data}` envelope, JSON-encoded.

### Envelope `kind` set + example `data`

```jsonc
// streamed assistant text
{"kind":"assistant_text","turn":1,"data":{"content":{"type":"text","text":"…"}}}
// reasoning
{"kind":"thought","turn":1,"data":{"content":{"type":"text","text":"…"}}}
// a tool the agent invoked (status in_progress)
{"kind":"tool_use","turn":1,"data":{"call":{"toolCallId":"tu1","title":"Read",
  "kind":"read","status":"in_progress","content":[],"locations":[],"rawInput":{…}}}}
// a tool result (status completed|failed) — content blocks incl. base64 images
{"kind":"tool_result","turn":1,"data":{"update":{"toolCallId":"tu1","status":"completed",
  "content":[{"type":"content","content":{"type":"text","text":"ok"}},
             {"type":"content","content":{"type":"image","data":"<base64>","mimeType":"image/png"}}]}}}
// end of turn — stop reason + usage/cost
{"kind":"result","turn":1,"data":{"stopReason":"end_turn",
  "usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":10,"cacheCreationTokens":0,"costUsd":0.02}}}
// lifecycle / misc
{"kind":"status","turn":1,"data":{"status":"working"}}       // starting|idle|working|dead
{"kind":"turn_started","turn":1,"data":{}}
{"kind":"plan","turn":1,"data":{"entries":[{"content":"…","priority":"high","status":"pending"}]}}
{"kind":"usage","turn":1,"data":{"usage":{…}}}
{"kind":"permission","turn":1,"data":{"toolCall":{…},"options":[…],"requestId":"…"}}  // M4
{"kind":"error","turn":1,"data":{"message":"…","data":null}}
{"kind":"user_text","turn":1,"data":{"content":{"type":"text","text":"…"}}}            // echo
```

`kind` values: `assistant_text · thought · user_text · tool_use · tool_result · plan ·
usage · turn_started · result · status · error · permission`.

### How to subscribe (consumer side)

Same mechanism extensions already use for events. If you're a **managed extension**,
declare the topic in your manifest and you'll get an `on_event(channel, data,
session_name)` callback:

```toml
# extension manifest
event_topics = ["agent:"]   # prefix-subscribe to ALL agent channels (ZMQ prefix match)
```

```julia
function on_event(channel, data, session_name)
    # channel == "agent:<id>", data == the JSON string of {kind,turn,data}
    env = JSON.parse(data)
    # forward env to your UI transport (e.g. SSE to the browser)
end
```

Or subscribe directly (non-extension): `SUB` to `ipc://<sock_dir>/kaimon-events.sock`,
`ZMQ.subscribe(sub, "agent:<id>")` (or `"agent:"` for all), `recv` topic (String) then
payload (`Vector{UInt8}`), `deserialize` → NamedTuple `(channel, data, session_name)`;
`data` is the JSON string above. (`sock_dir = Kaimon.KaimonGate.sock_dir()`.)

> Note: `data` rides the bus as a **JSON string** — convenient to forward straight to a
> browser/SSE without re-encoding.

---

## What's built vs. pending

**Built & verified (M1+M2):**
- `src/agent_acp_types.jl` — `Kaimon.ACP` submodule: the ACP-shaped event model
  (`ContentBlock`/`ImageBlock`, `ToolCall(Update)`, `Usage`, the `AgentEvent` union,
  `envelope(e,turn)`). Round-trip unit-tested incl. the image path.
- `src/agent_backend.jl` — `AgentBackend` seam + `ClaudeBackend` (spawns `claude -p`
  stream-JSON; maps SDK events → ACP). Mapper unit-tested with synthetic input.
- `src/agent_session.jl` — `AgentSession` + registry, status FSM, per-session cost,
  the event relay onto `agent:<id>`, orphan reaping (pid file) + shutdown hook.
- `src/agent_tools.jl` — the six MCP tools above.
- Wired into `src/Kaimon.jl` includes, `collect_tools()`, and gate start/stop.

**Pending:**
- **M3 — MCP self-connection.** Generate an `--mcp-config` pointing the spawned
  `claude` at the *live* Kaimon MCP (+ `--strict-mcp-config`), passed via
  `agent_open(mcp_config=…)`. Until this lands, the agent **cannot call `slate.*` /
  `ex` / any extension tool** — it can only chat. This is the piece that makes it
  *drive* your notebook.
- **M4 — permission policy** (`permission` events → browser approval), cost caps.
- **TUI monitor tab** (planned: tab `9` = Agents, Advanced → `0`).
- **Live smoke test** — a real `claude` spawn end-to-end (spawn/multi-turn/bus) hasn't
  been run yet; only the event mapper has (zero-cost, synthetic).

---

## Open questions to confirm with the Kaimon side

1. Tool names/signatures above — good, or rename to match your consumer?
2. The `kind` set + `data` shapes — anything missing for your UI (e.g. you want raw
   token deltas? we currently emit complete messages, not partial streaming)?
3. `agent_open` id: you'll likely want to pass your own `id` (notebook id) — confirmed
   supported.
4. For M3: how should the agent's `--mcp-config` address the live Kaimon MCP — the
   HTTP endpoint (`http://127.0.0.1:<port>`) or a socket? (Gates M3.)

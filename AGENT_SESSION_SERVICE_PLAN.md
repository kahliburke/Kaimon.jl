# Plan: Kaimon-owned Agent Session service

**Goal.** Make "an AI agent you can talk to" a **first-class Kaimon capability**,
not something each extension reimplements. Kaimon spawns and owns a `claude`
process (headless, stream-JSON), exposes a small gate/MCP surface to *send a turn*
and *stream events*, and any extension (KaimonSlate first, then gotutor, etc.)
consumes it. The agent is itself an **MCP client of Kaimon**, so it automatically
has every extension's tools (`slate.*`, `ex`, …) with zero per-extension wiring.

This mirrors what Kaimon already does for gate REPL sessions and managed
extensions — an **AgentSession** is the natural sibling of a gate session.

> Context: this is driven by the KaimonSlate notebook ("shared live notebook with
> an embedded agent"). The notebook will be the first consumer: a browser chat
> pane → notebook server → Kaimon agent service → events stream back → the agent
> edits cells via `slate.*`. KaimonSlate needs **no** subprocess management; Kaimon
> owns it.

---

## Strategic context (why this is worth doing *well*)

This service is the **differentiator**, not plumbing. The reactive-notebook space
already has strong players — **marimo** (Python; recently shipped an ACP *client*)
and **Pluto.jl** (the Julia incumbent). KaimonSlate's edge isn't being a marginally
better notebook in isolation; it's being **agent-native**: the agent is a
first-class collaborator wired into the whole Kaimon lab, not a chat box bolted on.
That thesis sets the priorities here:

- **Reach the whole lab, not just one notebook.** Because the agent is an MCP client
  of Kaimon, it gets *every* extension's tools, `ex`, code search, memory —
  cross-project, not sandboxed. This is the structural advantage marimo/Pluto can't
  match; don't narrow the agent's tool surface to slate-only.
- **The agent must SEE results.** "Plot it → look → refine" only works if tool
  results carry **rich output** (images/tables, not just text). Make sure the MCP
  path can return image content to the agent — KaimonSlate's capture already
  produces base64 PNGs/tables; the tools should surface them so a vision model can
  iterate on what it sees.
- **Multi-agent is strategic, not optional.** ACP (now mature — §below) makes
  Claude + Gemini + Codex + OpenCode interchangeable. Treat the **ACP-client backend
  as primary** so users can pick/compare agents (what Zed/marimo already offer),
  with the raw stream-JSON Claude backend as a fallback.
- **Concurrency from day one.** Design the registry for multiple live agent
  sessions — per notebook, and across extensions.

---

## Why Kaimon (not the extension)

- **One home** for the cross-cutting concerns that don't belong in an extension:
  model choice, auth/keys, permission policy, conversation/session lifecycle, the
  transcript.
- **Reusable** across extensions via the existing gate stream + tool-call paths.
- **Symmetric** with the session manager: spawn/own/reap a child process, expose
  it over the gate — exactly the gate-session pattern.
- The agent, connected to Kaimon over MCP, gets **all tools for free**.

---

## Background: the runtime is a process, MCP is the tool layer

MCP *exposes* tools; it does **not** run an LLM loop. So the agent must be a real
process. Use Claude Code headless in **stream-JSON** mode (multi-turn, structured
I/O — no TUI scraping):

```
claude --input-format stream-json --output-format stream-json --verbose -p \
       --model <model> \
       --mcp-config <kaimon-mcp.json> --strict-mcp-config \
       --add-dir <cwd> \
       <permission flags>
```

- Reads a **stream of user-turn JSON objects** on stdin and stays alive for the
  whole conversation (until stdin closes).
- Emits **JSONL events** on stdout: `system`/init, `assistant` (text + `tool_use`),
  `user` (`tool_result`), and a final `result` per turn.
- Verify exact flags against the installed `claude` version; prefer the Claude
  Agent SDK only if driving the CLI proves unstable. (We're in Julia, so spawning
  the CLI + piping is the path of least resistance.)

**Turn we write to stdin:**
```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"plot the data"}]}}
```

**MCP self-connection (critical).** The spawned `claude` must connect to the
**already-running Kaimon MCP server** (the same one the user's Claude Code uses),
*not* spawn a fresh stdio instance — Kaimon is a singleton. So Kaimon's MCP must be
reachable as a shared endpoint (HTTP/SSE or a socket the config points at). Generate
a minimal `--mcp-config` that references the live Kaimon MCP, and pass
`--strict-mcp-config` so the child uses only that. Result: the agent sees
`slate.*`, `ex`, and every extension tool.

---

## Multi-agent: a backend abstraction (don't hard-wire Claude)

The above is Claude-specific (`claude` CLI + stream-JSON). Each agentic CLI (Codex,
Gemini, aider, Cursor CLI, …) differs in flags, I/O format, MCP config, and
permission model. Two layers handle this — one local, one leaning on standards.

**1. Keep the seam thin — an `AgentBackend` interface.** Everything *above* it is
vendor-neutral (the `agent_*` gate tools, the `agent:<id>` stream, the
`{kind,turn,data}` envelope, lifecycle/reaping). Only the adapter is per-CLI:

```julia
abstract type AgentBackend end
start(::AgentBackend; cwd, model, tools, permission) -> handle   # spawn the process
send(handle, text)                                               # one user turn
events(handle) -> Channel of normalized events                   # parse → envelope
interrupt(handle); close(handle); status(handle)
```

`ClaudeBackend` implements it via stream-JSON; `CodexBackend`/`GeminiBackend` later
implement the same handful of methods. Manager, gate surface, and consumers
(KaimonSlate) are written **once** against the interface.

**2. Lean on the standards that already exist — the "better way".**

- **Tools are already universal: MCP.** Most agent CLIs are MCP *clients*. Point
  any of them at the live Kaimon MCP and they get `slate.*`, `ex`, every extension
  tool — no per-CLI tool work. That half is already solved.
- **Host↔agent is being standardized: ACP (Agent Client Protocol).** ACP is the
  counterpart to MCP for *this exact problem* — a host/editor driving an agent:
  `session/new`, `session/prompt` (send a turn), streamed `session/update` chunks
  (assistant text, tool calls + updates), and permission requests, over
  JSON-RPC/stdio. Agents are adopting it (Claude Code via an ACP adapter, Gemini
  CLI, Zed's agents…).

  **So shape the `AgentBackend` interface + the `{kind,…}` envelope on ACP's update
  types.** Then a backend is "an ACP transport to agent X," and any ACP-speaking
  CLI drops in with little/no adapter. The Claude backend can be stream-JSON now or
  its ACP adapter as ACP matures.

**ACP maturity (verified mid-2026).** ACP launched Aug 2025 (Zed) and is now a
real multi-editor / multi-agent standard at **stable protocol version 1**:
- **Clients:** Zed, JetBrains AI Assistant, a VS Code extension, Neovim, Emacs,
  Obsidian — and **marimo, a Python notebook, ships ACP as a client.** That last
  one is direct precedent for exactly what we're doing (a notebook driving agents).
- **Agents:** Gemini CLI (native `--acp`), Claude Code (`claude-agent-acp`
  adapter), OpenAI Codex (`codex-acp`), Goose, OpenCode, Kiro — plus Cline, Cursor's
  agent, Factory, Auggie, etc. An **ACP Registry** launched Jan 2026.
- **Caveats:** still early in spots — session *resumption* for external agents isn't
  shipped yet, remote transports are roadmap (it's local JSON-RPC/stdio today,
  which suits Kaimon spawning a subprocess perfectly).

**Recommendation (updated):** make the `AgentBackend` seam **an ACP client** — not
just "ACP-shaped." ACP is local subprocess JSON-RPC over stdio, which is exactly
Kaimon's spawn-and-own model, and it gets Claude + Gemini + Codex + OpenCode + Goose
**at once** (native or via their published adapters). A `ClaudeBackend` via
stream-JSON is still a fine *fallback*/first cut if the Claude ACP adapter is
fiddly, but ACP collapses the per-CLI cost from "an integration each" to "configure
the adapter." Keep everything above the seam (gate tools, `agent:<id>` stream,
envelope) vendor-neutral so an ACP backend and a raw stream-JSON backend coexist.

---

## Architecture

```
extension (e.g. KaimonSlate)                 Kaimon
  browser chat ──POST──▶ ext server               AgentSessionManager
                          │  gate tool call ─────▶  agent_send(id, text)
                          │                          └─ write turn → claude stdin
                          │                          ┌─ read claude stdout (JSONL)
                          ◀── gate PUB stream ───────┘   → publish on "agent:<id>"
  browser ◀──SSE── ext server  (subscribed to "agent:<id>")
                                                   claude (MCP client of Kaimon)
                                                     └─ tool_use slate.* ─▶ edits notebook
```

Key reuse: the **gate PUB/SUB stream** already carries events between workers and
extensions (KaimonSlate uses it today for `slate_refresh` — published with
`KaimonGate._publish_stream`, drained by the extension via
`drain_stream_messages!`). Agent events ride the **same** mechanism on a per-agent
channel.

### New module: `AgentSession` / `AgentSessionManager`

Sits beside the gate/session/extension managers. Responsibilities:

- **Spawn & own** the `claude` process (stdin/stdout pipes; `run(pipeline(cmd; ...); wait=false)`).
- **A stdout reader task** parsing JSONL events line-by-line.
- **Relay** each event onto the gate stream channel `agent:<agent_id>` (via the
  same publish path workers use), as a JSON envelope (below).
- **Lifecycle**: create / send / interrupt / close; reap on Kaimon shutdown.
- **Registry** keyed by `agent_id` (one per consumer/notebook is fine to start).

Suggested struct:
```julia
mutable struct AgentSession
    id::String
    proc::Base.Process
    stdin::Pipe
    cwd::String
    model::String
    status::Symbol            # :starting | :idle | :working | :dead
    reader::Task
    # optional: transcript path, last_activity, pending-turn queue
end
```

---

## Public surface (what consumers call)

Expose as **gate tools** (so extensions call them like any tool) — and optionally
MCP tools later. Names are suggestions:

| Tool | Args | Returns / effect |
|---|---|---|
| `agent_open` | `cwd::String, model::String="claude-sonnet-4-6", permission::String="allowlist", allowed_tools::Vector{String}=[]` | `agent_id::String`; spawns/owns the process |
| `agent_send` | `agent_id::String, text::String` | enqueues a user turn (writes to stdin); events arrive on the stream |
| `agent_interrupt` | `agent_id::String` | cancels the in-flight turn |
| `agent_close` | `agent_id::String` | kills the process, frees the registry |
| `agent_status` | `agent_id::String` | `{status, model, cwd, last_activity}` |

**Event stream** — channel `agent:<agent_id>`, one JSON envelope per gate-stream
message:
```json
{ "kind": "assistant_text" | "tool_use" | "tool_result" | "result" | "error" | "status",
  "turn": 3,
  "data": { ... raw-ish payload from the claude event ... } }
```
Map the claude stream-JSON events → these kinds (collapse the SDK's verbosity to
what a UI needs: streaming text deltas, which tool ran with what input, tool
results, end-of-turn `result` with usage/cost, and status transitions).

Consumers (KaimonSlate) already know how to **drain the gate stream**
(`drain_stream_messages!` filtered by channel) — they just add an `agent:<id>`
subscription and forward to their own UI transport (SSE).

---

## Decisions / config

1. **Model** — default `claude-sonnet-4-6` (fast/cheap for an interactive edit
   loop), switchable to `claude-opus-4-8`. Per-session via `agent_open`.
2. **Permissions (headless)** — start with an **allowlist** (`--allowedTools`,
   e.g. `mcp__kaimon__slate.*`, `mcp__kaimon__ex`, `Edit`, `Read`) plus
   `--permission-mode acceptEdits`. Phase 2: a **permission-prompt tool** that
   routes approvals back to the consumer UI (so the human approves risky calls in
   the browser). Make the policy a config field.
3. **Auth/keys** — Kaimon owns this (reuse the host's existing `claude` auth; no
   keys in extensions).
4. **Transcript** — the owned `claude` writes its own
   `~/.claude/projects/<munged-cwd>/<sessionId>.jsonl`. Expose that path via
   `agent_status` so a consumer can also mirror it; but the **stream is the
   primary** channel (don't depend on tailing the file).
5. **One process per consumer** to start; design the registry so multiple is easy.

---

## Cost model (post-June-15, 2026)

Anthropic split subscription billing into two non-interchangeable buckets
([help center](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)):

- **Interactive bucket** — normal subscription usage limits (rate-limit based).
  Hands-on Claude Code + chat. Unchanged.
- **Agent SDK bucket** — a new monthly dollar credit ($20 Pro / $100 Max 5x /
  **$200 Max 20x**), metered at API list rates. Funds `claude -p`, the Agent SDK,
  and **third-party apps over ACP** — i.e. *this service*. Drains first, no
  rollover, per-user, **claim once** (claim email ~June 8). When it's empty,
  usage either stops or spills to pay-as-you-go *if* usage credits are enabled.

**Implications locked for this build:**

1. **Auth = the host's subscription** (decision #3 holds). AgentSessions draw the
   Agent SDK credit. No keys in v1.
2. **ACP and raw `claude -p` are billing-identical** — both hit the SDK bucket.
   So the backend choice stays purely technical; we go **ACP-first**.
3. **Cost guardrails move from M4 → M2.** Surface `usage`/cost from each turn's
   `result` event, track a running per-session total, expose it in `agent_status`
   and the stream. A configurable per-session budget cap (pause the agent) is the
   first guardrail.
4. **Default to a cheap model** (`claude-sonnet-4-6`) — it directly sets how far
   the $200 stretches. **Vision/image tool-results are the biggest burner**
   (base64 PNGs are token-heavy); keep a knob to downscale/throttle image returns.
5. **API-key spillover** (`ANTHROPIC_API_KEY`, pay-as-you-go) stays a documented
   config knob *behind the `AgentBackend` seam* for when the SDK credit runs dry —
   not wired in v1, but the seam must not preclude it.

The buckets are **not fungible**: an ACP workload can't be routed onto the
interactive limit (that's TTY-scraping, which this change exists to stop). The
legit "use both" story is parallelism — AgentSessions on the SDK bucket while the
human drives interactive Claude Code on the interactive bucket.

---

## Lifecycle & reaping (learn from the gate-session bugs)

Apply the lessons in `STALE_TCP_SESSION_ISSUES.md`:

- **Kill on close / Kaimon shutdown** — `agent_close` and a shutdown hook must
  `kill` the process; don't leak `claude` children.
- **Reap orphans on start** — on Kaimon (re)start, kill leftover owned-agent
  processes from a prior instance (match a launch marker in argv, like the
  existing `_kill_orphan_extension_processes!`).
- **Status truthfully** — mark `:dead` when the process exits; surface it via
  `agent_status` and a `status` stream event.

---

## Milestones

- **M1 — runtime.** `AgentSession` + spawn `claude` (stream-JSON) + stdout reader
  that parses events. No surface yet. Test: write a turn to stdin, log parsed
  events. (Plain chat, no tools.)
- **M2 — gate surface.** `agent_open/send/interrupt/close/status` gate tools +
  relay events onto `agent:<id>`. Test: drive it from a REPL/another session and
  watch the stream.
- **M3 — MCP self-connection.** Generate `--mcp-config` for the live Kaimon MCP +
  `--strict-mcp-config`; confirm the agent can call `slate.*` / `ex`. This is what
  makes it *drive* the notebook.
- **M4 — policy & robustness.** Permission policy (allowlist→prompt-tool), model
  config, reaping/lifecycle, `agent_status` transcript path.

KaimonSlate then consumes M2/M3: a chat pane that calls `agent_open` (cwd = the
notebook's dir) and `agent_send`, subscribes to `agent:<id>`, and renders the
stream — while the agent edits cells through `slate.*` and the notebook's existing
SSE pushes the cell updates. No subprocess code in the extension.

---

## Integration contract for KaimonSlate (so we can build the consumer in parallel)

Please confirm/lock these so the slate side can be written against them:

1. Gate tool names + signatures (table above) — OK as-is, or renamed?
2. Stream channel name `agent:<agent_id>` and the envelope `{kind, turn, data}` —
   especially the `kind` set and how text deltas are chunked.
3. Whether `agent_open` returns a fresh id or accepts a caller-supplied id (so the
   notebook can key the agent to its notebook id).
4. How a consumer subscribes (does it call `connect`/a subscribe tool, or is
   draining `agent:<id>` from a shared `ConnectionManager` enough — as with
   `slate_refresh` today?).

---

## Open questions

- Exact `claude` flags for long-lived multi-turn stream-JSON on the installed
  version (and whether `-p` is needed alongside `--input-format stream-json`).
- How the live Kaimon MCP is addressable for the child's `--mcp-config`
  (HTTP/SSE/socket) — this gates M3.
- Permission UX: is `acceptEdits` + allowlist acceptable for v1, or do we need the
  browser-approval prompt-tool from the start?
- Cost guardrails (per-turn/`result` usage is in the stream — surface a running
  total?).

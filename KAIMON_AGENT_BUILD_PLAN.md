# Kaimon Agent Service — build plan for the KaimonSlate vision

**Companion to:** `KaimonSlate.jl/VISION.md`. **Scope:** what *Kaimon* builds so the
Slate vision is possible. Kaimon owns the **agent service** (spawn/own a `claude`,
normalize its output, stream it, track lifecycle/cost); KaimonSlate is the **consumer**
(the reactive notebook, the chat pane, the history spine). This doc is the Kaimon-side
half of the contract — the capabilities Slate builds *on top of*.

---

## The one job

The vision's enemy is **latency and opacity** — "47 human steps, then one 18-cell
`Write` after ten minutes of silence." The agent is a *blind file-author*; the cure is
a *live notebook operator* whose every action is visible the instant it happens and
whose results flow back into its context.

Kaimon can't make the notebook reactive (that's Slate). What Kaimon **can** do, and
what this plan is about: make the agent's activity **stream out token-by-token and
flow back result-by-result**, so "watch it build, steer it live" is even possible.
Everything here is in service of one line from the vision:

> The unit of progress is a cell appearing and running in front of you, in seconds.

---

## Vision pillar → Kaimon capability

| Vision pillar | What Kaimon builds | Status |
|---|---|---|
| **Kill the silent dump** (liveness) | Token streaming: assistant text + thinking as `delta:true` chunks on `agent:<id>` | ✅ done |
| **"See each other type"** (char-level edits) | Tool-input streaming: a `tool_use` fires the instant a call begins; its args stream as `tool_input_delta` — `slate_add_cell`'s code materializes live | ✅ done |
| **The agent sees what you see** | Faithful tool-result mapping incl. **base64 images** (`ImageBlock`) back into the agent's context | ✅ done (mapping); ⏳ image cost controls |
| **Incremental by construction** | `agent_open(system_prompt=…)` to install the "one cell, run, observe, continue" discipline per spawn | ✅ supported (Slate sets the prompt) |
| **Take-over / steering / "Makie not Plots"** | `agent_interrupt` (cancel in-flight turn) + permission presets (`default/lab/auto/bypass`) | ✅ works; ⏳ hardening (observe the ack) |
| **Presence — "🤖 editing `mult_fig`"** | The `agent:<id>` bus *is* the presence feed: early `tool_use` + status FSM (`idle⇄working`) drive the live indicator | ✅ done |
| **Reach the whole lab, not one notebook** | Agent inherits the host's ambient MCP config → gets `slate.*`, `ex`, code search, every tool, zero per-spawn wiring | ✅ works (by inheritance) |
| **Never lose work / provenance** | Kaimon-owned, vendor-neutral event log (`<id>.events.jsonl`) — a parallel durable record to Slate's history spine | ✅ done |
| **Cost is real (Agent-SDK credit)** | Per-session usage/cost from each turn's `result`; surfaced in `agent_status` | ✅ tracking; ⏳ budget caps + image throttle |

Legend: ✅ shipped · ⏳ planned/this-doc.

---

## The wire contract (what Slate codes against)

One channel per agent — `agent:<id>` on Kaimon's event bus — carrying `{kind, turn,
data}` envelopes. The streaming additions, all back-compatible:

- **`assistant_text` / `thought`** carry `delta`: `true` = append a token chunk;
  `false` (or absent) = the complete, authoritative block (also emitted, for
  self-healing + replay).
- **`tool_use`** is emitted the moment a call begins (`status: in_progress`, no input
  yet), then re-emitted as a **second `tool_use`** for the same `toolCallId` with the
  authoritative parsed input once the block closes. Correlate/replace by `toolCallId`.
  Every `tool_result` is therefore terminal (its `content`/images are the real output).
- **`tool_input_delta`** `{toolCallId, partialJson}` streams the call's arguments;
  fragments concatenate to the full input JSON.

**Liveness vs. truth:** `delta:true` and `tool_input_delta` ride the bus for liveness
but are **skipped from the event log and the TUI monitor** — the authoritative copies
(`delta:false`, the `tool_use` update, `tool_result`) are the durable record. Slate's
reload-replay buffer should mirror this (skip the liveness chunks).

Full reference: `docs/src/agents.md` → "AI Agent Sessions".

---

## Build phases

**Phase 0 — foundations (done).** Owned `claude` sessions, the ACP-shaped event model,
the `agent:<id>` bus, MCP tools (`agent_open/send/interrupt/close/status/list`),
permission presets, lifecycle/reaping, cost tracking, the TUI monitor, the event log.

**Phase 1 — liveness (done).** Text/thinking token streaming; tool-call announce +
input streaming. This is the bulk of "kill the silent dump."

**Phase 2 — seeing results, well.**
- ✅ **Resolution cap + downsample (done).** Tool-result PNGs are box-average
  downscaled to a max long edge before reaching the agent — `agent_image_max_long_edge`
  in `~/.config/kaimon/config.json`, default **1568** (the model's own effective cap, so
  it's free-and-lossless by default; lower it to trade quality for credit). Built on the
  existing `PNGFiles` dep — no image stack. Governance is **pixel/token-based**
  (≈ `w×h/750`), not image-count: a few small plots beat one full-size figure.
- ⏳ **Optional per-result token budget** — sum estimated image tokens per result, then
  downscale harder / drop extras beyond a ceiling. Deferred until real usage shows the
  per-image cap isn't enough.

**Phase 3 — steering hardening (done).** `agent_interrupt` now sends unique
`control_request{interrupt}` ids, and claude's `control_response` is parsed — an error
ack surfaces as an `AgentError` (a rejected interrupt is visible) rather than dropped;
a real cancel lands as `result{stopReason: cancelled}`.

**Phase 2.5 — tool-result images (done).** MCP tool results can now carry images:
`KaimonGate.image_result(png; text)` returns a sentinel envelope that the MCP egress
unwraps into a real image content block, downscaled to `tool_image_max_long_edge`
(default 1024) *before* the model consumes it — the actual cost lever (the stream-output
downscaler only governs forwarding). Verified live: a 1500×1000 test card arrived at the
model as 750×500. Unblocks Slate's `slate_view(notebook, cell)`. Spec:
`KAIMON_TOOL_IMAGE_RESULTS_SPEC.md`.

**Phase 4 — budget guardrails (parked, low priority).** A per-session cost cap that
pauses the agent when the running total crosses a threshold. Explicitly deprioritized —
bottom of the list, not happening for a long while.

---

## Open questions

**Resolved with Slate (no Kaimon change needed — shipped contract matches):**
- ✅ **Tool-input consumption** — Slate appends `tool_input_delta` by `toolCallId` and
  replaces on the authoritative `tool_use` update, and skips the liveness chunks
  (`tool_input_delta`, `delta:true`) from its reload-replay buffer.
- ✅ **Partial-JSON** — raw fragments. Slate accumulates `partialJson` per call and
  tolerant-extracts the source/code field to show it materializing. Kaimon stays
  general (doesn't guess which field is "the code").

- ✅ **Image cost governance** — reframed from image-count to **resolution/pixels** (the
  real token lever; the API caps at ~1.15 MP regardless). Shipped: a global max-long-edge
  box-downsample (`agent_image_max_long_edge`, default 1568). Per-result token budget
  deferred.

---

## Explicitly **not** Kaimon's job (Slate's territory)

The reactive engine, cell-level `slate.*` tools, per-cell 3-way merge + presence UI,
the durable history spine + replay UI, WebSocket live-typing/cursors, and
agent-edits-as-suggestions. Kaimon streams the agent and carries the events; Slate owns
the notebook and the collaboration surface.

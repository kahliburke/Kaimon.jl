# Spec — image content blocks in MCP tool results (the `slate_view` enabler)

**Status:** for review (no code written). **Default cap:** 1024 px long edge.
**Companion to:** `KAIMON_AGENT_BUILD_PLAN.md`. **Driver:** KaimonSlate wants a
`slate_view(notebook, cell)` tool that hands the agent the cell's rendered PNG so it can
*look* at a plot it just made — with Kaimon governing resolution/cost.

---

## TL;DR of the investigation (why this is needed)

1. **MCP tool results are text-only today.** Every handler return funnels through one of
   two egress points, both hardcoded to a single text block:
   - non-streaming: `src/MCPServer.jl:1248-1255` → `"content" => [Dict("type"=>"text", "text"=>result_text)]`
   - streaming (SSE): `src/MCPServer.jl:1526` → same shape
   and the return is `string(...)`'d on the way (`:1241`, `:1515`). A handler returning PNG
   bytes gets stringified into a text block (garbage to the model). **So `slate_view`
   returning an image is impossible without a Kaimon change.**

2. **The existing image downscaler does NOT govern cost.** `_tool_result_content` /
   `_downscale_png_b64` (`src/agent_backend.jl:342-415`) runs inside `_map_claude_event`
   (`:282`), which parses claude's **stdout** stream-json. By the time a `tool_result`
   appears there, **claude already received and paid vision tokens for the full-res image.**
   That downscaler only shrinks what Kaimon *forwards* to the event log + `agent:<id>` bus
   (Slate's replay/display) — it is an **outbound display filter, not a cost lever.**
   Confirmed by the input path: `backend_send` (`:178-180`) writes only `{type:"text"}` to
   claude's stdin — Kaimon never injects an image into the model.

3. **`Read` of an image is claude-internal.** Claude reads the file and ships it to the
   Anthropic API itself (server-side auto-downscale ~1568 px / ~1.15 MP). Kaimon never
   touches it.

**Conclusion:** to cap what the agent *consumes*, the downscale must happen in the **MCP
tool-result egress**, before bytes reach claude. That egress is also the thing that makes
`slate_view` possible. Same piece of work.

---

## The transport is already string-locked (this simplifies everything)

A gate tool's (`slate_*`) result is stringified at every hop, so a **string carrier
survives end-to-end** and no gate-protocol change is needed:

- gate source: `lib/KaimonGate/src/gate.jl:1693` → `_publish_stream("tool_complete", string(result); request_id)`
- sync receive: `src/gate_client.jl:2104` → `string(get(result.response, :value, ""))`
- async receive (what slate uses): `src/gate_client.jl:2201,2207` → result rides as the
  string `:data` field on the `tool_complete` PUB message, returned verbatim. **No
  truncation** on this path (the `max_output`/`truncate_output` cap is applied inside
  specific handlers like `ex`, not globally; a ~1 MB base64 string passes — ZMQ handles
  multi-MB frames).

So: encode the image result as a **plain string envelope**. It rides `:value`/`:data`
untouched; only MCPServer's egress learns to unwrap it.

---

## Design

### 1. The carrier — a sentinel-tagged content envelope (a String)

A handler that wants to return rich content returns a string of the form:

```
KAIMON-MCP-CONTENT/v1\n{"content":[ ...blocks... ],"isError":false}
```

- `content` is the MCP content array: `{"type":"text","text":...}` and/or
  `{"type":"image","data":"<base64>","mimeType":"image/png"}`.
- The sentinel prefix is chosen so it cannot collide with a tool that legitimately returns
  JSON text. Anything **not** starting with the sentinel is treated as plain text (full
  back-compat — every existing tool is unaffected).

### 2. Helper APIs (so handlers never hand-roll the envelope)

```julia
# KaimonGate (for gate/slate tools, runs in the user's REPL session)
KaimonGate.image_result(png::AbstractVector{UInt8}; mime="image/png", text=nothing) -> String
# returns the sentinel envelope string; `text`, if given, is prepended as a text block.

# Kaimon (for in-server native tools, same envelope)
Kaimon.image_result(png; mime="image/png", text=nothing) -> String
```

Slate's `slate_view` handler then looks like:

```julia
GateTool("slate_view", function (args)
    png = render_cell_png(args["notebook"], args["cell"])   # Slate's job
    return KaimonGate.image_result(png; text="Cell $(args["cell"]) rendered")
end)
```

### 3. The only Kaimon-internal change — egress unwrap + downscale

Add one helper and call it at both egress sites:

```julia
# new, in MCPServer.jl (or a small shared module)
function _build_tool_content(result_text::AbstractString)
    startswith(result_text, KAIMON_MCP_CONTENT_SENTINEL) || return
        (Any[Dict("type"=>"text","text"=>result_text)], false)        # unchanged path
    try
        env  = JSON.parse(chop_sentinel(result_text))
        blks = Any[]
        max_edge = _tool_image_max_edge()                              # default 1024
        for b in env["content"]
            if b["type"] == "image" && get(b,"mimeType","")=="image/png"
                b = merge(b, Dict("data"=>_downscale_png_b64(b["data"], max_edge)))
            end
            push!(blks, b)
        end
        return (blks, get(env, "isError", false))
    catch
        return (Any[Dict("type"=>"text","text"=>result_text)], false)  # malformed → text
    end
end
```

Wire it in:
- **non-streaming** `:1248-1255`: `content, isErr = _build_tool_content(string(result_text))`
  → `"result" => Dict("content"=>content, "isError"=>isErr)`.
- **streaming** `:1526`: same substitution into `result_dict`.

**This egress is the cost-governing point** — the downscale here caps what claude
consumes, unlike the existing output-side `_tool_result_content`. Reuses the already-tested
`_downscale_png_b64`.

### 4. Config

New global key, distinct from the forwarding one:
- `tool_image_max_long_edge` — **default 1024** — caps tool-result images *into* the model
  (the cost lever). Read via a new `_tool_image_max_edge()` mirroring `_agent_image_max_edge()`.
- `agent_image_max_long_edge` (existing, **1568**) stays as-is but is now understood as a
  *display/forwarding* lever (Slate replay + event-log image weight), not cost. Optional
  follow-up: lower its default too, or fold the two — separate decision, out of scope here.

---

## Back-compat & safety

- Non-envelope returns are byte-for-byte unchanged → every existing tool unaffected.
- Malformed envelope → falls back to the text block (never drops the result).
- Image decode/resize failure → `_downscale_png_b64` already returns input unchanged.
- Any MCP client benefits — including the human's interactive Claude Code session calling
  an image-returning tool gets a real, downscaled image block. Universal, not agent-only.

---

## What's explicitly NOT changing

- The gate ZMQ protocol / message schema (string carrier rides as-is).
- `backend_send` / the agent input path (still text-only to claude's stdin).
- The output-side `_tool_result_content` forwarding downscaler (orthogonal; display only).
- No JPEG/byte-budget: PNG is lossless so a hard KB cap isn't a reliable lever; pixel cap
  (1024 long edge) is the deterministic governor. JPEG would need a new encoder — deferred.

---

## Defaults rationale (Q3)

1024 px long edge is plenty for the agent to judge axes/shape/legend of a plot while
staying cheap (~1024×768 ≈ 1.0k vision tokens vs ~1.6k at 1568). Configurable for users who
want full fidelity. Matches Slate's proposal.

---

## Test plan

**Unit (deterministic, no live deps):**
- `_build_tool_content`: plain text → single text block, `isError=false`.
- envelope with text+image → 2 blocks; image `data` decodes to long edge ≤ 1024.
- malformed envelope (sentinel + bad JSON) → text fallback, result preserved.
- `isError:true` envelope → propagated to the response.
- `KaimonGate.image_result` round-trip: bytes → envelope string → parse → original bytes
  (pre-downscale) recoverable.

**Integration (seam, no live claude):**
- fake gate tool returns `image_result(big_png_bytes)` → pass the resulting string through
  `_build_tool_content` → assert one MCP image block, decoded long edge ≤ 1024.

**Live (with Slate):**
- `slate_view` on a real plot → agent describes it accurately (proves the image reached the
  model) → read newest `~/.cache/kaimon/agents/*.events.jsonl`, decode the image block,
  confirm dims ≤ cap.

---

## Open questions for review

1. **Sentinel format** — prefix-tagged JSON (recommended, collision-proof) vs a reserved
   top-level key like `{"__kaimon_mcp_content__":[...]}`. Prefer prefix.
2. **Fold the two downscale knobs?** Keep `tool_image_max_long_edge` (1024, cost) separate
   from `agent_image_max_long_edge` (1568, display) for now — confirm that's the right call.
3. **Multiple images per result** — supported by the content array; per-result token budget
   still deferred (Phase 4 territory).
4. **Where do the helpers live** — `KaimonGate.image_result` (gate tools) + `Kaimon.image_result`
   (native), sharing one envelope builder. OK?

// Kaimon bridge plugin for opencode.
//
// ACP has no way to express tool policy: opencode does its own file I/O, ignores
// the client's declared fs capabilities, and never sends session/request_permission.
// So the ACP backend carries the conversation and this carries the control.
//
// Decisions are made in Julia, not here. Allow/deny entries come in three forms
// (bare `ex`, qualified `mcp__kaimon__ex`, server-prefix `mcp__kaimon`) and only
// Kaimon has the matcher for them; an exact-match Set in JS would silently fail
// to block any of the qualified forms. ACPClientBackend copies this file into a
// per-session config directory and sets the KAIMON_* variables below.

const PORT = parseInt(process.env.KAIMON_BRIDGE_PORT || "0", 10)
const TOKEN = process.env.KAIMON_BRIDGE_TOKEN || ""
const AGENT_ID = process.env.KAIMON_AGENT_ID || ""
const PRESET = process.env.KAIMON_AGENT_PERMISSION || "default"
const SYSTEM_PROMPT = process.env.KAIMON_AGENT_SYSTEM_PROMPT || ""

// Only consulted when Kaimon can't be reached. Deliberately coarse: the precise
// rules live in Julia, so guessing them here would drift.
const MUTATING = new Set(["write", "edit", "patch", "bash", "shell", "run", "delete", "move"])

const offline = (tool) => {
  // No bridge configured at all: the agent runs its own policy, which is also
  // what a non-opencode ACP agent does.
  if (!PORT) return { allow: true }
  // A bridge was configured and didn't answer. The deny list can't be evaluated
  // here, so refuse anything that changes state rather than widen authority
  // because a server hiccuped.
  return MUTATING.has(tool)
    ? { allow: false, why: "kaimon unreachable; refusing a mutating tool" }
    : { allow: true }
}

async function decide(tool, args) {
  if (!PORT || !TOKEN) return offline(tool)
  try {
    const r = await fetch(`http://127.0.0.1:${PORT}/agent/permission`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "X-Kaimon-Agent-Id": AGENT_ID,
        "X-Kaimon-Bridge-Token": TOKEN,
      },
      body: JSON.stringify({ tool, args, preset: PRESET }),
      signal: AbortSignal.timeout(5000),
    })
    if (!r.ok) return offline(tool)
    return await r.json()
  } catch {
    return offline(tool)
  }
}

export const KaimonBridge = async () => ({
  // Enforced here rather than in permission.ask, which opencode never fires for
  // its own built-in tools — measured, see dev/acp.
  "tool.execute.before": async (input, output) => {
    const verdict = await decide(input.tool, output.args)
    if (verdict && verdict.allow === false) {
      throw new Error(`kaimon: ${input.tool} denied${verdict.why ? ` (${verdict.why})` : ""}`)
    }
    if (verdict && verdict.args) Object.assign(output.args, verdict.args)
  },

  // Still wired, for ACP agents that do route through it.
  "permission.ask": async (input, output) => {
    const verdict = await decide(input?.type || input?.tool || "unknown", input)
    output.status = verdict && verdict.allow === false ? "deny" : "allow"
  },

  // Rebuilt every turn, so a notebook's context tracks its live state. The Claude
  // backend binds its system prompt at spawn and has to reap the agent to change it.
  "experimental.chat.system.transform": async (_input, output) => {
    if (SYSTEM_PROMPT && Array.isArray(output.system)) output.system.push(SYSTEM_PROMPT)
  },
})

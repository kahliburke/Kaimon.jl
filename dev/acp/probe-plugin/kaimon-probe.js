// Probe plugin: does opencode load plugins in `acp` mode, and which of the
// control hooks actually fire during an ACP-driven turn?
//
// This is the pivotal question for the backend design. ACP itself gave us no
// permission control — opencode wrote a file despite the client declaring
// writeTextFile:false — so if the plugin hooks DO fire under ACP, we get the
// transport from ACP and the control from here, with no fork and no second
// server process.
//
// Every hook appends one JSON line to $ACPLAB_ROOT/logs/plugin.ndjson.

import { appendFileSync, mkdirSync } from "node:fs"
import { dirname, join } from "node:path"

const LOG = join(process.env.ACPLAB_ROOT || "/tmp/acplab", "logs", "plugin.ndjson")
mkdirSync(dirname(LOG), { recursive: true })

const rec = (hook, data) =>
  appendFileSync(LOG, JSON.stringify({ t: new Date().toISOString(), hook, ...data }) + "\n")

// Tools we refuse, to prove the deny path works. `permission.ask` is the polite
// lever; throwing from tool.execute.before is the one that works even when the
// agent never asks.
const DENY = new Set((process.env.ACPLAB_DENY_TOOLS || "").split(",").filter(Boolean))

export const KaimonProbe = async ({ project, directory, worktree }) => {
  rec("plugin.loaded", { directory, worktree, deny: [...DENY] })

  return {
    "permission.ask": async (input, output) => {
      rec("permission.ask", { input, statusIn: output.status })
      // Mutating output.status is the documented control point: "ask" would
      // block on a human, so a headless host has to answer here or hang.
      if (DENY.has(input?.type) || DENY.has(input?.tool)) output.status = "deny"
      else if (output.status === "ask") output.status = "allow"
      rec("permission.ask.decided", { statusOut: output.status })
    },

    "tool.execute.before": async (input, output) => {
      rec("tool.execute.before", { tool: input.tool, callID: input.callID, args: output.args })
      if (DENY.has(input.tool)) throw new Error(`acplab: ${input.tool} denied by policy`)
    },

    "tool.execute.after": async (input, output) => {
      rec("tool.execute.after", {
        tool: input.tool,
        callID: input.callID,
        title: output.title,
        outputLen: typeof output.output === "string" ? output.output.length : null,
      })
    },

    "experimental.chat.system.transform": async (input, output) => {
      rec("system.transform", { blocks: output.system?.length, model: input?.model?.modelID })
      // Proving the notebook-priming prompt can be injected per turn rather than
      // frozen at spawn, which is a capability ClaudeBackend does not have.
      output.system?.push("[acplab] system prompt injected by the Kaimon bridge plugin.")
    },

    "chat.params": async (input, output) => {
      rec("chat.params", { temperature: output.temperature, maxOutputTokens: output.maxOutputTokens })
    },

    event: async ({ event }) => {
      rec("event", { type: event?.type })
    },
  }
}

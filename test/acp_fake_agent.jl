# A fake ACP agent, driven from a script.
#
# The thing under test is the CLIENT, not anybody's model. Every interesting property of the ACP
# backend is about what it does when the agent behaves badly or awkwardly: a client request that
# never returns, a permission prompt racing an update, a payload of the wrong shape. A real agent
# cannot be asked to do those on command, and a real agent costs a turn to run at all.
#
# So: a subprocess that speaks newline-delimited JSON-RPC on stdio, answers the handshake, and then
# does exactly what its script tells it to. `ACPClientBackend` takes `argv`, so pointing the real
# backend at this needs no production code to know it exists.
#
# The script is a JSON array in KAIMON_FAKE_SCRIPT, each step one of:
#   {"send": {...}}          write this object to stdout verbatim
#   {"request": {...}}       an agent→client request; `id` is filled in
#   {"sleep": 0.2}           pause
# Steps run after `session/new` is answered. `session/prompt` is answered when the script ends,
# unless the script says {"hang": true}.

"Write the fake-agent program to `path` and return the argv that runs it."
function fake_agent_argv(path::AbstractString)
    open(path, "w") do io
        write(io, raw"""
        const readline = require("readline");
        const script = JSON.parse(process.env.KAIMON_FAKE_SCRIPT || "[]");
        const caps = JSON.parse(process.env.KAIMON_FAKE_CAPS || "{}");
        let nextId = 1000;
        const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");
        const sleep = (s) => new Promise(r => setTimeout(r, s * 1000));

        async function runScript() {
          for (const step of script) {
            if (step.sleep !== undefined) { await sleep(step.sleep); continue; }
            if (step.send) { out(step.send); continue; }
            if (step.request) { out({ jsonrpc: "2.0", id: nextId++, ...step.request }); continue; }
          }
        }

        let hang = script.some(s => s.hang === true);
        readline.createInterface({ input: process.stdin }).on("line", async (line) => {
          if (!line.trim()) return;
          let m; try { m = JSON.parse(line); } catch (_) { return; }
          if (m.method === "initialize") {
            out({ jsonrpc: "2.0", id: m.id,
                  result: { protocolVersion: 1, agentCapabilities: caps, authMethods: [] } });
          } else if (m.method === "session/new") {
            out({ jsonrpc: "2.0", id: m.id, result: { sessionId: "fake-session" } });
            runScript();
          } else if (m.method === "session/prompt") {
            await runScript();
            if (!hang) out({ jsonrpc: "2.0", id: m.id, result: { stopReason: "end_turn" } });
          } else if (m.method === "session/cancel") {
            // no reply: cancel is a notification
          } else if (m.id !== undefined && m.method) {
            out({ jsonrpc: "2.0", id: m.id, result: {} });
          }
        });
        """)
    end
    return ["node", path]
end

"""
Run `f(handle)` against a fake agent scripted by `steps`, then tear it down.

`caps` is what the fake reports at `initialize`, so a test can decide whether the client is
talking to a queueing agent without needing one.
"""
function with_fake_agent(f; steps = Any[], caps = Dict{String,Any}(), cwd = mktempdir(),
                         allow_writes = true, allowed_tools = String[],
                         permission = "default", disallowed_tools = nothing)
    prog = joinpath(mktempdir(), "fake_acp.js")
    # `nothing` means take what the preset would give a real spawn, which is what `agent_open`
    # composes. A test that cares about the deny list passes its own.
    deny = disallowed_tools === nothing ?
           unique(vcat(Kaimon.AGENT_SELF_TOOLS, Kaimon._permission_preset(permission)[3])) :
           collect(String, disallowed_tools)
    b = ACPClientBackend(; argv = fake_agent_argv(prog), permission = permission,
                         allowed_tools = allowed_tools, allow_writes = allow_writes,
                         disallowed_tools = deny, plugin_dir = nothing)
    withenv("KAIMON_FAKE_SCRIPT" => JSON.json(steps), "KAIMON_FAKE_CAPS" => JSON.json(caps)) do
        h = Kaimon.backend_start(b; cwd = cwd, agent_id = "fake-" * string(rand(UInt16), base = 16))
        try
            f(h)
        finally
            try; Kaimon.backend_close(h); catch; end
        end
    end
end

"Drain up to `n` events, or until `timeout` passes. Never blocks past the deadline."
function drain_events(h; n::Int = 10, timeout::Real = 5.0)
    got = Any[]
    deadline = time() + timeout
    while length(got) < n && time() < deadline
        if isready(h.events)
            push!(got, take!(h.events))
        else
            sleep(0.02)
        end
    end
    return got
end

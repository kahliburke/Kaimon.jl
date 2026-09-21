#!/usr/bin/env julia
#
# End-to-end check of ACPClientBackend against a real agent: spawn, handshake,
# one turn, drain the event channel, close. Prints the AgentEvent types in order,
# which is the thing worth eyeballing — a mapping bug shows up here as an
# AgentError("unmapped session/update: …") rather than as a crash.
#
#     source dev/acp/env.sh
#     julia --project=. dev/acp/e2e.jl [model] [prompt]

using Kaimon
const K = Kaimon
const ACP = Kaimon.ACP

model  = length(ARGS) >= 1 ? ARGS[1] : "opencode/minimax-m3"
prompt = length(ARGS) >= 2 ? join(ARGS[2:end], " ") :
         "Read calc.jl, tell me what y is, and briefly explain."

cwd = mktempdir()
write(joinpath(cwd, "calc.jl"), "x = 41\ny = x + 1\n")

b = K.ACPClientBackend(; argv = ["opencode", "acp"], model = model,
                       permission = "default",
                       system_prompt = "You are running inside a Kaimon ACP backend test.",
                       plugin_dir = K._acp_plugin_dir())

println("model  : $model")
println("cwd    : $cwd")
t0 = time()
h = K.backend_start(b; cwd = cwd, agent_id = "acp-e2e")
println("session: $(K.backend_session_id(h))  (handshake $(round(time()-t0; digits=1))s)")
println("pid    : $(K.backend_pid(h))  status=$(K.backend_status(h))\n")

turn = K.backend_send(h, prompt)
println("turn $turn sent\n")

counts = Dict{Symbol,Int}()
text = IOBuffer()
t1 = time()
for ev in K.events(h)
    counts[nameof(typeof(ev))] = get(counts, nameof(typeof(ev)), 0) + 1
    if ev isa ACP.AgentMessageChunk && ev.content isa ACP.TextBlock
        print(stdout, ev.content.text); write(text, ev.content.text)
    elseif ev isa ACP.ToolCallStarted
        println("\n  [tool] $(ev.call.title) kind=$(ev.call.kind) status=$(ev.call.status)")
    elseif ev isa ACP.UsageUpdated
        println("\n  [usage] $(ev.usage.input_tokens) ctx, cost=\$$(ev.usage.cost_usd)")
    elseif ev isa ACP.AgentError
        println("\n  [ERROR] $(ev.message)")
    elseif ev isa ACP.TurnEnded
        println("\n\n── turn ended: $(ev.stop_reason) in $(round(time()-t1; digits=1))s ──")
        break
    end
end

println("\nevent census:")
for (k, v) in sort(collect(counts); by = last, rev = true)
    println("  $(lpad(v, 5))  $k")
end

K.backend_close(h)
println("\nclosed. status=$(K.backend_status(h))")

#!/usr/bin/env julia
#
# ACP protocol probe — a throwaway client that drives one real session against an
# ACP agent and records every frame in both directions.
#
# The question this answers: which `session/update` variants does a given agent
# actually emit, and which callbacks does it make into the client? That set is
# exactly what an AgentBackend has to map onto ACP.AgentEvent, and it differs per
# agent, so it's worth measuring rather than reading a spec and hoping.
#
# Unlike the Claude backend's one-way stream-JSON, ACP is bidirectional: the agent
# calls back for permission and filesystem access mid-turn, and a client that
# doesn't answer will hang forever with the turn half-finished. So this is a peer,
# not a reader.
#
#     source dev/acp/env.sh
#     julia --project dev/acp/probe.jl "read Project.toml and name the first dependency"
#
# Agent under test is `opencode acp` unless ACPLAB_AGENT_CMD says otherwise.

using JSON
using Dates

const PROTOCOL_VERSION = 1

# ── peer ──────────────────────────────────────────────────────────────────────

mutable struct Peer
    proc::Base.Process
    inp::Pipe
    outp::Pipe
    next_id::Int
    pending::Dict{Int,Channel{Any}}
    raw::IO                       # every frame, verbatim, both directions
    updates::Dict{String,Int}     # session/update subtype → count
    inbound::Dict{String,Int}     # agent→client method → count
    lk::ReentrantLock
end

function spawn_agent(argv::Vector{String}, cwd::AbstractString, logdir::AbstractString)
    mkpath(logdir)
    inp, outp = Pipe(), Pipe()
    errpath = joinpath(logdir, "agent-stderr.log")
    proc = run(pipeline(Cmd(Cmd(argv); dir = cwd); stdin = inp, stdout = outp, stderr = errpath);
               wait = false)
    close(inp.out); close(outp.in)
    raw = open(joinpath(logdir, "frames.ndjson"), "w")
    return Peer(proc, inp, outp, 0, Dict{Int,Channel{Any}}(), raw,
                Dict{String,Int}(), Dict{String,Int}(), ReentrantLock())
end

"Write one JSON-RPC frame as nd-JSON and mirror it into the raw log."
function emit!(p::Peer, obj::AbstractDict)
    line = JSON.json(obj)
    lock(p.lk) do
        println(p.raw, JSON.json(Dict("dir" => "out", "t" => string(now()), "frame" => obj)))
        flush(p.raw)
        write(p.inp, line, '\n')
        flush(p.inp)
    end
    return nothing
end

"Send a request and block until its response arrives. Throws on a JSON-RPC error."
function call!(p::Peer, method::AbstractString, params)
    id = lock(p.lk) do
        p.next_id += 1
        p.pending[p.next_id] = Channel{Any}(1)
        p.next_id
    end
    emit!(p, Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    reply = take!(p.pending[id])
    lock(p.lk) do; delete!(p.pending, id); end
    haskey(reply, "error") && error("$method failed: $(JSON.json(reply["error"]))")
    return get(reply, "result", nothing)
end

respond!(p::Peer, id, result) =
    emit!(p, Dict("jsonrpc" => "2.0", "id" => id, "result" => result))

respond_error!(p::Peer, id, code::Int, msg::AbstractString) =
    emit!(p, Dict("jsonrpc" => "2.0", "id" => id,
                  "error" => Dict("code" => code, "message" => msg)))

# ── agent → client callbacks ──────────────────────────────────────────────────
#
# The probe grants permission and serves reads, so a turn can run to completion,
# but refuses writes: we declared writeTextFile=false in our capabilities, and an
# agent that asks anyway is itself a finding worth seeing in the log.

"Pick the least destructive permission option the agent offered."
function choose_option(options)
    options isa AbstractVector && !isempty(options) || return nothing
    for want in ("allow_once", "allow_always")
        for o in options
            get(o, "kind", "") == want && return get(o, "optionId", nothing)
        end
    end
    return get(first(options), "optionId", nothing)
end

function handle_request!(p::Peer, id, method::AbstractString, params)
    lock(p.lk) do; p.inbound[method] = get(p.inbound, method, 0) + 1; end
    params = params isa AbstractDict ? params : Dict{String,Any}()

    if method == "session/request_permission"
        opt = choose_option(get(params, "options", nothing))
        tool = get(get(params, "toolCall", Dict()), "title", "?")
        println("    ↳ permission for $(tool) → $(something(opt, "no option offered"))")
        respond!(p, id, opt === nothing ?
            Dict("outcome" => Dict("outcome" => "cancelled")) :
            Dict("outcome" => Dict("outcome" => "selected", "optionId" => opt)))

    elseif method == "fs/read_text_file"
        path = String(get(params, "path", ""))
        try
            content = read(path, String)
            # Optional windowing: 1-indexed start line plus a line count.
            if haskey(params, "line") || haskey(params, "limit")
                lines = split(content, '\n')
                from = max(1, Int(get(params, "line", 1)))
                n = Int(get(params, "limit", length(lines)))
                content = join(lines[from:min(end, from + n - 1)], '\n')
            end
            println("    ↳ fs/read_text_file $(basename(path)) ($(sizeof(content)) B)")
            respond!(p, id, Dict("content" => content))
        catch e
            respond_error!(p, id, -32000, sprint(showerror, e))
        end

    else
        println("    ↳ UNHANDLED agent request: $method $(JSON.json(params))")
        respond_error!(p, id, -32601, "probe does not implement $method")
    end
    return nothing
end

# ── session/update notifications ──────────────────────────────────────────────

"One readable line per update, plus a tally so the run ends with a census."
function handle_update!(p::Peer, params)
    upd = get(params, "update", nothing)
    upd isa AbstractDict || return
    kind = String(get(upd, "sessionUpdate", "?"))
    lock(p.lk) do; p.updates[kind] = get(p.updates, kind, 0) + 1; end

    if kind in ("agent_message_chunk", "agent_thought_chunk", "user_message_chunk")
        txt = get(get(upd, "content", Dict()), "text", "")
        # Dim thoughts, but only wrap them — resetting after every chunk litters
        # the transcript with escape codes when chunks are a few tokens wide.
        print(kind == "agent_thought_chunk" ? "\e[2m$txt\e[0m" : txt)
    elseif kind in ("tool_call", "tool_call_update")
        println("\n  [$kind] $(get(upd, "title", get(upd, "toolCallId", "?"))) " *
                "status=$(get(upd, "status", "-")) kind=$(get(upd, "kind", "-"))")
    elseif kind == "plan"
        println("\n  [plan] $(length(get(upd, "entries", []))) entries")
    else
        println("\n  [$kind] $(JSON.json(upd))")
    end
    return nothing
end

# ── reader ────────────────────────────────────────────────────────────────────

function reader_task(p::Peer)
    @async try
        while !eof(p.outp)
            line = readline(p.outp)
            isempty(strip(line)) && continue
            obj = try
                JSON.parse(line)
            catch
                println("\n  !! unparseable frame: $line")
                continue
            end
            lock(p.lk) do
                println(p.raw, JSON.json(Dict("dir" => "in", "t" => string(now()), "frame" => obj)))
                flush(p.raw)
            end

            if haskey(obj, "method") && haskey(obj, "id")
                handle_request!(p, obj["id"], String(obj["method"]), get(obj, "params", nothing))
            elseif haskey(obj, "method")
                m = String(obj["method"])
                m == "session/update" ? handle_update!(p, get(obj, "params", Dict())) :
                    println("\n  [notify] $m $(JSON.json(get(obj, "params", nothing)))")
            elseif haskey(obj, "id")
                ch = lock(p.lk) do; get(p.pending, obj["id"], nothing); end
                ch === nothing ? println("\n  !! response to unknown id $(obj["id"])") : put!(ch, obj)
            end
        end
    catch e
        e isa EOFError || println("\n  !! reader died: $(sprint(showerror, e))")
    end
end

# ── run ───────────────────────────────────────────────────────────────────────

function main()
    prompt = isempty(ARGS) ?
        "Read Project.toml in this directory and tell me the name of the package." :
        join(ARGS, " ")
    argv = split(get(ENV, "ACPLAB_AGENT_CMD", "opencode acp"))
    cwd = get(ENV, "ACPLAB_CWD", pwd())
    logdir = joinpath(get(ENV, "ACPLAB_ROOT", mktempdir()), "logs",
                      "probe-" * Dates.format(now(), "yyyymmdd-HHMMSS"))

    println("agent   : $(join(argv, ' '))")
    println("cwd     : $cwd")
    println("logs    : $logdir\n")

    p = spawn_agent(String.(argv), cwd, logdir)
    reader_task(p)

    println("→ initialize")
    init = call!(p, "initialize", Dict(
        "protocolVersion" => PROTOCOL_VERSION,
        "clientCapabilities" => Dict(
            # Read yes, write no. A probe that can't clobber the tree is a probe
            # you can point at a real checkout.
            "fs" => Dict("readTextFile" => true, "writeTextFile" => false),
            "terminal" => false)))
    println("  agent capabilities: $(JSON.json(get(init, "agentCapabilities", nothing)))")
    println("  auth methods      : $(JSON.json(get(init, "authMethods", nothing)))")
    println("  protocol version  : $(get(init, "protocolVersion", "?"))\n")

    println("→ session/new")
    sess = call!(p, "session/new", Dict("cwd" => abspath(cwd), "mcpServers" => []))
    sid = get(sess, "sessionId", nothing)
    println("  sessionId: $sid\n")

    println("→ session/prompt: $prompt\n")
    t0 = time()
    res = call!(p, "session/prompt", Dict(
        "sessionId" => sid,
        "prompt" => [Dict("type" => "text", "text" => prompt)]))
    dt = round(time() - t0; digits = 1)

    println("\n\n── turn ended in $(dt)s: stopReason=$(get(res, "stopReason", "?")) ──")
    println("\nsession/update subtypes seen:")
    isempty(p.updates) && println("  (none)")
    for (k, v) in sort(collect(p.updates); by = last, rev = true)
        println("  $(lpad(v, 5))  $k")
    end
    println("\nagent→client requests seen:")
    isempty(p.inbound) && println("  (none)")
    for (k, v) in sort(collect(p.inbound); by = last, rev = true)
        println("  $(lpad(v, 5))  $k")
    end
    println("\nraw frames: $(joinpath(logdir, "frames.ndjson"))")

    close(p.raw)
    kill(p.proc)
end

main()

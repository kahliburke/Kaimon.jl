# ── Shared Stress Test Infrastructure ────────────────────────────────────────
# Extracted from tui.jl so both the TUI Advanced tab and the `stress_test` MCP
# tool can reuse the same script generation, parsing, and formatting logic.

using Dates

"""Port the MCP HTTP server is listening on. Set by the TUI on server start."""
const GATE_PORT = Ref{Int}(3000)

# Parsed agent result from stress test output lines
mutable struct StressAgentResult
    agent_id::Int
    status::Symbol      # :pending, :init, :sending, :running, :ok, :fail
    elapsed::Float64
    events::Int
    progress::Int
    message::String
end

"""Write the self-contained stress test script to a temp file. Returns the path."""
function _write_stress_script()::String
    path = joinpath(tempdir(), "kaimon_stress_$(getpid()).jl")
    write(path, _STRESS_SCRIPT_SOURCE)
    return path
end

const _STRESS_SCRIPT_SOURCE = """
using HTTP, JSON, Dates

# ── Args: port session code --stress N --stagger S --timeout T ──
port = parse(Int, ARGS[1])
session = ARGS[2]
code = ARGS[3]
num_agents = parse(Int, ARGS[4])
stagger = parse(Float64, ARGS[5])
timeout = parse(Int, ARGS[6])

BASE_URL = "http://localhost:\$(port)/mcp"

function load_api_key()
    cfg = joinpath(homedir(), ".config", "kaimon", "security.json")
    isfile(cfg) || return nothing
    try
        data = JSON.parse(read(cfg, String))
        keys = get(data, "api_keys", [])
        isempty(keys) ? nothing : first(keys)
    catch
        nothing
    end
end

const API_KEY = load_api_key()

function make_headers(; session_id=nothing)
    h = ["Content-Type" => "application/json", "Accept" => "text/event-stream, application/json"]
    API_KEY !== nothing && push!(h, "Authorization" => "Bearer \$(API_KEY)")
    session_id !== nothing && push!(h, "Mcp-Session-Id" => session_id)
    h
end

function mcp_initialize(agent_id::Int)
    body = JSON.json(Dict(
        "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
        "params" => Dict(
            "protocolVersion" => "2025-11-25",
            "capabilities" => Dict(),
            "clientInfo" => Dict("name" => "stress-agent-\$(agent_id)", "version" => "0.1"),
        ),
    ))
    resp = HTTP.post(BASE_URL, make_headers(), body; status_exception=false, readtimeout=timeout)
    if resp.status != 200
        println("ERROR agent=\$(agent_id) elapsed=0.0 message=init_failed_http_\$(resp.status)")
        return nothing
    end
    sid = nothing
    for (name, value) in resp.headers
        lowercase(name) == "mcp-session-id" && (sid = value; break)
    end
    # Send initialized notification
    notif = JSON.json(Dict("jsonrpc" => "2.0", "method" => "notifications/initialized"))
    HTTP.post(BASE_URL, make_headers(; session_id=sid), notif; status_exception=false)
    println("INIT agent=\$(agent_id) session=\$(something(sid, "?"))")
    return sid
end

function call_tool(session_id::String, agent_id::Int)
    body = JSON.json(Dict(
        "jsonrpc" => "2.0", "id" => 2, "method" => "tools/call",
        "params" => Dict(
            "name" => "ex",
            "arguments" => Dict("e" => code, "q" => false, "ses" => session),
        ),
    ))
    event_count = 0
    progress_count = 0
    t0 = time()
    ok = false
    try
        HTTP.open("POST", BASE_URL, make_headers(; session_id);
                  status_exception=false, readtimeout=timeout) do io
            write(io, body)
            HTTP.closewrite(io)
            resp = HTTP.startread(io)
            ct = ""
            for (name, value) in resp.headers
                lowercase(name) == "content-type" && (ct = value; break)
            end
            if resp.status != 200
                println("ERROR agent=\$(agent_id) elapsed=\$(round(time()-t0,digits=2)) message=http_\$(resp.status)")
                return
            end
            if !contains(ct, "event-stream")
                ok = true
                println("RESULT agent=\$(agent_id) elapsed=\$(round(time()-t0,digits=2)) events=1 progress=0 ok=true")
                return
            end
            while !eof(io)
                line = try String(readline(io)) catch e; e isa EOFError ? break : rethrow(); end
                startswith(line, "data: ") || continue
                data_str = line[7:end]
                event_count += 1
                elapsed = round(time() - t0, digits=2)
                try
                    parsed = JSON.parse(data_str)
                    method = get(parsed, "method", nothing)
                    if method == "notifications/progress"
                        progress_count += 1
                        params = get(parsed, "params", Dict())
                        step = get(params, "progress", "?")
                        msg = get(params, "message", "")
                        println("PROGRESS agent=\$(agent_id) elapsed=\$(elapsed) step=\$(step) message=\$(first(string(msg), 80))")
                    elseif haskey(parsed, "result")
                        ok = true
                        content = get(get(parsed, "result", Dict()), "content", [])
                        text = length(content) > 0 ? get(content[1], "text", "") : ""
                        display_text = length(text) > 120 ? first(text, 120) * "..." : text
                        println("RESULT agent=\$(agent_id) elapsed=\$(elapsed) events=\$(event_count) progress=\$(progress_count) ok=true result=\$(display_text)")
                    elseif haskey(parsed, "error")
                        err = get(parsed, "error", Dict())
                        println("ERROR agent=\$(agent_id) elapsed=\$(elapsed) message=\$(get(err, "message", "unknown"))")
                    end
                catch
                    # skip unparseable
                end
            end
        end
    catch e
        elapsed = round(time() - t0, digits=2)
        msg = sprint(showerror, e; context=:compact => true)
        println("ERROR agent=\$(agent_id) elapsed=\$(elapsed) message=\$(first(msg, 120))")
    end
    if !ok
        elapsed = round(time() - t0, digits=2)
        println("RESULT agent=\$(agent_id) elapsed=\$(elapsed) events=\$(event_count) progress=\$(progress_count) ok=false")
    end
end

# ── Main ──
println("START agents=\$(num_agents) stagger=\$(stagger) timeout=\$(timeout)")

# Phase 1: Initialize
sessions = Pair{Int,String}[]
for i in 1:num_agents
    sid = mcp_initialize(i)
    sid !== nothing && push!(sessions, i => sid)
end

if isempty(sessions)
    println("SUMMARY total_time=0.0 succeeded=0 failed=\$(num_agents) fastest=0.0 slowest=0.0 mean=0.0")
    exit(0)
end

# Phase 2: Fire concurrently
println("SEND_ALL count=\$(length(sessions))")
t_global = time()

tasks = Task[]
for (idx, (agent_id, sid)) in enumerate(sessions)
    t = @async begin
        if stagger > 0 && idx > 1
            sleep(stagger * (idx - 1))
        end
        println("SEND agent=\$(agent_id)")
        call_tool(sid, agent_id)
    end
    push!(tasks, t)
end

for t in tasks
    try fetch(t) catch end
end

total_time = round(time() - t_global, digits=2)

# Phase 3: Summary
println("SUMMARY total_time=\$(total_time) succeeded=\$(length(sessions)) failed=\$(num_agents - length(sessions)) fastest=0.0 slowest=0.0 mean=0.0")
println("DONE")
"""

"""Parse a key=value pair from a stress test output line."""
function _parse_stress_kv(line::AbstractString)
    d = Dict{String,String}()
    for m in eachmatch(r"(\w+)=(\S+)", line)
        d[m.captures[1]] = m.captures[2]
    end
    d
end

"""Parse all RESULT/ERROR lines into StressAgentResult structs."""
function _parse_stress_results(output::Vector{String})::Vector{StressAgentResult}
    agents = Dict{Int,StressAgentResult}()
    for line in output
        if startswith(line, "INIT ")
            kv = _parse_stress_kv(line)
            aid = tryparse(Int, get(kv, "agent", ""))
            aid === nothing && continue
            agents[aid] = StressAgentResult(aid, :init, 0.0, 0, 0, "")
        elseif startswith(line, "SEND ")
            kv = _parse_stress_kv(line)
            aid = tryparse(Int, get(kv, "agent", ""))
            aid === nothing && continue
            haskey(agents, aid) && (agents[aid].status = :sending)
        elseif startswith(line, "PROGRESS ")
            kv = _parse_stress_kv(line)
            aid = tryparse(Int, get(kv, "agent", ""))
            aid === nothing && continue
            if haskey(agents, aid)
                agents[aid].status = :running
                agents[aid].progress += 1
                e = tryparse(Float64, get(kv, "elapsed", "0"))
                e !== nothing && (agents[aid].elapsed = e)
            end
        elseif startswith(line, "RESULT ")
            kv = _parse_stress_kv(line)
            aid = tryparse(Int, get(kv, "agent", ""))
            aid === nothing && continue
            if !haskey(agents, aid)
                agents[aid] = StressAgentResult(aid, :pending, 0.0, 0, 0, "")
            end
            a = agents[aid]
            a.status = get(kv, "ok", "false") == "true" ? :ok : :fail
            e = tryparse(Float64, get(kv, "elapsed", "0"))
            e !== nothing && (a.elapsed = e)
            ev = tryparse(Int, get(kv, "events", "0"))
            ev !== nothing && (a.events = ev)
            p = tryparse(Int, get(kv, "progress", "0"))
            p !== nothing && (a.progress = p)
            a.message = get(kv, "result", "")
        elseif startswith(line, "ERROR ")
            kv = _parse_stress_kv(line)
            aid = tryparse(Int, get(kv, "agent", ""))
            aid === nothing && continue
            if !haskey(agents, aid)
                agents[aid] = StressAgentResult(aid, :pending, 0.0, 0, 0, "")
            end
            a = agents[aid]
            a.status = :fail
            e = tryparse(Float64, get(kv, "elapsed", "0"))
            e !== nothing && (a.elapsed = e)
            a.message = get(kv, "message", "unknown")
        end
    end
    sorted = sort(collect(values(agents)); by = a -> a.agent_id)
    return sorted
end

"""
Write stress test results to a file (standalone, no TUI dependency).
Returns the file path written, or `nothing` on failure.
"""
function _write_stress_results_to_file(
    output::Vector{String},
    code,
    sess_key,
    n_agents,
    stagger,
    timeout,
)::Union{String,Nothing}
    results_dir = joinpath(kaimon_cache_dir(), "stress_results")
    mkpath(results_dir)
    ts = Dates.format(now(), "yyyy-mm-dd_HHMMSS")
    path = joinpath(results_dir, "$(ts).txt")
    try
        open(path, "w") do io
            println(io, "# Kaimon Stress Test Results")
            println(io, "# Date: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
            println(io, "# Code: $code")
            println(io, "# Session: $sess_key")
            println(io, "# Agents: $n_agents")
            println(io, "# Stagger: $(stagger)s")
            println(io, "# Timeout: $(timeout)s")
            println(io, "#")
            println(io)
            for line in output
                println(io, line)
            end
        end
        return path
    catch
        return nothing
    end
end

"""
Format parsed stress test results into a structured text summary for MCP tool return.
"""
function _format_stress_summary(
    agents::Vector{StressAgentResult},
    code::String,
    sess_key::String,
    n_agents::Int,
    stagger::Float64,
    timeout::Int,
    total_wall_time::Float64,
    result_file::Union{String,Nothing},
)::String
    buf = IOBuffer()
    println(buf, "Stress Test Results")
    println(buf, "===================")
    println(buf, "Code: $code")
    println(buf, "Agents: $n_agents | Stagger: $(stagger)s | Timeout: $(timeout)s")
    println(buf, "Session: $sess_key")
    println(buf)
    println(buf, "Per-Agent Results:")
    for a in agents
        status_str = a.status == :ok ? "OK  " : "FAIL"
        line = "  Agent $(a.agent_id): $status_str  elapsed=$(round(a.elapsed, digits=2))s  events=$(a.events)  progress=$(a.progress)"
        if a.status == :fail && !isempty(a.message)
            line *= "  message=$(first(a.message, 80))"
        end
        println(buf, line)
    end
    println(buf)

    succeeded = count(a -> a.status == :ok, agents)
    failed = length(agents) - succeeded
    total = length(agents)
    pct = total > 0 ? round(Int, 100 * succeeded / total) : 0

    ok_elapsed = [a.elapsed for a in agents if a.status == :ok]
    fastest = isempty(ok_elapsed) ? 0.0 : minimum(ok_elapsed)
    slowest = isempty(ok_elapsed) ? 0.0 : maximum(ok_elapsed)
    mean_t = isempty(ok_elapsed) ? 0.0 : sum(ok_elapsed) / length(ok_elapsed)

    println(buf, "Summary:")
    println(buf, "  Succeeded: $succeeded/$total ($pct%)")
    println(buf, "  Failed: $failed/$total")
    println(
        buf,
        "  Fastest: $(round(fastest, digits=2))s | Slowest: $(round(slowest, digits=2))s | Mean: $(round(mean_t, digits=2))s",
    )
    println(buf, "  Total wall time: $(round(total_wall_time, digits=2))s")

    if result_file !== nothing
        println(buf)
        println(buf, "Results saved to: $result_file")
    end

    return String(take!(buf))
end

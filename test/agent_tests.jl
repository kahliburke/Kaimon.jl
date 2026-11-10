using ReTest
using Kaimon

# An agent handle that is never driven: for a session whose policy alone is under test.
struct OnlyTestHandle <: Kaimon.AgentHandle end

# Replay a sequence of stream-JSON objects through the mapper, collecting every emitted
# ACP event (mirrors what _start_reader! does line-by-line). Shares one session_id Ref.
function _agent_map_seq(objs)
    sid = Ref("")
    tool_blocks = Dict{Int,String}()
    evs = Kaimon.ACP.AgentEvent[]
    for o in objs
        append!(evs, Kaimon._map_claude_event(o, sid, tool_blocks))
    end
    evs
end

@testset "Agent session: ACP + ClaudeBackend mapping" begin

    @testset "envelope: delta flag on text/thought chunks" begin
        ACP = Kaimon.ACP
        # default = a complete, authoritative block
        e = ACP.AgentMessageChunk(ACP.TextBlock("hi"))
        @test e.delta == false
        env = ACP.envelope(e, 3)
        @test env.kind == :assistant_text
        @test env.turn == 3
        @test env.data["delta"] == false
        @test env.data["content"]["text"] == "hi"

        # explicit incremental chunk
        d = ACP.AgentMessageChunk(ACP.TextBlock("to"), true)
        @test d.delta == true
        @test ACP.envelope(d, 3).data["delta"] == true

        # thoughts carry delta the same way
        th = ACP.AgentThoughtChunk(ACP.TextBlock("hmm"), true)
        tenv = ACP.envelope(th, 1)
        @test tenv.kind == :thought
        @test tenv.data["delta"] == true
        @test ACP.AgentThoughtChunk(ACP.TextBlock("x")).delta == false
    end

    @testset "envelope: image content round-trips" begin
        ACP = Kaimon.ACP
        img = ACP.AgentMessageChunk(ACP.ImageBlock("BASE64", "image/png"))
        d = ACP.envelope(img, 1).data["content"]
        @test d["type"] == "image"
        @test d["data"] == "BASE64"
        @test d["mimeType"] == "image/png"
    end

    @testset "map complete assistant/user/result events" begin
        ACP = Kaimon.ACP
        sid = Ref("")
        # system → captures session id, emits nothing
        @test isempty(Kaimon._map_claude_event(
            Dict("type" => "system", "session_id" => "sess-1"), sid))
        @test sid[] == "sess-1"

        # assistant: text + thinking + tool_use (all complete → delta=false)
        evs = Kaimon._map_claude_event(Dict(
                "type" => "assistant",
                "message" => Dict("content" => [
                    Dict("type" => "text", "text" => "hello"),
                    Dict("type" => "thinking", "thinking" => "reasoning"),
                    Dict("type" => "tool_use", "id" => "tu1", "name" => "Read",
                         "input" => Dict("file" => "a.jl")),
                ])), sid)
        @test length(evs) == 3
        @test evs[1] isa ACP.AgentMessageChunk && evs[1].delta == false && evs[1].content.text == "hello"
        @test evs[2] isa ACP.AgentThoughtChunk && evs[2].delta == false && evs[2].content.text == "reasoning"
        @test evs[3] isa ACP.ToolCallStarted && evs[3].call.tool_call_id == "tu1" && evs[3].call.kind == :read

        # user tool_result → ToolCallUpdated (completed)
        uevs = Kaimon._map_claude_event(Dict(
                "type" => "user",
                "message" => Dict("content" => [
                    Dict("type" => "tool_result", "tool_use_id" => "tu1",
                         "is_error" => false, "content" => "ok"),
                ])), sid)
        @test length(uevs) == 1
        @test uevs[1] isa ACP.ToolCallUpdated && uevs[1].update.status == :completed

        # result → TurnEnded with usage; cost is WIP/zeroed (claude's reported
        # total_cost_usd is ignored for now — see _claude_usage)
        revs = Kaimon._map_claude_event(Dict(
                "type" => "result", "stop_reason" => "end_turn", "total_cost_usd" => 0.02,
                "usage" => Dict("input_tokens" => 100, "output_tokens" => 50)), sid)
        @test length(revs) == 1
        @test revs[1] isa ACP.TurnEnded && revs[1].stop_reason == :end_turn
        @test revs[1].usage.cost_usd == 0.0   # zeroed regardless of reported cost
        @test revs[1].usage.input_tokens == 100
    end

    @testset "failed result surfaces AgentError + :refusal" begin
        ACP = Kaimon.ACP
        sid = Ref("")
        # An errored turn (e.g. API overloaded) must surface the CLI's error detail as an
        # AgentError before the terminal TurnEnded, so observers/governor can classify it.
        evs = Kaimon._map_claude_event(Dict(
                "type" => "result", "is_error" => true,
                "subtype" => "error_during_execution",
                "result" => "API Error: 429 overloaded_error",
                "usage" => Dict("input_tokens" => 10, "output_tokens" => 0)), sid)
        @test length(evs) == 2
        @test evs[1] isa ACP.AgentError
        @test occursin("overloaded", evs[1].message)
        @test evs[1].data["subtype"] == "error_during_execution"
        @test evs[1].data["is_error"] === true
        @test evs[2] isa ACP.TurnEnded && evs[2].stop_reason == :refusal
        @test evs[2].usage.input_tokens == 10   # usage still captured on failure

        # No error text → falls back to subtype for the message; clean turn → no AgentError.
        ev2 = Kaimon._map_claude_event(Dict(
                "type" => "result", "is_error" => true, "subtype" => "error_max_turns"), sid)
        @test ev2[1] isa ACP.AgentError && occursin("error_max_turns", ev2[1].message)
        ok = Kaimon._map_claude_event(Dict("type" => "result", "is_error" => false), sid)
        @test length(ok) == 1 && ok[1] isa ACP.TurnEnded && ok[1].stop_reason == :end_turn
    end

    @testset "map partial-message stream (token deltas)" begin
        ACP = Kaimon.ACP
        # Synthetic --include-partial-messages sequence:
        # content_block_start (text) → N text_delta → content_block_stop → complete assistant
        chunks = ["The", " two-state", " paramagnet"]
        seq = Any[
            Dict("type" => "stream_event",
                 "event" => Dict("type" => "content_block_start", "index" => 0,
                                 "content_block" => Dict("type" => "text", "text" => ""))),
        ]
        for c in chunks
            push!(seq, Dict("type" => "stream_event",
                "event" => Dict("type" => "content_block_delta", "index" => 0,
                                "delta" => Dict("type" => "text_delta", "text" => c))))
        end
        push!(seq, Dict("type" => "stream_event",
            "event" => Dict("type" => "content_block_stop", "index" => 0)))
        full = join(chunks)
        push!(seq, Dict("type" => "assistant",
            "message" => Dict("content" => [Dict("type" => "text", "text" => full)])))

        evs = _agent_map_seq(seq)
        deltas = [e for e in evs if e isa ACP.AgentMessageChunk && e.delta]
        finals = [e for e in evs if e isa ACP.AgentMessageChunk && !e.delta]

        # start/stop emit nothing; only the deltas + one complete block reach the bus
        @test length(evs) == length(chunks) + 1
        @test length(deltas) == length(chunks)   # acceptance: ≥2 deltas before the final
        @test length(finals) == 1
        # order preserved, and concat(deltas) == authoritative final text
        @test [d.content.text for d in deltas] == chunks
        @test join(d.content.text for d in deltas) == finals[1].content.text == full
    end

    @testset "map thinking deltas" begin
        ACP = Kaimon.ACP
        ev = Kaimon._map_claude_event(Dict("type" => "stream_event",
                "event" => Dict("type" => "content_block_delta", "index" => 0,
                                "delta" => Dict("type" => "thinking_delta",
                                                "thinking" => "because"))), Ref(""))
        @test length(ev) == 1
        @test ev[1] isa ACP.AgentThoughtChunk && ev[1].delta == true && ev[1].content.text == "because"
    end

    @testset "map tool-use input streaming" begin
        ACP = Kaimon.ACP
        # content_block_start(tool_use) → N input_json_delta → content_block_stop →
        # complete assistant tool_use (the cell's code typing in live, then authoritative)
        frags = ["{\"code\":\"", "plot(x)", "\"}"]
        seq = Any[
            Dict("type" => "stream_event",
                 "event" => Dict("type" => "content_block_start", "index" => 1,
                                 "content_block" => Dict("type" => "tool_use",
                                     "id" => "toolu_1", "name" => "slate_add_cell"))),
        ]
        for f in frags
            push!(seq, Dict("type" => "stream_event",
                "event" => Dict("type" => "content_block_delta", "index" => 1,
                                "delta" => Dict("type" => "input_json_delta", "partial_json" => f))))
        end
        push!(seq, Dict("type" => "stream_event",
            "event" => Dict("type" => "content_block_stop", "index" => 1)))
        push!(seq, Dict("type" => "assistant",
            "message" => Dict("content" => [
                Dict("type" => "tool_use", "id" => "toolu_1", "name" => "slate_add_cell",
                     "input" => Dict("code" => "plot(x)"))])))

        evs = _agent_map_seq(seq)
        # 1) the call is announced up front, before its args finish
        @test evs[1] isa ACP.ToolCallStarted
        @test evs[1].call.tool_call_id == "toolu_1"
        @test evs[1].call.status == :in_progress
        @test evs[1].call.raw_input === nothing
        # 2) input streams as ordered fragments addressed to the call
        ideltas = [e for e in evs if e isa ACP.ToolInputDelta]
        @test length(ideltas) == length(frags)
        @test all(d -> d.tool_call_id == "toolu_1", ideltas)
        @test [d.partial_json for d in ideltas] == frags
        @test join(d.partial_json for d in ideltas) == "{\"code\":\"plot(x)\"}"
        # 3) the final message re-emits the call as an authoritative tool_use carrying
        #    the full parsed input — the second tool_use for the id (replace by id)
        @test evs[end] isa ACP.ToolCallStarted
        @test evs[end].call.tool_call_id == "toolu_1"
        @test evs[end].call.raw_input == Dict("code" => "plot(x)")
        @test count(e -> e isa ACP.ToolCallStarted, evs) == 2   # announce + authoritative
        # envelope shape
        env = ACP.envelope(ideltas[1], 2)
        @test env.kind == :tool_input_delta
        @test env.data["toolCallId"] == "toolu_1"
        @test env.data["partialJson"] == frags[1]
    end

    @testset "ClaudeBackend: an interrupt excuses one turn, and only if it was sent" begin
        # A cancelled turn and a failed one look identical on the wire, so this flag is the only
        # thing that tells them apart — and while it is raised, a genuine error is swallowed.
        proc = open(`sleep 30`, "r+")
        h = Kaimon.ClaudeHandle(Kaimon.ClaudeBackend(; claude_path = "true"), proc,
                                proc.in, proc.out, Channel{Kaimon.ACP.AgentEvent}(Inf),
                                Task(() -> nothing), Ref(0), Ref(""), Dict{Int,String}(),
                                pwd(), "", Ref(0), Ref(false))
        try
            @test Kaimon.backend_interrupt(h)
            @test h.interrupting[]

            # Interrupting an idle agent raises it with no turn in flight, so no result arrives to
            # consume it. Starting a turn lowers it, or that turn reports itself cancelled.
            Kaimon.backend_send(h, "hello")
            @test !h.interrupting[]

            # A write that never left excuses nothing.
            close(proc.in)
            @test !Kaimon.backend_interrupt(h)
            @test !h.interrupting[]
        finally
            try; kill(proc); catch; end
        end
    end

    @testset "ClaudeBackend: stream flag toggles --include-partial-messages" begin
        on  = Kaimon._claude_args(Kaimon.ClaudeBackend(; stream = true), ".")
        off = Kaimon._claude_args(Kaimon.ClaudeBackend(; stream = false), ".")
        @test "--include-partial-messages" in on
        @test !("--include-partial-messages" in off)
        # streaming is on by default
        @test "--include-partial-messages" in Kaimon._claude_args(Kaimon.ClaudeBackend(), ".")
    end

    @testset "ClaudeBackend: `only` makes allowed_tools the whole tool set" begin
        allowed = ["Read", "Bash(git *)", "mcp__kaimon__notes_search", "mcp__kaimon__slate_dbg.frame"]
        tools_flag(b) = (args = Kaimon._claude_args(b, "."); i = findfirst(==("--tools"), args);
                         i === nothing ? nothing : args[i+1])
        # Built-ins: only those named, without argument patterns, and ToolSearch to reach MCP tools.
        @test tools_flag(Kaimon.ClaudeBackend(; allowed_tools = allowed, only = true)) == "Read,Bash,ToolSearch"
        @test tools_flag(Kaimon.ClaudeBackend(; allowed_tools = ["Read", "Write"], only = true)) == "Read,Write"
        @test tools_flag(Kaimon.ClaudeBackend(; only = true)) == ""          # nothing named: no built-ins
        @test tools_flag(Kaimon.ClaudeBackend(; allowed_tools = allowed)) === nothing
        # Kaimon's tools: only those named, in either spelling, or all when the server is named.
        @test Kaimon._only_allows(allowed, "notes_search")
        @test Kaimon._only_allows(allowed, "slate_dbg.frame") && Kaimon._only_allows(allowed, "slate_dbg_frame")
        @test !Kaimon._only_allows(allowed, "ex") && Kaimon._only_allows(["mcp__kaimon"], "ex")

        # Refused at tools/call for the agent that was given them, and only for it.
        aid = "only-test-agent"
        s = Kaimon.AgentSession(aid, Kaimon.ClaudeBackend(; allowed_tools = allowed, only = true), OnlyTestHandle(),
                                ".", "opus", :idle, Task(() -> nothing), time(), time(), Kaimon.ACP.Usage(),
                                Any[], String[], String[], ReentrantLock())
        lock(Kaimon.AGENT_SESSIONS_LOCK) do; Kaimon.AGENT_SESSIONS[aid] = s; end
        try
            @test Kaimon.agent_tool_refusal(aid, "notes_search") === nothing
            @test occursin("not among the tools", Kaimon.agent_tool_refusal(aid, "ex"))
            s.backend = Kaimon.ClaudeBackend(; allowed_tools = allowed)
            @test Kaimon.agent_tool_refusal(aid, "ex") === nothing        # without `only`, as before
        finally
            lock(Kaimon.AGENT_SESSIONS_LOCK) do; delete!(Kaimon.AGENT_SESSIONS, aid); end
        end
        @test_throws ErrorException Kaimon.agent_open(; cwd = ".", model = "acp:opencode", only = true)

        # ACP callback names from the `lab` preset are not CLI tools.
        @test Kaimon._only_builtin_tools(["Read", "fs/read_text_file", "mcp__kaimon__ex"]) == ["Read", "ToolSearch"]
        # Without a config of Kaimon's, an `only` agent gets no MCP servers rather than the user's.
        args = Kaimon._claude_args(Kaimon.ClaudeBackend(; only = true), ".")
        @test "--strict-mcp-config" in args && !("--mcp-config" in args)
        @test !("--strict-mcp-config" in Kaimon._claude_args(Kaimon.ClaudeBackend(), "."))
        # A config without Kaimon's agent header would leave the agent's calls unattributable.
        @test_throws ErrorException Kaimon.agent_open(; cwd = ".", only = true, mcp_config = "/tmp/x.json",
                                                      allowed_tools = ["Read"])
        port = Kaimon.MCP_SERVER_PORT[]
        Kaimon.MCP_SERVER_PORT[] = 0
        try
            @test_throws ErrorException Kaimon.agent_open(; cwd = ".", only = true,
                                                          allowed_tools = ["mcp__kaimon__ex"])
        finally
            Kaimon.MCP_SERVER_PORT[] = port
        end
    end

    @testset "the orphan-agent reaper signals only the process it recorded" begin
        withenv("KAIMON_CACHE_DIR" => mktempdir()) do
            p = run(`$(Base.julia_cmd()) --startup-file=no -e "sleep(60)"`; wait = false)
            try
                pid = getpid(p)
                Kaimon._record_agent_pid!("a1", pid)
                (rpid, started) = Kaimon._read_pid_file()["a1"]
                @test rpid == pid && started == Kaimon.Utils.process_start_id(pid)
                # The same pid with another start time is a different process: left alone, and forgotten.
                Kaimon._write_pid_file(Dict("a1" => (pid, started * "0")))
                Kaimon.reap_orphan_agents!()
                @test process_running(p)
                @test isempty(Kaimon._read_pid_file())
                # A bare pid, as written before start times were kept, is never signalled.
                write(Kaimon._agent_pid_file(), Kaimon.JSON.json(Dict("a1" => pid)))
                @test isempty(Kaimon._read_pid_file())
                Kaimon.reap_orphan_agents!()
                @test process_running(p)
                # The process it recorded is reaped.
                Kaimon._record_agent_pid!("a1", pid)
                Kaimon.reap_orphan_agents!()
                @test timedwait(() -> !process_running(p), 10.0) === :ok
            finally
                process_running(p) && kill(p, Base.SIGKILL)
            end
        end
    end

    @testset "an embedded Kaimon: its own directories, extensions and tools per caller" begin
        # Its own directories, named outright.
        d = mktempdir()
        withenv("KAIMON_CACHE_DIR" => joinpath(d, "c"), "KAIMON_CONFIG_DIR" => joinpath(d, "f")) do
            @test Kaimon.kaimon_cache_dir() == joinpath(d, "c") && Kaimon.kaimon_config_dir() == joinpath(d, "f")
            @test Kaimon._tui_log_path() == joinpath(d, "c", "server.log")
            @test Kaimon.KaimonGate.sock_dir() == joinpath(d, "c", "sock")
            # It reaps only its own extensions: those marked with its id, not the default Kaimon's.
            id = Kaimon._instance_id()
            @test Kaimon._is_this_instance(id) && !Kaimon._is_this_instance(nothing) && !Kaimon._is_this_instance("0123456789ab")
        end
        withenv("KAIMON_CACHE_DIR" => nothing) do
            @test Kaimon._is_this_instance(nothing)              # unmarked: started before the markers, the default's
            cmd(inst) = "julia -e spawned_by=\"extension\" namespace=\\\"slate\\\" " * (inst === nothing ? "" : "kaimon_instance=$inst")
            @test Kaimon._extension_cmdline_matches(cmd(Kaimon._instance_id()), "slate")
            @test Kaimon._extension_cmdline_matches(cmd(nothing), "slate")
            @test !Kaimon._extension_cmdline_matches(cmd("0123456789ab"), "slate")
        end
        # It indexes no code: it shares a Qdrant it must leave alone.
        withenv("KAIMON_CODE_INDEX" => "0") do
            @test !Kaimon.code_indexing()
            @test Kaimon._spawn_fts_coverage_sync!(; delay = 0) === nothing
            @test Kaimon._auto_index_project!(pkgdir(Kaimon)) === nothing
        end
        withenv("KAIMON_CODE_INDEX" => nothing) do
            @test Kaimon.code_indexing()
        end

        # Tools per caller, named on each request by the service in front.
        @test Kaimon._parse_allowed_tools(" notes.search, notes_read ,") == ["notes.search", "notes_read"]
        @test Kaimon._parse_allowed_tools(nothing) === nothing
        s = (; id = "allow-test-session")
        try
            Kaimon._set_request_allowed!(["notes.search", "notes_read"])
            @test Kaimon._refuse_tool_for_session(s, "notes.search", nothing) === nothing
            @test Kaimon._refuse_tool_for_session(s, "notes.read", nothing) === nothing     # either spelling
            @test occursin("not among", Kaimon._refuse_tool_for_session(s, "ex", nothing))
            @test occursin("not among", Kaimon._refuse_tool_for_session(s, "notes.add", nothing))
            Kaimon._set_request_allowed!(String[])                                                # an empty list: nothing
            @test Kaimon._refuse_tool_for_session(s, "notes.search", nothing) !== nothing
            Kaimon._set_request_allowed!(nothing)                                                 # no list: as before
            @test Kaimon._refuse_tool_for_session(s, "ex", nothing) === nothing
            withenv("KAIMON_RESTRICTED" => "1") do                                                # restricted: no list, no tools
                @test Kaimon._refuse_tool_for_session(s, "ex", nothing) !== nothing
                @test Kaimon._refuse_tool_for_session(nothing, "ex", nothing) !== nothing
                Kaimon._set_session_agent_id!(s.id, "some-agent")                                 # an agent's session: its own rules
                @test Kaimon._refuse_tool_for_session(s, "ex", nothing) === nothing
            end

            # The list belongs to the request: two requests on one session, overlapping, are each
            # judged by their own header.
            judged(list, tool) = fetch(@async begin
                Kaimon._set_request_allowed!(list)
                yield()                                       # let the other request set its list
                Kaimon._refuse_tool_for_session(s, tool, nothing)
            end)
            a = @async judged(["notes.search"], "notes.search")
            b = @async judged(["ex"], "notes.search")
            @test fetch(a) === nothing && fetch(b) !== nothing
        finally
            Kaimon._set_request_allowed!(nothing)
            lock(Kaimon._SESSION_AGENT_ID_LOCK) do; delete!(Kaimon._SESSION_AGENT_ID, s.id); end
        end
    end

    @testset "_spawn_argv wraps Windows shim scripts, not native exes" begin
        args = ["--model", "sonnet", "--add-dir", "C:\\a b"]
        # Windows npm shim (.cmd) → launched via cmd.exe /d /c (CreateProcess can't exec it).
        cmd = Kaimon._spawn_argv(["C:\\npm\\claude.cmd", args...], true)
        @test cmd[1:4] == ["cmd.exe", "/d", "/c", "C:\\npm\\claude.cmd"]
        @test cmd[5:end] == args                                  # original argv preserved after
        # .bat treated the same; .ps1 → PowerShell -File.
        @test Kaimon._spawn_argv(["x.bat"], true)[1:3] == ["cmd.exe", "/d", "/c"]
        @test Kaimon._spawn_argv(["x.ps1"], true)[1:5] ==
              ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
        # Native .exe on Windows → run as-is (no wrapper).
        @test Kaimon._spawn_argv(["C:\\bin\\claude.exe", args...], true) == ["C:\\bin\\claude.exe", args...]
        # Non-Windows → never wrapped, even for a .cmd-looking name.
        @test Kaimon._spawn_argv(["/usr/bin/claude", args...], false) == ["/usr/bin/claude", args...]
        @test Kaimon._spawn_argv(["weird.cmd"], false) == ["weird.cmd"]
        @test Kaimon._spawn_argv(String[], true) == String[]      # empty argv is a no-op
    end

    @testset "agent spawn error is sanitized (never leaks the environment)" begin
        # A real failed spawn raises an IOError whose text embeds `setenv(cmd, env)` — the
        # whole process environment, API keys included. The surfaced error must not contain it.
        leaky = Base.IOError(
            "could not spawn setenv(`claude -p`, [\"ANTHROPIC_API_KEY=sk-secret-XYZ\", " *
            "\"PATH=/x\"]): no such file or directory (ENOENT)", Base.UV_ENOENT)

        for win in (false, true)
            err = Kaimon._agent_spawn_error(leaky, ["claude", "-p"]; iswin = win)
            @test err isa ErrorException
            msg = sprint(showerror, err)
            @test occursin("claude", msg)              # names the CLI that failed
            @test !occursin("sk-secret-XYZ", msg)      # never the secret value
            @test !occursin("ANTHROPIC_API_KEY", msg)  # nor any env at all
        end

        # Windows ENOENT points the user at the npm-shim / native-install remedy.
        win_msg = sprint(showerror, Kaimon._agent_spawn_error(leaky, ["claude"]; iswin = true))
        @test occursin("install", lowercase(win_msg))
        # Non-Windows ENOENT gives a PATH hint, not the Windows shim spiel.
        nix_msg = sprint(showerror, Kaimon._agent_spawn_error(leaky, ["claude"]; iswin = false))
        @test occursin("PATH", nix_msg)

        # A non-ENOENT spawn failure still never leaks the env.
        other = Base.IOError(
            "could not spawn setenv(`claude`, [\"ANTHROPIC_API_KEY=sk-x\"])", Base.UV_EACCES)
        om = sprint(showerror, Kaimon._agent_spawn_error(other, ["claude"]; iswin = false))
        @test !occursin("sk-x", om)
        @test occursin("claude", om)
    end

    @testset "Utils.launch_argv resolves bare CLI names via which" begin
        U = Kaimon.Utils
        # Bare name → resolved by `which` to a .cmd shim → launched through cmd.exe.
        @test U.launch_argv(["claude", "mcp", "list"]; iswin = true,
            which = _ -> "C:\\npm\\claude.cmd") ==
            ["cmd.exe", "/d", "/c", "C:\\npm\\claude.cmd", "mcp", "list"]
        # Resolves to a native .exe → run the resolved path unwrapped.
        @test U.launch_argv(["claude"]; iswin = true, which = _ -> "C:\\bin\\claude.exe") ==
            ["C:\\bin\\claude.exe"]
        # .ps1 shim → PowerShell -File.
        @test U.launch_argv(["x"]; iswin = true, which = _ -> "C:\\x.ps1")[1:5] ==
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
        # Not found on PATH → keep the bare name (run() then errors/handled as before).
        @test U.launch_argv(["nope", "a"]; iswin = true, which = _ -> nothing) == ["nope", "a"]
        # Non-Windows → never touched, regardless of what which would return.
        @test U.launch_argv(["claude", "x"]; iswin = false, which = _ -> "C:\\claude.cmd") ==
            ["claude", "x"]

        # Sys.which misses the shim (only finds .exe on Windows) → PATHEXT fallback resolves it
        # and the .cmd is still wrapped. This is the real npm-shim case (Sys.which("claude")=nothing).
        @test U.launch_argv(["claude", "mcp"]; iswin = true, which = _ -> nothing,
            which_ext = _ -> "C:\\npm\\claude.cmd") ==
            ["cmd.exe", "/d", "/c", "C:\\npm\\claude.cmd", "mcp"]
        # Neither which nor the PATHEXT search finds it → bare name kept (handled by the
        # sanitized spawn error downstream).
        @test U.launch_argv(["claude"]; iswin = true, which = _ -> nothing,
            which_ext = _ -> nothing) == ["claude"]
    end

    @testset "Utils._which_pathext searches PATH × PATHEXT (the Sys.which .exe-only gap)" begin
        U = Kaimon.Utils
        pathext = ".COM;.EXE;.BAT;.CMD"
        path = "C:\\a;C:\\npm"
        # Build expected paths the same way the function does (`joinpath`), so the test is
        # host-agnostic (macOS joins with `/`, Windows with `\`).
        claude_cmd = joinpath("C:\\npm", "claude.cmd")
        @test U._which_pathext("claude"; path = path, pathext = pathext,
            exists = p -> p == claude_cmd) == claude_cmd   # Sys.which would return nothing here
        # PATHEXT order wins: prefer .EXE over .CMD when both exist in the same dir.
        tool_exe = joinpath("C:\\a", "tool.exe")
        tool_cmd = joinpath("C:\\a", "tool.cmd")
        @test U._which_pathext("tool"; path = path, pathext = pathext,
            exists = p -> p in (tool_exe, tool_cmd)) == tool_exe
        # Nothing on PATH → nothing.
        @test U._which_pathext("ghost"; path = path, pathext = pathext,
            exists = _ -> false) === nothing
        # A name that's already a path is not a bare name → nothing (caller handles it).
        @test U._which_pathext("C:\\x\\claude"; path = path, pathext = pathext,
            exists = _ -> true) === nothing
    end

    @testset "image downscale (tool-result PNG)" begin
        PF = Kaimon.PNGFiles
        B64 = Kaimon.Base64
        C = Kaimon.RGBA{Kaimon.N0f8}
        # a wide 80×2000 PNG (long edge 2000, over the default 1568 cap)
        wide = [C(0.3, 0.6, 0.9, 1) for _ in 1:80, _ in 1:2000]
        io = IOBuffer(); PF.save(io, wide); b64 = B64.base64encode(take!(io))

        # default cap 1568 → box factor cld(2000,1568)=2 → long edge halved to 1000
        out = Kaimon._downscale_png_b64(b64, 1568)
        @test out != b64
        dec = PF.load(IOBuffer(B64.base64decode(out)))
        @test maximum(size(dec)) == 1000
        @test maximum(size(dec)) <= 1568

        # already within bound → byte-identical passthrough
        small = [C(0.1, 0.1, 0.1, 1) for _ in 1:50, _ in 1:50]
        io2 = IOBuffer(); PF.save(io2, small); sb64 = B64.base64encode(take!(io2))
        @test Kaimon._downscale_png_b64(sb64, 1568) == sb64

        # max_edge ≤ 0 disables; garbage never throws (returns input)
        @test Kaimon._downscale_png_b64(b64, 0) == b64
        @test Kaimon._downscale_png_b64("not-a-png", 100) == "not-a-png"

        # config reader returns a positive default
        @test Kaimon._agent_image_max_edge() isa Int && Kaimon._agent_image_max_edge() > 0
    end

    @testset "MCP tool-result image content blocks" begin
        PF = Kaimon.PNGFiles
        B64 = Kaimon.Base64
        C = Kaimon.RGBA{Kaimon.N0f8}
        KG = Kaimon.KaimonGate
        png(img) = (io = IOBuffer(); PF.save(io, img); take!(io))

        # image_result builds a sentinel-tagged envelope; bytes round-trip
        small = [C(0.2, 0.4, 0.8, 1) for _ in 1:40, _ in 1:60]   # 40×60, within any cap
        sbytes = png(small)
        env = KG.image_result(sbytes; text = "hello plot")
        @test startswith(env, KG.MCP_CONTENT_SENTINEL)
        # Kaimon.image_result delegates to the same envelope
        @test Kaimon.image_result(sbytes; text = "hello plot") == env

        # _build_tool_content: plain text stays a single text block, no error
        c, e = Kaimon._build_tool_content("just text")
        @test e == false
        @test length(c) == 1 && c[1]["type"] == "text" && c[1]["text"] == "just text"

        # envelope with text + image → ordered [text, image]; small image passes through
        c, e = Kaimon._build_tool_content(env)
        @test e == false
        @test length(c) == 2
        @test c[1]["type"] == "text" && c[1]["text"] == "hello plot"
        @test c[2]["type"] == "image" && c[2]["mimeType"] == "image/png"
        dec = PF.load(IOBuffer(B64.base64decode(c[2]["data"])))
        @test size(dec) == (40, 60)   # within cap → not resized

        # image-only envelope (no text) → single image block
        c, e = Kaimon._build_tool_content(KG.image_result(sbytes))
        @test length(c) == 1 && c[1]["type"] == "image"

        # an oversized image is downscaled at egress (the cost lever): default cap 1024
        wide = [C(0.3, 0.6, 0.9, 1) for _ in 1:80, _ in 1:2000]   # long edge 2000
        c, e = Kaimon._build_tool_content(KG.image_result(png(wide)))
        big = PF.load(IOBuffer(B64.base64decode(c[1]["data"])))
        @test maximum(size(big)) <= Kaimon._tool_image_max_edge()
        @test maximum(size(big)) == 1000   # cld(2000,1024)=2 → halved

        # isError flag rides through the envelope
        errenv = KG.MCP_CONTENT_SENTINEL *
                 "{\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}"
        c, e = Kaimon._build_tool_content(errenv)
        @test e == true && c[1]["text"] == "boom"

        # malformed envelope never drops the result — falls back to text
        bad = KG.MCP_CONTENT_SENTINEL * "not json{"
        c, e = Kaimon._build_tool_content(bad)
        @test e == false && length(c) == 1 && c[1]["type"] == "text" && c[1]["text"] == bad

        # text with embedded quotes/newlines survives JSON escaping
        c, _ = Kaimon._build_tool_content(KG.image_result(sbytes; text = "a\"b\nc"))
        @test c[1]["text"] == "a\"b\nc"

        # log-safe stand-in: envelopes collapse, plain text is untouched
        @test startswith(Kaimon._tool_result_log_text(env), "[MCP rich content")
        @test Kaimon._tool_result_log_text("plain") == "plain"

        # config reader: positive Int default
        @test Kaimon._tool_image_max_edge() isa Int && Kaimon._tool_image_max_edge() > 0
    end

    @testset "control_response + cancel mapping (interrupt path)" begin
        ACP = Kaimon.ACP
        # an error ack is surfaced as an AgentError (so a rejected interrupt is visible)
        e = Kaimon._map_claude_event(Dict("type" => "control_response",
                "response" => Dict("subtype" => "error", "request_id" => "int-1",
                                   "error" => "not interruptible")), Ref(""))
        @test length(e) == 1
        @test e[1] isa ACP.AgentError && occursin("not interruptible", e[1].message)
        # a success ack needs no user-facing event
        @test isempty(Kaimon._map_claude_event(Dict("type" => "control_response",
            "response" => Dict("subtype" => "success", "request_id" => "int-2")), Ref("")))
        # a cancelled turn surfaces as result{stopReason: cancelled}
        r = Kaimon._map_claude_event(Dict("type" => "result", "stop_reason" => "cancelled"), Ref(""))
        @test r[1] isa ACP.TurnEnded && r[1].stop_reason == :cancelled
    end
end

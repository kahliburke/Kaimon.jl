# ─────────────────────────────────────────────────────────────────────────────
# KaimonGate · debug/breakpoint protocol + Infiltrator integration  (split from gate.jl; part of the KaimonGate module)
# ─────────────────────────────────────────────────────────────────────────────

# ── Debug Breakpoint State ───────────────────────────────────────────────────
# Programmatic breakpoint system for agent-assisted debugging.
# _breakpoint_hook() blocks the calling thread and communicates with the
# gate's message loop via Channels, allowing agents to inspect locals and
# eval expressions in the paused context.

const _DEBUG_PAUSED = Ref{Any}(nothing)        # NamedTuple with pause info, or nothing
const _DEBUG_RESUME_CH = Ref{Any}(nothing)      # Channel{Symbol} — :continue
const _DEBUG_EVAL_CH = Ref{Any}(nothing)        # Channel{Pair{String, Channel{Any}}}
const _INFILTRATOR_HOOKED = Ref(false)          # true once _install_infiltrator_hook! succeeds
const _INFILTRATOR_DISABLED = Ref(false)        # true after explicit uninstall — suppresses callback
const _INFILTRATOR_ORIG_PROMPT = Ref{Any}(nothing)  # original start_prompt method for restore

"""
    _breakpoint_hook(locals::Dict{Symbol,Any}; file="unknown", line=0)

Programmatic breakpoint for agent-assisted debugging. Pauses execution,
publishes breakpoint info via the PUB socket, and blocks until an agent
sends a continue command via the debug protocol.

Insert into code as:
    KaimonGate._breakpoint_hook(Base.@locals; file=@__FILE__, line=@__LINE__)
"""
function _breakpoint_hook(locals::Dict{Symbol,Any}; file::String = "unknown", line::Int = 0)
    # Keep Infiltrator's async check disabled so subsequent @infiltrate calls work
    Infiltrator = _find_infiltrator()
    if Infiltrator !== nothing
        isdefined(Infiltrator, :toggle_async_check) && Infiltrator.toggle_async_check(false)
        isdefined(Infiltrator, :clear_disabled!) && Infiltrator.clear_disabled!()
    end

    info = (
        file = file,
        line = line,
        locals = Dict(string(k) => sprint(show, MIME"text/plain"(), v; context = :limit => true) for (k, v) in locals),
        locals_types = Dict(string(k) => string(typeof(v)) for (k, v) in locals),
    )
    _publish_stream("breakpoint_hit", _serialize_result(info))

    resume_ch = Channel{Symbol}(1)
    eval_ch = Channel{Pair{String,Channel{Any}}}(32)
    _DEBUG_PAUSED[] = info
    _DEBUG_RESUME_CH[] = resume_ch
    _DEBUG_EVAL_CH[] = eval_ch

    # Process eval requests while paused — single persistent module so
    # assignments survive across evals and Infiltrator macros are available.
    eval_mod = Module()
    for (k, v) in locals
        Core.eval(eval_mod, Expr(:(=), k, QuoteNode(v)))
    end
    # Import Infiltrator exports (@exfiltrate etc.) if available
    try
        Core.eval(eval_mod, :(using Infiltrator))
    catch; end
    @async begin
        for (code, result_ch) in eval_ch
            try
                val = Base.invokelatest(Core.eval, eval_mod, Meta.parse(code))
                put!(result_ch, sprint(show, MIME"text/plain"(), val; context = :limit => true))
            catch e
                put!(result_ch, "ERROR: " * sprint(showerror, e))
            end
        end
    end

    try
        take!(resume_ch)
    catch e
        # Let the user break out of a paused breakpoint locally (Ctrl-C) instead
        # of being stuck until an agent resumes it (#34). Any failure to wait
        # (interrupt or a closed channel during shutdown) just resumes execution.
        e isa InterruptException || e isa InvalidStateException || rethrow()
        @info "Breakpoint released locally"
    end
    close(eval_ch)
    _DEBUG_PAUSED[] = nothing
    _DEBUG_RESUME_CH[] = nothing
    _DEBUG_EVAL_CH[] = nothing
    _publish_stream("breakpoint_resumed", "")
    return nothing
end

"""
    _install_infiltrator_hook!()

Override `Infiltrator.start_prompt` so that `@infiltrate` routes through the
gate's breakpoint system instead of opening an interactive REPL prompt.
Called automatically when `Infiltrator` is detected during `serve()`.

This also disables Infiltrator's async-context check (which would block
`@infiltrate` inside gate evals that run on spawned threads).
"""
function _find_infiltrator()
    for (pkgid, mod) in Base.loaded_modules
        pkgid.name == "Infiltrator" && return mod
    end
    return nothing
end

function _install_infiltrator_hook!()
    Infiltrator = _find_infiltrator()
    Infiltrator === nothing && error("Infiltrator not loaded")
    # Disable the async check — gate evals run on spawned threads
    if isdefined(Infiltrator, :toggle_async_check)
        Infiltrator.toggle_async_check(false)
    elseif isdefined(Infiltrator, :CHECK_TASK)
        Infiltrator.CHECK_TASK[] = false
    end
    # Clear any previously disabled infiltration points (from before hook install)
    if isdefined(Infiltrator, :clear_disabled!)
        Infiltrator.clear_disabled!()
    end
    # Save original start_prompt before overriding (for uninstall)
    if _INFILTRATOR_ORIG_PROMPT[] === nothing
        _INFILTRATOR_ORIG_PROMPT[] = Infiltrator.start_prompt
    end
    # (Re)enable routing — a prior stop()/uninstall_infiltrator_hook! set the
    # disabled flag, so a fresh serve() in the same process must clear it.
    _INFILTRATOR_DISABLED[] = false
    # Override start_prompt to route through our breakpoint system. Falls back to
    # the original prompt when the gate is stopped or the hook was disabled, so a
    # breakpoint hit after Gate.stop() opens the normal Infiltrator REPL instead
    # of hanging on a dead gate (#34).
    @eval function ($Infiltrator).start_prompt(
        mod, locals::Dict{Symbol,Any}, file, fileline, ex = nothing, bt = nothing;
        terminal = nothing, repl = nothing, nostack = false,
    )
        M = $(@__MODULE__)
        if M._INFILTRATOR_DISABLED[] || !M._RUNNING[]
            orig = M._INFILTRATOR_ORIG_PROMPT[]
            return orig === nothing ? nothing :
                   orig(mod, locals, file, fileline, ex, bt;
                        terminal = terminal, repl = repl, nostack = nostack)
        end
        M._breakpoint_hook(locals; file = string(file), line = Int(fileline))
    end
    _INFILTRATOR_HOOKED[] = true
    @info "Infiltrator.jl integration active — @infiltrate routes through gate debug protocol"
end

"""
    uninstall_infiltrator_hook!()

Restore Infiltrator's original `start_prompt` so `@infiltrate` opens the normal
interactive REPL prompt instead of routing through the gate debug protocol.
"""
function uninstall_infiltrator_hook!()
    _INFILTRATOR_DISABLED[] = true
    _INFILTRATOR_HOOKED[] || return
    Infiltrator = _find_infiltrator()
    Infiltrator === nothing && return
    orig = _INFILTRATOR_ORIG_PROMPT[]
    if orig !== nothing
        @eval function ($Infiltrator).start_prompt(
            mod, locals::Dict{Symbol,Any}, file, fileline, ex = nothing, bt = nothing;
            terminal = nothing, repl = nothing, nostack = false,
        )
            ($orig)(mod, locals, file, fileline, ex, bt;
                    terminal = terminal, repl = repl, nostack = nostack)
        end
    end
    _INFILTRATOR_HOOKED[] = false
    @info "Infiltrator.jl hook removed — @infiltrate uses default REPL prompt"
end

"""
    infiltrator_routing(on::Bool)

Toggle how `@infiltrate` behaves in this gate-connected REPL, **without stopping the
gate** (#34):

  • `on = true`  — route through the gate debug protocol (agent-driven: a breakpoint
                   pauses and the agent inspects via `debug_ctrl`/`debug_eval`).
  • `on = false` — restore Infiltrator's normal interactive `infil>` prompt so you can
                   debug the session yourself. Eval/tools keep working meanwhile.

Flip it off to poke around a long-running computation yourself, then back on to hand
debugging to the agent — no `restart()`/`serve()` needed. (`on = true` requires
Infiltrator to be loaded.)
"""
infiltrator_routing(on::Bool) = on ? _install_infiltrator_hook!() : uninstall_infiltrator_hook!()



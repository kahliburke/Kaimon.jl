# ─────────────────────────────────────────────────────────────────────────────
# KaimonGate · core eval · output capture · result serialization  (split from gate.jl; part of the KaimonGate module)
# ─────────────────────────────────────────────────────────────────────────────

# ── Core eval logic ──────────────────────────────────────────────────────────
# Extracted from Kaimon's execute_repllike, stripped of MCP-specific concerns
# (truncation, println stripping, prompt display). Those stay on the server side.

function _mirror_print(f::Function)
    try
        f()
    catch e
        e isa Base.IOError && (_MIRROR_REPL[] = false)
    end
end

function gate_eval(code::String; _mod::Module = Main, display_code::String = code)
    # Bounded concurrency: acquire a slot (blocks past the cap). Each eval captures
    # to its own task-local sink (see _eval_with_capture), so concurrent evals don't
    # clobber each other. Snapshot peers/queued AFTER acquiring for the result note.
    Threads.atomic_add!(_EVAL_QUEUED, 1)
    Base.acquire(_eval_semaphore())
    Threads.atomic_sub!(_EVAL_QUEUED, 1)
    Threads.atomic_add!(_EVAL_INFLIGHT, 1)
    peers  = max(0, _EVAL_INFLIGHT[] - 1)   # other evals running alongside this one
    queued = _EVAL_QUEUED[]                  # evals still waiting for a slot
    # Only the PRIMARY eval mirrors to the terminal (header + live output);
    # concurrent evals run headless (captured + streamed to Activity + returned).
    mirror_owned = _MIRROR_REPL[] && _claim_mirror!()
    try
        if mirror_owned
            _mirror_print() do
                printstyled("\nagent> ", color = :red, bold = true)
                print(display_code, "\n")
            end
        end

        # Check REPL availability
        repl =
            (isdefined(Base, :active_repl) && Base.active_repl !== nothing) ?
            Base.active_repl : nothing
        backend =
            repl !== nothing && hasproperty(repl, :backendref) ? repl.backendref : nothing
        has_repl =
            repl !== nothing &&
            backend !== nothing &&
            hasproperty(backend, :repl_channel) &&
            hasproperty(backend, :response_channel) &&
            isopen(backend.repl_channel) &&
            isopen(backend.response_channel)

        expr = Base.parse_input_line(code)

        # Use call_on_backend only from the message loop (synchronous :eval
        # on the interactive thread). Async evals run on default-pool threads
        # via Threads.@spawn — call_on_backend would deadlock because the
        # REPL backend is occupied by the user's interactive session.
        on_interactive = Threads.threadpool(Threads.threadid()) === :interactive
        result = if has_repl && on_interactive
            r = REPL.call_on_backend(() -> _eval_with_capture(expr; mirror = mirror_owned), backend)
            # call_on_backend returns (value, iserr) Pair or NamedTuple
            r isa Pair ? r.first : (r isa Tuple && length(r) == 2 ? r[1] : r)
        else
            _eval_with_capture(expr; mirror = mirror_owned)
        end
        mirror_owned && _maybe_echo_result(result)
        # Tag the result with how many other evals ran concurrently / were queued,
        # so the server can surface a note when concurrency was actually in play.
        return result isa NamedTuple ? merge(result, (concurrent = peers, queued = queued)) : result
    catch e
        return (
            stdout = "",
            stderr = "",
            value_repr = "",
            exception = sprint(showerror, e, catch_backtrace()),
            backtrace = sprint(Base.show_backtrace, catch_backtrace()),
            concurrent = peers,
            queued = queued,
        )
    finally
        mirror_owned && _release_mirror!()
        Threads.atomic_sub!(_EVAL_INFLIGHT, 1)
        Base.release(_eval_semaphore())
    end
end

function _maybe_echo_result(result)
    _MIRROR_REPL[] || return

    has_exc = hasproperty(result, :exception) && result.exception !== nothing
    if has_exc
        _mirror_print() do
            printstyled("ERROR: ", color = :red, bold = true)
            println(string(result.exception))
        end
        return
    end

    # stdout/stderr are mirrored live while reading redirected streams.
    if hasproperty(result, :value_repr)
        val = string(result.value_repr)
        isempty(val) || _mirror_print(() -> println(val))
    end
end

function _set_option!(key::String, value)
    if key == "mirror_repl"
        if value === true && !_ALLOW_MIRROR[]
            return (type = :ok, key = key, value = false)
        end
        _MIRROR_REPL[] = value === true
        return (type = :ok, key = key, value = _MIRROR_REPL[])
    end
    return (type = :error, message = "unknown option: $key")
end

function _current_options()
    return (type = :options, mirror_repl = _MIRROR_REPL[], allow_mirror = _ALLOW_MIRROR[])
end

"""
    tty_path() -> Union{String, Nothing}

Return the TTY device path configured for this gate session (e.g.
`"/dev/ttys042"`), or `nothing` if no external TTY has been set.

Use this in app code to forward rendering to a separate terminal window:

```julia
Tachikoma.app(model; tty_out = KaimonGate.tty_path(), tty_size = KaimonGate.tty_size())
```
"""
tty_path() = _GATE_TTY_PATH[]

"""
    tty_size() -> Union{Nothing, NamedTuple{(:rows, :cols)}}

Return the detected size of the configured external TTY, or `nothing`.
"""
tty_size() = _GATE_TTY_SIZE[]

function _detect_tty_size(path::String)
    try
        out = readchomp(pipeline(`stty size`, stdin = open(path, "r")))
        parts = split(out)
        length(parts) == 2 || return nothing
        rows = parse(Int, parts[1])
        cols = parse(Int, parts[2])
        rows > 0 && cols > 0 ? (rows = rows, cols = cols) : nothing
    catch
        nothing
    end
end

# Signal numbers (platform-specific)
const _SIGSTOP = @static Sys.isapple() ? Cint(17) : Cint(19)
const _SIGCONT = @static Sys.isapple() ? Cint(19) : Cint(18)

"""
Park the foreground shell of `path` by sending SIGSTOP to its process group,
and disable echo so no input appears on the display. Idempotent.
"""
function _park_remote_shell!(path::String)
    # Resume any previously parked shell first
    _unpark_remote_shell!()
    try
        # Use `ps` to find the process group IDs on this TTY.
        # TIOCGPGRP ioctl fails (ENOTTY) when our process doesn't own the session.
        tty_name = basename(path)  # e.g. "ttys019" from "/dev/ttys019"
        out = read(`ps -t $tty_name -o pgid=`, String)
        pgrps = unique([
            p for line in split(out, '\n') for
            p in (tryparse(Int32, strip(line)),) if p !== nothing && p > 0
        ])
        isempty(pgrps) && return
        # Disable echo
        try
            run(pipeline(`stty -echo`, stdin = open(path, "r")), wait = true)
            _GATE_TTY_ECHO_DISABLED[] = true
        catch
        end
        # Pause all process groups on this TTY (SIGSTOP cannot be caught or ignored)
        for pgrp in pgrps
            ccall(:kill, Cint, (Cint, Cint), -pgrp, _SIGSTOP)
        end
        _GATE_TTY_PARKED_PGRP[] = pgrps[1]
    catch
    end
end

"""
Resume a shell previously parked by `_park_remote_shell!` and restore echo.
"""
function _unpark_remote_shell!()
    pgrp = _GATE_TTY_PARKED_PGRP[]
    pgrp === nothing && return
    _GATE_TTY_PARKED_PGRP[] = nothing
    # Restore echo before resuming so the shell sees the correct settings
    if _GATE_TTY_ECHO_DISABLED[]
        path = _GATE_TTY_PATH[]
        if path !== nothing
            try
                run(pipeline(`stty echo`, stdin = open(path, "r")), wait = true)
            catch
            end
        end
        _GATE_TTY_ECHO_DISABLED[] = false
    end
    # Resume the process group
    try
        ccall(:kill, Cint, (Cint, Cint), -pgrp, _SIGCONT)
    catch
    end
end

"""
    set_tty!(path::String)

Configure an external TTY for rendering.

Detects the terminal size, pauses the shell in the remote terminal (via
SIGSTOP so nothing can be typed or echoed), and stores the path so
[`tty_path`](@ref) and [`tty_size`](@ref) return it for use by app code.

Call [`restore_tty!`](@ref) (or use the `finally` block pattern) after the
TUI exits to resume the shell and restore echo.

The TUI polls the remote terminal's size once per second, so resizing the
window works during rendering.
"""
function set_tty!(path::String)
    Sys.iswindows() && return (
        type = :error,
        message = "set_tty! requires a Unix TTY device (macOS/Linux only)",
    )
    ispath(path) || return (type = :error, message = "TTY device not found: $path")
    sz = _detect_tty_size(path)
    _GATE_TTY_PATH[] = path
    _GATE_TTY_SIZE[] = sz
    _park_remote_shell!(path)
    return (
        type = :ok,
        tty_path = path,
        rows = sz !== nothing ? sz.rows : nothing,
        cols = sz !== nothing ? sz.cols : nothing,
    )
end

"""
    restore_tty!()

Resume the shell paused by [`set_tty!`](@ref) and restore echo.
Call this after the TUI app exits (typically in a `finally` block).
"""
function restore_tty!()
    _unpark_remote_shell!()
end


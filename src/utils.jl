module Utils

"""
    process_running(pid::Int) -> Bool

Check if a process with the given PID is currently running.

This function provides a cross-platform way to check process existence:
- On Windows: Uses `tasklist` command
- On Unix/Linux/macOS: Uses `kill -0` signal check

Useful for health monitoring of Julia sessions.

# Examples
```julia
using Kaimon.Utils

# Check if a process is running
if process_running(1234)
    println("Process 1234 is alive")
else
    println("Process 1234 is not running")
end
```
"""
function process_running(pid::Int)
    if Sys.iswindows()
        # On Windows, `tasklist` is a common way to check for a PID.
        # The `findstr` command filters for the PID.
        # If the command succeeds (exit code 0), the process exists.
        # We need to check if the output contains the PID, as `tasklist` can return 0 even if not found.
        return read(`tasklist /FI "PID eq $pid"`, String) |> strip |> !isempty
    else
        # On Unix-like systems (Linux, macOS), `kill -0` is the standard
        # way to check if a process exists without sending a signal.
        return success(`kill -0 $pid`)
    end
end

export process_running

"""
    terminate_process(pid::Int; force::Bool=false) -> Nothing

Best-effort terminate a process by raw PID, cross-platform: `taskkill` on Windows,
`kill` (SIGTERM, or SIGKILL when `force`) elsewhere. Never throws — a missing process
or missing tool is ignored. Use for reaping PIDs we tracked in a file (no live
`Base.Process` handle); for a spawned handle prefer `kill(::Base.Process, signum)`.
"""
function terminate_process(pid::Integer; force::Bool = false)
    try
        if Sys.iswindows()
            cmd = force ? `taskkill /F /PID $pid` : `taskkill /PID $pid`
            run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false)
        else
            run(pipeline(`kill $(force ? "-9" : "-15") $pid`; stderr = devnull); wait = false)
        end
    catch
    end
    return nothing
end

export terminate_process

"""
    _which_pathext(name; path, pathext, exists) -> String | nothing

Resolve a bare command `name` across `PATH` × `PATHEXT` (Windows), returning the first
existing `<dir>\\<name><ext>` in PATHEXT order, or `nothing`. This fills the gap where
`Sys.which` resolves a bare name only as `.exe` on Windows — so an npm-installed CLI that
ships `.cmd`/`.ps1` shims (Claude Code, gemini, …) is invisible to `Sys.which` and thus to
`Base.run`, which then ENOENTs. `path`/`pathext`/`exists` are injectable so the search is
unit-testable off-Windows. A `name` that already contains a path separator returns `nothing`
(it isn't a bare name to resolve).
"""
function _which_pathext(name::AbstractString;
                        path = get(ENV, "PATH", ""),
                        pathext = get(ENV, "PATHEXT", ".COM;.EXE;.BAT;.CMD"),
                        exists = isfile)
    (occursin('/', name) || occursin('\\', name)) && return nothing
    exts = [lowercase(e) for e in split(pathext, ';'; keepempty = false)]
    for dir in split(path, ';'; keepempty = false)
        isempty(strip(dir)) && continue
        for e in exts
            cand = joinpath(String(dir), name * e)
            exists(cand) && return cand
        end
    end
    return nothing
end

"""
    launch_argv(argv; iswin=Sys.iswindows(), which=Sys.which) -> Vector{String}

Return an argv that will actually execute on this platform. `argv[1]` is the executable
(a bare name or a path). On Windows a bare name is resolved first via `Sys.which` (which only
finds `.exe`), then via a `PATH` × `PATHEXT` search (`_which_pathext`) so npm `.cmd`/`.ps1`
shims are found too; a resulting `.cmd`/`.bat`/`.ps1` shim — which `CreateProcess` (what
`run`/libuv use) cannot execute directly — is launched through its interpreter (`cmd.exe /d
/c`, or `powershell -File`). A native `.exe`, or any non-Windows target, is returned unchanged
apart from name→path resolution. `iswin`/`which`/`which_ext` are injectable so the rewrite is
unit-testable off-Windows.

Known edge: `cmd.exe` re-parses the command line, so an argv VALUE containing cmd
metacharacters (`% ! & | < >`) can mis-quote — rare for CLI flag values.
"""
function launch_argv(argv::AbstractVector{<:AbstractString};
                     iswin::Bool = Sys.iswindows(), which = Sys.which,
                     which_ext = _which_pathext)
    a = String[String(x) for x in argv]
    (iswin && !isempty(a)) || return a
    exe = a[1]
    # `Sys.which` resolves a bare name only as `.exe` on Windows, so npm `.cmd`/`.ps1` shims
    # slip through — fall back to a PATH × PATHEXT search so they're found and can be wrapped.
    resolved = if isfile(exe)
        exe
    else
        w = which(exe)
        w === nothing ? something(which_ext(exe), exe) : w
    end
    rest = @view a[2:end]
    ext = lowercase(splitext(resolved)[2])
    if ext == ".cmd" || ext == ".bat"
        # /d skips AutoRun; per-arg quotes from run()'s C-escaping carry through cmd's re-parse
        # for the common cases (paths/flags with spaces).
        return String["cmd.exe", "/d", "/c", resolved, rest...]
    elseif ext == ".ps1"
        return String["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                      resolved, rest...]
    end
    return String[resolved, rest...]
end

"""
    launch_cmd(cmd::Base.Cmd) -> Base.Cmd

`launch_argv` for a `Cmd`: resolve/wrap its argv so a Windows shim CLI actually runs. Wrap a
backtick command at the call site, e.g. `run(launch_cmd(\`claude mcp list\`))`.
"""
launch_cmd(cmd::Base.Cmd) = Base.Cmd(launch_argv(cmd.exec))

export launch_argv, launch_cmd

end # module Utils

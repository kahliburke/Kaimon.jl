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
    Sys.iswindows() && return _windows_start_id(pid) !== nothing
    # On Unix-like systems (Linux, macOS), `kill -0` is the standard
    # way to check if a process exists without sending a signal.
    return success(`kill -0 $pid`)
end

export process_running

"""
    process_start_id(pid) -> Union{String,Nothing}

When the process `pid` started, as an opaque string; `nothing` when no such process is running or
this platform can't tell. A pid is reused once its process exits, so a pid recorded in a file names
the process it was recorded for only together with this id (see [`same_process`](@ref)).
"""
function process_start_id(pid::Integer)::Union{String,Nothing}
    pid > 0 || return nothing
    try
        Sys.islinux() && return _linux_start_id(pid)
        Sys.isapple() && return _macos_start_id(pid)
        Sys.iswindows() && return _windows_start_id(pid)
    catch
    end
    return nothing
end

"""
    same_process(pid, started) -> Bool

Whether `pid` is still the process whose [`process_start_id`](@ref) was `started`.
"""
same_process(pid::Integer, started::AbstractString)::Bool =
    !isempty(started) && process_start_id(pid) == started

export process_start_id, same_process

# The boot id and field 22 of /proc/<pid>/stat (start time in clock ticks since boot). Field 2, the
# command name, is in parentheses and may contain spaces, so fields are counted after its last ')'.
function _linux_start_id(pid::Integer)
    stat = read("/proc/$pid/stat", String)
    fields = split(stat[findlast(')', stat)+1:end])
    boot = strip(read("/proc/sys/kernel/random/boot_id", String))
    return "$boot:$(fields[20])"
end

# `proc_pidinfo(PROC_PIDTBSDINFO)` fills a `struct proc_bsdinfo` (136 bytes), whose start time
# (`pbi_start_tvsec`, `pbi_start_tvusec`) is its last 16 bytes.
function _macos_start_id(pid::Integer)
    buf = zeros(UInt8, 136)
    n = ccall(:proc_pidinfo, Cint, (Cint, Cint, UInt64, Ptr{UInt8}, Cint), pid, 3, 0, buf, length(buf))
    n == length(buf) || return nothing
    sec, usec = reinterpret(UInt64, buf[121:136])
    return "$sec.$usec"
end

# The process's creation time from `GetProcessTimes`. An exited process keeps its pid while any
# handle to it is open, so it must also still be running (`STILL_ACTIVE`).
function _windows_start_id(pid::Integer)
    h = ccall((:OpenProcess, "kernel32"), stdcall, Ptr{Cvoid}, (UInt32, Cint, UInt32),
              0x1000, 0, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
    h == C_NULL && return nothing
    try
        code = Ref{UInt32}(0)
        ccall((:GetExitCodeProcess, "kernel32"), stdcall, Cint, (Ptr{Cvoid}, Ref{UInt32}), h, code) != 0 &&
            code[] == 259 || return nothing
        created, exited, kernel, user = Ref{UInt64}(0), Ref{UInt64}(0), Ref{UInt64}(0), Ref{UInt64}(0)
        ccall((:GetProcessTimes, "kernel32"), stdcall, Cint,
              (Ptr{Cvoid}, Ref{UInt64}, Ref{UInt64}, Ref{UInt64}, Ref{UInt64}),
              h, created, exited, kernel, user) == 0 && return nothing
        return string(created[])
    finally
        ccall((:CloseHandle, "kernel32"), stdcall, Cint, (Ptr{Cvoid},), h)
    end
end

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

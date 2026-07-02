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

end # module Utils

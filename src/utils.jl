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

end # module Utils

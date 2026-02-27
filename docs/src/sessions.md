# Session Management

Kaimon connects AI agents to live Julia REPLs. Each connected REPL is a **session** -- an independent Julia process with its own state, loaded packages, and working directory. Agents execute code, inspect types, run tests, and more by routing requests to a specific session.

## What Is a Session?

A session represents a single Julia REPL that has connected to the Kaimon server. Each session has:

- A unique **8-character session key** (e.g., `a3f8b2c1`) used to identify and target it.
- Its own Julia process with independent module state, variables, and loaded packages.
- A health status indicating whether it is responsive.

Multiple sessions can be connected simultaneously, allowing agents to work across different projects or environments at the same time.

## Starting a Session

There are three ways to connect a REPL, ranging from manual to fully automatic.

### Manual

Call `Gate.serve()` in any running REPL:

```julia
using Kaimon
Gate.serve()
```

This is non-blocking — the gate runs in a background task and the REPL remains
interactive. Good for one-off connections or scripts.

### Per-project auto-connect

The Config tab's onboarding flow writes a `.julia-startup.jl` file into your
project directory. Load it with Julia's `--load=` flag and the REPL auto-connects whenever
it launches in that directory:

```bash
julia --load=.julia-startup.jl
```

The generated file loads Revise and calls `Gate.serve()`, both wrapped in
`try/catch` so startup succeeds even when Kaimon is not running:

```julia
# .julia-startup.jl
try
    using Revise
catch e
    @info "ℹ Revise not loaded (optional)"
end
try
    using Kaimon
    Gate.serve()
catch e
    @warn "Kaimon Gate failed to start" exception = e
end
```

### Global auto-connect

The Config tab's **"Julia startup.jl (global gate)"** option appends the same
snippet to `~/.julia/config/startup.jl`. After that, every Julia session on
your machine auto-connects to Kaimon without any project-level setup.

Each REPL that calls `Gate.serve()` registers as a separate session with its own session key.

## Session Routing

When only one session is connected, agents do not need to specify a target -- all requests are routed to the single active session automatically.

When **multiple sessions** are connected, agents must specify which session to target by providing the 8-character session key. Every tool that executes code or inspects state accepts a `session` (or `ses`) parameter for this purpose:

```
ex(e="using LinearAlgebra", ses="a3f8b2c1")
run_tests(session="a3f8b2c1")
type_info(type_expr="Matrix{Float64}", session="a3f8b2c1")
```

If an agent omits the session key when multiple sessions are connected, the server returns an error indicating that a session must be specified.

## Viewing Sessions in the TUI

The TUI (terminal user interface) includes a **Sessions tab** that displays all connected REPLs. For each session, it shows:

- The session key.
- Connection status and health (based on periodic heartbeat checks).
- The Julia version and active project environment.

This tab provides a real-time overview of which REPLs are available for agents to target.

## Restarting a Session

To restart a session, use the `manage_repl` tool with the `restart` command:

```
manage_repl(command="restart")
manage_repl(command="restart", session="a3f8b2c1")
```

Restart replaces the Julia process in-place using `execvp`, which swaps the running process image without spawning a child. This means:

- The process ID stays the same.
- All Julia state is cleared (a fresh session begins).
- The session key is preserved, so agents can continue targeting the same key.
- Revise and other packages are reloaded from scratch.

Use restart when Revise fails to pick up structural changes, or when the session state has become corrupted.

## Shutting Down a Session

To cleanly disconnect a session, use the `manage_repl` tool with the `shutdown` command:

```
manage_repl(command="shutdown")
manage_repl(command="shutdown", session="a3f8b2c1")
```

This stops the session permanently. The session key is deregistered, and the REPL disconnects from the server. The Julia process exits.

## Auto-Discovery

Kaimon uses a file-based discovery mechanism. When a REPL calls `Gate.serve()`, it writes a ZMQ socket file to:

```
~/.cache/kaimon/sock/
```

The Kaimon server watches this directory for new socket files. When a new file appears, the server automatically connects to the corresponding REPL and registers it as a session. When a socket file is removed (e.g., on shutdown), the session is deregistered.

This design means sessions can start and stop independently of the server -- the server discovers them as they appear.

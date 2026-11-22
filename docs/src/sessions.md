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

Add the lightweight `KaimonGate` package and call `serve()` in any running REPL:

```julia
]add KaimonGate
using KaimonGate
KaimonGate.serve()
```

This is non-blocking — the gate runs in a background task and the REPL remains
interactive. Good for one-off connections or scripts.

### Per-project auto-connect

`Kaimon.Generate.create_startup_script(path)` writes a `.julia-startup.jl` file into a
project directory, and `Kaimon.Generate.create_repl_script(path)` an executable `repl`
launcher that loads it. Start the REPL through `./repl`, or with Julia's `--load=` flag:

```bash
julia --project --load=.julia-startup.jl
```

The generated file loads Revise and calls `KaimonGate.serve()` when KaimonGate is available
in the environment, so startup succeeds even when Kaimon is not running:

```julia
if Base.identify_package("KaimonGate") !== nothing
    try
        @eval using Revise
    catch
    end
    try
        @eval using KaimonGate
        @eval KaimonGate.serve()
    catch e
        @warn "KaimonGate failed to start" exception = e
    end
end
```

### Global auto-connect

The Config tab's **"Julia startup.jl (global gate)"** option appends the same
snippet to `~/.julia/config/startup.jl`. After that, every Julia session on
your machine auto-connects to Kaimon without any project-level setup.

Each REPL that calls `KaimonGate.serve()` registers as a separate session with its own session key.

### Managed sessions

The `start_session` MCP tool spawns Julia processes for projects in the allowed-projects list. This lets AI agents autonomously start sessions for projects they need to work on.

```
start_session(project_path="/path/to/MyProject")
# => "Session started. Session key: a3f8b2c1"

start_session()
# => Lists all allowed projects and their status
```

When a managed session starts, Kaimon:

1. Spawns a Julia subprocess via PTY (pseudo-terminal).
2. Activates the project environment and runs `Pkg.instantiate` (see [Instantiating the environment](configuration.md#Instantiating-the-environment)).
3. Loads Revise and calls `KaimonGate.serve(spawned_by="agent")`.
4. Waits for the gate connection, 120 seconds by default (`session_startup_timeout` in `config.json`, or `KAIMON_SESSION_STARTUP_TIMEOUT`).

The spawned process connects back as a regular gate session. It appears in the Sessions tab like any other session, but is tagged with `spawned_by: agent` to distinguish it from manually started REPLs.

A session that has not connected within that limit is reported as timed out, but its process keeps running for the same time again. If its gate connects in that window, the session is used: calling `start_session` again for the project waits for it rather than spawning another process. A process that never connects is then stopped. An agent-spawned gate that connects but matches no waiting session is logged in `server.log` with the reason.

Evaluations run on a worker thread, and sessions start with `-t auto`. A package that must be called from the main thread, such as PythonCall or GLMakie, needs `ex(…, mt=true)` for every eval that calls into it.

To configure which projects can be spawned, see [Projects Configuration](configuration.md#projects-configuration).

### Private sessions

By default `start_session` returns the session already running for a project, so every agent working on it shares one REPL, and its globals. Evals run concurrently, and each result says when another eval overlapped it.

An agent that needs a REPL of its own passes `private=true`. It gets a session that `start_session` never hands to another agent and that automatic binding never picks for one; calling `start_session(private=true)` again returns the same session. Setting **Agent sessions** to *private* in the Config tab (`a`), or `KAIMON_AGENT_SESSIONS=private`, makes that the default for every agent.

Privacy is per MCP connection. Subagents that share their parent's connection (as Claude Code's do) are one client to Kaimon, so a parent that runs subagents in parallel should call `start_session(private=true)` once per subagent and give each its own key to pass as `ses`. The user's own REPL is never private.

## Session Routing

Every tool that executes code or inspects state accepts a `session` (or `ses`) parameter naming the session by its 8-character key:

```
ex(e="using LinearAlgebra", ses="a3f8b2c1")
run_tests(session="a3f8b2c1")
type_info(type_expr="Matrix{Float64}", session="a3f8b2c1")
```

When it is omitted, the call goes to the agent's **bound** session: the one it last named with `ses`, the one `start_session` returned to it, or the one matching its workspace root. `ping` marks it. An agent with no bound session falls through to the only connected session, never counting another agent's private one; with several connected, the server returns an error asking for a key.

!!! note "Extension runtimes are not addressable sessions"
    Extensions connect through the Gate like a session, but they are **not** REPLs
    an agent can target. They are excluded from the session list agents route to,
    cannot be reached with `ses=`, and cannot be eval'd in — their runtime is not a
    scratch REPL and its output is not visible. Targeting one explicitly returns a
    message pointing you at `start_session` for a real REPL. Extensions are managed
    on the [Extensions](extensions.md) tab instead. To work in an extension's own
    project (e.g. developing the extension), start a normal session for it with
    `start_session`.

## Viewing Sessions in the TUI

The TUI (terminal user interface) includes a **Sessions tab** that displays all connected REPLs. For each session, it shows:

- The session key.
- Connection status and health (based on periodic heartbeat checks).
- The Julia version and active project environment.

This tab provides a real-time overview of which REPLs are available for agents to target.

### Session terminal

For agent-spawned sessions, you can open an embedded terminal by selecting the session and pressing `Enter`. This opens a full-screen PTY console connected to the session's Julia REPL, allowing you to interact with it directly while the agent continues to work through MCP tools.

Press `Esc` to close the terminal overlay. The underlying Julia process and gate connection remain active — closing the terminal only dismisses the view.

### Key reference

| Key | Action |
|-----|--------|
| `↑` / `↓` | Navigate session list |
| `Enter` | Open terminal for agent-spawned session |
| `f` | Filter sessions |
| `Esc` | Close terminal or filter |

## Restarting a Session

There are three ways to restart a session:

**From the agent** — use the `manage_repl` tool:

```
manage_repl(command="restart")
manage_repl(command="restart", session="a3f8b2c1")
```

**From the REPL** — call `KaimonGate.restart()` directly:

```julia
KaimonGate.restart()
```

**From the TUI** — press `r` on the selected session in the Sessions tab.

All three methods use `execvp`, which swaps the running process image without spawning a child. This means:

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

Kaimon uses a file-based discovery mechanism. When a REPL calls `KaimonGate.serve()`, it writes a ZMQ socket file to:

```
~/.cache/kaimon/sock/
```

The Kaimon server watches this directory for new socket files. When a new file appears, the server automatically connects to the corresponding REPL and registers it as a session. When a socket file is removed (e.g., on shutdown), the session is deregistered.

This design means sessions can start and stop independently of the server -- the server discovers them as they appear.

## Session Preferences

Per-project session preferences can be configured in `~/.config/kaimon/projects.json` under the `session_prefs` key. Preferences are matched by project name (case-insensitive basename) or full path, with a `*` wildcard for global defaults:

```json
{
  "session_prefs": {
    "MyProject": {
      "mirror_repl": true,
      "allow_restart": false
    },
    "*": {
      "allow_restart": true
    }
  }
}
```

| Preference | Description |
|------------|-------------|
| `mirror_repl` | Mirror agent eval output into the host REPL. Useful for seeing what agents execute in real time. |
| `allow_restart` | Whether the `manage_repl(command="restart")` command is permitted for this session. |

See [Configuration](configuration.md) for the full `projects.json` format.

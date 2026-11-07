# Configuration

Kaimon.jl uses a layered configuration system with global preferences, per-project settings, and environment variable overrides.

## Preferences

Kaimon uses [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl) for persistent settings, stored in `LocalPreferences.toml` in your project directory.

| Preference | Type | Description |
|------------|------|-------------|
| `gate_mirror_repl` | `Bool` | Mirror eval output from MCP agents into the host REPL. Useful for seeing what agents are executing in real time. |
| `agent_sessions` | `String` | `"shared"` (default): `start_session` returns the session already running for a project. `"private"`: each MCP client gets its own. Toggle with `[a]` in the Config tab. See [Private sessions](sessions.md#Private-sessions). |
| `print_strip` | `String` | How much output-producing code is removed from agent evals: `"off"`, `"moderate"` (default) or `"high"`. Cycle it with `[o]` in the Config tab. See [Print Stripping](@ref print-strip). |

Layout preferences for TUI panels (sizes, positions, visibility) are also persisted through the Preferences system.

### [Print Stripping](@id print-strip)

Agents given a shared REPL tend to report through `println`, `@show` and `@info`, which fills the
terminal and the agent's context with narration. Kaimon removes those calls from the code an
agent submits, at the level set by `print_strip` (or the `KAIMON_PRINT_STRIP` environment
variable, which takes precedence):

| Level | What is removed |
|-------|-----------------|
| `off` | Nothing. The code runs exactly as submitted. |
| `moderate` | With `q=true` only: print calls, `@show` and logging macros that the cell runs as statements. Function, macro, lambda and `do` bodies and call arguments are left alone. |
| `high` | Print calls everywhere, including inside functions the agent defines, whatever `q` is. `@show` with `q=true`. |

At every level, only Base's `print`/`println`/`printstyled` are candidates (`Profile.print(io)` is
another function), and a call writing to an IO variable is kept. Logging macros are removed only
as the cell's own top-level statements, since inside a `try`/`catch` they usually report real
errors. A removed `@show x = 1` still runs `x = 1`. The rest of the cell reaches the REPL exactly
as written, and the agent's result carries a note when anything was removed.

## Directory Layout

Kaimon organizes files across three locations: a global config directory, a cache directory for runtime data, and a per-project `.kaimon/` directory.

### Global config — `~/.config/kaimon/`

Respects `XDG_CONFIG_HOME` on Linux/macOS; uses `APPDATA` on Windows.

| File | Purpose |
|------|---------|
| `config.json` | Global settings: security mode, API keys, editor, qdrant prefix, [extension restart waits](extensions.md#Tools-Stay-Listed-Across-a-Restart) |
| `projects.json` | Allowed projects for managed sessions ([details](@ref projects-config)) |
| `extensions.json` | Extension registry ([details](extensions.md)) |
| `tcp_gates.json` | Registered TCP gate connections (host, port, name, token, stream_port) |

### Cache — `~/.cache/kaimon/`

Respects `XDG_CACHE_HOME` on Linux/macOS; uses `LOCALAPPDATA` on Windows.

| File / pattern | Purpose |
|----------------|---------|
| `server.log` | Main server log (TUI and standalone modes) |
| `sessions/<name>.log` | Per managed-session log |
| `extensions/<namespace>.log` | Per extension subprocess log |
| `indexer.log` | Qdrant indexer log |
| `kaimon.db` | SQLite database (activity history, session metadata) |
| `sessions.json` | Active MCP session registry |
| `qdrant_projects.json` | Qdrant index tracking (which projects are indexed) |
| `*.sock` | Unix sockets for REPL-to-MCP communication |

`server.log` records Info and above. To also record debug messages, start Kaimon with `JULIA_DEBUG` naming the modules: `JULIA_DEBUG=Kaimon kaimon`, or `JULIA_DEBUG=Kaimon,KaimonGate` to include KaimonGate's own. They appear as `[DEBUG]` lines.

### Per-project — `.kaimon/`

Located in the project root directory.

| File | Purpose |
|------|---------|
| `tools.json` | Enable or disable individual MCP tools for this project |
| `sessions.json` | Tracks active MCP sessions connected to this project |

## [Security Configuration](@id security-config)

The security config controls access to the MCP server via `config.json` at `~/.config/kaimon/`:

```json
{
  "mode": "strict",
  "api_keys": ["km_abc123..."],
  "allowed_ips": ["127.0.0.1", "::1"]
}
```

### Fields

| Field | Description |
|-------|-------------|
| `mode` | Security mode: `"strict"` (require API key + IP check), `"relaxed"` (localhost only, no key required), or `"lax"` |
| `api_keys` | List of authorized API keys |
| `allowed_ips` | IP addresses permitted to connect |
| `editor` | Editor for file:line links: `"vscode"`, `"cursor"`, `"zed"`, `"windsurf"` |
| `qdrant_prefix` | Prefix for Qdrant collection names (for shared instances). Set via Config tab `[Q]` or `KAIMON_QDRANT_PREFIX` env var. |

Use the security management tools to modify these settings programmatically:

- `Kaimon.security_status()` -- View current security configuration
- `Kaimon.setup_security()` -- Run the interactive security setup
- `Kaimon.generate_key()` -- Create a new API key
- `Kaimon.revoke_key()` -- Remove an API key
- `Kaimon.allow_ip()` / `Kaimon.deny_ip()` -- Manage the IP allowlist
- `set_security_mode` -- Switch between security modes

## [Projects Configuration](@id projects-config)

The `projects.json` file at `~/.config/kaimon/projects.json` controls which Julia projects can be spawned as managed sessions via the `start_session` MCP tool. It also holds per-project session preferences.

```json
{
  "projects": [
    {
      "project_path": "/path/to/MyProject",
      "enabled": true
    },
    {
      "project_path": "/path/to/AnotherProject",
      "enabled": false
    }
  ],
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

### Projects

| Field | Description |
|-------|-------------|
| `project_path` | Absolute path to a Julia project directory (must contain `Project.toml`) |
| `enabled` | Whether agents can spawn sessions for this project |
| `launch_config` | Julia launch flags for this project's spawned sessions ([details](@ref launch-config)) |

Manage the projects list through the TUI Config tab or by editing the file directly. The `start_session` tool called with no arguments lists all allowed projects and their current status.

### [Launch Configuration](@id launch-config)

How Kaimon starts a managed session for a project — most importantly, which **system image** it boots. A project with a custom sysimage should declare it here, or a spawned session will pay full compilation cost (and diverge from how you start the project by hand).

`sysimage` and `julia_bin` also apply to `run_tests`, so a project that pins a Julia is tested on that Julia. This matters when Kaimon itself runs on a different Julia than you do: an environment records the Julia version it was resolved for, and a dependency whose `[compat]` admits a different version per Julia resolves differently under each — so testing on the wrong Julia can leave the test environment pinned to a version that Julia cannot precompile. `run_tests` reports the Julia and manifest it used in its summary, and keeps one manifest per Julia version (`Manifest-v1.12.toml`) so two Julias never overwrite each other's resolution.

| Field | Description |
|-------|-------------|
| `sysimage` | `-J` system image. A relative path resolves against the project root |
| `julia_bin` | Julia binary, or a wrapper script that forwards its arguments to one. Default: the Julia running Kaimon |
| `julia_version` | Julia version to run, e.g. `1.12.6` or the series `1.12`. Resolved against juliaup's installs. Default: the Julia running Kaimon |
| `threads` | `-t` value. Default `auto` |
| `gcthreads` | `--gcthreads` value |
| `heap_size_hint` | `--heap-size-hint` value, e.g. `8G` |
| `startup_file` | Run `~/.julia/config/startup.jl`. Default `false` |
| `instantiate` | `Pkg.instantiate` before the session connects: `"auto"`, `"always"` or `"never"` (`true`/`false` also work). Default `"auto"` |
| `extra_flags` | Any further Julia flags, passed through verbatim |

#### Instantiating the environment

A spawned session runs `Pkg.instantiate` before it connects, so an environment that isn't installed yet still boots. By default (`"auto"`) this runs with Pkg's automatic precompilation turned off: missing packages are installed, and packages compile when the session loads them. Precompiling the whole manifest at each spawn would recompile every stale package in it, including dev'd packages that the session never loads and ones that currently fail to build.

`"always"` precompiles the whole manifest as well. `"never"` skips `Pkg.instantiate`, for an environment you manage by hand. Its output, including any failure, goes to the session log; a failure does not stop the session from connecting.

#### Requesting a Julia version

`julia_version` is the portable way to say which Julia a project needs. `julia_bin` is a path that exists on one contributor's machine, so it cannot be checked in; a version can. Both a patch (`1.12.6`) and a series (`1.12`, which takes the newest installed patch) work.

Resolution order is the Julia running Kaimon, then juliaup's installed versions, read from juliaup's own `juliaup.json`. `julia_bin` outranks `julia_version` when both are set, as the escape hatch for a Julia that juliaup does not manage.

If the requested version isn't installed and juliaup is available, Kaimon asks whether to install it, stating what will be downloaded and that your default `julia` is left alone. Kaimon never downloads a Julia without being told to. `juliaup add` can take minutes, so an accepted install runs in the background and the tool asks you to retry rather than holding the call open past your client's timeout.

Declining, or having no juliaup, is not fatal: the session or test run proceeds on the Julia Kaimon is running, and logs which version it substituted. If dependency resolution, precompilation, or tests then misbehave, that mismatch is the first thing to suspect.

There are two places to set it. Per user, in `projects.json`:

```json
{
  "projects": [
    {
      "project_path": "/path/to/MyProject",
      "enabled": true,
      "launch_config": {
        "sysimage": "MyProject-image.so",
        "threads": "auto",
        "heap_size_hint": "8G"
      }
    }
  ]
}
```

Or per project, checked into the repo, in the project's own `kaimon.toml` — so everyone working on it gets the same launch recipe with no local setup:

```toml
[launch]
sysimage = "MyProject-image.so"   # relative → resolved against the project root
threads = "auto"
startup_file = true
```

A user's `projects.json` entry is overlaid field-wise on the project's `kaimon.toml [launch]`, so you can override a single field locally and inherit the rest. A configured sysimage that doesn't exist on disk is logged and skipped — the session still starts, on the default image.

With `startup_file = true`, your `startup.jl` runs *before* the session's own boot script. If it connects a gate of its own, the session registers under those settings first and is then reconfigured — harmless, but worth knowing if your `startup.jl` does anything session-visible.

Edit the per-user half through the TUI Config tab: select a project and press `e` for the Launch Config modal.

!!! note "Restarting your own REPL"
    This config applies to sessions **Kaimon spawns**. A REPL you started yourself keeps its own launch flags across `manage_repl(command="restart")` — the gate re-execs with the original argv, so a custom `-J` sysimage, thread count, and heap hint all survive.

### Session Preferences

Per-project preferences are matched by project name (case-insensitive directory basename), full path, or `*` wildcard:

| Preference | Type | Description |
|------------|------|-------------|
| `mirror_repl` | `Bool` | Mirror agent eval output into the host REPL |
| `allow_restart` | `Bool` | Whether `manage_repl(command="restart")` is permitted |

See [Sessions](sessions.md#session-preferences) for details on how preferences are resolved.

## Tools Configuration

The `.kaimon/tools.json` file controls which MCP tools are available in a project. This is
useful for restricting which operations MCP agents can perform in sensitive projects, and for
trimming the advertised surface so agents choose from a shorter, more relevant list.

A config either **adjusts** the default surface or **selects** its own.

To turn a few tools off and keep everything else — a file that only subtracts starts from the
default surface:

```json
{
  "disabled_tools": ["pkg_add", "pkg_rm"]
}
```

To advertise only a chosen set — naming tools makes the file an allowlist:

```json
{
  "enabled_tools": ["ex", "search_code", "grep_code", "run_tests"]
}
```

Named groups work too, and can be toggled together:

```json
{
  "tool_sets": {
    "search": { "enabled": true,  "tools": ["search_code", "grep_code"] },
    "admin":  { "enabled": false, "tools": ["qdrant_create_collection"] }
  },
  "individual_overrides": { "run_tests": true, "_comment": "keys starting with _ are ignored" }
}
```

### Keys

| Key | Meaning |
|-----|---------|
| `tool_sets` | Named groups; every group with `"enabled": true` is unioned in. Selects. |
| `enabled_tools` | Tool names to advertise. `"*"` means the whole default surface. Names select; `"*"` does not. |
| `disabled_tools` | Tool names to remove. |
| `individual_overrides` | `name: true/false`, applied last so it overrides everything above. Keys beginning with `_` are comments. |

Some advanced and infrastructure tools are off the default surface. Naming one in
`enabled_tools`, a `tool_set`, or `individual_overrides` is the way to bring it back.

If a config resolves to zero tools, Kaimon warns rather than silently advertising nothing —
that is nearly always a typo in a tool name.

## Environment Variables

| Variable | Platform | Description |
|----------|----------|-------------|
| `XDG_CONFIG_HOME` | Linux/macOS | Override the default config directory (`~/.config`). Kaimon stores config in `$XDG_CONFIG_HOME/kaimon/`. |
| `APPDATA` | Windows | Windows config directory. Kaimon stores config in `$APPDATA/Kaimon/`. |
| `XDG_CACHE_HOME` | Linux/macOS | Override the default cache directory (`~/.cache`). Kaimon stores data in `$XDG_CACHE_HOME/kaimon/`. |
| `LOCALAPPDATA` | Windows | Windows equivalent of the cache directory. Kaimon stores data in `$LOCALAPPDATA/Kaimon/`. |
| `KAIMON_CONFIG_DIR` | all | Use this directory for config instead of the default. For a Kaimon embedded in another service; see [Running Kaimon inside another service](@ref embedded). |
| `KAIMON_CACHE_DIR` | all | Use this directory for the cache (database, sockets, sessions, logs) instead of the default. Its gates must see the same value to find it. |
| `KAIMON_RESTRICTED` | all | `1`: a request that names no tools in `X-Kaimon-Allowed-Tools`, from a session no agent owns, may use none. |
| `KAIMON_CODE_INDEX` | all | `0`: no automatic code indexing, and no FTS catch-up or pruning over the shared Qdrant. |
| `KAIMON_AGENT_SESSIONS` | all | `shared` or `private`. Overrides the `agent_sessions` preference. |
| `KAIMON_PRINT_STRIP` | all | `off`, `moderate` or `high`. Overrides the `print_strip` preference. See [Print Stripping](@ref print-strip). |
| `KAIMON_TEST_PROMOTE_AFTER` | all | Seconds a test run may hold the foreground before `run_tests` backgrounds it (default `30`). `0` never backgrounds. |
| `KAIMON_TEST_CONCURRENCY` | all | Test runs allowed in flight per project (default `1`). Runs are serialised because overlapping suites share fixtures and global state. |
| `KAIMON_TOOL_HOLD_SECONDS` | all | How long an extension's tools stay listed while it restarts (default `45`). Overrides `extension_tool_hold_seconds`. See [Tools Stay Listed Across a Restart](extensions.md#Tools-Stay-Listed-Across-a-Restart). |
| `KAIMON_TOOL_PARK_SECONDS` | all | How long a tool call waits for a restarting extension before giving up (default `40`). Overrides `extension_tool_park_seconds`. |
| `KAIMON_GATE_MODE` | all | Gate transport: `"ipc"` (default) or `"tcp"`. |
| `KAIMON_GATE_HOST` | all | TCP bind address (default `127.0.0.1`). |
| `KAIMON_GATE_PORT` | all | TCP REP socket port (default `0` = ephemeral). Setting it implies TCP mode. |
| `KAIMON_GATE_STREAM_PORT` | all | TCP PUB socket port (default `0` = ephemeral). |
| `KAIMON_GATE_TOKEN` | all | Gate auth token for TCP mode. See [Gate Authentication](security.md#gate-tcp-authentication). |

These configure the gate (`KaimonGate`); they can also be set in a project's
`kaimon.toml` `[gate]` section (see [TCP Mode](gate.md#tcp-mode)).

!!! note
    Under a full `Kaimon` install the gate **auto-starts** from these variables /
    `kaimon.toml` when the package loads. A standalone `using KaimonGate` session
    does not auto-start — it reads them for settings but you must call
    `KaimonGate.serve()` explicitly.

## [Running Kaimon inside another service](@id embedded)

A service can run a headless Kaimon of its own and put it in front of its users, beside the Kaimon
the same person runs for their own work. These settings keep the two apart and let the service
decide which tools each of its callers may use:

- `KAIMON_CONFIG_DIR` and `KAIMON_CACHE_DIR` give the instance its own config, keys, sockets,
  sessions and log. Each Kaimon reaps only the extensions it started.
- The service sends `X-Kaimon-Allowed-Tools` on every request it forwards: the tools that request's
  caller may use, comma-separated, in the dotted (`notes.search`) or underscore spelling. Each tool
  call and tool list is judged by the header on its own request. The service must strip any copy a
  client sends.
- `KAIMON_RESTRICTED=1` makes a request with no list get no tools, unless an agent Kaimon owns is
  behind its session. An agent's own permissions never widen the list.
- `KAIMON_CODE_INDEX=0` stops the instance indexing code, which would otherwise walk every
  collection in a Qdrant it shares with the service.

## TUI Configuration

The TUI (Terminal User Interface) built on [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl) supports customization of:

- **Themes** -- Visual appearance of the TUI panels and widgets
- **Layouts** -- Panel arrangement, sizes, and visibility

These settings are saved automatically via Tachikoma's preference system and persist across sessions. Use the TUI's built-in controls to adjust themes and layouts interactively.

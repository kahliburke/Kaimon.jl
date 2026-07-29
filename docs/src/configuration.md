# Configuration

Kaimon.jl uses a layered configuration system with global preferences, per-project settings, and environment variable overrides.

## Preferences

Kaimon uses [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl) for persistent settings, stored in `LocalPreferences.toml` in your project directory.

| Preference | Type | Description |
|------------|------|-------------|
| `gate_mirror_repl` | `Bool` | Mirror eval output from MCP agents into the host REPL. Useful for seeing what agents are executing in real time. |

Layout preferences for TUI panels (sizes, positions, visibility) are also persisted through the Preferences system.

## Directory Layout

Kaimon organizes files across three locations: a global config directory, a cache directory for runtime data, and a per-project `.kaimon/` directory.

### Global config — `~/.config/kaimon/`

Respects `XDG_CONFIG_HOME` on Linux/macOS; uses `APPDATA` on Windows.

| File | Purpose |
|------|---------|
| `config.json` | Global settings: security mode, API keys, editor, qdrant prefix |
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

| Field | Description |
|-------|-------------|
| `sysimage` | `-J` system image. A relative path resolves against the project root |
| `julia_bin` | Julia binary, or a wrapper script that forwards its arguments to one. Default: the Julia running Kaimon |
| `threads` | `-t` value. Default `auto` |
| `gcthreads` | `--gcthreads` value |
| `heap_size_hint` | `--heap-size-hint` value, e.g. `8G` |
| `startup_file` | Run `~/.julia/config/startup.jl`. Default `false` |
| `extra_flags` | Any further Julia flags, passed through verbatim |

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

The `.kaimon/tools.json` file controls which MCP tools are available in a project:

```json
{
  "disabled_tools": ["pkg_add", "pkg_rm"],
  "enabled_tools": ["*"]
}
```

This is useful for restricting which operations MCP agents can perform in sensitive projects.

## Environment Variables

| Variable | Platform | Description |
|----------|----------|-------------|
| `XDG_CONFIG_HOME` | Linux/macOS | Override the default config directory (`~/.config`). Kaimon stores config in `$XDG_CONFIG_HOME/kaimon/`. |
| `APPDATA` | Windows | Windows config directory. Kaimon stores config in `$APPDATA/Kaimon/`. |
| `XDG_CACHE_HOME` | Linux/macOS | Override the default cache directory (`~/.cache`). Kaimon stores data in `$XDG_CACHE_HOME/kaimon/`. |
| `LOCALAPPDATA` | Windows | Windows equivalent of the cache directory. Kaimon stores data in `$LOCALAPPDATA/Kaimon/`. |
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

## TUI Configuration

The TUI (Terminal User Interface) built on [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl) supports customization of:

- **Themes** -- Visual appearance of the TUI panels and widgets
- **Layouts** -- Panel arrangement, sizes, and visibility

These settings are saved automatically via Tachikoma's preference system and persist across sessions. Use the TUI's built-in controls to adjust themes and layouts interactively.

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
| `config.json` | Global security and editor settings ([details](@ref security-config)) |
| `projects.json` | Allowed projects for managed sessions ([details](@ref projects-config)) |
| `extensions.json` | Extension registry ([details](extensions.md)) |

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
  "api_keys": [
    {
      "key": "km_abc123...",
      "name": "my-editor",
      "created": "2025-01-15T10:30:00Z"
    }
  ],
  "allowed_ips": ["127.0.0.1", "::1"]
}
```

### Fields

| Field | Description |
|-------|-------------|
| `mode` | Security mode: `"strict"` (require API key + IP check), `"permissive"` (localhost only, no key required), or `"off"` |
| `api_keys` | List of authorized API keys with metadata |
| `allowed_ips` | IP addresses permitted to connect |

Use the security management tools to modify these settings programmatically:

- `security_status` -- View current security configuration
- `setup_security` -- Run the interactive security setup
- `generate_key` -- Create a new API key
- `revoke_key` -- Remove an API key
- `allow_ip` / `deny_ip` -- Manage the IP allowlist
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

Manage the projects list through the TUI Config tab or by editing the file directly. The `start_session` tool called with no arguments lists all allowed projects and their current status.

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

## TUI Configuration

The TUI (Terminal User Interface) built on [Tachikoma.jl](https://github.com/...) supports customization of:

- **Themes** -- Visual appearance of the TUI panels and widgets
- **Layouts** -- Panel arrangement, sizes, and visibility

These settings are saved automatically via Tachikoma's preference system and persist across sessions. Use the TUI's built-in controls to adjust themes and layouts interactively.

# Configuration

Kaimon.jl uses a layered configuration system with global preferences, per-project settings, and environment variable overrides.

## Preferences

Kaimon uses [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl) for persistent settings, stored in `LocalPreferences.toml` in your project directory.

| Preference | Type | Description |
|------------|------|-------------|
| `gate_mirror_repl` | `Bool` | Mirror eval output from MCP agents into the host REPL. Useful for seeing what agents are executing in real time. |

Layout preferences for TUI panels (sizes, positions, visibility) are also persisted through the Preferences system.

## Config Directories

Kaimon organizes configuration across three locations:

### `~/.cache/kaimon/`

Cache directory for runtime data:

- Socket files for REPL-to-MCP communication
- Log files
- Temporary data

The cache directory respects the `XDG_CACHE_HOME` environment variable. On Windows, it falls back to `LOCALAPPDATA`.

### `~/.config/kaimon/`

Global configuration that applies across all projects:

- **`security.json`** -- Global security settings (see [Security Configuration](@ref security-config) below)

### `.kaimon/` (per-project)

Project-level configuration, located in the project root:

- **`security.json`** -- Project-specific security overrides
- **`tools.json`** -- Enable or disable individual MCP tools for this project
- **`sessions.json`** -- Tracks active MCP sessions connected to this project

## [Security Configuration](@id security-config)

The `security.json` file controls access to the MCP server. It can exist at both the global (`~/.config/kaimon/`) and per-project (`.kaimon/`) levels:

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
| `XDG_CACHE_HOME` | Linux/macOS | Override the default cache directory (`~/.cache`). Kaimon stores data in `$XDG_CACHE_HOME/kaimon/`. |
| `LOCALAPPDATA` | Windows | Windows equivalent of the cache directory. Kaimon stores data in `$LOCALAPPDATA/kaimon/`. |

## TUI Configuration

The TUI (Terminal User Interface) built on [Tachikoma.jl](https://github.com/...) supports customization of:

- **Themes** -- Visual appearance of the TUI panels and widgets
- **Layouts** -- Panel arrangement, sizes, and visibility

These settings are saved automatically via Tachikoma's preference system and persist across sessions. Use the TUI's built-in controls to adjust themes and layouts interactively.

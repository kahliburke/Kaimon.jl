# Security Model

Kaimon executes arbitrary Julia code on your machine, so controlling access is important. The security system provides three modes, API key authentication, and IP allowlisting to match different trust environments.

## Security Modes

Kaimon's MCP endpoint runs in one of three modes. The mode decides what a request must carry and where it may come from:

| Mode | API key | Client IP |
|---|---|---|
| `strict` | Required | Must be in the IP allowlist |
| `relaxed` | Required | Any |
| `lax` | Not checked | Localhost only |

### Strict

Every request needs a valid API key and must come from an allowlisted IP. The default allowlist is `127.0.0.1` and `::1`, so a local-only setup works without changes. Use it on shared machines, or whenever you want explicit access control.

### Relaxed

Every request needs a valid API key, from any IP. Use it when clients on other machines connect directly.

### Lax

No credential is checked, and only requests from localhost are accepted. Any process on the machine can call every tool, including `ex`, which runs arbitrary Julia code as you. Use it on a single-user machine where you trust everything that runs.

Change the mode with `Kaimon.set_security_mode(:strict)` (or `:relaxed`, `:lax`), then restart Kaimon.

## API Key Management

Kaimon provides functions to manage API keys:

| Function | Description |
|---|---|
| `Kaimon.generate_key()` | Generate a new API key and add it to the configuration. It is printed once. |
| `Kaimon.revoke_key(key)` | Revoke an existing API key so it can no longer be used. |
| `Kaimon.set_security_mode(mode)` | Set the mode: `:strict`, `:relaxed` or `:lax`. |
| `Kaimon.security_status()` | Display the current security mode, active keys, and IP allowlist. |

### Using API Keys with MCP Clients

MCP clients send the key in the `Authorization` header:

```json
{
  "headers": {
    "Authorization": "Bearer your-api-key-here"
  }
}
```

The client installers in the TUI's Config tab write this header for you when a key is configured. After generating a key or changing the mode, re-run the installer for each client you use.

## Agents Kaimon Starts

An agent Kaimon spawns (with `agent_open`, or from a Slate notebook) never receives the API key. It gets its own token instead, minted when it starts and revoked when it ends. The token is the agent's credential in every mode, and the only way Kaimon identifies the agent: its permission preset, allowlist and the guard against agents spawning agents apply to the calls that carry it. A token left behind in a config file stops working once its agent is gone.

The token makes an agent's calls attributable; it does not contain the agent. An agent with unrestricted native file or shell access runs as you, so it can read your own MCP client configs, API key included, and call Kaimon without its token. In `lax` mode it needs no credential at all. To hold an agent to its preset, deny it native file and shell tools (the `notebook` preset does this for Claude and opencode agents) or run it in an OS-level sandbox.

## Seeing the Security State

The TUI's Server tab shows the active mode and how many requests the server has refused, with the reason for the most recent one: a missing or invalid API key, an IP outside the allowlist, a revoked agent token, or a session that belongs to another agent. In the Agents tab, each agent shows a short fingerprint of its token (never the token itself), the MCP session bound to it, and when it last made a call.

## IP Allowlists

The allowlist applies in `strict` mode:

| Function | Description |
|---|---|
| `allow_ip(ip)` | Add an IP address to the allowlist. |
| `deny_ip(ip)` | Remove an IP address from the allowlist. |

Only allowlisted IPs are accepted, so an empty allowlist refuses every request. `relaxed` mode does not check the client IP, and `lax` mode accepts localhost only.

## Gate (TCP) Authentication

The sections above govern the **MCP HTTP server**. A separate concern is the
**gate** (`KaimonGate`) when it binds a TCP socket for remote access — see
[TCP Mode](gate.md#tcp-mode). The gate enforces its own token, independent of
the MCP server's API keys:

- **Standalone `KaimonGate`** (the lightweight `]add KaimonGate` install, e.g. on
  a remote/compute node): the gate token comes **only** from the
  `KAIMON_GATE_TOKEN` environment variable. If it is unset, the TCP gate is
  **open** — any client that can reach the port can evaluate code in the session.
  Always set `KAIMON_GATE_TOKEN` before exposing a gate on a shared or
  network-reachable host (and prefer binding to `127.0.0.1` + an SSH tunnel over
  `0.0.0.0`).
- **Full `Kaimon`** install: the token is taken from `KAIMON_GATE_TOKEN` if set,
  otherwise derived from your security config's API keys when the config mode is
  not `:lax`. So a strict/relaxed config automatically protects TCP gates started
  by that process.

!!! warning
    IPC (Unix-socket) gates are protected by filesystem permissions on
    `~/.cache/kaimon/sock/` and do not use a token. The token only applies to
    TCP mode. A `0.0.0.0` bind with no token exposes a remote code-execution
    endpoint to the network.

## Encrypted Transport (CURVE)

A bearer token proves *who may call* a TCP gate, but it travels in the clear and
the traffic is unencrypted. For a gate exposed beyond `localhost`, enable
**CURVE** — ZMQ's Curve25519 transport — for confidentiality, integrity, and
**mutual** authentication on the wire. CURVE replaces the SSH tunnel as the
security layer (server pinning + a client allow-list), and its **soy-free mode**
SSH-bootstraps the server pin to close the TOFU first-use gap entirely.

See **[Encrypted Transport (CURVE)](curve.md)** for the full trust model, key
management (`[k]` in the TUI), soy-free verification, and stall diagnostics.

## Configuration

Security settings are stored in a global JSON configuration file:

```
~/.config/kaimon/config.json
```

Legacy `security.json` files are automatically migrated to `config.json` on first access.

### Configuration Format

A typical `config.json` file:

```json
{
  "mode": "strict",
  "api_keys": [
    "key-abc123..."
  ],
  "allowed_ips": [
    "127.0.0.1",
    "::1"
  ]
}
```

## Setup Wizard

For interactive configuration, use the setup wizard:

```julia
using Kaimon
Kaimon.setup_wizard_tui()
```

The wizard walks you through:

1. Choosing a security mode (Strict, Relaxed, or Lax).
2. Generating an initial API key.
3. Configuring IP allowlists.
4. Writing the configuration file to the appropriate location.

This is the recommended way to configure security for the first time.

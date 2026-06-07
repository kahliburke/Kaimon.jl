# Security Model

Kaimon executes arbitrary Julia code on your machine, so controlling access is important. The security system provides three modes, API key authentication, and IP allowlisting to match different trust environments.

## Security Modes

Kaimon operates in one of three security modes:

### Strict

API key is **required** for all requests. Any request without a valid key is rejected.

Best for:
- Production or shared servers.
- Environments where multiple users or agents may connect.
- Any situation where you want explicit access control.

### Relaxed

API key is **optional** but honored. Requests without a key are allowed, but if a key is provided, it must be valid.

Best for:
- Local development with some protection.
- Environments where you want the option to authenticate without enforcing it globally.

### Lax

**No authentication**. All requests are accepted regardless of whether a key is provided.

Best for:
- Fully trusted local environments.
- Quick experimentation where security overhead is unnecessary.

## API Key Management

Kaimon provides functions to manage API keys:

| Function | Description |
|---|---|
| `Kaimon.generate_key()` | Generate a new API key and register it with the server. |
| `Kaimon.revoke_key()` | Revoke an existing API key so it can no longer be used. |
| `Kaimon.security_status()` | Display the current security mode, active keys, and IP allowlist. |

### Using API Keys with MCP Clients

MCP clients authenticate by including the API key in the `X-API-Key` HTTP header. In your MCP client configuration, set the header:

```json
{
  "headers": {
    "X-API-Key": "your-api-key-here"
  }
}
```

The server validates this header on each request (in Strict and Relaxed modes).

## IP Allowlists

You can restrict which IP addresses are permitted to connect:

| Function | Description |
|---|---|
| `allow_ip(ip)` | Add an IP address to the allowlist. Only allowlisted IPs can connect. |
| `deny_ip(ip)` | Remove an IP address from the allowlist. |

When the allowlist is empty, all IPs are permitted (subject to API key requirements based on the security mode). Once at least one IP is added to the allowlist, only those IPs are accepted.

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

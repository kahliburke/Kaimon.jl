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
| `generate_key()` | Generate a new API key and register it with the server. |
| `revoke_key()` | Revoke an existing API key so it can no longer be used. |
| `security_status()` | Display the current security mode, active keys, and IP allowlist. |

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

## Configuration

Security settings are stored in JSON configuration files. Kaimon checks two locations:

### Per-Project Configuration

```
.kaimon/security.json
```

Place this file in your project root to configure security settings specific to that project. Per-project settings override global settings when working within that project.

### Global Configuration

```
~/.config/kaimon/security.json
```

Global settings apply to all projects unless overridden by a per-project configuration.

### Configuration Format

A typical `security.json` file:

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

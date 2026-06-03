# API Reference

## Public API

```@docs
Kaimon.start!
Kaimon.tui
Kaimon.call_tool
Kaimon.list_tools
Kaimon.tool_help
Kaimon.security_status
Kaimon.setup_security
Kaimon.generate_key
Kaimon.revoke_key
Kaimon.allow_ip
Kaimon.deny_ip
Kaimon.set_security_mode
```

## KaimonGate

The gate is the standalone `KaimonGate` package. (The full `Kaimon` install also
keeps a deprecated `Kaimon.Gate` alias for the old `Kaimon.Gate.*` API; new code
should use `KaimonGate`.)

### Lifecycle

```@docs
Kaimon.KaimonGate.serve
Kaimon.KaimonGate.stop
Kaimon.KaimonGate.restart
Kaimon.KaimonGate.status
Kaimon.KaimonGate.connect!
```

### Tools

```@docs
Kaimon.KaimonGate.GateTool
Kaimon.KaimonGate.call_tool
Kaimon.KaimonGate.list_tools
```

### Background jobs & progress

```@docs
Kaimon.KaimonGate.is_cancelled
Kaimon.KaimonGate.stash
Kaimon.KaimonGate.progress
Kaimon.KaimonGate.push_panel
```

### Terminal

```@docs
Kaimon.KaimonGate.tty_path
Kaimon.KaimonGate.tty_size
Kaimon.KaimonGate.uninstall_infiltrator_hook!
```

### Host-integration hooks

When the full `Kaimon` package loads, it installs these providers so the
standalone gate can report Kaimon's version, apply personality, and so on. They
are only needed when embedding `KaimonGate` in another host.

```@docs
Kaimon.KaimonGate.PROTOCOL_VERSION
Kaimon.KaimonGate.set_version_provider!
Kaimon.KaimonGate.set_personality_provider!
Kaimon.KaimonGate.set_mirror_pref_provider!
Kaimon.KaimonGate.set_tachikoma!
Kaimon.KaimonGate.set_auth_token_provider!
Kaimon.KaimonGate.set_restart_code_builder!
```

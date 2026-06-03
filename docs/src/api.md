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
KaimonGate.serve
KaimonGate.stop
KaimonGate.restart
KaimonGate.status
KaimonGate.connect!
```

### Tools

```@docs
KaimonGate.GateTool
KaimonGate.call_tool
KaimonGate.list_tools
```

### Background jobs & progress

```@docs
KaimonGate.is_cancelled
KaimonGate.stash
KaimonGate.progress
KaimonGate.push_panel
```

### Terminal

```@docs
KaimonGate.tty_path
KaimonGate.tty_size
KaimonGate.uninstall_infiltrator_hook!
```

### Host-integration hooks

When the full `Kaimon` package loads, it installs these providers so the
standalone gate can report Kaimon's version, apply personality, and so on. They
are only needed when embedding `KaimonGate` in another host.

```@docs
KaimonGate.PROTOCOL_VERSION
KaimonGate.set_version_provider!
KaimonGate.set_personality_provider!
KaimonGate.set_mirror_pref_provider!
KaimonGate.set_tachikoma!
KaimonGate.set_auth_token_provider!
KaimonGate.set_restart_code_builder!
```

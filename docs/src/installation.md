# Installation

## Requirements

- **Julia 1.12** or later

## Install Kaimon

### Julia App (Recommended)

Use Julia's package app system to install the `kaimon` command globally:

```julia
]app add Kaimon
```

This installs a `kaimon` script to `~/.julia/bin/`. Make sure `~/.julia/bin` is on your `PATH`, then launch from anywhere:

```bash
kaimon
```

To update to a newer release later:

```julia
]app add Kaimon
```

To pin a specific version:

```julia
]app add Kaimon@1.2.2
```

!!! warning "`app` commands fail with `Permission denied`"
    Kaimon 2.8.1 and earlier pulled in a Tachikoma version whose build step registered a
    `Tachi` app pointing into the read-only package tree. That entry makes every later
    `app` operation fail, including updating Kaimon itself. Upgrading does not remove it,
    so drop it once by hand:

    ```julia
    ]app rm Tachi
    ```

### Connect a Julia session (KaimonGate)

To make one of your project's Julia sessions reachable by the `kaimon` dashboard,
you only need the lightweight **[KaimonGate](https://github.com/kahliburke/Kaimon.jl)**
package. It depends on just ZMQ and the standard library — fast to install and
free of dependency conflicts (handy on remote/compute nodes):

```julia
pkg> add KaimonGate
```

Then, in the session you want to expose:

```julia
using KaimonGate
KaimonGate.serve()
```

The session appears in the running `kaimon` TUI. This is the recommended way to
connect your own projects, whether local or remote.

### As a Library (full Kaimon)

You can also add the full `Kaimon` package as a dependency; it bundles
`KaimonGate`, so `KaimonGate.serve()` works exactly as above. (The full package
also keeps a **deprecated** `Kaimon.Gate` alias for the historical
`Kaimon.Gate.*` API — new code should use `KaimonGate`.)

```julia
using Pkg
Pkg.add("Kaimon")
```

Or to track the development branch:

```julia
Pkg.develop(url="https://github.com/kahliburke/Kaimon.jl")
```

## Connect Codex CLI or the VS Code extension

In Kaimon's **Config** tab, press `i` and choose **OpenAI Codex**. The installer
writes a native Streamable HTTP connection to `~/.codex/config.toml` (or
`$CODEX_HOME/config.toml` when set), including Kaimon's API key when required.
Codex CLI and its VS Code extension share this configuration; restart Codex or
the extension after configuring it. The installer does not require `npx`,
`mcp-remote`, or the Codex CLI to be on Kaimon's `PATH`.

An existing `kaimon` entry is reused regardless of capitalization, and an old
`mcp-remote` entry is migrated to HTTP. Other servers, global settings, and the
Codex login are preserved. The file is reserialized as TOML, so comments and
formatting may change. The installer retains Kaimon's tool policies, timeouts,
and custom headers, and updates its endpoint and authentication to match the
running Kaimon server. Removal deletes only that server entry and leaves login
and shared environment files intact.

This connects Codex to Kaimon's tools. To have Kaimon launch Codex itself through
ACP, also install `codex-acp` as described in [ACP agents](@ref).

## Optional Dependencies

### Qdrant (Semantic Search)

Kaimon can index your codebase into [Qdrant](https://qdrant.tech/) for natural language code search. If you want to use the semantic search tools (`qdrant_index_project`, `search_code`, etc.), you need a local Qdrant on port `6333`.

The easiest way is **managed Qdrant** — no Docker needed. On the Search tab, press `l` (`enable managed Qdrant`) and Kaimon downloads the Qdrant binary into a private service environment and runs it for you. It's opt-in, so nothing is downloaded unless you ask. See [Setting Up Qdrant](search.md#setting-up-qdrant) for the full workflow (enable / stop / remove).

Prefer to run it yourself? Any Qdrant on `6333` works, e.g. via Docker:

```bash
docker run -d --name qdrant -p 6333:6333 -p 6334:6334 \
  -v qdrant_storage:/qdrant/storage \
  qdrant/qdrant
```

Qdrant is not required for core functionality. The semantic search tools will simply be unavailable if no Qdrant instance is detected.

### VS Code Remote Control

To use VS Code integration tools (`execute_vscode_command`, `navigate_to_file`, etc.), Kaimon includes a built-in VS Code extension. Install it from the TUI Config tab (press `v`), or from the Julia REPL:

```julia
using Kaimon
Kaimon.install_vscode_remote_control()
```

Reload VS Code after installation to activate. This enables AI agents to execute VS Code commands and navigate to specific file locations from the MCP interface.

## Verify Installation

Run `kaimon` from any terminal:

```bash
kaimon
```

On first launch, a setup wizard will guide you through security configuration and MCP client setup. You should see the TUI dashboard appear with session, activity, and configuration panels.

## Next Steps

- [Getting Started](getting-started.md) -- Configure your MCP client and connect to the server
- [Tool Catalog](tools.md) -- Browse the available tools
- [Security](security.md) -- Set up API keys and choose a security mode

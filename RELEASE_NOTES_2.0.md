# Kaimon 2.0.0

Kaimon gives an AI agent a live Julia REPL over MCP: run code, introspect types
and methods, drive the debugger, run tests, and search code against the running
session. 2.0 reworks search and the session model, changes how agents connect,
and splits the gate into its own lightweight package.

## A standalone gate: KaimonGate

The session and eval machinery now lives in KaimonGate, a separate package with a
small, tightly constrained dependency set. It is easy to add to your own project
or session without pulling in all of Kaimon, and spawned agent sessions boot it
instead of full Kaimon, so a session never recompiles Kaimon against your project.

## Search

- `grep_code` is a native MCP grep: an exact pattern or regex over the live
  working tree that returns the enclosing function or struct for each hit. It is a
  safer, clearer alternative to the piped grep/awk/sed bash commands models
  otherwise reach for, and much easier to read when you are watching what the
  agent runs. It is confined to the project scope by default.
- `search_code` finds code by meaning, now fusing vector similarity with a local
  SQLite FTS5 index, so results hold up whether you describe the behavior or
  remember an exact identifier.
- Both are repo scoped, respect `.gitignore`, and take opt-in metadata filters.
  `grep_code` can include logs and generated files on request.

## Sessions

Agents bind to the right gate from their workspace root, `start_session` reuses a
running gate instead of spawning a duplicate, and a new project is approved from a
prompt inside your client instead of by editing JSON (`allow_any_project` covers
container and VM setups).

## Long work that does not block

Any eval past about thirty seconds becomes a background job with progress and
cancellation, and it survives a restart.

## Agent backends

The supported agent is Claude today, built to speak ACP so other agents can plug
in soon. New and still experimental: local model backends (MLX and an in-process
Ollama loop) for keeping inference on your own machine.

## CURVE encryption, and a path to TachiRei

The gate transport can run CURVE encrypted over ZMQ, with key management and a
trust store in the TUI, which opens up secure connectivity across a network. It
also lays the groundwork for TachiRei.jl, a platform for persistent remote Julia
sessions and applications that people and multiple agents can connect to at once
(coming soon).

## KaimonSlate

A browser-based notebook (a "slate") built on Kaimon's extension system, where you
and an agent build and run cells in the same document, with doc search and PDF
export. It ships separately as
[KaimonSlate.jl](https://github.com/kahliburke/KaimonSlate.jl).

## Windows and headless

Windows support: the gate uses TCP in place of IPC. Headless parity: the same
analytics, indexing, housekeeping, and clean shutdown as the TUI.

## Stability and performance

The ZMQ transport was rewritten (persistent DEALER/ROUTER, event driven messaging,
adaptive timeouts), lowering reply latency and idle CPU, and a broad pass closed a
long list of stability issues from the 1.x line.

---

Thanks to @jonalm and @Eben60 for reports that shaped a lot of this.

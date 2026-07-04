# Changelog

All notable changes to Kaimon are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project aims to follow
semantic versioning.

## [2.0.0] — unreleased

The 2.0 release is a broad overhaul of how agents find code, talk to Julia
sessions, and run long work — on top of a rewritten ZMQ transport that makes the
whole system markedly more stable and quieter at idle.

### Highlights

- **Two-tool code search.** `search_code` finds code by *meaning* (hybrid
  semantic + local SQLite FTS5 lexical), `grep_code` finds an *exact* pattern over
  the live working tree and returns each hit's enclosing symbol. Both are
  repo-scoped and `.gitignore`-aware.
- **Smarter agent ↔ session model.** Each agent is bound to the right gate
  automatically by its workspace root, `start_session` converges on an existing
  gate instead of spawning duplicates, and projects can be approved in-client via
  an MCP elicitation prompt instead of hand-editing config.
- **Rewritten ZMQ transport.** Persistent DEALER/ROUTER request path, event-driven
  messaging, and an optional CURVE-encrypted link — lower latency, much lower idle
  CPU, and the end of a class of intermittent GC/segfault races.
- **Cooperative background evaluation.** Long evals auto-promote to background
  jobs with progress, stash, and cooperative cancellation, and survive a restart.
- **Headless parity and Windows support.**

### Added

- **`search_code`** — hybrid semantic + lexical code search (Qdrant embeddings +
  SQLite FTS5), backend-agnostic, with query-shape lexical weighting and
  span-overlap dedup.
- **`grep_code`** — exact pattern/regex search over the live tree (ripgrep-backed)
  that returns each match's enclosing function/struct, with optional
  natural-language ranking and `no_ignore` to include logs/generated/gitignored
  text.
- **Opt-in metadata filters** across both FTS and Qdrant.
- **In-client project approval** — when a project isn't allow-listed,
  `start_session` asks for consent via MCP **elicitation** ("allow once" / "always
  allow"), with graceful fallback when the client can't elicit. `allow_any_project`
  opt-out for container/VM environments (#46).
- **Automatic agent→gate routing** by MCP workspace `roots`, so an agent targets
  the correct project without manual session selection.
- **MCP server `instructions`** delivered on connect (cross-agent guidance), and
  **client capability logging** at initialize (protocol version + advertised
  capabilities/extensions).
- **Cooperative long-running evaluation** — auto-promotion past ~30 s, `check_eval`
  / `cancel_eval`, and `KaimonGate.progress` / `stash` / `is_cancelled`, with jobs
  persisted across a restart.
- **CURVE-encrypted gate transport** with TUI key-management and trust-store.
- **Local-model agent backends** — `vmlx:` (MLX) and an in-process Ollama ReAct
  loop; `claude --effort` passthrough.
- **`manage_extension`** tool and extension-callable Qdrant/Ollama building blocks.
- **Windows support** via an IPC→TCP transport switch (#41).
- **Headless parity** — analytics DB, housekeeping loop, periodic indexing, clean
  Ctrl-Q/Ctrl-C shutdown.
- **TUI** — Agents/Clients tab overhaul (status icons, event & transcript views,
  inline user prompts), CURVE link indicators, and a key-management modal. The
  Agents-tab event popup shows an event's **full tool input/output** (call args +
  result content), word-wrapped and scrollable, rather than a one-line summary.
- **`run_tests` coverage** — `coverage=true` now collects `--code-coverage=user`
  data into a per-file summary (the flag was previously accepted but ignored).
- **`usage_quiz`** behavioral primer and two-tool search documentation.

### Changed

- `start_session` **converges on an already-connected gate** for a project
  (manual or spawned) instead of creating a duplicate, and spawned sessions now
  `cd` into the project directory so project-relative paths resolve correctly.
- **Tool surface tightened** from ~68 to ~49 default tools.
- `qdrant_search_code` renamed to **`search_code`** (now backend-agnostic, hybrid
  by default).
- **`Revise.revise()` is stripped from agent code** like `println` — the gate
  replays Revise's transform before every eval, so an explicit call is a no-op.
- **`usage_instructions` composes** the always-on server instructions plus the
  extended guide, so the essential guidance has a single source.
- Agent sessions spawn the lightweight **KaimonGate** rather than full Kaimon (#47).
- **`run_tests` pattern filtering is now honest** — a `pattern` only reaches tests
  via `ARGS`, so when a suite can't honor it (plain Test.jl / SafeTestsets /
  TestItemRunner, vs. ReTest's `retest(ARGS...)`) the result carries an explicit
  warning instead of silently running the whole suite.

### Performance

- Rewritten ZMQ fabric: persistent DEALER/ROUTER (retiring per-request REQ),
  event-driven client/gate messaging, and adaptive recv timeouts — lower reply
  latency and substantially lower idle CPU.
- Fixed a multi-minute FTS search hang; collection-scoped the trigram match and
  forced an FTS-driven query plan.
- Moved analytics / jobs / FTS SQLite access off the interactive pool, behind a
  single-lock encapsulation.
- Indexing runs as a background job with progress; FTS-first two-pass indexing,
  deterministic point IDs, per-project reindex cooldown, and orphan pruning across
  both Qdrant and FTS.

### Fixed

- **`_CaptureIO` is now total** — a failed background task's notice can no longer
  throw through the gate's stdout/stderr and produce "…giving up" (regression from
  the concurrent-eval work).
- **Package loads are byte-safe under the capture** — `using`/`import` (and the Pkg
  precompilation it triggers) no longer aborts with `_CaptureIO does not support byte
  I/O` / "…giving up". Precompilation writes its progress bar and the runtime's
  failed-task notice as raw bytes at a pinned loading-time world age below the
  capture's byte methods, so the load now runs on the real fd-backed streams.
- **Session → project survives a server restart** — an agent that reconnects with its
  established MCP session id reassociates to its project (persisted the moment it binds
  to a gate), so `search_code`/`grep_code` no longer silently scope to the server's own
  directory. An unbound agent gets a clear error instead of a wrong-repo search.
- **Named sessions show their name** — `start_session(name=…)` is now reflected in the
  Sessions table rather than the name derived from the project directory.
- A class of **intermittent `gc_sweep_pool` segfaults** from ZMQ races — socket
  creation, SUB recv/close, event-PUB sends, and unbounded weakref growth (#51).
- **Dropped eval output** — bounded-wait drain so an unterminated final line isn't
  lost from the returned result.
- **Infiltrator** — post-stop hang, Ctrl-C release, and a self-debug routing toggle
  (#34).
- **Headless** — eval results are returned and TCP no longer double-connects (#50).
- **ReTest result parsing** — failing suites reported `Fail: 0` and pattern-filtered
  suites `Pass: 0` (ReTest's varying-header, blank-column, non-contiguous summary
  tables broke the scraper); counts are now correct. The `Test.finish` instrumentation
  forwards kwargs and guards its emission, so it survives Julia-version signature drift.
- **Gate eval no longer crashes with a `FieldError`** on REPL backends that lack
  `ast_transforms` (e.g. the Antigravity IDE); it degrades gracefully instead (#56).
- XDG cache-dir handling (#42); a failed session now writes its logfile; stale
  VS Code references in the README (#36); Qdrant volume-persistence docs (#37).

### Internal

- Split five multi-thousand-line files (`gate.jl`, `gate_client.jl`,
  `tool_definitions.jl`, `setup_wizard_tui.jl`, `qdrant_indexer.jl`) into topical
  modules and slimmed `Kaimon.jl`; decomposed the MCP request handlers into
  per-method/stream helpers.
- Dead-code removal and several latent-bug fixes surfaced by static analysis.
- CI: added a link checker (#32).

### Acknowledgments

Thanks to **@jonalm** for the detailed report behind much of the session/routing
hardening (#55), to **@Eben60** for the GLMakie/IDE-REPL investigation (#56), and to
everyone who filed issues that shaped this release
(#34, #36, #37, #41, #42, #46, #47, #50, #51, #56).

<!-- DRAFT: generated from `git log main..2.0-integration`; trim/reword before release. -->

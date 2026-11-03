# Changelog

Release notes for Kaimon and KaimonGate (`lib/KaimonGate`), newest first. Each entry is also published on the GitHub release for its tag.

## Kaimon 2.12.0 (unreleased)

[Diff since v2.11.1](https://github.com/kahliburke/Kaimon.jl/compare/v2.11.1...v2.12.0)

**New:**
- On Linux, agents' processes can be confined with Landlock. With `KAIMON_CONFINE_POLICY` naming a policy file, an agent and everything it runs can read all but the policy's denied paths and write only its working directory, a temporary directory and its CLI's state. The kernel enforces it, so it holds for the agent's own file and shell tools. `agent_open` takes `confine_write` and `confine_allow` for folders one agent may also write or read. See the security docs.

**Fixes:**
- On Windows, replies from a gate are read as soon as they arrive. The request reader, the stream readers and the service endpoint wait on each socket's own watcher instead of opening a libuv poll handle per receive, which Windows does not support on a socket that already has one: replies arrived hundreds of milliseconds to seconds late, and a notebook's local worker showed as unresponsive. Requires KaimonGate 1.6.
- Extension processes honor `maxlog`, and leave it out of the logged fields.

## KaimonGate 1.6.0 (unreleased)

[Diff since KaimonGate-v1.5.2](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.5.2...KaimonGate-v1.6.0)

- `set_request_router!(router)` lets a host choose where each request runs, for example on threads of its own for status and UI requests. Routed requests are not counted against the in-flight cap, and at the cap the gate keeps reading so they are still served, holding default-lane requests in a bounded backlog (`KAIMON_GATE_MAX_DEFERRED`, 256).
- `serve(; owner_wake = true)` runs the request loop event-driven: it parks until a request arrives or a reply is queued, and sends each reply at once instead of noticing it on the next receive timeout. A sequence of requests then takes a fraction of a millisecond per request instead of several. Also set by `KAIMON_GATE_OWNER_WAKE` or `owner_wake` in `kaimon.toml` `[gate]`; off by default.
- Timed receives wait on the socket's own watcher (`_recv_within`) rather than setting `rcvtimeo`, which made every wait open a libuv poll handle. On Windows that delayed replies by up to seconds.
- A TCP gate exits promptly on SIGTERM. Its exit cleanup runs inside libuv's loop, so it now closes the sockets without terminating the ZMQ context or printing, both of which could wait there forever.

## Kaimon 2.11.1 (2026-11-01)

[Diff since v2.11.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.11.0...v2.11.1)

**Changes:**
- Each agent Kaimon starts gets its own token instead of the global API key. The token is minted at spawn and revoked when the agent ends, so a config file or environment left behind by an agent holds nothing that still works. It is also the only source of the agent's identity: the security gate accepts it, the agent's MCP session is bound to it, and an `X-Kaimon-Agent-Id` header no longer grants anything. A session that belongs to one agent refuses another agent's token. This makes agent calls reliably attributable; it does not contain an agent that has unrestricted native file or shell access (see the security docs).
- The TUI shows the active security mode on the Server tab and in the Config tab, and counts refused requests with the reason for the most recent one. In the Agents tab, each agent shows a fingerprint of its token (never the token itself), the MCP session bound to it, and when it last made a call.

**Fixes:**
- The security docs now describe the modes as the server enforces them: `relaxed` requires the API key, `lax` accepts localhost only, clients send the key as `Authorization: Bearer`, and an empty IP allowlist refuses every request in `strict` mode.
- With Revise, changes to MCP request handling take effect without restarting the server. The handler was nested inside `start_mcp_server`, so the running server kept the version it started with.

## Kaimon 2.11.0 (2026-11-01)

[Diff since v2.10.4](https://github.com/kahliburke/Kaimon.jl/compare/v2.10.4...v2.11.0)

**New:**
- Codex as a Kaimon agent: `acp:codex[:model]` drives Codex through the ACP adapter `@agentclientprotocol/codex-acp`, with your existing Codex login, including a ChatGPT plan (#108, by @gwr-de). Codex connections inherited from your own config are disabled for the agent, so its Kaimon tool calls always carry its identity and policy, including the recursion guard. The adapter is checked at startup, and Codex's own file and shell tools follow Codex's approval and sandbox settings.
- The Codex installer writes a native HTTP connection that the Codex CLI and VS Code extension share, without `mcp-remote`, and rewrites only Kaimon's table in `config.toml` (#108).
- A managed llama.cpp embedding backend for search: llama-server runs on loopback with a per-launch API key, serving the same GGUF model as Ollama, so existing indexes stay valid. `embedding.llamacpp_server` can name your own llama-server build, and Ollama's address is now a setting.
- Managed Qdrant runs on loopback with a per-launch API key. Its storage, port, and a user-run server are set in `search.json`.
- Cross-project search queries every Kaimon collection directly and merges the hits by score. The merged collection that copied every vector is no longer written, and an old one is removed at startup.
- An embedding model can be removed from the Search tab.

**Changes:**
- `cancel_eval` records a request instead of ending the job: `check_eval` shows "cancel requested" until the code stops, and the job is then recorded as `cancelled` with its result. A finished job, an unknown id, or an ambiguous prefix is answered without changing anything (#107, by @abavoil).
- The Activity pane marks a promoted `ex` by how its background job ended: ✓ completed, ✗ failed, ⊘ cancelled, ⏳ still running.
- Indexing skips chunks already embedded with the current model, so an interrupted index resumes where it stopped, and the configured embedding model is checked before indexing starts. Long chunks are embedded in pieces of at most 4,000 characters.
- When search falls back to lexical matching, it names the embedding backend and model it could not reach.

**Fixes:**
- An extension's TUI panel can reach its own extension session, which agent-facing lookups hide by default.
- A one-line docstring stays attached to its own definition in index chunks.

## Kaimon 2.10.4 (2026-10-30)

[Diff since v2.10.3](https://github.com/kahliburke/Kaimon.jl/compare/v2.10.3...v2.10.4)

**Fixes:**
- A `KaimonGate.stash` key ending in a non-ASCII character, such as `∞`, no longer crashes the Kaimon server. Each stream message from a session is handled on its own, so one that fails is logged and dropped.
- Test summary rows, launch-config summaries in the Config tab, and tab completion in the debug console handle non-ASCII text.
- Managed Qdrant gets as long as it needs to load its collections at startup. The wait resets whenever Qdrant logs progress, up to 10 minutes. Its log is rotated to `qdrant.log.1` at startup once it passes 32 MB.

## KaimonGate 1.5.2 (2026-10-29)

[Diff since KaimonGate-v1.5.1](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.5.1...KaimonGate-v1.5.2)

- `KaimonGate.is_cancelled()`, `stash()` and `progress()` work inside `mt=true` evals, and output printed by those evals is attributed to their request. The request id now reaches the REPL backend task that runs them (#103, fixed by @abavoil in #106).

## Kaimon 2.10.3 (2026-10-29)

[Diff since v2.10.2](https://github.com/kahliburke/Kaimon.jl/compare/v2.10.2...v2.10.3)

**Fixes:**
- `tools/list_changed` reaches a client on its POST responses even when its GET receive stream also took the notification. A stream the client had stopped reading, such as one left over from an idle session, could consume it, so tools an extension registered stayed hidden until `/mcp` was run (#100, fixed by @csvance in #101).
- A gate tool call that changes the tool list, such as an `ex` that loads an extension, carries the notification ahead of its result.
- A session the server had forgotten (reaped as idle, or from before a restart) is sent the pending list changes again on its first request back.

## Kaimon 2.10.2 (2026-10-28)

[Diff since v2.10.1](https://github.com/kahliburke/Kaimon.jl/compare/v2.10.1...v2.10.2)

**Fixes:**
- `run_tests(coverage=true)` counts coverage the way LocalCoverage and Coverage.jl do (through CoverageTools). The lines of a function no test called, and of a file no test loaded, now count as not covered. Before, they were left out, which overstated coverage.
- Coverage is only collected for the project under test, so dependencies no longer collect stray `.cov` files. Every `.cov` file a run produces in the project is removed afterwards, `test/` included.
- A project under a symlinked path, such as macOS's `/tmp`, now gets coverage. Julia's `--code-coverage=@<path>` records nothing there, so Kaimon uses `--code-coverage=user` for such a project.

## KaimonGate 1.5.1 (2026-10-27)

[Diff since KaimonGate-v1.5.0](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.5.0...KaimonGate-v1.5.1)

- CURVE key buffers stay rooted while they are copied into strings.
- A failed `execvp` during a restart reports the errno of that failure.

## Kaimon 2.10.1 (2026-10-27)

[Diff since v2.10.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.10.0...v2.10.1)

**Fixes:**
- A reply that arrived while another request was being sent on the same gate connection could be left unread, so the call waited out its timeout.
- Shutting down a session Kaimon started (`manage_repl shutdown` or the TUI) now stops its process, closes its terminal and reaps it, including a stalled session. A session that exits on its own is reaped as well. Before, each one left a zombie process and an open pseudo-terminal, and new sessions eventually began to fail (#105, reported by @michakraus).
- A timeout on a session started in the last few minutes says it may still be loading packages.
- `kaimon` exits without Julia's C exit hook. On Julia 1.13 that hook deadlocked most exits of a process with ZMQ and HTTP threads still live.
- The backtrace peek only signals a local gate with a known pid. A remote gate's pid belongs to another machine, and pid 0 would have signalled Kaimon's own process group.
- A client speaking MCP 2026-07-28 is answered so that it falls back to the `initialize`-based protocol, instead of being served as though it had initialized.

**Requires Tachikoma 2.8**, which fixes a heap overwrite on macOS each time a TUI entered raw mode, the likely cause of the crash in #89.

## KaimonGate 1.5.0 (2026-10-07)

[Diff since KaimonGate-v1.4.0](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.4.0...KaimonGate-v1.5.0)

- Restores the capture stream after `redirect_stdout(f, io)` / `redirect_stderr(f, io)`. Before, a session's output was left on a dead pipe.
- A cell that loads packages keeps the output of its other statements (#96, reported by @oschulz).
- Every overlapping eval is told about the overlap.
- `KAIMON_CACHE_DIR` lets a gate find a Kaimon that runs with its own cache directory.

## Kaimon 2.10.0 (2026-10-07)

[Diff since v2.9.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.9.0...v2.10.0)

**Print stripping you can configure (#94, #95).** How much of an agent's `println`/`@show`/logging is removed is now a setting: Config tab `[o]`, or `KAIMON_PRINT_STRIP`.
- `moderate` (the new default) only removes calls the cell runs as statements, and only with `q=true`. Function, macro, lambda and `do` bodies are left alone.
- `high` is the previous behavior. `off` removes nothing.
- Removal now cuts the call out of the source text, so the rest of the cell reaches the REPL exactly as written. `$` interpolation inside macros works again.
- A removed `@show x = 1` still runs `x = 1`. `Profile.print(io)` and other non-Base `print` functions are never touched.

**Private agent sessions (#97).**
- `start_session(private=true)`, or Config tab `[a]` (`KAIMON_AGENT_SESSIONS=private`), gives an agent a session no other agent is handed.
- Tools called without `ses` now go to the caller's bound session.
- Every overlapping eval is told about the overlap, not just the one that joined second.

**`instantiate` launch setting (#99).** Spawned sessions run `Pkg.instantiate` without precompiling the whole manifest by default. `always` and `never` are available per project, in `kaimon.toml`, `projects.json` or the Launch Config modal. Its output goes to the session log, and a failure no longer stops the session from connecting.

**Restricting a claude agent to its tools.** `agent_open(only=true)` makes `allowed_tools` the agent's entire tool set. The CLI loads only the built-in tools it names and no MCP servers except Kaimon's, and Kaimon hides and refuses its own tools the list doesn't name.

**Running Kaimon inside another service.**
- `KAIMON_CONFIG_DIR` and `KAIMON_CACHE_DIR` give an instance its own state, and each instance reaps only the extensions it started.
- The `X-Kaimon-Allowed-Tools` request header limits the tools of that request's caller.
- `KAIMON_RESTRICTED=1` gives a request without a list no tools.
- `KAIMON_CODE_INDEX=0` turns off code indexing.

**Also:**
- A cell that loads packages keeps the rest of its output (#96).
- `manage_repl restart` accepts stalled sessions (#98).
- `run_tests` caches the environment it builds from `[extras]`/`[targets]` and says whether it was built or reused.
- A restarted gate takes its namespace back from a predecessor whose process has exited.
- A tool call waits for a gate that is still connecting, and fails at once for a stalled gate whose process is gone.

**Fixes:**
- An SSE socket leak that eventually broke starting processes (`grep_code` and `run_tests` failing with `EBADF`).
- Lexical-search operations failing in tasks started before SQLite was loaded.
- Qdrant requests failing on a pooled connection Qdrant had closed.

**Thanks** to @oschulz for the detailed reports behind #94, #95, #96, #97 and #99, and to @abavoil for reporting #98 and contributing the fix.

Works with KaimonGate 1.4; 1.5.0 carries the gate-side fixes above.

## Kaimon 2.9.0 (2026-09-22)

[Diff since v2.8.6](https://github.com/kahliburke/Kaimon.jl/compare/v2.8.6...v2.9.0)


**ACP agent backend.** `agent_open(model="acp:<agent>[:<model>]")` drives any agent that speaks the [Agent Client Protocol](https://agentclientprotocol.com) over stdio — `opencode`, `claude` (via `claude-agent-acp`), `gemini` — alongside the existing claude CLI and local Ollama/MLX backends. Because ACP exposes the model as a session method rather than a spawn flag, `agent_set_model` repoints a **live** agent without losing its conversation, and `agent_status` now reports `queues_prompts`.

**Permission presets `notebook` and `specialist`.** `notebook` allows Kaimon's own tools and denies the agent's native file and shell tools, for an agent working on a notebook where `slate_*` sees live cell state and `Read` sees stale disk. `specialist` is `notebook` without the allowance, so a spawn's `allowed_tools` is its entire toolset. How far a preset reaches into an ACP agent's *own* tools depends on the agent, and a spawn now reports on its event stream when it cannot reach them.

**Portable `[launch] julia_version` (#91).** A project can name the Julia it needs as a patch (`1.12.6`) or a series (`1.12`), resolved against juliaup, instead of a `julia_bin` path that only exists on one machine. Sessions and `run_tests` resolve the binary through the same code, and each version gets its own `Manifest-v<major>.<minor>.toml`.

**An extension's tools stay listed across a restart.** Restarting an extension from the TUI or `manage_extension` holds its tools in the advertised list instead of unregistering them, so a connected agent never sees the toolset change; a call arriving mid-restart parks until the extension is back. Waits are configurable via `extension_tool_hold_seconds` and `extension_tool_park_seconds`.

**Behaviour change.** The recursion guard now also denies the CLI's own subagent spawners (`Agent`, `Task`, `Workflow`) by default, so an owned agent cannot multiply processes by that route. Restrictions were always inherited by subagents; the count was not. Pass `disallowed_tools = []` to allow nested agents as before.

## Kaimon 2.8.6 (2026-09-19)

[Diff since v2.8.5](https://github.com/kahliburke/Kaimon.jl/compare/v2.8.5...v2.8.6)

Require Tachikoma 2.7, which spawns a Windows pseudo-console instead of erroring. This is what makes `start_session` work on Windows (#79).

## Kaimon 2.8.5 (2026-09-17)

[Diff since v2.8.4](https://github.com/kahliburke/Kaimon.jl/compare/v2.8.4...v2.8.5)

Require Tachikoma 2.6.2, which fixes Windows console input: arrow keys and Esc reached the TUI as stray characters and mouse movement produced spurious tab switches (#93).

## Kaimon 2.8.4 (2026-09-12)

[Diff since v2.8.3](https://github.com/kahliburke/Kaimon.jl/compare/v2.8.3...v2.8.4)

Extension environment resolution.

- Resolve every extension's environment alongside Kaimon, dev checkouts included. A checkout was previously launched from its own manifest, so a dependency it shares with Kaimon could resolve to a different version in each. The subprocess stacks both environments on LOAD_PATH and takes the first that has a package, so the mismatched pair failed to precompile without naming either one. This also drops the boot time resolve that re-armed the conflict on every start.
- Retry a managed environment build once from a clean Project.toml and Manifest.toml. A cached environment can pin a developed path that has since moved, which fails the resolve outright instead of being re-resolved around. The failed attempt's log is preserved.
- Report the first error line from the current boot when an extension crashes, alongside its exit code. Previously only the exit code was surfaced and the cause sat unread in the extension log.

## Kaimon 2.8.3 (2026-09-10)

[Diff since v2.8.2](https://github.com/kahliburke/Kaimon.jl/compare/v2.8.2...v2.8.3)

Julia 1.13 compatibility. No API or behavior changes on 1.12.

- Fix a load failure on Julia 1.13, where Base.JuliaSyntax dropped the terminal `MacroName` kind. Because `K"..."` resolves during lowering, the missing kind failed the whole package at load (#88).
- Fix `run_tests` on Julia 1.13. The test runner hooked `Test.push_testset`, which was removed when the testset stack moved to ScopedValues.
- Rebuild extension environments per Julia minor version. A manifest resolved under one minor pins stdlib JLL versions the next ships differently, which failed the extension at load.

## Kaimon 2.8.2 (2026-09-08)

[Diff since v2.8.1](https://github.com/kahliburke/Kaimon.jl/compare/v2.8.1...v2.8.2)


Requires Tachikoma 2.6.1.

Tachikoma 2.6.0 and earlier registered a `tachi` CLI app from a build step, pointing into the read-only package tree. That entry makes every later `pkg> app` operation fail with `Permission denied`, including updating Kaimon, which installs as an app itself. Tachikoma 2.6.1 drops the build step and this release raises the floor past the affected versions.

The stale entry survives the upgrade. If you installed Kaimon before this release, remove it once by hand:

```
pkg> app rm Tachi
```

## Kaimon 2.8.1 (2026-09-07)

[Diff since v2.8.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.8.0...v2.8.1)

Requires KaimonGate 1.4, which is where this release's user-visible changes are. A long-lived session gets three fixes:

- **A gate that lost its control plane stayed bound, running and deaf** (#86). The ROUTER owner loop treated a transient recv error the same as a dead socket and exited, unsupervised, so every tool call failed with "Gate not connected" while the process, the socket and the running flag all looked healthy. The loop no longer exits on a transient error, and an exit that does happen is noticed and respawned on a rebound socket. Thanks to @csvance for the diagnosis and the fix (#87).
- **An explicit remote TCP gate restarted as a plain IPC gate** on a different port, having also dropped its namespace and both `allow_*` options. The restart configuration was read from module state after teardown had reset it; it is now taken before teardown.
- **A CURVE gate could bind with no authenticator behind it.** The ZAP handler was started before the gate was marked running, and a handler scheduled in that window closed the socket it had just bound.

Reflecting a session's tools is also cached now. A client reflects every tool on every heartbeat ping and each reflection read the whole file defining the tool, so an idle gate spent most of its time re-reading the same files.

The only change on the Kaimon side is that the extension stream subscriber reaches the gate's ZMQ context through the public `KaimonGate.gate_context()` rather than a private binding.

## KaimonGate 1.4.0 (2026-09-07)

[Diff since KaimonGate-v1.3.3](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.3.3...KaimonGate-v1.4.0)

**Fixed**

- An explicit remote TCP gate restarted as a plain IPC gate on a different port, dropping its namespace and both `allow_*` options. Both restart paths tear down before rebuilding the launch command, and the command was assembled from module state that teardown had just reset. The configuration is now taken before teardown and handed to the restart.
- A ZAP handler scheduled before the gate was marked running exited immediately and closed the socket it had just bound, leaving a CURVE gate to bind with no authenticator behind it. The handler now runs until its own socket is closed and does not depend on that flag's timing.

**Changed**

- Per-session state is held in a single `GateSession` rather than ~30 module-level `Ref`s reset by name at teardown. Dropping the session is the teardown, so a field added to it cannot be forgotten on stop — which is how the restart bug arose. Process-scoped state (job results, the capture mux, host hooks, the reflection caches, the stream-presence callbacks) deliberately stays module-level; the distinction is documented where the struct is defined.
- `gate_context()` is public, for a host that creates its own sockets on the gate's ZMQ context.
- The supervisor respawning a faulted message loop is now covered by a test, which needed the ability to build gate state without binding a real gate.

## Kaimon 2.8.0 (2026-09-06)

[Diff since v2.7.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.7.0...v2.8.0)

**New tools**

- `edit_code` — scoped multi-file edit, the write side of `grep_code` with the same `path`/`file`/`glob` scoping. Every `.jl` is parsed before anything is written and a single parse failure aborts the whole batch untouched, so a bad pattern can never leave a half-applied edit behind. Returns the unified diff.
- `rename_symbol` — identifier rename over JuliaSyntax's token stream, so it distinguishes an identifier from a comment or a string while still renaming an interpolated `$name`. Not scope-aware; scope it with `path`/`glob` and read the returned diff.

**Fixed**

- Headless server stopped itself when backgrounded from a shell (#85). Reading the controlling terminal, or putting it in raw mode, raises SIGTTIN/SIGTTOU on a background process group and stops every process in it, leaving the port bound with nothing left to accept on it. The quit-key reader now also requires being the terminal's foreground process group, child processes are spawned with `stdin=devnull`, those signals are ignored in headless mode, and SIGTERM gets the same clean teardown the quit key runs.
- Startup output no longer writes carriage returns and escape codes into a redirected log; each status prints once, plainly, when stdout is not a terminal.
- A default config is written on a headless first start, instead of blocking on the interactive setup wizard.
- The startup environment refresh is skipped for a registry install.
- Extension boot resolves only in a dev checkout. Resolving a managed environment reached back into the read-only depot directory, and where that was writable it planted a `Manifest.toml` that made the install read as a dev checkout from then on.
- Kaimon and the extension now resolve in one environment.
- The Extensions detail pane refreshes when `enabled` / `auto_start` are toggled, rather than showing the old value until the selection moves.
- Check the IPC socket path length before binding (KaimonGate 1.3.3).

## KaimonGate 1.3.3 (2026-09-06)

[Diff since KaimonGate-v1.3.2](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.3.2...KaimonGate-v1.3.3)

**Fixed**

- Check the IPC socket path length before binding. A cache directory long enough to push the socket path past the platform `sun_path` limit now fails with a clear error instead of binding a silently truncated name.
- Precompile the gate startup path (#82).

## KaimonGate 1.3.2 (2026-09-02)

[Diff since KaimonGate-v1.3.1](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.3.1...KaimonGate-v1.3.2)

- Precompile KaimonGate's startup path (#82, by @BJMCox).

## Kaimon 2.7.0 (2026-08-25)

[Diff since v2.6.1](https://github.com/kahliburke/Kaimon.jl/compare/v2.6.1...v2.7.0)

### Search indexing: one source of truth for what gets indexed (#80)

Directory resolution was duplicated across `index_project`, `sync_index`, and the Collection Manager, and the copies disagreed — a project with no `src/` was reported as having stale files that indexing never visited. The stale count and the indexer now derive from a single file enumeration, so they cannot drift apart.

**What changed**

- Unconfigured projects now fall back to git-aware project detection, including source files in the project root.
- The default extension set covers the common languages. The previous Julia/TypeScript-only default silently indexed nothing for a Python, Rust, or Go project.
- A directory entry ending in `/*` is scanned non-recursively. Auto-detection uses this for the project root, so root-level files are indexed without the root absorbing the entire tree.
- Generated and vendored content is excluded in layers: `.gitignore` (in a git repository the candidate list comes from git, matching `grep_code`'s scope), build and vendor directory names, generated-artifact suffixes, and size/single-line ceilings that catch committed bundles.

Explicit per-project configuration is unchanged and still takes precedence.

## Kaimon 2.6.1 (2026-08-22)

[Diff since v2.6.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.6.0...v2.6.1)

### An extension that moved is picked up without restarting Kaimon

`extensions.json` was reconciled by namespace alone, so an entry whose `project_path` changed was
never re-read: the pane went on naming the old directory and the process kept running from it. That
is the normal shape of an upgrade — a registry or app install lives at `packages/<Name>/<slug>`, the
slug follows the version's tree hash, and the old slug survives until a `Pkg.gc`, so nothing errored
and the update simply appeared not to have happened.

The registry entry is now compared as well, and the running process is replaced when the install
moved under it — a graceful gate shutdown first, then a spawn against the new path, whose managed
environment rebuilds on its own. Deliberately narrow: an extension stopped by hand stays stopped, a
crashing one keeps its backoff, and `enabled` flipped in the file is honoured either way. Two entries
claiming one namespace are no longer both run.

Also: the startup budget begins when the process launches rather than covering the environment
rebuild that precedes it, which for a version bump is a full precompile.

## Kaimon 2.6.0 (2026-08-22)

[Diff since v2.5.1](https://github.com/kahliburke/Kaimon.jl/compare/v2.5.1...v2.6.0)

**Long test runs background automatically.** `run_tests` used to hold the call open for the whole suite and cancel at ten minutes, so the slowest suites were the ones that got killed. It now estimates duration from previous runs of the same invocation and hands back a run id immediately, or promotes on the clock when there's no history yet. Estimates key on project, pattern and coverage together — with no project-wide fallback, so a filtered subset never inherits the full suite's duration.

**New `check_tests` tool** collects a backgrounded run: a one-line progress summary while it's going, and exactly what `run_tests` would have returned once it finishes. Also lists runs in flight, and cancels.

Runs on one project are serialised by default, since overlapping suites share fixtures, temp directories and global state; raise `KAIMON_TEST_CONCURRENCY` to allow overlap. The backgrounding threshold is `KAIMON_TEST_PROMOTE_AFTER` (default 30s, `0` disables).

Also fixes `ollama_embed` defaulting to the compiled-in embedding model rather than the one configured in `search.json`, which could place vectors in a different space than the collections the indexer builds.

## Kaimon 2.5.1 (2026-08-21)

[Diff since v2.5.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.5.0...v2.5.1)

Fix `.kaimon/tools.json` silently disabling every tool. Any config file switched the surface to an allowlist built from an empty set, so a file that only turned one tool off turned all of them off — including the `disabled_tools`/`enabled_tools` example in the documentation, whose keys were never read at all. A config now either selects a surface (enabled `tool_sets`, named `enabled_tools`) or adjusts the default one, so a subtract-only file reads as a denylist. Unknown tool names and a resolution matching no tool both warn.

Also requires Reseau >= 1.3.5: earlier versions verify an expired TLS fixture in their own precompile workload and can no longer precompile, taking HTTP down with them.

Closes #78.

## Kaimon 2.5.0 (2026-08-18)

[Diff since v2.4.1](https://github.com/kahliburke/Kaimon.jl/compare/v2.4.1...v2.5.0)

Extensions can declare startup environment variables in their `kaimon.toml` manifest, for runtime settings a process only reads at start and that no Julia flag exposes. Defaults apply only where the parent has not already set the variable, so a value you export always wins.

## Kaimon 2.4.1 (2026-08-18)

[Diff since v2.4.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.4.0...v2.4.1)

Fix `StringIndexError` when truncating output containing multi-byte characters. Output truncation guarded on character counts but sliced by byte index, so a cut landing inside a multi-byte codepoint threw and discarded the entire eval result; the retained tail was also taken from the wrong offset on non-ASCII input. Fixed at the other data-truncation sites as well.

Closes #74, #75.

## KaimonGate 1.3.1 (2026-08-18)

[Diff since KaimonGate-v1.3.0](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.3.0...KaimonGate-v1.3.1)

Fix silently-empty tool descriptions when a docstring ends in a multi-byte character. The source-docstring extractor stripped the closing `"""` by byte index, so a multi-byte character immediately before it threw `StringIndexError`; the extractor's catch-all swallowed that and returned an empty description.

## Kaimon 2.4.0 (2026-08-13)

[Diff since v2.3.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.3.0...v2.4.0)


Requires KaimonGate 1.3, which carries the gate-side half of the session-tool
changes below.

#### Features
- Session-tool calls are bounded by SILENCE rather than a flat wall clock, so a
  tool that reports progress runs as long as it needs, and a tool author can
  declare an explicit budget via `timeout_ms`.
- Registering session tools on a running gate is now additive: a name is
  replaced, everything else survives. Previously the last registrant won and
  earlier tools vanished, which could take down a session rather than a single
  feature.
- Tool-call observer hook, for code that needs to know a tool ran without
  wrapping the handler (a handler's signature is its published schema).

#### Fixes
- A fractional `created_at` in the global `config.json` — including the value
  written by the `time()` fallback — threw against the `Int64` field, and the
  surrounding catch turned that into "no config", re-running the setup wizard
  over an existing configuration. Rounded on read.

## KaimonGate 1.3.0 (2026-08-13)

[Diff since KaimonGate-v1.2.0](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.2.0...KaimonGate-v1.3.0)


#### Features
- Session-tool deadlines now measure SILENCE rather than total wall clock: any
  frame from the gate refreshes the deadline, so a tool that reports progress
  runs as long as it needs. Adds a keepalive so a quiet-but-alive call is
  distinguishable from a hung one, plus an absolute runaway backstop that yields
  to an explicitly declared budget. `GateTool` gains `timeout_ms` for work that
  is legitimately slow and silent.
- `serve(tools = ...)` on a running gate now merges by name instead of replacing
  the registry outright. A session has several registrants that cannot see each
  other, so the previous behaviour let the last one silently drop the rest.
- New tool-call observer hook. Observers run after the handler and cannot alter
  its result; a throwing observer is swallowed. Wrapping a handler was not an
  option because a handler's signature is its published schema.

## Kaimon 2.3.0 (2026-07-29)

[Diff since v2.2.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.2.0...v2.3.0)

# Kaimon 2.3.0

Custom system images for managed sessions, a fix for restarts losing the gate
when Julia was launched with a separated `--sysimage` flag, and two silent-data
bugs: per-project launch config and session preferences were being dropped on
load, and a clean shutdown ended in a stack trace.

Requires Tachikoma 2.5 and bundles KaimonGate 1.2.

### Custom system images and launch config (#69)

A project with a custom sysimage can now declare it, so a session Kaimon spawns
boots the same way you start the project by hand instead of paying full
compilation cost. `LaunchConfig` gains `sysimage`, `julia_bin` (a Julia binary,
or a wrapper script that forwards its arguments to one), and `startup_file`
(`~/.julia/config/startup.jl` was previously suppressed unconditionally).

There are two places to set it. Per user, in `projects.json` — editable from the
TUI Config tab, select a project and press `e`:

```json
"launch_config": { "sysimage": "MyProject-image.so", "heap_size_hint": "8G" }
```

Or per project, checked into the repo, in the project's own `kaimon.toml`, so
everyone working on it gets the same launch recipe with no local setup:

```toml
[launch]
sysimage = "MyProject-image.so"   # relative → resolved against the project root
threads = "auto"
```

The user's entry is overlaid field-wise on the project's, so a single field can
be overridden locally while the rest is inherited. A configured sysimage that
isn't on disk is logged and skipped — the session still starts, on the default
image. Thanks to **@ufechner7** for the report.

### Fix: restarting a REPL launched with `--sysimage <path>` (#69)

Restarting a REPL you started yourself replays its original launch flags, so a
custom sysimage, thread count, and heap hint survive. But the check for "was
this launched with a script?" didn't know which flags take a value as a separate
token, so the path in `julia --sysimage /path/sys.so` looked like a script
argument. The restart then took the verbatim-replay branch and re-exec'd a plain
interactive REPL that never called `serve()` — the session didn't come back at
all. The attached forms (`-J/path`, `--sysimage=/path`) were unaffected.

Value-taking flags are now recognized as a shared set, and `-e`/`-E`/`-L` are
explicit user-code triggers rather than a side effect of the path check.

### Fix: launch config and session preferences were silently discarded

Nested JSON objects parse as `JSON.Object`, which is an `AbstractDict` but not a
`Dict` — and both `projects.json` readers guarded on `isa Dict`. Every
per-project `launch_config` (threads, GC threads, heap hint, extra flags) and
every persisted `mirror_repl` / `allow_restart` preference was dropped on load
and silently replaced with defaults.

### Fix: clean shutdown no longer ends in a stack trace

The managed-Qdrant `atexit` reaper read its child's pid *after* terminating it,
to decide whether the PID file was its own. `getpid` throws `ESRCH` on a handle
whose process has exited and been reaped — the expected state at that point — so
the error escaped `atexit` on every clean exit.

## KaimonGate 1.2.0 (2026-07-29)

[Diff since KaimonGate-v1.1.0](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.1.0...KaimonGate-v1.2.0)

#### Fixes

- **Restarting a REPL launched with a separated `--sysimage <path>` no longer loses the gate** (#69). The check for "was this process launched with a script?" only skipped the values of `-C`/`-J`/`--project`/`-t`, so any *other* flag whose value is a path looked like a positional script argument. The restart then took the verbatim-replay branch and re-exec'd a plain interactive REPL that never called `serve()` — so the session did not come back at all. The attached spellings (`-J/path`, `--sysimage=/path`) were unaffected.

  Value-taking flags are now recognized as a single shared set, used both to skip values during script detection and to fuse each flag with its value into one token when reconstructing the launch command. `-e`/`-E`/`-L` are explicit user-code triggers rather than a side effect of the path check.

#### Compatibility

- Paired with Kaimon 2.3.0, which requires `KaimonGate = "1.2"`.

## Kaimon 2.2.0 (2026-07-23)

[Diff since v2.1.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.1.0...v2.2.0)


#### Features
- **Binary streaming transport** — event-driven, wake-on-arrival stream draining
  and a zero-copy raw binary frame path for high-rate streaming consumers (live
  widgets/plots, KaimonSlate binary-emit), cutting stream latency and idle CPU.
- **Startup KaimonGate upgrade prompt** — on interactive launch, offers to update
  a stale registry-installed global KaimonGate so auto-connecting REPL sessions
  pick up the latest gate fixes. No-op for dev/current installs; dismissals are
  remembered per version; re-armed with `kaimon --reset-global-prompt`.

#### Fixes
- **#67** — a raw-mode Tachikoma TUI run from a gate REPL no longer wedges the
  host REPL on exit (stream guard via Tachikoma 2.4's `set_stream_guard!`).

#### Requires
- Tachikoma 2.4, KaimonGate 1.1.

## KaimonGate 1.1.0 (2026-07-22)

[Diff since KaimonGate-v1.0.1](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.0.1...KaimonGate-v1.1.0)


#### Features
- Event-driven stream draining (`wait_stream_messages!`) that wakes on frame
  arrival instead of polling on a fixed cadence, and a zero-copy raw binary
  frame path (`_publish_stream_raw`) that skips the Serialization envelope for
  high-rate streaming consumers. Binary payloads are preserved end-to-end as bytes.

#### Fixes
- Register a stream guard (via Tachikoma's `set_stream_guard!`) so a raw-mode
  Tachikoma TUI run from a gate-hosted REPL no longer wedges the host REPL's
  stdin on exit (Kaimon #67). Adds public `disable_wedge_guard!` for a host that
  runs its own persistent full-screen TUI alongside the capture mux. The guard is
  a no-op unless a Tachikoma new enough to define the hook is loaded.

## Kaimon 2.1.0 (2026-07-20)

[Diff since v2.0.8](https://github.com/kahliburke/Kaimon.jl/compare/v2.0.8...v2.1.0)


#### Features
- **Managed (zero-Docker) Qdrant** (#24): Kaimon lazily installs `Qdrant_jll` into a small Kaimon-owned environment and runs the binary itself — no Docker required. Includes TUI start/stop controls, autostart on launch, and create-collection/embedding robustness.

#### Fixes
- Extension runtimes are no longer treated as addressable REPL sessions: agents can no longer be auto-bound to (or eval in) an extension's runtime; explicit targeting points at `start_session` for a real REPL.
- Windows: resolve the npm `claude` shim via `PATHEXT` (#66), and stop leaking environment in spawn errors.
- Extensions receive Kaimon's active environment on `JULIA_LOAD_PATH`, and registry/app-installed extensions get a properly instantiated runtime env (#61, #65).

#### Compatibility
- Requires Tachikoma 2.3.7.

## Kaimon 2.0.8 (2026-07-18)

[Diff since v2.0.7](https://github.com/kahliburke/Kaimon.jl/compare/v2.0.7...v2.0.8)


Fixes extension boot on a fresh registry/app install (`pkg> app add Kaimon` + `app add <extension>`), which previously crash-looped. Two independent load-path failures, both resolved:

- **`using Kaimon` fails** — the extension subprocess carried the manifest-less `pkgdir(Kaimon)` on its load path. Kaimon now puts the running instance's active (manifest-bearing) environment there instead. (#61, thanks @mthelm85)
- **`using <ExtensionModule>` fails** — the extension was launched with `--project=<manifest-less, write-protected depot dir>`, so its own deps couldn't resolve. Kaimon now maintains a writable, instantiated environment per extension (`~/.julia/environments/kaimon-ext/<namespace>`) and launches against it; dev checkouts with their own manifest are unchanged. (#65)

## Kaimon 2.0.7 (2026-07-17)

[Diff since v2.0.6](https://github.com/kahliburke/Kaimon.jl/compare/v2.0.6...v2.0.7)

### Changes

- Require **Tachikoma 2.3.6**, which fixes input starvation in render-bound TUI apps (keyboard/mouse were dropped while the app kept animating when a frame exceeded its budget).

## Kaimon 2.0.6 (2026-07-17)

#### Fixes
- **Windows extensions no longer wedge at startup.** On Windows a local IPC gate is bound over TCP (no IPC transport); under a non-lax (API-key) security config it enforces its auth token, but the discovery watcher connected tokenless and was rejected with `"Authentication required"` — leaving extensions (e.g. KaimonSlate) stuck at `:starting` in a restart loop. The watcher now presents the same token, authenticating to its own local gate.
- **Fixed extension loading** by removing an unused `using ReTest` import that forced ReTest onto extension-subprocess `LOAD_PATH`s, where it failed to resolve.

#### Observability
- A health-check ping that receives an error reply (e.g. an auth rejection) is now logged, throttled to once per distinct message, instead of being silently treated as a healthy pong.

#### Dependencies
- Requires **Tachikoma 2.3.5** — Windows console-size/resize handling and `ReadConsoleInputW` mouse + keyboard support, plus international-keyboard decoding on all platforms.

## Kaimon 2.0.5 (2026-07-15)

[Diff since v2.0.4](https://github.com/kahliburke/Kaimon.jl/compare/v2.0.4...v2.0.5)

Security & Claude Code compat patch.

- **Security:** removed a localhost OAuth auto-mint that issued bearer tokens to anyone who could reach the port (auth bypass); Kaimon now accepts only configured API keys, and `Origin` validation rejects `localhost`-spoof hosts (e.g. `localhost.evil.test`).
- **Compat:** OAuth/OIDC probe paths return a clean 404 with a JSON error body, so modern Claude Code no longer crashes on discovery and keyless clients get a clear "Missing API key".
- **Chore/CI:** gitignore deploy artifacts; LinkCheck false-positive exclusion.

## Kaimon 2.0.4 (2026-07-12)

[Diff since v2.0.3](https://github.com/kahliburke/Kaimon.jl/compare/v2.0.3...v2.0.4)

**Fixes**
- **`ex`**: a call that omitted the `e` parameter (e.g. the code was passed as `code`) silently ran an *empty* eval — success with no result and only a bare `agent>` in the shared REPL. It now returns a clear error (with a hint when `code` was used), and the tool description / instructions / docs state plainly that the parameter is `e`.
- **TUI**: control characters (`\r`, `\n`, backspace, …) in tool-call content no longer smear the Activity table / log pane (carriage-return corruption seen on slate tool calls). Requires the companion Tachikoma 2.3.4 `set_string!` control-char strip; `[compat]` bumped to `Tachikoma = "2.3.4"`.
- **Gate**: the "advertised for discovery" diagnostic no longer prints to the console on interactive Julia startup — dropped to `@debug` for a user's own gate; spawned/extension gates keep it in their captured logs.

**Changed**
- **Code search**: `search_code` (by meaning) is now the documented default for discovery over `grep_code`; a `grep_code` call that finds nothing (a true negative) nudges toward `search_code`.

## Kaimon 2.0.3 (2026-07-11)

[Diff since v2.0.2](https://github.com/kahliburke/Kaimon.jl/compare/v2.0.2...v2.0.3)

- Auto-background threshold for long evals is now configurable (Config tab or `KAIMON_GATE_PROMOTE_AFTER`; 0 = never), and a promoted eval's finished result is now shown in the Activity tab instead of the placeholder (#59)
- Write the Antigravity MCP config where current builds read it — `~/.gemini/config/mcp.json` (also keeping the legacy path) (#57)
- Extension log viewer no longer freezes the TUI (and MCP server) on large logs; extension logs are now size-capped
- Fix reattaching to a detached remote worker (a stale connection could block reconnect)

## Kaimon 2.0.2 (2026-07-10)

[Diff since v2.0.1](https://github.com/kahliburke/Kaimon.jl/compare/v2.0.1...v2.0.2)

Minor bug fixes and agent-facing output-format tweaks.

## Kaimon 2.0.1 (2026-07-09)

[Diff since v2.0.0](https://github.com/kahliburke/Kaimon.jl/compare/v2.0.0...v2.0.1)


#### Fixed
- **Elicitation prompts no longer silently time out.** `grep_code` path-consent and `start_session` project-consent prompts were delivered to a single receive-stream outbox keyed by the caller's POST session id. Clients such as Claude Code present a *different* `Mcp-Session-Id` on their GET receive stream than on tool-call POSTs, so the targeted outbox was empty and the request no-op'd — an immediate "no answer" with no prompt shown. Delivery now targets the caller's own stream, else any open receive stream, else the in-flight tool-call SSE stream.
- **`tools/list_changed` is re-delivered on every change.** The persistent GET receive stream deduped notifications by method name for its entire lifetime, so a re-queued `tools/list_changed` (e.g. after each extension restart) was suppressed forever — forcing a manual reconnect. Notifications now carry a monotonic sequence and consumers track a per-session cursor, so every re-queue is delivered; the board is no longer drained, so a POST flush can't steal a notification from a concurrent GET stream.

#### Changed
- `run_tests` honors `|`-separated OR patterns: `pattern="a|b"` runs testsets matching *either*, by splitting into a ReTest disjunction array (a bare string was matched literally before).

## Kaimon 2.0.0 (2026-07-08)

[Diff since v1.3.1](https://github.com/kahliburke/Kaimon.jl/compare/v1.3.1...v2.0.0)

Kaimon gives an AI agent a live Julia REPL over MCP: run code, introspect types
and methods, drive the debugger, run tests, and search code against the running
session. 2.0 reworks search and the session model, changes how agents connect,
and splits the gate into its own lightweight package.

### Breaking changes

This is a major, breaking release — the highlights below are the full changelog,
but the changes most likely to affect an existing setup are:

- **`qdrant_search_code` is renamed to `search_code`** (now backend-agnostic and
  hybrid by default). Update anything that referenced the old tool name.
- **The default tool surface is tightened** (~68 → ~49 tools); several advanced
  tools are now gated off by default and must be explicitly enabled per project.

### A standalone gate: KaimonGate

The session and eval machinery now lives in KaimonGate, a separate package with a
small, tightly constrained dependency set. It is easy to add to your own project
or session without pulling in all of Kaimon, and spawned agent sessions boot it
instead of full Kaimon, so a session never recompiles Kaimon against your project.

### Search

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

### Sessions

Agents bind to the right gate from their workspace root, `start_session` reuses a
running gate instead of spawning a duplicate, and a new project is approved from a
prompt inside your client instead of by editing JSON (`allow_any_project` covers
container and VM setups).

### Long work that does not block

Any eval past about thirty seconds becomes a background job with progress and
cancellation, and it survives a restart.

### Agent backends

The supported agent is Claude today, built to speak ACP so other agents can plug
in soon. New and still experimental: local model backends (MLX and an in-process
Ollama loop) for keeping inference on your own machine.

### CURVE encryption, and a path to TachiRei

The gate transport can run CURVE encrypted over ZMQ, with key management and a
trust store in the TUI, which opens up secure connectivity across a network. It
also lays the groundwork for TachiRei.jl, a platform for persistent remote Julia
sessions and applications that people and multiple agents can connect to at once
(coming soon).


A browser-based notebook (a "slate") built on Kaimon's extension system, where you
and an agent build and run cells in the same document, with doc search and PDF
export. It ships separately as
[KaimonSlate.jl](https://github.com/kahliburke/KaimonSlate.jl).

### Windows and headless

Windows support: the gate uses TCP in place of IPC. Headless parity: the same
analytics, indexing, housekeeping, and clean shutdown as the TUI.

### Stability and performance

The ZMQ transport was rewritten (persistent DEALER/ROUTER, event driven messaging,
adaptive timeouts), lowering reply latency and idle CPU, and a broad pass closed a
long list of stability issues from the 1.x line.

---

### Thanks

To the contributors who shipped code in this release:

- **@KristianHolme** — Wayland clipboard support (#1) and Cursor / opencode client support (#2)
- **@haakon-e** — manual gate restart from the REPL and TUI (#17), and the detailed Infiltrator report behind #34

And to everyone whose issue reports shaped 2.0: **@jonalm** (#55), **@Eben60** (#56),
**@ufechner7** (#36, #37), **@mind6** (#41), **@csvance** (#42, #46), **@jeffwack** (#47),
**@brendanjohnharris** (#50), and **@1-Bart-1** (#51).

## KaimonGate 1.0.1 (2026-07-08)

[Diff since KaimonGate-v1.0.0](https://github.com/kahliburke/Kaimon.jl/compare/KaimonGate-v1.0.0...KaimonGate-v1.0.1)

- A session can carry a display label, and Slate stream events are routed to the right session.

## KaimonGate 1.0.0 (2026-07-08)

First release of KaimonGate, part of the upcoming Kaimon 2.0 release.

KaimonGate is the lightweight eval gate that runs *inside* a Julia session so the Kaimon MCP server can execute, debug, and introspect code. It depends only on ZMQ and the standard library, so splitting it out of Kaimon greatly reduces the dependency footprint required for Gate sessions — a session can connect without pulling in the full Kaimon dependency tree, which matters most on remote/compute nodes.

## Kaimon 1.3.1 (2026-04-16)

### Fix: custom port from config.json respected by TUI (#27)

The TUI entry point was ignoring the `port` field in `~/.config/kaimon/config.json`, always using the default 2828 unless `--port` was passed on the command line. The headless path already did the right thing — the TUI now matches.

Priority: CLI `--port` > config.json `port` field > default 2828.

### Install

```
]app add Kaimon@1.3.1
```


## Kaimon 1.3.0 (2026-04-16)

### What's New

#### Main-thread eval for GLMakie/GLFW (#21)
The `ex` tool now supports `mt=true` to route evals through the REPL backend on thread 1. Required for GLMakie, GLFW, and any library that needs the main thread.

```julia
ex(e="using GLMakie; scatter([1,2,3], [4,5,6])", mt=true)
```

#### Version compatibility check (#26)
Gate sessions now report their Kaimon version in health check pongs. The TUI warns when a session loads a mismatched version — catches the case where a stale dev'd copy in the global env causes silent serialization failures. The app startup also checks for version/path mismatches.

#### VS Code integration fix (#25)
Kaimon ships its own VS Code Remote Control extension — no third-party extension needed. Install from the TUI Config tab (`v`) or `Kaimon.install_vscode_remote_control()`. Fixed `list_vscode_commands` (was calling an undefined function). Extension installs globally without requiring a project.

#### Tool call tracking
The `total_tool_calls` counter and sparkline in the TUI status bar now actually work (were always showing 0).

#### server_log performance
The `server_log` tool now reads from an in-memory ring buffer instead of scanning the full log file on disk. Also added log rotation at 10MB.

#### Docs
- Fixed tab table (added Debug, Extensions tabs)
- Updated tool count (50+)
- Fixed `api_keys` format in configuration docs
- Updated install instructions to use registry

### Install

```
]app add Kaimon@1.3.0
```


## Kaimon 1.2.2 (2026-04-12)

### Main-thread eval for GLMakie/GLFW (#21)

The `ex` MCP tool now supports `mt=true` (main-thread mode), which routes evals through the REPL backend on thread 1. This is required for GLMakie, GLFW, and any library that needs the main thread for OpenGL/GPU calls.

#### Usage

```julia
ex(e="using GLMakie; GLMakie.activate!()", mt=true)
ex(e="fig = Figure(); scatter(fig[1,1], [1,2,3], [4,5,6]); display(fig)", mt=true)
```

Without `mt=true`, async evals run on default-pool threads, causing `ThreadAssertionError`. With `mt=true`, the gate spawns the eval on the interactive pool, and `gate_eval` routes through `REPL.call_on_backend` to execute on thread 1.

#### Install

```
]app add Kaimon@1.2.2
```


## Kaimon 1.2.1 (2026-04-07)

Bugfix release.

### What's Changed

- **Dismissible global env prompt** (#19) — The "Add Kaimon to your global Julia environment?" prompt on startup now offers `[Y/n/never]`. Choosing "never" persists the choice in `~/.config/kaimon/config.json` so you won't be asked again. Re-enable with `kaimon --reset-global-prompt`.

  The prompt text also now mentions alternatives (Julia 1.12 workspaces, ShareAdd.jl, per-project deps) for users who prefer to keep their global environment minimal.

Thanks @Eben60 for the report.

### Install

```julia
]app add https://github.com/kahliburke/Kaimon.jl#v1.2.1
```

## Kaimon 1.2.0 (2026-04-05)

### What's New

#### Gate.push_panel() — Push-based extension→panel communication
Extensions can now stream state updates to their TUI panels in real time via `Gate.push_panel(key, value)`. Values are delivered via ZMQ PUB/SUB and appear in the panel's `ctx._cache[:panel_state]` on the next frame — no polling or `ctx.eval()` needed.

#### Extension restart reliability
- Extensions now survive restarts cleanly — tools keep their namespace, SUB sockets reconnect, and the TUI panel auto-detects session key changes
- Stale extension connections are evicted on namespace collision (fixes "hello_2" dedup bug)
- Extension status accurately reflects connection state during restarts

#### MCP notification delivery
- Pending notifications (tools/list_changed, resources/list_changed) now use a shared dict instead of a single-consumer Channel, so both GET SSE streams and POST response flushes can deliver independently

#### HelloExtension polish
- Reference example now uses `@match` for idiomatic key handling
- Three-pane layout: greetings, dice rolls, and activity log with timestamped push events
- Comprehensive teaching comments explaining the ext_panel protocol

#### Extension documentation
- New sections: TUI Panel Protocol, Gate.push_panel() API, shutdown hooks
- Extension demo animation added to generate_assets.jl
- Updated installation instructions to pin release tags

### Install / Update

```julia
]app add https://github.com/kahliburke/Kaimon.jl#v1.2.0
```

## Kaimon 1.1.0 (2026-04-04)

Major feature release with 146 commits since v1.0.

#### Highlights

- **TCP Gate mode** — connect to remote Julia sessions over TCP with SSH tunnel support, token auth, and fixed PUB ports
- **Extensions system** — load third-party tools via an extensions manifest with auto-restart and lifecycle management
- **Cross-project semantic search** — search code across all indexed projects via Qdrant, with collection management UI
- **Background jobs** — long-running evals auto-promote to background jobs with `Gate.stash`/`Gate.progress` for intermediate reporting, persisted to SQLite
- **Session restart** — `Gate.restart()` from REPL or `[r]` from TUI Sessions tab, preserving session ID for automatic reconnection
- **Antigravity autoconfig** — new client config template for Google Antigravity (Streamable HTTP transport)

#### Improvements

- Test runner rewritten: extracted to template file, fixed `JULIA_LOAD_PATH` inheritance bug, added `project_path` parameter for running tests without a gate session, live progress reporting during test runs
- Global PUB event bus for GC-safe event delivery
- Thread-safe ZMQ recv to avoid finalizer segfaults
- Parallel health check pings with push-based ECG heartbeat
- Search config UI with TextInput fields, directory exclusions, draggable divider
- Extension boot scripts with `Pkg.resolve()` before loading

#### Compatibility

- Requires Julia 1.12+
- Tachikoma 2.1.0+

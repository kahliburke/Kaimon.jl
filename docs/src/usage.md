# Usage

Kaimon's terminal UI has seven tabs, each accessible by pressing its number key. This page walks through each tab.

![Kaimon dashboard](assets/kaimon_overview.gif)

| Key | Tab | Purpose |
|---|---|---|
| `1` | Server | Live server logs and status |
| `2` | Sessions | Connected Julia REPLs |
| `3` | Activity | Tool call history and results |
| `4` | Search | Semantic code search |
| `5` | Tests | Run and browse test results |
| `6` | Config | MCP client setup and onboarding |
| `7` | Advanced | Stress testing and diagnostics |

Press `q` to quit, `?` to show a key reference overlay.

---

## 1 — Server

The Server tab shows live output from the Kaimon MCP server: incoming requests, authentication events, errors, and internal diagnostics. Use it to confirm that clients are connecting and requests are being routed correctly.

The status bar at the top shows the server address and port.

---

## 2 — Sessions

The Sessions tab lists all Julia REPLs currently connected through the Gate.

![Sessions tab](assets/kaimon_sessions.gif)

Each entry shows:
- The 8-character **session key** (used to target tools at a specific REPL)
- Connection status and heartbeat health
- Julia version and active project

When multiple sessions are connected, tools that execute code require a `ses` or `session` parameter to specify the target. See [Sessions](sessions.md) for routing details.

---

## 3 — Activity

The Activity tab is a real-time feed of every tool call the MCP server has handled.

![Activity tab](assets/kaimon_activity.gif)

The left pane shows a scrollable list of tool call records. Each entry shows the tool name, session target, timestamp, and result status (success or error).

Select a record with `↑`/`↓` and press `Enter` to open the detail pane on the right, which shows the full input arguments, the return value, and any error message.

### Key Reference

| Key | Action |
|---|---|
| `↑` / `↓` | Navigate entries |
| `Enter` | Open detail pane |
| `Esc` | Close detail pane |
| `Tab` | Cycle pane focus |

---

## 4 — Search

The Search tab manages semantic vector indexes over your codebase and runs natural language queries against them.

![Search tab](assets/kaimon_search.gif)

The tab has three panes:

- **Status** (top) — Qdrant and Ollama health, active collection, embedding model
- **Query** (middle) — type your search query here
- **Results** (bottom) — ranked code chunks with relevance scores

Press `/` to focus the query input, type a natural language description, and press `Enter`. Use `Tab` to move to results and `↑`/`↓` to scroll.

Press `i` to index the current project, `m` to open the Collection Manager, and `o` to configure the embedding model.

![Search model configuration](assets/kaimon_search_config.gif)

![Collection manager](assets/kaimon_collection_manager.gif)

For full details — key reference, model options, collection management — see [Semantic Search](search.md).

---

## 5 — Tests

The Tests tab is primarily a display surface for test runs triggered by the AI agent via the `run_tests` tool. When the agent runs your tests, results stream in here in real time — you can watch progress, see which testsets pass or fail, and read failure details without leaving the TUI.

You can also trigger a run manually with `r`. If multiple gate sessions with a `test/runtests.jl` are connected, a picker dialog appears so you can choose which project to test.

![Tests tab](assets/kaimon_tests.gif)

Results stream in as they complete. When all tests finish, the pane shows a pass/fail summary tree.

Select a failed test with `↑`/`↓` and press `Space` to expand it. The right pane shows the failure message and backtrace. Toggle between the structured tree view and raw output with `o`.

### Key Reference

| Key | Action |
|---|---|
| `r` | Run tests (opens session picker if needed) |
| `o` | Toggle tree / raw output view |
| `F` | Toggle follow mode (auto-select newest run) |
| `x` | Cancel a running test |
| `↑` / `↓` | Navigate runs or tree nodes |
| `Space` | Expand / collapse tree node |
| `Esc` | Cancel running test |
| `Tab` | Cycle pane focus |

---

## 6 — Config

The Config tab handles all MCP client setup. It generates and writes configuration files for supported editors and CLI tools.

![Config tab](assets/kaimon_config.gif)

Supported clients: **Claude Code**, **VS Code** (Copilot / Continue), **Cursor**, **Gemini CLI**, **KiloCode**.

Press `i` to open the client list and select a target. Press `Enter` to write the config. Kaimon writes the correct format for each client including your API key if running in authenticated mode.

The onboarding flow (`o`) creates a `.julia-startup.jl` file for per-project auto-connect, and the global gate option (`g`) appends the same snippet to `~/.julia/config/startup.jl` so every Julia session connects automatically.

![Per-project gate](assets/kaimon_startup_project.gif)

![Global gate](assets/kaimon_startup_global.gif)

See [Getting Started](getting-started.md) for the full onboarding walkthrough.

---

## 7 — Advanced

The Advanced tab provides stress testing and load diagnostics. It lets you fire configurable bursts of concurrent tool calls against the running server to measure throughput and latency under load.

Use this tab to verify that the server handles parallel requests correctly when multiple agents or sessions are active simultaneously.

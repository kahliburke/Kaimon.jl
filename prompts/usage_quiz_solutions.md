# Kaimon Usage Quiz — Solutions

Self-grade: award partial credit for capturing the key ideas. **Total 100; pass ≥75.** If
you score below 75, review `usage_instructions` and retake.

---

## Q1: Shared REPL model (10)

You and the user drive ONE live Julia REPL in real time — your `ex()` code and its output
appear in their session immediately, as if they typed it. **Implication:** `println`/`print`
to stdout is STRIPPED from what you get back (and the user already sees the run), so never
use `println` to communicate or to surface a value. Explain what you're doing in TEXT
responses (outside tool calls), and return a final expression with `q=false` to see a value.

- 10: shared REPL + println stripped + use TEXT / return-value
- 6: shared REPL only, missed println stripping
- 0: didn't get the shared model

---

## Q2: When to use `q=false` (10 — 2 each)

a) `q=true` (import) · b) `q=true` (assignment) · c) `q=false` (you need the value to judge
the bug) · d) `q=true` (definition) · e) `q=false` (you need to read the signatures).
**Key:** `q=false` only when you need the return value to make a decision.

---

## Q3: Critique this code (10)

1. **println is stripped (4)** — all four `println`s produce nothing you'll see; narrate in
   TEXT instead.
2. **Needless `q=false` (3)** — wastes tokens returning values you don't need (imports,
   assignments). Default `q=true`; use `q=false` only for `m` *if* you inspect it.
3. **No batching (3)** — collapse into one call:
   `ex(e="include(\"MyModule.jl\"); using .MyModule; data=[1,2,3,4,5]; m=mean(data)")`, then
   `ex(e="m", q=false)` only if you need to see `m`.

---

## Q4: Sessions & routing (12 — 3 each)

a) A separate Julia REPL process (a connected gate) with its own state, packages, and
   project, identified by an 8-char key.
b) `ping()` (or `resources/list`) lists the connected sessions with their keys and projects.
c) Pass `ses="<key>"` to route a call to a specific session; use it whenever more than one
   session is connected.
d) You get an **error** asking which session to use — it won't guess. This matters for
   **safety**: the user often runs MANY sessions for different projects at once, so a blind
   default could execute your code in the WRONG project. Confirm your session before you
   mutate state.

---

## Q5: Pick the right tool (10)

a) `search_methods("push!")` (1.5) · b) `run_tests()` — proper test subprocess, streamed
output (1.5) · c) `type_info("DataFrame")` — fields, hierarchy, type params (1.5) ·
d) `search_code(query="WebSocket connection handling")` — finds by meaning (1.5) ·
e) `grep_code(pattern="_eval_with_capture")` — every exact call site WITH its enclosing
function (2) · f) **`mt=true`** — GLMakie/GLFW/OpenGL must run on thread 1; without it the
async eval lands on a default-pool thread and throws `ThreadAssertionError` (2).
Each beats raw `ex` (formatted, robust, purpose-built).

---

## Q6: Eval tracking (6 — 3 each)

a) Immediately, **before** execution begins — delivered as `{"eval_id":"XXXXXXXX"}` in the
   first progress notification's params (and again in the final result), so you have it even
   if the call times out.
b) `check_eval(eval_id="XXXXXXXX")` → status (running/completed/failed/timeout), elapsed
   time, and a result preview if available.

---

## Q7: Background jobs (12)

a) The eval is **auto-promoted to a background job**; `ex` returns the job id immediately and
   the work keeps running on the gate. (2)
b) `check_eval(eval_id="…")` → status, elapsed, last-activity timestamp, stashed values, and
   the full result once complete. (2)
c) Wait **≥30 s** before the first check, then every ~60 s+; don't rapid-poll (it won't
   finish faster). "Last activity" recent ⇒ active; stale (e.g. 120 s) ⇒ possibly stuck or
   in a long stash-less stretch → decide wait-vs-cancel. (2)
d) `Gate.stash(key, value)` (and `Gate.progress(msg)`), published via PUB/SUB and visible
   through `check_eval`. e.g. a training loop stashing `epoch`/`loss` each iteration. (3)
e) `cancel_eval(eval_id="…")` signals the gate; the running code must **cooperatively check**
   `Gate.is_cancelled()` in its loop and `break` — Julia can't force-interrupt threads. (2)
f) Jobs are **persisted to SQLite**; on restart Kaimon reconciles `running` jobs against
   gate-cached results; jobs older than 1 h with no session are marked `lost`. (1)

---

## Q8: Searching code (10 — 2 each)

a) `grep_code(pattern="_eval_with_capture")` — every occurrence WITH its enclosing function,
   exact and repo-scoped over the live tree; shell `grep`/`find` miss the enclosing symbol
   and aren't repo-scoped.
b) `search_code(query="where HTTP routing is handled")` — a short natural-language phrase;
   semantic-first, so describe the behaviour, don't guess the name.
c) **Not** the OR-bag disaster it once was — the lexical arm is floored on bag-of-words
   queries, so it won't flood you with keyword-coincidences. But a word-salad still embeds
   worse than a coherent phrase: **say what you want** — `search_code(query="apply power at
   the start of a turn")`. And if `atStartOfTurn`/`onApplyPower` are exact symbols you know,
   `grep_code(pattern="atStartOfTurn|onApplyPower")`.
d) **False.** `search_code`'s lexical half (local SQLite FTS) keeps working with Ollama/Qdrant
   down (`mode="lexical"`; hybrid degrades to lexical-only), and `grep_code` never needs
   embeddings at all (ripgrep over files). No shell grep needed even offline.
e) You **don't** have to leave the Kaimon tools: `grep_code(pattern=…, no_ignore=true)` also
   searches logs and generated/gitignored/hidden files. Shell `grep`/`sed`/`awk` is the right
   call only to **transform** matches (sed/awk) or **pipe** them into another command.

---

## Q9: Debugging (10)

a) Insert an **`@infiltrate`** breakpoint into the code and inspect interactively, instead of
   re-running with print statements and guessing. Revise usually picks the breakpoint up — no
   restart needed. (3)
b) `@infiltrate` **PAUSES** execution at the breakpoint for interactive inspection
   (collaborative — the user can explore too via the Debug tab); `@exfiltrate` does **NOT**
   pause — it captures variables to the Infiltrator safehouse for later. Use `@infiltrate`
   when you want to interact at that point; `@exfiltrate` to collect data and keep running. (3)
c) `debug_ctrl(action="status")` shows the file/line and all locals with types;
   `debug_eval(expression="…")` evaluates any expression in the breakpoint scope (e.g.
   `typeof(x)`, `length(data)`); `debug_ctrl(action="continue")` resumes. (2)
d) `debug_safehouse(action="inspect")` lists the captured vars;
   `debug_safehouse(action="inspect", expression="x + y")` evaluates with them;
   `debug_safehouse(action="clear")` cleans up. (2)

---

## Q10: Environment & staying out of trouble (10)

a) `pkg_add(packages=["Name"])` (not `Pkg.add()` directly). **NEVER** call `Pkg.activate()` —
   don't change the active project out from under the user. (2)
b) **Restart** the session: `manage_repl(command="restart")`. `struct`/`__init__`/module-level
   changes aren't safely hot-reloaded by Revise — a restart is lightweight (session key
   preserved, the gate reconnects) and faster than fighting world-age / stale state. (3)
c) **No.** The precompile cache is essentially never the cause — don't clear it. And assume
   the user restarts diligently, so don't blame Revise / stale code: find the real error
   (`UndefVarError`, wrong module qualification, a world-age error). (3)
d) Go through the **session** (`ex` / `run_tests`), not a `julia -e` subprocess — the
   subprocess loses the warm REPL state, the loaded packages, and Revise tracking, and the
   user can't see it. (2)

---

## Final Assessment

**Total: _____ / 100  ·  Pass ≥ 75**

- **90–100 — EXCELLENT:** ready to work efficiently.
- **75–89 — GOOD:** skim the areas you missed.
- **Below 75 — REVIEW:** study `usage_instructions` and retake.

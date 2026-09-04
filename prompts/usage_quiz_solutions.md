# Kaimon Usage Quiz — Solutions

Self-grade: award partial credit for capturing the key ideas. **Total 100; pass ≥75.** If you
score below 75, review `usage_instructions` and retake.

---

## Q1: Shared REPL & surfacing values (12)

a) You and the user drive ONE live Julia REPL — your `ex()` code and its output appear in
   their session immediately, as if they typed it. **Consequence:** `println`/`print` to
   stdout is **STRIPPED** from what you get back (and the user already saw the run), so never
   use `println` to communicate or to surface a value. Narrate in TEXT responses, and return a
   final expression with `q=false` when you need to see something. (5)
b) `using Statistics` → `q=true` (import, no value needed) · `data = [1,2,3]` → `q=true`
   (assignment) · `length(result)` → `q=false` (you need the value to judge the bug).
   **Key:** `q=false` only when the return value changes what you do next. (3)
c) Three faults: **(i)** every `println` is stripped, so none of that narration reaches you —
   put it in TEXT instead; **(ii)** `q=false` on imports and assignments wastes tokens
   returning values you don't need; **(iii)** no batching — three round trips for one
   sequence. Fix: one call,
   `ex(e="include(\"MyModule.jl\"); using .MyModule; data=[1,2,3,4,5]; m=mean(data)")`, then
   `ex(e="m", q=false)` only if you actually need to see `m`. (4)

---

## Q2: Sessions & routing (10)

a) A separate Julia REPL process (a connected gate) with its own state, packages, and project,
   identified by an 8-char key. `ping()` lists them with keys and projects. (4)
b) You get an **error** asking which session to use — it won't guess. That's a **safety**
   property, not a nicety: the user often runs many sessions for different projects at once, so
   a blind default could execute your code in the WRONG project. Confirm the session before
   mutating state. (3)
c) **Don't wait — start it yourself:** `start_session(project_path="/abs/path")` spawns a REPL
   and hands back its key (`start_session()` with no args lists the allowed projects). This is
   the normal way to get a session, not something to ask the user for. (3)

---

## Q3: Picking the right tool (10)

a) `search_methods("push!")` — every signature and overload, formatted. (2)
b) `type_info("DataFrame")` — fields, hierarchy, type parameters. (2)
c) `run_tests()` — a proper test subprocess with the right environment, streamed results, and
   it backgrounds a slow suite rather than blocking. (3)
d) **`mt=true`** — GLMakie/GLFW/OpenGL must run on thread 1; without it the eval lands on a
   default-pool thread and throws `ThreadAssertionError`. (3)

Each beats raw `ex`: purpose-built, formatted, and robust to the failure modes above.

---

## Q4: Searching code (14)

a) `grep_code(pattern="_eval_with_capture")` — every occurrence WITH its enclosing function,
   exact and repo-scoped over the live tree. Shell `grep`/`find` miss the enclosing symbol and
   aren't repo-scoped or `.gitignore`-aware. (3)
b) **Don't guess-and-grep — that's the trap.** `grep_code` matches only the literal text you
   type, so it is structurally blind to synonyms, indirection, and the code you didn't know to
   name; a wrong guess returns nothing and you can't distinguish "not here" from "I guessed
   wrong." Describe it instead: `search_code(query="where HTTP routing is handled")` —
   semantic-ranked, surfaces the real code whatever it's called. Default to `search_code` when
   exploring; drop to `grep_code` once you hold a real name. (4)
c) **No** — `search_code(mode="lexical")` still works with embeddings down, and `grep_code`
   never needed them. Shell `grep`/`sed`/`awk` is right only when you must **transform** matches
   or pipe them onward; for reading gitignored/generated text use
   `grep_code(..., no_ignore=true)`. (3)
d) **Globs are anchored to the PROJECT ROOT**, not to `path=` — so `path="src"` +
   `glob=["src/worker.jl"]` double-anchors to `src/src/worker.jl` and matches nothing. Write
   `glob=["src/worker.jl"]` alone, or a bare basename `glob=["worker.jl"]` (no `/`), which
   matches at any depth. (4)

---

## Q5: Changing code across files (12)

a) `edit_code(pattern="old_name", replacement="new_name", path="src", word=true)` — the write
   side of `grep_code`, same scoping arguments. `word=true` stops the pattern matching inside
   longer identifiers, so `old_name_helper` and `my_old_name` survive; without it the rename
   quietly corrupts every symbol that merely contains the text. (3)
b) Any three of: **(i)** nothing validates the result, so a bad substitution leaves files that
   no longer parse and you find out later; **(ii)** a failure partway through leaves a
   **half-applied** edit; **(iii)** the transcript shows the *script*, not the change, so
   nobody can review it without a separate `git diff`; **(iv)** it needs fresh authorization
   every time, because "run arbitrary code" isn't a contract anyone can pre-approve;
   **(v)** it's an extra round trip plus a separate verification step. (3)
c) **Nothing is written at all** — all twelve stay byte-identical, including the eleven that
   were fine, and you get the parse error for the one that failed. That's the design: a
   partially applied bulk edit is the worst available outcome, because the tree is in a state
   nobody intended and nobody knows which files moved. Aborting whole leaves exactly one thing
   to do — fix the pattern and re-run. (3)
d) **`edit_code` does not** — it edits text, so it matches inside strings, comments, and
   docstrings as happily as in code. **`rename_symbol(old_name=…, new_name=…)` does**: it
   matches on JuliaSyntax's **token stream**, so the lexer separates an Identifier from a
   Comment or a String for you — and an interpolated `$old_name` inside a string is still
   renamed, because that one *is* a real reference. What it still gets wrong: it is **not
   scope-aware**, so an unrelated local of the same name elsewhere is renamed too. So: use
   `rename_symbol` for an identifier rename, `edit_code` for anything else, and in both cases
   scope with `path`/`glob` and read the returned diff. (3)

---

## Q6: Long-running evals (14)

a) The eval is **auto-promoted to a background job**: `ex` returns the eval id immediately and
   the work continues on the gate. Check it with `check_eval(eval_id="…")` → status, elapsed,
   last activity, stashed values, and the result once complete. (4)
b) Wait **≥30 s** before the first check, then ~60 s apart — rapid polling won't make it
   finish sooner. Recent "last activity" ⇒ alive; stale ⇒ possibly stuck or in a long
   stash-less stretch, so decide wait-vs-cancel. (3)
c) `cancel_eval(eval_id="…")` sets a flag; the running code must **cooperatively** check
   `KaimonGate.is_cancelled()` and `break`. Julia can't force-interrupt a thread, so a loop
   that never checks **cannot be cancelled**. (3)
d) The canonical cooperative loop: (4)

```julia
ex(e="""
results = []
for i in 1:10
    KaimonGate.is_cancelled() && break      # honor cancel_eval — REQUIRED, or it can't be stopped
    push!(results, heavy_step(i))
    KaimonGate.stash(:completed, i)         # inspectable mid-run via check_eval
    KaimonGate.progress("chunk \$i/10 done") # streamed status line
end
results                                      # final expression = the job's returned value
""")
```

Full credit needs all three: the `is_cancelled()` break, a `progress`/`stash` update, and
returning the value as a final expression (not `println`). The `KaimonGate.` qualifier
matters — these are `public` but not exported, so bare `progress(…)` throws `UndefVarError`.

---

## Q7: Backgrounded test runs — and not sleeping (12)

a) **Go do other work** — the next task, a related edit, reading the code you were about to
   change. Anything except waiting. (3)
b) The number is irrelevant; the mistake is **waiting at all**. Sleeping turns a backgrounded
   run back into a blocking one, which is exactly what backgrounding exists to prevent — you
   pay the full wall-clock and gain nothing over collecting on demand. Sleeping *longer* than
   the run wastes the wait twice over. Rapid-polling is the same error in smaller pieces. (4)
c) When the answer actually gates you — in practice **before committing**, or when a decision
   genuinely depends on it. Until then assume it passes (it usually does) and keep moving;
   `check_tests(run_id=…)` reports on demand. (3)
d) **Say so and return.** Report that the run is in flight and hand the turn back — the user
   can see it's running and would rather have control than watch you burn wall-clock in a
   `sleep`. (2)

---

## Q8: Debugging & staying out of trouble (16)

a) Don't re-run and guess — insert a breakpoint. `@infiltrate` **PAUSES** at the breakpoint
   for interactive inspection (collaborative: the user can explore too via the Debug tab);
   `@exfiltrate` does **not** pause — it captures variables to the safehouse for later, via
   `debug_safehouse(action="inspect")`. Use the first to interact, the second to collect data
   and keep running. (4)
b) `debug_ctrl(action="status")` for file/line and locals; `debug_eval(expression="…")` to
   evaluate in the breakpoint scope; `debug_ctrl(action="continue")` to resume. (3)
c) `pkg_add(packages=["Name"])`, not `Pkg.add()` directly. **NEVER** call `Pkg.activate()` —
   don't change the active project out from under the user. (3)
d) **Restart** the session: `manage_repl(command="restart")`. `struct`/`__init__`/module-level
   changes aren't safely hot-reloaded; a restart is lightweight (session key preserved, gate
   reconnects) and faster than fighting world-age or stale state. (3)
e) **No.** The precompile cache is essentially never the cause — don't clear it. And assume the
   user restarts diligently, so don't blame Revise or stale code: find the real error
   (`UndefVarError`, wrong module qualification, a world-age error). (3)

---

## Final Assessment

**Total: _____ / 100  ·  Pass ≥ 75**

- **90–100 — EXCELLENT:** ready to work efficiently.
- **75–89 — GOOD:** skim the areas you missed.
- **Below 75 — REVIEW:** study `usage_instructions` and retake.

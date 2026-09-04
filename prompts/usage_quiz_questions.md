# Kaimon Usage Quiz

A primer on working effectively with Kaimon: the shared REPL, sessions, the purpose-built
tools (search, editing, introspection, testing, debugging), background work, and the habits
that keep you out of trouble. Answer each question, then call `usage_quiz(show_sols=true)` to
check your answers and self-grade. **Aim for ≥75/100.**

---

## Question 1: Shared REPL & surfacing values (12 points)

a) You and the user drive one live REPL. What's the single most important consequence for how
   you communicate and how you surface a value?
b) `q=true` is the default. For each, pick `q=true` or `q=false` and say why:
   `ex(e="using Statistics")` · `ex(e="data = [1,2,3]")` · `ex(e="length(result)")` (checking a bug)
c) Critique this, and give the fix:

```julia
ex(e="println('Loading...'); include('MyModule.jl')", q=false)
ex(e="println('Data...'); data = [1,2,3,4,5]", q=false)
ex(e="println('Mean: ', mean(data))", q=false)
```

---

## Question 2: Sessions & routing (10 points)

a) What is a "session", and how do you list the connected ones?
b) What happens if you omit `ses=` while several are connected — and why does that matter for
   *safety* rather than just convenience?
c) You need a project that ISN'T connected. Do you wait for the user? What do you do?

---

## Question 3: Picking the right tool (10 points)

Which tool beats raw `ex` for each, and why?

a) See every method of `push!`
b) Inspect the fields and hierarchy of a `DataFrame`
c) Run the project's test suite
d) Run `using GLMakie; scatter([1,2,3],[4,5,6])` — which `ex` parameter is essential, and why?

---

## Question 4: Searching code (14 points)

Two tools: **`search_code`** finds by MEANING (semantic-first — describe the behaviour) and is
the DEFAULT for exploring; **`grep_code`** finds an EXACT pattern once you hold a real token.

a) Find every call site of the exact function `_eval_with_capture`. Which tool, and why not
   shell `grep`/`find`?
b) You're mapping an unfamiliar subsystem — "where HTTP routing is handled" — and know none of
   the names. You *could* guess a plausible name and `grep_code` it. Why is that the trap
   (what does grep structurally miss), and what do you do instead?
c) Ollama (embeddings) is down. Should you fall back to shell `grep`? When *is* shell
   `grep`/`sed`/`awk` actually the right call?
d) `grep_code(pattern="memo", path="src", glob=["src/worker.jl"])` finds nothing, though
   `src/worker.jl` plainly contains `memo`. What's wrong — what is a glob anchored to?

---

## Question 5: Changing code across files (12 points)

You need to rename `old_name` to `new_name` everywhere under `src/`.

a) Which tool, with what arguments? Why is `word=true` worth setting?
b) You could write a `python3 -c` or `sed` one-liner instead. Give **three** concrete things
   that loses — actual properties of the outcome, not "it isn't Julia".
c) One of twelve files would fail to parse after the substitution. What happens to the other
   eleven, and why is that the design rather than a limitation?
d) The rename also hits `"old_name"` inside a log string and a mention in a docstring. Does
   the tool know the difference? What does that imply for how you scope it?

---

## Question 6: Long-running evals (14 points)

a) What happens automatically when an `ex()` runs past ~30 s, and how do you check on it?
b) How often should you poll, and what does "last activity" tell you?
c) How does cancellation work — what must the running code do for it to be possible?
d) **Write it.** Give the actual `ex(...)` call for a loop over 10 heavy chunks that
   (i) streams progress, (ii) checks for cancellation and bails cleanly, and (iii) returns the
   collected result. Show the Julia code.

---

## Question 7: Backgrounded test runs — and not sleeping (12 points)

You call `run_tests(pattern="parser")` and get
`🧪 Backgrounded as run 4 — "parser", ~3m. check_tests(run_id=4) to collect.`

a) What do you do in the next ten seconds? Be specific.
b) A colleague suggests `sleep 200` in Bash so the suite is definitely done before you check.
   Give the reason this is wrong that has nothing to do with the number 200.
c) When is the right moment to actually collect the result?
d) There is genuinely nothing else to work on until it finishes. What do you do?

---

## Question 8: Debugging & staying out of trouble (16 points)

a) A test fails and the output doesn't say why. What's the recommended approach instead of
   re-running and guessing — and what's the difference between `@infiltrate` and `@exfiltrate`?
b) At an `@infiltrate` breakpoint: how do you see the locals, evaluate an expression in that
   scope, and resume?
c) Add a package to the session's project — which tool, and what must you NEVER do to the
   environment?
d) After changing a `struct` or `__init__`, the session acts as if the old code is loaded.
   What do you do?
e) You suspect the precompile cache is corrupt, or that Revise missed your edit. Are these
   likely the cause?

---

## Scoring

**Total: 100. Pass: ≥75.**

- **90–100** — excellent; ready to work efficiently.
- **75–89** — good; skim the areas you missed.
- **Below 75** — review `usage_instructions` and retake.

**Check your answers:** `usage_quiz(show_sols=true)`

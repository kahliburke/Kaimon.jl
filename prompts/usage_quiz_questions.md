# Kaimon Usage Quiz

A primer on working effectively with Kaimon: the shared REPL and `ex` tool, sessions, the
purpose-built tools (search, introspection, testing, debugging), background jobs, and the
behaviours that keep you productive and out of trouble. Answer each question, then call
`usage_quiz(show_sols=true)` to check your answers and self-grade. **Aim for ≥75/100.**

---

## Question 1: Shared REPL model (10 points)

You and the user share one live REPL. What does that mean concretely, and what is the
single most important implication for how you communicate and how you surface values?

---

## Question 2: When to use `q=false` (10 points)

`q=true` (the default) suppresses the return value; `q=false` returns it. Pick one for each
and say why:

a) `ex(e="using Statistics")`
b) `ex(e="data = [1, 2, 3, 4, 5]")`
c) `ex(e="length(result)")` — to check for a bug
d) `ex(e="function foo(x) x^2 end")`
e) `ex(e="methods(my_function)")` — to read the signatures

---

## Question 3: Critique this code (10 points)

Identify every problem and give the fix:

```julia
ex(e="println('Loading...'); include('MyModule.jl')", q=false)
ex(e="println('Data...'); data = [1,2,3,4,5]", q=false)
ex(e="println('Mean...'); m = mean(data)", q=false)
ex(e="println('Result: ', m)", q=false)
```

---

## Question 4: Sessions & routing (12 points)

a) What is a "session" in Kaimon?
b) How do you discover the connected sessions?
c) When and how do you use `ses=` on `ex` and other tools?
d) What happens if you omit `ses` while several sessions are connected — and why does this
   matter for *safety*?
e) You need to run code in a project that ISN'T in the connected list. Can you get a session
   for it yourself, or must you wait for the user — and how?

---

## Question 5: Pick the right tool (10 points)

Which Kaimon tool fits each task — and why does it beat raw `ex`?

a) See every method of `push!`
b) Run the project's test suite with a pass/fail summary
c) Inspect the fields and hierarchy of a `DataFrame`
d) Find code that handles WebSocket connections, by concept (you don't know the name)
e) Find every call site of the exact function `_eval_with_capture`
f) Run `using GLMakie; scatter([1,2,3],[4,5,6])` — which `ex` parameter is essential, and why?

---

## Question 6: Eval tracking (6 points)

a) When is the eval ID available — before, during, or after execution — and how is it delivered?
b) An `ex()` call timed out on your side. How do you find out whether it actually finished?

---

## Question 7: Background jobs (12 points)

a) What happens automatically when an `ex()` runs longer than ~30 s?
b) How do you check a promoted job, and what does it report?
c) How often should you poll, and how does "last activity" guide that?
d) How can long-running code report progress / intermediate values to you?
e) How does cancellation work — what must the running code do?
f) What happens to background jobs across a Kaimon restart?
g) **Write it.** Give the actual `ex(...)` call for a long task — a loop over 10 heavy chunks
   — that (i) streams a progress update each iteration, (ii) checks for cancellation and bails
   cleanly, and (iii) returns the collected result. Show the Julia code.

---

## Question 8: Searching code (10 points)

Kaimon has TWO search tools: **`search_code`** finds by MEANING (semantic-first — describe
what the code does), and **`grep_code`** finds an EXACT pattern/regex over the live tree,
returning each hit's enclosing function.

a) Find every call site of the exact function `_eval_with_capture`. Which tool, and why not shell `grep`/`find`?
b) You want "where HTTP routing is handled" but don't know the function name. Which tool, and what query?
c) Is a long bag of keywords (`"transform power parse method body atStartOfTurn actions"`) a problem under semantic-first search? What's better?
d) Ollama (embeddings) is down. Should you fall back to shell `grep`? Explain.
e) You need to search a `.log` file or other generated/gitignored text. Do you have to leave the Kaimon tools? When is shell `grep`/`sed`/`awk` actually the right call?

---

## Question 9: Debugging (10 points)

a) A test fails and the output doesn't tell you why. What's the recommended approach
   instead of re-running and guessing — and which macro?
b) What's the difference between `@infiltrate` and `@exfiltrate`, and when do you use each?
c) At an `@infiltrate` breakpoint, how do you see the locals, evaluate an expression in that
   scope, and then resume?
d) You used `@exfiltrate` to capture values without pausing. How do you inspect them afterward?

---

## Question 10: Environment & staying out of trouble (10 points)

a) Add a package to the session's project — which tool, and what must you NEVER do to the environment?
b) After changing a `struct` or `__init__`, the session behaves as if the old code is loaded. What do you do?
c) You suspect the precompile cache is corrupt, or that Revise didn't pick up your edit. Are these likely the cause?
d) To run project code or tests, should you `julia -e ...` in Bash or go through the session? Why?

---

## Scoring

**Total: 100. Pass: ≥75.**

- **90–100** — excellent; ready to work efficiently.
- **75–89** — good; skim the areas you missed.
- **Below 75** — review `usage_instructions` and retake.

**Check your answers:** `usage_quiz(show_sols=true)`

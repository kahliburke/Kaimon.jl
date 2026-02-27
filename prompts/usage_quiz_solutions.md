# Kaimon Usage Quiz - Solutions

## Self-Grading Instructions

1. Compare your answers with solutions below
2. Award points based on key concepts captured (partial credit allowed)
3. Calculate total score out of 100
4. If below 75, review `usage_instructions` and retake

---

## Question 1: Shared REPL Model (15 points)

**Answer:** User and agent work in the same REPL in real-time. Everything you execute appears in their REPL immediately with the same output.

**Key implication:** DO NOT use `println` to communicate — it's stripped. User already sees your code execute. Use TEXT responses (outside tool calls) to explain what you're doing.

**Grading:**
- 15: Explained shared REPL + println stripped + use TEXT responses
- 10: Shared REPL mentioned, missed println stripping
- 5: Vague understanding
- 0: Didn't understand shared model

---

## Question 2: When to Use `q=false` (25 points)

**Answers:**
- a) `q=true` — no return value needed (import)
- b) `q=true` — don't need to see the array (assignment)
- c) `q=false` — NEED value to decide (is it the right length?)
- d) `q=true` — don't need to see function object (definition)
- e) `q=false` — need to analyze method signatures

**Key:** Only `q=false` when you need the return value for decision-making.

**Grading:** 5 points each (correct answer + reasoning)

---

## Question 3: Critique This Code (25 points)

**Problems:**

1. **println is stripped (10 pts)** — All println calls to stdout are removed. Use TEXT responses instead.

2. **Unnecessary q=false (10 pts)** — Wastes tokens. Use `q=true` (default) for assignments/imports.

3. **No batching (5 pts)** — Four separate calls could be combined into one or two.

**Corrected:**
```julia
# TEXT: "Let me load the module and compute the mean:"
ex(e="include('MyModule.jl'); using .MyModule; data = [1,2,3,4,5]; m = mean(data)")
ex(e="m", q=false)  # Only if you need to inspect the value
```

**Grading:**
- 25: All three problems identified with corrections
- 20: println + q=false issues found
- 15: Only println issue found
- 10: Vague awareness something's wrong
- 0: Thought code was fine

---

## Question 4: Multi-Session Concept (20 points)

**Answers:**

a) A session is a separate Julia REPL process connected via ZMQ gate. Each has its own state, packages, and project. (5 pts)

b) Use `ping()` to list connected sessions, or check `resources/list` which shows available sessions with their keys. (5 pts)

c) Pass `ses="<8-char-key>"` to route a tool call to a specific session. Required when multiple sessions are connected. (5 pts)

d) Error — the tool returns an error asking you to specify which session to use. (5 pts)

**Grading:** 5 points per sub-question

---

## Question 5: Tool Selection (15 points)

**Answers:**

a) `search_methods("push!")` — Purpose-built for method discovery. Better than `ex(e="methods(push!)", q=false)` because it formats output and handles edge cases. (~4 pts)

b) `run_tests()` — Spawns a proper test subprocess with streaming output. Better than `ex` with `@test` for full test suites. (~4 pts)

c) `type_info("DataFrame")` — Shows fields, hierarchy, and type parameters. Better than `ex(e="fieldnames(DataFrame)", q=false)` for complete picture. (~4 pts)

d) `qdrant_search_code(query="WebSocket connection handling")` — Semantic search finds relevant code by meaning. (~3 pts)

**Grading:** ~4 points each, partial credit for reasonable alternatives with explanation

---

## Final Assessment

**Total:** _____ / 100

- **90-100 — EXCELLENT:** Ready to work efficiently
- **75-89 — GOOD:** Review missed areas before starting
- **60-74 — REVIEW NEEDED:** Review `usage_instructions` and retake
- **Below 60 — NEEDS STUDY:** Must score 75+ before working with users

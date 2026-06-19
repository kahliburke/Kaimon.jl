# Kaimon Usage Quiz

Test your understanding of the `ex` tool and shared REPL environment. Answer each question, then call `usage_quiz(show_sols=true)` to check answers and grade yourself.

---

## Question 1: Shared REPL Model (15 points)

What does it mean that the user and agent work in a shared REPL, and what's the most important implication for communication?

---

## Question 2: When to Use `q=false` (25 points)

Should you use `q=true` or `q=false` for each? Explain why.

a) `ex(e="using Statistics")`
b) `ex(e="test_data = [1, 2, 3, 4, 5]")`
c) `ex(e="length(result)")` - to check if there's a bug
d) `ex(e="function foo(x) return x^2 end")`
e) `ex(e="methods(my_function)")` - to analyze signatures

---

## Question 3: Critique This Code (20 points)

Identify ALL problems and explain what should be done instead:

```julia
ex(e="println('Loading module...'); include('MyModule.jl')", q=false)
ex(e="println('Creating test data...'); data = [1,2,3,4,5]", q=false)
ex(e="println('Computing mean...'); m = mean(data)", q=false)
ex(e="println('Result is: ', m)", q=false)
```

---

## Question 4: Multi-Session Concept (20 points)

a) What is a "session" in Kaimon?
b) How do you discover available sessions?
c) When and how do you use the `ses` parameter on `ex` and other tools?
d) What happens if you call `ex` without `ses` when multiple sessions are connected?

---

## Question 5: Tool Selection (15 points)

For each task, which tool should you use and why?

a) You want to see all methods of `push!`
b) You want to run the project's test suite and see pass/fail summary
c) You want to check what fields a `DataFrame` has
d) You want to find code that handles WebSocket connections (by concept)
e) You need to run `using GLMakie; scatter([1,2,3], [4,5,6])` — what `ex` parameter is critical and why?

---

## Question 6: Eval Tracking (10 points)

a) When does the eval ID become available — before, during, or after the evaluation executes? How is it delivered?
b) If a long-running `ex()` call times out on the client side, how can you check if it completed?

---

## Question 7: Background Jobs (15 points)

a) What happens automatically when an `ex()` call takes longer than 30 seconds?
b) How do you check on a promoted job's progress? What information is available?
c) How often should you poll check_eval, and how does "last activity" help you decide?
d) How can running code report intermediate values to the agent? Give an example.
e) How does cooperative cancellation work? What must the running code do?
f) What happens to background jobs if the Kaimon TUI is restarted?

---

## Question 8: Code Search vs grep (15 points)

`search_code` is hybrid: it combines semantic (meaning-based) vector search with exact keyword/identifier matching, fused and ranked together. Use `format="structured"` for a JSON hit array instead of the ranked text.

a) You need to find every place the exact function `_eval_with_capture` is called. Which tool and `mode`, and why should you NOT reach for `grep`/`find`/Bash?
b) You're new to a codebase and want "where HTTP routing is handled." Which tool and what kind of query?
c) True or false: if Ollama (embeddings) is down, you should fall back to `grep` for code search. Explain.
d) When, if ever, is `grep`/Bash the right tool over `search_code`?

---

## Grading Scale

- **100-130**: Excellent! Ready to use Kaimon effectively.
- **90-99**: Good. Review missed areas before starting.
- **78-89**: Review `usage_instructions` and retake.
- **Below 78**: Study `usage_instructions` carefully and retake.

**Check answers:** `usage_quiz(show_sols=true)`

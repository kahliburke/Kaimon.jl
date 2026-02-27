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

## Question 3: Critique This Code (25 points)

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
d) You want to find code that handles WebSocket connections

---

## Grading Scale

- **90-100**: Excellent! Ready to use Kaimon effectively.
- **75-89**: Good. Review missed areas before starting.
- **60-74**: Review `usage_instructions` and retake.
- **Below 60**: Study `usage_instructions` carefully and retake.

**Check answers:** `usage_quiz(show_sols=true)`

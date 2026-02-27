# ── Test Output Parser ────────────────────────────────────────────────────────
# Incremental line-by-line state machine for parsing Julia Test.jl and ReTest
# output into structured results. Used by the test runner subprocess reader.

using Dates

# ── Data Structures ──────────────────────────────────────────────────────────

@enum TestStatus TEST_PASS TEST_FAIL TEST_ERROR TEST_BROKEN TEST_SKIP

mutable struct TestResult
    name::String
    status::TestStatus
    pass_count::Int
    fail_count::Int
    error_count::Int
    total_count::Int
    depth::Int   # nesting level in testset hierarchy
end

mutable struct TestFailure
    file::String
    line::Int
    expression::String
    evaluated::String    # "Evaluated: 1 == 2"
    testset::String
    backtrace::String    # captured stack trace lines
end

@enum TestRunStatus RUN_RUNNING RUN_PASSED RUN_FAILED RUN_ERROR RUN_CANCELLED

mutable struct TestRun
    id::Int
    project_path::String
    started_at::DateTime
    finished_at::Union{DateTime,Nothing}
    status::TestRunStatus
    pattern::String
    results::Vector{TestResult}
    failures::Vector{TestFailure}
    raw_output::Vector{String}    # all stdout lines
    total_pass::Int
    total_fail::Int
    total_error::Int
    total_tests::Int
    pid::Int                      # test subprocess PID
    process::Union{Base.Process,Nothing}
end

function TestRun(; id::Int = 0, project_path::String = "", pattern::String = "")
    return TestRun(
        id,
        project_path,
        now(),
        nothing,
        RUN_RUNNING,
        pattern,
        TestResult[],
        TestFailure[],
        String[],
        0,
        0,
        0,
        0,
        0,
        nothing,
    )
end

# ── Parser State ─────────────────────────────────────────────────────────────
# The parser accumulates multi-line failure blocks before emitting a TestFailure.

mutable struct _ParserState
    in_failure_block::Bool
    failure_file::String
    failure_line::Int
    failure_expression::String
    failure_evaluated::String
    failure_testset::String
    failure_backtrace_lines::Vector{String}
    in_summary::Bool          # inside "Test Summary:" table
    summary_header::String    # header row of summary table
    current_testset::String   # last seen testset name for context
    has_testset_done::Bool    # true if we've seen TESTSET_DONE lines (skip summary parsing)
end

_ParserState() = _ParserState(false, "", 0, "", "", "", String[], false, "", "", false)

# Global parser state per TestRun (keyed by run id)
const _PARSER_STATES = Dict{Int,_ParserState}()

"""
    parse_test_line!(run::TestRun, line::String) -> Bool

Parse a single line of test output and update the TestRun accordingly.
Returns `true` if the line was meaningful (failure, summary, etc.), `false` otherwise.

Never throws — parsing errors are silently ignored and raw output is always captured.
"""
# Strip ANSI escape codes from a string
const _ANSI_RE_PARSER =
    r"\e(?:\[[?=>!]?[0-9;:]*[A-Za-z@~]|\][^\x07]*\x07|\([A-Za-z0-9]|[A-Za-z0-9=<>])"
_strip_ansi(s::String) = replace(s, _ANSI_RE_PARSER => "")

function parse_test_line!(run::TestRun, line::String)::Bool
    # Always capture raw output regardless of parse success
    push!(run.raw_output, line)

    try
        # Strip ANSI color codes before parsing (Pkg.test output may contain them)
        clean_line = _strip_ansi(line)
        return _parse_test_line_inner!(run, clean_line)
    catch
        # Parsing error — silently ignore. The raw output is already captured
        # and the agent will get it if structured parsing fails entirely.
        return false
    end
end

"""Inner parse logic, separated so parse_test_line! can catch errors."""
function _parse_test_line_inner!(run::TestRun, line::String)::Bool
    state = get!(_PARSER_STATES, run.id) do
        _ParserState()
    end

    # ── Structured status lines from our runner script ───────────────────
    if startswith(line, "TEST_RUNNER:")
        state.in_summary = false
        return _parse_runner_line!(run, state, line)
    end

    # ── Failure block detection ──────────────────────────────────────────
    # Julia Test.jl failure format:
    #   Test Failed at /path/to/file.jl:123
    #     Expression: ...
    #     Evaluated: ...
    m_fail = match(r"Test Failed at (.+):(\d+)$", line)
    if m_fail !== nothing
        # Flush any previous failure block
        _flush_failure!(run, state)
        state.in_failure_block = true
        state.failure_file = m_fail.captures[1]
        state.failure_line = parse(Int, m_fail.captures[2])
        state.failure_expression = ""
        state.failure_evaluated = ""
        state.failure_testset = state.current_testset
        empty!(state.failure_backtrace_lines)
        return true
    end

    # Accumulate failure block lines
    if state.in_failure_block
        stripped = lstrip(line)
        if startswith(stripped, "Expression:")
            state.failure_expression = strip(stripped[length("Expression:")+1:end])
            return true
        elseif startswith(stripped, "Evaluated:")
            state.failure_evaluated = strip(stripped[length("Evaluated:")+1:end])
            return true
        elseif startswith(stripped, "Stacktrace:") || startswith(stripped, "[")
            push!(state.failure_backtrace_lines, line)
            return true
        elseif !isempty(state.failure_backtrace_lines) && (
            startswith(stripped, "@") || startswith(stripped, "[") || startswith(line, " ")
        )
            push!(state.failure_backtrace_lines, line)
            return true
        else
            # End of failure block
            _flush_failure!(run, state)
        end
    end

    # ── Error block detection ────────────────────────────────────────────
    # "Test threw exception" or "Error During Test at"
    m_err = match(r"Error During Test at (.+):(\d+)$", line)
    if m_err !== nothing
        _flush_failure!(run, state)
        state.in_failure_block = true
        state.failure_file = m_err.captures[1]
        state.failure_line = parse(Int, m_err.captures[2])
        state.failure_expression = "Error during test"
        state.failure_evaluated = ""
        state.failure_testset = state.current_testset
        empty!(state.failure_backtrace_lines)
        return true
    end

    # ── Test Summary table ───────────────────────────────────────────────
    if contains(line, "Test Summary:")
        _flush_failure!(run, state)
        state.in_summary = true
        # The "Test Summary:" line often contains the header columns after |
        # e.g. "Test Summary:  | Pass  Fail  Error  Total"
        if contains(line, "|")
            state.summary_header = line
        else
            state.summary_header = ""
        end
        return true
    end

    # ── ReTest summary header detection ──────────────────────────────────
    # ReTest prints a header line like "                            Pass  "
    # (column names only, no pipe, no "Test Summary:" prefix)
    # followed by "Module.Name:" and then indented rows with |
    if !state.in_summary
        retest_header = match(
            r"^\s+(Pass|Fail|Error|Broken|Total)(\s+(Pass|Fail|Error|Broken|Total))*\s*$",
            line,
        )
        if retest_header !== nothing
            _flush_failure!(run, state)
            state.in_summary = true
            # Build a synthetic header with | so our parser can map columns
            state.summary_header = "ReTest Summary | " * strip(line)
            return true
        end
    end

    if state.in_summary
        return _parse_summary_line!(run, state, line)
    end

    # ── Track current testset name ───────────────────────────────────────
    m_testset = match(r"^(\s*)Test set:\s*(.+)", line)
    if m_testset !== nothing
        state.current_testset = strip(m_testset.captures[2])
        return true
    end

    return false
end

"""Flush a pending failure block into run.failures."""
function _flush_failure!(run::TestRun, state::_ParserState)
    if state.in_failure_block &&
       (!isempty(state.failure_file) || !isempty(state.failure_expression))
        push!(
            run.failures,
            TestFailure(
                state.failure_file,
                state.failure_line,
                state.failure_expression,
                state.failure_evaluated,
                state.failure_testset,
                join(state.failure_backtrace_lines, "\n"),
            ),
        )
    end
    state.in_failure_block = false
    state.failure_file = ""
    state.failure_line = 0
    state.failure_expression = ""
    state.failure_evaluated = ""
    empty!(state.failure_backtrace_lines)
end

"""Parse structured lines from our runner script (TEST_RUNNER: prefix)."""
function _parse_runner_line!(run::TestRun, state::_ParserState, line::String)::Bool
    payload = strip(line[length("TEST_RUNNER:")+1:end])

    if startswith(payload, "START")
        run.status = RUN_RUNNING
        return true
    elseif startswith(payload, "TESTSET_DONE")
        state.has_testset_done = true
        kv = _parse_kv(payload)
        # name= is emitted last to allow spaces in testset names.
        # Extract everything after " name=" rather than using _parse_kv.
        name_idx = findfirst(" name=", payload)
        name = if name_idx !== nothing
            strip(payload[last(name_idx)+1:end])
        else
            get(kv, "name", "")
        end
        pass = tryparse(Int, get(kv, "pass", "0"))
        fail = tryparse(Int, get(kv, "fail", "0"))
        err = tryparse(Int, get(kv, "error", "0"))
        total = tryparse(Int, get(kv, "total", "0"))
        depth = tryparse(Int, get(kv, "depth", "0"))
        status = if (something(fail, 0) > 0 || something(err, 0) > 0)
            TEST_FAIL
        else
            TEST_PASS
        end
        push!(
            run.results,
            TestResult(
                name,
                status,
                something(pass, 0),
                something(fail, 0),
                something(err, 0),
                something(total, 0),
                something(depth, 0),
            ),
        )
        # Accumulate totals only from depth-0 (root) results. Each depth-0
        # result already includes cumulative counts from its children, so we
        # never sum non-root results. With multiple depth-0 testsets (no wrapper
        # @testset), we += to capture all of them.
        if something(depth, 0) == 0
            run.total_pass += something(pass, 0)
            run.total_fail += something(fail, 0)
            run.total_error += something(err, 0)
            run.total_tests += something(total, 0)
        end
        return true
    elseif startswith(payload, "DONE")
        kv = _parse_kv(payload)
        status_str = get(kv, "status", "passed")
        run.status = if status_str == "passed"
            RUN_PASSED
        elseif status_str == "failed"
            RUN_FAILED
        else
            RUN_ERROR
        end
        run.finished_at = now()
        _flush_failure!(run, state)
        # Clean up parser state
        delete!(_PARSER_STATES, run.id)
        return true
    end
    return false
end

"""
Parse a Test Summary table line.

Test.jl format uses a single `|` to separate the testset name from the numbers:
```
Test Summary:       | Pass  Fail  Error  Total
  My Tests          |   10     2      1     13
    SubTest A       |    5     1      0      6
```

The numbers are space-aligned columns (not pipe-separated).
We parse the header to determine column name→position mapping, then extract
numbers from the data rows by matching column positions.
"""
function _parse_summary_line!(run::TestRun, state::_ParserState, line::String)::Bool
    stripped = strip(line)

    # If we already have structured TESTSET_DONE results, skip summary parsing
    # but still consume lines until end of summary block to avoid mis-parsing.
    if state.has_testset_done
        if isempty(stripped)
            state.in_summary = false
        end
        return true
    end

    # Detect header row (contains column names like "Pass", "Fail", etc.)
    if isempty(state.summary_header) && contains(line, "|")
        state.summary_header = line
        return true
    end

    # Empty or separator line ends summary
    if isempty(stripped) || all(c -> c in ('-', '=', ' ', '─', '━'), stripped)
        if isempty(stripped)
            state.in_summary = false
        end
        return true
    end

    # Parse data rows
    if contains(line, "|")
        pipe_pos = findfirst('|', line)
        pipe_pos === nothing && return false

        name_part = strip(line[1:pipe_pos-1])
        values_part = line[pipe_pos+1:end]

        # Calculate depth from leading whitespace in the name section
        leading = length(line[1:pipe_pos-1]) - length(lstrip(line[1:pipe_pos-1]))
        depth = div(leading, 2)  # normalize to levels

        # Extract all integers from the values section
        nums = Int[]
        for m in eachmatch(r"\d+", values_part)
            push!(nums, parse(Int, m.match))
        end

        pass = 0
        fail = 0
        err = 0
        broken = 0
        total = 0

        # Map numbers to columns using the header
        if !isempty(state.summary_header)
            hdr_pipe_pos = findfirst('|', state.summary_header)
            if hdr_pipe_pos !== nothing
                hdr_values = state.summary_header[hdr_pipe_pos+1:end]
                # Extract column names in order from header
                col_names = String[]
                for m in eachmatch(r"[A-Za-z]+", hdr_values)
                    push!(col_names, lowercase(m.match))
                end

                for (i, col_name) in enumerate(col_names)
                    i > length(nums) && break
                    if col_name in ("pass", "passed")
                        pass = nums[i]
                    elseif col_name in ("fail", "failed")
                        fail = nums[i]
                    elseif col_name in ("error", "errors")
                        err = nums[i]
                    elseif col_name == "broken"
                        broken = nums[i]
                    elseif col_name == "total"
                        total = nums[i]
                    end
                end
            end
        else
            # No header — try positional: Pass, Fail, Error, Total
            length(nums) >= 1 && (pass = nums[1])
            length(nums) >= 2 && (fail = nums[2])
            length(nums) >= 3 && (err = nums[3])
            length(nums) >= 4 && (total = nums[4])
        end

        if total == 0
            total = pass + fail + err + broken
        end

        status = (fail > 0 || err > 0) ? TEST_FAIL : TEST_PASS

        push!(run.results, TestResult(name_part, status, pass, fail, err, total, depth))

        # Update running totals from top-level results (depth 0)
        # Accumulate across multiple summary tables (Test.jl + ReTest)
        if depth == 0
            run.total_pass += pass
            run.total_fail += fail
            run.total_error += err
            run.total_tests += total
        end

        return true
    end

    # ReTest module header line: "Main.ModuleName:" (no pipe, ends with colon)
    if match(r"^[A-Za-z_][\w.]*:\s*$", stripped) !== nothing
        return true  # skip module header, stay in summary mode
    end

    # Non-pipe line while in summary — might be end of summary
    state.in_summary = false
    return false
end

"""Parse key=value pairs from a structured line."""
function _parse_kv(line::AbstractString)::Dict{String,String}
    d = Dict{String,String}()
    for m in eachmatch(r"(\w+)=(\S+)", line)
        d[m.captures[1]] = m.captures[2]
    end
    return d
end

"""
    format_test_summary(run::TestRun) -> String

Format a completed TestRun into a focused summary for the agent.
Only includes pass/fail counts and failure details — no raw output dump.
"""
function format_test_summary(run::TestRun)::String
    buf = IOBuffer()

    # Status line
    status_str = if run.status == RUN_PASSED
        "PASSED"
    elseif run.status == RUN_FAILED
        "FAILED"
    elseif run.status == RUN_ERROR
        "ERROR"
    elseif run.status == RUN_CANCELLED
        "CANCELLED"
    else
        "RUNNING"
    end

    project_name = basename(run.project_path)
    println(buf, "Test Results: $project_name — $status_str")
    println(buf, "="^60)

    # Counts
    duration = if run.finished_at !== nothing
        dt = Dates.value(run.finished_at - run.started_at) / 1000.0
        "$(round(dt, digits=1))s"
    else
        "running"
    end
    println(
        buf,
        "Pass: $(run.total_pass) | Fail: $(run.total_fail) | Error: $(run.total_error) | Total: $(run.total_tests) | Duration: $duration",
    )

    # Testset breakdown (if any)
    if !isempty(run.results)
        println(buf)
        println(buf, "Testsets:")
        for r in run.results
            indent = "  "^(r.depth + 1)
            marker = if r.fail_count > 0 || r.error_count > 0
                "X"
            else
                "."
            end
            counts = "$(r.pass_count) pass"
            r.fail_count > 0 && (counts *= ", $(r.fail_count) fail")
            r.error_count > 0 && (counts *= ", $(r.error_count) error")
            println(buf, "$indent[$marker] $(r.name): $counts")
        end
    end

    # Failure details
    if !isempty(run.failures)
        println(buf)
        println(buf, "Failures:")
        println(buf, "-"^60)
        for (i, f) in enumerate(run.failures)
            println(buf, "  $i) $(f.file):$(f.line)")
            !isempty(f.testset) && println(buf, "     Testset: $(f.testset)")
            !isempty(f.expression) && println(buf, "     Expression: $(f.expression)")
            !isempty(f.evaluated) && println(buf, "     Evaluated: $(f.evaluated)")
            if !isempty(f.backtrace)
                # Show first few lines of backtrace
                bt_lines = split(f.backtrace, "\n")
                for bt_line in first(bt_lines, 5)
                    println(buf, "     $bt_line")
                end
                if length(bt_lines) > 5
                    println(buf, "     ... ($(length(bt_lines) - 5) more lines)")
                end
            end
            println(buf)
        end
    end

    # If parsing yielded no structured results and no failures, fall back to
    # showing the tail of raw output so the agent always has something useful.
    if isempty(run.results) && isempty(run.failures) && !isempty(run.raw_output)
        println(buf)
        println(buf, "Raw output (last 50 lines):")
        println(buf, "-"^60)
        for line in last(run.raw_output, 50)
            println(buf, line)
        end
    end

    return String(take!(buf))
end

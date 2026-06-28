# ─────────────────────────────────────────────────────────────────────────────
# Kaimon · eval execution: capture display, output sanitize/truncate, execute_repllike  (relocated from Kaimon.jl; part of the Kaimon module)
# ─────────────────────────────────────────────────────────────────────────────

struct IOBufferDisplay <: AbstractDisplay
    io::IOBuffer
    IOBufferDisplay() = new(IOBuffer())
end
# Resolve ambiguities with Base.Multimedia
Base.displayable(::IOBufferDisplay, ::AbstractString) = true
Base.displayable(::IOBufferDisplay, ::MIME) = true
Base.displayable(::IOBufferDisplay, _) = true
Base.display(d::IOBufferDisplay, x) = show(d.io, MIME("text/plain"), x)
Base.display(d::IOBufferDisplay, mime::AbstractString, x) = show(d.io, MIME(mime), x)
Base.display(d::IOBufferDisplay, mime::MIME, x) = show(d.io, mime, x)
Base.display(d::IOBufferDisplay, mime, x) = show(d.io, mime, x)

"""
    _serialize_expr(expr) -> String

Serialize a (possibly-modified) AST back to valid Julia code.
`Base.parse_input_line` wraps multi-line code in `:toplevel`, and
`string(Expr(:toplevel, ...))` / `string(Expr(:using, ...))` etc. fall back
to `\$(Expr(...))` (the quoted representation), injecting literal `\$` that
corrupts the code. This function uses `show_unquoted` which renders
expressions as valid Julia source without quoting artifacts.
"""
function _serialize_expr(expr)
    if expr isa Expr && expr.head == :toplevel
        parts = String[]
        for arg in expr.args
            arg isa LineNumberNode && continue
            # Recursively handle nested :toplevel exprs (produced by
            # Base.parse_input_line for multi-statement code)
            if arg isa Expr && arg.head == :toplevel
                s = _serialize_expr(arg)
                !isempty(s) && push!(parts, s)
            else
                push!(parts, sprint(Base.show_unquoted, arg, 0, 0))
            end
        end
        return join(parts, "\n")
    else
        return sprint(Base.show_unquoted, expr, 0, 0)
    end
end

"""Match a `Revise.revise()` / `Main.Revise.revise()` call (by callee; args
ignored). The gate replays Revise's `revise_first` ast-transform before every
eval, so an explicit call is always a redundant no-op — we strip it from agent
code like `println`, so it never clutters the user's mirrored REPL."""
function _is_revise_revise_call(func)
    (func isa Expr && func.head == :. && length(func.args) >= 2) || return false
    (func.args[end] isa QuoteNode && func.args[end].value == :revise) || return false
    base = func.args[1]
    base === :Revise && return true
    return base isa Expr && base.head == :. && length(base.args) >= 2 &&
           base.args[end] isa QuoteNode && base.args[end].value == :Revise
end

"""
    remove_println_calls(expr, toplevel=true, strip_show=true, was_stripped=Ref(false))

Strip println, print, printstyled, @show, logging macros, and redundant
`Revise.revise()` calls from an AST expression.
When quiet mode is on, agents shouldn't use these to communicate since
the user already sees code execution in their REPL.

Logging macros (@error, @debug, @info, @warn) are only removed at the top level,
not inside function definitions or other nested code.

Returns the modified expression and sets was_stripped[] = true if any output functions were removed.
"""
function remove_println_calls(
    expr,
    toplevel::Bool = true,
    strip_show::Bool = true,
    was_stripped::Ref{Bool} = Ref(false),
)
    if expr isa Expr
        # Check if this is a print-related call
        if expr.head == :call
            func = expr.args[1]
            # Strip redundant Revise.revise() — the gate replays Revise's
            # `revise_first` ast-transform before every eval, so an explicit call
            # is always a no-op that only clutters the mirrored REPL.
            if _is_revise_revise_call(func)
                return nothing
            end
            # List of functions to remove (always, regardless of level)
            print_funcs = [:println, :print, :printstyled]
            # Check if this is a print call targeting stdout (no IO arg)
            # vs an IO-targeted call like println(io, ...) which should be kept
            func_name = if func in print_funcs
                func
            elseif (
                func isa Expr &&
                func.head == :. &&
                length(func.args) >= 2 &&
                func.args[end] isa QuoteNode &&
                func.args[end].value in print_funcs
            )
                func.args[end].value
            else
                nothing
            end
            if func_name !== nothing
                # Only strip stdout-targeted calls:
                # - println("msg"), print("a", "b"), printstyled("x", color=:red)
                # - Explicit stdout: println(stdout, "msg")
                # Keep IO-targeted calls: println(io, "msg"), print(buf, "data")
                #
                # Heuristic: IO-targeted iff first positional arg is a variable
                # (Symbol) that isn't stdout/stderr. This correctly handles keyword
                # args in printstyled and multi-arg print to stdout.
                pos_args = [
                    a for a in expr.args[2:end] if
                    !(a isa Expr && a.head in (:kw, :parameters))
                ]
                first_pos = length(pos_args) >= 1 ? pos_args[1] : nothing
                is_io_targeted =
                    length(pos_args) >= 2 &&
                    first_pos isa Symbol &&
                    first_pos ∉ (:stdout, :stderr)
                if !is_io_targeted
                    was_stripped[] = true
                    return nothing
                end
                # IO-targeted print call — keep it
            end
        elseif expr.head == :macrocall
            macro_name = expr.args[1]
            # Remove @show conditionally based on strip_show parameter
            if strip_show && macro_name == Symbol("@show")
                was_stripped[] = true
                return nothing
            end
            # Remove logging macros ONLY at top level
            if toplevel
                logging_macros =
                    [Symbol("@error"), Symbol("@debug"), Symbol("@info"), Symbol("@warn")]
                if macro_name in logging_macros
                    was_stripped[] = true
                    return nothing
                end
                # Also handle qualified logging macros
                if (
                    macro_name isa Expr &&
                    macro_name.head == :. &&
                    length(macro_name.args) >= 2 &&
                    macro_name.args[end] isa QuoteNode &&
                    macro_name.args[end].value in [:error, :debug, :info, :warn]
                )
                    was_stripped[] = true
                    return nothing
                end
            end
        end

        # Determine if we're entering a nested scope (not top level anymore)
        entering_nested = expr.head in [:function, :macro, :let, :do, :try, :->]

        # Recursively process all arguments, filtering out nothings
        new_args = []
        for arg in expr.args
            cleaned = remove_println_calls(
                arg,
                toplevel && !entering_nested,
                strip_show,
                was_stripped,
            )
            if cleaned !== nothing
                push!(new_args, cleaned)
            end
        end
        # If we have a block and removed some statements, rebuild it
        if expr.head == :block && length(new_args) != length(expr.args)
            return Expr(expr.head, new_args...)
        else
            return Expr(expr.head, new_args...)
        end
    end
    return expr
end

"""
    truncate_output(output::String, max_length::Int, value=nothing)

Intelligently truncate output if it exceeds max_length.
For collections, tries to provide type info and summary.
Otherwise, shows first 2/3 and last 1/3 with indicator.
"""
function truncate_output(output::String, max_length::Int, value = nothing)
    length(output) <= max_length && return output

    # Try intelligent summary for common collection types
    if value !== nothing
        try
            if value isa Union{AbstractArray,AbstractDict,Set,Tuple}
                summary_str = "Type: $(typeof(value))"
                if applicable(length, value)
                    summary_str *= ", Length: $(length(value))"
                elseif applicable(size, value)
                    summary_str *= ", Size: $(size(value))"
                end

                # If summary itself is short enough, use it with truncated display
                if length(summary_str) < max_length ÷ 2
                    # Still show some of the actual content
                    remaining = max_length - length(summary_str) - 200 # Leave room for message
                    if remaining > 100
                        keep_start = (remaining * 2) ÷ 3
                        keep_end = remaining ÷ 3
                        truncated = output[1:min(keep_start, length(output))]
                        if length(output) > keep_start + keep_end
                            truncated *= "\n... [~$(length(output) - keep_start - keep_end) chars omitted] ...\n"
                            end_start = max(1, length(output) - keep_end + 1)
                            truncated *= output[end_start:end]
                        end
                        return summary_str * "\n" * truncated
                    end
                end
            end
        catch
            # If anything fails, fall through to simple truncation
        end
    end

    # Simple truncation: show first 2/3 and last 1/3
    keep_start = (max_length * 2) ÷ 3
    keep_end = max_length ÷ 3
    omitted = length(output) - keep_start - keep_end

    result = output[1:keep_start]
    result *= "\n\n... [~$omitted chars omitted] ...\n\n"
    end_start = max(1, length(output) - keep_end + 1)
    result *= output[end_start:end]

    return result
end

function execute_repllike(
    str;
    silent::Bool = false,
    quiet::Bool = true,
    description::Union{String,Nothing} = nothing,
    show_prompt::Bool = true,
    max_output::Int = 6000,
    session::String = "",
)
    # Route through gate when running in TUI server mode.
    # This makes ALL tools that call execute_repllike gate-aware automatically.
    if GATE_MODE[] && GATE_CONN_MGR[] !== nothing
        return execute_via_gate(
            str;
            quiet = quiet,
            silent = silent,
            max_output = max_output,
            session = session,
        )
    end

    lock(EXEC_REPLLIKE_LOCK)
    try
        # Check for Pkg.activate usage
        if contains(str, "activate(") && !contains(str, r"#.*overwrite no-activate-rule")
            return """
                ERROR: Using Pkg.activate to change environments is not allowed.
                You should assume you are in the correct environment for your tasks.
                You may use Pkg.status() to see the current environment and available packages.
                If you need to use a third-party 'activate' function, add '# overwrite no-activate-rule' at the end of your command.
            """
        end

        # Check if we have an active REPL (interactive mode) or running in server mode
        # Note: `Base.active_repl` may exist but be `nothing` in non-interactive contexts.
        repl =
            (isdefined(Base, :active_repl) && (Base.active_repl !== nothing)) ?
            Base.active_repl : nothing
        backend =
            repl !== nothing && hasproperty(repl, :backendref) ? repl.backendref : nothing
        has_repl =
            repl !== nothing &&
            backend !== nothing &&
            hasproperty(backend, :repl_channel) &&
            hasproperty(backend, :response_channel) &&
            isopen(backend.repl_channel) &&
            isopen(backend.response_channel)

        # Track whether user explicitly wants to see the return value
        # In non-quiet mode, show return value unless they added a semicolon
        show_return_value = !quiet && !REPL.ends_with_semicolon(str)

        # Auto-append semicolon in quiet mode to suppress output
        if quiet && !REPL.ends_with_semicolon(str)
            str = str * ";"
        end

        expr = Base.parse_input_line(str)

        # Always strip println (it's never appropriate for agent communication)
        # Strip @show only in quiet mode; in verbose mode (q=false), @show is useful for debugging
        was_stripped = Ref(false)
        expr = remove_println_calls(expr, true, quiet, was_stripped)

        if has_repl && !silent
            REPL.prepare_next(repl)
        end

        # Only print the agent prompt if not silent and show_prompt is true
        if !silent && show_prompt
            printstyled("\nagent> ", color = :red, bold = :true)
            if description !== nothing
                println(description)
            else
                # Transform println calls to comments for display
                display_str = replace(str, r"println\s*\(\s*\"([^\"]*)\"\s*\)" => s"# \1")
                display_str = replace(display_str, r"@info\s+\"([^\"]*?)\"" => s"# \1")
                display_str =
                    replace(display_str, r"@warn\s+\"([^\"]*?)\"" => s"# WARNING: \1")
                display_str =
                    replace(display_str, r"@error\s+\"([^\"]*?)\"" => s"# ERROR: \1")
                # Split on semicolons for multi-line display
                display_str = replace(display_str, r";\s*" => "\n")
                # If multiline, start on new line for proper indentation
                if contains(display_str, '\n')
                    println()  # Start on new line
                    print(display_str, "\n")
                else
                    print(display_str, "\n")
                end
            end
        end

        # Evaluate the expression and capture stdout/stderr.
        # Important: in interactive REPL mode, evaluation happens on the REPL backend task.
        # Redirecting stdout/stderr in the current task won't reliably capture backend output.
        # So we run a function on the backend that performs the capture *within* the backend task.
        backend_iserr = false
        response = try
            if has_repl
                result = REPL.call_on_backend(
                    () -> begin
                        orig_stdout = stdout
                        orig_stderr = stderr

                        stdout_read, stdout_write = redirect_stdout()
                        stderr_read, stderr_write = redirect_stderr()

                        stdout_content = String[]
                        stderr_content = String[]

                        stdout_task = @async begin
                            try
                                while !eof(stdout_read)
                                    line = readline(stdout_read; keep = true)
                                    push!(stdout_content, line)
                                    if !silent
                                        write(orig_stdout, line)
                                        flush(orig_stdout)
                                    end
                                end
                            catch e
                                if !isa(e, EOFError)
                                    @debug "stdout read error" exception = e
                                end
                            end
                        end

                        stderr_task = @async begin
                            try
                                while !eof(stderr_read)
                                    line = readline(stderr_read; keep = true)
                                    push!(stderr_content, line)
                                    if !silent
                                        write(orig_stderr, line)
                                        flush(orig_stderr)
                                    end
                                end
                            catch e
                                if !isa(e, EOFError)
                                    @debug "stderr read error" exception = e
                                end
                            end
                        end

                        value = nothing
                        caught = nothing
                        bt = nothing
                        try
                            # Apply REPL ast_transforms (Revise, softscope, etc.).
                            # Guard on the field: some hosts expose a REPLBackendRef
                            # without `ast_transforms` (accessing it throws FieldError).
                            if isdefined(Base, :active_repl_backend) &&
                               Base.active_repl_backend !== nothing &&
                               hasproperty(Base.active_repl_backend, :ast_transforms)
                                for xf in Base.active_repl_backend.ast_transforms
                                    expr = Base.invokelatest(xf, expr)
                                end
                            end
                            value = Core.eval(Main, expr)
                        catch e
                            caught = e
                            bt = catch_backtrace()
                        finally
                            redirect_stdout(orig_stdout)
                            redirect_stderr(orig_stderr)

                            close(stdout_write)
                            close(stderr_write)

                            wait(stdout_task)
                            wait(stderr_task)

                            close(stdout_read)
                            close(stderr_read)
                        end

                        (
                            stdout = join(stdout_content),
                            stderr = join(stderr_content),
                            value = value,
                            exception = caught,
                            backtrace = bt,
                        )
                    end,
                    backend,
                )

                val, iserr = if result isa Pair
                    (result.first, result.second)
                elseif result isa Tuple && length(result) == 2
                    (result[1], result[2])
                else
                    (result, false)
                end

                backend_iserr = iserr
                val
            else
                # Server/non-interactive mode: capture in the current task.
                orig_stdout = stdout
                orig_stderr = stderr

                stdout_read, stdout_write = redirect_stdout()
                stderr_read, stderr_write = redirect_stderr()

                stdout_content = String[]
                stderr_content = String[]

                stdout_task = @async begin
                    try
                        while !eof(stdout_read)
                            line = readline(stdout_read; keep = true)
                            push!(stdout_content, line)
                            if !silent
                                write(orig_stdout, line)
                                flush(orig_stdout)
                            end
                        end
                    catch e
                        if !isa(e, EOFError)
                            @debug "stdout read error" exception = e
                        end
                    end
                end

                stderr_task = @async begin
                    try
                        while !eof(stderr_read)
                            line = readline(stderr_read; keep = true)
                            push!(stderr_content, line)
                            if !silent
                                write(orig_stderr, line)
                                flush(orig_stderr)
                            end
                        end
                    catch e
                        if !isa(e, EOFError)
                            @debug "stderr read error" exception = e
                        end
                    end
                end

                value = nothing
                caught = nothing
                bt = nothing
                try
                    # Apply REPL ast_transforms (Revise, softscope, etc.).
                    # Guard on the field: some hosts expose a REPLBackendRef
                    # without `ast_transforms` (accessing it throws FieldError).
                    if isdefined(Base, :active_repl_backend) &&
                       Base.active_repl_backend !== nothing &&
                       hasproperty(Base.active_repl_backend, :ast_transforms)
                        for xf in Base.active_repl_backend.ast_transforms
                            expr = xf(expr)
                        end
                    end
                    value = Core.eval(Main, expr)
                catch e
                    caught = e
                    bt = catch_backtrace()
                finally
                    redirect_stdout(orig_stdout)
                    redirect_stderr(orig_stderr)

                    close(stdout_write)
                    close(stderr_write)

                    wait(stdout_task)
                    wait(stderr_task)

                    close(stdout_read)
                    close(stderr_read)
                end

                (
                    stdout = join(stdout_content),
                    stderr = join(stderr_content),
                    value = value,
                    exception = caught,
                    backtrace = bt,
                )
            end
        catch e
            backend_iserr = true
            (exception = e, backtrace = catch_backtrace())
        end

        captured_content =
            if response isa NamedTuple &&
               haskey(response, :stdout) &&
               haskey(response, :stderr)
                String(response.stdout) * String(response.stderr)
            else
                ""
            end

        # Note: Output was already displayed in real-time by the async tasks
        # No need to print captured_content again unless silent mode

        # Format the result for display
        result_str = if response isa NamedTuple
            if haskey(response, :exception) && response.exception !== nothing
                io_buf = IOBuffer()
                try
                    showerror(io_buf, response.exception, response.backtrace)
                catch
                    # If Base's error hint machinery explodes due to a mock/partial REPL,
                    # still return the core exception message.
                    showerror(io_buf, response.exception)
                end
                "ERROR: " * String(take!(io_buf))
            elseif haskey(response, :value) && show_return_value
                io_buf = IOBuffer()
                show(io_buf, MIME("text/plain"), response.value)
                String(take!(io_buf))
            else
                ""
            end
        elseif response isa Exception
            io_buf = IOBuffer()
            showerror(io_buf, response)
            "ERROR: " * String(take!(io_buf))
        else
            ""
        end

        # Refresh REPL if not silent and we have a REPL
        if !silent && has_repl
            if !isempty(result_str)
                println(result_str)
            end
            REPL.prepare_next(repl)
            REPL.LineEdit.refresh_line(repl.mistate)
        end

        # In quiet mode, don't return captured stdout/stderr (println output)
        # EXCEPT for errors - always return errors to the agent.
        # REPL.eval_on_backend signals errors via an `iserr` flag instead of throwing.
        has_error =
            backend_iserr ||
            (
                response isa NamedTuple &&
                haskey(response, :exception) &&
                response.exception !== nothing
            ) ||
            response isa Exception

        result = if quiet && !has_error
            ""  # In quiet mode without errors, return empty string (suppresses "nothing")
        else
            # Return full output for non-quiet mode OR when there's an error
            captured_content * result_str
        end

        # Add reminder if output functions were stripped
        if was_stripped[]
            reminder = "\n\n⚠️  Note: println/print/logging calls were removed. Use q=false with a final expression to see values."
            result = result * reminder
        end

        # Apply truncation if output exceeds max_output
        original_length = length(result)
        if original_length > max_output
            # Get the value for intelligent truncation (if available)
            value_for_truncation = if response isa NamedTuple && haskey(response, :value)
                response.value
            else
                nothing
            end

            result = truncate_output(result, max_output, value_for_truncation)

            # Add educational message about truncation
            educational_msg = """


⚠️  Output truncated ($max_output of $original_length chars shown).

This usually means you should use a different approach:
- Check dimensions first: length(x), size(x), summary(x)
- Sample data: first(x, 10), x[1:100], rand(x, 5)
- Filter before display: filter(condition, x)
- Access specific fields: x.field or keys(x)

Use max_output parameter only if you truly need more output."""

            result = result * educational_msg
        end

        return result
    finally
        unlock(EXEC_REPLLIKE_LOCK)
    end
end

SERVER = Ref{Union{Nothing,MCPServer}}(nothing)
ALL_TOOLS = Ref{Union{Nothing,Vector{MCPTool}}}(nothing)

# Lock for thread-safe dynamic tool registration/unregistration

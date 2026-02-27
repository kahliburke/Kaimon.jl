
module Kaimon

using REPL
using JSON
using InteractiveUtils
using Profile
using HTTP
using Random
using SHA
using Dates
using Coverage
using ReTest
using Pkg
using Sockets
using TOML
using LoggingExtras
using Serialization
using Preferences
using ZMQ
using Printf
using UUIDs
using Tachikoma
using Match

export @mcp_tool, MCPTool
export start!, stop!, test_server

# ── Shared cache directory ────────────────────────────────────────────────────
# Single source of truth for ~/.cache/kaimon (respects XDG_CACHE_HOME).
# All operational files (logs, sockets, sessions, db, pid files) go here.

"""
    kaimon_cache_dir() -> String

Return the path to the Kaimon cache directory, creating it if needed.
Respects `XDG_CACHE_HOME` on Unix; uses `LOCALAPPDATA` on Windows.
Defaults to `~/.cache/kaimon`.
"""
function kaimon_cache_dir()
    dir = get(ENV, "XDG_CACHE_HOME") do
        if Sys.iswindows()
            joinpath(
                get(ENV, "LOCALAPPDATA", joinpath(homedir(), "AppData", "Local")),
                "Kaimon",
            )
        else
            joinpath(homedir(), ".cache", "kaimon")
        end
    end
    mkpath(dir)
    return dir
end

include("utils.jl")
include("database.jl")
include("qdrant_client.jl")
include("tools.jl")
include("Generate.jl")
include("gate_prefs.jl")
include("gate.jl")
include("gate_client.jl")
include("stress_test.jl")
include("test_output_parser.jl")
include("test_runner.jl")
include("tui.jl")

# Export public API functions
export start!, stop!, test_server
export setup_security, security_status, generate_key, revoke_key
export allow_ip, deny_ip, set_security_mode
export call_tool, list_tools, tool_help
export tui  # TUI server entry point
export setup_wizard_tui  # Animated security setup wizard
export Gate  # Eval gate module (includes GateTool for session-scoped tools)
export get_gate_mirror_repl_preference, set_gate_mirror_repl_preference!

# ============================================================================
# Port Management
# ============================================================================

"""
    find_free_port(start_port::Int=40000, end_port::Int=49999) -> Int

Find an available port in the specified range by attempting to bind to each port.

# Arguments
- `start_port::Int=40000`: Start of port range to search (default: 40000-49999 for dynamic ports)
- `end_port::Int=49999`: End of port range to search

# Returns
- `Int`: First available port in the range

# Throws
- `ErrorException`: If no free port is found in the range

# Examples
```julia
# Find port in default range (40000-49999)
port = find_free_port()

# Find port in custom range
port = find_free_port(4000, 4999)
```
"""
function find_free_port(start_port::Int = 40000, end_port::Int = 49999)
    last_error = nothing
    ports_tried = 0

    for port = start_port:end_port
        ports_tried += 1
        try
            # Try to bind to the port - if successful, it's available
            server = Sockets.listen(Sockets.InetAddr(parse(IPAddr, "127.0.0.1"), port))
            close(server)
            @info "Found free port" port = port ports_tried = ports_tried
            return port
        catch e
            # Port is in use or binding failed, try next one
            last_error = e
            if ports_tried <= 5 || ports_tried == end_port - start_port + 1
                @debug "Port unavailable" port = port exception = e
            end
            continue
        end
    end

    # Provide detailed error message
    error_msg = "No free ports available in range $start_port-$end_port"
    if last_error !== nothing
        error_msg *= ". Last error: $(sprint(showerror, last_error))"
    end
    error(error_msg)
end

# Version tracking - gets git commit hash at runtime
function version_info()
    try
        pkg_dir = pkgdir(@__MODULE__)
        git_dir = joinpath(pkg_dir, ".git")

        # Check if it's a git repo first (dev package)
        if isdir(git_dir)
            try
                commit = readchomp(`git -C $(pkg_dir) rev-parse --short HEAD`)
                dirty = success(`git -C $(pkg_dir) diff --quiet`) ? "" : "-dirty"
                return "$(commit)$(dirty)"
            catch git_error
                @warn "Failed to get git version" exception = git_error
                # Fall through to read from Project.toml
            end
        end

        # Read version from Project.toml
        project_file = joinpath(pkg_dir, "Project.toml")
        if isfile(project_file)
            project = TOML.parsefile(project_file)
            if haskey(project, "version")
                return "v$(project["version"])"
            end
        end

        return "unknown"
    catch e
        @warn "Failed to get version info" exception = e
        return "unknown"
    end
end

# ============================================================================
# Tool Definition Macros
# ============================================================================

"""
    @mcp_tool id description params handler

Define an MCP tool with symbol-based identification.

# Arguments
- `id`: Symbol literal (e.g., :exec_repl) - becomes both internal ID and string name
- `description`: String describing the tool
- `params`: Parameters schema Dict
- `handler`: Function taking (args) or (args, stream_channel)

# Examples
```julia
tool = @mcp_tool :exec_repl "Execute Julia code" Dict(
    "type" => "object",
    "properties" => Dict("expression" => Dict("type" => "string")),
    "required" => ["expression"]
) (args, stream_channel=nothing) -> begin
    execute_repllike(get(args, "expression", ""); stream_channel=stream_channel)
end
```
"""
macro mcp_tool(id, description, params, handler)
    if !(id isa QuoteNode || (id isa Expr && id.head == :quote))
        error("@mcp_tool requires a symbol literal for id, got: $id")
    end

    # Extract the symbol from QuoteNode
    id_sym = id isa QuoteNode ? id.value : id.args[1]
    name_str = string(id_sym)

    return esc(
        quote
            MCPTool(
                $(QuoteNode(id_sym)),    # :exec_repl
                $name_str,                # "exec_repl"
                $description,
                $params,
                $handler,
            )
        end,
    )
end

include("security.jl")
include("setup_wizard_tui.jl")
include("repl_status.jl")
include("tool_definitions.jl")
include("MCPServer.jl")
include("config_utils.jl")
include("vscode.jl")
include("reflection_tools.jl")
include("qdrant_tools.jl")
include("qdrant_indexer.jl")

# ============================================================================
# VS Code Response Storage for Bidirectional Communication
# ============================================================================

# Global dictionary to store VS Code command responses
# Key: request_id (String), Value: (result, error, timestamp)
const VSCODE_RESPONSES = Dict{String,Tuple{Any,Union{Nothing,String},Float64}}()

# Lock for thread-safe access to response dictionary
const VSCODE_RESPONSE_LOCK = ReentrantLock()

# Global dictionary to store single-use nonces for VS Code callbacks
# Key: request_id (String), Value: (nonce, timestamp)
const VSCODE_NONCES = Dict{String,Tuple{String,Float64}}()

# Lock for thread-safe access to nonces dictionary
const VSCODE_NONCE_LOCK = ReentrantLock()

# Lock for serializing REPL-like execution.
# `execute_repllike` currently uses stdout/stderr redirection which is process-global;
# concurrent calls can collide and leave the session in a bad state.
const EXEC_REPLLIKE_LOCK = ReentrantLock()


"""
    store_vscode_response(request_id::String, result, error::Union{Nothing,String})

Store a response from VS Code for later retrieval.
Thread-safe storage using VSCODE_RESPONSE_LOCK.
"""
function store_vscode_response(request_id::String, result, error::Union{Nothing,String})
    lock(VSCODE_RESPONSE_LOCK) do
        VSCODE_RESPONSES[request_id] = (result, error, time())
    end
end

"""
    retrieve_vscode_response(request_id::String; timeout::Float64=5.0, poll_interval::Float64=0.1)

Retrieve a stored VS Code response, waiting up to `timeout` seconds.
Returns (result, error) tuple or throws TimeoutError.
Automatically cleans up the stored response after retrieval.
"""
function retrieve_vscode_response(
    request_id::String;
    timeout::Float64 = 5.0,
    poll_interval::Float64 = 0.1,
)
    start_time = time()

    while (time() - start_time) < timeout
        response = lock(VSCODE_RESPONSE_LOCK) do
            get(VSCODE_RESPONSES, request_id, nothing)
        end

        if response !== nothing
            # Clean up the stored response
            lock(VSCODE_RESPONSE_LOCK) do
                delete!(VSCODE_RESPONSES, request_id)
            end
            return (response[1], response[2])  # (result, error)
        end

        sleep(poll_interval)
    end

    error("Timeout waiting for VS Code response (request_id: $request_id)")
end

"""
    cleanup_old_vscode_responses(max_age::Float64=60.0)

Remove responses older than `max_age` seconds to prevent memory leaks.
Should be called periodically.
"""
function cleanup_old_vscode_responses(max_age::Float64 = 60.0)
    current_time = time()
    lock(VSCODE_RESPONSE_LOCK) do
        for (request_id, (_, _, timestamp)) in collect(VSCODE_RESPONSES)
            if (current_time - timestamp) > max_age
                delete!(VSCODE_RESPONSES, request_id)
            end
        end
    end
end

# ============================================================================
# Nonce Management for VS Code Authentication
# ============================================================================

"""
    generate_nonce()

Generate a cryptographically secure random nonce for single-use authentication.
Returns a 32-character hex string.
"""
function generate_nonce()
    return bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
end

"""
    store_nonce(request_id::String, nonce::String)

Store a nonce for a specific request ID. Thread-safe.
"""
function store_nonce(request_id::String, nonce::String)
    lock(VSCODE_NONCE_LOCK) do
        VSCODE_NONCES[request_id] = (nonce, time())
    end
end

"""
    validate_and_consume_nonce(request_id::String, nonce::String)::Bool

Validate that a nonce matches the stored nonce for a request ID, then consume it (delete it).
Returns true if valid, false otherwise. Thread-safe.
"""
function validate_and_consume_nonce(request_id::String, nonce::String)::Bool
    lock(VSCODE_NONCE_LOCK) do
        stored = get(VSCODE_NONCES, request_id, nothing)
        if stored === nothing
            return false
        end

        stored_nonce, _ = stored
        # Delete immediately to prevent reuse
        delete!(VSCODE_NONCES, request_id)

        return stored_nonce == nonce
    end
end

"""
    cleanup_old_nonces(max_age::Float64=60.0)

Remove nonces older than `max_age` seconds to prevent memory leaks.
Should be called periodically.
"""
function cleanup_old_nonces(max_age::Float64 = 60.0)
    current_time = time()
    lock(VSCODE_NONCE_LOCK) do
        for (request_id, (_, timestamp)) in collect(VSCODE_NONCES)
            if (current_time - timestamp) > max_age
                delete!(VSCODE_NONCES, request_id)
            end
        end
    end
end

# ============================================================================
# VS Code URI Helpers
# ============================================================================

# Helper function to trigger VS Code commands via URI
function trigger_vscode_uri(uri::String)
    if Sys.isapple()
        run(`open $uri`)
    elseif Sys.islinux()
        run(`xdg-open $uri`)
    elseif Sys.iswindows()
        run(`cmd /c start $uri`)
    else
        error("Unsupported operating system")
    end
end

# Helper function to build VS Code command URI
function build_vscode_uri(
    command::String;
    args::Union{Nothing,String} = nothing,
    request_id::Union{Nothing,String} = nothing,
    mcp_port::Int = 3000,
    nonce::Union{Nothing,String} = nothing,
    publisher::String = "Kaimon",
    name::String = "vscode-remote-control",
)
    uri = "vscode://$(publisher).$(name)?cmd=$(command)"
    if args !== nothing
        uri *= "&args=$(args)"
    end
    if request_id !== nothing
        uri *= "&request_id=$(request_id)"
    end
    if mcp_port != 3000
        uri *= "&mcp_port=$(mcp_port)"
    end
    if nonce !== nothing
        uri *= "&nonce=$(HTTP.URIs.escapeuri(nonce))"
    end
    return uri
end

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
            push!(parts, sprint(Base.show_unquoted, arg, 0, 0))
        end
        return join(parts, "\n")
    else
        return sprint(Base.show_unquoted, expr, 0, 0)
    end
end

"""
    remove_println_calls(expr, toplevel=true, strip_show=true, was_stripped=Ref(false))

Strip println, print, printstyled, @show, and logging macros from an AST expression.
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
                            # Apply REPL ast_transforms (Revise, softscope, etc.)
                            if isdefined(Base, :active_repl_backend) &&
                               Base.active_repl_backend !== nothing
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
                    # Apply REPL ast_transforms (Revise, softscope, etc.)
                    if isdefined(Base, :active_repl_backend) &&
                       Base.active_repl_backend !== nothing
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
const TOOL_REGISTRY_LOCK = ReentrantLock()

"""
    _register_dynamic_tools!(tools::Vector{MCPTool})

Register tools into the global registry at runtime. Updates both `ALL_TOOLS[]`
and `SERVER[].tools`. Sends `tools/list_changed` notification.
Thread-safe.
"""
function _register_dynamic_tools!(tools::Vector{MCPTool})
    lock(TOOL_REGISTRY_LOCK) do
        for tool in tools
            if ALL_TOOLS[] !== nothing
                push!(ALL_TOOLS[], tool)
            end
            server = SERVER[]
            if server !== nothing
                server.tools[tool.id] = tool
                server.name_to_id[tool.name] = tool.id
            end
        end
    end
    _notify_tools_changed()
end

"""
    _unregister_dynamic_tools!(prefix::String)

Remove all tools whose name starts with `prefix` from the global registry.
Sends `tools/list_changed` notification. Thread-safe.
"""
function _unregister_dynamic_tools!(prefix::String)
    removed = false
    lock(TOOL_REGISTRY_LOCK) do
        if ALL_TOOLS[] !== nothing
            before = length(ALL_TOOLS[])
            filter!(t -> !startswith(t.name, prefix), ALL_TOOLS[])
            removed = length(ALL_TOOLS[]) < before
        end
        server = SERVER[]
        if server !== nothing
            for (id, tool) in collect(server.tools)
                if startswith(tool.name, prefix)
                    delete!(server.tools, id)
                    delete!(server.name_to_id, tool.name)
                    removed = true
                end
            end
        end
    end
    removed && _notify_tools_changed()
end

"""
    _notify_tools_changed()

Push a `notifications/tools/list_changed` notification to the pending queue
so MCP clients re-fetch the tool list on the next SSE response.
"""
function _notify_tools_changed()
    try
        push!(
            _PENDING_NOTIFICATIONS,
            Dict{String,Any}(
                "jsonrpc" => "2.0",
                "method" => "notifications/tools/list_changed",
            ),
        )
    catch
        # Channel full or not initialized — non-critical
    end
end

# ── Gate mode globals ──────────────────────────────────────────────────────
# When running in TUI server mode, tool calls route through the gate client
# instead of executing in-process.

const GATE_MODE = Ref{Bool}(false)
const GATE_CONN_MGR = Ref{Union{Nothing,ConnectionManager}}(nothing)

"""
    _resolve_gate_conn(session) -> (conn, error_string)

Resolve a gate connection from the session key. Returns (conn, nothing) on success,
or (nothing, error_message) on failure.
"""
function _resolve_gate_conn(session::String)
    mgr = GATE_CONN_MGR[]
    if mgr === nothing
        return (nothing, "ERROR: Gate mode active but no ConnectionManager configured")
    end

    conn = if isempty(session)
        conns = connected_sessions(mgr)
        if length(conns) == 1
            conns[1]
        else
            nothing
        end
    else
        get_connection_by_key(mgr, session)
    end
    if conn === nothing
        available =
            join(["$(short_key(c)) ($(c.name))" for c in connected_sessions(mgr)], ", ")
        if isempty(available)
            return (
                nothing,
                "ERROR: No REPL sessions connected. Start a gate in your Julia REPL:\n  Gate.serve()",
            )
        end
        return (nothing, "ERROR: No session matched '$(session)'. Available: $available")
    end
    return (conn, nothing)
end

"""
    _prepare_gate_code(code, quiet) -> (cleaned_code, show_return_value, was_stripped)

Apply println stripping and quiet-mode semicolons to code before sending to gate.
"""
function _prepare_gate_code(code::String, quiet::Bool)
    was_stripped = Ref(false)
    expr = Base.parse_input_line(code)
    expr = remove_println_calls(expr, true, quiet, was_stripped)
    cleaned_code = if expr === nothing
        ""
    elseif was_stripped[]
        _serialize_expr(expr)
    else
        code
    end

    show_return_value = !quiet && !REPL.ends_with_semicolon(code)
    if quiet && !REPL.ends_with_semicolon(cleaned_code)
        cleaned_code = cleaned_code * ";"
    end

    return (cleaned_code, show_return_value, was_stripped)
end

"""
    _format_gate_response(response, show_return_value, quiet, was_stripped, max_output) -> String

Format a gate eval response into the final result string.
"""
function _format_gate_response(
    response,
    show_return_value::Bool,
    quiet::Bool,
    was_stripped::Ref{Bool},
    max_output::Int,
)
    captured = ""
    if hasproperty(response, :stdout) && hasproperty(response, :stderr)
        captured = string(response.stdout) * string(response.stderr)
    end

    result_str = ""
    if hasproperty(response, :exception) && response.exception !== nothing
        result_str = "ERROR: " * string(response.exception)
    elseif show_return_value && hasproperty(response, :value_repr)
        result_str = string(response.value_repr)
    end

    has_error = hasproperty(response, :exception) && response.exception !== nothing
    result = if quiet && !has_error
        ""
    else
        captured * result_str
    end

    if was_stripped[]
        result *= "\n\n⚠️  Note: println/print/logging calls were removed. Use q=false with a final expression to see values."
    end

    if length(result) > max_output
        original_length = length(result)
        result = truncate_output(result, max_output, nothing)
        result *= "\n\n⚠️  Output truncated ($max_output of $original_length chars shown)."
    end

    return result
end

"""
    execute_via_gate_streaming(code; quiet=true, silent=false, max_output=6000, session="", on_progress=nothing)

Execute code on a remote REPL via the gate client using async eval with streaming output.
The `on_progress` callback receives `(message::String)` for each output chunk, enabling
upstream callers (e.g. SSE progress notifications) to forward incremental output.

Falls back to synchronous `eval_remote` if the gate doesn't support `:eval_async`.
"""
function execute_via_gate_streaming(
    code::String;
    quiet::Bool = true,
    silent::Bool = false,
    max_output::Int = 6000,
    session::String = "",
    on_progress::Union{Function,Nothing} = nothing,
)
    conn, err = _resolve_gate_conn(session)
    err !== nothing && return err

    cleaned_code, show_return_value, was_stripped = _prepare_gate_code(code, quiet)

    # Use async eval with streaming — on_output forwards chunks to on_progress
    on_output = if on_progress !== nothing
        (channel, data) -> begin
            try
                on_progress("[$channel] $data")
            catch
            end
        end
    else
        nothing
    end

    response =
        eval_remote_async(conn, cleaned_code; display_code = code, on_output = on_output)

    # Fallback: if gate doesn't support :eval_async (old gate version),
    # the error will mention "unknown request type". Retry with sync eval_remote.
    if hasproperty(response, :exception) &&
       response.exception !== nothing &&
       contains(string(response.exception), "unknown request type")
        response = eval_remote(conn, cleaned_code; display_code = code)
    end

    return _format_gate_response(
        response,
        show_return_value,
        quiet,
        was_stripped,
        max_output,
    )
end

"""
    execute_via_gate(code; quiet=true, max_output=6000)

Execute code on a remote REPL via the gate client. Used when GATE_MODE is
active (TUI server process). Falls back to in-process eval if no gate is
connected.

Delegates to `execute_via_gate_streaming` with async eval for robustness
(avoids blocking the REQ socket during long evals).
"""
function execute_via_gate(
    code::String;
    quiet::Bool = true,
    silent::Bool = false,
    max_output::Int = 6000,
    session::String = "",
)
    return execute_via_gate_streaming(
        code;
        quiet = quiet,
        silent = silent,
        max_output = max_output,
        session = session,
        on_progress = nothing,
    )
end

# ============================================================================
# Tool Configuration Management
# ============================================================================

"""
    load_tools_config(config_path::String = ".kaimon/tools.json")

Load the tools configuration from .kaimon/tools.json.
Returns a Set of enabled tool names (as Symbols).

The configuration supports:
- Tool sets that can be enabled/disabled as groups
- Individual tool overrides that take precedence over tool set settings

If the config file doesn't exist, returns `nothing` to indicate all tools should be enabled.
"""
function load_tools_config(
    config_path::String = ".kaimon/tools.json",
    workspace_dir::String = pwd(),
)
    full_path = joinpath(workspace_dir, config_path)

    # If config doesn't exist, enable all tools (backward compatibility)
    if !isfile(full_path)
        return nothing
    end

    try
        config = JSON.parsefile(full_path; dicttype = Dict{String,Any})
        enabled_tools = Set{Symbol}()

        # First, process tool sets
        tool_sets = get(config, "tool_sets", Dict())
        for (set_name, set_config) in tool_sets
            if get(set_config, "enabled", false)
                tools = get(set_config, "tools", String[])
                for tool_name in tools
                    push!(enabled_tools, Symbol(tool_name))
                end
            end
        end

        # Then apply individual overrides
        individual_overrides = get(config, "individual_overrides", Dict())
        for (tool_name, enabled) in individual_overrides
            # Skip comment entries
            if startswith(tool_name, "_")
                continue
            end

            tool_sym = Symbol(tool_name)
            if enabled
                push!(enabled_tools, tool_sym)
            else
                delete!(enabled_tools, tool_sym)
            end
        end

        return enabled_tools
    catch e
        @warn "Error loading tools configuration from $full_path: $e. Enabling all tools."
        return nothing
    end
end

"""
    filter_tools_by_config(enabled_tools::Union{Set{Symbol},Nothing})

Filter tools from ALL_TOOLS based on the enabled tools set.
If enabled_tools is `nothing`, returns all tools (backward compatibility).
"""
function filter_tools_by_config(enabled_tools::Union{Set{Symbol},Nothing})
    if enabled_tools === nothing
        return ALL_TOOLS[]
    end

    return filter(tool -> tool.id in enabled_tools, ALL_TOOLS[])
end

"""
    collect_tools() -> Vector{MCPTool}

Assemble all MCP tools (core, reflection, Qdrant) into a single vector.
Used by both `start!()` and the TUI to build the tool list for the MCP server.
"""
function collect_tools()::Vector{MCPTool}
    reflection_tools = create_reflection_tools()
    qdrant_tools = create_qdrant_tools()

    return MCPTool[
        ping_tool,
        usage_instructions_tool,
        usage_quiz_tool,
        tool_help_tool,
        repl_tool,
        manage_repl_tool,
        set_tty_tool,
        vscode_command_tool,
        list_vscode_commands_tool,
        investigate_tool,
        search_methods_tool,
        macro_expand_tool,
        type_info_tool,
        profile_tool,
        list_names_tool,
        code_lowered_tool,
        code_typed_tool,
        format_tool,
        lint_tool,
        navigate_to_file_tool,
        open_and_breakpoint_tool,
        start_debug_session_tool,
        add_watch_expression_tool,
        copy_debug_value_tool,
        debug_step_over_tool,
        debug_step_into_tool,
        debug_step_out_tool,
        debug_continue_tool,
        debug_stop_tool,
        pkg_add_tool,
        pkg_rm_tool,
        run_tests_tool,
        stress_test_tool,
        reflection_tools...,
        qdrant_tools...,
    ]
end


"""
    start!(; port=nothing, verbose=true, security_mode=nothing, julia_session_name="", workspace_dir=pwd())

Start the Kaimon MCP server.

# Arguments
- `port::Union{Int,Nothing}=nothing`: Server port. Use `0` for dynamic port assignment (finds first available port in 40000-49999). If `nothing`, uses port from configuration.
- `verbose::Bool=true`: Show startup messages
- `security_mode::Union{Symbol,Nothing}=nothing`: Override security mode (:strict, :relaxed, or :lax)
- `julia_session_name::String=""`: Name for this Julia session
- `workspace_dir::String=pwd()`: Project root directory

# Dynamic Port Assignment
Set `port=0` (or use `"port": 0` in security.json) to automatically find and use an available port.
The server will search ports 40000-49999 for the first free port. This higher range avoids conflicts with common services.

# Examples
```julia
# Use configured port from security.json
Kaimon.start!()

# Use specific port
Kaimon.start!(port=4000)

# Use dynamic port assignment
Kaimon.start!(port=0)

# Start with a custom name
Kaimon.start!(julia_session_name="data-processor")
```
"""
function start!(;
    port::Union{Int,Nothing} = nothing,
    verbose::Bool = true,
    security_mode::Union{Symbol,Nothing} = nothing,
    julia_session_name::String = "",
    workspace_dir::String = pwd(),
    session_uuid::Union{String,Nothing} = nothing,
)
    SERVER[] !== nothing && stop!() # Stop existing server if running

    # Temporarily suppress Info logs during startup to avoid interfering with spinner
    old_logger = global_logger()
    global_logger(ConsoleLogger(stderr, Logging.Warn))

    # Start animated spinner for startup
    spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
    spinner_idx = Ref(1)
    spinner_active = Ref(true)
    status_msg = Ref("Starting Kaimon...")

    # Background task to animate spinner
    spinner_task = @async begin
        while spinner_active[]
            msg = status_msg[]
            # Magenta spinner, bold gray text
            print("\r\033[K\033[35m$(spinner[spinner_idx[]])\033[0m \033[1;90m$msg\033[0m")
            flush(stdout)
            spinner_idx[] = spinner_idx[] % length(spinner) + 1
            sleep(0.08)
        end
    end

    # Load or prompt for security configuration
    # Use workspace_dir (project root) not pwd() (which may be agent dir)
    @debug "Loading security config" workspace_dir = workspace_dir
    security_config = load_security_config(workspace_dir)

    # Fall back to global config
    if security_config === nothing
        security_config = load_global_security_config()
    end

    if security_config === nothing
        # Stop spinner before launching wizard
        spinner_active[] = false
        wait(spinner_task)
        global_logger(old_logger)

        print("\r\033[K")  # Clear spinner line
        security_config = setup_wizard_tui()
        if security_config === nothing
            error("Security configuration required. Run Kaimon.setup() first.")
        end
    else
        @debug "Security config loaded successfully" port = security_config.port mode =
            security_config.mode
    end

    # Determine port: function arg overrides config, otherwise use what load_security_config() found
    actual_port = if port !== nothing
        if port == 0
            # Port 0 means find a free port dynamically
            @info "Finding available port dynamically"
            find_free_port()
        else
            @info "Using port from function argument" port = port
            port
        end
    else
        # load_security_config already loaded the right port
        config_port = security_config.port
        if config_port == 0
            # Port 0 in config means find a free port dynamically
            @info "Finding available port dynamically (from config)"
            find_free_port()
        else
            @debug "Using port from loaded config" port = config_port mode =
                (julia_session_name != "" ? "agent:$julia_session_name" : "normal")
            config_port
        end
    end

    # Override security mode if specified
    if security_mode !== nothing
        if !(security_mode in [:strict, :relaxed, :lax])
            # Stop spinner before showing error
            spinner_active[] = false
            wait(spinner_task)
            global_logger(old_logger)

            print("\r\033[K")  # Clear spinner line
            error("Invalid security_mode. Must be :strict, :relaxed, or :lax")
        end
        security_config = SecurityConfig(
            security_mode,
            security_config.api_keys,
            security_config.allowed_ips,
            security_config.port,
            security_config.index_dirs,
            security_config.index_extensions,
            security_config.created_at,
        )
    end

    # Update status message
    status_msg[] = "Starting Kaimon (security: $(security_config.mode))..."

    # Show security status if verbose
    if verbose
        printstyled("\n📡 Server Port: ", color = :cyan, bold = true)
        printstyled("$actual_port\n", color = :green, bold = true)
        println()
    end

    all_tools = collect_tools()
    Kaimon.ALL_TOOLS[] = all_tools

    # Load tools configuration from workspace directory
    enabled_tools = load_tools_config(".kaimon/tools.json", workspace_dir)

    # Filter tools based on configuration
    active_tools = filter_tools_by_config(enabled_tools)

    # Show tool configuration status if verbose and config exists
    if verbose && enabled_tools !== nothing
        disabled_count = length(all_tools) - length(active_tools)
        if disabled_count > 0
            printstyled("🔧 Tools: ", color = :cyan, bold = true)
            println("$(length(active_tools)) enabled, $disabled_count disabled by config")
        end
    end

    # Update status for server launch
    status_msg[] = "Starting Kaimon (launching server on port $actual_port)..."
    SERVER[] = start_mcp_server(
        active_tools,
        actual_port;
        verbose = verbose,
        security_config = security_config,
        session_uuid = session_uuid,
    )

    # Stop the spinner and show completion
    spinner_active[] = false
    wait(spinner_task)  # Wait for spinner task to finish

    # Restore original logger
    global_logger(old_logger)

    # Green checkmark, dark blue text, yellow dragon, muted cyan port number
    print(
        "\r\033[K\033[1;32m✓\033[0m \033[38;5;24mKaimon server started\033[0m \033[33m🐉\033[0m \033[90m(port $actual_port)\033[0m\n",
    )
    flush(stdout)

    if isdefined(Base, :active_repl) && Base.active_repl !== nothing
        try
            set_prefix!(Base.active_repl)
            # Refresh the prompt to show the new prefix
            if isdefined(Base.active_repl, :mistate) && Base.active_repl.mistate !== nothing
                REPL.LineEdit.refresh_line(Base.active_repl.mistate)
            end
        catch e
            @debug "Failed to set REPL prefix" exception = e
        end
    else
        atreplinit(set_prefix!)
    end


    nothing
end

function set_prefix!(repl)
    try
        mode = get_mainmode(repl)
        if mode !== nothing
            mode.prompt = REPL.contextual_prompt(repl, "✻ julia> ")
        end
    catch e
        @debug "Failed to set REPL prefix" exception = e
    end
end
function unset_prefix!(repl)
    try
        mode = get_mainmode(repl)
        if mode !== nothing
            mode.prompt = REPL.contextual_prompt(repl, REPL.JULIA_PROMPT)
        end
    catch e
        @debug "Failed to unset REPL prefix" exception = e
    end
end
function get_mainmode(repl)
    try
        if !isdefined(repl, :interface) || repl.interface === nothing
            return nothing
        end
        modes = filter(repl.interface.modes) do mode
            mode isa REPL.Prompt &&
                mode.prompt isa Function &&
                contains(mode.prompt(), "julia>")
        end
        return isempty(modes) ? nothing : only(modes)
    catch e
        @debug "Failed to get main REPL mode" exception = e
        return nothing
    end
end

function stop!()
    if SERVER[] !== nothing
        println("Stop existing server...")

        # Stop background indexing scheduler
        try
            stop_index_sync_scheduler()
        catch e
            @debug "Failed to stop index sync scheduler" exception = e
        end

        stop_mcp_server(SERVER[])
        SERVER[] = nothing
        if isdefined(Base, :active_repl) && Base.active_repl !== nothing
            try
                unset_prefix!(Base.active_repl) # Reset the prompt prefix
            catch e
                @debug "Failed to reset REPL prefix" exception = e
            end
        end
    else
        println("No server running to stop.")
    end
end

"""
    test_server(port::Int=3000; max_attempts::Int=3, delay::Float64=0.5)

Test if the MCP server is running and responding to REPL requests.

Attempts to connect to the server on the specified port and send a simple
exec_repl command. Returns `true` if successful, `false` otherwise.

# Arguments
- `port::Int`: The port number the MCP server is running on (default: 3000)
- `max_attempts::Int`: Maximum number of connection attempts (default: 3)
- `delay::Float64`: Delay in seconds between attempts (default: 0.5)

# Example
```julia
if Kaimon.test_server(3000)
    println("✓ MCP Server is responding")
else
    println("✗ MCP Server is not responding")
end
```
"""
function test_server(
    port::Int = 3000;
    host = "127.0.0.1",
    max_attempts::Int = 3,
    delay::Float64 = 0.5,
)
    for attempt = 1:max_attempts
        try
            # Use HTTP.jl for a clean, proper request
            body = """{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"exec_repl","arguments":{"expression":"println(\\\"🎉 MCP Server ready!\\\")","silent":true}}}"""

            # Build headers with security if configured
            headers = Dict{String,String}("Content-Type" => "application/json")

            # Prefer explicit env var when present
            env_key = get(ENV, "JULIA_MCP_API_KEY", "")

            # Load workspace security config (if available)
            security_config = try
                load_security_config()
            catch
                nothing
            end

            auth_key = nothing

            if !isempty(env_key)
                auth_key = env_key
            elseif security_config !== nothing && security_config.mode != :lax
                # Use the first configured key, if any
                if !isempty(security_config.api_keys)
                    auth_key = first(security_config.api_keys)
                end
            end

            if auth_key !== nothing
                headers["Authorization"] = "Bearer $(auth_key)"
            end

            response = HTTP.post(
                "http://$host:$port/",
                collect(headers),
                body;
                readtimeout = 5,
                connect_timeout = 2,
            )

            # Check if we got a successful response
            if response.status == 200
                REPL.prepare_next(Base.active_repl)
                return true
            end
        catch e
            if attempt < max_attempts
                sleep(delay)
            end
        end
    end

    println("✗ MCP Server on port $port is not responding after $max_attempts attempts")
    return false
end

# ============================================================================
# Public Security Management Functions
# ============================================================================

"""
    security_status()

Display current security configuration.
"""
function security_status()
    config = load_security_config()
    if config === nothing
        printstyled("\n⚠️  No security configuration found\n", color = :yellow, bold = true)
        println("Run Kaimon.setup_security() to configure")
        println()
        return
    end
    show_security_status(config)
end

"""
    setup_security(; force::Bool=false)

Launch the security setup wizard.
"""
function setup_security(; force::Bool = false, mode::Symbol = :auto)
    if !force
        existing = load_global_security_config()
        if existing === nothing
            existing = load_security_config()
        end
        if existing !== nothing
            println()
            printstyled(
                "Security configuration already exists (mode: $(existing.mode))\n",
                color = :green,
            )
            print("Reconfigure? [y/N]: ")
            response = strip(lowercase(readline()))
            if !(response == "y" || response == "yes")
                return existing
            end
        end
    end
    return setup_wizard_tui(; mode = mode)
end

"""
    generate_key()

Generate and add a new API key to the current configuration.
"""
function generate_key()
    return add_api_key!(pwd())
end

"""
    revoke_key(key::String)

Revoke (remove) an API key from the configuration.
"""
function revoke_key(key::String)
    return remove_api_key!(key, pwd())
end

"""
    allow_ip(ip::String)

Add an IP address to the allowlist.
"""
function allow_ip(ip::String)
    return add_allowed_ip!(ip, pwd())
end

"""
    deny_ip(ip::String)

Remove an IP address from the allowlist.
"""
function deny_ip(ip::String)
    return remove_allowed_ip!(ip, pwd())
end

"""
    set_security_mode(mode::Symbol)

Change the security mode (:strict, :relaxed, or :lax).
"""
function set_security_mode(mode::Symbol)
    return change_security_mode!(mode, pwd())
end

"""
    call_tool(tool_id::Symbol, args::Dict)

Call an MCP tool directly from the REPL without hanging.

This helper function handles the two-parameter signature that most tools expect
(args and stream_channel), making it easier to call tools programmatically.

# Examples
```julia
Kaimon.call_tool(:exec_repl, Dict("expression" => "2 + 2"))
Kaimon.call_tool(:investigate_environment, Dict())
Kaimon.call_tool(:search_methods, Dict("query" => "println"))
```

# Available Tools
Call `list_tools()` to see all available tools and their descriptions.
"""
function call_tool(tool_id::Symbol, args::Dict)
    if SERVER[] === nothing
        error("MCP server is not running. Start it with Kaimon.start!()")
    end

    server = SERVER[]
    if !haskey(server.tools, tool_id)
        error("Tool :$tool_id not found. Call list_tools() to see available tools.")
    end

    tool = server.tools[tool_id]

    # Execute tool handler synchronously when called from REPL
    # This avoids deadlock when tools call execute_repllike
    try
        # Try calling with just args first (most common case)
        # If that fails with MethodError, try with streaming channel parameter
        result = try
            tool.handler(args)
        catch e
            if e isa MethodError && hasmethod(tool.handler, Tuple{typeof(args),typeof(nothing)})
                # Handler supports streaming, call with both parameters
                tool.handler(args, nothing)
            else
                rethrow(e)
            end
        end
        return result
    catch e
        rethrow(e)
    end
end

function call_tool(tool_id::Symbol, args::Pair{Symbol,String}...)
    return call_tool(tool_id, Dict([String(k) => v for (k, v) in args]))
end

"""
    list_tools()

List all available MCP tools with their names and descriptions.

Returns a dictionary mapping tool names to their descriptions.
"""
function list_tools()
    if SERVER[] === nothing
        error("MCP server is not running. Start it with Kaimon.start!()")
    end

    server = SERVER[]
    tools_info = Dict{Symbol,String}()

    for (id, tool) in server.tools
        tools_info[id] = tool.description
    end

    # Print formatted output
    println("\n📚 Available MCP Tools")
    println("="^70)
    println()

    for (name, desc) in sort(collect(tools_info))
        printstyled("  • ", name, "\n", color = :cyan, bold = true)
        # Print first line of description
        first_line = split(desc, "\n")[1]
        println("    ", first_line)
        println()
    end

    return tools_info
end

"""
    tool_help(tool_id::Symbol)
Get detailed help/documentation for a specific MCP tool.
"""
function tool_help(tool_id::Symbol; extended::Bool = false)
    if SERVER[] === nothing
        error("MCP server is not running. Start it with Kaimon.start!()")
    end

    server = SERVER[]
    if !haskey(server.tools, tool_id)
        error("Tool :$tool_id not found. Call list_tools() to see available tools.")
    end

    tool = server.tools[tool_id]

    println("\n📖 Help for MCP Tool :$tool_id")
    println("="^70)
    println()
    println(tool.description)
    println()

    # Try to load extended documentation if requested
    if extended
        extended_help_path =
            joinpath(dirname(dirname(@__FILE__)), "extended-help", "$(string(tool_id)).md")

        if isfile(extended_help_path)
            println("\n" * "="^70)
            println("Extended Documentation")
            println("="^70)
            println()
            println(read(extended_help_path, String))
        else
            println("(No extended documentation available for this tool)")
        end
    end

    return tool
end

function restart(; session::String = "")
    call_tool(:manage_repl, Dict("command" => "restart", "session" => session))
end
function shutdown(; session::String = "")
    call_tool(:manage_repl, Dict("command" => "shutdown", "session" => session))
end

end #module

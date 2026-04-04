# ─────────────────────────────────────────────────────────────────────────────
# Demo: println behavior in Kaimon's ex tool
#
# This file demonstrates how println/print/stdout works through the MCP
# pipeline. Run each section via the ex tool to see the behavior.
#
# Key principle: The ex tool strips println/print from the AGENT'S submitted
# code AST, but does NOT affect prints inside functions that already exist
# or that are called by the agent's code. Runtime stdout from called functions
# is captured and returned with q=false.
# ─────────────────────────────────────────────────────────────────────────────

# ── Functions with println (simulating user code / library code) ─────────────

"""Simulate a long-running computation with progress output."""
function demo_compute_with_progress(n::Int)
    total = 0.0
    for i in 1:n
        println("Processing batch $i/$n...")
        total += sum(rand(1000))
        sleep(0.1)
    end
    println("Done! Processed $n batches.")
    return total
end

"""Simulate loading a dataset with status messages."""
function demo_load_data(path::String)
    println("Loading data from: $path")
    println("Parsing headers...")
    sleep(0.1)
    println("Reading 1000 rows...")
    sleep(0.1)
    data = Dict("rows" => 1000, "cols" => 5, "path" => path)
    println("Data loaded successfully: $(data["rows"]) rows, $(data["cols"]) columns")
    return data
end

"""Simulate a compilation step (like CUDA kernel JIT)."""
function demo_compile_kernel(name::String)
    println("Compiling kernel '$name'...")
    for phase in ["parsing", "type inference", "optimization", "code generation"]
        println("  [$phase] ", name)
        sleep(0.2)
    end
    println("Kernel '$name' compiled successfully.")
    return Symbol(name)
end

"""Function that uses @info/@warn for structured logging."""
function demo_with_logging(x)
    @info "Starting computation" x
    if x < 0
        @warn "Negative input, taking absolute value" x
        x = abs(x)
    end
    result = x^2
    @info "Computation complete" result
    return result
end

"""Function that writes to an IO buffer (not stdout)."""
function demo_io_targeted(data)
    buf = IOBuffer()
    println(buf, "Header: demo output")
    for (i, item) in enumerate(data)
        println(buf, "  Row $i: $item")
    end
    return String(take!(buf))
end

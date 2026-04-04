# ─────────────────────────────────────────────────────────────────────────────
# Demo: Streaming progress to agents via Gate.progress and GateTools
#
# Gate.progress() sends real-time progress updates to the MCP client during
# long-running tool calls. This is the preferred method for agents to receive
# incremental updates without waiting for the full result.
# ─────────────────────────────────────────────────────────────────────────────

using Kaimon.Gate: GateTool, progress

# ── Simple streaming progress ────────────────────────────────────────────────

demo_progress_tool = GateTool(
    "demo_long_compute",
    function(n::Int=5)
        results = Float64[]
        for i in 1:n
            progress("Computing batch $i/$n...")
            push!(results, sum(rand(10_000)))
            sleep(2.0)
        end
        progress("All $n batches complete!")
        return (batches=n, total=sum(results), mean=sum(results)/n)
    end
)

# ── Structured domain progress (CUDA-like compilation) ───────────────────────

demo_compile_tool = GateTool(
    "demo_compile_kernels",
    function(kernel_names::Vector{String}=["matmul", "softmax", "attention"])
        compiled = String[]
        for (i, name) in enumerate(kernel_names)
            progress("[$i/$(length(kernel_names))] Compiling '$name'...")
            for phase in ["parse", "type inference", "optimization", "code generation"]
                progress("  $name: $phase...")
                sleep(1.5)
            end
            push!(compiled, name)
            progress("  $name: complete!")
        end
        return (compiled=compiled, count=length(compiled))
    end
)

# Register tools with the running gate
append!(Kaimon.Gate._SESSION_TOOLS[], [demo_progress_tool, demo_compile_tool])

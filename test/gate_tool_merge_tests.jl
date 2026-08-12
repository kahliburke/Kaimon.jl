using ReTest
using Kaimon

const KG = Kaimon.KaimonGate

# ─────────────────────────────────────────────────────────────────────────────
# Registering tools on an ALREADY-RUNNING gate is additive.
#
# A session has several registrants and none of them can see the others: the host
# registers its own tools at boot, a notebook worker registers the tools its host drives
# it through, and any package extension loaded into the session registers from `__init__`.
# When `serve(tools = ...)` replaced the list outright, whichever call ran last silently
# won and the loser was not a missing feature but a broken session -- a `using SomePkg`
# that fired an extension's registration dropped the worker's own tools, so the host could
# no longer talk to the process at all. An extension cannot merge from its side, because
# it has no way to read what is already registered, so the merge has to live here.
# ─────────────────────────────────────────────────────────────────────────────

"""Run `f` against a gate that BELIEVES it is running, with `tools` already registered,
and restore every touched global afterwards. No socket is bound: `_serve`'s merge branch
returns before any transport work, so the flag is all the branch needs."""
function with_running_gate(f, tools; namespace = "incumbent_ns")
    saved = (
        running = KG._RUNNING[],
        tools = KG._SESSION_TOOLS[],
        ns = KG._SESSION_NAMESPACE[],
        sid = KG._SESSION_ID[],
    )
    KG._RUNNING[] = true
    KG._SESSION_TOOLS[] = tools
    KG._SESSION_NAMESPACE[] = namespace
    KG._SESSION_ID[] = "test-session"
    try
        f()
    finally
        KG._RUNNING[] = saved.running
        KG._SESSION_TOOLS[] = saved.tools
        KG._SESSION_NAMESPACE[] = saved.ns
        KG._SESSION_ID[] = saved.sid
    end
end

toolnames() = [t.name for t in KG._SESSION_TOOLS[]]

@testset "serve(tools=...) on a running gate merges" begin

    @testset "incumbent tools survive a later registrant" begin
        incumbents = [KG.GateTool("host_a", () -> "a"), KG.GateTool("host_b", () -> "b")]
        with_running_gate(incumbents) do
            KG.serve(force = true, tools = [KG.GateTool("ext_x", () -> "x")])
            # The regression this file exists for: under the old wholesale replacement
            # this was exactly ["ext_x"], and the session's own tools were gone.
            @test toolnames() == ["host_a", "host_b", "ext_x"]
        end
    end

    @testset "a same-named tool is replaced, not duplicated" begin
        old_handler = () -> "old"
        with_running_gate([KG.GateTool("host_a", old_handler), KG.GateTool("host_b", () -> "b")]) do
            new_handler = () -> "new"
            KG.serve(force = true, tools = [KG.GateTool("host_a", new_handler)])
            @test toolnames() == ["host_a", "host_b"]            # no duplicate, order held
            idx = findfirst(t -> t.name == "host_a", KG._SESSION_TOOLS[])
            @test KG._SESSION_TOOLS[][idx].handler === new_handler
        end
    end

    @testset "re-registering an identical set is idempotent" begin
        tools = [KG.GateTool("host_a", () -> "a"), KG.GateTool("host_b", () -> "b")]
        with_running_gate(copy(tools)) do
            KG.serve(force = true, tools = tools)
            @test toolnames() == ["host_a", "host_b"]
        end
    end

    @testset "two independent extensions both survive" begin
        with_running_gate([KG.GateTool("host_a", () -> "a")]) do
            KG.serve(force = true, tools = [KG.GateTool("ext_one", () -> 1)])
            KG.serve(force = true, tools = [KG.GateTool("ext_two", () -> 2)])
            # Neither extension can see the other; before the merge the second erased
            # the first, which is the case ReactantNitro's gate extension documents as
            # unfixable from the extension side.
            @test toolnames() == ["host_a", "ext_one", "ext_two"]
        end
    end

    @testset "an auto-derived namespace leaves the incumbent one alone" begin
        with_running_gate([KG.GateTool("host_a", () -> "a")]; namespace = "incumbent_ns") do
            KG.serve(force = true, tools = [KG.GateTool("ext_x", () -> "x")])
            # The caller named no namespace, so `_serve` derived one from the active
            # project. Adopting it would rename every incumbent tool at the MCP layer on
            # behalf of a caller that never asked.
            @test KG._SESSION_NAMESPACE[] == "incumbent_ns"
        end
    end

    @testset "an explicit namespace still re-labels the gate" begin
        with_running_gate([KG.GateTool("host_a", () -> "a")]; namespace = "incumbent_ns") do
            KG.serve(force = true, tools = [KG.GateTool("ext_x", () -> "x")],
                     namespace = "chosen_ns")
            @test KG._SESSION_NAMESPACE[] == "chosen_ns"
        end
    end

end

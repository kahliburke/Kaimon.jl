using Test
using KaimonGate

# A stand-in for the parts of Revise the gate reads: the queue of (pkgdata, file) pairs
# awaiting revision, its lock, and `basedir`. Here a pkgdata is just its directory.
module FakeRevise
const revision_queue = Set{Tuple{String,String}}()
const revise_lock = ReentrantLock()
basedir(pkgdata::String) = pkgdata
end

module OldRevise end   # a Revise without a revision queue

@testset "revise_queue_mtime" begin
    @test KaimonGate.revise_queue_mtime(OldRevise) === nothing
    @test KaimonGate.revise_queue_mtime(FakeRevise) == 0.0

    dir = mktempdir()
    a = joinpath(dir, "a.jl")
    b = joinpath(dir, "b.jl")
    write(a, "a")
    write(b, "b")
    push!(FakeRevise.revision_queue, (dir, "a.jl"), (dir, "b.jl"))
    @test KaimonGate.revise_queue_mtime(FakeRevise) == max(mtime(a), mtime(b))

    # A queued file that no longer exists does not hide the others.
    push!(FakeRevise.revision_queue, (dir, "gone.jl"))
    @test KaimonGate.revise_queue_mtime(FakeRevise) == max(mtime(a), mtime(b))

    empty!(FakeRevise.revision_queue)
    @test KaimonGate.revise_queue_mtime(FakeRevise) == 0.0
end

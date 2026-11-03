# ── Confining agents' processes ───────────────────────────────────────────────
# Under a policy (`KAIMON_CONFINE_POLICY`, a file of `deny`/`allow`/`write`/`unset` lines), an agent's
# process and everything it starts can read all but the denied paths and write only its own: its
# working directory, the CLI's state and a temporary directory. Enforced by the kernel (Landlock,
# through deps/confine/kaimon-confine.c), so it holds for every backend's own file and shell tools
# alike, which a tool-call check cannot. Linux only; elsewhere a policy is not applied. An agent run
# in-process (Ollama, vmlx) is not a process of its own and is not confined.

const CONFINE_SOURCE = normpath(joinpath(@__DIR__, "..", "deps", "confine", "kaimon-confine.c"))

"""
    Confinement(; write = String[], allow = String[])

What an agent may write and read beyond the policy: its own folders, and files inside denied ones
(a document it is to read, kept where the policy hides).
"""
Base.@kwdef struct Confinement
    write::Vector{String} = String[]
    allow::Vector{String} = String[]
end

"The policy file agents are confined by, or `nothing` when they are not (no policy, or not Linux)."
function confine_policy()
    p = get(ENV, "KAIMON_CONFINE_POLICY", "")
    return isempty(p) || !Sys.islinux() ? nothing : p
end

"""
    confine_launcher() -> String

The `kaimon-confine` launcher: `KAIMON_CONFINE` when set, else built from its source with the C
compiler on first use, into Kaimon's cache under the source's hash.
"""
function confine_launcher()
    exe = get(ENV, "KAIMON_CONFINE", "")
    isempty(exe) || return exe
    exe = joinpath(kaimon_cache_dir(), "confine", bytes2hex(sha256(read(CONFINE_SOURCE)))[1:16], "kaimon-confine")
    isfile(exe) && return exe
    compilers = filter(!isnothing, Sys.which.(["cc", "gcc", "clang"]))
    isempty(compilers) && error("Confining agents needs a C compiler to build $(basename(CONFINE_SOURCE)) (or KAIMON_CONFINE set to a built one)")
    mkpath(dirname(exe))
    tmp = "$exe.$(getpid())"
    run(`$(first(compilers)) -O2 -o $tmp $CONFINE_SOURCE`)
    mv(tmp, exe; force = true)
    return exe
end

"""
    confine(cmd, c::Confinement; state = String[]) -> Cmd

`cmd` run through the launcher under the policy, able to write also `c.write` and `state` (the CLI's
own state) and to read `c.allow`; `cmd` itself when there is no policy. Folders to write are made
first, since a path that does not exist is not granted.
"""
function confine(cmd::Cmd, c::Confinement; state::AbstractVector{<:AbstractString} = String[])
    policy = confine_policy()
    policy === nothing && return cmd
    args = [confine_launcher(), "--policy", policy]
    for w in vcat(c.write, state)
        ispath(w) || mkpath(w)
        push!(args, "--write", w)
    end
    for a in c.allow
        push!(args, "--allow", a)
    end
    return Cmd(Cmd([args; "--"; cmd.exec]); env = cmd.env, dir = cmd.dir, ignorestatus = cmd.ignorestatus)
end

"The temporary directory of confined agent `id` (its `TMPDIR`), removed when the agent closes."
confine_tmp(id::AbstractString) = joinpath(kaimon_cache_dir(), "agents", "$id.tmp")

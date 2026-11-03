# ── Confining agents' processes ───────────────────────────────────────────────
# Under a policy (`KAIMON_CONFINE_POLICY`, a file of `deny`/`allow`/`write`/`unset` lines), an agent's
# process and everything it starts can read all but the denied paths and write only its own: its
# working directory, the CLI's state and a temporary directory. Enforced by the kernel (Landlock,
# through the launcher in confine_launcher.jl), so it holds for every backend's own file and shell
# tools alike, which a tool-call check cannot. Linux only; elsewhere a policy is not applied. An agent
# run in-process (Ollama, vmlx) is not a process of its own and is not confined.

include("confine_launcher.jl")
const CONFINE_SCRIPT = joinpath(@__DIR__, "confine_launcher.jl")

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

The `kaimon-confine` launcher: `KAIMON_CONFINE` when set, else a script in Kaimon's cache that runs
confine_launcher.jl with this Julia, on one thread (Landlock restricts the thread that asks) and
compiling nothing, so it starts quickly. Named by its contents, so another Julia or Kaimon gets its own.
"""
function confine_launcher()
    exe = get(ENV, "KAIMON_CONFINE", "")
    isempty(exe) || return exe
    q(s) = "'" * replace(s, "'" => "'\\''") * "'"
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    script = "#!/bin/sh\n# Runs a command confined by Landlock: see Kaimon's confine_launcher.jl.\n" *
             "exec $(q(julia)) -t1 --startup-file=no --history-file=no -O0 --compile=min $(q(CONFINE_SCRIPT)) \"\$@\"\n"
    exe = joinpath(kaimon_cache_dir(), "confine", bytes2hex(sha256(script))[1:16], "kaimon-confine")
    isfile(exe) && return exe
    mkpath(dirname(exe))
    tmp = "$exe.$(getpid())"
    write(tmp, script)
    chmod(tmp, 0o755)
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

using ReTest
using Kaimon

# The launcher's rules are worked out the same on every Unix (`--dry-run`); only Linux applies them.
@testset "Confining agents' processes" begin
    cmd = setenv(`echo hi`, ["A=1"]; dir = tempdir())

    @testset "without a policy a command runs as it is" begin
        withenv("KAIMON_CONFINE_POLICY" => nothing) do
            @test Kaimon.confine_policy() === nothing
            @test Kaimon.confine(cmd, Kaimon.Confinement(; write = ["/x"])).exec == cmd.exec
        end
    end

    Sys.iswindows() && return
    launcher = try Kaimon.confine_launcher() catch; nothing end
    launcher === nothing && return                     # no C compiler here

    @testset "everything is readable but the denied paths" begin
        root = realpath(mktempdir())
        home = joinpath(root, "home", "svc")
        for d in ("secret", "public", "agents/mine", "agents/other", "data/pdfs")
            mkpath(joinpath(home, d))
        end
        touch(joinpath(home, "data", "pdfs", "p.pdf"))
        touch(joinpath(home, ".profile"))
        symlink(joinpath(home, "secret"), joinpath(home, "into-secret"))
        policy = joinpath(root, "policy")
        write(policy, """
            # what agents may not read
            deny $home/secret
            deny $home/agents
            deny $home/data
            """)
        rules = readlines(`$launcher --dry-run --policy $policy --allow $home/data/pdfs/p.pdf --write $home/agents/mine -- true`)
        reads = Set(chopprefix(r, "read ") for r in rules if startswith(r, "read "))
        writes = Set(chopprefix(r, "write ") for r in rules if startswith(r, "write "))
        @test joinpath(home, "public") in reads && joinpath(home, ".profile") in reads
        @test !any(r -> startswith(r, joinpath(home, "secret")) || startswith(r, joinpath(home, "agents")), reads)
        @test joinpath(home, "data", "pdfs", "p.pdf") in reads                 # allowed inside a denied folder
        @test !(joinpath(home, "data") in reads)
        @test !(joinpath(home, "into-secret") in reads)                        # a link is not a way in
        @test writes == Set([joinpath(home, "agents", "mine"), "/dev/null"])
        @test last(rules) == "run true"
    end

    @testset "a command is wrapped in the launcher under a policy" begin
        policy = tempname()
        write(policy, "deny /nonexistent\n")
        withenv("KAIMON_CONFINE_POLICY" => policy, "KAIMON_CONFINE" => launcher) do
            if Sys.islinux()
                w = mktempdir()
                c = Kaimon.confine(cmd, Kaimon.Confinement(; write = [w]); state = [joinpath(w, "state")])
                @test c.exec[1:3] == [launcher, "--policy", policy]
                @test c.exec[end-1:end] == ["echo", "hi"] && "--" in c.exec
                @test isdir(joinpath(w, "state"))                              # made, so it can be granted
                @test c.env == cmd.env && c.dir == cmd.dir
            else
                @test Kaimon.confine_policy() === nothing                      # Landlock is Linux's
                @test Kaimon.confine(cmd, Kaimon.Confinement()).exec == cmd.exec
            end
        end
    end

    @testset "where confined ACP agents keep their state" begin
        env = Dict("CODEX_HOME" => "/c", "XDG_CONFIG_HOME" => "/session")
        @test Kaimon._acp_state_dirs(["codex-acp"], env) == ["/c"]
        @test joinpath("/session", "opencode") in Kaimon._acp_state_dirs(["opencode", "acp"], env)
        @test Kaimon._acp_state_dirs(["something-else"], env) == String[]
    end

    if Sys.islinux() && parse(Int, readchomp(`$launcher --check`)) > 0
        @testset "the kernel holds a confined process to its rules" begin
            root = realpath(mktempdir())
            mkpath(joinpath(root, "secret")); mkpath(joinpath(root, "work"))
            write(joinpath(root, "secret", "k"), "hidden")
            confined(script) = success(`$launcher --deny $root/secret --write $root/work --unset SECRET -- sh -c $script`)
            @test !confined("cat $root/secret/k")
            @test confined("echo x > $root/work/f") && read(joinpath(root, "work", "f"), String) == "x\n"
            @test !confined("echo x > $root/elsewhere")
            @test withenv(() -> confined("test -z \"\$SECRET\""), "SECRET" => "s")
        end
    end
end

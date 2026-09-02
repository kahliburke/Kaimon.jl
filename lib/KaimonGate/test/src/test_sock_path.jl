using Test
using KaimonGate

# ── IPC socket path length ────────────────────────────────────────────────────
#
# `sun_path` is 104 bytes on macOS/BSD and 108 on Linux, NUL included. Over the
# limit, ZMQ's `bind` reports only "File name too long". (#84)

if Sys.iswindows()
    @info "Skipping IPC socket path tests: no IPC transport on Windows"
else
    @testset "IPC socket path length" begin
        limit = KaimonGate._SUN_PATH_MAX
        sid = string(Base.UUID(rand(UInt128)))
        # sock_dir() appends "kaimon/sock"; the stream socket has the longer name.
        overhead = length("/kaimon/sock") + length("/$(sid)-stream.sock")

        # Base must be short enough to leave room; the default temp dir on macOS
        # already exceeds the whole budget.
        mktempdir("/tmp") do tmp
            pad(total) = tmp * repeat("d", total - length(tmp))

            fits = pad(limit - 1 - overhead)
            over = fits * "d"

            withenv("XDG_CACHE_HOME" => fits) do
                @test KaimonGate._check_ipc_path_length(sid) === nothing
            end
            withenv("XDG_CACHE_HOME" => over) do
                @test_throws ArgumentError KaimonGate._check_ipc_path_length(sid)
            end

            # The message has to name the cause; that is the whole point.
            msg = withenv("XDG_CACHE_HOME" => over) do
                try
                    KaimonGate._check_ipc_path_length(sid)
                    ""
                catch e
                    sprint(showerror, e)
                end
            end
            @test occursin("XDG_CACHE_HOME", msg)
            @test occursin(string(limit - 1), msg)
        end
    end
end

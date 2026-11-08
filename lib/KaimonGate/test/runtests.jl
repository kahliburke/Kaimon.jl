# Isolate the cache/socket directory for the whole suite, the way Kaimon's own runtests.jl
# does. Several files here bind REAL gate sockets and write discovery metadata under
# `sock_dir()`. Unisolated that is the developer's live `~/.cache/kaimon/sock`, where a
# running Kaimon is discovering sessions and reaping stale ones — so it would delete a
# metadata file out from under a test that had just written it, intermittently and only on a
# machine with a gate running. `_gate_cache_dir` reads these at runtime, so setting them here
# is enough.
let cache = mktempdir()
    ENV["XDG_CACHE_HOME"] = cache                 # Unix
    Sys.iswindows() && (ENV["LOCALAPPDATA"] = cache)
end

using SafeTestsets

# KAIMON_GATE_OWNER_WAKE=1 runs the whole suite with the event-driven message loop, including the
# tests that start a loop without `serve` (which is where the setting is otherwise resolved).
import KaimonGate
let ow = tryparse(Bool, get(ENV, "KAIMON_GATE_OWNER_WAKE", ""))
    ow === nothing || (KaimonGate._OWNER_WAKE_ON[] = ow)
end

@safetestset "Aqua" include("src/test_aqua.jl")
@safetestset "Precompile directives" include("src/test_precompile.jl")
@safetestset "Socket path length" include("src/test_sock_path.jl")
@safetestset "Environment settings" include("src/test_env_settings.jl")
@safetestset "Service request" include("src/test_service_request.jl")
@safetestset "Type metadata" include("src/test_type_meta.jl")
@safetestset "Value coercion" include("src/test_coercion.jl")
@safetestset "Tool dispatch" include("src/test_dispatch.jl")
@safetestset "Source docstring" include("src/test_source_docstring.jl")
@safetestset "Message handler" include("src/test_handle_message.jl")
@safetestset "Loop supervision" include("src/test_loop_supervision.jl")
@safetestset "Socket wait" include("src/test_socket_wait.jl")
@safetestset "SIGTERM exit" include("src/test_sigterm_exit.jl")
@safetestset "Capture race" include("src/test_capture_race.jl")
@safetestset "Stream guard" include("src/test_stream_guard.jl")
@safetestset "Concurrent eval" include("src/test_eval_concurrency.jl")
@safetestset "Request id forwarding" include("src/test_request_id_forwarding.jl")
@safetestset "Debug breakpoint" include("src/test_debug.jl")
@safetestset "ZMQ integration" include("src/test_integration.jl")
@safetestset "CURVE transport" include("src/test_curve.jl")
@safetestset "Restart replay" include("src/test_restart_replay.jl")

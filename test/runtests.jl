# Isolate the whole suite's cache/socket directory so tests can NEVER touch a live
# Kaimon's ~/.cache/kaimon (sockets, sessions.json, analytics DB). call_tool_tests'
# start!()/stop!() otherwise bind and then rm the SHARED kaimon-service.sock at the
# real path, killing a running TUI/server's service endpoint mid-test-run. Both the
# gate sock_dir() and the server cache dir honor these at runtime, so setting them
# before anything loads Kaimon redirects all of it into a throwaway tempdir.
let cache = mktempdir()
    ENV["XDG_CACHE_HOME"] = cache                 # Unix
    Sys.iswindows() && (ENV["LOCALAPPDATA"] = cache)
end

using ReTest

# Include the tests module (registers all testsets)
include("KaimonTests.jl")
using .KaimonTests

# Run all tests with ReTest
if isempty(ARGS)
    retest()
else
    retest(ARGS[1])
end
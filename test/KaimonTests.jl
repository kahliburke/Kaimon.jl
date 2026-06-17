module KaimonTests

using ReTest

# Include all test files
include("security_tests.jl")
include("server_tests.jl")
include("session_tests.jl")
include("call_tool_tests.jl")
include("reflection_tools_tests.jl")
include("generate_tests.jl")
include("ast_stripping_tests.jl")
include("ex_quiet_error_tests.jl")
include("version_tests.jl")
include("qdrant_indexer_tests.jl")
include("fts_index_tests.jl")
include("session_status_tests.jl")
include("session_spawn_loadpath_tests.jl")
include("resources_prompts_tests.jl")
include("tui_analytics_tests.jl")
include("test_output_parser_tests.jl")
include("gate_async_tests.jl")
include("tcp_stale_session_tests.jl")
include("test_runner_tests.jl")
include("agent_tests.jl")
include("rate_governor_tests.jl")
include("service_endpoint_tests.jl")
include("ollama_backend_tests.jl")
include("zmq_socket_concurrency_tests.jl")
include("request_channel_tests.jl")
include("xpub_presence_tests.jl")
include("projects_config_tests.jl")

end # module

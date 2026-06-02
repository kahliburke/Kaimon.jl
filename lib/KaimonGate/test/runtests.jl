using SafeTestsets

@safetestset "Aqua" include("src/test_aqua.jl")
@safetestset "Type metadata" include("src/test_type_meta.jl")
@safetestset "Value coercion" include("src/test_coercion.jl")
@safetestset "Tool dispatch" include("src/test_dispatch.jl")
@safetestset "Message handler" include("src/test_handle_message.jl")
@safetestset "ZMQ integration" include("src/test_integration.jl")

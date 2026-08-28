# Compile the normal startup path into the package image. These signatures cover
# serve() resolving its defaults and forwarding them to _serve without starting
# sockets or creating runtime state during package precompilation.
precompile(serve, ())

const _SERVE_KWARGS_TYPE = NamedTuple{
    (
        :name,
        :session_id,
        :force,
        :tools,
        :namespace,
        :allow_mirror,
        :allow_restart,
        :spawned_by,
        :on_shutdown,
        :infiltrator,
        :mode,
        :host,
        :port,
        :stream_port,
        :curve,
        :server_secret,
        :allow_any,
        :allowed_clients,
        :discoverable,
    ),
    Tuple{
        String,
        Nothing,
        Bool,
        Vector{GateTool},
        String,
        Bool,
        Bool,
        String,
        Nothing,
        Bool,
        Symbol,
        String,
        Int,
        Int,
        Bool,
        Nothing,
        Bool,
        Vector{String},
        Bool,
    },
}
precompile(Core.kwcall, (_SERVE_KWARGS_TYPE, typeof(_serve)))

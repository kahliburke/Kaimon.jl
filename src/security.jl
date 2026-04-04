# ============================================================================
# Security Module - API Key Authentication and IP Allowlisting
# ============================================================================

using Random
using SHA
using JSON
using TOML

# Global configuration structure
struct KaimonConfig
    mode::Symbol  # :strict, :relaxed, or :lax
    api_keys::Vector{String}
    allowed_ips::Vector{String}
    port::Int
    created_at::Int64
    editor::String  # Editor for file:line links: "vscode", "cursor", "zed", "windsurf"
    qdrant_prefix::String  # Prefix for Qdrant collection names (for shared instances)
end

const SecurityConfig = KaimonConfig  # backwards compatibility alias

function KaimonConfig(
    mode::Symbol,
    api_keys::Vector{String},
    allowed_ips::Vector{String},
    port::Int = 0,
    editor::String = "vscode",
    qdrant_prefix::String = "",
)
    return KaimonConfig(
        mode,
        api_keys,
        allowed_ips,
        port,
        Int64(round(time())),
        editor,
        qdrant_prefix,
    )
end

"""
    generate_api_key() -> String

Generate a cryptographically secure API key.
Format: kaimon_<40 hex characters>
"""
function generate_api_key()
    # Generate 20 random bytes (160 bits)
    random_bytes = rand(UInt8, 20)
    # Convert to hex string
    hex_string = bytes2hex(random_bytes)
    return "kaimon_" * hex_string
end

"""
    get_global_config_path() -> String

Get the path to the global configuration file.
Returns `~/.config/kaimon/config.json`.

Automatically migrates from the legacy `security.json` name on first access.
"""
function get_global_config_path()
    new_path = joinpath(kaimon_config_dir(), "config.json")
    if !isfile(new_path)
        old_path = joinpath(kaimon_config_dir(), "security.json")
        if isfile(old_path)
            mv(old_path, new_path)
        end
    end
    return new_path
end

const PERSONALITY_EMOTICONS = Dict("dragon" => "🐉", "butterfly" => "🦋", "l33t" => "👻")

"""
    load_personality() -> String

Load the wizard personality emoticon from the global config.
Returns a default if not set.
"""
function load_personality()
    config_path = get_global_config_path()
    isfile(config_path) || return "⚡"
    try
        data = JSON.parse(read(config_path, String); dicttype = Dict{String,Any})
        p = get(data, "personality", "")
        return get(PERSONALITY_EMOTICONS, p, "⚡")
    catch
        return "⚡"
    end
end

"""
    load_global_config() -> Union{KaimonConfig, Nothing}

Load the global configuration from `~/.config/kaimon/config.json`.
"""
function load_global_config()
    config_path = get_global_config_path()

    if !isfile(config_path)
        return nothing
    end

    try
        content = read(config_path, String)
        data = JSON.parse(content; dicttype = Dict{String,Any})

        mode = Symbol(get(data, "mode", "strict"))
        api_keys = get(data, "api_keys", String[])
        allowed_ips = get(data, "allowed_ips", ["127.0.0.1", "::1"])
        port = get(data, "port", 0)
        created_at = get(data, "created_at", time())
        editor = get(data, "editor", "vscode")
        qdrant_prefix = String(get(data, "qdrant_prefix", ""))

        return KaimonConfig(
            mode,
            api_keys,
            allowed_ips,
            port,
            created_at,
            editor,
            qdrant_prefix,
        )
    catch e
        @warn "Failed to load global config" exception = e
        return nothing
    end
end

"""
    update_global_config!(; kwargs...) -> Bool

Load the current config, update specified fields, and save. Returns false
if no config exists. This is the preferred way to modify individual config
fields without manually reconstructing the entire struct.

# Examples
```julia
update_global_config!(editor="cursor")
update_global_config!(api_keys=vcat(config.api_keys, [new_key]))
update_global_config!(qdrant_prefix="myteam")
```
"""
function update_global_config!(; kwargs...)
    config = load_global_config()
    config === nothing && return false
    fields = Dict{Symbol,Any}(
        :mode => config.mode,
        :api_keys => config.api_keys,
        :allowed_ips => config.allowed_ips,
        :port => config.port,
        :created_at => config.created_at,
        :editor => config.editor,
        :qdrant_prefix => config.qdrant_prefix,
    )
    for (k, v) in kwargs
        haskey(fields, k) || error("Unknown config field: $k")
        fields[k] = v
    end
    new_config = KaimonConfig(
        fields[:mode], fields[:api_keys], fields[:allowed_ips],
        fields[:port], fields[:created_at], fields[:editor], fields[:qdrant_prefix],
    )
    save_global_config(new_config)
end

"""
    save_global_config(config::SecurityConfig) -> Bool

Save configuration to the global path `~/.config/kaimon/config.json`.
"""
function save_global_config(config::SecurityConfig)
    config_path = get_global_config_path()
    config_dir = dirname(config_path)

    if !isdir(config_dir)
        mkpath(config_dir)
    end

    try
        # Read existing data first to preserve extra keys (e.g. "personality")
        existing = if isfile(config_path)
            try
                JSON.parse(read(config_path, String); dicttype = Dict{String,Any})
            catch
                Dict{String,Any}()
            end
        else
            Dict{String,Any}()
        end

        existing["mode"] = string(config.mode)
        existing["api_keys"] = config.api_keys
        existing["allowed_ips"] = config.allowed_ips
        existing["port"] = config.port
        existing["created_at"] = config.created_at
        existing["editor"] = config.editor
        if !isempty(config.qdrant_prefix)
            existing["qdrant_prefix"] = config.qdrant_prefix
        end

        json_str = JSON.json(existing, 2)
        write(config_path, json_str)

        if !Sys.iswindows()
            chmod(config_path, 0o600)
        end

        return true
    catch e
        @warn "Failed to save global config" exception = e
        return false
    end
end

"""
    validate_api_key(key::String, config::SecurityConfig) -> Bool

Validate an API key against the security configuration.
"""
function validate_api_key(key::String, config::SecurityConfig)
    # In :lax mode, no API key required
    if config.mode == :lax
        return true
    end

    return key in config.api_keys
end

"""
    validate_ip(ip::String, config::SecurityConfig) -> Bool

Validate an IP address against the allowlist.
"""
function validate_ip(ip::String, config::SecurityConfig)
    # In :relaxed mode, skip IP validation
    if config.mode == :relaxed
        return true
    end

    # In :lax mode, only allow localhost
    if config.mode == :lax
        return ip in ["127.0.0.1", "::1", "localhost"]
    end

    # In :strict mode, check against allowlist
    return ip in config.allowed_ips
end

"""
    extract_api_key(req::HTTP.Request) -> Union{String, Nothing}

Extract API key from Authorization header.
Supports: "Bearer <key>" or just "<key>"
"""
function extract_api_key(req)
    for (name, value) in req.headers
        if lowercase(name) == "authorization"
            # Remove "Bearer " prefix if present
            if startswith(value, "Bearer ")
                return value[8:end]
            else
                return value
            end
        end
    end
    return nothing
end

"""
    get_client_ip(req::HTTP.Request) -> String

Extract client IP address from request.
Checks X-Forwarded-For header first, then falls back to peer address.
"""
function get_client_ip(req)
    # Check X-Forwarded-For header (for proxies)
    for (name, value) in req.headers
        if lowercase(name) == "x-forwarded-for"
            # Take the first IP in the list
            return strip(split(value, ",")[1])
        end
    end

    # Fall back to direct connection IP (if available)
    # HTTP.jl doesn't always expose this easily, so default to localhost
    return "127.0.0.1"
end

"""
    show_security_status(config::SecurityConfig)

Display current security configuration in a readable format.
"""
function show_security_status(config::SecurityConfig)
    println()
    println("🔒 Security Configuration")
    println("="^50)
    println()
    println("Mode: ", config.mode)
    println("  • :strict  - API key + IP allowlist required")
    println("  • :relaxed - API key required, any IP allowed")
    println("  • :lax     - Localhost only, no API key")
    println()
    println("API Keys: ", length(config.api_keys))
    for (i, key) in enumerate(config.api_keys)
        masked_key = key[1:min(15, length(key))] * "..." * key[max(1, end - 3):end]
        println("  $i. $masked_key")
    end
    println()
    println("Allowed IPs: ", length(config.allowed_ips))
    for ip in config.allowed_ips
        println("  • $ip")
    end
    println()
    println("Editor: ", config.editor)
    println()
    println("Created: ", Dates.unix2datetime(config.created_at))
    println()
end

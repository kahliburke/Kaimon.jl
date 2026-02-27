using Documenter
using DocumenterVitepress
using Kaimon

# Copy assets into VitePress public/assets/.
# In CI (KAIMON_ASSET_BASE set) all assets are served from the docs-assets
# GitHub Release, so nothing needs to be copied.
# Locally, copy everything except .tach and .svg files.
let public_assets = joinpath(@__DIR__, "src", "public", "assets")
    src_dir = joinpath(@__DIR__, "src", "assets")
    if isdir(src_dir) && !haskey(ENV, "KAIMON_ASSET_BASE")
        mkpath(public_assets)
        for f in readdir(src_dir; join = false)
            src = joinpath(src_dir, f)
            isfile(src) || continue
            endswith(f, ".tach") && continue
            endswith(f, ".svg") && continue
            cp(src, joinpath(public_assets, f); force = true)
        end
    end
end

# Clean stale build directory to avoid ENOTEMPTY errors from Documenter
let build_dir = joinpath(@__DIR__, "build")
    for attempt = 1:3
        isdir(build_dir) || break
        try
            rm(build_dir; recursive = true, force = true)
        catch
            attempt == 3 && rethrow()
            sleep(0.5)
        end
    end
end

# Step 1: Generate markdown only — skip VitePress so we can patch config first
makedocs(;
    sitename = "Kaimon.jl",
    modules = [Kaimon],
    remotes = nothing,
    format = DocumenterVitepress.MarkdownVitepress(;
        repo = "https://github.com/kahliburke/Kaimon.jl",
        devurl = "dev",
        deploy_url = "kahliburke.github.io/Kaimon.jl",
        build_vitepress = false,
    ),
    pages = [
        "Home" => "index.md",
        "Installation" => "installation.md",
        "Getting Started" => "getting-started.md",
        "Guide" => [
            "Usage" => "usage.md",
            "Architecture" => "architecture.md",
            "Tool Catalog" => "tools.md",
            "The Gate" => "gate.md",
            "Sessions" => "sessions.md",
            "Semantic Search" => "search.md",
            "Security" => "security.md",
            "VS Code" => "vscode.md",
            "Configuration" => "configuration.md",
        ],
        "API Reference" => "api.md",
    ],
    warnonly = [:missing_docs, :docs_block, :cross_references],
)

# Step 2: Fix &amp; in markdown headings before VitePress sees them
let documenter_out = joinpath(@__DIR__, "build", ".documenter")
    for (root, dirs, files) in walkdir(documenter_out)
        for f in files
            endswith(f, ".md") || continue
            path = joinpath(root, f)
            content = read(path, String)
            fixed = replace(content, r"^(#{1,6}\s.*)&amp;(.*)"m => s"\1&\2")
            fixed != content && write(path, fixed)
        end
    end
end

# Step 3: Patch VitePress config.mts base path for deploy subfolder
# (e.g. /Kaimon.jl/dev/ or /Kaimon.jl/previews/PR42/)
let config_path =
    joinpath(@__DIR__, "build", ".documenter", ".vitepress", "config.mts")
    if isfile(config_path)
        deploy_decision = Documenter.deploy_folder(
            Documenter.auto_detect_deploy_system();
            repo = "github.com/kahliburke/Kaimon.jl",
            devbranch = "main",
            devurl = "dev",
            push_preview = true,
        )
        folder = deploy_decision.subfolder
        base = "/Kaimon.jl/$(folder)$(isempty(folder) ? "" : "/")"
        config = read(config_path, String)
        config = replace(config, r"const BASE = '[^']*'" => "const BASE = '$(base)'")
        write(config_path, config)
    end
end

# Step 4: Build VitePress and deploy
DocumenterVitepress.build_docs(joinpath(@__DIR__, "build"))

deploydocs(;
    repo = "github.com/kahliburke/Kaimon.jl",
    target = "build/.documenter/.vitepress/dist",
    devbranch = "main",
    push_preview = true,
)

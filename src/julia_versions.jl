# ── Julia version resolution (juliaup) ────────────────────────────────────────
# A project can name the Julia it needs portably, as `[launch] julia_version = "1.12.6"`,
# instead of a `julia_bin` path that only exists on one contributor's machine. That makes the
# requirement checked-in and shareable, which an absolute path can never be.
#
# Resolution reads juliaup's own `juliaup.json` rather than shelling out to `juliaup` or
# passing `julia +1.12.6`. Both call sites build an argv where `+channel` would have to be the
# first argument, and juliaup's shim is not guaranteed to be on a spawned process's PATH.
# juliaup records the binary path of every install, including the macOS app-bundle layout, so
# reading the file is both cheaper and more portable than either alternative.

"""
    juliaup_dir() -> String

The directory juliaup keeps its installs and `juliaup.json` in, honoring
`JULIAUP_DEPOT_PATH`. The path is returned whether or not it exists.
"""
function juliaup_dir()
    custom = strip(get(ENV, "JULIAUP_DEPOT_PATH", ""))
    isempty(custom) || return expanduser(String(custom))
    return joinpath(homedir(), ".julia", "juliaup")
end

"""Path to juliaup's state file, whether or not it exists."""
juliaup_config_path() = joinpath(juliaup_dir(), "juliaup.json")

"""
    juliaup_installed_julias() -> Vector{Tuple{VersionNumber,String}}

Every Julia juliaup has installed, as `(version, binary_path)`, newest first. Empty when
juliaup isn't in use, its state file is unreadable, or none of the recorded binaries exist.
"""
function juliaup_installed_julias()
    out = Tuple{VersionNumber,String}[]
    path = juliaup_config_path()
    isfile(path) || return out
    data = try
        JSON.parsefile(path)
    catch e
        @debug "Could not read juliaup config" path exception = e
        return out
    end
    raw = get(data, "InstalledVersions", nothing)
    raw isa AbstractDict || return out
    root = juliaup_dir()
    for (key, info) in raw
        info isa AbstractDict || continue
        # Keys carry juliaup's platform suffix ("1.12.7+0.aarch64.apple.darwin14"); the
        # version is the part before it.
        v = tryparse(VersionNumber, first(split(String(key), '+')))
        v === nothing && continue
        # juliaup records BinaryPath because the layout is platform-specific (on macOS the
        # binary sits inside an .app bundle). Fall back to the conventional layout only if
        # that key is missing.
        rel = get(info, "BinaryPath", nothing)
        bin = if rel isa AbstractString && !isempty(rel)
            normpath(joinpath(root, String(rel)))
        else
            p = String(get(info, "Path", ""))
            isempty(p) ? "" : normpath(joinpath(root, p, "bin", Sys.iswindows() ? "julia.exe" : "julia"))
        end
        (isempty(bin) || !isfile(bin)) && continue
        push!(out, (v, bin))
    end
    sort!(out; by = first, rev = true)
    return out
end

"""
    julia_version_matches(want::AbstractString, v::VersionNumber) -> Bool

Whether `want` designates `v`. A patch version ("1.12.6") must match exactly. A series
("1.12") matches any patch in it, so a project can pin the minor it supports without
naming a patch that will age out.
"""
function julia_version_matches(want::AbstractString, v::VersionNumber)
    parts = split(strip(String(want)), '.')
    # Parsed by hand rather than via VersionNumber: `tryparse(VersionNumber, "1.12")` succeeds
    # as 1.12.0, which would turn a series request into an exact-patch one.
    length(parts) in (2, 3) || return false
    major = tryparse(Int, parts[1])
    minor = tryparse(Int, parts[2])
    (major === nothing || minor === nothing) && return false
    (v.major == major && v.minor == minor) || return false
    length(parts) == 2 && return true
    patch = tryparse(Int, parts[3])
    return patch !== nothing && v.patch == patch
end

"""
    resolve_julia_binary(version::AbstractString) -> Union{String,Nothing}

The binary for `version`, or `nothing` when it isn't installed. The Julia running Kaimon is
matched first, so a project asking for the version already in use needs no juliaup at all.
"""
function resolve_julia_binary(version::AbstractString)
    want = strip(String(version))
    isempty(want) && return joinpath(Sys.BINDIR, "julia")
    julia_version_matches(want, VERSION) && return joinpath(Sys.BINDIR, "julia")
    for (v, bin) in juliaup_installed_julias()
        julia_version_matches(want, v) && return bin
    end
    return nothing
end

"""
    juliaup_command() -> Union{String,Nothing}

The `juliaup` executable, or `nothing` when it isn't installed. On Windows `Sys.which`
resolves a bare name only as `.exe`, so PATHEXT shims are looked up too.
"""
function juliaup_command()
    exe = Sys.which("juliaup")
    exe === nothing || return String(exe)
    return Sys.iswindows() ? _which_pathext("juliaup") : nothing
end

"""
    install_julia_version(version::AbstractString) -> (ok::Bool, output::String)

Run `juliaup add <version>`. Only ever called after the user has agreed to it: downloading a
Julia without asking is explicitly out of scope. Never throws; a failure comes back as
`(false, message)` with the combined output so the reason is reportable.
"""
function install_julia_version(version::AbstractString)
    exe = juliaup_command()
    exe === nothing && return (false, "juliaup is not installed")
    want = strip(String(version))
    isempty(want) && return (false, "no Julia version requested")
    try
        out = read(pipeline(`$exe add $want`; stderr = stdout), String)
        # `juliaup add` exits 0 for an already-installed channel, so success is confirmed by
        # the binary actually being resolvable rather than by the exit code alone.
        if resolve_julia_binary(want) === nothing
            return (false, isempty(strip(out)) ? "juliaup add $want reported no error, but $want is still not installed" : out)
        end
        return (true, out)
    catch e
        return (false, sprint(showerror, e))
    end
end

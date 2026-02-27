# ── Kaimon Logo Rendering ──────────────────────────────────────────────────────
#
# Loads the Kaimon logo PNG once, caches the pixel matrix, and provides
# _render_logo!(area, f; tick) for use in any Tachikoma view function.
#
# White/near-white pixels are composited out so the logo renders cleanly on
# dark terminal themes without a white background rectangle.
# ──────────────────────────────────────────────────────────────────────────────

import PNGFiles
import Tachikoma: PixelImage, load_pixels!, ColorRGB

const _LOGO_PATH = joinpath(@__DIR__, "assets", "kaimon_logo1.png")

# Cached pixel matrix — loaded once on first render.
const _LOGO_PIXELS = Ref{Union{Matrix{ColorRGB},Nothing}}(nothing)

function _load_logo_pixels()::Union{Matrix{ColorRGB},Nothing}
    isfile(_LOGO_PATH) || return nothing
    try
        raw = PNGFiles.load(_LOGO_PATH)   # Matrix{RGBA{N0f8}} or Matrix{RGB{N0f8}}
        h, w = size(raw)
        pixels = Matrix{ColorRGB}(undef, h, w)
        has_alpha = hasfield(eltype(raw), :alpha)
        for i = 1:h, j = 1:w
            px = raw[i, j]
            r_f = Float64(px.r)
            g_f = Float64(px.g)
            b_f = Float64(px.b)
            a_f = has_alpha ? Float64(px.alpha) : 1.0

            # Composite against black
            r_f *= a_f
            g_f *= a_f
            b_f *= a_f

            # Treat near-white as transparent (removes white background)
            lum = 0.299 * r_f + 0.587 * g_f + 0.114 * b_f
            if lum > 0.82
                pixels[i, j] = ColorRGB(0x00, 0x00, 0x00)
            else
                pixels[i, j] = ColorRGB(
                    round(UInt8, r_f * 255),
                    round(UInt8, g_f * 255),
                    round(UInt8, b_f * 255),
                )
            end
        end
        pixels
    catch e
        @warn "Kaimon: logo load failed" exception = e
        nothing
    end
end

function _get_logo_pixels()::Union{Matrix{ColorRGB},Nothing}
    if _LOGO_PIXELS[] === nothing
        _LOGO_PIXELS[] = _load_logo_pixels()
    end
    _LOGO_PIXELS[]
end

"""
    _render_logo!(area::Rect, f::Frame; tick::Int=0)

Render the Kaimon logo into `area` using `PixelImage`.
Does nothing if the logo file is missing or the area is too small.
"""
function _render_logo!(area::Rect, f::Frame; tick::Int = 0)
    area.width < 2 || area.height < 2 && return
    pixels = _get_logo_pixels()
    pixels === nothing && return
    img = PixelImage(area.width, area.height)
    load_pixels!(img, pixels)
    render(img, area, f; tick = tick)
end

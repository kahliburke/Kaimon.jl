# (Kaimon setup wizard — split into setup_wizard_*.jl; this one loads FIRST)
# ═══════════════════════════════════════════════════════════════════════════════
# Setup Wizard TUI — 3-Mode Animated Security Setup
#
# Tachikoma-based TUI wizard with Dragon, Butterfly, and Neuromancer personality
# modes. Collects security configuration and saves to ~/.config/kaimon/config.json.
# ═══════════════════════════════════════════════════════════════════════════════

# Additional Tachikoma imports not already brought in by tui.jl
import Tachikoma:
    BOX_ROUNDED,
    BigText,
    intrinsic_size,
    ProgressList,
    ProgressItem,
    TaskStatus,
    task_pending,
    task_running,
    task_done,
    PixelImage,
    load_pixels!

# ── ASCII Art ────────────────────────────────────────────────────────────────

const DRAGON_ASCII = raw"""
                                                     __----~~~~~~~~~~~------___
                                    .  .   ~~//====......          __--~ ~~
                    -.            \_|//     |||\\  ~~~~~~::::... /~
                 ___-==_       _-~o~  \/    |||  \\            _/~~-
         __---~~~.==~||\=_    -_--~/_-~|-   |\\   \\        _/~
     _-~~     .=~    |  \\-_    '-~7  /-   /  ||    \      /
   .~       .~       |   \\ -_    /  /-   /   ||      \   /
  /  ____  /         |     \\ ~-_/  /|- _/   .||       \ /
  |~~    ~~|--~~~~--_ \     ~==-/   | \~--===~~        .\
           '         ~-|      /|    |-~\~~       __--~~
                       |-~~-_/ |    |   ~\_   _-~            /\
                            /  \     \__   \/~                \__
                        _--~ _/ | .-~~____--~-/                  ~~==.
                       ((->/~   '.|||' -_|    ~~-/ ,              . _||
                                  -_     ~\      ~~---l__i__i__i--~~_/
                                  _-~-__   ~)  \--______________--~~
                                //.-~~~-~_--~- |-------~~~~~~~~
                                       //.-~~~--\
"""

const DRAGON_MOUTH_OPEN = raw"""
                                                     __----~~~~~~~~~~~------___
                                    .  .   ~~//====......          __--~ ~~
                    -.            \_|//     |||\\  ~~~~~~::::... /~
                 ___-==_       _-~O~  \/    |||  \\            _/~~-
         __---~~~.==~||\=_    - --~/_-~|-   |\\   \\        _/~
     _-~~     .=~    |  \\-_   <-/- > /-   /  ||    \      /
   .~       .~       |   \\ -_    /  /-   /   ||      \   /
  /  ____  /         |     \\ ~-_/  /|- _/   .||       \ /
  |~~    ~~|--~~~~--_ \     ~==-/   | \~--===~~        .\
           '         ~-|      /|    |-~\~~       __--~~
                       |-~~-_/ |    |   ~\_   _-~            /\
                            /  \     \__   \/~                \__
                        _--~ _/ | .-~~____--~-/                  ~~==.
                       ((->/~   '.|||' -_|    ~~-/ ,              . _||
                                  -_     ~\      ~~---l__i__i__i--~~_/
                                  _-~-__   ~)  \--______________--~~
                                //.-~~~-~_--~- |-------~~~~~~~~
                                       //.-~~~--\
"""

# Detect mouth position for fire particle emission.

function _detect_dragon_mouth()
    lines = split(DRAGON_ASCII, '\n')
    for (i, line) in enumerate(lines)
        idx = findfirst("'-~7", line)
        if idx !== nothing
            return (i, first(idx) + 2)
        end
    end
    return (7, 31)
end

# TUI-safe butterfly art (pure ASCII — no fullwidth/emoji chars that break set_string!)
const GENTLE_BUTTERFLY_ASCII = raw"""
                              .  *  .       _ " _
             _ " _          .  *  .  *    (_\|/_)
            (_\|/_)       *  .  *  .       (/|\)
     _ " _   (/|\)      .  *  .  *  .
    (_\|/_)           *              _ " _
     (/|\)    _ " _     *  .  *    (_\|/_)     _ " _
             (_\|/_)      .  *      (/|\)     (_\|/_)
              (/|\)     *  .  *  .             (/|\)
                      .  *  .  *  .
        _ " _       *  .  *  .  *  .  *    _ " _
       (_\|/_)        .  *  .  *  .       (_\|/_)
        (/|\)       *  .  *  .  *  .       (/|\)
                      .  *  .  *  .
     _ " _          *  .       .  *        _ " _
    (_\|/_)           .  *  .  *          (_\|/_)
     (/|\)              *  .  *            (/|\)

        *  .  You've got this!  .  *
            *  .  .  *  .  .  *
"""

# Motivational phrases for butterfly (gentle) intro animation
const MOTIVATIONAL_PHRASES = [
    "You're doing great!",
    "Security is self-care.",
    "One step at a time.",
    "Almost there!",
    "You've got this!",
    "Safe and sound.",
]

# Color palettes
const FIRE_COLORS = [196, 202, 208, 214, 220, 226, 220, 214, 208, 202]
const BUTTERFLY_COLORS = [219, 183, 147, 111, 75, 39, 75, 111, 147, 183]
const PASTEL_COLORS = [218, 225, 189, 195, 159, 153, 183, 219, 225, 189]
const WIZARD_COLORS = [33, 39, 45, 51, 87, 123, 159, 105, 69]
const NEURO_GREENS = [22, 28, 34, 40, 46, 82, 118, 154, 190, 226]

# Small companion art (first ~10 lines)
const DRAGON_PREVIEW_LINES = split(DRAGON_ASCII, '\n')[1:min(10, end)]
const BUTTERFLY_PREVIEW_LINES = split(GENTLE_BUTTERFLY_ASCII, '\n')[1:min(10, end)]

# Wizard companion art
const _WIZ_ART = raw"""
                      ____
                    .'* *.'
                 __/_*_*(_
                / _______ \
               _\_)/___\(_/_
              / _((\O O/))_ \
              \ \())(-)(()/ /
               ' \(((()))/ '
              / ' \)).))/ ' \
             / _ \ - | - /_  \
            (   ( .;''';. .'  )
            _\"__ /    )\ __"/_
              \/  \   ' /  \/
               .'  '...' ' )
                / /  |  \ \
               / .   .   . \
              /   .     .   \
             /   /   |   \   \
           .'   /    b    '.  '.
       _.-'    /     Bb     '-. '-._
   _.-'       |      BBb       '-.  '-.
  (________mrf\____.dBBBb.________)____)
  """

const _WIZ_B_ART = raw"""

   _ " _
  (_\|/_)
   (/|\)

"""

const COMPANION_WIZ = split(_WIZ_ART, '\n')
const COMPANION_WIZ_B = split(_WIZ_B_ART, '\n')


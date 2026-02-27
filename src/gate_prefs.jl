const PREF_GATE_MIRROR_REPL = "gate_mirror_repl"

"""
    get_gate_mirror_repl_preference() -> Bool

Return whether gate evaluations should mirror command/result text in the host REPL.
"""
function get_gate_mirror_repl_preference()
    val = @load_preference(PREF_GATE_MIRROR_REPL, false)
    return val === true
end

"""
    set_gate_mirror_repl_preference!(enabled::Bool) -> Bool

Persist host-REPL mirroring preference in LocalPreferences.toml.
"""
function set_gate_mirror_repl_preference!(enabled::Bool)
    @set_preferences!(PREF_GATE_MIRROR_REPL => enabled)
    return enabled
end

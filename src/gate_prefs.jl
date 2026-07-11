const PREF_GATE_MIRROR_REPL = "gate_mirror_repl"

"""
    get_gate_mirror_repl_preference() -> Bool

Return whether gate evaluations should mirror command/result text in the host REPL.
"""
function get_gate_mirror_repl_preference()
    val = @load_preference(PREF_GATE_MIRROR_REPL, true)
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

const PREF_GATE_PROMOTE_AFTER = "gate_promote_after"   # seconds; 0 = never promote

"""
    get_gate_promote_after_preference() -> Float64

Seconds a foreground eval may run before it's promoted to a background job. `0` means
never promote (the eval stays foreground until it finishes). Default 30s. Overridden by
the `KAIMON_GATE_PROMOTE_AFTER` env var in `_promote_after`.
"""
function get_gate_promote_after_preference()::Float64
    val = @load_preference(PREF_GATE_PROMOTE_AFTER, 30.0)
    return val isa Real ? max(0.0, Float64(val)) : 30.0
end

"""
    set_gate_promote_after_preference!(secs::Real) -> Float64

Persist the auto-background threshold (seconds; 0 = never) in LocalPreferences.toml.
"""
function set_gate_promote_after_preference!(secs::Real)::Float64
    s = max(0.0, Float64(secs))
    @set_preferences!(PREF_GATE_PROMOTE_AFTER => s)
    return s
end

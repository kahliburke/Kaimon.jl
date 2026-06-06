# ═══════════════════════════════════════════════════════════════════════════════
# RateGovernor — central admission control for agent turns
#
# The Kaimon server is the only place that sees *all* agent turns (crew, Slate,
# direct) — their concurrency, usage, and errors — so global API-rate governance
# lives here. Three coupled controls + token accounting, all behind one
# Condition's lock:
#
#   §5.1  concurrency cap   — a hard ceiling on in-flight turns. Backpressure:
#                             when full, admission BLOCKS (never drops).
#   §5.2  AIMD token rate   — a token bucket whose refill rate R self-tunes:
#                             multiplicative decrease on a rate-limit signal,
#                             additive increase over a clean window.
#   §5.4  retry/backoff     — an exponential-backoff schedule + a rate-limit
#                             classifier the caller applies per turn.
#   §5.5  tokens/min budget — rolling token volume from observed TurnEnded.usage;
#                             throttles admission as it approaches the budget.
#
# Feedback is fed from the agent event stream (see agent_session.jl `_start_relay!`):
#   record_turn_end!(total_tokens)  — usage accounting (§5.5)
#   note_rate_error!(retry_after)   — a rate-limited AgentError drives AIMD (§5.2)
#
# Admission wraps agent-turn dispatch in the service endpoint via with_admission.
# Decoupled from ACP/ZMQ on purpose — it speaks only Ints and Floats.
# ═══════════════════════════════════════════════════════════════════════════════
module RateGovernor

# Wall clock. Plain `time()` is fine in module code (the Date.now ban is only for
# workflow scripts); a turn outlives any clock skew we care about here.
_now() = time()

# ── Config (env, with conservative defaults; AIMD discovers the real ceiling) ──
Base.@kwdef struct Config
    max_concurrency::Int        = 4      # in-flight turns ceiling (backpressure)
    rate_rps::Float64           = 2.0    # initial / target refill rate R (req/s)
    rate_max::Float64           = 8.0    # R_max ceiling for AIMD recovery
    rate_min::Float64           = 0.25   # R_min floor
    rate_step::Float64          = 0.5    # additive increase per clean interval
    decrease_factor::Float64    = 0.5    # multiplicative decrease on a rate error
    bucket_capacity::Float64    = 8.0    # token-bucket burst capacity
    tokens_per_min::Float64     = 0.0    # tokens/min budget; 0 = disabled
    max_retries::Int            = 4      # per-turn rate-error retries
    recover_interval_s::Float64 = 20.0   # clean window before additive increase
    base_cooldown_s::Float64    = 5.0    # refill pause when retry_after is unknown
end

_envf(k, d) = (v = get(ENV, k, nothing); v === nothing ? d : something(tryparse(Float64, v), d))
_envi(k, d) = (v = get(ENV, k, nothing); v === nothing ? d : something(tryparse(Int, v), d))

"Build a Config from KAIMON_AGENT_* env vars, falling back to the defaults above."
function config_from_env()
    rmax = _envf("KAIMON_AGENT_RATE_MAX", 8.0)
    Config(
        max_concurrency    = _envi("KAIMON_AGENT_MAX_CONCURRENCY", 4),
        rate_rps           = _envf("KAIMON_AGENT_RATE_RPS", 2.0),
        rate_max           = rmax,
        rate_min           = _envf("KAIMON_AGENT_RATE_MIN", 0.25),
        rate_step          = _envf("KAIMON_AGENT_RATE_STEP", 0.5),
        bucket_capacity    = _envf("KAIMON_AGENT_RATE_BUCKET", rmax),  # default capacity = R_max
        tokens_per_min     = _envf("KAIMON_AGENT_TOKENS_PER_MIN", 0.0),
        max_retries        = _envi("KAIMON_AGENT_MAX_RETRIES", 4),
        recover_interval_s = _envf("KAIMON_AGENT_RECOVER_INTERVAL_S", 20.0),
    )
end

# ── State (all access under lock(s.cond)) ─────────────────────────────────────
mutable struct State
    cfg::Config
    in_flight::Int
    rate::Float64                              # current AIMD R
    tokens::Float64                            # token-bucket level
    last_refill::Float64
    paused_until::Float64                      # refill paused (cooldown) until t
    last_increase::Float64
    last_rate_error::Float64
    rate_errors::Int                           # cumulative
    usage_window::Vector{Tuple{Float64,Int}}   # (t, tokens) for the rolling minute
    cond::Threads.Condition                    # wakes waiters on release/error/timer
end

# One global governor — the server is the single point that sees all turns.
const STATE = Ref{Union{State,Nothing}}(nothing)

"(Re)initialize the global governor. Safe to call once at server start."
function init!(cfg::Config = config_from_env())
    now = _now()
    STATE[] = State(cfg, 0, cfg.rate_rps, cfg.bucket_capacity, now, 0.0, now, 0.0, 0,
                    Tuple{Float64,Int}[], Threads.Condition())
    return STATE[]
end

_state() = (s = STATE[]; s === nothing ? init!() : s)

const _WINDOW_S = 60.0   # tokens/min rolling window

# ── Internal helpers (caller holds the lock) ──────────────────────────────────
function _refill!(s::State, now::Float64)
    if now < s.paused_until        # cooldown: accrue nothing, but don't burst after
        s.last_refill = now
        return
    end
    dt = now - s.last_refill
    dt <= 0 && return
    s.tokens = min(s.cfg.bucket_capacity, s.tokens + dt * s.rate)
    s.last_refill = now
end

# Additive increase: only after a clean window with no recent rate error.
function _maybe_recover!(s::State, now::Float64)
    if now - s.last_increase >= s.cfg.recover_interval_s &&
       now - s.last_rate_error >= s.cfg.recover_interval_s &&
       s.rate < s.cfg.rate_max
        s.rate = min(s.cfg.rate_max, s.rate + s.cfg.rate_step)
        s.last_increase = now
    end
end

_trim_window!(s::State, now::Float64) =
    filter!(((t, _),) -> now - t <= _WINDOW_S, s.usage_window)

function _tokens_per_min(s::State, now::Float64)
    _trim_window!(s, now)
    isempty(s.usage_window) ? 0 : sum(tok for (_, tok) in s.usage_window)
end

# Seconds until at least `cost` tokens *could* be available (refill or cooldown).
function _wait_hint(s::State, now::Float64, cost::Float64)
    if now < s.paused_until
        return s.paused_until - now
    end
    deficit = cost - s.tokens
    deficit <= 0 && return 1.0           # not token-bound; re-poll for slot/budget
    s.rate <= 0 && return 1.0
    return deficit / s.rate
end

# Timed wait on the condition: wakes on notify OR after `seconds` (capped so the
# time-based token bucket is always re-evaluated). Must be called holding the lock.
function _timed_wait(cond::Threads.Condition, seconds::Float64)
    seconds = clamp(seconds, 0.05, 5.0)   # events still notify; cap only bounds time-polls
    t = Timer(_ -> (lock(cond) do; notify(cond); end), seconds)
    try
        wait(cond)
    finally
        close(t)
    end
end

# ── Admission (§5.1 + §5.2 + §5.5) ────────────────────────────────────────────
"""
    with_admission(f; cost=1.0)

Run `f()` once a concurrency slot, a rate token (`cost`), and tokens/min headroom
are all available — blocking (backpressure) until then. Always releases the slot,
even if `f` throws.
"""
function with_admission(f; cost::Real = 1.0)
    s = _state()
    _acquire!(s, float(cost))
    try
        return f()
    finally
        _release!(s)
    end
end

function _acquire!(s::State, cost::Float64)
    lock(s.cond) do
        while true
            now = _now()
            _refill!(s, now)
            _maybe_recover!(s, now)
            slot_ok   = s.in_flight < s.cfg.max_concurrency
            token_ok  = s.tokens >= cost
            paused    = now < s.paused_until
            budget_ok = s.cfg.tokens_per_min <= 0 || _tokens_per_min(s, now) < s.cfg.tokens_per_min
            if slot_ok && token_ok && budget_ok && !paused
                s.in_flight += 1
                s.tokens -= cost
                return
            end
            # A slot-only block is event-driven — `release` notifies, so plain-wait
            # with no timer (this is the common case under backpressure, and the per-
            # iteration Timer is what caused scheduler churn with many parked workers).
            # Any time-based constraint (token refill, cooldown, budget-window expiry)
            # has no waking event, so it must time-poll.
            if !slot_ok && token_ok && budget_ok && !paused
                wait(s.cond)
            else
                _timed_wait(s.cond, _wait_hint(s, now, cost))
            end
        end
    end
end

function _release!(s::State)
    lock(s.cond) do
        s.in_flight = max(0, s.in_flight - 1)
        notify(s.cond)
    end
end

# ── Feedback from the event stream (§5.2 + §5.5) ──────────────────────────────
"""
    note_rate_error!(retry_after=nothing)

A rate-limit signal was observed (a turn surfaced 429/overloaded). Multiplicative
decrease of R and pause refills for `retry_after` seconds (or a base cooldown if
unknown).
"""
function note_rate_error!(retry_after::Union{Real,Nothing} = nothing)
    s = _state()
    lock(s.cond) do
        now = _now()
        s.rate = max(s.cfg.rate_min, s.rate * s.cfg.decrease_factor)
        s.rate_errors += 1
        s.last_rate_error = now
        cooldown = retry_after === nothing ? s.cfg.base_cooldown_s : max(0.0, float(retry_after))
        s.paused_until = max(s.paused_until, now + cooldown)
        s.last_refill = now
        notify(s.cond)     # wake waiters so they re-evaluate the pause
    end
    nothing
end

"""
    record_turn_end!(total_tokens)

Feed a completed turn's token total into the rolling tokens/min budget (§5.5).
"""
function record_turn_end!(total_tokens::Integer)
    total_tokens <= 0 && return nothing
    s = _state()
    lock(s.cond) do
        now = _now()
        push!(s.usage_window, (now, Int(total_tokens)))
        _trim_window!(s, now)
        notify(s.cond)     # budget may have shifted; let a budget-blocked waiter recheck
    end
    nothing
end

# ── Rate-limit classifier + backoff (§5.3 + §5.4) ─────────────────────────────
const _RATE_PATTERNS = (
    r"\b429\b", r"rate[ _-]?limit", r"overloaded", r"too many requests", r"quota exceeded",
)

"""
    is_rate_limited(msg) -> Bool

True if `msg` (an AgentError message / failed-turn text) looks like a 429 /
overloaded / rate-limit signal. Conservative substring/regex match — see §5.3.
"""
function is_rate_limited(msg::AbstractString)
    m = lowercase(msg)
    any(p -> occursin(p, m), _RATE_PATTERNS)
end
is_rate_limited(::Nothing) = false

"""Best-effort parse of a `retry-after`/`Retry-After` seconds value from a message.
Returns the seconds as Float64, or nothing if absent."""
function retry_after_seconds(msg::AbstractString)
    m = match(r"retry[ _-]?after[\"':=\s]+(\d+(?:\.\d+)?)"i, msg)
    m === nothing && return nothing
    return tryparse(Float64, m.captures[1])
end
retry_after_seconds(::Nothing) = nothing

"""
    backoff_seconds(attempt; retry_after=nothing) -> Float64

Exponential backoff with jitter for retry #`attempt` (0-based): base 1s, ×2 per
attempt, capped at 60s. Honors `retry_after` verbatim when known.
"""
function backoff_seconds(attempt::Integer; base::Real = 1.0, factor::Real = 2.0,
                         cap::Real = 60.0, retry_after::Union{Real,Nothing} = nothing)
    retry_after !== nothing && return max(0.0, float(retry_after))
    raw = min(float(cap), float(base) * float(factor)^attempt)
    return raw * (0.5 + 0.5 * rand())   # 50–100% jitter; rand() is fine in module code
end

max_retries() = _state().cfg.max_retries

# ── Observability (§7) ────────────────────────────────────────────────────────
"""
    status() -> NamedTuple

A cheap snapshot of governor state for a TUI/Console readout: in_flight,
max_concurrency, current rate R, tokens available, rolling tokens/min + budget,
throttled flag, cooldown remaining, cumulative rate errors.
"""
function status()
    s = _state()
    lock(s.cond) do
        now = _now()
        _refill!(s, now)
        paused_for = max(0.0, s.paused_until - now)
        (
            in_flight       = s.in_flight,
            max_concurrency = s.cfg.max_concurrency,
            rate            = round(s.rate, digits = 3),
            rate_max        = s.cfg.rate_max,
            rate_min        = s.cfg.rate_min,
            tokens_available = round(s.tokens, digits = 2),
            tokens_per_min  = _tokens_per_min(s, now),
            token_budget    = s.cfg.tokens_per_min,
            throttled       = paused_for > 0 || s.in_flight >= s.cfg.max_concurrency,
            cooldown_remaining = round(paused_for, digits = 2),
            rate_errors     = s.rate_errors,
        )
    end
end

end # module RateGovernor

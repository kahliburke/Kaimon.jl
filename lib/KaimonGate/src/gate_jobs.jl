# ─────────────────────────────────────────────────────────────────────────────
# KaimonGate · background job tracking · cancellation · stash/progress  (split from gate.jl; part of the KaimonGate module)
# ─────────────────────────────────────────────────────────────────────────────

# ── Job Safehouse ─────────────────────────────────────────────────────────────
# Allows long-running evals/tools to stash intermediate values that can be
# inspected while the job is still running (like Infiltrator's @exfiltrate).

const _JOB_SAFEHOUSE = Dict{String, Dict{String, Any}}()
const _JOB_SAFEHOUSE_LOCK = ReentrantLock()

# ── Cooperative Cancellation ─────────────────────────────────────────────────
# Set by the TUI when cancel_eval is called. User code checks via is_cancelled().

const _CANCELLED_JOBS = Set{String}()
const _CANCELLED_JOBS_LOCK = ReentrantLock()

# ── Completed Job Results Cache ──────────────────────────────────────────────
# Stores serialized results of completed evals so the TUI can retrieve them
# after a restart (when the original PUB/SUB delivery was missed).

const _COMPLETED_RESULTS = Dict{String, Vector{UInt8}}()  # eval_id → serialized result
const _COMPLETED_RESULTS_LOCK = ReentrantLock()
const _COMPLETED_RESULTS_MAX = 50  # keep last N results

"""
    cancel_job!(eval_id::String)

Mark a job as cancelled. Called from the TUI side (via PUB/SUB or direct).
"""
function cancel_job!(eval_id::String)
    lock(_CANCELLED_JOBS_LOCK) do
        push!(_CANCELLED_JOBS, eval_id)
    end
end

"""
    is_cancelled(; job_id::String="") -> Bool

Check if the current job has been cancelled. Call this in long-running loops
to support cooperative cancellation.

If called from within a GateTool handler or async eval, the job ID is
detected automatically. Otherwise, pass `job_id` explicitly.

# Example
```julia
for epoch in 1:1000
    KaimonGate.is_cancelled() && break
    loss = train_epoch!(model)
    KaimonGate.stash("epoch", epoch)
    KaimonGate.progress("Epoch \$epoch: loss=\$loss")
end
```
"""
function is_cancelled(; job_id::String="")
    if isempty(job_id)
        job_id = string(get(task_local_storage(), :gate_request_id, ""))
    end
    isempty(job_id) && return false
    lock(_CANCELLED_JOBS_LOCK) do
        job_id in _CANCELLED_JOBS
    end
end

"""
    stash(key::String, value; job_id::String="")

Stash a value in the current job's safehouse. If called from within a GateTool
handler or async eval, the job ID is detected automatically. Otherwise, pass
`job_id` explicitly.

Retrieve stashed values with `check_eval` or `inspect_job`.

# Example
```julia
for epoch in 1:100
    loss = train_epoch!(model)
    KaimonGate.stash("epoch", epoch)
    KaimonGate.stash("loss", loss)
    KaimonGate.stash("lr", get_lr(optimizer))
    KaimonGate.progress("Epoch \$epoch: loss=\$loss")
end
```
"""
function stash(key::String, value; job_id::String="")
    if isempty(job_id)
        job_id = string(get(task_local_storage(), :gate_request_id, ""))
    end
    isempty(job_id) && return
    lock(_JOB_SAFEHOUSE_LOCK) do
        if !haskey(_JOB_SAFEHOUSE, job_id)
            _JOB_SAFEHOUSE[job_id] = Dict{String, Any}()
        end
        _JOB_SAFEHOUSE[job_id][key] = value
    end
    # Publish stash update so TUI can collect it
    try
        repr_v = sprint(show, value; context=:limit => true)
        if length(repr_v) > 500
            repr_v = first(repr_v, 500) * "..."
        end
        _publish_stream("job_stash", "$key=$repr_v"; request_id = job_id)
    catch
    end
    # Echo to stderr — uses \r overwrite so rapid stash calls stay on one line
    try
        short_v = sprint(show, value; context=:limit => true)
        if length(short_v) > 40
            short_v = first(short_v, 40) * "…"
        end
        ts = Dates.format(Dates.now(), "HH:MM:SS")
        line = "[$ts] 📌 $key=$short_v"
        _stderr_overwrite!(line, :stash)
    catch
    end
    nothing
end

"""
    stash(pairs::Pair...; job_id::String="")

Stash multiple values at once.

# Example
```julia
KaimonGate.stash("epoch" => epoch, "loss" => loss, "accuracy" => acc)
```
"""
function stash(pairs::Pair{String}...; job_id::String="")
    if isempty(pairs)
        return
    end
    # Batch: stash each value individually (publishes + safehouse)
    for (k, v) in pairs
        if isempty(job_id)
            stash(k, v)
        else
            stash(k, v; job_id)
        end
    end
end

"""
    push_panel(key::String, value)

Push a state update to the extension's TUI panel. The value is delivered
via PUB/SUB and appears in the panel's `ctx._cache[:panel_state][key]`
on the next frame.

Use this from tool handlers or background tasks to stream data to the
panel without the panel needing to poll via `ctx.eval()`.

# Example
```julia
function my_tool_handler(args)
    result = do_work(args)
    KaimonGate.push_panel("result", result)
    KaimonGate.push_panel("status", "done")
    return "OK"
end
```
"""
function push_panel(key::String, value)
    _publish_stream("panel_push", (key = key, value = value))
end

"""
    push_panel(pairs::Pair{String}...)

Push multiple panel state updates at once.

# Example
```julia
KaimonGate.push_panel("greetings" => greetings, "rolls" => rolls)
```
"""
function push_panel(pairs::Pair{String}...)
    for (k, v) in pairs
        push_panel(k, v)
    end
end

"""
    get_stash(job_id::String) -> Dict{String, Any}

Retrieve all stashed values for a job. Returns empty Dict if none.
"""
function get_stash(job_id::String)
    lock(_JOB_SAFEHOUSE_LOCK) do
        for (k, v) in _JOB_SAFEHOUSE
            if startswith(k, job_id)
                return copy(v)
            end
        end
        return Dict{String, Any}()
    end
end

"""
    clear_stash(job_id::String)

Clear the safehouse for a job. Called automatically when check_eval retrieves
a completed job's result.
"""
function clear_stash(job_id::String)
    lock(_JOB_SAFEHOUSE_LOCK) do
        for k in collect(keys(_JOB_SAFEHOUSE))
            startswith(k, job_id) && delete!(_JOB_SAFEHOUSE, k)
        end
    end
end


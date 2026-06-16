# ─────────────────────────────────────────────────────────────────────────────
# Kaimon Qdrant indexer · Revise auto-reindex hook + event watcher  (split from qdrant_indexer.jl)
# ─────────────────────────────────────────────────────────────────────────────

"""
    setup_revise_hook(project_path::String=pwd(); collection::Union{String,Nothing}=nothing, silent::Bool=false)

Set up a Revise.jl callback to automatically re-index files when they change.
Only works if Revise is loaded in Main.
Set silent=true to suppress all output (logs to file only).
"""
function setup_revise_hook(
    project_path::String=pwd();
    collection::Union{String,Nothing}=nothing,
    silent::Bool=false,
)
    if !isdefined(Main, :Revise)
        msg = "Revise.jl not loaded - automatic re-indexing disabled"
        !silent && @warn msg
        with_index_logger(() -> @warn msg)
        return nothing
    end

    col_name = String(
        collection === nothing ? get_project_collection_name(project_path) : collection,
    )

    src_dir = joinpath(project_path, "src")
    if !isdir(src_dir)
        src_dir = project_path
    end

    # Revise callbacks are zero-arg in current Revise API.
    # We run sync_index() to incrementally pick up changed/deleted files.
    callback = function ()
        try
            result = sync_index(
                project_path;
                collection=col_name,
                verbose=false,
                silent=true,  # Always silent in background
            )
            with_index_logger(() -> @info "Auto-sync after Revise event" reindexed = result.reindexed deleted = result.deleted chunks = result.chunks)
        catch e
            with_index_logger(() -> @warn "Failed to sync index after Revise event" exception = e)
        end
    end

    # Register with Revise
    # Watch project source directory; callback is invoked by Revise with no args.
    try
        Main.Revise.add_callback(callback, [src_dir])
        msg = "Revise hook installed for automatic index updates"
        !silent && @info msg
        with_index_logger(() -> @info msg collection = col_name)
        return callback
    catch e
        msg = "Failed to set up Revise hook"
        !silent && @warn msg exception = e
        with_index_logger(() -> @warn msg exception = e)
        return nothing
    end
end

# Global refs for the Revise event watcher
const REVISE_EVENT_TASK = Ref{Union{Task,Nothing}}(nothing)
const REVISE_EVENT_STOP = Ref{Bool}(false)
const REVISE_EVENT_CHANGES = Ref{Int}(0)

"""
    start_revise_event_watcher(; project_path::String=pwd(), collection::Union{String,Nothing}=nothing, silent::Bool=false)

Start an event-driven Revise watcher that waits on `Revise.revision_event`,
applies revisions, and syncs the Qdrant index after each change.
"""
function start_revise_event_watcher(;
    project_path::String=pwd(),
    collection::Union{String,Nothing}=nothing,
    silent::Bool=false,
)
    if !isdefined(Main, :Revise)
        msg = "Revise.jl not loaded - event watcher disabled"
        !silent && @warn msg
        with_index_logger(() -> @warn msg)
        return nothing
    end

    if REVISE_EVENT_TASK[] !== nothing && !istaskdone(REVISE_EVENT_TASK[])
        msg = "Revise event watcher already running"
        !silent && @warn msg
        with_index_logger(() -> @warn msg)
        return REVISE_EVENT_TASK[]
    end

    col_name = String(
        collection === nothing ? get_project_collection_name(project_path) : collection,
    )
    REVISE_EVENT_STOP[] = false
    REVISE_EVENT_CHANGES[] = 0

    task = @async begin
        while !REVISE_EVENT_STOP[]
            try
                # Wait for filesystem change notification (Revise-level signal)
                wait(Main.Revise.revision_event)
                REVISE_EVENT_STOP[] && break
                Base.reset(Main.Revise.revision_event)

                # Apply pending revisions before syncing index
                Main.Revise.revise()

                REVISE_EVENT_CHANGES[] += 1
                result = sync_index(
                    project_path;
                    collection=col_name,
                    verbose=false,
                    silent=true,
                )
                with_index_logger(() -> @info "Revise applied changes" total_changes = REVISE_EVENT_CHANGES[] reindexed = result.reindexed deleted = result.deleted chunks = result.chunks)
            catch e
                if e isa InterruptException || REVISE_EVENT_STOP[]
                    break
                end
                with_index_logger(() -> @error "Revise watcher error" exception = (e, catch_backtrace()))
                sleep(1)  # Brief back-off on error
            end
        end
    end

    REVISE_EVENT_TASK[] = task
    msg = "Revise event watcher started"
    !silent && @info msg collection = col_name
    with_index_logger(() -> @info msg collection = col_name)
    return task
end

"""
    stop_revise_event_watcher(; silent::Bool=false)

Stop the event-driven Revise watcher if running.
"""
function stop_revise_event_watcher(; silent::Bool=false)
    task = REVISE_EVENT_TASK[]
    if task === nothing || istaskdone(task)
        return false
    end
    REVISE_EVENT_STOP[] = true
    try
        # Wake wait(revision_event) so the task can exit quickly.
        Base.notify(Main.Revise.revision_event)
    catch
    end
    try
        wait(task)
    catch
    end
    REVISE_EVENT_TASK[] = nothing
    msg = "Revise event watcher stopped"
    !silent && @info msg
    with_index_logger(() -> @info msg)
    return true
end

# (The old single-project periodic index-sync scheduler was removed — it was
# never started anywhere. Indexing is now driven event-wise by
# auto-index-on-connect and file-change reindex, plus a shared multi-project
# periodic sync (`_sync_all_enabled_projects!`) run by headless housekeeping.)

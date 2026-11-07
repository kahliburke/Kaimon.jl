# ── Machine identity ──────────────────────────────────────────────────────────
# A client decides from this whether a gate's PID names a process it can see. A loopback address
# does not settle that: an SSH tunnel, a container's port-forward and WSL1's loopback shared with
# Windows all put another machine's gate at 127.0.0.1.

const _MACHINE_ID = Ref{String}("")

"""
    machine_id() -> String

An identity for the machine and process namespace this Julia runs in, equal for two processes
exactly when one can look up the other's PID. The kernel name, then: on macOS the host UUID; on
Linux the machine id and the PID namespace (so a container differs from its host); on Windows
the host name. Reported in the gate's pong.
"""
function machine_id()
    isempty(_MACHINE_ID[]) || return _MACHINE_ID[]
    id = try
        _machine_id_part()
    catch
        ""
    end
    isempty(id) && (id = gethostname())
    return _MACHINE_ID[] = string(Sys.KERNEL, ":", id)
end

function _machine_id_part()
    if Sys.isapple()
        uuid = zeros(UInt8, 16)
        wait = Int64[5, 0]                       # struct timespec: give up after 5 s
        ret = ccall(:gethostuuid, Cint, (Ptr{UInt8}, Ptr{Int64}), uuid, wait)
        return ret == 0 ? bytes2hex(uuid) : ""
    elseif Sys.islinux()
        mid = ""
        for f in ("/etc/machine-id", "/var/lib/dbus/machine-id", "/proc/sys/kernel/random/boot_id")
            mid = try strip(read(f, String)) catch; "" end
            isempty(mid) || break
        end
        ns = try readlink("/proc/self/ns/pid") catch; "" end   # "pid:[4026531836]"; absent on WSL1
        return isempty(ns) ? mid : string(mid, ":", ns)
    end
    return ""
end

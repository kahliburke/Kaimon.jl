# kaimon-confine: run a command with its file access limited by Landlock (Linux 5.13 and later).
#
#   kaimon-confine [--policy FILE] [--deny P] [--allow P] [--write P] [--unset VAR] -- CMD ARGS...
#   kaimon-confine --check        prints the kernel's Landlock ABI version (0 when it has none)
#   kaimon-confine --dry-run ...  prints the rules and the command instead of running it
#
# Everything is readable except the `deny` paths; an `allow` path inside a denied one is readable
# again. Only the `write` paths (and /dev/null) can be written. Landlock grants and never denies, so
# "all but these" is granted as the siblings of each denied path and of each of its ancestors, down
# from `/`. Symbolic links met on the way are not granted: their targets are, wherever they lie. A
# policy file holds the same options one per line (`deny /srv/app/secrets`), with `#` comments.
#
# A script on Base alone, run by `confine_launcher`'s wrapper (one thread, nothing compiled), so it
# starts in a fraction of a second. It restricts its own thread, then replaces itself with the
# command, which keeps the restriction with everything it starts. Kaimon includes it for its rules.
module KaimonConfine

Base.@kwdef mutable struct Rules
    deny::Vector{String} = String[]
    allow::Vector{String} = String[]
    write::Vector{String} = String[]
    unset::Vector{String} = String[]
    reads::Vector{String} = String[]
end

struct ConfineError <: Exception
    msg::String
end

real(p) = try realpath(p) catch; nothing end

function option!(r::Rules, key::AbstractString, val::AbstractString)
    key == "unset" && return push!(r.unset, val)
    key in ("deny", "allow", "write") || throw(ConfineError("unknown option $key"))
    p = real(val)
    p === nothing || push!(getfield(r, Symbol(key)), p)     # nothing there: nothing to grant or hide
end

function read_policy!(r::Rules, file::AbstractString)
    lines = try readlines(file) catch e; throw(ConfineError("cannot read the policy $file: $(sprint(showerror, e))")) end
    for line in lines
        s = strip(line)
        (isempty(s) || startswith(s, '#')) && continue
        parts = split(s; limit = 2)
        length(parts) == 2 || throw(ConfineError("a policy line needs a value: $s"))
        option!(r, parts[1], strip(parts[2]))
    end
end

"Whether directory `p` holds a denied path somewhere beneath it."
above_denied(r::Rules, p::AbstractString) = any(d -> p == "/" ? d != "/" : startswith(d, p * "/"), r.deny)

"Grant reading everything beneath `dir` but the denied paths."
function walk!(r::Rules, dir::AbstractString)
    names = try readdir(dir) catch; return end         # unreadable to this user anyway
    for name in names
        p = dir == "/" ? "/" * name : dir * "/" * name
        st = try lstat(p) catch; continue end
        (islink(st) || p in r.deny) && continue
        isdir(st) && above_denied(r, p) ? walk!(r, p) : push!(r.reads, p)
    end
end

"The paths to read, once the options are in: around the denied ones, and the allowed ones."
function grant!(r::Rules)
    push!(r.write, "/dev/null")
    isempty(r.deny) ? push!(r.reads, "/") : walk!(r, "/")
    append!(r.reads, r.allow)
    return r
end

# Landlock: the same system call numbers on every architecture Linux gives them to.
const CREATE_RULESET, ADD_RULE, RESTRICT_SELF = 444, 445, 446
const EXECUTE, WRITE_FILE, READ_FILE, READ_DIR = UInt64(1) << 0, UInt64(1) << 1, UInt64(1) << 2, UInt64(1) << 3
const MAKE_SYM, REFER, TRUNCATE = UInt64(1) << 12, UInt64(1) << 13, UInt64(1) << 14
const READ_RIGHTS = EXECUTE | READ_FILE | READ_DIR
const FILE_RIGHTS = EXECUTE | WRITE_FILE | READ_FILE | TRUNCATE      # all a file (not a directory) can be given

"The kernel's Landlock ABI version, 0 when it has none."
function abi()
    Sys.islinux() || return 0
    v = ccall(:syscall, Clong, (Clong, Ptr{Cvoid}, Csize_t, UInt32), CREATE_RULESET, C_NULL, 0, 1)
    return v < 0 ? 0 : Int(v)
end

errno_text() = Libc.strerror(Libc.errno())

function add_rule(ruleset::Cint, p::AbstractString, rights::UInt64, handled::UInt64)
    fd = ccall(:open, Cint, (Cstring, Cint), p, 0o10000000 | 0o2000000)   # O_PATH | O_CLOEXEC
    fd < 0 && return                                                          # gone since it was listed
    isdir(p) || (rights &= FILE_RIGHTS)
    attr = zeros(UInt8, 12)                                                   # packed: u64 allowed, s32 fd
    GC.@preserve attr begin
        unsafe_store!(Ptr{UInt64}(pointer(attr)), rights & handled)
        unsafe_store!(Ptr{Cint}(pointer(attr) + 8), fd)
        ccall(:syscall, Clong, (Clong, Cint, Cint, Ptr{UInt8}, UInt32), ADD_RULE, ruleset, 1, attr, 0) == 0 ||
            throw(ConfineError("cannot add a rule for $p: $(errno_text())"))
    end
    ccall(:close, Cint, (Cint,), fd)
end

"Restrict this thread to the rules; what it runs next inherits them."
function restrict!(r::Rules)
    v = abi()
    v >= 1 || throw(ConfineError("this kernel has no Landlock, so the command cannot be confined"))
    # Every file right of Landlock's first ABI, and those of later ones this kernel knows. Device ioctls
    # (ABI 5) are left alone: restricting them would only break terminals.
    handled = (MAKE_SYM << 1) - 1 | (v >= 2 ? REFER : 0) | (v >= 3 ? TRUNCATE : 0)
    attr = Ref(handled)                                     # struct landlock_ruleset_attr, its first field
    ruleset = Cint(ccall(:syscall, Clong, (Clong, Ptr{UInt64}, Csize_t, UInt32), CREATE_RULESET, attr, 8, 0))
    ruleset < 0 && throw(ConfineError("cannot create a Landlock ruleset: $(errno_text())"))
    foreach(p -> add_rule(ruleset, p, READ_RIGHTS, handled), r.reads)
    foreach(p -> add_rule(ruleset, p, handled, handled), r.write)
    ccall(:prctl, Cint, (Cint, Culong, Culong, Culong, Culong), 38, 1, 0, 0, 0) == 0 ||   # PR_SET_NO_NEW_PRIVS
        throw(ConfineError("cannot set no_new_privs: $(errno_text())"))
    ccall(:syscall, Clong, (Clong, Cint, UInt32), RESTRICT_SELF, ruleset, 0) == 0 ||
        throw(ConfineError("cannot restrict the process: $(errno_text())"))
    ccall(:close, Cint, (Cint,), ruleset)
end

"Replace this process with `cmd`, as a process of its own would start: no signal blocked or ignored."
function exec(cmd::Vector{String})
    # Julia blocks the signals its listener thread takes in every other thread, and ignores some
    # (SIGPIPE, SIGTRAP); a program started from here would inherit both, and take no SIGTERM.
    ccall(:pthread_sigmask, Cint, (Cint, Ptr{UInt8}, Ptr{Cvoid}), 2, zeros(UInt8, 128), C_NULL)   # SIG_SETMASK, none
    for sig in 1:31
        sig in (9, 19) || ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), sig, C_NULL)            # SIG_DFL
    end
    argv = [pointer.(cmd); Ptr{UInt8}(C_NULL)]
    GC.@preserve cmd ccall(:execvp, Cint, (Cstring, Ptr{Ptr{UInt8}}), cmd[1], argv)
    throw(ConfineError("cannot run $(cmd[1]): $(errno_text())"))
end

function main(args::Vector{String})
    r, i, dry = Rules(), 1, false
    while i <= length(args)
        a = args[i]
        a == "--" && (i += 1; break)
        a == "--check" && return println(abi())
        a == "--dry-run" && (dry = true; i += 1; continue)
        (startswith(a, "--") && i < length(args)) || throw(ConfineError("unknown argument $a"))
        a == "--policy" ? read_policy!(r, args[i+1]) : option!(r, a[3:end], args[i+1])
        i += 2
    end
    i <= length(args) || throw(ConfineError("no command to run"))
    cmd = args[i:end]
    grant!(r)
    foreach(v -> delete!(ENV, v), r.unset)
    if dry
        foreach(p -> println("read ", p), r.reads)
        foreach(p -> println("write ", p), r.write)
        return println("run ", join(cmd, " "))
    end
    Sys.islinux() || throw(ConfineError("confining needs Linux's Landlock"))
    restrict!(r)
    exec(cmd)
end

end # module KaimonConfine

if abspath(PROGRAM_FILE) == @__FILE__
    try
        KaimonConfine.main(ARGS)
    catch e
        e isa KaimonConfine.ConfineError || rethrow()
        println(stderr, "kaimon-confine: ", e.msg)
        exit(126)
    end
end

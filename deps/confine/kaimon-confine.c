// kaimon-confine: run a command with its file access limited by Landlock (Linux 5.13 and later).
//
//   kaimon-confine [--policy FILE] [--deny P] [--allow P] [--write P] [--unset VAR] -- CMD ARGS...
//   kaimon-confine --check        prints the kernel's Landlock ABI version (0 when it has none)
//   kaimon-confine --dry-run ...  prints the rules and the command instead of running it
//
// Everything is readable except the `deny` paths; an `allow` path inside a denied one is readable
// again. Only the `write` paths (and /dev/null) can be written. Landlock grants and never denies, so
// "all but these" is granted as the siblings of each denied path and of each of its ancestors, down
// from `/`. Symbolic links met on the way are not granted: their targets are, wherever they lie. A
// policy file holds the same options one per line (`deny /srv/app/secrets`), with `#` comments.
// The restriction holds for the command and everything it starts; it cannot be lifted.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <linux/landlock.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif

typedef struct { char **v; int n, cap; } list;

static list deny, allow, writes, unsets, reads;
static int dry_run = 0;

static void die(const char *what, const char *arg) {
    fprintf(stderr, "kaimon-confine: %s%s%s%s%s\n", what, arg ? " " : "", arg ? arg : "",
            errno ? ": " : "", errno ? strerror(errno) : "");
    exit(126);
}

static void push(list *l, const char *s) {
    if (l->n == l->cap) {
        l->cap = l->cap ? 2 * l->cap : 64;
        if (!(l->v = realloc(l->v, l->cap * sizeof *l->v))) die("out of memory", NULL);
    }
    l->v[l->n++] = strdup(s);
}

// The real path of `p`, added to `l`; a path that does not exist is left out (nothing to grant or hide).
static void push_real(list *l, const char *p) {
    char real[PATH_MAX];
    if (realpath(p, real)) push(l, real);
}

static int in(const list *l, const char *p) {
    for (int i = 0; i < l->n; i++) if (strcmp(l->v[i], p) == 0) return 1;
    return 0;
}

// Whether directory `p` holds a denied path somewhere beneath it.
static int above_denied(const char *p) {
    size_t n = strlen(p);
    for (int i = 0; i < deny.n; i++) {
        const char *d = deny.v[i];
        if (n == 1 && p[0] == '/' && d[1] != '\0') return 1;
        if (strncmp(d, p, n) == 0 && d[n] == '/') return 1;
    }
    return 0;
}

// Grant reading everything beneath `dir` but the denied paths.
static void walk(const char *dir) {
    DIR *d = opendir(dir);
    if (!d) return;                                  // unreadable to this user anyway
    struct dirent *e;
    while ((e = readdir(d))) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        char p[PATH_MAX];
        snprintf(p, sizeof p, "%s/%s", strcmp(dir, "/") == 0 ? "" : dir, e->d_name);
        struct stat st;
        if (lstat(p, &st) != 0 || S_ISLNK(st.st_mode) || in(&deny, p)) continue;
        if (S_ISDIR(st.st_mode) && above_denied(p)) walk(p);
        else push(&reads, p);
    }
    closedir(d);
}

static void option(const char *key, const char *val) {
    if (strcmp(key, "deny") == 0) push_real(&deny, val);
    else if (strcmp(key, "allow") == 0) push_real(&allow, val);
    else if (strcmp(key, "write") == 0) push_real(&writes, val);
    else if (strcmp(key, "unset") == 0) push(&unsets, val);
    else { errno = 0; die("unknown option", key); }
}

static void read_policy(const char *file) {
    FILE *f = fopen(file, "r");
    if (!f) die("cannot read the policy", file);
    char line[PATH_MAX + 32];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = '\0';
        char *s = line;
        while (*s == ' ' || *s == '\t') s++;
        if (*s == '\0' || *s == '#') continue;
        char *val = strpbrk(s, " \t");
        if (!val) { errno = 0; die("a policy line needs a value:", s); }
        *val++ = '\0';
        while (*val == ' ' || *val == '\t') val++;
        option(s, val);
    }
    fclose(f);
}

#ifdef __linux__
static int ll_abi(void) {
    long v = syscall(__NR_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    return v < 0 ? 0 : (int)v;
}

// The rights a file (rather than a directory) can be given.
#define FILE_RIGHTS (LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_READ_FILE)
#define READ_RIGHTS (LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR)

static void add_rule(int ruleset, const char *p, __u64 rights, __u64 handled) {
    int fd = open(p, O_PATH | O_CLOEXEC);
    if (fd < 0) return;                              // gone since it was listed
    struct stat st;
    if (fstat(fd, &st) == 0 && !S_ISDIR(st.st_mode)) {
        __u64 file = FILE_RIGHTS;
#ifdef LANDLOCK_ACCESS_FS_TRUNCATE
        file |= LANDLOCK_ACCESS_FS_TRUNCATE;
#endif
        rights &= file;
    }
    struct landlock_path_beneath_attr pb = { .allowed_access = rights & handled, .parent_fd = fd };
    if (syscall(__NR_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &pb, 0) != 0) die("cannot add a rule for", p);
    close(fd);
}

static void restrict_self(void) {
    int abi = ll_abi();
    if (abi < 1) { errno = 0; die("this kernel has no Landlock, so the command cannot be confined", NULL); }
    // Every file right of Landlock's first ABI, and those of later ones this kernel knows. Device ioctls
    // (ABI 5) are left alone: restricting them would only break terminals.
    __u64 handled = (LANDLOCK_ACCESS_FS_MAKE_SYM << 1) - 1;
#ifdef LANDLOCK_ACCESS_FS_REFER
    if (abi >= 2) handled |= LANDLOCK_ACCESS_FS_REFER;
#endif
#ifdef LANDLOCK_ACCESS_FS_TRUNCATE
    if (abi >= 3) handled |= LANDLOCK_ACCESS_FS_TRUNCATE;
#endif
    struct landlock_ruleset_attr attr = { .handled_access_fs = handled };
    int ruleset = syscall(__NR_landlock_create_ruleset, &attr, sizeof attr, 0);
    if (ruleset < 0) die("cannot create a Landlock ruleset", NULL);
    for (int i = 0; i < reads.n; i++) add_rule(ruleset, reads.v[i], READ_RIGHTS, handled);
    for (int i = 0; i < writes.n; i++) add_rule(ruleset, writes.v[i], handled, handled);
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) die("cannot set no_new_privs", NULL);
    if (syscall(__NR_landlock_restrict_self, ruleset, 0) != 0) die("cannot restrict the process", NULL);
    close(ruleset);
}
#endif

int main(int argc, char **argv) {
    int i = 1;
    for (; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--") == 0) { i++; break; }
        if (strcmp(a, "--check") == 0) {
#ifdef __linux__
            printf("%d\n", ll_abi());
#else
            printf("0\n");
#endif
            return 0;
        }
        if (strcmp(a, "--dry-run") == 0) { dry_run = 1; continue; }
        if (strncmp(a, "--", 2) != 0 || i + 1 == argc) { errno = 0; die("unknown argument", a); }
        if (strcmp(a, "--policy") == 0) read_policy(argv[++i]);
        else option(a + 2, argv[++i]);
    }
    if (i >= argc) { errno = 0; die("no command to run", NULL); }
    push_real(&writes, "/dev/null");
    if (deny.n == 0) push(&reads, "/");
    else walk("/");
    for (int k = 0; k < allow.n; k++) push(&reads, allow.v[k]);
    for (int k = 0; k < unsets.n; k++) unsetenv(unsets.v[k]);
    if (dry_run) {
        for (int k = 0; k < reads.n; k++) printf("read %s\n", reads.v[k]);
        for (int k = 0; k < writes.n; k++) printf("write %s\n", writes.v[k]);
        for (int k = i; k < argc; k++) printf("%s%s", k > i ? " " : "run ", argv[k]);
        printf("\n");
        return 0;
    }
#ifdef __linux__
    restrict_self();
#else
    errno = 0;
    die("confining needs Linux's Landlock", NULL);
#endif
    execvp(argv[i], argv + i);
    die("cannot run", argv[i]);
}

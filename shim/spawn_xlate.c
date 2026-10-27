/* Scoped spawn backport for musl addons on Android before API 34.
 *
 * Rename the addon's imports to Posix_*; never interpose on Termux/Node.
 * Initialize musl's whole opaque objects (336-byte attrs, 80-byte actions),
 * then store private handles accessed only through this API.
 * musl's LP64 sigset is 128 bytes; Linux/Android uses its first 64 bits.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

_Static_assert(sizeof(void *) == 8 && sizeof(sigset_t) == 8,
               "spawn translator requires Android LP64");

enum {
    RESETIDS = 1, SETPGROUP = 2, SETSIGDEF = 4,
    USEVFORK = 64, SETSID = 128
};
struct spawn_attr {
    short flags;
    pid_t pgroup;
    sigset_t sigdefault;
};
struct action {
    struct action *next;
    int from, to;
    char *directory;
};
struct actions {
    struct action *head, *tail;
};

static void *handle(const void *storage) {
    void *p = NULL;
    if (storage) memcpy(&p, storage, sizeof(p));
    return p;
}
static void store(void *storage, void *p) {
    memcpy(storage, &p, sizeof(p));
}

int Posix_spawnattr_init(void *storage) {
    if (!storage) return EINVAL;
    memset(storage, 0, 336);
    void *p = calloc(1, sizeof(struct spawn_attr));
    store(storage, p);
    return p ? 0 : ENOMEM;
}
int Posix_spawnattr_destroy(void *storage) {
    if (!storage) return EINVAL;
    free(handle(storage));
    store(storage, NULL);
    return 0;
}
int Posix_spawnattr_setflags(void *storage, short flags) {
    struct spawn_attr *attr = handle(storage);
    if (!attr || (flags & ~(RESETIDS | SETPGROUP | SETSIGDEF | USEVFORK | SETSID)))
        return EINVAL;
    attr->flags = flags;
    return 0;
}
int Posix_spawnattr_setpgroup(void *storage, pid_t group) {
    struct spawn_attr *attr = handle(storage);
    if (!attr) return EINVAL;
    attr->pgroup = group;
    return 0;
}
int Posix_spawnattr_setsigdefault(void *storage, const void *mask) {
    struct spawn_attr *attr = handle(storage);
    if (!attr || !mask) return EINVAL;
    memcpy(&attr->sigdefault, mask, sizeof(attr->sigdefault));
    return 0;
}

int Posix_spawn_file_actions_init(void *storage) {
    if (!storage) return EINVAL;
    memset(storage, 0, 80);
    void *p = calloc(1, sizeof(struct actions));
    store(storage, p);
    return p ? 0 : ENOMEM;
}
int Posix_spawn_file_actions_destroy(void *storage) {
    struct actions *list = handle(storage);
    if (!list) return EINVAL;
    for (struct action *p = list->head, *next; p; p = next) {
        next = p->next;
        free(p->directory);
        free(p);
    }
    free(list);
    store(storage, NULL);
    return 0;
}
static void append(struct actions *list, struct action *p) {
    if (list->tail) list->tail->next = p;
    else list->head = p;
    list->tail = p;
}
int Posix_spawn_file_actions_adddup2(void *storage, int from, int to) {
    struct actions *list = handle(storage);
    if (!list) return EINVAL;
    if (from < 0 || to < 0) return EBADF;
    long limit = sysconf(_SC_OPEN_MAX);
    if (limit > 0 && (from >= limit || to >= limit)) return EBADF;
    struct action *p = calloc(1, sizeof(*p));
    if (!p) return ENOMEM;
    p->from = from;
    p->to = to;
    append(list, p);
    return 0;
}
int Posix_spawn_file_actions_addchdir_np(void *storage, const char *directory) {
    struct actions *list = handle(storage);
    if (!list || !directory) return EINVAL;
    struct action *p = calloc(1, sizeof(*p));
    if (!p) return ENOMEM;
    p->directory = strdup(directory);
    if (!p->directory) { free(p); return ENOMEM; }
    append(list, p);
    return 0;
}

static void child_error(int fd, int error) {
    while (write(fd, &error, sizeof(error)) < 0 && errno == EINTR) {}
    _exit(127);
}

int Posix_spawnp(pid_t *pid_out, const char *file, const void *action_storage,
                 const void *attr_storage, char *const argv[], char *const envp[]) {
    struct actions *list = handle(action_storage);
    struct spawn_attr *attr = handle(attr_storage);
    if (!file || !argv || (action_storage && !list) || (attr_storage && !attr))
        return EINVAL;

    /* Keep the error writer outside every fd referenced by file actions.
     * Otherwise dup2 could close it, or a closed source fd could appear valid. */
    int minimum = 3;
    for (struct action *p = list ? list->head : NULL; p; p = p->next) {
        if (p->directory) continue;
        int highest = p->from > p->to ? p->from : p->to;
        if (highest == INT_MAX) return EBADF;
        if (highest >= minimum) minimum = highest + 1;
    }
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC) < 0) return errno;
    int writer = fcntl(pipefd[1], F_DUPFD_CLOEXEC, minimum);
    int error = errno;
    close(pipefd[1]);
    if (writer < 0) { close(pipefd[0]); return error; }

    sigset_t all, old_mask;
    sigfillset(&all);
    error = pthread_sigmask(SIG_BLOCK, &all, &old_mask);
    if (error) { close(pipefd[0]); close(writer); return error; }
    pid_t pid = fork();
    error = errno;
    if (pid == 0) {
        close(pipefd[0]);
        short flags = attr ? attr->flags : 0;
        struct sigaction disposition;
        struct sigaction default_action = {0};
        default_action.sa_handler = SIG_DFL;
        sigemptyset(&default_action.sa_mask);
        for (int sig = 1; sig < NSIG; ++sig) {
            if (sig == SIGKILL || sig == SIGSTOP) continue;
            if (sigaction(sig, NULL, &disposition) < 0) {
                if (errno == EINVAL) continue; /* libc-reserved signals */
                child_error(writer, errno);
            }
            if (((flags & SETSIGDEF) && sigismember(&attr->sigdefault, sig) == 1) ||
                (disposition.sa_handler != SIG_DFL && disposition.sa_handler != SIG_IGN)) {
                if (sigaction(sig, &default_action, NULL) < 0) child_error(writer, errno);
            }
        }
        if ((flags & RESETIDS) && (setegid(getgid()) < 0 || seteuid(getuid()) < 0))
            child_error(writer, errno);
        if ((flags & SETSID) && setsid() < 0) child_error(writer, errno);
        if ((flags & SETPGROUP) && setpgid(0, attr->pgroup) < 0) child_error(writer, errno);

        for (struct action *p = list ? list->head : NULL; p; p = p->next) {
            if (p->directory) {
                if (chdir(p->directory) < 0) child_error(writer, errno);
            } else if (p->from != p->to) {
                if (dup2(p->from, p->to) < 0) child_error(writer, errno);
            } else {
                int fdflags = fcntl(p->from, F_GETFD);
                if (fdflags < 0 || fcntl(p->from, F_SETFD, fdflags & ~FD_CLOEXEC) < 0)
                    child_error(writer, errno);
            }
        }
        if (sigprocmask(SIG_SETMASK, &old_mask, NULL) < 0) child_error(writer, errno);
        extern char **environ;
        execvpe(file, argv, envp ? envp : environ);
        child_error(writer, errno);
    }
    pthread_sigmask(SIG_SETMASK, &old_mask, NULL);
    close(writer);
    if (pid < 0) { close(pipefd[0]); return error; }

    size_t received = 0;
    while (received < sizeof(error)) {
        ssize_t n = read(pipefd[0], (char *)&error + received, sizeof(error) - received);
        if (n < 0 && errno == EINTR) continue;
        if (n == 0) break; /* CLOEXEC closed the writer after a successful exec */
        if (n < 0) { error = errno; received = sizeof(error); break; }
        received += (size_t)n;
    }
    close(pipefd[0]);
    if (received) {
        if (received != sizeof(error)) error = EIO;
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        return error;
    }
    if (pid_out) *pid_out = pid;
    return 0;
}

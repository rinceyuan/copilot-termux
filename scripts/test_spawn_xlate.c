#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int Posix_spawnattr_init(void *);
int Posix_spawnattr_destroy(void *);
int Posix_spawnattr_setflags(void *, short);
int Posix_spawnattr_setpgroup(void *, pid_t);
int Posix_spawnattr_setsigdefault(void *, const void *);
int Posix_spawn_file_actions_init(void *);
int Posix_spawn_file_actions_destroy(void *);
int Posix_spawn_file_actions_adddup2(void *, int, int);
int Posix_spawn_file_actions_addchdir_np(void *, const char *);
int Posix_spawnp(pid_t *, const char *, const void *, const void *, char *const [], char *const []);

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "FAIL line %d: %s (errno=%d)\n", __LINE__, #expr, errno); exit(1); \
} } while (0)

static const char *self;
static int wait_status(pid_t pid) {
    int status;
    while (waitpid(pid, &status, 0) < 0) CHECK(errno == EINTR);
    return status;
}
static void expect_success(pid_t pid) {
    int status = wait_status(pid);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
static void *thread_spawn(void *unused) {
    (void)unused;
    for (int i = 0; i < 5; ++i) {
        pid_t pid;
        char *args[] = {(char *)self, "--child-ok", NULL};
        CHECK(Posix_spawnp(&pid, self, NULL, NULL, args, NULL) == 0);
        expect_success(pid);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--child-ok") == 0) return 0;
    if (argc > 1 && strcmp(argv[1], "--child-state") == 0) {
        struct sigaction sa;
        sigset_t mask;
        CHECK(sigaction(SIGUSR1, NULL, &sa) == 0 && sa.sa_handler == SIG_DFL);
        CHECK(sigprocmask(SIG_SETMASK, NULL, &mask) == 0);
        CHECK(sigismember(&mask, SIGUSR2) == 1);
        CHECK(getpgrp() == getpid());
        return 0;
    }
    CHECK(argc == 2);
    self = argv[0];
    struct { uint64_t before; unsigned char data[336]; uint64_t after; } attr;
    struct { uint64_t before; unsigned char data[80]; uint64_t after; } actions;
    memset(&attr, 0xa5, sizeof(attr));
    memset(&actions, 0xa5, sizeof(actions));
    CHECK(Posix_spawnattr_init(attr.data) == 0);
    CHECK(Posix_spawn_file_actions_init(actions.data) == 0);
    CHECK(attr.before == UINT64_C(0xa5a5a5a5a5a5a5a5) && attr.before == attr.after);
    CHECK(actions.before == attr.before && actions.after == attr.after);

    char work[4096], subdir[4096], output[8192];
    CHECK(snprintf(work, sizeof(work), "%s/work-XXXXXX", argv[1]) < (int)sizeof(work));
    CHECK(mkdtemp(work) != NULL);
    CHECK(snprintf(subdir, sizeof(subdir), "%s/child", work) < (int)sizeof(subdir));
    CHECK(mkdir(subdir, 0700) == 0);
    int pipefd[2];
    CHECK(pipe2(pipefd, O_CLOEXEC) == 0);
    CHECK(Posix_spawn_file_actions_adddup2(actions.data, pipefd[1], STDOUT_FILENO) == 0);
    CHECK(Posix_spawn_file_actions_addchdir_np(actions.data, work) == 0);
    CHECK(Posix_spawn_file_actions_addchdir_np(actions.data, "child") == 0);
    char *args[] = {"sh", "-c", "printf '%s|%s' \"$PWD\" \"$SPAWN_VALUE\"", NULL};
    char *env[] = {"SPAWN_VALUE=correct", NULL};
    pid_t pid;
    CHECK(Posix_spawnp(&pid, "/system/bin/sh", actions.data, attr.data, args, env) == 0);
    close(pipefd[1]);
    ssize_t length = read(pipefd[0], output, sizeof(output) - 1);
    CHECK(length >= 0);
    output[length] = '\0';
    close(pipefd[0]);
    expect_success(pid);
    char expected[8192];
    snprintf(expected, sizeof(expected), "%s|correct", subdir);
    CHECK(strcmp(output, expected) == 0);
    CHECK(Posix_spawn_file_actions_destroy(actions.data) == 0);
    puts("PASS: musl storage bounds, ordered chdir, dup2 and environment");

    CHECK(setenv("PATH", "/system/bin", 1) == 0);
    char *true_args[] = {"sh", "-c", "exit 0", NULL};
    CHECK(Posix_spawnp(&pid, "sh", NULL, NULL, true_args, NULL) == 0);
    expect_success(pid);
    CHECK(Posix_spawnp(&pid, "/copilot-test-no-such-command", NULL, NULL, true_args, NULL) == ENOENT);
    CHECK(Posix_spawn_file_actions_init(actions.data) == 0);
    CHECK(Posix_spawn_file_actions_addchdir_np(actions.data, "/copilot-test-no-such-dir") == 0);
    CHECK(Posix_spawnp(&pid, self, actions.data, NULL, true_args, NULL) == ENOENT);
    CHECK(Posix_spawn_file_actions_destroy(actions.data) == 0);
    puts("PASS: PATH lookup and synchronous exec/chdir errors");

    CHECK(Posix_spawn_file_actions_init(actions.data) == 0);
    CHECK(Posix_spawn_file_actions_adddup2(actions.data, -1, 1) == EBADF);
    int closed_fd = open("/dev/null", O_RDONLY);
    CHECK(closed_fd >= 0);
    close(closed_fd);
    CHECK(Posix_spawn_file_actions_adddup2(actions.data, closed_fd, STDOUT_FILENO) == 0);
    CHECK(Posix_spawnp(&pid, self, actions.data, NULL, true_args, NULL) == EBADF);
    CHECK(Posix_spawn_file_actions_destroy(actions.data) == 0);
    puts("PASS: error pipe cannot make an invalid source fd appear open");

    CHECK(Posix_spawn_file_actions_init(actions.data) == 0);
    CHECK(pipe2(pipefd, O_CLOEXEC) == 0);
    CHECK(dup2(pipefd[1], 9) == 9);
    CHECK(fcntl(9, F_SETFD, FD_CLOEXEC) == 0);
    CHECK(Posix_spawn_file_actions_adddup2(actions.data, 9, 9) == 0);
    char *fd_args[] = {"sh", "-c", "printf kept >&9", NULL};
    CHECK(Posix_spawnp(&pid, "sh", actions.data, NULL, fd_args, NULL) == 0);
    close(9);
    close(pipefd[1]);
    CHECK(read(pipefd[0], output, sizeof(output)) == 4 && memcmp(output, "kept", 4) == 0);
    close(pipefd[0]);
    expect_success(pid);
    CHECK(Posix_spawn_file_actions_destroy(actions.data) == 0);
    puts("PASS: dup2(fd, fd) clears close-on-exec");

    struct sigaction ignored = {0}, old_action, after;
    ignored.sa_handler = SIG_IGN;
    CHECK(sigaction(SIGUSR1, &ignored, &old_action) == 0);
    sigset_t blocked, old_mask, after_mask;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGUSR2);
    CHECK(pthread_sigmask(SIG_BLOCK, &blocked, &old_mask) == 0);
    unsigned char musl_mask[128] = {0};
    sigset_t defaults;
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGUSR1);
    memcpy(musl_mask, &defaults, sizeof(defaults));
    CHECK(Posix_spawnattr_setsigdefault(attr.data, musl_mask) == 0);
    CHECK(Posix_spawnattr_setpgroup(attr.data, 0) == 0);
    CHECK(Posix_spawnattr_setflags(attr.data, 2 | 4) == 0);
    CHECK(Posix_spawnattr_setflags(attr.data, (short)0x8000) == EINVAL);
    char *state_args[] = {(char *)self, "--child-state", NULL};
    CHECK(Posix_spawnp(&pid, self, NULL, attr.data, state_args, NULL) == 0);
    expect_success(pid);
    CHECK(sigaction(SIGUSR1, NULL, &after) == 0 && after.sa_handler == SIG_IGN);
    CHECK(pthread_sigmask(SIG_SETMASK, NULL, &after_mask) == 0 &&
          sigismember(&after_mask, SIGUSR2) == 1);
    CHECK(sigaction(SIGUSR1, &old_action, NULL) == 0);
    CHECK(pthread_sigmask(SIG_SETMASK, &old_mask, NULL) == 0);
    CHECK(Posix_spawnattr_destroy(attr.data) == 0);
    puts("PASS: signal defaults, inherited mask, process group and parent state");

    pthread_t threads[3];
    for (int i = 0; i < 3; ++i) CHECK(pthread_create(&threads[i], NULL, thread_spawn, NULL) == 0);
    for (int i = 0; i < 3; ++i) CHECK(pthread_join(threads[i], NULL) == 0);
    CHECK(rmdir(subdir) == 0 && rmdir(work) == 0);
    puts("PASS: concurrent callers");
    return 0;
}

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

#include "include/target_conditionals.h"

#if TARGET_OS_LINUX
// For posix_spawn_file_actions_addchdir_np
#define _GNU_SOURCE 1
// For pidfd_open
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <sched.h>
#endif

#include "include/process_shims.h"

#if TARGET_OS_WINDOWS
#include <windows.h>
#else
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <grp.h>
#include <signal.h>
#include <signal.h>
#include <string.h>
#include <fcntl.h>
#include <pthread.h>

#include <stdio.h>

#if __has_include(<crt_externs.h>)
#include <crt_externs.h>
#elif defined(_WIN32)
#include <stdlib.h>
#elif __has_include(<unistd.h>)
#include <unistd.h>
extern char **environ;
#endif

#if __has_include(<mach/vm_page_size.h>)
#include <mach/vm_page_size.h>
#endif

int _was_process_exited(int status) {
    return WIFEXITED(status);
}

int _get_exit_code(int status) {
    return WEXITSTATUS(status);
}

int _was_process_signaled(int status) {
    return WIFSIGNALED(status);
}

int _get_signal_code(int status) {
    return WTERMSIG(status);
}

int _was_process_suspended(int status) {
    return WIFSTOPPED(status);
}

#if TARGET_OS_LINUX
#include <stdio.h>

#ifndef SYS_pidfd_send_signal
#define SYS_pidfd_send_signal 424
#endif 

int _shims_snprintf(
    char * _Nonnull str,
    int len,
    const char * _Nonnull format,
    char * _Nonnull str1,
    char * _Nonnull str2
) {
    return snprintf(str, len, format, str1, str2);
}

int _pidfd_send_signal(int pidfd, int signal) {
    return syscall(SYS_pidfd_send_signal, pidfd, signal, NULL, 0);
}

#endif

#if __has_include(<mach/vm_page_size.h>)
vm_size_t _subprocess_vm_size(void) {
    // This shim exists because vm_page_size is not marked const, and therefore looks like global mutable state to Swift.
    return vm_page_size;
}
#endif

// MARK: - Private Helpers
static pthread_mutex_t _subprocess_fork_lock = PTHREAD_MUTEX_INITIALIZER;

static int _subprocess_block_everything_but_something_went_seriously_wrong_signals(sigset_t *old_mask) {
    sigset_t mask;
    int r = 0;
    r |= sigfillset(&mask);
    r |= sigdelset(&mask, SIGABRT);
    r |= sigdelset(&mask, SIGBUS);
    r |= sigdelset(&mask, SIGFPE);
    r |= sigdelset(&mask, SIGILL);
    r |= sigdelset(&mask, SIGKILL);
    r |= sigdelset(&mask, SIGSEGV);
    r |= sigdelset(&mask, SIGSTOP);
    r |= sigdelset(&mask, SIGSYS);
    r |= sigdelset(&mask, SIGTRAP);

    r |= pthread_sigmask(SIG_BLOCK, &mask, old_mask);
    return r;
}

#define _subprocess_precondition(__cond) do { \
    int eval = (__cond); \
    if (!eval) { \
        __builtin_trap(); \
    } \
} while(0)

#if __DARWIN_NSIG
#  define _SUBPROCESS_SIG_MAX __DARWIN_NSIG
#else
#  define _SUBPROCESS_SIG_MAX 32
#endif


// MARK: - Darwin (posix_spawn)
#if TARGET_OS_MAC
static int _subprocess_spawn_prefork(
    pid_t  * _Nonnull  pid,
    const char  * _Nonnull  exec_path,
    const posix_spawn_file_actions_t _Nullable * _Nonnull file_actions,
    const posix_spawnattr_t _Nullable * _Nonnull spawn_attrs,
    char * _Nullable const args[_Nonnull],
    char * _Nullable const env[_Nullable],
    uid_t * _Nullable uid,
    gid_t * _Nullable gid,
    int number_of_sgroups, const gid_t * _Nullable sgroups,
    int create_session,
    void (* _Nullable configurator)(void)
) {
#define write_error_and_exit int error = errno; \
    write(pipefd[1], &error, sizeof(error));\
    close(pipefd[1]); \
    _exit(EXIT_FAILURE)

    // Set `POSIX_SPAWN_SETEXEC` flag since we are forking ourselves
    short flags = 0;
    int rc = posix_spawnattr_getflags(spawn_attrs, &flags);
    if (rc != 0) {
        return rc;
    }

    rc = posix_spawnattr_setflags(
        (posix_spawnattr_t *)spawn_attrs, flags | POSIX_SPAWN_SETEXEC
    );
    if (rc != 0) {
        return rc;
    }
    // Setup pipe to catch exec failures from child
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return errno;
    }
    // Set FD_CLOEXEC so the pipe is automatically closed when exec succeeds
    flags = fcntl(pipefd[0], F_GETFD);
    if (flags == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }
    flags |= FD_CLOEXEC;
    if (fcntl(pipefd[0], F_SETFD, flags) == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }

    flags = fcntl(pipefd[1], F_GETFD);
    if (flags == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }
    flags |= FD_CLOEXEC;
    if (fcntl(pipefd[1], F_SETFD, flags) == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }

    // Finally, fork
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated"
    pid_t childPid = fork();
#pragma GCC diagnostic pop
    if (childPid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }

    if (childPid == 0) {
        // Child process
        close(pipefd[0]);  // Close unused read end

        // Perform setups
        if (number_of_sgroups > 0 && sgroups != NULL) {
            // POSIX doesn't define setgroups (only getgroups) and therefore makes no guarantee of async-signal-safety,
            // but we'll assume in practice it should be async-signal-safe on any reasonable platform based on the fact
            // that getgroups is async-signal-safe.
            if (setgroups(number_of_sgroups, sgroups) != 0) {
                write_error_and_exit;
            }
        }

        if (uid != NULL) {
            if (setuid(*uid) != 0) {
                write_error_and_exit;
            }
        }

        if (gid != NULL) {
            if (setgid(*gid) != 0) {
                write_error_and_exit;
            }
        }

        if (create_session != 0) {
            (void)setsid();
        }

        // Run custom configuratior
        if (configurator != NULL) {
            configurator();
        }

        // Use posix_spawnas exec
        int error = posix_spawn(pid, exec_path, file_actions, spawn_attrs, args, env);
        // If we reached this point, something went wrong
        write(pipefd[1], &error, sizeof(error));
        close(pipefd[1]);
        _exit(EXIT_FAILURE);
    } else {
        // Parent process
        // Close unused write end
        close(pipefd[1]);
        // Communicate child pid back
        *pid = childPid;
        // Read from the pipe until pipe is closed
        // either due to exec succeeds or error is written
        while (TRUE) {
            int childError = 0;
            ssize_t read_rc = read(pipefd[0], &childError, sizeof(childError));
            if (read_rc == 0) {
                // exec worked!
                close(pipefd[0]);
                return 0;
            } else if (read_rc > 0) {
                // Child exec failed and reported back
                close(pipefd[0]);
                return childError;
            } else {
                // Read failed
                if (errno == EINTR) {
                    continue;
                } else {
                    close(pipefd[0]);
                    return errno;
                }
            }
        }
    }
}

int _subprocess_spawn(
    pid_t  * _Nonnull  pid,
    const char  * _Nonnull  exec_path,
    const posix_spawn_file_actions_t _Nullable * _Nonnull file_actions,
    const posix_spawnattr_t _Nullable * _Nonnull spawn_attrs,
    char * _Nullable const args[_Nonnull],
    char * _Nullable const env[_Nullable],
    uid_t * _Nullable uid,
    gid_t * _Nullable gid,
    int number_of_sgroups, const gid_t * _Nullable sgroups,
    int create_session,
    void (* _Nullable configurator)(void)
) {
    int require_pre_fork = uid != NULL ||
        gid != NULL ||
        number_of_sgroups > 0 ||
        create_session > 0 ||
        configurator != NULL;

    if (require_pre_fork != 0) {
        int rc = _subprocess_spawn_prefork(
            pid,
            exec_path,
            file_actions, spawn_attrs,
            args, env,
            uid, gid, number_of_sgroups, sgroups, create_session, configurator
        );
        return rc;
    }

    // Spawn
    return posix_spawn(pid, exec_path, file_actions, spawn_attrs, args, env);
}

#endif // TARGET_OS_MAC

// MARK: - Linux (fork/exec + posix_spawn fallback)
#if TARGET_OS_LINUX || TARGET_OS_BSD
#ifndef __GLIBC_PREREQ
#define __GLIBC_PREREQ(maj, min) 0
#endif

#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif

int _pidfd_open(pid_t pid) {
    return syscall(SYS_pidfd_open, pid, 0);
}

// SYS_clone3 is only defined on Linux Kernel 5.3 and above
// Define our dummy value if it's not available (as is the case with Musl libc)
#ifndef SYS_clone3
#define SYS_clone3 435
#endif

#ifndef CLONE_PIDFD
#define CLONE_PIDFD 0x00001000
#endif

// Can't use clone_args from sched.h because only Glibc defines it; Musl does not (and there's no macro to detect Musl)
struct _subprocess_clone_args {
    uint64_t flags;
    uint64_t pidfd;
    uint64_t child_tid;
    uint64_t parent_tid;
    uint64_t exit_signal;
    uint64_t stack;
    uint64_t stack_size;
    uint64_t tls;
    uint64_t set_tid;
    uint64_t set_tid_size;
    uint64_t cgroup;
};

static int _clone3(int *pidfd) {
    struct _subprocess_clone_args args = {
        .flags = CLONE_PIDFD,       // Get a pidfd referring to child
        .pidfd = (uintptr_t)pidfd,  // Int pointer for the pidfd (int pidfd = -1;)
        .exit_signal = SIGCHLD,     // Ensure parent gets SIGCHLD
        .stack = 0,                 // No stack needed for separate address space
        .stack_size = 0,
        .parent_tid = 0,
        .child_tid = 0,
        .tls = 0
    };

    return syscall(SYS_clone3, &args, sizeof(args));
}

int _subprocess_fork_exec(
    pid_t * _Nonnull pid,
    int * _Nonnull pidfd,
    const char * _Nonnull exec_path,
    const char * _Nullable working_directory,
    const int file_descriptors[_Nonnull],
    char * _Nullable const args[_Nonnull],
    char * _Nullable const env[_Nullable],
    uid_t * _Nullable uid,
    gid_t * _Nullable gid,
    gid_t * _Nullable process_group_id,
    int number_of_sgroups, const gid_t * _Nullable sgroups,
    int create_session,
    void (* _Nullable configurator)(void)
) {
#define write_error_and_exit int error = errno; \
    write(pipefd[1], &error, sizeof(error));\
    close(pipefd[1]); \
    _exit(EXIT_FAILURE)

    // Setup pipe to catch exec failures from child
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return errno;
    }
    // Set FD_CLOEXEC so the pipe is automatically closed when exec succeeds
    short flags = fcntl(pipefd[0], F_GETFD);
    if (flags == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }
    flags |= FD_CLOEXEC;
    if (fcntl(pipefd[0], F_SETFD, flags) == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }

    flags = fcntl(pipefd[1], F_GETFD);
    if (flags == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }
    flags |= FD_CLOEXEC;
    if (fcntl(pipefd[1], F_SETFD, flags) == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }

    // Protect the signal masking below
    // Note that we only unlock in parent since child
    // will be exec'd anyway
    int rc = pthread_mutex_lock(&_subprocess_fork_lock);
    _subprocess_precondition(rc == 0);
    // Block all signals on this thread
    sigset_t old_sigmask;
    rc = _subprocess_block_everything_but_something_went_seriously_wrong_signals(&old_sigmask);
    if (rc != 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }

    // Finally, fork / clone
    int _pidfd = -1;
    // First attempt to use clone3, only fall back to fork if clone3 is not available
    pid_t childPid = _clone3(&_pidfd);
    if (childPid < 0) {
        if (errno == ENOSYS) {
            // clone3 is not implemented. Use fork instead
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated"
            childPid = fork();
#pragma GCC diagnostic pop
        } else {
            // Report all other errors
            close(pipefd[0]);
            close(pipefd[1]);
            return errno;
        }
    }

    if (childPid < 0) {
        // Fork failed
        close(pipefd[0]);
        close(pipefd[1]);
        return errno;
    }

    if (childPid == 0) {
        // Child process
        // Reset signal handlers
        for (int signo = 1; signo < _SUBPROCESS_SIG_MAX; signo++) {
            if (signo == SIGKILL || signo == SIGSTOP) {
                continue;
            }
            void (*err_ptr)(int) = signal(signo, SIG_DFL);
            if (err_ptr != SIG_ERR) {
                continue;
            }

            if (errno == EINVAL) {
                break; // probably too high of a signal
            }

            write_error_and_exit;
        }

        // Reset signal mask
        sigset_t sigset = { 0 };
        sigemptyset(&sigset);
        int rc = sigprocmask(SIG_SETMASK, &sigset, NULL) != 0;
        if (rc != 0) {
            write_error_and_exit;
        }

        // Perform setups
        if (working_directory != NULL) {
            if (chdir(working_directory) != 0) {
                write_error_and_exit;
            }
        }

        if (uid != NULL) {
            if (setuid(*uid) != 0) {
                write_error_and_exit;
            }
        }

        if (gid != NULL) {
            if (setgid(*gid) != 0) {
                write_error_and_exit;
            }
        }

        if (number_of_sgroups > 0 && sgroups != NULL) {
            // POSIX doesn't define setgroups (only getgroups) and therefore makes no guarantee of async-signal-safety,
            // but we'll assume in practice it should be async-signal-safe on any reasonable platform based on the fact
            // that getgroups is async-signal-safe.
            if (setgroups(number_of_sgroups, sgroups) != 0) {
                write_error_and_exit;
            }
        }

        if (create_session != 0) {
            (void)setsid();
        }

        if (process_group_id != NULL) {
            (void)setpgid(0, *process_group_id);
        }

        // Bind stdin, stdout, and stderr
        if (file_descriptors[0] >= 0) {
            rc = dup2(file_descriptors[0], STDIN_FILENO);
        } else {
            rc = close(STDIN_FILENO);
        }
        if (rc < 0) {
            write_error_and_exit;
        }

        if (file_descriptors[2] >= 0) {
            rc = dup2(file_descriptors[2], STDOUT_FILENO);
        } else {
            rc = close(STDOUT_FILENO);
        }
        if (rc < 0) {
            write_error_and_exit;
        }

        if (file_descriptors[4] >= 0) {
            rc = dup2(file_descriptors[4], STDERR_FILENO);
        } else {
            rc = close(STDERR_FILENO);
        }
        if (rc < 0) {
            write_error_and_exit;
        }

        // Close parent side
        if (file_descriptors[1] >= 0) {
            rc = close(file_descriptors[1]);
        }
        if (file_descriptors[3] >= 0) {
            rc = close(file_descriptors[3]);
        }
        if (file_descriptors[5] >= 0) {
            rc = close(file_descriptors[5]);
        }

        if (rc < 0) {
            write_error_and_exit;
        }

        // Run custom configuratior
        if (configurator != NULL) {
            configurator();
        }
        // Finally, exec
        execve(exec_path, args, env);
        // If we reached this point, something went wrong
        write_error_and_exit;
    } else {
#define reap_child_process_and_return_errno int capturedError = errno; \
    close(pipefd[0]); \
    siginfo_t info; \
    waitid(P_PID, childPid, &info, WEXITED); \
    return capturedError

        // On Linux 5.3 and lower, we have to fetch pidfd separately
        // Newer Linux supports clone3 which returns pidfd directly
        if (_pidfd < 0) {
            _pidfd = _pidfd_open(childPid);
            if (_pidfd < 0) {
                reap_child_process_and_return_errno;
            }
        }

        // Parent process
        close(pipefd[1]);  // Close unused write end

        // Restore old signmask
        rc = pthread_sigmask(SIG_SETMASK, &old_sigmask, NULL);
        if (rc != 0) {
            reap_child_process_and_return_errno;
        }

        // Unlock
        rc = pthread_mutex_unlock(&_subprocess_fork_lock);
        _subprocess_precondition(rc == 0);

        // Communicate child pid back
        *pid = childPid;
        *pidfd = _pidfd;
        // Read from the pipe until pipe is closed
        // either due to exec succeeds or error is written
        while (1) {
            int childError = 0;
            ssize_t read_rc = read(pipefd[0], &childError, sizeof(childError));
            if (read_rc == 0) {
                // exec worked!
                close(pipefd[0]);
                return 0;
            }
            // if we reach this point, exec failed.
            // Since we already have the child pid (fork succeed), reap the child
            // This mimic posix_spawn behavior
            siginfo_t info;
            waitid(P_PID, childPid, &info, WEXITED);

            if (read_rc > 0) {
                // Child exec failed and reported back
                close(pipefd[0]);
                return childError;
            } else {
                // Read failed
                if (errno == EINTR) {
                    continue;
                } else {
                    close(pipefd[0]);
                    return errno;
                }
            }
        }
    }
}

#endif // TARGET_OS_LINUX

#endif // !TARGET_OS_WINDOWS

#pragma mark - Environment Locking

#if __has_include(<libc_private.h>)
#import <libc_private.h>
void _subprocess_lock_environ(void) {
    environ_lock_np();
}

void _subprocess_unlock_environ(void) {
    environ_unlock_np();
}
#else
void _subprocess_lock_environ(void) { /* noop */ }
void _subprocess_unlock_environ(void) { /* noop */ }
#endif

char ** _subprocess_get_environ(void) {
#if __has_include(<crt_externs.h>)
    return *_NSGetEnviron();
#elif defined(_WIN32)
#include <stdlib.h>
    return _environ;
#elif TARGET_OS_WASI
    return __wasilibc_get_environ();
#elif __has_include(<unistd.h>)
    return environ;
#endif
}


#if TARGET_OS_WINDOWS

typedef struct {
    DWORD pid;
    HWND mainWindow;
} CallbackContext;

static BOOL CALLBACK enumWindowsCallback(
    HWND hwnd,
    LPARAM lParam
) {
    CallbackContext *context = (CallbackContext *)lParam;
    DWORD pid;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == context->pid) {
        context->mainWindow = hwnd;
        return FALSE; // Stop enumeration
    }
    return TRUE; // Continue enumeration
}

BOOL _subprocess_windows_send_vm_close(
    DWORD pid
) {
    // First attempt to find the Window associate
    // with this process
    CallbackContext context = {0};
    context.pid = pid;
    EnumWindows(enumWindowsCallback, (LPARAM)&context);

    if (context.mainWindow != NULL) {
        if (SendMessage(context.mainWindow, WM_CLOSE, 0, 0)) {
            return TRUE;
        }
    }

    return FALSE;
}

unsigned int _subprocess_windows_get_errno(void) {
    return errno;
}

#endif


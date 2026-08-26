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
#include <string.h>
#include <fcntl.h>
#include <pthread.h>
#include <dirent.h>
#include <dlfcn.h>
#include <stdio.h>
#include <limits.h>

#if __has_include(<linux/close_range.h>)
#include <linux/close_range.h>
#endif

#include <sys/syscall.h>
#include <sys/utsname.h>
#include <sys/wait.h>

#if __has_include(<paths.h>)
// For _PATH_STDPATH / _PATH_DEFPATH
#include <paths.h>
#endif

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

#if TARGET_OS_MAC
// For posix_spawnattr_set_qos_class_np.
#include <pthread/spawn.h>
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

uint64_t _subprocess_nofile_soft_limit(void) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) {
        return 0;
    }
    return (uint64_t)rl.rlim_cur;
}

size_t _subprocess_default_search_path(char * _Nullable buffer, size_t size) {
    // `confstr(_CS_PATH)` is the POSIX query for the standard path, and is
    // preferred because the C library answers for the running system. Bionic
    // only declares it from API level 26, so Android uses its `<paths.h>`
    // macro instead rather than raising this package's minimum API level.
#if defined(_CS_PATH) && !defined(__ANDROID__)
    size_t queried = confstr(_CS_PATH, buffer, size);
    if (queried > 0) {
        return queried;
    }
#endif

    // Fall back to the standard path fixed at compile time. `_PATH_STDPATH` is
    // the system utility path on Darwin and the BSDs and with glibc;
    // `_PATH_DEFPATH` is what Bionic and musl provide.
#if defined(_PATH_STDPATH)
    const char *standardPath = _PATH_STDPATH;
#elif defined(_PATH_DEFPATH)
    const char *standardPath = _PATH_DEFPATH;
#else
    const char *standardPath = NULL;
#endif

    if (standardPath == NULL) {
        return 0;
    }
    size_t required = strlen(standardPath) + 1;
    if (buffer != NULL && size > 0) {
        // Truncate and terminate the way `confstr` does, so the caller can
        // detect the short buffer from the returned size alone.
        strncpy(buffer, standardPath, size - 1);
        buffer[size - 1] = '\0';
    }
    return required;
}

int _subprocess_pthread_create(
#if TARGET_OS_MAC || defined(__FreeBSD__) || defined(__OpenBSD__) || TARGET_LIBC_MUSL
    pthread_t _Nullable * _Nonnull ptr,
#else
    pthread_t * _Nonnull ptr,
#endif
    pthread_attr_t const * _Nullable attr,
    void * _Nullable (* _Nonnull start)(void * _Nullable),
    void * _Nullable context
) {
    return pthread_create(ptr, attr, start, context);
}

#endif

#if __has_include(<mach/vm_page_size.h>)
vm_size_t _subprocess_vm_size(void) {
    // This shim exists because vm_page_size is not marked const, and therefore looks like global mutable state to Swift.
    return vm_page_size;
}
#endif

#if TARGET_OS_MAC || TARGET_OS_UNIX
static void _subprocess_reap_pid(pid_t pid) {
    siginfo_t info;
    int rc;
    do {
        rc = waitid(P_PID, pid, &info, WEXITED);
    } while (rc == -1 && errno == EINTR);
}
#endif

// MARK: - posix_spawn capabilities

#if _POSIX_SPAWN

typedef int (* _subprocess_addclosefrom_t)(posix_spawn_file_actions_t *, int);
typedef int (* _subprocess_addfchdir_t)(posix_spawn_file_actions_t *, int);

static uint32_t _subprocess_spawn_caps = 0;
static _subprocess_addclosefrom_t _subprocess_addclosefrom_impl = NULL;
static _subprocess_addfchdir_t _subprocess_addfchdir_impl = NULL;
static pthread_once_t _subprocess_spawn_caps_once = PTHREAD_ONCE_INIT;

// Both call sites are behind the corresponding #ifdef, so on a platform that
// defines neither flag -- FreeBSD and OpenBSD define no POSIX_SPAWN_CLOEXEC_DEFAULT
// and no POSIX_SPAWN_SETSID -- this would be an unused function warning.
#if !TARGET_OS_MAC && (defined(POSIX_SPAWN_CLOEXEC_DEFAULT) || defined(POSIX_SPAWN_SETSID))
/// Whether `posix_spawnattr_setflags` accepts `flag`.
///
/// Bionic rejects unknown flags with `EINVAL`, so this detects a pre-Android-13
/// runtime with no version sniffing at all.
static int _subprocess_spawnattr_accepts_flag(short flag) {
    posix_spawnattr_t attrs;
    if (posix_spawnattr_init(&attrs) != 0) {
        return 0;
    }
    int rc = posix_spawnattr_setflags(&attrs, flag);
    (void)posix_spawnattr_destroy(&attrs);
    return rc == 0;
}
#endif

static void _subprocess_spawn_caps_init(void) {
    uint32_t caps = 0;

#if TARGET_OS_MAC
    // Nothing is probed: the macOS 13 deployment target already covers
    // POSIX_SPAWN_CLOEXEC_DEFAULT (10.7), POSIX_SPAWN_SETSID (10.12) and
    // posix_spawn_file_actions_addfchdir_np (10.15).
    caps |= _SUBPROCESS_SPAWN_CAP_CLOEXEC_DEFAULT;
    caps |= _SUBPROCESS_SPAWN_CAP_SETSID_FLAG;

    // TARGET_OS_OSX, not TARGET_OS_MAC: the latter is every Apple platform, and
    // the SDK marks posix_spawn_file_actions_addfchdir_np
    // __API_UNAVAILABLE(ios, tvos, watchos, visionos). Referring to it at all on
    // those platforms is a hard error, not a deprecation warning, and that
    // includes Mac Catalyst, which reports as iOS even though it runs on macOS.
    // Leaving the capability unset there routes a working directory to the
    // fallback path via rule 5, where the child chdirs itself.
    //
    // The _np spelling is deprecated as of macOS 26 in favour of
    // posix_spawn_file_actions_addfchdir, but that replacement is macOS 26+
    // only, so with a macOS 13 deployment target the _np name is the one that
    // exists everywhere this runs.
    //
    // FIXME: use posix_spawn_file_actions_addfchdir and drop this pragma once
    // the deployment target can be raised to macOS 26.
#if TARGET_OS_OSX
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _subprocess_addfchdir_impl = posix_spawn_file_actions_addfchdir_np;
#pragma clang diagnostic pop
    caps |= _SUBPROCESS_SPAWN_CAP_CHDIR_ACTION;
#endif
#else
    // dlsym rather than a weak symbol reference. glibc versions these symbols
    // (addclosefrom_np is GLIBC_2.34), and a weak reference to a symbol that
    // exists at a *newer version* than the one present is not reliably resolved
    // to NULL, whereas dlsym cannot fail at load time. Uniform across Linux,
    // Android and the BSDs so no header-version gate is needed either: FreeBSD
    // grew these actions in 13.1 and OpenBSD has none of them.
    _subprocess_addclosefrom_impl = (_subprocess_addclosefrom_t)dlsym(
        RTLD_DEFAULT, "posix_spawn_file_actions_addclosefrom_np"
    );
    _subprocess_addfchdir_impl = (_subprocess_addfchdir_t)dlsym(
        RTLD_DEFAULT, "posix_spawn_file_actions_addfchdir_np"
    );
    if (_subprocess_addclosefrom_impl != NULL) {
        caps |= _SUBPROCESS_SPAWN_CAP_CLOSEFROM_ACTION;
    }
    if (_subprocess_addfchdir_impl != NULL) {
        caps |= _SUBPROCESS_SPAWN_CAP_CHDIR_ACTION;
    }
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    if (_subprocess_spawnattr_accepts_flag(POSIX_SPAWN_CLOEXEC_DEFAULT)) {
        caps |= _SUBPROCESS_SPAWN_CAP_CLOEXEC_DEFAULT;
    }
#endif
#ifdef POSIX_SPAWN_SETSID
    if (_subprocess_spawnattr_accepts_flag(POSIX_SPAWN_SETSID)) {
        caps |= _SUBPROCESS_SPAWN_CAP_SETSID_FLAG;
    }
#endif
#endif // TARGET_OS_MAC

    _subprocess_spawn_caps = caps;
}

uint32_t _subprocess_spawn_capabilities(void) {
    (void)pthread_once(&_subprocess_spawn_caps_once, _subprocess_spawn_caps_init);
    return _subprocess_spawn_caps;
}

// `file_actions` is `void *` rather than `posix_spawn_file_actions_t *` because
// the typedef is a pointer on Darwin, FreeBSD, OpenBSD and Bionic but a struct on
// glibc and musl. Swift imports a pointer-to-pointer parameter with an optional
// pointee and a pointer-to-struct parameter with a non-optional one, so no single
// Swift spelling fits both; an opaque pointer fits both.
int _subprocess_spawn_addclosefrom(void *file_actions, int from) {
    // Load-bearing, not defensive: `_subprocess_addclosefrom_impl` is written by
    // `_subprocess_spawn_caps_init`, and this call is what runs it under the
    // `pthread_once` that orders that write against the read below. Dropping it
    // would leave the read racing with initialization.
    (void)_subprocess_spawn_capabilities();
    if (_subprocess_addclosefrom_impl == NULL) {
        return ENOSYS;
    }
    return _subprocess_addclosefrom_impl(
        (posix_spawn_file_actions_t *)file_actions, from
    );
}

int _subprocess_spawn_addfchdir(void *file_actions, int fd) {
    // Load-bearing; see `_subprocess_spawn_addclosefrom` above.
    (void)_subprocess_spawn_capabilities();
    if (_subprocess_addfchdir_impl == NULL) {
        return ENOSYS;
    }
    return _subprocess_addfchdir_impl(
        (posix_spawn_file_actions_t *)file_actions, fd
    );
}

// MARK: - Opaque posix_spawn file actions and attributes
//
// See the header for why these exist. Each allocates storage for the real
// typedef and hands back an opaque pointer to it, so Swift never has to name a
// type whose imported shape differs between libcs.

void *_subprocess_spawn_file_actions_create(int *error) {
    posix_spawn_file_actions_t *file_actions = malloc(sizeof(*file_actions));
    if (file_actions == NULL) {
        *error = ENOMEM;
        return NULL;
    }
    int rc = posix_spawn_file_actions_init(file_actions);
    if (rc != 0) {
        free(file_actions);
        *error = rc;
        return NULL;
    }
    *error = 0;
    return file_actions;
}

void _subprocess_spawn_file_actions_free(void *file_actions) {
    if (file_actions == NULL) {
        return;
    }
    (void)posix_spawn_file_actions_destroy(
        (posix_spawn_file_actions_t *)file_actions
    );
    free(file_actions);
}

int _subprocess_spawn_file_actions_adddup2(void *file_actions, int fd, int new_fd) {
    return posix_spawn_file_actions_adddup2(
        (posix_spawn_file_actions_t *)file_actions, fd, new_fd
    );
}

int _subprocess_spawn_file_actions_addclose(void *file_actions, int fd) {
    return posix_spawn_file_actions_addclose(
        (posix_spawn_file_actions_t *)file_actions, fd
    );
}

void *_subprocess_spawnattr_create(int *error) {
    posix_spawnattr_t *spawn_attrs = malloc(sizeof(*spawn_attrs));
    if (spawn_attrs == NULL) {
        *error = ENOMEM;
        return NULL;
    }
    int rc = posix_spawnattr_init(spawn_attrs);
    if (rc != 0) {
        free(spawn_attrs);
        *error = rc;
        return NULL;
    }
    *error = 0;
    return spawn_attrs;
}

void _subprocess_spawnattr_free(void *spawn_attrs) {
    if (spawn_attrs == NULL) {
        return;
    }
    (void)posix_spawnattr_destroy((posix_spawnattr_t *)spawn_attrs);
    free(spawn_attrs);
}

int _subprocess_spawnattr_reset_signals(void *spawn_attrs) {
    sigset_t no_signals;
    sigset_t all_signals;
    if (sigemptyset(&no_signals) != 0) {
        return errno;
    }
    if (sigfillset(&all_signals) != 0) {
        return errno;
    }
    // SIGKILL and SIGSTOP must be excluded, not merely tolerated. Bionic's
    // POSIX_SPAWN_SETSIGDEF loop calls sigaction() unconditionally for every
    // member of this set, and Linux rejects sigaction() on those two with
    // EINVAL even when the disposition asked for is SIG_DFL
    // (SIG_KERNEL_ONLY_MASK in the kernel's do_sigaction). Bionic then
    // _exit(127)s the child before it reaches execve, and posix_spawn still
    // returns 0, so every spawn would look like a program that launched and
    // exited 127. Excluding them costs nothing anywhere: neither can be caught
    // or ignored, so neither can have a disposition that needs resetting.
    // The fork/exec path skips them for the same reason.
    if (sigdelset(&all_signals, SIGKILL) != 0) {
        return errno;
    }
    if (sigdelset(&all_signals, SIGSTOP) != 0) {
        return errno;
    }
    int rc = posix_spawnattr_setsigmask(
        (posix_spawnattr_t *)spawn_attrs, &no_signals
    );
    if (rc != 0) {
        return rc;
    }
    return posix_spawnattr_setsigdefault(
        (posix_spawnattr_t *)spawn_attrs, &all_signals
    );
}

int _subprocess_spawnattr_setflags(void *spawn_attrs, short flags) {
    return posix_spawnattr_setflags((posix_spawnattr_t *)spawn_attrs, flags);
}

int _subprocess_spawnattr_setpgroup(void *spawn_attrs, pid_t pgroup) {
    return posix_spawnattr_setpgroup((posix_spawnattr_t *)spawn_attrs, pgroup);
}

#if TARGET_OS_MAC
int _subprocess_spawnattr_set_qos_class(void *spawn_attrs, int qos_class) {
    return posix_spawnattr_set_qos_class_np(
        (posix_spawnattr_t *)spawn_attrs, (qos_class_t)qos_class
    );
}
#endif // TARGET_OS_MAC

int _subprocess_spawn(
    pid_t * _Nonnull pid,
    int * _Nonnull pidfd,
    const char * _Nonnull exec_path,
    const void * _Nullable file_actions,
    const void * _Nullable spawn_attrs,
    char * _Nullable const args[_Nonnull],
    char * _Nullable const env[_Nullable]
) {
    *pidfd = -1;
    // NULL is meaningful for both: posix_spawn reads it as "no file actions" and
    // "no attributes".
    int rc = posix_spawn(
        pid, exec_path,
        (const posix_spawn_file_actions_t *)file_actions,
        (const posix_spawnattr_t *)spawn_attrs,
        args, env
    );
#if TARGET_OS_LINUX
    if (rc == 0) {
        // pidfd_open on a child that has not been reaped always succeeds:
        // pidfd_prepare only reports ESRCH once the task has been reaped, and
        // nothing reaps our children before we do. A kernel older than 5.3
        // returns -1, which the caller treats as "monitor by SIGCHLD".
        *pidfd = _pidfd_open(*pid);
    }
#endif
    return rc;
}

short _subprocess_spawn_flag_cloexec_default(void) {
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    return (short)POSIX_SPAWN_CLOEXEC_DEFAULT;
#else
    return 0;
#endif
}

short _subprocess_spawn_flag_setsid(void) {
#ifdef POSIX_SPAWN_SETSID
    return (short)POSIX_SPAWN_SETSID;
#else
    return 0;
#endif
}

short _subprocess_spawn_flags_reset_signals(void) {
    return (short)(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
}

short _subprocess_spawn_flag_setpgroup(void) {
    return (short)POSIX_SPAWN_SETPGROUP;
}

#endif // _POSIX_SPAWN

// Declared in the header's `!TARGET_OS_WINDOWS` section: Windows has no
// `O_DIRECTORY` (nor `O_SEARCH`/`O_PATH`), and nothing there opens a directory
// to `fchdir` from.
#if !TARGET_OS_WINDOWS

int _subprocess_open_directory_flags(void) {
#if defined(O_SEARCH)
    // O_DIRECTORY is explicit: only Darwin defines O_SEARCH as
    // (O_EXEC | O_DIRECTORY). FreeBSD defines it as plain O_EXEC and musl as
    // plain O_PATH, so without O_DIRECTORY this would happily open a regular
    // executable file.
    return O_SEARCH | O_DIRECTORY | O_CLOEXEC;
#elif defined(O_PATH)
    return O_PATH | O_DIRECTORY | O_CLOEXEC;
#else
    return O_RDONLY | O_DIRECTORY | O_CLOEXEC;
#endif
}

int _subprocess_can_open_directory_for_search(void) {
#if defined(O_SEARCH) || defined(O_PATH)
    return 1;
#else
    return 0;
#endif
}

int _subprocess_faccessat_eaccess_flag(void) {
#if defined(__BIONIC__)
    // Bionic rejects every nonzero flag with EINVAL -- AT_EACCESS included, on
    // the stated grounds that Android has no set-uid programs and never runs
    // code with euid != uid. Passing 0 there checks the real IDs instead, which
    // by that same reasoning is the same answer.
    return 0;
#else
    return AT_EACCESS;
#endif
}

#endif // !TARGET_OS_WINDOWS

// MARK: - Darwin (posix_spawn)
#if TARGET_OS_MAC
int _subprocess_spawn_prefork(
    pid_t  * _Nonnull  pid,
    const char  * _Nonnull  exec_path,
    const void * _Nullable file_actions,
    const void * _Nonnull spawn_attrs,
    char * _Nullable const args[_Nonnull],
    char * _Nullable const env[_Nullable],
    uid_t * _Nullable uid,
    gid_t * _Nullable gid,
    int number_of_sgroups, const gid_t * _Nullable sgroups,
    int create_session
) {
#define write_error_and_exit int error = errno; \
    write(pipefd[1], &error, sizeof(error));\
    close(pipefd[1]); \
    _exit(EXIT_FAILURE)

    // Set `POSIX_SPAWN_SETEXEC` flag since we are forking ourselves. Unlike
    // `posix_spawn`, this needs real attributes to add the flag to.
    short flags = 0;
    int rc = posix_spawnattr_getflags(
        (const posix_spawnattr_t *)spawn_attrs, &flags
    );
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

        // Drop the group before the user. setuid() to a non-root uid clears
        // the capabilities/privileges, so a following setgid() would fail
        // with EPERM. https://github.com/swiftlang/swift-subprocess/issues/342
        if (gid != NULL) {
            if (setgid(*gid) != 0) {
                write_error_and_exit;
            }
        }

        if (uid != NULL) {
            if (setuid(*uid) != 0) {
                write_error_and_exit;
            }
        }

        if (create_session != 0) {
            (void)setsid();
        }

        // Use posix_spawnas exec
        int error = posix_spawn(
            pid, exec_path,
            (const posix_spawn_file_actions_t *)file_actions,
            (const posix_spawnattr_t *)spawn_attrs,
            args, env
        );
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
            }
            // Capture errno now, before close()/waitid() can overwrite it.
            int read_errno = errno;
            if (read_rc < 0 && read_errno == EINTR) {
                // Interrupted by a signal. Retry the read. Do not reap here;
                // the child is reaped exactly once below.
                continue;
            }
            // Setup or exec failed and the child has _exit()'d; reap it to
            // avoid a zombie. The plain (non-prefork) path delegates to
            // posix_spawn(), which reaps its own child on failure, so only
            // this manual-fork path needs an explicit reap.
            _subprocess_reap_pid(childPid);
            close(pipefd[0]);
            if (read_rc > 0) {
                // Child reported its errno back
                return childError;
            } else {
                return read_errno;
            }
        }
    }
}

#endif // TARGET_OS_MAC

// MARK: - Linux/BSD (fork/exec + posix_spawn fallback)
#if TARGET_OS_UNIX && !TARGET_OS_MAC

#if TARGET_OS_LINUX
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif

int _pidfd_open(pid_t pid) {
    return syscall(SYS_pidfd_open, pid, 0);
}

// SYS_pidfd_send_signal is only defined on Linux Kernel 5.1 and above
// Define our dummy value if it's not available
#ifndef SYS_pidfd_send_signal
#define SYS_pidfd_send_signal 424
#endif

int _pidfd_send_signal(int pidfd, int signal) {
    return syscall(SYS_pidfd_send_signal, pidfd, signal, NULL, 0);
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

struct linux_dirent64 {
    unsigned long d_ino;
    unsigned long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[];
};

static int _getdents64(int fd, struct linux_dirent64 *dirp, size_t nbytes) {
    return syscall(SYS_getdents64, fd, dirp, nbytes);
}

// SYS_close_range is only defined on Linux Kernel 5.9 and above.
// Define our value if it's not available and call the syscall directly because
// glibc < 2.34 (e.g. Amazon Linux 2) doesn't provide a close_range() wrapper.
#ifndef SYS_close_range
#define SYS_close_range 436
#endif

#ifndef CLOSE_RANGE_CLOEXEC
#define CLOSE_RANGE_CLOEXEC (1U << 2)
#endif

static int _close_range(unsigned int first, unsigned int last, unsigned int flags) {
    return syscall(SYS_close_range, first, last, flags);
}

int _subprocess_install_sigchld_handler(void (*handler)(int)) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handler;
    sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
    sigemptyset(&sa.sa_mask);
    return sigaction(SIGCHLD, &sa, NULL);
}
#endif

// FIXME: once FreeBSD 15.1 can be required, set posix_spawnattr_setprocdescp_np
// on the posix_spawn path so FreeBSD gets a process descriptor there too, and
// stops being the one platform where preferring posix_spawn costs the
// descriptor. Added to FreeBSD in January 2026: present in stable/15, absent
// from releng/15.0.
static pid_t _subprocess_pdfork(int *fdp) {
#if TARGET_OS_LINUX
    return _clone3(fdp); // CLONE_PIDFD always sets close-on-exec on the fd
#elif TARGET_OS_FREEBSD
    return pdfork(fdp, PD_CLOEXEC);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int _subprocess_pdkill(int pidfd, int signal) {
#if TARGET_OS_LINUX
    return _pidfd_send_signal(pidfd, signal);
#elif TARGET_OS_FREEBSD
    return pdkill(pidfd, signal);
#else
    errno = ENOSYS;
    return -1;
#endif
}

static pthread_mutex_t _subprocess_fork_lock = PTHREAD_MUTEX_INITIALIZER;

static int _subprocess_make_critical_mask(sigset_t *old_mask) {
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

#if defined(NSIG_MAX)           /* POSIX issue 8 */
# define _SUBPROCESS_SIG_MAX NSIG_MAX
#elif defined(__DARWIN_NSIG)    /* Darwin */
# define _SUBPROCESS_SIG_MAX __DARWIN_NSIG
#elif defined(_SIG_MAXSIG)      /* FreeBSD */
# define _SUBPROCESS_SIG_MAX _SIG_MAXSIG
#elif defined(_SIGMAX)          /* QNX */
# define _SUBPROCESS_SIG_MAX (_SIGMAX + 1)
#elif defined(NSIG)             /* 99% of everything else */
# define _SUBPROCESS_SIG_MAX NSIG
#else                           /* Last resort */
# define _SUBPROCESS_SIG_MAX (sizeof(sigset_t) * CHAR_BIT + 1)
#endif

#if !TARGET_OS_FREEBSD
int _shims_snprintf(
    char * _Nonnull str,
    int len,
    const char * _Nonnull format,
    char * _Nonnull str1,
    char * _Nonnull str2
) {
    return snprintf(str, len, format, str1, str2);
}
#endif

static int _positive_int_parse(const char *str) {
    char *end;
    long value = strtol(str, &end, 10);
    if (end == str) {
        // No digits found
        return -1;
    }
    if (errno == ERANGE || value <= 0 || value > INT_MAX) {
        // Out of range
        return -1;
    }
    return (int)value;
}

#if defined(__linux__)
/// Set `FD_CLOEXEC` on all open file descriptors listed under `fd_dir` so
/// they are automatically closed upon `execve()`.
/// Safe to use after `vfork()` and before `execve()`
static void _set_cloexec_to_open_fds(const char *fd_dir) {
    int dir_fd = open(fd_dir, O_RDONLY);
    if (dir_fd < 0) {
        return;
    }

    // Buffer for directory entries - allocated on stack, no heap allocation
    char buffer[4096] = {0};

    while (1) {
        long bytes_read = _getdents64(dir_fd, (struct linux_dirent64 *)buffer, sizeof(buffer));
        if (bytes_read < 0) {
            if (errno == EINTR) {
                continue;
            } else {
                close(dir_fd);
                return;
            }
        }
        if (bytes_read == 0) {
            close(dir_fd);
            return;
        }
        long offset = 0;
        while (offset < bytes_read) {
            struct linux_dirent64 *entry = (struct linux_dirent64 *)(buffer + offset);
            // Skip "." and ".." entries
            if (entry->d_name[0] != '.') {
                int fd = _positive_int_parse(entry->d_name);
                if (fd > STDERR_FILENO && fd != dir_fd) {
                    int flags = fcntl(fd, F_GETFD);
                    if (flags >= 0) {
                        // Set FD_CLOEXEC on every open fd so they are closed after exec()
                        fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
                    }
                }
            }
            offset += entry->d_reclen;
        }
    }
}
#endif

// This function is only used on non-Linux systems.
static int _highest_possibly_open_fd(void) {
    return sysconf(_SC_OPEN_MAX);
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
    int create_session
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
    rc = _subprocess_make_critical_mask(&old_sigmask);
    if (rc != 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        pthread_mutex_unlock(&_subprocess_fork_lock);
        return errno;
    }

    // Finally, fork / clone
    int _pidfd = -1;
    // First attempt to create a process file descriptor on supported platforms, only fall back to fork if those are not available
    pid_t childPid = _subprocess_pdfork(&_pidfd);
    if (childPid < 0) {
        if (errno == ENOSYS) {
            // process file descriptor is not implemented. Use fork instead
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated"
            childPid = fork();
#pragma GCC diagnostic pop
        } else {
            // Report all other errors
            close(pipefd[0]);
            close(pipefd[1]);
            pthread_mutex_unlock(&_subprocess_fork_lock);
            return errno;
        }
    }

    if (childPid < 0) {
        // Fork failed
        close(pipefd[0]);
        close(pipefd[1]);
        pthread_mutex_unlock(&_subprocess_fork_lock);
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

        if (number_of_sgroups > 0 && sgroups != NULL) {
            // POSIX doesn't define setgroups (only getgroups) and therefore makes no guarantee of async-signal-safety,
            // but we'll assume in practice it should be async-signal-safe on any reasonable platform based on the fact
            // that getgroups is async-signal-safe.
            if (setgroups(number_of_sgroups, sgroups) != 0) {
                write_error_and_exit;
            }
        }

        // Drop the group before the user. setuid() to a non-root uid clears
        // the capabilities/privileges, so a following setgid() would fail
        // with EPERM. https://github.com/swiftlang/swift-subprocess/issues/342
        if (gid != NULL) {
            if (setgid(*gid) != 0) {
                write_error_and_exit;
            }
        }

        if (uid != NULL) {
            if (setuid(*uid) != 0) {
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
        // Close all other file descriptors
        rc = -1;
        errno = ENOSYS;
        #if defined(__linux__)
        // We must NOT close pipefd[1] for writing errors
        rc = _close_range(STDERR_FILENO + 1, pipefd[1] - 1, CLOSE_RANGE_CLOEXEC);
        rc |= _close_range(pipefd[1] + 1, ~0U, CLOSE_RANGE_CLOEXEC);
        #elif defined(__FreeBSD__)
        // We must NOT close pipefd[1] for writing errors
        rc = close_range(STDERR_FILENO + 1, pipefd[1] - 1, CLOSE_RANGE_CLOEXEC);
        rc |= close_range(pipefd[1] + 1, ~0U, CLOSE_RANGE_CLOEXEC);
        #elif defined(__OpenBSD__)
        // OpenBSD Supports closefrom, but not close_range
        // See https://man.openbsd.org/closefrom
        for (int fd = STDERR_FILENO + 1; fd <= pipefd[1] - 1; fd++) {
            close(fd);
        }
        rc = closefrom(pipefd[1] + 1);
        #endif
        if (rc != 0) {
            #if defined(__linux__)
            _set_cloexec_to_open_fds("/dev/fd");
            #else
            // close_range failed (or doesn't exist), fall back to setting FD_CLOEXEC
            int highest_open_fd = _highest_possibly_open_fd();
            for (int fd = STDERR_FILENO + 1; fd <= highest_open_fd; fd++) {
                // We must NOT close pipefd[1] for writing errors
                if (fd != pipefd[1]) {
                    int flags = fcntl(fd, F_GETFD);
                    if (flags >= 0) {
                        // Set FD_CLOEXEC on every open fd so they are closed after exec()
                        fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
                    }
                }
            }
            #endif
        }

        // Finally, exec
        execve(exec_path, args, env);
        // If we reached this point, something went wrong
        write_error_and_exit;
    } else {
#define reap_child_process_and_return_errno int capturedError = errno; \
    close(pipefd[0]); \
    _subprocess_reap_pid(childPid); \
    return capturedError

#if TARGET_OS_LINUX
        // On Linux 5.3 and lower, we have to fetch pidfd separately
        // Newer Linux supports clone3 which returns pidfd directly
        if (_pidfd < 0) {
            _pidfd = _pidfd_open(childPid);
        }
#endif

        // Parent process
        close(pipefd[1]);  // Close unused write end

        // Restore old signmask
        rc = pthread_sigmask(SIG_SETMASK, &old_sigmask, NULL);
        if (rc != 0) {
            pthread_mutex_unlock(&_subprocess_fork_lock);
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
            // Capture errno now, before close()/waitid() can overwrite it.
            int read_errno = errno;
            if (read_rc < 0 && read_errno == EINTR) {
                // Interrupted by a signal. Retry the read. Do not reap here;
                // the child is reaped exactly once below.
                continue;
            }
            // exec failed. Reap the child (mimics posix_spawn, which reaps on
            // exec failure) using the pid from the successful fork.
            _subprocess_reap_pid(childPid);
            close(pipefd[0]);
            if (read_rc > 0) {
                // Child exec failed and reported its errno back
                return childError;
            } else {
                return read_errno;
            }
        }
    }
}

#endif // TARGET_OS_UNIX && !TARGET_OS_MAC

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

errno_t _subprocess_windows_get_errno(void) {
    return errno;
}

DWORD_PTR _subprocess_PROC_THREAD_ATTRIBUTE_HANDLE_LIST(void) {
    return PROC_THREAD_ATTRIBUTE_HANDLE_LIST;
}

#endif


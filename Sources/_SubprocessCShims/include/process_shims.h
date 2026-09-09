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

#ifndef process_shims_h
#define process_shims_h

#include "target_conditionals.h"

#if !TARGET_OS_WINDOWS
#include <pthread.h>
#include <unistd.h>
#include <sys/resource.h>

#if _POSIX_SPAWN
#include <spawn.h>
#endif

#if TARGET_OS_LINUX
#include <sys/epoll.h>
#include <sys/signalfd.h>
#endif // TARGET_OS_LINUX

#if TARGET_OS_FREEBSD
#include <sys/procdesc.h>
#endif

#if TARGET_OS_LINUX || TARGET_OS_FREEBSD
#include <sys/eventfd.h>
#include <sys/wait.h>
#endif // TARGET_OS_LINUX || TARGET_OS_FREEBSD

// musl provides no identifying macro, so it is spelled as Linux that is
// neither glibc nor Bionic. Correct only after a libc header (<pthread.h>
// above) has put __GLIBC__ in scope, which is why this lives here and not in
// target_conditionals.h.
#if TARGET_OS_LINUX && !defined(__GLIBC__) && !defined(__ANDROID__)
#define TARGET_LIBC_MUSL 1
#else
#define TARGET_LIBC_MUSL 0
#endif // TARGET_LIBC_MUSL

#ifdef __cplusplus
extern "C" {
#endif

int _subprocess_pthread_create(
#if TARGET_OS_MAC || defined(__FreeBSD__) || defined(__OpenBSD__) || TARGET_LIBC_MUSL
    pthread_t _Nullable * _Nonnull ptr,
#else
    pthread_t * _Nonnull ptr,
#endif
#if defined(__FreeBSD__) || defined(__OpenBSD__)
    const pthread_attr_t _Nullable * _Nullable attr,
#else
    const pthread_attr_t * _Nullable attr,
#endif
    void * _Nullable (* _Nonnull start)(void * _Nullable),
    void * _Nullable context
);

#if TARGET_OS_MAC || TARGET_OS_UNIX
/// Creates a pipe, atomically marking both ends close-on-exec where the
/// platform/OS combination supports `pipe2(2)`. Falls back to `pipe()`
/// followed by `fcntl(F_SETFD, FD_CLOEXEC)` where the atomic primitive isn't
/// available, which (unlike `pipe2`) cannot avoid briefly leaving the
/// descriptors inheritable to a `fork()` racing on another thread.
int _subprocess_pipe_cloexec(int fildes[_Nonnull 2]);

/// Duplicates `fildes` onto `fildes2` (as `dup2` would), atomically marking
/// the new descriptor close-on-exec where the platform/OS combination
/// supports `dup3(2)`. As with a raw `dup3()` call, `fildes` must not equal
/// `fildes2` (returns `EINVAL` otherwise, even on the `dup2`-based fallback
/// path).
///
/// No caller needs this yet; provided for parity with
/// `_subprocess_pipe_cloexec` so a future one doesn't have to reimplement
/// the same SDK-availability handling.
int _subprocess_dup3_cloexec(int fildes, int fildes2);

/// Duplicates `fildes` onto the lowest-numbered unused descriptor, marking
/// the new descriptor close-on-exec.
///
/// Implemented with `fcntl(F_DUPFD_CLOEXEC)`, which -- unlike `pipe2`/`dup3`
/// above -- has been available on Darwin, Linux, and the BSDs for a long
/// time, so no SDK-availability fallback is needed here.
int _subprocess_dup_cloexec(int fildes);
#endif // TARGET_OS_MAC || TARGET_OS_UNIX

#if __has_include(<mach/vm_page_size.h>)
vm_size_t _subprocess_vm_size(void);
#endif

#if TARGET_OS_MAC
int _subprocess_spawn(
    pid_t * _Nonnull pid,
    const char * _Nonnull exec_path,
    const posix_spawn_file_actions_t _Nullable * _Nonnull file_actions,
    const posix_spawnattr_t _Nullable * _Nonnull spawn_attrs,
    char * _Nullable const args[_Nonnull],
    char * _Nullable const env[_Nullable],
    uid_t * _Nullable uid,
    gid_t * _Nullable gid,
    int number_of_sgroups, const gid_t * _Nullable sgroups,
    int create_session
);
#endif // TARGET_OS_MAC

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
);

int _was_process_exited(int status);
int _get_exit_code(int status);
int _was_process_signaled(int status);
int _get_signal_code(int status);
int _was_process_suspended(int status);

/// Returns the soft RLIMIT_NOFILE value for the current process, or 0 on
/// error.  Implemented in C so that RLIMIT_NOFILE always resolves to the
/// correct type regardless of how the Swift Glibc/Darwin overlay imports it.
uint64_t _subprocess_nofile_soft_limit(void);

/// Writes the system's standard `PATH` value into `buffer`.
///
/// Follows the `confstr(3)` protocol: returns the buffer size required to hold
/// the value including its null terminator, and writes at most `size` bytes,
/// truncating and null-terminating if the value does not fit. Returns 0 when
/// the platform reports no standard path, in which case nothing is written.
size_t _subprocess_default_search_path(char * _Nullable buffer, size_t size);

void _subprocess_lock_environ(void);
void _subprocess_unlock_environ(void);
char * _Nullable * _Nullable _subprocess_get_environ(void);

int _subprocess_pdkill(int pidfd, int signal);

#if TARGET_OS_UNIX && !TARGET_OS_FREEBSD
int _shims_snprintf(
    char * _Nonnull str,
    int len,
    const char * _Nonnull format,
    char * _Nonnull str1,
    char * _Nonnull str2
);
#endif

#if TARGET_OS_LINUX
int _pidfd_open(pid_t pid);

// P_PIDFD is only defined on Linux Kernel 5.4 and above
// Define our value if it's not available
#ifndef P_PIDFD
#define P_PIDFD 3
#endif

int _subprocess_install_sigchld_handler(void (* _Nonnull handler)(int));

#endif

#ifdef __cplusplus
} // extern "C"
#endif

#endif // !TARGET_OS_WINDOWS

#if TARGET_OS_WINDOWS

#include <Windows.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef _WINDEF_
typedef unsigned long DWORD;
typedef int BOOL;
#endif

BOOL _subprocess_windows_send_vm_close(DWORD pid);
errno_t _subprocess_windows_get_errno(void);

/// Get the value of `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`.
///
/// This function is provided because `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` is a
/// complex macro and cannot be imported directly into Swift.
DWORD_PTR _subprocess_PROC_THREAD_ATTRIBUTE_HANDLE_LIST(void);

#ifdef __cplusplus
} // extern "C"
#endif

#endif

#endif /* process_shims_h */

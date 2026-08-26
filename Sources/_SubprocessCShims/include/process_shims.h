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

#if __has_include(<mach/vm_page_size.h>)
vm_size_t _subprocess_vm_size(void);
#endif

#if _POSIX_SPAWN

/// Bits returned by `_subprocess_spawn_capabilities()`.
///
/// `CLOEXEC_DEFAULT` and `CLOSEFROM_ACTION` are the two mechanisms by which
/// `posix_spawn` can be asked to close every inherited descriptor. When neither
/// is present, `posix_spawn` cannot be used: closing descriptors by enumerating
/// them in the parent would leak any descriptor another thread opens between the
/// enumeration and the spawn.
#define _SUBPROCESS_SPAWN_CAP_CLOEXEC_DEFAULT  (1u << 0)
#define _SUBPROCESS_SPAWN_CAP_CLOSEFROM_ACTION (1u << 1)
#define _SUBPROCESS_SPAWN_CAP_CHDIR_ACTION     (1u << 2)
#define _SUBPROCESS_SPAWN_CAP_SETSID_FLAG      (1u << 3)

/// The `posix_spawn` features this process can actually use, as a bitmask of
/// the `_SUBPROCESS_SPAWN_CAP_*` constants.
///
/// Resolved once, on first call, and cached. Detection is deliberately at
/// runtime: a binary built against one libc is expected to run against another,
/// so nothing here may be decided at compile time.
uint32_t _subprocess_spawn_capabilities(void);

/// Appends a "close every descriptor from `from` upwards" file action.
///
/// Returns `ENOSYS` when the platform has no such action, which callers must
/// treat as a programming error: check
/// `_SUBPROCESS_SPAWN_CAP_CLOSEFROM_ACTION` first.
int _subprocess_spawn_addclosefrom(void * _Nonnull file_actions, int from);

/// Appends an `fchdir` file action.
///
/// Returns `ENOSYS` when the platform has no such action, which callers must
/// treat as a programming error: check `_SUBPROCESS_SPAWN_CAP_CHDIR_ACTION`
/// first.
int _subprocess_spawn_addfchdir(void * _Nonnull file_actions, int fd);

// MARK: - Opaque posix_spawn file actions and attributes
//
// Every `posix_spawn_file_actions_*` and `posix_spawnattr_*` entry point the
// Swift side needs is wrapped here, taking an opaque `void *` handle.
//
// This is not indirection for its own sake: no single Swift spelling can call
// these functions on every platform. Swift imports
// `posix_spawn_file_actions_init` as taking
// `UnsafeMutablePointer<posix_spawn_file_actions_t?>` on Darwin, FreeBSD and
// OpenBSD, but `UnsafeMutablePointer<posix_spawn_file_actions_t>` on glibc, musl
// and Bionic, and those two types are not interconvertible. The difference is
// not the typedef shape alone — Bionic's typedef is a pointer like Darwin's, but
// its headers are nullability-audited, so the pointee imports as non-optional.
// An opaque handle sidesteps the question entirely and needs no per-platform
// conditional.
//
// Every wrapper returns the underlying libc return value unchanged, so the
// caller's existing errno mapping keeps working.

/// Allocates and initialises a `posix_spawn_file_actions_t`.
///
/// Returns NULL and sets `*error` to `ENOMEM`, or to what
/// `posix_spawn_file_actions_init` reported, on failure. The handle must be
/// released with `_subprocess_spawn_file_actions_free`.
void * _Nullable _subprocess_spawn_file_actions_create(int * _Nonnull error);

/// Destroys and frees a handle from
/// `_subprocess_spawn_file_actions_create`. Accepts NULL.
void _subprocess_spawn_file_actions_free(void * _Nullable file_actions);

/// Appends a `dup2` file action.
int _subprocess_spawn_file_actions_adddup2(
    void * _Nonnull file_actions, int fd, int new_fd
);

/// Appends a `close` file action.
int _subprocess_spawn_file_actions_addclose(void * _Nonnull file_actions, int fd);

/// Allocates and initialises a `posix_spawnattr_t`.
///
/// Returns NULL and sets `*error` on failure. The handle must be released with
/// `_subprocess_spawnattr_free`.
void * _Nullable _subprocess_spawnattr_create(int * _Nonnull error);

/// Destroys and frees a handle from `_subprocess_spawnattr_create`. Accepts
/// NULL.
void _subprocess_spawnattr_free(void * _Nullable spawn_attrs);

/// Sets an empty signal mask and a full set of default signal dispositions,
/// which is what `POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF` then applies.
///
/// Combined into one call because `sigemptyset` and `sigfillset` are macros
/// rather than functions on some platforms, so Swift cannot rely on calling
/// them.
int _subprocess_spawnattr_reset_signals(void * _Nonnull spawn_attrs);

/// Sets the spawn attribute flags.
int _subprocess_spawnattr_setflags(void * _Nonnull spawn_attrs, short flags);

/// Sets the process group the child joins, honoured with
/// `POSIX_SPAWN_SETPGROUP`.
int _subprocess_spawnattr_setpgroup(void * _Nonnull spawn_attrs, pid_t pgroup);

#if TARGET_OS_MAC
/// Sets the child's QoS class.
///
/// Darwin only, and Darwin accepts only `QOS_CLASS_UTILITY` and
/// `QOS_CLASS_BACKGROUND`, reporting `EINVAL` for anything else.
int _subprocess_spawnattr_set_qos_class(void * _Nonnull spawn_attrs, int qos_class);
#endif // TARGET_OS_MAC

/// The `POSIX_SPAWN_CLOEXEC_DEFAULT` flag value, or 0 where the platform has no
/// such flag.
///
/// Provided in C because the macro exists only in some libcs, so Swift cannot
/// reference it portably — there is no `#if canImport` for a macro.
short _subprocess_spawn_flag_cloexec_default(void);

/// The `POSIX_SPAWN_SETSID` flag value, or 0 where the platform has no such
/// flag. Provided in C for the same reason as
/// `_subprocess_spawn_flag_cloexec_default`.
short _subprocess_spawn_flag_setsid(void);

/// `POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF`, the flags that make the
/// attributes set by `_subprocess_spawnattr_reset_signals` take effect.
///
/// Provided in C so that the conversion to the `short` that
/// `posix_spawnattr_setflags` takes happens where the values are defined.
/// Converting in Swift instead would trap if a platform ever defined one above
/// `Int16.max`, which is a build no one would notice until it ran.
short _subprocess_spawn_flags_reset_signals(void);

/// The `POSIX_SPAWN_SETPGROUP` flag value. Provided in C for the same reason as
/// `_subprocess_spawn_flags_reset_signals`.
short _subprocess_spawn_flag_setpgroup(void);

#endif // _POSIX_SPAWN

/// The `open(2)` flags for a descriptor suitable for an `fchdir` file action.
///
/// `chdir(2)` requires only execute (search) permission on the directory, so
/// `O_RDONLY` would reject a directory that can legitimately be used as a
/// working directory. `O_SEARCH` (Darwin, FreeBSD) requires exactly that
/// permission and so matches `chdir`'s semantics.
///
/// `O_PATH` (glibc, musl, Bionic — accepted by `fchdir` since Linux 3.5) does
/// *not*: the kernel zeroes `acc_mode` for `O_PATH`, so it checks no permission
/// on the target at all and will happily open a directory with mode 000. It is
/// still the right flag to ask for, being the only one that does not demand read
/// permission, but the caller must check searchability separately -- see
/// `resolveWorkingDirectory()`, which does so against the returned descriptor.
///
/// `O_DIRECTORY` is always ORed in explicitly. Only Darwin defines `O_SEARCH` as
/// `(O_EXEC | O_DIRECTORY)`; FreeBSD defines it as plain `O_EXEC` and musl as
/// plain `O_PATH`, neither of which implies `O_DIRECTORY`, so without it
/// `open("/bin/sh", O_SEARCH)` would succeed on a regular executable file.
///
/// Only meaningful when `_subprocess_can_open_directory_for_search()` returns
/// nonzero; otherwise this falls back to `O_RDONLY`, which does not match
/// `chdir`'s semantics, and the caller must not open the directory at all.
///
/// Provided in C because these are macros only some platforms define, so Swift
/// cannot select between them portably — there is no `#if canImport` for a
/// macro.
int _subprocess_open_directory_flags(void);

/// Whether this platform can open a directory with search-only permission, and
/// so whether an `fchdir`-capable descriptor can be obtained without requiring
/// read permission on the directory.
///
/// Where this returns 0 the platform has no `fchdir` file action either, so a
/// working directory is always applied by `chdir` in the child and no descriptor
/// is needed.
int _subprocess_can_open_directory_for_search(void);

/// The `faccessat(2)` flags for a permission check that uses the effective IDs.
///
/// `AT_EACCESS` everywhere it works, so a set-uid host process is judged by the
/// IDs the child will actually be judged by rather than by its real ones. Bionic
/// rejects every nonzero flag with `EINVAL`, so it gets 0: Android has no set-uid
/// programs and never runs code with `euid != uid`, which is Bionic's own stated
/// reason for not supporting the flag, so the real IDs give the same answer there.
///
/// Provided in C because the choice depends on the C library, not the OS.
int _subprocess_faccessat_eaccess_flag(void);

#if _POSIX_SPAWN
/// Spawns a process with `posix_spawn`, reporting a process descriptor where the
/// platform provides one.
///
/// This expresses only what `posix_spawn` can express. A configuration that
/// needs `setuid`, `setgid`, `setgroups`, a session it cannot request through
/// an attribute, or descriptor closing the libc cannot perform must use
/// `_subprocess_spawn_prefork` (Darwin) or `_subprocess_fork_exec` (elsewhere)
/// instead; the caller decides, having consulted
/// `_subprocess_spawn_capabilities()`.
///
/// On success `*pid` is the child. `*pidfd` is a process descriptor on Linux and
/// Android, or `-1` on every other platform and whenever one could not be
/// obtained — a kernel older than 5.3 has no `pidfd_open`, which the caller's
/// `SIGCHLD` monitoring already handles.
int _subprocess_spawn(
    pid_t * _Nonnull pid,
    int * _Nonnull pidfd,
    const char * _Nonnull exec_path,
    const void * _Nullable file_actions,
    const void * _Nullable spawn_attrs,
    char * _Nullable const args[_Nonnull],
    char * _Nullable const env[_Nullable]
);
#endif // _POSIX_SPAWN

#if TARGET_OS_MAC
/// Forks, applies the privilege and session changes that have no `posix_spawn`
/// attribute, then uses `posix_spawn` with `POSIX_SPAWN_SETEXEC` as the exec.
///
/// This is the Darwin fallback path, so Darwin never reaches a raw `execve`. The
/// child's `errno` is relayed to the parent over a `CLOEXEC` pipe, and the child
/// is reaped here if it fails before exec.
int _subprocess_spawn_prefork(
    pid_t * _Nonnull pid,
    const char * _Nonnull exec_path,
    const void * _Nullable file_actions,
    const void * _Nonnull spawn_attrs,
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

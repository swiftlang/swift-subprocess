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
#include <unistd.h>

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

#endif

#endif // !TARGET_OS_WINDOWS

#if TARGET_OS_WINDOWS

#include <Windows.h>

#ifndef _WINDEF_
typedef unsigned long DWORD;
typedef int BOOL;
#endif

BOOL _subprocess_windows_send_vm_close(DWORD pid);
unsigned int _subprocess_windows_get_errno(void);

/// Get the value of `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`.
///
/// This function is provided because `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` is a
/// complex macro and cannot be imported directly into Swift.
DWORD_PTR _subprocess_PROC_THREAD_ATTRIBUTE_HANDLE_LIST(void);

#endif

#endif /* process_shims_h */

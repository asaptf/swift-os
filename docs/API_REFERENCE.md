# SwiftOS API Reference

This document is the consumer reference for the current SwiftOS EL0 API. It
covers the raw syscall ABI, the native Swift bridge, C compatibility layouts,
handle rights, and examples.

The build-time contracts are the headers in `userland/lib/` and
`userland/compat/`. This document mirrors those contracts for people writing or
porting applications.

## Public Header Map

Use this document for narrative guidance, but include the project headers when
building code:

| Header | Audience | Defines |
| --- | --- | --- |
| `userland/lib/syscall.h` | Raw C and low-level ports | Syscall numbers, inline syscall wrappers, mmap constants, handle rights |
| `userland/lib/swift_user.h` | Native Embedded Swift tools | `swiftos_*` bridge functions and Swift-friendly constants |
| `userland/lib/fs.h` | Raw C filesystem code | `stat`, `dirent`, open flags, file type helpers |
| `userland/lib/termios.h` | Raw C terminal code | Minimal `termios` layout and flags |
| `userland/compat/*` | newlib and C ports | POSIX-shaped declarations and compatibility shims |

The headers are the build contract. This reference should change in the same
commit whenever a public header or syscall dispatcher contract changes.

## Choosing An API Layer

SwiftOS exposes several layers over the same EL0 ABI. Choose the highest layer
that fits the program you are writing:

| Layer | Use it for | Include or entry point | Error convention |
| --- | --- | --- | --- |
| Native Swift bridge | First-party Embedded Swift tools and new SwiftOS applications | `-import-objc-header userland/lib/swift_user.h` | Most helpers return negative errno-like values; address-returning helpers return 0 on failure |
| Raw C syscall wrappers | ABI probes, very small utilities, and tests that need exact kernel behavior | `#include "lib/syscall.h"` | Negative errno-like values are returned directly |
| C filesystem/terminal headers | Small C programs that want SwiftOS layouts without newlib | `lib/fs.h`, `lib/termios.h` | Negative errno-like values are returned directly |
| newlib compatibility | Larger C ports and POSIX-shaped source builds | `crt0_newlib.o`, `newlib_syscalls.o`, `userland/compat/*`, newlib | Most failures become `-1` plus `errno` |
| User commands | Normal administration and package workflows | `/bin/pkg`, `/bin/top`, `/bin/ps`, shell tools | Human-readable command output and exit status |

Prefer the native Swift bridge for new SwiftOS programs. Prefer newlib only
when porting existing C code that expects POSIX-shaped declarations. Avoid
calling raw syscalls from application code unless you need an ABI test or a
feature that has no bridge helper yet.

## API Recipe Index

The fastest path to a correct program is to start from a shipped userland
example that already boots in QEMU. Use this index to find the closest working
source, then follow its Makefile rule and acceptance test.

| Task | Start from | Main API surface | Verification |
| --- | --- | --- | --- |
| Minimal native Swift command | `userland/echo.swift`, `userland/pwd.swift` | `swiftos_puts`, `swiftos_write`, `swiftos_getcwd` | `./tests/swift_coreutils_test.sh` |
| Files, directories, and metadata | `userland/ls.swift`, `userland/touch.swift`, `userland/rm.swift` | `swiftos_open`, `swiftos_getdents`, `swiftos_stat`, mutation helpers | `./tests/swift_fileops_test.sh`, `./tests/swift_ls_test.sh`, `./tests/swift_rm_r_test.sh` |
| Raw C syscall and fd behavior | `userland/hello.c`, `userland/fdopsdemo.c` | `userland/lib/syscall.h`, `userland/lib/fs.h`, `pipe`, `poll`, `dup2` | `./tests/boot_test.sh` |
| Process launch and explicit handles | `userland/argvdemo.c`, `userland/spawndemo.c` | `spawn`, `spawn_handles`, `swiftos_spawn_handle`, handle rights | `./tests/boot_test.sh`, `./tests/spawn_self_exec_test.sh` |
| Security context and confinement | `userland/securitydemo.c`, `userland/identitydemo.c` | `security_info`, `login`, `confine`, capability bits | `./tests/boot_test.sh`, `./tests/cap_enforce_test.sh`, `./tests/console_login_test.sh` |
| IPC endpoint and handle transfer | `userland/c4b_sockxfer.c` | `endpoint_create`, `ipc_send`, `ipc_recv`, transfer rights | `./tests/ipc_socket_transfer_test.sh` |
| Synchronous request/reply IPC | `userland/ipc_call_test.c` | `ipc_call`, `ipc_reply_recv`, reply-port correlation | `make ipc-call-test` |
| Endpoint badges (client tagging) | `userland/qw4_badge.c` | `ipc_badge`, `ipc_recv_badged`, send-capability badge | `make qw4-badge-test` |
| Opaque device discovery and grants | `userland/drvsvcdemo.c`, `userland/drvinputd.c` | `device_discover`, `device_claim`, `device_info`, endpoint handle transfer | `make c5-device-authority-test` |
| Cells: isolate + supervise a service | `userland/cell-supervisor.swift`, `userland/cell-kv-supervisor.swift` | `cell_create` (root + page/handle caps), `cell_spawn`, `cell_stat`, `cell_pids`, `cell_destroy` | `make c6-cell-service-test`, `make c7-cell-supervisor-test`, `make c7-cell-realservice-test` |
| UDP or TCP service | `userland/udpecho.swift`, `userland/tcpecho.swift`, `userland/httpd.swift` | socket helpers, `swiftos_bind`, `swiftos_accept`, `swiftos_poll` | `./tests/udp_echo_test.sh`, `./tests/tcp_echo_test.sh`, `./tests/httpd_test.sh` |
| Network status preflight | `userland/netinfo.swift` | `netinfo`, `swiftos_netinfo_refresh`, `swiftos_net_*` | `make netinfo-test` |
| DNS, TCP, or TLS client | `userland/nslookup.swift`, `userland/tcpget.swift`, `userland/tlsget.swift` | `swiftos_resolve`, `swiftos_connect`, `swiftos_read`, `swiftos_write` | `./tests/dns_test.sh`, `./tests/tcp_connect_test.sh`, `./tests/tls_test.sh` |
| Anonymous and file-backed memory maps | `userland/mmapdemo.swift`, `userland/llm.swift`, `userland/llmd.swift` | `swiftos_mmap`, `swiftos_mmap_file`, `swiftos_mprotect`, W^X rules | `./tests/mmap_test.sh`, `./tests/llm_run_test.sh`, `./tests/llm_serve_test.sh` |
| C mmap and executable-memory permissions | `userland/mprotectprobe.c` | `mmap`, `mprotect`, `munmap`, W^X rules through newlib compat | `./tests/mprotect_test.sh` |
| C large mmap compatibility | `userland/largemmapprobe.c` | multi-MiB `mmap`, partial `mprotect`, bottom-region `munmap` reuse through newlib compat | `make largemmap-test` |
| C lazy mmap reservation compatibility | `userland/mmapreserveprobe.c` | `mmap(PROT_NONE)`, `MAP_NORESERVE`, `mprotect` commit/decommit, reserved-region JIT path | `make mmapreserve-test` |
| C fixed mmap compatibility | `userland/mapfixedprobe.c` | `MAP_FIXED`, `MAP_FIXED_NOREPLACE`, guard-page recommit, fixed-region JIT path | `make mapfixed-test` |
| Threads, futexes, and atomics | `userland/threadsdemo.swift` | `swiftos_thread_create`, `swiftos_futex`, `swiftos_atomic_*` | `./tests/threads_test.sh` |
| C pthread compatibility | `userland/pthreadprobe.c` | `pthread_create`, `pthread_join`, mutexes, condition variables, once, thread-specific data | `./tests/pthread_test.sh` |
| C thread-sync compatibility | `userland/threadsyncprobe.c` | `sem_init`, `sem_wait`, `sem_post`, `sem_timedwait`, `pthread_rwlock_*` | `./tests/threadsync_test.sh` |
| C select/pselect compatibility | `userland/selectprobe.c` | `select`, `pselect`, `fd_set` readiness over `poll` | `./tests/select_test.sh` |
| C eventfd compatibility | `userland/eventfdprobe.c` | `eventfd`, `eventfd_read`, `eventfd_write`, `poll`/`select` readiness | `./tests/eventfd_test.sh` |
| C libuv async wake compatibility | `userland/uvwakeprobe.c` | worker-thread `eventfd_write` waking a main-thread `poll` waiter | `./tests/uvwake_test.sh` |
| C libuv semaphore compatibility | `userland/uvsemprobe.c` | `sem_init`, `sem_wait`, `sem_trywait`, `sem_timedwait`, and `sem_post` behavior used by libuv semaphores | `./tests/uvsem_test.sh` |
| C libuv rwlock compatibility | `userland/uvrwlockprobe.c` | `pthread_rwlock_*` reader/writer semantics used by libuv rwlock wrappers | `./tests/uvrwlock_test.sh` |
| C libuv mutex-type compatibility | `userland/uvmutexprobe.c` | `PTHREAD_MUTEX_ERRORCHECK` and `PTHREAD_MUTEX_RECURSIVE` semantics used by libuv mutex init paths | `./tests/uvmutex_test.sh` |
| C libuv thread-name compatibility | `userland/uvthreadnameprobe.c` | `pthread_setname_np` and `pthread_getname_np` semantics used by libuv thread naming helpers | `./tests/uvthreadname_test.sh` |
| C libuv thread-stack compatibility | `userland/uvthreadstackprobe.c` | `getrlimit(RLIMIT_STACK)`, `getpagesize`, and `pthread_attr_setstacksize` behavior used by `uv_thread_create_ex` | `./tests/uvthreadstack_test.sh` |
| C libuv key/once compatibility | `userland/uvkeyonceprobe.c` | `pthread_once`, thread-local keys, `pthread_self`/`pthread_equal`, join, and detach behavior used by libuv's Unix thread layer | `./tests/uvkeyonce_test.sh` |
| C libuv environment compatibility | `userland/uvenvprobe.c`, `userland/envchild.c` | `getenv`/`setenv`/`unsetenv`, `execve` envp propagation, and libuv-style `environ` override before `execvp` | `./tests/uvenv_test.sh` |
| C libuv barrier compatibility | `userland/uvbarrierprobe.c` | reusable `pthread_barrier_*` phases for libuv's native barrier path | `./tests/uvbarrier_test.sh` |
| C libuv timed condition compatibility | `userland/uvcondprobe.c` | `pthread_cond_timedwait` with `CLOCK_MONOTONIC` timeout and signal wake paths | `./tests/uvcond_test.sh` |
| C libuv socketpair compatibility | `userland/uvsocketpairprobe.c` | `AF_UNIX` full-duplex `socketpair` with flags and poll readiness | `./tests/uvsocketpair_test.sh` |
| C libuv signal watcher compatibility | `userland/uvsignalprobe.c` | `pthread_sigmask` facade plus handler-to-pipe wake path | `./tests/uvsignal_test.sh` |
| C libuv atfork compatibility | `userland/uvatforkprobe.c` | `pthread_atfork` prepare/parent/child handler ordering around `fork` | `./tests/uvatfork_test.sh` |
| C libuv process spawn compatibility | `userland/uvspawnprobe.c` | `fork`/`execvp` close-on-exec error-pipe handshake, `dup2` stdio mapping, and `waitpid` status used by libuv's Unix `uv_spawn` path | `./tests/uvspawn_test.sh` |
| C signal lifecycle compatibility | `userland/signalprobe.c` | `sigaction`, `signal`, `raise`, current-process handler frames via `sigreturn`, `kill(pid, 0)`, `kill(pid, SIGTERM)`, `waitpid` signaled status | `./tests/signal_test.sh` |
| System and process statistics | `userland/top.swift`, `userland/ps.swift` | `sysinfo`, `procstat`, `swiftos_sys_*`, `swiftos_top_*` | `./tests/top_test.sh`, `./tests/boot_test.sh` |
| C realtime and monotonic clocks | `userland/clockprobe.c` | `clock_gettime`, `clock_getres`, `nanosleep`, `SYS_TIME`, `SYS_SYSINFO` | `./tests/clock_test.sh` |
| Package install and package store | `userland/pkg.swift`, `userland/pkghello.swift` | `pkg_install`, `pkg_info`, `pkg_remove`, `/bin/pkg` repository workflow | `make package-local-install-test`, `make package-remove-test`, `make package-repo-install-test`, `make package-ports-seed-repo-install-test`, `make package-static-host-repo-install-test`, `make package-static-host-dns-repo-install-test` |
| A/B update store operations | `userland/swos-confirm.swift`, `userland/swos-activate.swift`, `userland/swos-update.swift` | `update_confirm`, `update_activate`, `update_stage`, `swiftos_update_*` | `./tests/ab_confirm_test.sh`, `./tests/ab_activate_test.sh`, `./tests/ab_stage_test.sh` |
| Kernel slot staging, activation, and health confirmation | `userland/swos-kstage.swift`, `userland/swos-kactivate.swift`, `userland/swos-kconfirm.swift` | `kernel_stage`, `kernel_activate`, `kernel_confirm`, `swiftos_kernel_*` | `./tests/uefi_kstage_test.sh`, `./tests/uefi_kactivate_test.sh`, `./tests/uefi_kconfirm_test.sh` |

When copying an example, keep the same API layer unless you are deliberately
testing a lower layer. Mixing raw syscalls, native Swift bridge helpers, and
newlib wrappers in one small program usually makes error handling harder to
reason about.

## Building Against The API

Use the Makefile as the source of truth for toolchain flags. The Embedded Swift
flags, target triple, linker script, and support objects are toolchain-version
specific and should not be copied from memory.

Native Swift programs use this shape:

1. Compile the Swift source with `$(USER_SWIFT_FLAGS)` and
   `-import-objc-header userland/lib/swift_user.h`.
2. Link with `$(BUILD)/user_crt0.o`, `$(BUILD)/user_swift_user.o`, the program
   object, and `userland/user.ld`.
3. Add the resulting ELF to the base image or package it into a `.swpkg`.

C/newlib ports use this shape:

1. Compile with `$(USER_CFLAGS)` and the project compatibility include paths.
2. Link with `crt0_newlib.o`, `newlib_syscalls.o`, compatibility objects,
   newlib, libm, and libgcc.
3. Keep the binary static; SwiftOS does not have a dynamic loader.

For copy-paste build recipes, see
[APPLICATION_COOKBOOK.md](APPLICATION_COOKBOOK.md). For package payloads, see
[PACKAGE_GUIDE.md](PACKAGE_GUIDE.md).

## ABI Summary

SwiftOS exposes its own POSIX-like syscall ABI. It is not the Linux syscall ABI.

| Property | Value |
| --- | --- |
| Architecture | AArch64 |
| User mode | EL0 |
| Kernel mode | EL1 |
| Trap instruction | `svc #0` |
| Syscall number | `x8` |
| Arguments | `x0...x5` are reserved; current public wrappers use up to `x3` |
| Return value | `x0` |
| Linking | Static only |
| Dynamic loader | None |
| Main C ABI | `int main(int argc, char **argv, char **envp)` |

Most syscalls return a nonnegative success value or a negative errno-like value.
Some value-returning syscalls use a different convention; those are called out in
the syscall table.

## Raw Syscall Helpers

`userland/lib/syscall.h` provides inline helpers:

```c
static inline long __syscall3(long n, long a0, long a1, long a2);
static inline long __syscall4(long n, long a0, long a1, long a2, long a3);
```

Example:

```c
#include "lib/syscall.h"

int main(void) {
    const char msg[] = "hello\n";
    long n = write(1, msg, sizeof(msg) - 1);
    return n < 0 ? 1 : 0;
}
```

Raw helpers generally return negative errors directly. Native `swiftos_*`
helpers return negative errors for most integer-returning calls, but some
address-returning helpers use a sentinel such as 0. newlib and compatibility
wrappers convert many failures to `-1` plus `errno`. Do not mix those error
conventions without checking the wrapper you are calling.

### Error Handling By Layer

Use the wrapper's convention rather than guessing from the syscall table:

| Call style | Success | Failure |
| --- | --- | --- |
| Raw integer syscall wrapper | Nonnegative syscall-specific value | Negative errno-like value |
| Raw value-returning syscall (`time`, `resolve`, `sbrk`, `mmap`, `mmap_file`) | Returned directly in `x0` | Wrapper-specific sentinel or encoded negative value |
| Native Swift bridge integer helper | Nonnegative result or 0 | Negative errno-like value |
| Native Swift bridge address helper | Nonzero virtual address | 0 |
| newlib compatibility call | POSIX-shaped result | Usually `-1` plus `errno` |

When writing examples or tests, print the raw negative value near the failing
operation. It makes QEMU serial logs much easier to diagnose and matches the
style used by the shipped diagnostic programs.

## Syscall Table

The syscall numbers below must match `userland/lib/syscall.h` and
`kernel/syscall/syscall.swift`.

| No. | Name | Arguments | Return |
| ---: | --- | --- | --- |
| 1 | `open` | `path`, `flags`, `mode` | fd or negative error |
| 2 | `read` | `fd`, `buf`, `count` | bytes read or negative error |
| 3 | `write` | `fd`, `buf`, `count` | bytes written or negative error |
| 4 | `close` | `fd` | 0 or negative error |
| 5 | `exit` | `status` | does not return for an active process |
| 6 | `lseek` | `fd`, `offset`, `whence` | new offset or negative error |
| 7 | `tcgetattr` | `fd`, `termios*` | 0 or negative error |
| 8 | `tcsetattr` | `fd`, `actions`, `termios*` | 0 or negative error |
| 9 | `sigaction` | `sig`, `handler`, `restorer` | 0 |
| 10 | `kill` | `pid`, `sig` | 0, negative error, or termination through signal delivery |
| 11 | `getpid` | none | process id |
| 12 | `spawn` | `path`, `argv` | child exit status or negative error |
| 13 | `waitpid` | `pid`, `status*`, `options` | pid or negative error |
| 14 | `stat` | `path`, `kstat*` | 0 or negative error |
| 15 | `fstat` | `fd`, `kstat*` | 0 or negative error |
| 16 | `getdents` | `fd`, `buf`, `count` | bytes copied or negative error |
| 17 | `chdir` | `path` | 0 or negative error |
| 18 | `getcwd` | `buf`, `size` | length or negative error |
| 19 | `sbrk` | `incr` | previous break, or `(void *)-1` through wrappers |
| 20 | `fork` | none | child pid in parent, 0 in child, or negative error |
| 21 | `execve` | `path`, `argv`, `envp` | no return on success; copies argv/envp to the new stack; negative error |
| 22 | `psinfo` | `buffer`, `capacity` | total process count or negative error |
| 23 | `dup` | `fd` | new fd or negative error |
| 24 | `dup2` | `oldfd`, `newfd` | new fd or negative error |
| 25 | `pipe` | `int fds[2]` | 0 or negative error |
| 26 | `poll` | `pollfd*`, `nfds`, `timeout_ms` | ready count, 0 timeout, or negative error |
| 27 | `unlink` | `path` | 0 or negative error |
| 28 | `rename` | `oldpath`, `newpath` | 0 or negative error |
| 29 | `mkdir` | `path`, `mode` | 0 or negative error |
| 30 | `rmdir` | `path` | 0 or negative error |
| 31 | `security_info` | `security_info*` | 0 or negative error |
| 32 | `login` | `principal`, `session`, `caps` | 0 or negative error |
| 33 | `ftruncate` | `fd`, `length` | 0 or negative error |
| 34 | `fcntl` | `fd`, `cmd`, `arg` | command result or negative error |
| 35 | `chmod` | `path`, `mode` | 0 or negative error |
| 36 | `chown` | `path`, `owner` | 0 or negative error |
| 37 | `time` | none | Unix seconds |
| 38 | `socket` | `domain`, `type`, `proto` | fd or negative error |
| 39 | `bind` | `fd`, `port` | 0 or negative error |
| 40 | `sendto` | `fd`, `msg*` | bytes sent or negative error |
| 41 | `recvfrom` | `fd`, `msg*` | bytes received or negative error |
| 42 | `listen` | `fd`, `backlog` | 0 or negative error |
| 43 | `accept` | `fd` | connection fd or negative error |
| 44 | `connect` | `fd`, `ip`, `port` | 0 or negative error |
| 45 | `resolve` | `name`, `server_ip`, `server_port` | host-order IPv4, or 0 on failure |
| 46 | `sysinfo` | `buffer`, `capacity` | 0 or negative error |
| 47 | `procstat` | `buffer`, `capacity` | process count or negative error |
| 48 | `thread_create` | `entry`, `arg`, `stack_top` | thread id or negative error |
| 49 | `futex` | `uaddr`, `op`, `val` | op-specific result or negative error |
| 50 | `confine` | `path` | 0 or negative error |
| 51 | `endpoint_create` | `int ends[2]` | 0 or negative error |
| 52 | `ipc_send` | `fd`, `msg*` | 0 or negative error |
| 53 | `ipc_recv` | `fd`, `msg*` | bytes received or negative error |
| 54 | `mmap` | `addr`, `length`, `prot` | base VA or negative error |
| 55 | `munmap` | `addr`, `length` | 0 or negative error |
| 56 | `mprotect` | `addr`, `length`, `prot` | 0 or negative error |
| 57 | `nanosleep` | `seconds`, `nanoseconds` | 0 or negative error |
| 58 | `spawn_handles` | `path`, `argv`, `HandleSpec*`, `count` | child exit status or negative error |
| 59 | `mmap_file` | `fd`, `length`, `prot` | base VA or negative error |
| 60 | `pkg_install` | `fd`, `name`, `version_revision` | 0 or negative error |
| 61 | `pkg_info` | `index`, `buf`, `cap` | bytes copied or negative error |
| 62 | `device_claim` | `name`, `device_info*` | device fd or negative error |
| 63 | `device_info` | `fd`, `device_info*` | 0 or negative error |
| 64 | `device_discover` | `index`, `device_info*` | 0 or negative error |
| 65 | `update_confirm` | none | 0 or negative error |
| 66 | `update_activate` | none | 0 or negative error |
| 67 | `update_stage` | none | 0 or negative error |
| 68 | `kernel_stage` | none | 0 or negative error |
| 69 | `kernel_activate` | none | 0 or negative error |
| 70 | `kernel_confirm` | none | 0 or negative error |
| 71 | `eventfd` | `initval`, `flags` | fd or negative error |
| 72 | `pkg_stream_begin` | `desc*` | 0 or negative error |
| 73 | `pkg_stream_write` | `buf`, `count` | 0 or negative error |
| 74 | `pkg_stream_commit` | none | 0 or negative error |
| 75 | `pkg_stream_abort` | none | 0 or negative error |
| 76 | `sigreturn` | none | restores a kernel-built signal frame |
| 77 | `log_read` | `buf`, `cap`, `max_count` | bytes written or negative error |
| 78 | `socketpair` | `fds*`, `flags` | 0 or negative error |
| 79 | `pkg_files` | `name`, `buf`, `cap` | bytes needed or negative error |
| 80 | `random` | `buf`, `cap` | bytes written or negative error |
| 81 | `pkg_remove` | `name` | 0 or negative error |
| 82 | `log_stats` | `buf`, `cap` | 0 or negative error |
| 83 | `netinfo` | `buffer`, `capacity` | 0 or negative error |
| 84 | `openpty` | `master*`, `slave*` | 0 or negative error |
| 85 | `pty_set_foreground` | `fd`, `pid` | 0 or negative error |
| 86 | `security_info_ex` | `security_info_ex*` | 0 or negative error |
| 87 | `fsync` | `fd` | 0 or negative error (flushes /data to media) |
| 88 | `sync` | none | 0 (flushes all writable filesystems) |
| 89 | `recv` | `fd`, `buf`, `len` | bytes peeked (TCP `MSG_PEEK`) or negative error |
| 90 | `reboot` | `cmd` | does not return on success; negative error (needs `capConsole`) |
| 91 | `ipc_call` | `fd`, `msg*` | reply bytes or negative error (send + block for reply) |
| 92 | `ipc_reply_recv` | `fd`, `msg*` | request bytes or negative error (reply then receive) |
| 93 | `ipc_badge` | `fd`, `badge` | 0 or negative error (stamp a server-chosen client tag on a send-end endpoint handle) |
| 94 | `update_stage_begin` | `version`, `total` | 0 or negative error (reserve the inactive A/B slot for streaming; needs `capConsole`) |
| 95 | `update_stage_write` | `buf`, `count` | bytes accepted or negative error (append base-image bytes to the inactive slot; needs `capConsole`) |
| 96 | `update_stage_commit` | none | 0 or negative error (validate + flush the staged slot present/untried; needs `capConsole`) |
| 97 | `update_stage_abort` | none | 0 or negative error (discard an in-progress stage; needs `capConsole`) |
| 98 | `spawn_handles_async` | `path`, `argv`, `specs`, `count` | child pid or negative error (non-blocking explicit-handle spawn) |
| 99 | `name_register` | `name`, `endpoint_fd` | 0 or negative error (publish a recv-end endpoint under a name; needs `capConsole`) |
| 100 | `name_lookup` | `name` | fresh send-end fd or negative error (capability grant-by-lookup) |
| 101 | `device_mmap` | `fd`, `len` | base user VA or negative error (map a claimed device's MMIO window; gated on the grant's `.map` right) |
| 102 | `shmring_create` | `pages` | channel id or negative error (full-duplex shared-memory SPSC ring; needs `capNet`) |
| 103 | `shmring_map` | `id` | base user VA or negative error (map a channel's pages read/write) |
| 104 | `shmring_close` | `id` | 0 or negative error (drop the creator's base reference to a channel) |
| 105 | `virt_to_phys` | `va`, `handle_fd` | physical address or negative error (resolve a VA to its PA for a userland driver's DMA/virtqueue setup; gated on owning a mappable device grant) |
| 106 | `tty_inject` | `byte` | 0 or negative error (feed one byte to the kernel tty input as if typed; the userland input driver's path to the line discipline; needs `capConsole`) |
| 107 | `cell_stat` | `cellId`, `buf`, `cap` | live process count or negative error (aggregate one cell's `{processes, residentPages, cpuTicks, handles}` accounting domain; needs `capProcessInspect`) |
| 108 | `cell_create` | `root_path`, `page_cap`, `handle_cap`, `out_cell_id` | `.cell` control-handle fd or negative error (mint a fresh CellId with an optional namespace root + resident-page/handle caps; `0` cap = unlimited; needs `capConsole`) |
| 109 | `cell_spawn` | `cell_fd`, `path`, `argv`, `specs`, `count` | child pid or negative error (launch a process into the cell named by the held control handle, with explicit handle inheritance) |
| 110 | `cell_pids` | `cell_fd`, `buf`, `cap` | live member count or negative error (enumerate a cell's processes by tag, for supervised teardown) |
| 111 | `cell_destroy` | `cell_fd` | 0, `-EBUSY` while members live, or negative error (free the CellId once the cell is empty) |
| 112 | `kernel_install_begin` | none | 0 or negative error (reserve the inactive ESP kernel slot for a streamed new-kernel install; needs `capConsole`) |
| 113 | `kernel_install_write` | `buf`, `count` | bytes accepted or negative error (append kernel-image bytes to the inactive ESP slot; needs `capConsole`) |
| 114 | `kernel_install_commit` | `entry` | 0 or negative error (verify hash + per-slot signature and write the signed manifest entry; needs `capConsole`) |
| 115 | `kernel_install_abort` | none | 0 or negative error (discard an in-progress kernel install; needs `capConsole`) |

Notes:

- `spawn` is synchronous in the current implementation: it resolves the image,
  runs a child, waits, and returns the child's exit status.
- `spawn` inherits only stdio by default. Use `spawn_handles` for explicit
  handle inheritance.
- `fork` remains for compatibility and inherits the full handle table.
- `time`, `resolve`, `sbrk`, raw `mmap`, and raw `mmap_file` are
  value-returning paths and need wrapper-specific error handling.
- `fcntl` command numbers match the active newlib `<fcntl.h>` used by the
  sysroot. The kernel handles the subset needed by shell redirection and status
  flags.
- `netinfo` is a read-only network status snapshot for deploy preflight tools.
  It is still gated by `capNet`.
- `openpty` allocates a pseudo-terminal pair and writes the master and slave fds
  to the caller-supplied pointers. `pty_set_foreground` names the foreground
  process (target of tty-generated signals such as Ctrl-C) for the PTY referenced
  by either end; a `pid` of 0 clears it.

## Filesystem API

### Open Flags

SwiftOS kernel open flags:

| Flag | Value | Meaning |
| --- | ---: | --- |
| `O_RDONLY` | `0` | Read-only |
| `O_WRONLY` | `1` | Write-only |
| `O_RDWR` | `2` | Read-write |
| `O_CREAT` | `0x40` | Create a tmpfs file if missing |
| `O_TRUNC` | `0x80` | Truncate writable tmpfs file |
| `O_APPEND` | `0x100` | Append writes |
| `O_CLOEXEC` | `0x200` | Close fd on exec |
| `O_NONBLOCK` | `0x4000` | Nonblocking status flag used through `fcntl` |

`userland/lib/newlib_syscalls.c` translates newlib's BSD-style open flag values
to these kernel values.

### `struct stat`

The kernel stat record is 32 bytes:

```c
struct stat {
    unsigned int st_mode;   // offset 0
    unsigned int st_uid;    // offset 4
    unsigned long st_size;  // offset 8
    unsigned int st_gid;    // offset 16
    unsigned int st_nlink;  // offset 20
    unsigned long st_mtime; // offset 24
};
```

Mode type bits:

| Name | Value |
| --- | ---: |
| `S_IFMT` | `0xF000` |
| `S_IFREG` | `0x8000` |
| `S_IFDIR` | `0x4000` |
| `S_IFCHR` | `0x2000` |
| `S_IFIFO` | `0x1000` |

### `struct dirent`

Directory entries are variable length:

```c
struct dirent {
    unsigned long d_ino;      // offset 0
    unsigned long d_off;      // offset 8
    unsigned short d_reclen;  // offset 16
    unsigned char d_type;     // offset 18
    char d_name[];            // offset 19, NUL-terminated
};
```

`d_type` values currently used:

| Value | Meaning |
| ---: | --- |
| 4 | Directory |
| 8 | Regular file |

### Filesystem Capabilities

`open` checks process capabilities:

- Reads require `capFsRead`.
- Writes and creates require `capTmpWrite`.
- The base image is read-only even for privileged users.
- Path mutation syscalls such as `unlink`, `rename`, `mkdir`, `rmdir`, `chmod`,
  and `chown` require tmpfs write authority and operate on writable nodes.

`confine(path)` narrows the current process to a filesystem subtree. It is
confine-only: a process cannot widen the root after confinement.

## Package Store API

The target-side package manager uses public package-store syscalls for mutable
store operations and active package inspection. These are low-level APIs for
trusted system tools. Most applications should invoke `/bin/pkg` instead of
calling them directly.

Related file formats:

- [SWPKG_FORMAT.md](SWPKG_FORMAT.md) describes the package archive.
- [PKGSTORE_FORMAT.md](PKGSTORE_FORMAT.md) describes the append-only store.
- [PKGREPO_FORMAT.md](PKGREPO_FORMAT.md) describes signed repository catalogs.
- [PACKAGE_GUIDE.md](PACKAGE_GUIDE.md) shows the user-facing package workflow.

### Raw C Wrappers

`userland/lib/syscall.h` declares:

```c
int pkg_install(int fd, const char *name, const char *version_revision);
int pkg_info(int index, char *buf, size_t cap);
int pkg_files(const char *name, char *buf, size_t cap);
int pkg_remove(const char *name);

struct swiftos_pkg_stream_begin_desc {
    char name[32];
    char version_revision[16];
    unsigned long payload_size;
    unsigned char payload_sha256[32];
};

int pkg_stream_begin(const struct swiftos_pkg_stream_begin_desc *desc);
int pkg_stream_write(const void *buf, size_t count);
int pkg_stream_commit(void);
int pkg_stream_abort(void);
```

`pkg_install` appends the package payload, writes a new activation record, moves
the active pointer, and mounts the active package view.

`pkg_remove` appends a new activation record without the named package and
makes that activation the next boot's active generation. Current VFS package
payloads are not live-unmounted, so applications should treat the deactivation
as effective after reboot.

`pkg_stream_begin` starts the repository install path after `/bin/pkg` has
already parsed and verified the `.swpkg` header, manifest hash, manifest
metadata, and catalog entry. The descriptor names the package, revision, payload
byte count, and expected payload SHA-256. `pkg_stream_write` appends payload
chunks directly to the package store, `pkg_stream_commit` validates the final
payload and activates the package, and `pkg_stream_abort` drops the in-progress
mutation. This avoids caching full repository `.swpkg` blobs in `/tmp`.

Contract:

- The caller must run as the root principal; non-root callers receive `-13`.
- A package-store virtio block device must be present; otherwise the syscall
  returns `-2`.
- Only one package-store mutation may run at a time; a concurrent install
  receives `-11`.
- `fd` must refer to a readable `.swpkg` file.
- `name` is 1 to 31 bytes; `version_revision` is 1 to 15 bytes.
- The package must be unsigned `SWPKG001` v1, with valid manifest and payload
  SHA-256 hashes in the header.
- The payload must be a packed `SWOSBASE` v2 image.
- Repository catalog signatures and package download hashes are verified by
  `/bin/pkg` before it calls `pkg_install` or the streaming API; they are not
  part of these syscalls.

Example:

```c
#include "lib/syscall.h"
#include "lib/fs.h"

int main(void) {
    int fd = open("/tmp/pkghello.swpkg", O_RDONLY);
    if (fd < 0) {
        return 1;
    }

    int rc = pkg_install(fd, "pkghello", "1.0.0_1");
    close(fd);
    return rc == 0 ? 0 : 1;
}
```

`pkg_info` enumerates active package payloads by index. It writes a NUL-terminated
`name-version_revision` string to `buf` and returns the number of payload bytes
that would be written, excluding the trailing NUL. A missing index returns `-2`.

`pkg_files` enumerates the file paths in an active package payload. `name` is a
package name, `buf` receives newline-separated absolute paths, and the return
value is the byte count needed for the complete list. A missing active package
returns `-2`. Passing `cap == 0` is allowed and reports the required size without
writing `buf`.

Example:

```c
char line[80];
for (int i = 0; i < 16; i++) {
    int n = pkg_info(i, line, sizeof(line));
    if (n < 0) {
        break;
    }
    write(1, line, (unsigned long)n);
    write(1, "\n", 1);
}
```

### Native Swift Bridge

`userland/lib/swift_user.h` exposes the same package-store operations for
Embedded Swift tools:

```c
int swiftos_pkg_install(int fd, const char *name, const char *version_revision);
int swiftos_pkg_info(int index, char *buf, unsigned long cap);
int swiftos_pkg_files(const char *name, char *buf, unsigned long cap);
int swiftos_pkg_remove(const char *name);
int swiftos_pkg_stream_begin(const char *name, const char *version_revision,
                             unsigned long payload_size,
                             const unsigned char *payload_sha256);
int swiftos_pkg_stream_write(const void *buf, unsigned long count);
int swiftos_pkg_stream_commit(void);
int swiftos_pkg_stream_abort(void);
```

Swift example:

```swift
var buf = Array<CChar>(repeating: 0, count: 80)
let rc = buf.withUnsafeMutableBufferPointer { bp in
    swiftos_pkg_info(0, bp.baseAddress!, UInt(bp.count))
}
if rc >= 0 {
    buf.withUnsafeBufferPointer { bp in
        swiftos_puts(bp.baseAddress!)
    }
    swiftos_puts("\n")
}
```

## Cells

A **Cell** is a userland-supervisor composition over a cheap per-process `CellId`
tag — an isolation + resource-accounting domain assembled from primitives that
already exist (a process tree, the handle table, a VFS namespace root, and
per-domain accounting), **not** a fat in-kernel object. See
[CAPABILITIES.md](CAPABILITIES.md) §5 for the design decision and the C6/C7 arc.

`userland/lib/swift_user.h` exposes the cell control surface for Embedded Swift
supervisors:

```c
// Aggregate one cell's live {processes, residentPages, cpuTicks, handles} domain.
int swiftos_cell_query(unsigned int cell, struct swiftos_cell_stat *out);
// Mint a fresh cell: an optional namespace root + an optional resident-page cap and
// handle cap (0 = unlimited for either). Returns a `.cell` control-handle fd. Needs
// CAP_CONSOLE. Authority over the cell is by holding this handle.
int  swiftos_cell_create(const char *root, unsigned long page_cap,
                         unsigned long handle_cap, unsigned int *out_cell_id);
// Launch a process into the cell named by `cell_fd`, with explicit handle inheritance
// (the same spec vector as swiftos_spawn_handles_async). Returns the child pid.
long swiftos_cell_spawn(int cell_fd, const char *path, void *argv,
                        const void *handles, unsigned long handle_count);
// Enumerate a cell's live members by tag (the supervisor's "walk the job tree").
int  swiftos_cell_pids(int cell_fd, void *buf, unsigned long cap);
// Free the cell's CellId; refused with EBUSY while any member is still live.
int  swiftos_cell_destroy(int cell_fd);
```

The caps are enforced kernel-side: the resident-page cap is checked both at
spawn-into-cell time (C6d) and at every per-process growth site (C7a — `sbrk`,
anon `mmap`/`mprotect` commit, shared-frame map), and the handle cap is enforced
at the user-facing handle constructors (C7b — refused with `EMFILE`). A supervisor
can drive deterministic, page-granular heap growth in a hosted workload with the
heap bridge `swiftos_sbrk` (the previous-break primitive alongside
`swiftos_heap_break`).

The persistent restart/FDIR pattern (C7c) and a real in-tree service hosted in a
cell (C7d, `/bin/kv` over pipes) are shown in `userland/cell-supervisor.swift` and
`userland/cell-kv-supervisor.swift`; assembly + one-service-per-cell is
`userland/cellsvcprobe.swift`. Acceptance: `make c6-cell-service-test`,
`make c7-cell-supervisor-test`, `make c7-cell-realservice-test`.

## Device Grants

C5b added an opaque device-handle scaffold for restartable driver services, and
C5c connects that scaffold to real virtio-input discovery when QEMU exposes a
`virtio-keyboard-device`. C5d keeps the virtio-mmio location visible as
non-authoritative metadata through the public device-info ABI. C5e is the
current focused gate: it claims `virtio-input.0`, checks the manifest metadata,
surfaced virtio-mmio base/length, and withheld authority mask, transfers the
handle to `/bin/drvinputd`, and reclaims it after service exit. Headless boots
without an input device keep the `pseudo-input.0` fallback so the supervisor
path remains testable.

```c
struct swiftos_device_info {
    unsigned int kind;
    unsigned int bus;
    unsigned long mmio_base;
    unsigned long mmio_len;
    unsigned int irq;
    unsigned int flags;
    unsigned int generation;
    unsigned int claimed;
    char name[24];
};

int device_claim(const char *name, struct swiftos_device_info *info);
int device_info(int fd, struct swiftos_device_info *info);
int device_discover(int index, struct swiftos_device_info *info);
```

Contract:

- `device_discover(index, &info)` enumerates the registry by stable manifest
  ordinal. It writes the same 64-byte record as `device_info`; `claimed` reports
  whether a live grant owns the device. An out-of-range ordinal returns `-2`.
- `device_claim("virtio-input.0", &info)` returns a discovered virtio-mmio input
  device fd when the platform exposes one. `kind` is
  `SWIFTOS_DEVICE_KIND_VIRTIO_INPUT`, `bus` is
  `SWIFTOS_DEVICE_BUS_VIRTIO_MMIO`, `mmio_base`/`mmio_len` identify the transport
  window, and `SWIFTOS_DEVICE_FLAG_DISCOVERED` (also exported as the C5d
  `SWIFTOS_DEVICE_FLAG_DISCOVERED_MMIO` alias) is set.
- `device_claim("pseudo-input.0", &info)` remains the headless fallback when no
  real input device is discovered.
- A second claim while a live handle owns the grant returns `-16`.
- Moving the handle through `ipc_send` invalidates the sender's source fd.
- Closing the final fd for the device releases the registry claim.
- `device_info` fills the fixed 64-byte metadata record. C5c/C5d expose discovery
  metadata only: device handles still have `getattr + transfer` rights and
  `SWIFTOS_DEVICE_FLAG_NO_MMIO_GRANT`, so there is no userland MMIO map, IRQ
  endpoint, or DMA window yet.
- C5e reserves `SWIFTOS_DEVICE_FLAG_MMIO_GRANT`,
  `SWIFTOS_DEVICE_FLAG_IRQ_GRANT`, and `SWIFTOS_DEVICE_FLAG_DMA_GRANT` for the
  future handoff milestones. Current grants must keep
  `SWIFTOS_DEVICE_FLAG_HARDWARE_AUTHORITY` clear.

Supervisor-side handoff pattern:

```c
struct swiftos_device_info info;
int found = 0;
for (int i = 0; i < 4; i += 1) {
    int r = device_discover(i, &info);
    if (r == -2) {
        break;
    }
    if (r < 0) {
        return r;
    }
    int real = info.kind == SWIFTOS_DEVICE_KIND_VIRTIO_INPUT &&
        info.bus == SWIFTOS_DEVICE_BUS_VIRTIO_MMIO &&
        info.mmio_base != 0 &&
        info.mmio_len != 0 &&
        (info.flags & SWIFTOS_DEVICE_FLAG_DISCOVERED) != 0;
    int pseudo = info.kind == SWIFTOS_DEVICE_KIND_PSEUDO_INPUT &&
        info.bus == SWIFTOS_DEVICE_BUS_PSEUDO &&
        info.mmio_base == 0 &&
        info.mmio_len == 0;
    if ((real || pseudo) &&
        (info.flags & SWIFTOS_DEVICE_FLAG_NO_MMIO_GRANT) != 0 &&
        info.claimed == 0) {
        found = 1;
        break;
    }
}
if (!found) {
    return -2;
}

int dev_fd = device_claim(info.name, &info);
if (dev_fd < 0) {
    return dev_fd;
}
if ((info.kind != SWIFTOS_DEVICE_KIND_VIRTIO_INPUT &&
     info.kind != SWIFTOS_DEVICE_KIND_PSEUDO_INPUT) ||
    (info.flags & SWIFTOS_DEVICE_FLAG_NO_MMIO_GRANT) == 0 ||
    info.claimed != 1) {
    close(dev_fd);
    return -22;
}

long sent = ipc_send(command_endpoint, "DEVH", 4, dev_fd, SWIFTOS_RIGHTS_ALL_INHERIT);
if (sent < 0) {
    close(dev_fd);
    return (int)sent;
}

// The transfer moved the handle; the sender no longer owns dev_fd.
if (device_info(dev_fd, &info) != -9) {
    return -22;
}
```

Service-side receive pattern:

```c
char cmd[8];
int received_fd = -1;
long n = ipc_recv(command_endpoint, cmd, sizeof(cmd), &received_fd);
if (n == 4 && received_fd >= 0) {
    struct swiftos_device_info info;
    if (device_info(received_fd, &info) == 0) {
        // Current grants are metadata-only authority, not MMIO/IRQ/DMA access.
        close(received_fd);
    }
}
```

The complete checked-in example is `userland/drvsvcdemo.c` supervising
`userland/drvinputd.c`; `make c5-device-authority-test` validates the discovery
metadata, withheld-authority envelope, handoff, busy-claim, and release markers
under `-smp 4`.
`make c5-device-discovery-test` and `make c5-device-handle-test` remain
compatible aliases for the same harness.

## Terminal API

The `termios` ABI is intentionally small:

```c
struct termios {
    unsigned int c_iflag;
    unsigned int c_oflag;
    unsigned int c_cflag;
    unsigned int c_lflag;
};
```

Only `c_lflag` is interpreted today.

| Flag | Value | Meaning |
| --- | ---: | --- |
| `ICANON` | `1 << 0` | Canonical line mode |
| `ECHO` | `1 << 1` | Echo input |
| `ISIG` | `1 << 2` | Signal-generating input such as Ctrl-C |
| `TCSANOW` | `0` | Apply immediately |

Example:

```c
struct termios t;
tcgetattr(0, &t);
t.c_lflag &= ~ECHO;
tcsetattr(0, TCSANOW, &t);
```

## Poll API

`pollfd` is 8 bytes:

```c
struct pollfd {
    int fd;        // offset 0
    short events;  // offset 4
    short revents; // offset 6
};
```

Events:

| Event | Value |
| --- | ---: |
| `POLLIN` | `0x001` |
| `POLLOUT` | `0x004` |
| `POLLERR` | `0x008` |
| `POLLHUP` | `0x010` |
| `POLLNVAL` | `0x020` |

Example:

```c
struct pollfd p = { .fd = fd, .events = POLLIN, .revents = 0 };
int ready = poll(&p, 1, 1000);
```

## Security API

### Capabilities

Process capability bits:

| Bit | Name | Value |
| ---: | --- | ---: |
| 0 | `capConsole` | `1 << 0` |
| 1 | `capSpawn` | `1 << 1` |
| 2 | `capFsRead` | `1 << 2` |
| 3 | `capTmpWrite` | `1 << 3` |
| 4 | `capProcessInspect` | `1 << 4` |
| 5 | `capNet` | `1 << 5` |
| 6 | `capLogExport` | `1 << 6` |

`security_info` writes:

```c
struct security_info {
    unsigned int principal;
    unsigned int session;
    unsigned long caps;
};
```

`login(principal, session, caps)` replaces the calling process's context only if
the caller holds `capConsole`. The normal path is `/bin/console-login`.

`security_info_ex` writes the *effective* and *real* identity (the swift-os
analogue of Unix euid/ruid):

```c
struct security_info_ex {
    unsigned int principal;       // effective: what the process can do now
    unsigned int session;
    unsigned long caps;
    unsigned int real_principal;  // real: who invoked the process
    unsigned int real_session;
    unsigned long real_caps;
};
```

The two are equal for an ordinary process; they diverge only after a
**setuid-on-exec**. A binary packed into the read-only signed base image with the
setuid mode bit (octal `4000`) elevates the process's *effective* identity to the
file owner (full root authority) on exec, while preserving the invoker as the
*real* identity. The setuid bit is honored **only** for read-only base-image
files — never for tmpfs — so the trust root is the signed image. `/bin/sudo` is
the one setuid-root binary: it reads the real identity via `security_info_ex`,
re-authenticates the invoker against `/etc/swos/passwd`, checks
`/etc/swos/sudoers`, then `login()`s to the target identity and `execve()`s the
command. See COMMAND_REFERENCE.md (`sudo`).

`capSpawn` is the process-launch authority bit in the identity model. Current
process-launch behavior is documented by the syscall table and the handle
inheritance rules below; do not treat `capSpawn` as Linux-style execute
permission.

`capLogExport` gates `log_read`, `log_stats`, and `/bin/logtail`. The default
seeded accounts do not include this bit.

### Seeded Principals

| Principal | Name | Caps |
| ---: | --- | --- |
| 1 | `root` | `0x3f` |
| 2 | `user` | `0x0e` |
| 3 | `guest` | `0x02` |

## Handle Rights

A handle is a per-process descriptor naming an object and carrying rights.
Current handle kinds are:

| Kind | Meaning |
| --- | --- |
| `tty` | Console stream |
| `file` | File or directory |
| `pipe` | Pipe endpoint |
| `socket` | Network socket |
| `endpoint` | IPC endpoint |
| `device` | Opaque device-ownership grant |

Rights constants from `userland/lib/syscall.h`:

| Right | Value |
| --- | ---: |
| `SWIFTOS_RIGHT_READ` | `1u << 0` |
| `SWIFTOS_RIGHT_WRITE` | `1u << 1` |
| `SWIFTOS_RIGHT_EXECUTE` | `1u << 2` |
| `SWIFTOS_RIGHT_MAP` | `1u << 3` |
| `SWIFTOS_RIGHT_DUPLICATE` | `1u << 4` |
| `SWIFTOS_RIGHT_TRANSFER` | `1u << 5` |
| `SWIFTOS_RIGHT_GETATTR` | `1u << 6` |
| `SWIFTOS_RIGHT_SETATTR` | `1u << 7` |
| `SWIFTOS_RIGHT_ALL` | All currently defined rights |

Rights are attenuated on explicit transfer. A child cannot receive rights that
the parent handle does not hold.

## Process Creation

### `spawn`

```c
char *const argv[] = { "echo", "hello", 0 };
long status = spawn("/bin/echo", argv);
```

The current `spawn` wrapper is synchronous and returns the child exit status.
It inherits stdio only.

### `spawn_handles`

`spawn_handles` starts the child with an empty handle table and installs exactly
the provided handle specs.

```c
struct swiftos_spawn_handle {
    int source_fd;
    int target_fd;
    unsigned int rights;
    unsigned int flags;
};
```

Flags:

| Flag | Value |
| --- | ---: |
| `SWIFTOS_SPAWN_HANDLE_CLOEXEC` | `1u << 0` |

Example:

```c
int fd = open("/etc/motd", O_RDONLY);
struct swiftos_spawn_handle handles[] = {
    { 0, 0, SWIFTOS_RIGHT_ALL, 0 },
    { 1, 1, SWIFTOS_RIGHT_ALL, 0 },
    { 2, 2, SWIFTOS_RIGHT_ALL, 0 },
    { fd, 3, SWIFTOS_RIGHT_READ | SWIFTOS_RIGHT_GETATTR, 0 },
};
char *const argv[] = { "argvdemo", "inheritcheck", 0 };
long rc = spawn_handles("/bin/argvdemo", argv, handles, 4);
```

Native Embedded Swift code can call the same kernel operation through the raw
bridge when it needs explicit handle inheritance:

```c
long swiftos_spawn_handles_raw(const char *path, void *argv,
                               const void *handles,
                               unsigned long handle_count);
```

`argv` points at a null-terminated pointer vector. `handles` points at records
with the same 16-byte layout as `struct swiftos_spawn_handle`; this raw shape
keeps the bridge easy to construct from Swift temporary allocations.

## IPC Endpoints

Endpoint pairs are created with:

```c
int ends[2];
endpoint_create(ends); // ends[0] = send end, ends[1] = recv end
```

`ipc_send` and `ipc_recv` use small message structs hidden by the inline wrappers:

```c
long ipc_send(int fd, const void *buf, unsigned long len, int handle_fd,
              unsigned int requested_rights);
long ipc_recv(int fd, void *buf, unsigned long cap, int *out_handle_fd);
```

Behavior:

- A message carries bytes and optionally one moved handle.
- Sending a handle invalidates the sender's source fd on success.
- Endpoint send requires write rights.
- Endpoint receive requires read rights.
- Moving or importing a handle through an endpoint requires transfer rights where
  enforced by the endpoint policy.
- **Rights attenuation (QW5).** The handle installed in the receiver gets
  `effective = held ∩ requested_rights` — a fresh, attenuated handle. A grant can
  only narrow the sender's authority, never widen it. Pass
  `SWIFTOS_RIGHTS_ALL_INHERIT` to grant everything held (the identity intersection).
  `requested_rights` is ignored when `handle_fd < 0`.

Example:

```c
int ep[2];
endpoint_create(ep);

int fd = open("/etc/hostname", O_RDONLY);
ipc_send(ep[0], "H", 1, fd, SWIFTOS_RIGHTS_ALL_INHERIT); // grant all held rights

char byte;
int received = -1;
long n = ipc_recv(ep[1], &byte, 1, &received);
```

### Synchronous request/reply (`ipc_call` / `ipc_reply_recv`)

For request/reply RPC, `ipc_call` sends a request on a send end and blocks until
the server replies; `ipc_reply_recv` is the server hot loop — reply to the
previous request, then block for the next — in one syscall. The kernel mints a
transient reply port per call and correlates the reply to the exact blocked
caller, so the server needs no second endpoint or hand-built correlation:

```c
long ipc_call(int fd, const void *buf, unsigned long len, int handle_fd,
              void *reply_buf, unsigned long reply_cap, int *out_handle_fd);
long ipc_reply_recv(int fd, unsigned long reply_port,
                    const void *reply_buf, unsigned long reply_len, int reply_handle_fd,
                    void *recv_buf, unsigned long recv_cap, int *out_handle_fd,
                    unsigned long *out_reply_port);
```

Behavior:

- Same 256-byte byte-message model and one-moved-handle rule as `ipc_send`/`ipc_recv`.
- The server passes `reply_port = 0` on its first turn (nothing to reply to yet);
  each receive writes the new request's reply-port token to `*out_reply_port` for
  the server to reply to on the next turn.
- The reply-port token is a kernel-internal value validated on reply (it must name
  a port currently awaiting on the server's own endpoint); a stale/forged token
  returns `EINVAL`.
- A caller whose server exits without replying fails with `EPIPE` rather than
  hanging.

```c
// Server hot loop:
unsigned long rp = 0;            // 0 = no reply on the first turn
char out[256]; unsigned long out_len = 0; int out_h = -1;
for (;;) {
    char req[256]; int in_h = -1; unsigned long token = 0;
    long n = ipc_reply_recv(recv_fd, rp, out, out_len, out_h,
                            req, sizeof(req), &in_h, &token);
    if (n < 0) break;            // endpoint torn down: done
    rp = token;                  // reply to THIS request next turn
    /* ... build the reply into out/out_len/out_h ... */
}
```

### Endpoint badges (`ipc_badge` / `ipc_recv_badged`)

A badge is a server-chosen `UInt32` stamped onto a *send-capability* (the send-end
endpoint handle), so one receiving endpoint shared among many clients can tell
which client a message came from with no side-channel identity lookup — the
structural confused-deputy defense (`docs/CAPABILITIES.md` §4.2). The badge rides
with the capability (through a handle transfer or a direct `ipc_send`), not with
the endpoint; `0` is the unbadged default.

```c
int  ipc_badge(int fd, unsigned int badge);   // stamp a send-end handle; 0 clears
long ipc_recv_badged(int fd, void *buf, unsigned long cap,
                     int *out_handle_fd, unsigned int *out_badge); // *out_badge = sender's badge
```

Behavior:

- `ipc_badge` accepts only a send-end endpoint fd the caller holds; a non-endpoint
  or recv-end fd returns `EINVAL`.
- `ipc_recv_badged` reports the sending capability's badge in `*out_badge` (`0` =
  unbadged); pass `out_badge = NULL` to skip reporting. Plain `ipc_recv` is exactly
  `ipc_recv_badged(..., NULL)` — it carries a zero out-badge VA, so the recv msg
  struct is a fixed 32 bytes for every caller.

### Shared-memory ring (`shmring_create` / `shmring_map` / `shmring_close`)

LA3 adds a single-producer/single-consumer shared-memory data path for IPC that
moves payloads with no syscall per record — the prerequisite for relocating the
network stack to a userland service, and reusable by the Node.js / AI data
planes. A channel owns N physically-contiguous pages laid out as a full-duplex
pair of rings (ring0 in the first half, ring1 in the second); two processes map
the same pages and exchange length-prefixed records by reserving/committing and
peeking/releasing against the shared cursors. Ordering is enforced by the cursor
publish/consume barriers (the producer publishes `tail` with release ordering,
the consumer reads it with acquire ordering); there are no locks on the data
path. The sans-IO ring core is `kernel/ipc/shmring.swift` — the same file the
kernel, the host unit test, and the userland side compile.

```c
long shmring_create(unsigned long pages); // -> channel id (needs capNet)
long shmring_map(int id);                 // -> base user VA (or negative errno)
int  shmring_close(int id);               // drop the creator's base reference
```

The native-Swift bridges are `swiftos_shmring_create`, `swiftos_shmring_map`,
and `swiftos_shmring_close`; the userland ring uses `swiftos_atomic_load` /
`swiftos_atomic_store` (SEQ_CST) to publish and consume the cursors across
processes. Page lifetime rides the PMM reference count: `create` takes the base
reference, each `map` bumps it, process teardown drops it, and `close` (or owner
exit) drops the base reference — frames free on the last drop, so a peer that
still maps the channel keeps it alive until it too exits. Syscalls 102–104; see
`/bin/shmringprobe` and `tests/shmring_test.sh` (`make shmring-test`).

## Memory API

### `sbrk`

`sbrk(incr)` grows the process heap and returns the previous break. It backs the
native Swift userland allocator in `swift_user.c`.

### `mmap`

Protection bits:

| Name | Value |
| --- | ---: |
| `PROT_NONE` | `0x0` |
| `PROT_READ` | `0x1` |
| `PROT_WRITE` | `0x2` |
| `PROT_EXEC` | `0x4` |

Flags accepted by the POSIX-shaped wrapper:

| Name | Value |
| --- | ---: |
| `MAP_PRIVATE` | `0x02` |
| `MAP_FIXED` | `0x10` |
| `MAP_ANONYMOUS` | `0x20` |
| `MAP_ANON` | `MAP_ANONYMOUS` |
| `MAP_NORESERVE` | `0x4000` |
| `MAP_FIXED_NOREPLACE` | `0x100000` |
| `MAP_FAILED` | `(void *)-1` |

Current behavior:

- Only anonymous private mappings are supported.
- Without `MAP_FIXED`, `addr` is treated as a hint and ignored; `fd` and
  `offset` are ignored for anonymous mappings.
- `MAP_FIXED` may replace pages inside an existing anonymous reservation.
- `MAP_FIXED_NOREPLACE` returns `EEXIST` when the target overlaps an existing
  anonymous reservation or live mapping.
- `PROT_NONE` reserves virtual address space without resident frames.
- Non-`PROT_NONE` `mmap` allocates fresh zero-filled pages eagerly.
- `mprotect` inside an anonymous reservation commits missing pages for
  `PROT_READ`, `PROT_WRITE`, or `PROT_EXEC`, and `mprotect(PROT_NONE)`
  decommits live pages while preserving the reservation.
- `MAP_FIXED(PROT_NONE)` decommits live pages in the fixed range while
  preserving the surrounding reservation.
- `PROT_WRITE | PROT_EXEC` is rejected.
- The JIT pattern is RW mapping, write code, then `mprotect` to RX.

Example:

```c
void *p = mmap(0, 4096, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
if (p == MAP_FAILED) {
    return 1;
}
mprotect(p, 4096, PROT_READ | PROT_EXEC);
munmap(p, 4096);
```

### `mmap_file`

The native Swift bridge exposes file-backed read-only mappings for model files
and other large immutable inputs:

```c
unsigned long swiftos_mmap_file(int fd, unsigned long len, int prot);
```

Current behavior:

- The file must be a readable disk-backed file descriptor.
- `prot` must be exactly `PROT_READ`.
- The mapping is demand-paged from the backing file.
- The Swift bridge returns 0 on failure; the raw syscall returns a base VA or a
  negative errno encoded in the return register.

Example:

```c
int fd = open("/models/stories15M/1/model.bin", O_RDONLY);
unsigned long base = swiftos_mmap_file(fd, size, PROT_READ);
if (base == 0) {
    close(fd);
    return 1;
}
close(fd);
```

## Threads And Futexes

Thread creation:

```c
int swiftos_thread_create(unsigned long entry,
                          unsigned long arg,
                          unsigned long stack_top);
```

The new thread shares the process address space. The entry function is called
with `arg` and must terminate with `swiftos_thread_exit()`.

Futex operations:

| Operation | Value | Meaning |
| --- | ---: | --- |
| `SWIFTOS_FUTEX_WAIT` | 0 | Block while `*uaddr == val` |
| `SWIFTOS_FUTEX_WAKE` | 1 | Wake up to `val` waiters |

Use the atomic helpers in `swift_user.h`:

```c
unsigned int swiftos_atomic_cas(unsigned int *p,
                                unsigned int expected,
                                unsigned int desired);
unsigned int swiftos_atomic_swap(unsigned int *p, unsigned int desired);
unsigned int swiftos_atomic_load(unsigned int *p);
unsigned int swiftos_atomic_add(unsigned int *p, unsigned int delta);
```

## Networking API

Networking is gated by `capNet`.

Constants:

| Name | Value |
| --- | ---: |
| `AF_INET` | 2 |
| `AF_INET6` | 10 |
| `SOCK_STREAM` | 1 |
| `SOCK_DGRAM` | 2 |
| `IPPROTO_TCP` | 6 |
| `IPPROTO_UDP` | 17 |

### Native Swift Bridge

`swift_user.h` exposes convenience socket constructors:

```c
int swiftos_socket(void);              // AF_INET, SOCK_DGRAM
int swiftos_socket_ipv6(void);         // AF_INET6, SOCK_DGRAM
int swiftos_socket_stream(void);       // AF_INET, SOCK_STREAM
int swiftos_socket_stream_ipv6(void);  // AF_INET6, SOCK_STREAM
```

UDP:

```c
int swiftos_bind(int fd, unsigned short port);
long swiftos_sendto(int fd, const void *buf, unsigned long len,
                    unsigned int ip, unsigned short port);
long swiftos_recvfrom(int fd, void *buf, unsigned long cap,
                      unsigned int *ip, unsigned short *port);
```

TCP:

```c
int swiftos_listen(int fd, int backlog);
int swiftos_accept(int fd);
int swiftos_connect(int fd, unsigned int ip, unsigned short port);
long swiftos_poll(void *fds, unsigned long nfds, long timeout_ms);
```

DNS:

```c
unsigned int swiftos_resolve(const char *name,
                             unsigned int server_ip,
                             unsigned short server_port);
```

IPv4 addresses in the native bridge are host order. For example,
`0x0A000202` means `10.0.2.2`.

### UDP Message Layouts

The raw `sendto` and `recvfrom` syscalls take `fd` plus a pointer to a message
record.

IPv4 effective layout:

```c
struct swiftos_udp_msg {
    unsigned long buf;    // offset 0
    unsigned int len;     // offset 8
    unsigned int ip;      // offset 12, host-order IPv4
    unsigned short port;  // offset 16, host-order port
    unsigned short pad;   // offset 18
};
```

IPv6 packed layout:

```c
struct swiftos_udp_msg_v6 {
    unsigned long buf;       // offset 0
    unsigned int len;        // offset 8
    unsigned char ip6[16];   // offset 12, network-order IPv6
    unsigned short port;     // offset 28
    unsigned int scope;      // offset 30
} __attribute__((packed));
```

### POSIX-Shaped Sockets

`userland/compat/sys/socket.h`, `netinet/in.h`, and `netdb.h` provide a
source-level compatibility layer for ported C software. The layer translates
selected POSIX-shaped calls onto SwiftOS syscalls:

- `socket`
- `bind`
- `connect`
- `listen`
- `accept`
- `accept4` with `SOCK_NONBLOCK` and `SOCK_CLOEXEC`
- `send`, `recv`
- `sendto`, `recvfrom`
- `socketpair(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0, fds)`
- `sendmsg`, `recvmsg` for supported paths
- `setsockopt`, `getsockopt` for a minimal set
- `gethostbyname`, `getaddrinfo`, `getnameinfo`

`socket(..., SOCK_* | SOCK_NONBLOCK | SOCK_CLOEXEC, ...)` applies the requested
status and descriptor flags through `fcntl`. `pipe2(O_NONBLOCK | O_CLOEXEC)` is
available through the newlib compatibility headers, and pipe read/write honor
`O_NONBLOCK` with `EAGAIN`. `socketpair` is a SwiftOS local full-duplex fd pair
over VFS pipe queues, not a Linux ABI socket; it supports the libuv `SOCK_STREAM`
local-pair shape, bidirectional `read`/`write` and `send`/`recv`, `SO_TYPE`,
`POLLIN`/`POLLOUT`, and peer-close `POLLHUP`/`POLLERR`.

Unsupported options return conventional errors where possible.

### POSIX-Shaped Signal Lifecycle

SwiftOS signal support is deliberately narrow while the runtime port matures:

- `sigaction` records `SIG_DFL`, `SIG_IGN`, and handler pointers.
- `signal` and `raise` are provided by the newlib compatibility layer.
- `sigprocmask`/`pthread_sigmask` expose a no-op mask facade with conventional
  `oldset` reporting and argument validation for ported runtimes that bracket
  handler installation.
- Current-process custom handlers are delivered on syscall return through a
  kernel-built user signal frame and the compat `sigreturn` trampoline.
- `/bin/uvsignalprobe` covers the libuv-shaped watcher path where a handler
  writes a compact message into a nonblocking pipe that the event loop polls.
- `kill(pid, 0)` probes positive PIDs.
- `kill(pid, SIGTERM)` terminates a child under the default disposition.
- `waitpid` reports signaled children with the signal number in the low bits.

Process groups, enforced signal masks, blocked-syscall interruption, remote
async custom handler delivery, and complete libuv-style signal watcher
semantics are not implemented yet.

### POSIX-Shaped Event Counters

`userland/compat/sys/eventfd.h` exposes a small event-counter facade for
ported event loops:

- `eventfd(initval, EFD_NONBLOCK | EFD_CLOEXEC | EFD_SEMAPHORE)`
- `eventfd_read(fd, eventfd_t*)`
- `eventfd_write(fd, eventfd_t)`

The backing syscall is SwiftOS `eventfd` number 71, not a Linux ABI entry. Reads
and writes transfer one 64-bit little-endian counter value. Nonblocking empty
reads return `EAGAIN`; `EFD_SEMAPHORE` reads decrement by one and return 1.
`poll(POLLIN)` and `select` report readability when the counter is nonzero, and
`POLLIN` clears after the counter is drained.

## Process And System Stats Layouts

### `psinfo`

`psinfo(buffer, capacity)` writes fixed 32-byte records:

```c
struct swiftos_ps_entry {
    unsigned int pid;    // offset 0
    unsigned int ppid;   // offset 4
    unsigned int state;  // offset 8
    char name[20];       // offset 12
};
```

### `sysinfo`

`sysinfo(buffer, capacity)` writes a system stats blob for `/bin/top` and other
observability tools. A capacity of 0 requests the legacy 64-byte layout.
A capacity of at least 200 bytes requests the full S5 layout with per-CPU timer
and idle counters.

The first 64 bytes are stable:

```c
struct swiftos_sysinfo {
    unsigned long uptime_ticks;   // offset 0
    unsigned long idle_ticks;     // offset 8
    unsigned long mem_total;      // offset 16
    unsigned long mem_free;       // offset 24
    unsigned long kernel_image;   // offset 32
    unsigned long kernel_heap;    // offset 40
    unsigned int hz;              // offset 48
    unsigned int proc_total;      // offset 52
    unsigned int proc_running;    // offset 56
    unsigned int reserved;        // offset 60
};
```

The full 200-byte layout appends:

```c
#define SWIFTOS_CPU_MAX 8

struct swiftos_sysinfo_s5 {
    unsigned long uptime_ticks;                  // offset 0
    unsigned long idle_ticks;                    // offset 8
    unsigned long mem_total;                     // offset 16
    unsigned long mem_free;                      // offset 24
    unsigned long kernel_image;                  // offset 32
    unsigned long kernel_heap;                   // offset 40
    unsigned int hz;                             // offset 48
    unsigned int proc_total;                     // offset 52
    unsigned int proc_running;                   // offset 56
    unsigned int reserved;                       // offset 60
    unsigned int cpu_count;                      // offset 64
    unsigned int cpu_capacity;                   // offset 68
    unsigned long cpu_ticks[SWIFTOS_CPU_MAX];    // offset 72
    unsigned long cpu_idle_ticks[SWIFTOS_CPU_MAX]; // offset 136
};
```

`cpu_count` is clamped to the platform CPU count and `SWIFTOS_CPU_MAX`.
`cpu_capacity` publishes the ABI array capacity. Entries at or above
`cpu_count` are zero. Native Swift userland should prefer the bridge accessors
instead of depending on the raw offsets directly.

### `procstat`

`procstat(buffer, capacity)` writes 56-byte records:

```c
struct swiftos_procstat {
    unsigned int pid;          // offset 0
    unsigned int ppid;         // offset 4
    unsigned int state;        // offset 8
    unsigned int principal;    // offset 12
    unsigned long cpu_ticks;   // offset 16
    unsigned long start_tick;  // offset 24
    unsigned long res_bytes;   // offset 32
    char name[16];             // offset 40
};
```

The native Swift bridge wraps these layouts through `swiftos_ps_*`,
`swiftos_sys_*`, and `swiftos_top_*` accessors.

## Network Status Layout

`netinfo(buffer, capacity)` writes a fixed 56-byte network status record for
deploy preflight tools. The syscall is read-only but requires `capNet`.

```c
struct swiftos_netinfo {
    unsigned int flags;       // offset 0: ready, DHCPv4, static IPv6, IPv6 gateway
    unsigned int ipv4;        // offset 4, host-order IPv4
    unsigned int gateway4;    // offset 8, host-order IPv4
    unsigned int dns4;        // offset 12, host-order IPv4
    unsigned int mask4;       // offset 16, host-order IPv4 mask
    unsigned char ipv6[16];   // offset 20, network order
    unsigned char gateway6[16]; // offset 36, network order
    unsigned int prefix6;     // offset 52
};
```

Flags:

| Flag | Meaning |
| --- | --- |
| `SWIFTOS_NETINFO_READY` | virtio-net is attached and initialized |
| `SWIFTOS_NETINFO_DHCP4` | IPv4 came from DHCP |
| `SWIFTOS_NETINFO_STATIC6` | IPv6 came from `/etc/swos/net-ipv6` |
| `SWIFTOS_NETINFO_GW6` | `gateway6` is populated |

Native Swift userland should prefer `swiftos_netinfo_refresh()` and the
`swiftos_net_*` accessors instead of depending on raw offsets directly.

## Native Swift Bridge Index

Declared in `userland/lib/swift_user.h`.

### Output And Raw I/O

```c
void swiftos_putc(unsigned char c);
void swiftos_puts(const char *s);
long swiftos_write(int fd, const void *buf, unsigned long count);
long swiftos_read(int fd, void *buf, unsigned long count);
int swiftos_close(int fd);
int swiftos_pipe(int fds[2]);
```

### Filesystem

```c
int swiftos_open(const char *path, int flags);
int swiftos_fsync(int fd);
long swiftos_lseek(int fd, long offset, int whence);
int swiftos_ftruncate(int fd, long length);
long swiftos_getcwd(char *buf, unsigned long size);
long swiftos_getdents(int fd, void *buf, unsigned long count);
int swiftos_stat(const char *path, unsigned int *mode, unsigned int *uid,
                 unsigned int *gid, unsigned int *nlink,
                 unsigned long *size, unsigned long *mtime);
int swiftos_mkdir(const char *path);
int swiftos_rmdir(const char *path);
int swiftos_unlink(const char *path);
int swiftos_rename(const char *oldpath, const char *newpath);
int swiftos_chmod(const char *path, unsigned int mode);
int swiftos_chown(const char *path, unsigned int owner);
```

`swiftos_fsync` flushes an open file's data to stable media for datafs (`/data`)
durability, returning 0 on success. The mutation helpers (`swiftos_mkdir`
through `swiftos_chown`) apply to tmpfs only; the base image is read-only.

### Package Store

```c
int swiftos_pkg_install(int fd, const char *name, const char *version_revision);
int swiftos_pkg_info(int index, char *buf, unsigned long cap);
int swiftos_pkg_files(const char *name, char *buf, unsigned long cap);
int swiftos_pkg_remove(const char *name);
int swiftos_pkg_stream_begin(const char *name, const char *version_revision,
                             unsigned long payload_size,
                             const unsigned char *payload_sha256);
int swiftos_pkg_stream_write(const void *buf, unsigned long count);
int swiftos_pkg_stream_commit(void);
int swiftos_pkg_stream_abort(void);
```

### Update Store

```c
int swiftos_update_confirm(void);
int swiftos_update_activate(void);
int swiftos_update_stage(void);
int swiftos_kernel_stage(void);
int swiftos_kernel_activate(void);
int swiftos_kernel_confirm(void);
```

### Power Control

```c
int swiftos_reboot(void);
int swiftos_poweroff(void);
```

Both need `CAP_CONSOLE` (the boot/admin context). The kernel flushes `/data`
(`sync`) and issues PSCI `SYSTEM_RESET` (`swiftos_reboot`) or `SYSTEM_OFF`
(`swiftos_poweroff`); on success the machine resets or powers off and the call
never returns. They return a negative value on failure (`-1` EPERM for a
non-console principal, `-38` ENOSYS when no PSCI conduit is present). These back
`/bin/reboot` and `/bin/shutdown`.

### Logging

```c
long swiftos_log_read(void *buf, unsigned long cap, unsigned long max_count);
int  swiftos_log_stats(unsigned long *capacity, unsigned long *available,
                       unsigned long *total_written, unsigned long *overwritten);
```

The raw `log_stats` syscall writes a 32-byte record:
`capacity:u64`, `available:u64`, `total_written:u64`, `overwritten:u64`.

### Runtime Entropy

```c
long swiftos_random(void *buf, unsigned long count);
```

### Security And Process

```c
int swiftos_login(unsigned int principal, unsigned int session, unsigned long caps);
int swiftos_context(unsigned int *principal, unsigned int *session, unsigned long *caps);
int swiftos_context_ex(unsigned int *principal, unsigned int *session, unsigned long *caps,
                       unsigned int *real_principal, unsigned int *real_session,
                       unsigned long *real_caps);
int swiftos_exec_shell(const char *path);
int swiftos_execv(const char *path, char *const argv[]);
int swiftos_pty_spawn_shell(const char *path, int slave_fd);
int swiftos_waitpid(int pid, int *status);
long swiftos_getpid(void);
```

`swiftos_context_ex` returns both the effective and real identity (see the
`security_info_ex` syscall above); `swiftos_execv` replaces the current image
with `path` and the given argv. Together they back `/bin/sudo`.

`swiftos_pty_spawn_shell` forks and execs an interactive shell with `slave_fd`
wired to the child's stdin/stdout/stderr (all other fds closed). It returns the
child pid in the parent, or a negative value on fork error, and never returns in
the child. `swiftos_waitpid` waits for `pid` to exit and writes the wait-encoded
status to `*status` (the exit code is `(status >> 8) & 0xff`); it returns the
pid, or a negative value on error.

### System And Process Stats

```c
#define SWIFTOS_CPU_MAX 8

int swiftos_ps_refresh(void);
unsigned int swiftos_ps_pid(int index);
unsigned int swiftos_ps_ppid(int index);
unsigned int swiftos_ps_state(int index);
const char *swiftos_ps_name(int index);

int swiftos_sysinfo_refresh(void);
unsigned long swiftos_sys_uptime_ticks(void);
unsigned long swiftos_sys_idle_ticks(void);
unsigned long swiftos_sys_mem_total(void);
unsigned long swiftos_sys_mem_free(void);
unsigned long swiftos_sys_kernel_image(void);
unsigned long swiftos_sys_kernel_heap(void);
unsigned int swiftos_sys_hz(void);
unsigned int swiftos_sys_proc_total(void);
unsigned int swiftos_sys_proc_running(void);
unsigned int swiftos_sys_cpu_count(void);
unsigned int swiftos_sys_cpu_capacity(void);
unsigned long swiftos_sys_cpu_ticks(unsigned int cpu);
unsigned long swiftos_sys_cpu_idle_ticks(unsigned int cpu);

int swiftos_top_refresh(void);
unsigned int swiftos_top_pid(int i);
unsigned int swiftos_top_ppid(int i);
unsigned int swiftos_top_state(int i);
unsigned int swiftos_top_principal(int i);
unsigned long swiftos_top_cpu_ticks(int i);
unsigned long swiftos_top_start_tick(int i);
unsigned long swiftos_top_res_bytes(int i);
const char *swiftos_top_name(int i);
```

`swiftos_ps_refresh()` and `swiftos_top_refresh()` size their cached process
snapshots dynamically from the kernel-reported live count; callers should iterate
from `0` to the returned count and use the accessors above.

### Time

```c
unsigned long swiftos_time(void);
void swiftos_fmt_time(unsigned long t, char *out);
void swiftos_nanosleep(unsigned long sec, unsigned long nsec);
```

### Terminal

```c
int  swiftos_openpty(int *master, int *slave);
int  swiftos_pty_set_foreground(int fd, int pid);
void swiftos_set_echo(int on);
void swiftos_set_raw(int on);
```

`swiftos_openpty` allocates a pseudo-terminal pair, writing the master fd to
`*master` and the slave fd to `*slave`; it returns 0 on success, else a negative
value. `swiftos_pty_set_foreground` sets the foreground process (target of
tty-generated signals such as Ctrl-C) for the PTY referenced by `fd` (either
end); a `pid` of 0 clears it.

### Memory

```c
unsigned long swiftos_heap_break(void);
#define SWIFTOS_PROT_NONE  0x0
#define SWIFTOS_PROT_READ  0x1
#define SWIFTOS_PROT_WRITE 0x2
#define SWIFTOS_PROT_EXEC  0x4

unsigned long swiftos_mmap(unsigned long len, int prot);
unsigned long swiftos_mmap_file(int fd, unsigned long len, int prot);
int swiftos_munmap(unsigned long addr, unsigned long len);
int swiftos_mprotect(unsigned long addr, unsigned long len, int prot);
```

`swiftos_mmap` and `swiftos_mmap_file` return 0 on failure because valid
mappings are never placed at VA 0.

### Networking

```c
int swiftos_socket(void);
int swiftos_socket_ipv6(void);
int swiftos_socket_stream(void);
int swiftos_socket_stream_ipv6(void);
int swiftos_bind(int fd, unsigned short port);

long swiftos_sendto(int fd, const void *buf, unsigned long len,
                    unsigned int ip, unsigned short port);
long swiftos_recvfrom(int fd, void *buf, unsigned long cap,
                      unsigned int *ip, unsigned short *port);
long swiftos_sendto_ipv6(int fd, const void *buf, unsigned long len,
                         const unsigned char ip6[16], unsigned short port);
long swiftos_recvfrom_ipv6(int fd, void *buf, unsigned long cap,
                           unsigned char ip6[16], unsigned short *port);

int swiftos_listen(int fd, int backlog);
int swiftos_accept(int fd);
int swiftos_connect(int fd, unsigned int ip, unsigned short port);
long swiftos_poll(void *fds, unsigned long nfds, long timeout_ms);
unsigned int swiftos_resolve(const char *name, unsigned int server_ip,
                             unsigned short server_port);

int swiftos_netinfo_refresh(void);
unsigned int swiftos_net_flags(void);
unsigned int swiftos_net_ipv4(void);
unsigned int swiftos_net_gateway4(void);
unsigned int swiftos_net_dns4(void);
unsigned int swiftos_net_mask4(void);
unsigned int swiftos_net_ipv6_prefix_len(void);
unsigned char swiftos_net_ipv6_byte(unsigned int index);
unsigned char swiftos_net_gateway6_byte(unsigned int index);
```

IPv4 addresses are host order. IPv6 addresses are 16 bytes in network order.
The `swiftos_net_*` accessors read the cached `SYS_NETINFO` snapshot refreshed
by `swiftos_netinfo_refresh()`.

### Threads And Atomics

```c
#define SWIFTOS_FUTEX_WAIT 0
#define SWIFTOS_FUTEX_WAKE 1

int swiftos_thread_create(unsigned long entry,
                          unsigned long arg,
                          unsigned long stack_top);
int swiftos_futex(unsigned int *uaddr, int op, unsigned int val);
void swiftos_thread_exit(void) __attribute__((noreturn));

unsigned int swiftos_atomic_cas(unsigned int *p,
                                unsigned int expected,
                                unsigned int desired);
unsigned int swiftos_atomic_swap(unsigned int *p, unsigned int desired);
unsigned int swiftos_atomic_load(unsigned int *p);
unsigned int swiftos_atomic_add(unsigned int *p, unsigned int delta);
```

### IPC, Endpoints, And Fork

```c
int  swiftos_endpoint_create(int ends[2]);
long swiftos_ipc_send(int fd, const void *buf, unsigned long len, int handle_fd);
long swiftos_ipc_recv(int fd, void *buf, unsigned long cap, int *out_handle_fd);
int  swiftos_fork(void);
```

`swiftos_endpoint_create` creates an IPC endpoint pair (`ends[0]` is the send
end, `ends[1]` the recv end), returning 0 on success. `swiftos_ipc_send` sends
`len` bytes on a send end and, when `handle_fd >= 0`, transfers that handle to
the peer (granting every right the sender holds); `swiftos_ipc_recv` blocks for
one message, copying up to `cap` bytes into `buf` and storing any transferred
handle's new fd in `*out_handle_fd` (`-1` if none), returning the byte count or
a negative errno. `swiftos_fork` forks the calling process copy-on-write (0 in
the child, the child pid in the parent, negative on error). These forward to the
C-only inline syscalls in `userland/lib/syscall.h` — the documented low-level
bridge exception used by native Swift services (see
`userland/lib/userland_service.swift` and the `IPC Endpoints` section above).

### Device Grants And MMIO

```c
int  swiftos_device_claim(const char *name, struct swiftos_device_info *info);
int  swiftos_device_query(int fd, struct swiftos_device_info *info);
int  swiftos_device_discover(int index, struct swiftos_device_info *info);
long swiftos_device_mmap(int fd, unsigned long len);
long swiftos_virt_to_phys(unsigned long va, int handle_fd);

unsigned int   swiftos_mmio_read32(unsigned long addr);
void           swiftos_mmio_write32(unsigned long addr, unsigned int value);
unsigned short swiftos_mmio_read16(unsigned long addr);
void           swiftos_mmio_write16(unsigned long addr, unsigned short value);
void           swiftos_mmio_write64(unsigned long addr, unsigned long value);
void           swiftos_dmb(void);
```

`swiftos_device_claim` claims an opaque device grant by name (needs
`CAP_CONSOLE`) and returns a handle fd; `swiftos_device_query` inspects the grant
held on `fd` and `swiftos_device_discover` enumerates available grants by index,
both filling `struct swiftos_device_info` and returning 0 or a negative errno.
`swiftos_device_mmap` maps the claimed device's MMIO window into this process,
gated on the grant's `.map` right, returning the mapped base VA (`>= 0`) or a
small negative errno (`-13` EACCES for a metadata-only grant). `swiftos_virt_to_phys`
resolves a VA to its physical address for a userland driver programming
DMA/virtqueue registers, gated on `handle_fd` being a mappable grant the caller
owns. The `swiftos_mmio_*` accessors and `swiftos_dmb` (a full `dsb sy` data
memory barrier) are the volatile MMIO/DMA-ring primitives Embedded Swift cannot
express directly; the userland virtio-input/virtio-net drivers use them to touch
device registers and order ring writes against device notifications. See the
`Device Grants` section above for the grant model and `struct swiftos_device_info`
layout.

### Name Registry

```c
int swiftos_name_register(const char *name, int endpoint_fd);
int swiftos_name_lookup(const char *name);
```

`swiftos_name_register` publishes the recv end of an endpoint under a short name
(needs `CAP_CONSOLE`); `swiftos_name_lookup` resolves a name to a fresh send-end
fd (negative / `-ENOENT` on failure). Together they are the explicit
grant-by-lookup path a supervisor uses to wire a service's command endpoint to
its clients.

### Process Launch And TTY Injection

```c
long swiftos_run(const char *path, char *const *argv);
int  swiftos_tty_inject(unsigned char byte);
unsigned int swiftos_tcget_lflag(int fd);
int          swiftos_tcset_lflag(int fd, unsigned int lflag);
```

`swiftos_run` synchronously runs `path` with a NULL-terminated `argv` (fork +
exec + wait, inheriting stdin/stdout/stderr) and returns the child's exit status
(negative on error); `/bin/crond` uses it to launch scheduled jobs. `swiftos_tty_inject`
injects one byte into the kernel tty input as if typed on the console (needs
`CAP_CONSOLE`; `-1` EPERM without it) and backs the userland virtio-input driver
feeding decoded keystrokes to the line discipline. `swiftos_tcget_lflag` and
`swiftos_tcset_lflag` get/set the per-fd `c_lflag` termios word for an explicit
fd — unlike `swiftos_set_echo`/`swiftos_set_raw`, which act on fd 0 — so a test
can prove `tcgetattr`/`tcsetattr` route to the terminal behind a given fd.

### Staged Image Updates

```c
int swiftos_update_stage_begin(unsigned long version, unsigned long total);
int swiftos_update_stage_write(const void *buf, unsigned long count);
int swiftos_update_stage_commit(void);
int swiftos_update_stage_abort(void);

int swiftos_kernel_install_begin(void);
int swiftos_kernel_install_write(const void *buf, unsigned long count);
int swiftos_kernel_install_commit(const void *entry);
int swiftos_kernel_install_abort(void);
```

The `swiftos_update_stage_*` family streams a signed base image into the inactive
A/B slot from a userland buffer: `begin` declares the monotonic OS `version`
(which must exceed the store's anti-rollback floor) and `total` image length,
`write` appends bytes, then `commit`/`abort` finalize or discard. The
`swiftos_kernel_install_*` family streams a new host-signed kernel into the
inactive ESP slot and commits its 104-byte signed manifest entry (the kernel
verifies the hash plus a per-slot Ed25519 signature). All need `CAP_CONSOLE` and
return 0 on success or a negative errno. These back `/bin/swos-stagebase` and
`/bin/swos-kinstall` and complement the slot-promotion helpers in **Update Store**
above.

## Compatibility Layer

The newlib and compatibility surface is intentionally source-level, not ABI
emulation. Important files:

| File | Purpose |
| --- | --- |
| `userland/lib/newlib_syscalls.c` | newlib bottom-end syscalls |
| `userland/compat/stubs.c` | POSIX-like functions and safe stubs |
| `userland/compat/sys/mman.h` | `mmap`, `munmap`, `mprotect`, and memory protection constants |
| `userland/compat/sys/socket.h` | socket source declarations |
| `userland/compat/netinet/in.h` | IPv4/IPv6 address structures |
| `userland/compat/netdb.h` | name-resolution declarations |
| `userland/compat/poll.h` | `pollfd` and event constants |
| `userland/compat/time.h` | realtime and monotonic clock declarations |
| `userland/compat/termios.h` | terminal compatibility declarations |

Expect some POSIX calls to be no-ops or `ENOSYS` stubs until a port needs real
behavior and tests are added.

`clock_gettime` supports `CLOCK_REALTIME`, `CLOCK_REALTIME_COARSE`,
`CLOCK_MONOTONIC`, `CLOCK_MONOTONIC_RAW`, `CLOCK_MONOTONIC_COARSE`, and
`CLOCK_BOOTTIME`. Realtime is backed by `SYS_TIME` and the QEMU PL031 RTC;
monotonic clocks are backed by `SYS_SYSINFO` uptime ticks and timer Hz. CPU-time
and alarm clocks are not implemented and fail with `EINVAL`.

## API Verification Map

When changing a public API, run the narrow test for that surface and at least
one booting acceptance path:

| API area | Primary files | Focused verification |
| --- | --- | --- |
| Syscall numbers and dispatch | `userland/lib/syscall.h`, `kernel/syscall/syscall.swift` | `make docs-test`, then `make test` for booting dispatch coverage |
| Handle rights and explicit inheritance | `kernel/vfs/handle.swift`, `userland/lib/syscall.h` | `tests/handle_test.swift`, `./tests/boot_test.sh` |
| Filesystem and native Swift file tools | `kernel/vfs/vfs.swift`, `userland/lib/fs.h`, `userland/lib/swift_user.h` | `./tests/swift_fileops_test.sh`, `./tests/swift_ls_test.sh`, `./tests/boot_test.sh` |
| Terminal and signals | `userland/lib/termios.h`, `kernel/tty/tty.swift`, `kernel/signal/signal.swift` | `./tests/boot_test.sh`, focused interactive smoke where needed |
| IPC endpoint transfer | `kernel/vfs/handle.swift`, `kernel/vfs/vfs.swift`, `userland/lib/syscall.h` | `./tests/ipc_socket_transfer_test.sh`, `./tests/boot_test.sh` |
| Device discovery and grants | `kernel/vfs/vfs.swift`, `userland/lib/syscall.h`, `userland/drvsvcdemo.c`, `userland/drvinputd.c` | `make c5-device-authority-test` |
| Threads and futexes | `kernel/sched/futex.swift`, `userland/lib/swift_user.h` | `./tests/threads_test.sh`, `./tests/boot_test.sh` |
| C compat pthreads | `userland/compat/pthread.h`, `userland/compat/stubs.c`, `userland/pthreadprobe.c` | `make pthread-test`, `./tests/boot_test.sh` |
| C compat semaphores and rwlocks | `userland/compat/pthread.h`, `userland/compat/semaphore.h`, `userland/compat/stubs.c`, `userland/threadsyncprobe.c` | `make threadsync-test`, `./tests/boot_test.sh` |
| C compat select/pselect | `userland/compat/stubs.c`, `userland/selectprobe.c` | `make select-test`, `./tests/boot_test.sh` |
| C compat eventfd | `userland/compat/sys/eventfd.h`, `userland/compat/stubs.c`, `userland/eventfdprobe.c` | `make eventfd-test`, `./tests/boot_test.sh` |
| C compat libuv async wake | `userland/compat/pthread.h`, `userland/compat/sys/eventfd.h`, `userland/compat/stubs.c`, `userland/uvwakeprobe.c` | `make uvwake-test`, `./tests/boot_test.sh` |
| C compat libuv semaphore | `userland/compat/pthread.h`, `userland/compat/semaphore.h`, `userland/compat/stubs.c`, `userland/uvsemprobe.c` | `make uvsem-test`, `./tests/boot_test.sh` |
| C compat libuv rwlock | `userland/compat/pthread.h`, `userland/compat/semaphore.h`, `userland/compat/stubs.c`, `userland/uvrwlockprobe.c` | `make uvrwlock-test`, `./tests/boot_test.sh` |
| C compat libuv mutex types | `userland/compat/pthread.h`, `userland/compat/stubs.c`, `userland/uvmutexprobe.c` | `make uvmutex-test`, `./tests/boot_test.sh` |
| C compat libuv thread names | `userland/compat/pthread.h`, `userland/compat/stubs.c`, `userland/uvthreadnameprobe.c` | `make uvthreadname-test`, `./tests/boot_test.sh` |
| C compat libuv thread stacks | `userland/compat/pthread.h`, `userland/compat/sys/resource.h`, `userland/compat/unistd.h`, `userland/compat/stubs.c`, `userland/uvthreadstackprobe.c` | `make uvthreadstack-test`, `./tests/boot_test.sh` |
| C compat libuv key/once/thread identity | `userland/compat/pthread.h`, `userland/compat/stubs.c`, `userland/uvkeyonceprobe.c` | `make uvkeyonce-test`, `./tests/boot_test.sh` |
| C compat libuv environment handoff | `kernel/user/ustack.swift`, `kernel/user/process.swift`, `kernel/syscall/syscall.swift`, `userland/lib/crt0_newlib.S`, `userland/compat/stubs.c`, `userland/uvenvprobe.c`, `userland/envchild.c` | `make uvenv-test`, `./tests/boot_test.sh` |
| C compat libuv barrier | `userland/compat/pthread.h`, `userland/compat/stubs.c`, `userland/uvbarrierprobe.c` | `make uvbarrier-test`, `./tests/boot_test.sh` |
| C compat libuv timed condition wait | `userland/compat/pthread.h`, `userland/compat/stubs.c`, `userland/uvcondprobe.c` | `make uvcond-test`, `./tests/boot_test.sh` |
| C compat libuv socketpair | `kernel/vfs/vfs.swift`, `kernel/syscall/syscall.swift`, `userland/compat/sys/socket.h`, `userland/compat/stubs.c`, `userland/uvsocketpairprobe.c` | `make uvsocketpair-test`, `./tests/boot_test.sh` |
| C compat libuv signal watcher | `userland/compat/pthread.h`, `userland/compat/signal.h`, `userland/compat/stubs.c`, `userland/uvsignalprobe.c` | `make uvsignal-test`, `./tests/boot_test.sh` |
| C compat libuv atfork | `userland/compat/pthread.h`, `userland/compat/stubs.c`, `userland/uvatforkprobe.c` | `make uvatfork-test`, `./tests/boot_test.sh` |
| C compat libuv process spawn | `userland/compat/pthread.h`, `userland/compat/signal.h`, `userland/compat/unistd.h`, `userland/compat/stubs.c`, `userland/uvspawnprobe.c` | `make uvspawn-test`, `./tests/boot_test.sh` |
| C compat signal lifecycle | `kernel/signal/signal.swift`, `kernel/user/process.swift`, `userland/compat/stubs.c`, `userland/signalprobe.c` | `make signal-test`, `./tests/boot_test.sh` |
| C compat clocks | `userland/compat/time.h`, `userland/compat/stubs.c`, `userland/clockprobe.c` | `make clock-test`, `./tests/boot_test.sh` |
| mmap and W^X | `kernel/mm/vm.swift`, `userland/lib/syscall.h`, `userland/lib/swift_user.h` | `./tests/mmap_test.sh`, `./tests/boot_test.sh` |
| C compat mmap and mprotect | `userland/compat/sys/mman.h`, `userland/compat/stubs.c`, `userland/mprotectprobe.c` | `make mprotect-test`, `./tests/boot_test.sh` |
| C compat large mmap | `userland/compat/sys/mman.h`, `userland/compat/stubs.c`, `userland/largemmapprobe.c` | `make largemmap-test`, `./tests/boot_test.sh` |
| C compat mmap reservation | `kernel/user/process.swift`, `userland/compat/sys/mman.h`, `userland/mmapreserveprobe.c` | `make mmapreserve-test`, `./tests/boot_test.sh` |
| C compat fixed mmap | `kernel/user/process.swift`, `userland/compat/sys/mman.h`, `userland/mapfixedprobe.c` | `make mapfixed-test`, `./tests/boot_test.sh` |
| Networking bridge | `kernel/net/*`, `userland/netinfo.swift`, `userland/lib/swift_user.h`, `userland/compat/sys/socket.h` | `make netinfo-test`, `./tests/udp_echo_test.sh`, `./tests/tcp_echo_test.sh`, `./tests/dns_test.sh`, `./tests/boot_test.sh` |
| Package syscalls | `kernel/pkg/store.swift`, `userland/pkg.swift`, `userland/lib/syscall.h` | `make package-local-install-test`, `make package-repo-install-test`, `make package-lua-repo-install-test`, `make ports-recipe-test`, `make ports-bzip2-repo-fixture`, `make ports-ca-certificates-repo-fixture`, `make package-ports-seed-repo-install-test`, `make package-static-host-repo-install-test`, `make package-static-host-dns-repo-install-test` |
| Log export | `kernel/log/log.swift`, `kernel/syscall/syscall.swift`, `userland/logtail.swift`, `userland/lib/swift_user.h` | `make log-export-test` |
| Runtime entropy | `kernel/drivers/virtio_rng.swift`, `kernel/syscall/syscall.swift`, `userland/lib/swift_user.h`, `userland/ssh.swift`, `userland/sshd.swift` | `make ssh-runtime-entropy-test`, `make sshd-runtime-entropy-test` |
| Native Swift bridge helpers | `userland/lib/swift_user.h`, `userland/lib/swift_user.c` | `./tests/swift_coreutils_test.sh`, `./tests/swift_headwc_test.sh`, `./tests/swift_date_test.sh` |

Documentation must move with the code. If a syscall number, structure layout,
constant, or bridge helper changes, update this reference, the relevant guide,
and the acceptance test in the same milestone.

## Error Codes

The kernel commonly returns negative errno-like values. Frequently observed
values include:

| Value | Conventional name |
| ---: | --- |
| `-1` | `EPERM` |
| `-2` | `ENOENT` |
| `-9` | `EBADF` |
| `-11` | `EAGAIN` |
| `-12` | `ENOMEM` |
| `-13` | `EACCES` |
| `-17` | `EEXIST` |
| `-20` | `ENOTDIR` |
| `-21` | `EISDIR` |
| `-22` | `EINVAL` |
| `-28` | `ENOSPC` |
| `-30` | `EROFS` |
| `-32` | `EPIPE` |
| `-38` | `ENOSYS` |
| `-39` | `ENOTEMPTY` |

Check the specific syscall path for exact behavior. The raw SwiftOS bridge and
the newlib compatibility layer do not always expose errors in the same shape.

## Complete Example: Explicit Handle Spawn

```c
#include "lib/syscall.h"
#include "lib/fs.h"

int main(void) {
    int motd = open("/etc/motd", O_RDONLY);
    if (motd < 0) {
        return 1;
    }

    struct swiftos_spawn_handle handles[] = {
        { 0, 0, SWIFTOS_RIGHT_ALL, 0 },
        { 1, 1, SWIFTOS_RIGHT_ALL, 0 },
        { 2, 2, SWIFTOS_RIGHT_ALL, 0 },
        { motd, 3, SWIFTOS_RIGHT_READ | SWIFTOS_RIGHT_GETATTR, 0 },
    };

    char *const argv[] = { "argvdemo", "inheritcheck", 0 };
    long status = spawn_handles("/bin/argvdemo", argv, handles, 4);
    close(motd);
    return status == 2 ? 0 : 1;
}
```

Verification:

```sh
./tests/boot_test.sh
./tests/spawn_self_exec_test.sh
```

## Complete Example: Native Swift Hello

```swift
@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc
    _ = argv
    _ = envp

    swiftos_puts("hello from native Swift\n")
    return 0
}
```

Verification:

```sh
./tests/swift_coreutils_test.sh
```

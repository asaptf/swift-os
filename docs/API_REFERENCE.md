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
| UDP or TCP service | `userland/udpecho.swift`, `userland/tcpecho.swift`, `userland/httpd.swift` | socket helpers, `swiftos_bind`, `swiftos_accept`, `swiftos_poll` | `./tests/udp_echo_test.sh`, `./tests/tcp_echo_test.sh`, `./tests/httpd_test.sh` |
| DNS, TCP, or TLS client | `userland/nslookup.swift`, `userland/tcpget.swift`, `userland/tlsget.swift` | `swiftos_resolve`, `swiftos_connect`, `swiftos_read`, `swiftos_write` | `./tests/dns_test.sh`, `./tests/tcp_connect_test.sh`, `./tests/tls_test.sh` |
| Anonymous and file-backed memory maps | `userland/mmapdemo.swift`, `userland/llm.swift`, `userland/llmd.swift` | `swiftos_mmap`, `swiftos_mmap_file`, `swiftos_mprotect`, W^X rules | `./tests/mmap_test.sh`, `./tests/llm_run_test.sh`, `./tests/llm_serve_test.sh` |
| Threads, futexes, and atomics | `userland/threadsdemo.swift` | `swiftos_thread_create`, `swiftos_futex`, `swiftos_atomic_*` | `./tests/threads_test.sh` |
| System and process statistics | `userland/top.swift`, `userland/ps.swift` | `sysinfo`, `procstat`, `swiftos_sys_*`, `swiftos_top_*` | `./tests/top_test.sh`, `./tests/boot_test.sh` |
| Package install and package store | `userland/pkg.swift`, `userland/pkghello.swift` | `pkg_install`, `pkg_info`, `/bin/pkg` repository workflow | `make package-local-install-test`, `make package-repo-install-test`, `make package-static-host-repo-install-test`, `make package-static-host-dns-repo-install-test` |

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
style used by the shipped demo programs.

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
| 9 | `sigaction` | `sig`, `handler` | 0 |
| 10 | `kill` | `pid`, `sig` | 0 or termination through signal delivery |
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
| 21 | `execve` | `path`, `argv`, `envp` | no return on success, negative error |
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

The target-side package manager uses two public syscalls for the mutable package
store. These are low-level APIs for trusted system tools. Most applications
should invoke `/bin/pkg` instead of calling them directly.

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
```

`pkg_install` appends the package payload, writes a new activation record, moves
the active pointer, and mounts the active package view.

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
  `/bin/pkg` before it calls `pkg_install`; they are not part of this syscall.

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

## Device Grants

C5b adds an opaque device-handle scaffold for restartable driver services. The
current registry has one pseudo device, `pseudo-input.0`, used by
`/bin/drvsvcdemo` and `/bin/drvinputd` to prove device ownership moves over IPC.
It is not a real MMIO, IRQ, or DMA grant yet.

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
```

Contract:

- `device_claim("pseudo-input.0", &info)` returns a device fd with metadata and
  transfer authority, or a negative error.
- A second claim while a live handle owns the grant returns `-16`.
- Moving the handle through `ipc_send` invalidates the sender's source fd.
- Closing the final fd for the device releases the registry claim.
- `device_info` fills the fixed 64-byte metadata record. `mmio_base`,
  `mmio_len`, and `irq` are zero in C5b because hardware access is deliberately
  not granted.

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

`capSpawn` is the process-launch authority bit in the identity model. Current
process-launch behavior is documented by the syscall table and the handle
inheritance rules below; do not treat `capSpawn` as Linux-style execute
permission.

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

## IPC Endpoints

Endpoint pairs are created with:

```c
int ends[2];
endpoint_create(ends); // ends[0] = send end, ends[1] = recv end
```

`ipc_send` and `ipc_recv` use small message structs hidden by the inline wrappers:

```c
long ipc_send(int fd, const void *buf, unsigned long len, int handle_fd);
long ipc_recv(int fd, void *buf, unsigned long cap, int *out_handle_fd);
```

Behavior:

- A message carries bytes and optionally one moved handle.
- Sending a handle invalidates the sender's source fd on success.
- Endpoint send requires write rights.
- Endpoint receive requires read rights.
- Moving or importing a handle through an endpoint requires transfer rights where
  enforced by the endpoint policy.

Example:

```c
int ep[2];
endpoint_create(ep);

int fd = open("/etc/hostname", O_RDONLY);
ipc_send(ep[0], "H", 1, fd);

char byte;
int received = -1;
long n = ipc_recv(ep[1], &byte, 1, &received);
```

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
| `MAP_ANONYMOUS` | `0x20` |
| `MAP_ANON` | `MAP_ANONYMOUS` |
| `MAP_FAILED` | `(void *)-1` |

Current behavior:

- Only anonymous private mappings are supported.
- `addr`, `fd`, and `offset` are ignored by the wrapper.
- The kernel allocates fresh zero-filled pages.
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
- `send`, `recv`
- `sendto`, `recvfrom`
- `sendmsg`, `recvmsg` for supported paths
- `setsockopt`, `getsockopt` for a minimal set
- `gethostbyname`, `getaddrinfo`, `getnameinfo`

Unsupported options return conventional errors where possible.

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

## Native Swift Bridge Index

Declared in `userland/lib/swift_user.h`.

### Output And Raw I/O

```c
void swiftos_putc(unsigned char c);
void swiftos_puts(const char *s);
long swiftos_write(int fd, const void *buf, unsigned long count);
long swiftos_read(int fd, void *buf, unsigned long count);
int swiftos_close(int fd);
```

### Filesystem

```c
int swiftos_open(const char *path, int flags);
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

### Package Store

```c
int swiftos_pkg_install(int fd, const char *name, const char *version_revision);
int swiftos_pkg_info(int index, char *buf, unsigned long cap);
```

### Security And Process

```c
int swiftos_login(unsigned int principal, unsigned int session, unsigned long caps);
int swiftos_context(unsigned int *principal, unsigned int *session, unsigned long *caps);
int swiftos_exec_shell(const char *path);
long swiftos_getpid(void);
```

### System And Process Stats

```c
#define SWIFTOS_TOP_MAX 16
#define SWIFTOS_CPU_MAX 8

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

### Time

```c
unsigned long swiftos_time(void);
void swiftos_fmt_time(unsigned long t, char *out);
void swiftos_nanosleep(unsigned long sec, unsigned long nsec);
```

### Terminal

```c
void swiftos_set_echo(int on);
void swiftos_set_raw(int on);
```

### Memory

```c
unsigned long swiftos_heap_break(void);
unsigned long swiftos_mmap(unsigned long len, int prot);
unsigned long swiftos_mmap_file(int fd, unsigned long len, int prot);
int swiftos_munmap(unsigned long addr, unsigned long len);
int swiftos_mprotect(unsigned long addr, unsigned long len, int prot);
```

`swiftos_mmap` and `swiftos_mmap_file` return 0 on failure because valid
mappings are never placed at VA 0.

### Networking, Threads, Atomics

See the networking and threads sections above for the full list.

## Compatibility Layer

The newlib and compatibility surface is intentionally source-level, not ABI
emulation. Important files:

| File | Purpose |
| --- | --- |
| `userland/lib/newlib_syscalls.c` | newlib bottom-end syscalls |
| `userland/compat/stubs.c` | POSIX-like functions and safe stubs |
| `userland/compat/sys/socket.h` | socket source declarations |
| `userland/compat/netinet/in.h` | IPv4/IPv6 address structures |
| `userland/compat/netdb.h` | name-resolution declarations |
| `userland/compat/poll.h` | `pollfd` and event constants |
| `userland/compat/termios.h` | terminal compatibility declarations |

Expect some POSIX calls to be no-ops or `ENOSYS` stubs until a port needs real
behavior and tests are added.

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
| Threads and futexes | `kernel/sched/futex.swift`, `userland/lib/swift_user.h` | `./tests/threads_test.sh`, `./tests/boot_test.sh` |
| mmap and W^X | `kernel/mm/vm.swift`, `userland/lib/syscall.h`, `userland/lib/swift_user.h` | `./tests/mmap_test.sh`, `./tests/boot_test.sh` |
| Networking bridge | `kernel/net/*`, `userland/lib/swift_user.h`, `userland/compat/sys/socket.h` | `./tests/udp_echo_test.sh`, `./tests/tcp_echo_test.sh`, `./tests/dns_test.sh`, `./tests/boot_test.sh` |
| Package syscalls | `kernel/pkg/store.swift`, `userland/pkg.swift`, `userland/lib/syscall.h` | `make package-local-install-test`, `make package-repo-install-test`, `make package-lua-repo-install-test`, `make package-ports-seed-repo-install-test`, `make package-static-host-repo-install-test`, `make package-static-host-dns-repo-install-test` |
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

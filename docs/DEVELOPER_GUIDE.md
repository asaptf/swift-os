# SwiftOS Developer Guide

This guide explains how to build user programs for SwiftOS. It covers the
recommended native Embedded Swift path, the C/newlib compatibility path, and the
workflow for adding programs to the base image.

For exact syscall and structure details, see [API_REFERENCE.md](API_REFERENCE.md).
For platform, runtime, package, filesystem, and porting compatibility decisions,
see [COMPATIBILITY_GUIDE.md](COMPATIBILITY_GUIDE.md).
For a practical source-port workflow, see [PORTING_GUIDE.md](PORTING_GUIDE.md).
For copy-paste application recipes, see
[APPLICATION_COOKBOOK.md](APPLICATION_COOKBOOK.md). For validation strategy,
see [TESTING_GUIDE.md](TESTING_GUIDE.md).

## Development Model

SwiftOS userland is static and rebuilt from source:

- Target architecture: `aarch64-none-none-elf`.
- User mode: EL0.
- Linking: static only.
- Dynamic loader: none.
- Primary language: Embedded Swift.
- C compatibility: newlib plus project-owned compatibility shims.
- Kernel ABI: SwiftOS POSIX-like syscall ABI, not Linux.

There are two supported application paths:

| Path | Use it for | Link inputs |
| --- | --- | --- |
| Native Embedded Swift | First-party tools and modern SwiftOS apps | `crt0.o`, `swift_user.o`, your Swift object |
| C/newlib compat | Porting C programs and compatibility tools | `crt0_newlib.o`, `newlib_syscalls.o`, compat stubs, newlib, libm, libgcc |

Prefer native Embedded Swift for new SwiftOS programs.

## Native Swift User Programs

Native tools import the C bridge declared in `userland/lib/swift_user.h`. The
Makefile passes it with:

```make
-import-objc-header userland/lib/swift_user.h
```

The program entry point is a C-callable `main`:

```swift
@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc
    _ = argv
    _ = envp

    swiftos_puts("hello from SwiftOS\n")
    return 0
}
```

Rules of thumb:

- Do not import Foundation.
- Avoid host-only Swift APIs.
- Use `swiftos_*` bridge calls for I/O, filesystem, network, process, time,
  mmap, thread, and futex operations.
- Use `withUnsafeTemporaryAllocation` for short-lived buffers.
- Keep long-lived heap use deliberate. The Swift runtime allocation hooks route
  through the K&R-style allocator in `swift_user.c`.
- If dynamic `String` comparison or hashing needs Unicode data tables, link
  `$(SWIFT_UNICODE_DATA)` as `calc` and `kv` do.

### Print Text

```swift
swiftos_puts("status: ok\n")
swiftos_putc(0x0A)
```

Write bytes to a file descriptor:

```swift
let message: StaticString = "raw bytes\n"
message.withUTF8Buffer {
    _ = swiftos_write(1, $0.baseAddress, UInt($0.count))
}
```

### Read A File

```swift
@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc
    _ = argv
    _ = envp

    let fd = swiftos_open("/etc/motd", 0)
    if fd < 0 {
        swiftos_puts("open failed\n")
        return 1
    }

    withUnsafeTemporaryAllocation(byteCount: 128, alignment: 1) { buf in
        let n = swiftos_read(fd, buf.baseAddress, UInt(buf.count))
        if n > 0 {
            _ = swiftos_write(1, buf.baseAddress, UInt(n))
        }
    }
    _ = swiftos_close(fd)
    return 0
}
```

### Create A tmpfs File

The base filesystem is read-only. Write scratch data under `/tmp`:

```swift
let fd = swiftos_open("/tmp/example.txt", 0x40 | 1) // O_CREAT | O_WRONLY
if fd >= 0 {
    let s: StaticString = "hello tmpfs\n"
    s.withUTF8Buffer {
        _ = swiftos_write(fd, $0.baseAddress, UInt($0.count))
    }
    _ = swiftos_close(fd)
}
```

The process needs `capTmpWrite`.

### Use UDP

```swift
let fd = swiftos_socket()
if fd < 0 {
    swiftos_puts("socket failed\n")
    return 1
}
if swiftos_bind(fd, 5555) != 0 {
    swiftos_puts("bind failed\n")
    return 1
}

var ip: UInt32 = 0
var port: UInt16 = 0
withUnsafeTemporaryAllocation(byteCount: 512, alignment: 16) { buf in
    let n = swiftos_recvfrom(fd, buf.baseAddress, UInt(buf.count), &ip, &port)
    if n > 0 {
        _ = swiftos_sendto(fd, buf.baseAddress, UInt(n), ip, port)
    }
}
_ = swiftos_close(fd)
```

The process needs `capNet`.

### Use TCP

```swift
let fd = swiftos_socket_stream()
if fd < 0 { return 1 }
if swiftos_bind(fd, 8080) != 0 { return 1 }
if swiftos_listen(fd, 8) != 0 { return 1 }

let client = swiftos_accept(fd)
if client >= 0 {
    swiftos_puts("accepted\n")
    _ = swiftos_close(client)
}
_ = swiftos_close(fd)
```

For a poll-driven server, follow `userland/httpd.swift`.

### Use mmap With W^X

```swift
let len: UInt = 4096
let protRW = Int32(SWIFTOS_PROT_READ) | Int32(SWIFTOS_PROT_WRITE)
let protRX = Int32(SWIFTOS_PROT_READ) | Int32(SWIFTOS_PROT_EXEC)
let rw = swiftos_mmap(len, protRW)
if rw == 0 {
    swiftos_puts("mmap failed\n")
    return 1
}

// Write code or data into rw...

if swiftos_mprotect(rw, len, protRX) != 0 {
    swiftos_puts("mprotect failed\n")
    return 1
}

_ = swiftos_munmap(rw, len)
```

`PROT_WRITE | PROT_EXEC` is rejected.

### Use Threads And Futexes

`swiftos_thread_create(entry, arg, stack_top)` starts another EL0 thread in the
same address space. The entry function must call `swiftos_thread_exit()` rather
than returning, because the thread enters from `eret` without a normal return
address.

Use the atomic helpers in `swift_user.h` plus `swiftos_futex()` to build locks.
See `userland/threadsdemo.swift` for the complete pattern.

## Adding A Native Swift Program

Assume a new source file:

```text
userland/mytool.swift
```

Add a userland artifact variable near the other `USER_*_ELF` variables:

```make
USER_MYTOOL_ELF := $(BUILD)/mytool.elf
```

Add an object rule:

```make
$(BUILD)/user_mytool.o: userland/mytool.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/mytool.swift -o $@
```

Add a link rule:

```make
$(USER_MYTOOL_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_mytool.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_mytool.o -o $@
```

If the program needs Unicode data tables for dynamic `String` comparison or
hashing, add `$(SWIFT_UNICODE_DATA)` before `-o $@`.

Add the ELF to the base-image dependencies and copy it into `$(BASE_ROOT)/bin`
in the base-image recipe:

```make
cp $(USER_MYTOOL_ELF) $(BASE_ROOT)/bin/mytool
```

Then build and boot:

```sh
make build base-image
make run
```

Inside the guest:

```sh
/bin/mytool
```

## C Programs On The Raw Syscall ABI

Small C programs can use `userland/lib/syscall.h` directly:

```c
#include "lib/syscall.h"

int main(void) {
    const char msg[] = "hello from C\n";
    write(1, msg, sizeof(msg) - 1);
    return 0;
}
```

The raw wrapper style returns SwiftOS values directly. Most syscalls return a
nonnegative success value or a negative errno-like value. The raw wrappers do not
always set C `errno`.

## C Programs Through newlib

Ported C software should use the newlib path:

1. Build the sysroot:

   ```sh
   make newlib
   ```

2. Build or port the program with `aarch64-elf-gcc`.
3. Link statically with:

   - `userland/lib/crt0_newlib.S`
   - `userland/lib/newlib_syscalls.c`
   - `userland/compat/stubs.c`
   - `sysroot/aarch64-elf/lib/libc.a`
   - `libm` and `libgcc` when needed

The compatibility layer provides source-level POSIX shapes for busybox, nginx
probes, and similar software. It is not Linux ABI compatibility. It translates
selected functions onto the SwiftOS syscall surface and stubs unsupported calls
with conventional errors when possible.

## Porting Checklist

When evaluating a C or Swift runtime port, check:

- Does it require dynamic linking? SwiftOS currently supports static linking
  only.
- Does it require Linux syscall numbers? SwiftOS does not provide them.
- Does it assume a persistent writable root filesystem? Use `/tmp` or package
  image design instead.
- Does it require `fork` semantics? `fork` exists for compatibility, but the
  preferred process model is explicit spawn with selected handles.
- Does it require mmap executable pages? The supported pattern is RW mapping,
  write code, then `mprotect` to RX.
- Does it need network sockets? The process must have `capNet`.
- Does it need filesystem reads or writes? The process must have `capFsRead`
  and/or `capTmpWrite`.
- Does it need many file descriptors? Current compat `OPEN_MAX` is small.
- Does it require signals, process groups, or terminal ioctls beyond the current
  shell subset? Check `userland/compat/stubs.c`.

## Testing A Program

Add at least one test that proves the behavior from outside the kernel:

- Host-side Swift unit test for pure logic.
- In-QEMU serial test for user-visible behavior.
- Network test with QEMU slirp and host tools such as `nc` or `curl`.
- Boot acceptance marker if the program is part of a milestone.

Tests should be wired into `make test` when they are part of the standard
acceptance suite.

## Common Mistakes

### Importing Foundation

Do not import Foundation in native userland. The userland target is freestanding
Embedded Swift.

### Writing To The Base Image

The base filesystem is read-only. Use `/tmp`.

### Returning From A Thread Entry

An EL0 thread entry must call `swiftos_thread_exit()`.

### Passing A Handle Without Rights

`spawn_handles` attenuates rights. The child cannot perform an operation unless
the inherited handle includes the needed right.

### Assuming POSIX `errno` On Raw Wrappers

The raw syscall wrappers return negative errno-like values. The newlib compat
layer converts many calls to `errno`, but the raw bridge does not.

## Source Examples

Good starting points:

| File | Shows |
| --- | --- |
| `userland/echo.swift` | Minimal argument handling and output |
| `userland/cat.swift` | File read loop |
| `userland/ls.swift` | `stat`, `getdents`, and formatting |
| `userland/httpd.swift` | Poll-driven TCP server and static file serving |
| `userland/udpecho.swift` | UDP sockets, IPv4, and IPv6 message layouts |
| `userland/threadsdemo.swift` | EL0 threads, atomics, futex |
| `userland/mmapdemo.swift` | mmap, munmap, mprotect, W^X |
| `userland/spawndemo.c` | `spawn` and `spawn_handles` |
| `userland/c4b_sockxfer.c` | Endpoint handle transfer |

# SwiftOS Application Cookbook

This cookbook gives practical recipes for building small SwiftOS applications.
Use it with [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) for the development model
and [API_REFERENCE.md](API_REFERENCE.md) for exact syscall, structure, and
bridge details. For evaluating upstream source ports, use
[PORTING_GUIDE.md](PORTING_GUIDE.md).

SwiftOS user programs are static EL0 binaries. The normal workflow is:

1. Write the program under `userland/`.
2. Add a Makefile object rule, link rule, base-image dependency, and copy step.
3. Run `make build base-image`.
4. Boot the guest and run the program from `/bin`.
5. Add a host or QEMU acceptance test before treating the behavior as shipped.

## Choose A Path

| Path | Use it when | Notes |
| --- | --- | --- |
| Native Embedded Swift | New first-party tools and modern SwiftOS apps | Preferred path. Uses `userland/lib/swift_user.h` as the bridge. |
| Raw C syscall app | Tiny low-level utilities and ABI probes | Uses `userland/lib/syscall.h` directly. Negative errno-like returns are exposed. |
| C/newlib port | Porting larger C software | Uses newlib, `userland/lib/newlib_syscalls.c`, and `userland/compat/*`. |
| Package artifact | Optional software outside the default `/bin` set | Use `.swpkg`, package-store, signed repository, or the current seed/static-host install smoke. |

## Recipe: Native Swift Command

Create `userland/helloapp.swift`:

```swift
// SPDX-License-Identifier: Apache-2.0

private func writeCString(_ p: UnsafePointer<CChar>) {
    var n = 0
    while p[n] != 0 { n += 1 }
    _ = swiftos_write(1, UnsafeRawPointer(p), UInt(n))
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    swiftos_puts("helloapp: hello")
    if argc > 1, let argv = argv, let name = argv[1] {
        swiftos_puts(", ")
        writeCString(name)
    }
    swiftos_puts("\n")
    return 0
}
```

Add a binary variable near the other `USER_*_ELF` variables:

```make
USER_HELLOAPP_ELF := $(BUILD)/helloapp.elf
```

Add the program to `BASE_EXEC_ELFS`:

```make
BASE_EXEC_ELFS := \
	$(USER_HELLOAPP_ELF) \
	...
```

Add an object rule near the other native Swift object rules:

```make
$(BUILD)/user_helloapp.o: userland/helloapp.swift userland/lib/swift_user.h Makefile | $(BUILD)/.dir
	$(SWIFTC) $(USER_SWIFT_FLAGS) -c userland/helloapp.swift -o $@
```

Add a link rule near the other native Swift link rules:

```make
$(USER_HELLOAPP_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_helloapp.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_swift_user.o $(BUILD)/user_helloapp.o -o $@
```

Add the base-image copy step in the `$(BASE_IMG)` recipe:

```make
cp $(USER_HELLOAPP_ELF) $(BASE_ROOT)/bin/helloapp
```

Build and boot:

```sh
make build base-image
make run
```

In the guest:

```sh
/bin/helloapp SwiftOS
```

Expected output:

```text
helloapp: hello, SwiftOS
```

## Recipe: Read A Base File And Write tmpfs

The base image is read-only. Use it for application assets and defaults, then
write runtime state under `/tmp`.

```swift
// SPDX-License-Identifier: Apache-2.0

private let oReadOnly: Int32 = 0
private let oWriteOnly: Int32 = 1
private let oCreate: Int32 = 0x40
private let oTrunc: Int32 = 0x80

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc
    _ = argv
    _ = envp

    let inFd = swiftos_open("/etc/motd", oReadOnly)
    if inFd < 0 {
        swiftos_puts("filecopy: cannot open /etc/motd\n")
        return 1
    }

    let outFd = swiftos_open("/tmp/motd.copy", oCreate | oTrunc | oWriteOnly)
    if outFd < 0 {
        swiftos_puts("filecopy: cannot create /tmp/motd.copy\n")
        _ = swiftos_close(inFd)
        return 1
    }

    withUnsafeTemporaryAllocation(byteCount: 256, alignment: 16) { buf in
        while true {
            let n = swiftos_read(inFd, buf.baseAddress, UInt(buf.count))
            if n <= 0 { break }
            _ = swiftos_write(outFd, buf.baseAddress, UInt(n))
        }
    }

    _ = swiftos_close(outFd)
    _ = swiftos_close(inFd)
    swiftos_puts("filecopy: wrote /tmp/motd.copy\n")
    return 0
}
```

Capability requirements:

- Reading `/etc/motd` requires `capFsRead`.
- Creating `/tmp/motd.copy` requires `capTmpWrite`.
- The seeded `root` and `user` accounts can run this flow; `guest` cannot read
  files in the default identity store.

## Recipe: One-Shot TCP Service

Boot QEMU with host TCP 5555 forwarded to guest TCP 5555. The network profile
in [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md) shows the complete QEMU command.

Application core:

```swift
// SPDX-License-Identifier: Apache-2.0

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc
    _ = argv
    _ = envp

    let fd = swiftos_socket_stream()
    if fd < 0 {
        swiftos_puts("minihttp: socket failed\n")
        return 1
    }
    if swiftos_bind(fd, 5555) != 0 {
        swiftos_puts("minihttp: bind failed\n")
        _ = swiftos_close(fd)
        return 1
    }
    if swiftos_listen(fd, 1) != 0 {
        swiftos_puts("minihttp: listen failed\n")
        _ = swiftos_close(fd)
        return 1
    }

    swiftos_puts("minihttp: listening on 5555\n")
    let client = swiftos_accept(fd)
    if client >= 0 {
        let response: StaticString =
            "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nhello\n"
        response.withUTF8Buffer {
            _ = swiftos_write(client, $0.baseAddress, UInt($0.count))
        }
        _ = swiftos_close(client)
    }

    _ = swiftos_close(fd)
    return 0
}
```

Host check:

```sh
curl http://127.0.0.1:5555/
```

Expected output:

```text
hello
```

The process needs `capNet`; use the seeded `root` account unless the identity
store has been changed.

## Recipe: Raw C Syscall Utility

Create `userland/chello.c`:

```c
// SPDX-License-Identifier: Apache-2.0

#include "lib/syscall.h"

int main(void) {
    const char msg[] = "chello: hello from raw syscalls\n";
    long n = write(1, msg, sizeof(msg) - 1);
    return n < 0 ? 1 : 0;
}
```

Add a binary variable:

```make
USER_CHELLO_ELF := $(BUILD)/chello.elf
```

Add the ELF to `BASE_EXEC_ELFS`, then add an object rule:

```make
$(BUILD)/user_chello.o: userland/chello.c userland/lib/syscall.h Makefile | $(BUILD)/.dir
	$(CLANG) $(USER_CFLAGS) userland/chello.c -o $@
```

Add a link rule:

```make
$(USER_CHELLO_ELF): $(BUILD)/user_crt0.o $(BUILD)/user_chello.o userland/user.ld Makefile
	$(LDBIN) $(USER_LDFLAGS) $(BUILD)/user_crt0.o $(BUILD)/user_chello.o -o $@
```

Add the base-image copy step:

```make
cp $(USER_CHELLO_ELF) $(BASE_ROOT)/bin/chello
```

Build and run:

```sh
make build base-image
make run
```

Guest:

```sh
/bin/chello
```

Expected output:

```text
chello: hello from raw syscalls
```

Raw syscall wrappers return SwiftOS values directly. Most failures are negative
errno-like values, not `-1` plus `errno`.

## Recipe: Use newlib For A C Port

Use newlib when a port expects C library calls such as `printf`, `malloc`, or
POSIX-shaped socket declarations.

1. Build the sysroot:

   ```sh
   make newlib
   ```

2. Start from an existing newlib-linked target such as `userland/newlibtest.c`.
3. Link against:

   - `userland/lib/crt0_newlib.S`
   - `userland/lib/newlib_syscalls.c`
   - `userland/compat/stubs.c` when the port needs compatibility shims
   - `sysroot/aarch64-elf/lib/libc.a`
   - `libm` and `libgcc` when needed

4. Keep the resulting binary static and copy it into the base image or a package
   payload.

Do not expect Linux syscall numbers, dynamic linking, `/proc`, `/sys`, or a
persistent writable root.

## Recipe: Ship A Program As A Package

Use packages when the program should not be part of the default base `/bin` set.
The current checked-in fixtures cover five levels:

| Level | What it proves | Command |
| --- | --- | --- |
| Read-only payload overlay | A package payload can be mounted at boot | `make package-overlay-test` |
| Package-store activation | A package-store image can activate a payload at boot | `make package-store-test` |
| Guest local install | `/bin/pkg install FILE` installs into a writable package-store disk | `make package-local-install-test` |
| Signed repository install | `/bin/pkg install NAME` resolves dependencies and verifies a signed catalog | `make package-repo-install-test` |
| Real source-port repository install | `/bin/pkg install lua`, `zlib`, `bzip2`, `ca-certificates`, `pcre2`, `tzdata`, `nginx`, and `sqlite` install real upstream/data packages | `make package-ports-seed-repo-install-test` |

The sample fixture builds `/usr/bin/pkghello`:

```sh
make package-fixture
build/swpkg inspect build/pkghello.swpkg
make package-overlay-test
make package-store-test
make package-local-install-test
make package-repo-install-test
```

The important pieces are:

| Path | Purpose |
| --- | --- |
| `fixtures/pkghello/manifest.json` | Package metadata and file manifest |
| `build/pkghello.swpkg` | Host package artifact |
| `build/pkghello-payload.img` | Read-only payload image attached at boot |
| `build/pkgstore-install.img` | Writable package-store image used by target-side install tests |
| `build/pkgrepo-root/aarch64/current/catalog.signed` | Signed repository catalog fixture |

Inside the guest, the local install path looks like:

```sh
pkg list
pkg install /packages/pkghello.swpkg
pkg list
/usr/bin/pkghello
```

The signed repository path looks like:

```sh
pkg repo set http://10.0.2.2:<port>/aarch64/current
pkg update
pkg search pkghello
pkg info pkghello
pkg install pkghello
/usr/bin/pkghello
```

Public hosted repositories, remove, upgrade, rollback, and version-constraint
solving are not current behavior.

### Recipe: Build And Install Source Ports

Lua, zlib, bzip2, zstd, xz, ca-certificates, pcre2, tzdata, nginx, and sqlite are the
current real port fixtures. They prove checksum-verified source fetch, static
AArch64 cross-build or data-only staging, `.swpkg` creation, signed local
repository publication, and target-side install from a default repository URL.
The Lua-only smoke remains useful for the interpreter path; the seed repository
smoke installs Lua, zlib, bzip2, zstd, xz, ca-certificates, pcre2, tzdata, nginx, and
sqlite and runs the `minigzip`, zstd, and xz round trips, bzip2 version/marker smoke, CA bundle marker,
`pcre2grep` regex match, zoneinfo marker read, nginx version/marker smoke, and
a SQLite in-memory query in the guest. The static-host smoke serves the same
seed repository from a deployable web-root layout and repeats that
install path; the hosted URL smoke proves that `/bin/pkg` can install from a
DNS-resolved HTTP repository hostname.

```sh
make ports-lua-repo-fixture
build/swpkg inspect build/lua.swpkg
build/pkgrepo inspect build/lua-repo-root/aarch64/current/catalog.signed
make package-lua-repo-install-test
make ports-zlib-repo-fixture
make ports-bzip2-repo-fixture
make ports-ca-certificates-repo-fixture
make ports-pcre2-repo-fixture
make ports-tzdata-repo-fixture
make ports-nginx-repo-fixture
make ports-sqlite-repo-fixture
make ports-seed-repo-fixture
make package-ports-seed-repo-install-test
make ports-static-host-publish
make package-static-host-repo-install-test
make ports-hosted-url-verify-test
make package-static-host-dns-repo-install-test
```

The guest-side flow exercised by the test is:

```sh
pkg repo set http://10.0.2.2:<port>/aarch64/current
pkg update
pkg install lua
/usr/bin/lua -v
/usr/bin/lua -e 'print(21 * 2)'
pkg install zlib
pkg install bzip2
pkg install ca-certificates
pkg install pcre2
pkg install tzdata
pkg install nginx
pkg install sqlite
echo zlib-ok > /tmp/zlib.txt
/usr/bin/minigzip /tmp/zlib.txt
/usr/bin/minigzip -d /tmp/zlib.txt.gz
cat /tmp/zlib.txt
echo bzip2-ok > /tmp/bzip2.txt
/usr/bin/bzip2 /tmp/bzip2.txt
/usr/bin/bzip2 -d /tmp/bzip2.txt.bz2
cat /tmp/bzip2.txt
cat /usr/share/certs/swiftos-ca-bundle.version
echo nginx-lighttpd > /tmp/pcre2.txt
/usr/bin/pcre2grep 'nginx|lighttpd' /tmp/pcre2.txt
cat /usr/share/zoneinfo/swiftos-tzdata.version
/usr/sbin/nginx -v
/usr/bin/sqlite3 -batch -noheader -cmd '.mode list' :memory: 'select 6*7;'
```

Use this recipe as the maintainer-side and guest-smoke reference for new source
ports.

## Testing Recipes

Use the smallest test that proves the behavior:

| Behavior | Test shape |
| --- | --- |
| Pure parser or algorithm | Host Swift unit test compiled with `/usr/bin/swiftc` |
| Console command output | QEMU serial test that logs in and runs the command |
| TCP/UDP behavior | QEMU slirp test plus host `curl` or `nc` |
| Base image contents | Host test that opens `build/base.img` or guest `ls -l` check |
| Package overlay visibility | `make package-overlay-test` |
| Guest package install | `make package-local-install-test` or `make package-repo-install-test` |
| Source port package fixture | `make ports-recipe-test`, the individual package fixture for the port you changed, `make package-ports-seed-repo-install-test`, `make package-static-host-repo-install-test`, and `make package-static-host-dns-repo-install-test` |

For a command promoted into the default image, add the test to `make test` when
the workflow is stable enough for the standard acceptance suite.

## Common Review Checklist

Before merging a new application:

- The program is static and does not import host-only APIs.
- The program handles negative `swiftos_*` returns explicitly.
- Filesystem writes stay under `/tmp` unless the design adds a new writable
  service.
- Networking tools document the required QEMU host forwarding and `capNet`.
- Long-running services expose a clear ready marker on serial; see
  [SERVICE_GUIDE.md](SERVICE_GUIDE.md) for the current service contract.
- Optional software uses `/usr` package paths and records whether it is proven
  by a local install, signed repository install, or source-port repository
  install smoke.
- The Makefile rule includes all source dependencies that should trigger a
  rebuild.
- `make build base-image` passes.
- A focused test proves the user-visible workflow.

## Source Examples

Use these checked-in programs as reference implementations:

| Source | Pattern |
| --- | --- |
| `userland/echo.swift` | Argument scanning and raw stdout writes |
| `userland/cat.swift` | File read loop |
| `userland/ls.swift` | Directory entries, stat records, formatting |
| `userland/httpd.swift` | Poll-driven TCP server |
| `userland/tcpecho.swift` | One-shot TCP server |
| `userland/udpecho.swift` | UDP sockets and peer address handling |
| `userland/threadsdemo.swift` | EL0 threads, atomics, futex |
| `userland/mmapdemo.swift` | Anonymous mmap, munmap, mprotect, W^X |
| `userland/llmd.swift` | File-backed mmap, TCP service, model-bundle verification |
| `userland/spawndemo.c` | `spawn`, `spawn_handles`, handle inheritance |
| `userland/c4b_sockxfer.c` | Endpoint handle transfer |
| `userland/drvsvcdemo.c`, `userland/drvinputd.c` | Restartable service supervision, device discovery, and opaque grant transfer |

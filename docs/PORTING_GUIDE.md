# SwiftOS Porting Guide

This guide explains how to evaluate and port source-built software to SwiftOS.
It is written for application authors, package maintainers, and release owners
who need to decide whether a program can run on the current SwiftOS ABI and how
to adapt it without importing legacy platform assumptions.

SwiftOS is not Linux, does not provide a Linux ABI, and does not run existing
ELF binaries unchanged. Porting means rebuilding from source against the
SwiftOS syscall surface, native Embedded Swift bridge, or C/newlib compatibility
layer.

Use this guide with:

- [Compatibility Guide](COMPATIBILITY_GUIDE.md) for platform-level compatibility
  decisions.
- [Developer Guide](DEVELOPER_GUIDE.md) for native SwiftOS build patterns.
- [Application Cookbook](APPLICATION_COOKBOOK.md) for copy-paste app recipes.
- [API Reference](API_REFERENCE.md) for syscall numbers, structures, bridge
  calls, and handle rights.
- [Package Guide](PACKAGE_GUIDE.md) for package payload and package-store
  workflows.
- [Package Build Automation Guide](PACKAGE_BUILD_AUTOMATION.md) for the planned
  `swport` recipe, CI, and repository publishing workflow.
- [Administration Guide](ADMINISTRATION_GUIDE.md) for accounts, capabilities,
  and image configuration.

## Porting Model

SwiftOS ports are static, source-built, and explicit about their dependencies.

| Property | Current SwiftOS requirement |
| --- | --- |
| CPU target | `aarch64-none-none-elf` |
| Binary format | Static ELF user program |
| Dynamic loader | None |
| Kernel ABI | SwiftOS POSIX-like syscalls, not Linux syscalls |
| C library | newlib port plus project-owned compatibility shims |
| Preferred new app path | Native Embedded Swift |
| Durable installed files | Immutable base image or read-only package payload |
| Runtime writable state | `/tmp`, RAM-backed and cleared on reboot |
| Networking | Requires virtio-net boot profile and `capNet` |

The porting goal is not to emulate a legacy Unix distribution. Prefer small
source changes, static linking, explicit capability requirements, and tests that
prove the exact workflow under QEMU.

## First Decision

Do not start with the build system. Start by classifying the program.

| Program shape | Recommended path |
| --- | --- |
| New first-party tool | Native Embedded Swift |
| Tiny low-level probe | Raw C with `userland/lib/syscall.h` |
| Existing C program needing libc | C/newlib compatibility path |
| Network daemon | Native Swift or C/newlib, plus explicit `capNet` test |
| CLI tool with filesystem reads and `/tmp` writes | Native Swift or C/newlib |
| Program requiring Linux `/proc`, `/sys`, ioctls, epoll, dlopen, or shared libraries | Redesign, stub, or defer |
| Binary-only software | Not compatible |
| Software needing persistent writable root | Redesign state storage or defer |

If the program is small and core to SwiftOS, rewrite it natively. If the program
is an upstream C utility with portable libc assumptions, try newlib. If it
depends on Linux kernel surfaces, treat the missing surface as a product
decision, not a local hack.

## Compatibility Triage

Before editing code, answer these questions.

| Question | Continue when | Stop or redesign when |
| --- | --- | --- |
| Is source available? | Yes | Binary-only |
| Can it link statically? | Yes | Requires shared libraries or plugins |
| Can storage be read-only plus `/tmp`? | Yes | Requires persistent mutable root |
| Can missing OS APIs be removed or shimmed narrowly? | Yes | Requires broad Linux emulation |
| Does it need networking? | QEMU profile and `capNet` are acceptable | It assumes host networking configuration APIs |
| Does it need process control? | `spawn`, `execve`, pipes, `poll`, or limited `fork` are enough | Needs full Unix job control or procfs |
| Does it need threads? | Current `thread_create` and futex-like waits are enough | Needs full pthreads contract |
| Does it need files larger than the current test envelope? | You can add focused tests | It needs unimplemented storage behavior |

Record the decision in the package notes or PR description. A good port should
make its missing assumptions obvious before code review.

## Choose A Build Path

### Native Embedded Swift

Use this for new SwiftOS tools and services.

Reference files:

| File | Use |
| --- | --- |
| `userland/lib/swift_user.h` | Swift bridge declarations |
| `userland/lib/swift_user.c` | Runtime hooks and bridge implementation |
| `userland/user.ld` | User ELF linker script |
| `userland/*.swift` | Existing native tools |

Rules:

- Do not import Foundation.
- Keep binaries static.
- Use `swiftos_*` bridge calls for OS services.
- Check negative return values explicitly.
- Document required capability bits.
- Add a QEMU test for user-visible behavior.

### Raw C Syscalls

Use this for small ABI probes or utilities that do not need libc.

Reference files:

| File | Use |
| --- | --- |
| `userland/lib/syscall.h` | Syscall numbers and inline wrappers |
| `userland/lib/fs.h` | File structures and flags |
| `userland/lib/termios.h` | Minimal terminal ABI |

Raw wrappers expose SwiftOS return conventions directly. Most errors are
negative errno-like values. Do not assume libc-style `-1` plus `errno` unless
you are using a compatibility wrapper that documents it.

### C/newlib Compatibility

Use this for C ports that expect `printf`, `malloc`, basic POSIX-shaped file
APIs, socket declarations, or common libc entry points.

Reference files:

| File | Use |
| --- | --- |
| `userland/lib/crt0_newlib.S` | newlib startup |
| `userland/lib/newlib_syscalls.c` | newlib bottom end |
| `userland/compat/stubs.c` | Compatibility shims |
| `userland/compat/*` | Header compatibility surface |

Build the sysroot when needed:

```sh
make newlib
```

Then model the Makefile target on an existing newlib-linked program. Keep the
link static and stage the resulting ELF into the base image or a package
payload.

## Common Code Adaptations

| Upstream assumption | SwiftOS adaptation |
| --- | --- |
| Linux syscall numbers | Use `syscall.h` wrappers or newlib shims |
| Dynamic linking or `dlopen` | Build a static binary and disable plugin loading |
| `/proc` or `/sys` | Use SwiftOS process/sysinfo APIs when available, or remove the feature |
| Persistent `/var` or `/etc` writes | Use `/tmp` for scratch; rebuild base image for defaults |
| `fork` as a server concurrency primitive | Prefer `poll`, threads/futex where suitable, or a native service design |
| `epoll`, `kqueue`, netlink | Use current `poll` and socket syscalls or defer feature |
| Unix users/groups as security policy | Map to SwiftOS principals and capability masks |
| Runtime package downloads | Use host-built package payloads today |
| Shell scripts relying on many external tools | Keep scripts small or port the required tools first |

When adding a shim, keep it narrow. A stub that fails clearly is better than a
large compatibility layer that silently lies about behavior.

## Filesystem Porting

SwiftOS has an immutable base image and RAM-backed `/tmp`.

| Need | Recommended path |
| --- | --- |
| Read default config | Stage it under `base/etc/` or another base-image path |
| Read web/static assets | Stage them under `base/www/` or a package payload |
| Read model or data blobs | Stage them under `models/` and pack into `/models` |
| Write runtime scratch | Use `/tmp` |
| Persist runtime data across reboot | Not a current guest contract |
| Install optional software | Use a read-only package payload or package-store image |

Example guest check:

```sh
cat /etc/motd
echo ok >/tmp/port-check.txt
cat /tmp/port-check.txt
```

Writes outside writable tmpfs should fail. Do not work around that by adding
mutable root assumptions to the port.

## Networking Porting

Networking requires:

1. QEMU launched with a virtio-net device.
2. A principal with `capNet`.
3. A program built against current socket and poll APIs.

Start with a narrow smoke:

```sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
./tests/dns_test.sh
```

Use these reference programs:

| Source | Pattern |
| --- | --- |
| `userland/httpd.swift` | Poll-driven TCP server |
| `userland/tcpecho.swift` | TCP accept/read/write loop |
| `userland/udpecho.swift` | UDP socket and peer handling |
| `userland/tcpget.swift` | Simple TCP client |
| `userland/nslookup.swift` | DNS resolver use |
| `userland/tlsget.swift` | TLS 1.3 demo client path |

Current limits:

- No target-side interface configuration command.
- No production certificate trust store policy.
- No Linux netlink, iptables, or routing-tool compatibility.
- `/bin/httpd` and `/bin/llmd` both bind guest TCP 8080; test one at a time.

## Process And Concurrency Porting

Current process and concurrency tools include:

| Need | Current surface |
| --- | --- |
| Run another image | `spawn`, `spawn_handles`, `execve` |
| Wait for a child | `waitpid` |
| Pipes and redirection | `pipe`, `dup`, `dup2`, `fcntl`, `poll` |
| Threads | `thread_create` |
| Wait/wake primitive | `futex` |
| Memory mapping | `mmap`, `mmap_file`, `munmap`, `mprotect` |

Guidance:

- Prefer explicit `spawn_handles` for new designs that pass authority.
- Treat broad `fork` inheritance as compatibility, not the long-term model.
- Use `poll` for small servers before adding more process concurrency.
- Respect W^X: `PROT_WRITE | PROT_EXEC` mappings are rejected.
- Add a stress or QEMU acceptance test when touching concurrency behavior.

## Packaging A Port

Use a package payload when the port should not become part of the default base
image.

Current package flow:

```sh
make package-fixture
make package-overlay-test
make package-store-test
```

Package content is read-only at runtime. Put binaries under `/usr/bin` in the
payload namespace unless the package guide says otherwise.

Before publishing a package recipe, record:

- Source origin and license.
- Build flags and static-link choices.
- Installed paths.
- Required capability bits.
- Guest command used for verification.
- Known disabled upstream features.
- Acceptance test name.

See [Package Guide](PACKAGE_GUIDE.md) and
[Server Software Catalog](SERVER_SOFTWARE_CATALOG.md).

## Testing A Port

Every shipped port needs an executable proof.

| Port behavior | Recommended proof |
| --- | --- |
| Pure parser, archive reader, or formatter | Host unit test |
| Command output | QEMU serial login test |
| File read/write behavior | QEMU test plus `/tmp` and base-image checks |
| Package visibility | Package overlay or package-store test |
| TCP service | QEMU network test plus host `curl` or `nc` |
| UDP service | QEMU network test plus host UDP client |
| DNS client | Resolver test |
| TLS client | TLS fixture test |
| AI/model asset loader | Model-bundle host test plus serving smoke |

Minimum gates for a user-visible port:

```sh
make build base-image
./tests/boot_test.sh
```

Use `make test` before calling a broad userland or compatibility change
release-ready.

## Documentation For A Port

When a port becomes a supported SwiftOS workflow, update the relevant docs:

| Change | Docs to update |
| --- | --- |
| New command in the default image | `COMMAND_REFERENCE.md`, `USER_GUIDE.md`, tests |
| New network service | `SERVICE_GUIDE.md`, `NETWORKING_GUIDE.md`, tests |
| New package payload | `PACKAGE_GUIDE.md`, package format notes, tests |
| New public ABI shim | `API_REFERENCE.md`, `DEVELOPER_GUIDE.md`, headers |
| New admin workflow | `ADMINISTRATION_GUIDE.md`, `TROUBLESHOOTING.md` |
| New known limit | `RELEASE_NOTES.md`, `COMPATIBILITY_GUIDE.md` |

Prefer documenting the exact current behavior. Future goals belong in roadmap
documents unless the feature already works.

## Port Review Checklist

Before merging a port:

1. The program is rebuilt from source for `aarch64-none-none-elf`.
2. The binary is static.
3. No Linux ABI, dynamic loader, `/proc`, `/sys`, or kernel-module assumption
   remains in the supported path.
4. Runtime writes are under `/tmp` or an explicitly documented service.
5. Installed defaults are in the base image or package payload.
6. Required capability bits are documented.
7. Negative SwiftOS syscall returns are handled.
8. Network tests name the QEMU forwarding and guest port.
9. A focused test proves the main user-visible behavior.
10. User-facing docs and troubleshooting notes are updated.

## Useful Reference Programs

| Source | Pattern |
| --- | --- |
| `userland/echo.swift` | Argument scanning and stdout writes |
| `userland/cat.swift` | File read loop |
| `userland/ls.swift` | Directory entries, stat records, name lookup |
| `userland/head.swift` | Simple file processing |
| `userland/wc.swift` | Text counting and stdin/file handling |
| `userland/httpd.swift` | Poll-driven static HTTP server |
| `userland/tcpecho.swift` | TCP server |
| `userland/udpecho.swift` | UDP server |
| `userland/threadsdemo.swift` | Threads, atomics, futex |
| `userland/mmapdemo.swift` | mmap, mprotect, W^X |
| `userland/llmd.swift` | File-backed mmap, model bundles, TCP serving |
| `userland/spawndemo.c` | Spawn and explicit handle inheritance |
| `userland/c4b_sockxfer.c` | IPC endpoint handle transfer |

Use these as working examples before inventing a new pattern.

## When To Defer A Port

Deferring is the right choice when the port would require a broad compatibility
fiction.

Defer when the program requires:

- Linux kernel modules or device nodes that SwiftOS does not expose.
- Dynamic libraries or plugin loading as a core feature.
- Persistent database or writable-root semantics that cannot be redesigned.
- Full pthreads or process-group behavior not covered by current APIs.
- `/proc`, `/sys`, netlink, cgroups, namespaces, seccomp, or containers.
- GPU, CUDA, ROCm, or desktop graphics stacks.
- Production TLS trust policy before the trust-store work lands.

Record the blocker in the package catalog or roadmap so the dependency is
visible and can be scheduled deliberately.

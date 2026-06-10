# SwiftOS Compatibility Guide

This guide describes what the current SwiftOS system is compatible with, what
requires a port, and what is intentionally outside the current product contract.
It is written for operators, application authors, and people evaluating whether
an existing workload can run on SwiftOS.

SwiftOS is a modern, static, capability-aware operating system. Compatibility is
source-oriented: rebuild programs for the SwiftOS ABI, link statically, package
them into the immutable base image or a read-only package overlay, and design
runtime state around explicit capabilities and `/tmp` scratch storage.

## Compatibility Snapshot

| Area | Current support |
| --- | --- |
| CPU architecture | AArch64 only |
| Primary machine | QEMU `virt` |
| Firmware paths | Direct `-kernel` fallback and UEFI/AAVMF disk boot |
| VirtualBox ARM | Best-effort profile |
| Kernel ABI | SwiftOS POSIX-like syscall ABI, not Linux |
| Userland linking | Static only |
| Dynamic loader | Not present |
| Native Swift apps | Embedded Swift user programs through `userland/lib/swift_user.h` |
| C apps | Source ports through newlib and project-owned compatibility shims |
| Shell | Busybox `ash` for login and bring-up compatibility |
| Filesystem writes | `/tmp` tmpfs only |
| Installed software | Immutable base image plus read-only package overlays and package-store activations |
| Networking | virtio-net, IPv4/IPv6 smoke, TCP, UDP, DNS, HTTP demos, TLS client demo |
| Packages | Host-built `.swpkg` format, read-only payload overlays, and P3a package-store boot activation |
| Containers | No Docker/OCI compatibility |
| Linux binaries | Not supported |
| x86-64 binaries | Not supported |

For exact build variables and QEMU profiles, see
[CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md). For syscall details,
see [API_REFERENCE.md](API_REFERENCE.md).

## What Compatibility Means

SwiftOS does not try to run legacy binaries unchanged. A workload is considered
compatible when it can be:

1. Built for `aarch64-none-none-elf`.
2. Linked statically.
3. Run through the SwiftOS syscall ABI.
4. Given explicit process capabilities and handles.
5. Installed into the base image or a read-only package overlay.
6. Written so durable state is not assumed to live in a mutable root filesystem.

This keeps the trusted core small and makes compatibility testable. It also
means many Unix-like source programs can be ported, while Linux binary
compatibility is not a goal.

## Hardware And Platform Compatibility

### Supported Now

| Platform | Status | Notes |
| --- | --- | --- |
| QEMU `virt`, direct `-kernel` | Primary | Used by most development and acceptance tests |
| QEMU `virt`, UEFI/AAVMF disk | Primary boot path | Uses `build/swift-os.img` plus read-only base image |
| QEMU `virt`, virtio-net | Supported for network tests | Required for `httpd`, `llmd`, echo tools, DNS, TLS demos |
| QEMU `virt`, framebuffer/input | Smoke-tested | Used by graphical and busybox `vi` smoke paths |
| VirtualBox ARM | Best effort | Board profile exists; see [VIRTUALBOX.md](VIRTUALBOX.md) |

### Not Supported Now

| Platform | Status |
| --- | --- |
| x86-64 / amd64 | Not supported |
| Raspberry Pi boards | Not supported |
| PC BIOS boot | Not supported |
| ACPI-first server hardware | Not supported |
| SMP EL0 general execution | In hardening roadmap; use current SMP tests for readiness only |

Example primary boot:

```sh
make build base-image build/virt.dtb
make run
```

Example UEFI boot:

```sh
make disk base-image
make disk-run
```

Acceptance coverage: `./tests/boot_test.sh`, `./tests/uefi_boot_test.sh`,
`./tests/smp_boot_test.sh`.

## Application Compatibility

### Native Embedded Swift

Native SwiftOS user programs are the preferred application path.

Current contract:

- Use Embedded Swift.
- Do not import Foundation.
- Use the C bridge in `userland/lib/swift_user.h`.
- Export a C-callable `main`.
- Link statically with the SwiftOS userland startup objects.
- Stage the ELF into `/bin` through `make base-image` or into a package payload.

Minimal shape:

```swift
@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    swiftos_puts("hello from SwiftOS\n")
    return 0
}
```

See [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) for the full workflow.

### C And newlib Source Ports

C programs can be ported at source level through:

- `userland/lib/syscall.h` for raw SwiftOS syscall helpers.
- `userland/lib/crt0_newlib.S` for newlib startup.
- `userland/lib/newlib_syscalls.c` for libc syscall glue.
- `userland/compat/` for POSIX-like compatibility declarations and stubs.

Use this path for small C utilities and selected compatibility software. It is
not glibc compatibility and not Linux syscall compatibility.

Build prerequisites:

```sh
make newlib
make busybox
```

### Busybox Compatibility

Busybox is present as `/bin/busybox` and is used as the login shell. It is a
bring-up and compatibility tool, not the long-term SwiftOS application model.

Useful current coverage:

```sh
/bin/busybox ash
/bin/busybox vi /tmp/note.txt
```

Acceptance coverage: `./tests/busybox_test.sh`, `./tests/vi_test.sh`.

### Linux Binaries

Linux ELF binaries do not run on SwiftOS.

Reasons:

- Syscall numbers and syscall semantics are SwiftOS-specific.
- There is no Linux dynamic loader.
- There is no glibc or musl userspace ABI contract.
- The security model is capabilities and handles, not Linux uid/capability
  inheritance.

Port the source instead. For new software, prefer native Embedded Swift.

## Runtime Compatibility

| Runtime | Current status | Guidance |
| --- | --- | --- |
| Embedded Swift user programs | Supported | Preferred path |
| Full Swift with Foundation | Not current | Avoid host-only APIs; use Embedded Swift |
| C/newlib | Supported for selected ports | Static source ports only |
| musl | Possible future option | Not the current libc path |
| Node.js | Long-horizon goal | Do not assume it works now |
| JVM | Long-horizon goal | Do not assume it works now |
| POSIX threads | Not a full pthreads contract | Use current `thread_create`/futex APIs |
| Dynamic languages needing files + sockets only | Porting candidate | Requires static runtime port and capability review |

The current AI-serving proof path is native Swift:

```sh
/bin/llm
/bin/llmd
```

`/bin/llm` keeps the small fp32 `stories260K` console demo. `/bin/llmd`
defaults to the signed verified Q8_0 `stories15M` bundle under
`/models/stories15M` and can be started with explicit
`llmd [model.bin] [tokenizer.bin]` paths for supported checkpoint formats
without signed-bundle verification.

Acceptance coverage: `./tests/llm_run_test.sh`, `./tests/llm_serve_test.sh`.

## Filesystem And Data Compatibility

SwiftOS has a two-tier filesystem:

| Path | Source | Writable | Lifetime |
| --- | --- | --- | --- |
| `/bin` | Packed base image | No | Immutable until rebuilt |
| `/etc` | Packed base image | No | Immutable until rebuilt |
| `/www` | Packed base image | No | Immutable until rebuilt |
| `/models` | Packed base image | No | Immutable until rebuilt |
| `/tmp` | tmpfs | Yes, with `capTmpWrite` | Lost on reboot |
| `/usr/bin/pkghello` | Package overlay fixture | No | Present only with overlay attached |

Compatible applications should treat installed files as read-only and use
`/tmp` for runtime scratch:

```sh
mkdir /tmp/app
echo ok >/tmp/app/status.txt
cat /tmp/app/status.txt
```

Not supported as current compatibility contracts:

- Persistent mutable root filesystem.
- ext2/ext4/FAT/UFS/ZFS mounting.
- journaling.
- fsck.
- POSIX ACLs.
- Extended attributes.
- User home directories with durable storage.

To change installed files, rebuild the base image:

```sh
make base-image
```

To add package overlay content, build and attach a payload image:

```sh
make package-fixture
make package-overlay-test
```

## Networking Compatibility

Socket programs require:

1. A QEMU virtio-net device.
2. A process with `capNet`.

For complete launch profiles, host forwarding, DNS, TCP/UDP, TLS, IPv6 smoke
paths, and troubleshooting, see [NETWORKING_GUIDE.md](NETWORKING_GUIDE.md).

Current user-visible network tools:

| Tool | Protocol | Purpose |
| --- | --- | --- |
| `/bin/httpd` | TCP 8080 | Static file server for `/www` |
| `/bin/llmd` | TCP 8080 | TinyStories inference over HTTP |
| `/bin/tcpecho` | TCP 5555 | One-shot TCP echo server |
| `/bin/udpecho` | UDP 5555 | One-shot UDP echo server |
| `/bin/tcpget` | TCP client | Guest-to-host TCP active open |
| `/bin/nslookup` | UDP DNS | A and AAAA lookup demo |
| `/bin/tlsget` | TLS client | TLS 1.3 runtime demo |

Example host forwarding for HTTP-style services:

```sh
qemu-system-aarch64 ... \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080 \
  -device virtio-net-device,netdev=n0
```

Then run one TCP 8080 service in the guest:

```sh
/bin/httpd
# or
/bin/llmd
```

`/bin/httpd` and `/bin/llmd` both bind guest TCP port 8080, so run one at a
time.

TLS note: `tlsget` exercises the current TLS 1.3 client path, but production
certificate verification is not complete. Do not treat it as a production trust
decision.

Acceptance coverage: `./tests/httpd_test.sh`, `./tests/llm_serve_test.sh`,
`./tests/tcp_echo_test.sh`, `./tests/udp_echo_test.sh`,
`./tests/tcp_connect_test.sh`, `./tests/dns_test.sh`, `./tests/tls_test.sh`,
`./tests/ipv6_smoke_test.sh`, `./tests/ipv6_tcp_echo_test.sh`, and
`./tests/ipv6_udp_echo_test.sh`.

## Security And Identity Compatibility

SwiftOS exposes POSIX-like names where useful, but kernel authorization is not
Unix-root-centered.

Current identity source:

| File | Role |
| --- | --- |
| `base/etc/swos/passwd` | SwiftOS principal and capability source |
| `base/etc/passwd` | Compatibility view |
| `base/etc/group` | Compatibility view |

Seeded accounts:

| Account | Principal | Capability mask | Compatibility meaning |
| --- | ---: | ---: | --- |
| `root` | 1 | `0x3f` | Full demo authority; not a Unix superuser contract |
| `user` | 2 | `0x0e` | Spawn, filesystem read, tmpfs write |
| `guest` | 3 | `0x02` | Spawn-only restricted account |

File owner and mode metadata are visible through `ls -l`, `chmod`, and `chown`,
but current access checks are capability-first. A port that assumes `uid == 0`
can override all filesystem and network policy must be adapted.

See [SECURITY_GUIDE.md](SECURITY_GUIDE.md) and
[CAPABILITIES.md](CAPABILITIES.md).

## Package And Distribution Compatibility

SwiftOS package compatibility is currently host-side and boot-activation based.

Supported now:

- Host `.swpkg` tool.
- Package manifests.
- Payload extraction.
- Read-only package payload image attachment at boot.
- Preseeded package-store image attachment at boot.
- Guest execution from attached package namespace, proven by `/usr/bin/pkghello`.

Not supported now:

- Target-side `pkg install`.
- Target-side remove/upgrade transactions.
- Network package repositories.
- RPM, DEB, APK, Homebrew, Nix, or OCI image compatibility.

Example:

```sh
make package-fixture
make package-overlay-test
make package-store-test
```

For the complete package runbook, see [PACKAGE_GUIDE.md](PACKAGE_GUIDE.md). See
[PACKAGE_MANAGEMENT.md](PACKAGE_MANAGEMENT.md) and [SWPKG_FORMAT.md](SWPKG_FORMAT.md)
for design and format details.

## Porting Decision Tree

Use this checklist before porting a program.

| Question | If yes | If no |
| --- | --- | --- |
| Is source code available? | Rebuild for SwiftOS | Binary-only software is not compatible |
| Can it link statically? | Continue | Remove dynamic-loader dependency first |
| Can it use the SwiftOS syscall surface or newlib shims? | Continue | Add or redesign the missing ABI path |
| Does it need persistent writable root? | Redesign state storage | Use base image plus `/tmp` |
| Does it need networking? | Run with `capNet` and virtio-net | It can run in non-network sessions |
| Does it need `fork` heavily? | Audit carefully | Prefer `spawn` or native process design |
| Does it assume Linux `/proc` or `/sys`? | Port or remove those assumptions | Continue |
| Does it require kernel modules? | Not compatible now | Continue |
| Does it need GPU/CUDA/ROCm? | Not compatible now | Continue |

## Porting Workflow

1. Start with the current docs map:

   ```sh
   less docs/DOCUMENTATION.md
   ```

2. Confirm the target build works:

   ```sh
   make tools-check
   make build
   ```

3. Choose the application path:

   - Native Embedded Swift: [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md).
   - C/newlib source port: [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md#c-programs-through-newlib).
   - Raw syscall C: [API_REFERENCE.md](API_REFERENCE.md).

4. Decide where files live:

   - Installed files: base image or package overlay.
   - Runtime scratch: `/tmp`.
   - Durable storage: not a current guest contract.

5. Decide capabilities:

   - File reads: `capFsRead`.
   - tmpfs writes: `capTmpWrite`.
   - networking: `capNet`.
   - process inspection: `capProcessInspect`.

6. Add an acceptance test that boots QEMU when the behavior depends on kernel,
   VFS, networking, process, or capability behavior.

7. Update user-facing docs and command references when the port becomes a
   shipped interface.

## Common Compatibility Questions

### Can I run a Linux static binary?

No. Static linking removes the dynamic loader dependency, but the binary still
uses the Linux syscall ABI. Rebuild the program for SwiftOS.

### Can I use `/tmp` like a normal writable filesystem?

Use it for scratch state only. It is RAM-backed and lost on reboot.

### Can a fully capable `root` process write `/etc`?

No. The base image is read-only by design. Change `/etc` by rebuilding the base
image.

### Can I run an HTTP service?

Yes, with a virtio-net boot profile and `capNet`. Current examples are
`/bin/httpd` and `/bin/llmd`.

### Can I use TLS for production trust decisions?

Not yet. `tlsget` proves the TLS runtime path, but certificate verification is
not complete.

### Can I run Node.js or the JVM?

Not today. They are long-horizon goals. Keep ports from depending on choices
that would block those runtimes later, but do not document them as current
features.

### Can I use Docker containers?

No. Future Cells are planned as SwiftOS-native isolated execution domains, not
Docker or Linux namespace compatibility.

## Verification

Use the narrowest test that proves the compatibility path you changed.

| Path | Minimum verification |
| --- | --- |
| Native Swift user program | `make build base-image`, command-specific QEMU test |
| C/newlib user program | `make newlib`, `make build base-image`, relevant QEMU test |
| Base image content | `make base-image`, `./tests/vfs_disk_test.sh` |
| Package overlay/store | `make package-overlay-test`; `make package-store-test` |
| Login or capabilities | `./tests/console_login_test.sh`, `./tests/cap_enforce_test.sh` |
| Network service | Service-specific network test plus `./tests/virtio_net_test.sh` |
| LLM serving | `./tests/llm_serve_test.sh` |
| UEFI boot | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |

For broad release confidence, run:

```sh
make test
```

## Related Documents

- [GETTING_STARTED.md](GETTING_STARTED.md): first boot.
- [USER_GUIDE.md](USER_GUIDE.md): using the running guest.
- [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md): command syntax and examples.
- [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md): host and QEMU
  knobs.
- [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md): writing and porting applications.
- [API_REFERENCE.md](API_REFERENCE.md): syscall and bridge ABI.
- [SECURITY_GUIDE.md](SECURITY_GUIDE.md): capability and handle model.
- [PACKAGE_MANAGEMENT.md](PACKAGE_MANAGEMENT.md): package ecosystem state.

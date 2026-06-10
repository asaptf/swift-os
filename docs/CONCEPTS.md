# SwiftOS Concepts

This guide explains the core ideas behind the current SwiftOS system. It is for
readers who want the mental model before diving into command syntax, API
layouts, package formats, or kernel design notes.

SwiftOS is a small AArch64 operating system written in Embedded Swift. Its
current product shape is application and AI hosting, with embedded/appliance
deployment as a co-primary profile. It is intentionally not a Linux clone:
software is rebuilt from source, images are immutable, authority is explicit,
and tests are part of the public contract.

Use this guide with:

- [Getting Started](GETTING_STARTED.md) for the first boot.
- [User Guide](USER_GUIDE.md) for interactive operation.
- [Administration Guide](ADMINISTRATION_GUIDE.md) for accounts and image
  administration.
- [Developer Guide](DEVELOPER_GUIDE.md) for writing native programs.
- [Porting Guide](PORTING_GUIDE.md) for adapting source-built software.
- [API Reference](API_REFERENCE.md) for exact ABI details.
- [Architecture](ARCHITECTURE.md) for the long-form design record.

## Product Shape

SwiftOS is currently:

| Property | Meaning |
| --- | --- |
| QEMU-first | The primary target is `qemu-system-aarch64 -M virt` |
| Serial-first | The normal UI is the PL011 serial console through QEMU |
| Static | User programs are statically linked |
| Source-built | Existing Linux or macOS binaries do not run unchanged |
| Immutable by default | Installed system files come from read-only images |
| Capability-aware | Processes carry explicit authority bits and handles carry rights |
| Test-driven | Milestones ship executable host or QEMU checks |

The current system is useful for development, demos, compatibility work, and
early product hardening. It is not yet a general desktop or production hosting
environment.

## Boot And Execution Levels

SwiftOS uses AArch64 exception levels:

| Term | Meaning |
| --- | --- |
| EL1 | Kernel mode |
| EL0 | User mode |

The normal boot targets are:

| Boot path | Use it for |
| --- | --- |
| Direct `-kernel` boot | Fast kernel, userland, and VFS development |
| UEFI/GPT disk boot | Firmware handoff and primary boot-path validation |
| Graphical smoke boot | Framebuffer/input checks, not a desktop shell |

The direct path normally uses:

```text
build/kernel.elf
build/base.img
build/virt.dtb
```

The UEFI path normally uses:

```text
build/swift-os.img
build/base.img
```

See [Installation Guide](INSTALLATION_GUIDE.md) for exact commands.

## Images And Artifacts

SwiftOS separates boot artifacts from installed software artifacts.

| Artifact | Concept |
| --- | --- |
| `build/kernel.elf` | Kernel image for direct QEMU boot |
| `build/kernel.bin` | Flat kernel binary used by loader flows |
| `build/base.img` | Read-only packed base filesystem |
| `build/virt.dtb` | Device tree used by direct QEMU boot |
| `build/swift-os.img` | GPT disk with the EFI System Partition and loader |
| `.swpkg` | Host-built package artifact |
| Package payload image | Read-only package filesystem attached at boot |
| Package store image | Package-store boot activation image |

An update today means rebuilding one or more artifacts on the host, booting the
candidate, validating it, and keeping rollback artifacts available. See
[Update And Rollback Guide](UPDATE_GUIDE.md).

## Filesystem Model

SwiftOS uses a two-tier filesystem:

| Tier | Typical paths | Writable | Lifetime |
| --- | --- | --- | --- |
| Packed base image | `/bin`, `/etc`, `/www`, `/models` | No | Across boots until rebuilt |
| tmpfs scratch | `/tmp` | Yes, with `capTmpWrite` | Cleared on reboot |

This design keeps boot deterministic and avoids in-place mutation of system
files. To change durable system content, edit host-side inputs and rebuild the
base image:

```sh
make base-image
```

Inside the guest:

```sh
cat /etc/motd
echo ok >/tmp/check.txt
cat /tmp/check.txt
```

Writes to `/etc`, `/bin`, `/www`, and `/models` should fail in the current
system.

## Identity And Authority

SwiftOS does not use Unix `uid 0` as the primary authority model. A process has
a security context:

```text
principal
session
capability mask
cell tag
```

The current checked-in image has three demo accounts:

| Account | Role |
| --- | --- |
| `root` | Full demo authority, including networking |
| `user` | Filesystem read plus tmpfs write |
| `guest` | Spawn-only confinement checks |

Check the current identity:

```sh
id
```

The capability mask controls coarse authority such as filesystem reads, tmpfs
writes, process inspection, and networking. File descriptors and IPC endpoints
also carry per-handle rights, so authority is not only a global bitmask.

For the operational model, see [User Guide](USER_GUIDE.md). For administration,
see [Administration Guide](ADMINISTRATION_GUIDE.md). For exact ABI structures,
see [API Reference](API_REFERENCE.md).

## Handles And Capabilities

A handle is a small process-local descriptor that names a kernel object and
carries rights. Handles are used for files, pipes, tty, sockets, and IPC
endpoints.

The current important ideas are:

- A process may have a capability bit such as `capFsRead` or `capNet`.
- An opened handle may still be read-only, write-only, or transfer-limited.
- `spawn` starts a child with stdio only by default.
- `spawn_handles` passes an explicit, attenuated handle set.
- IPC transfer moves a handle to the receiver on success.
- `confine(path)` narrows filesystem visibility and cannot widen it again.

This is the practical bridge from today's capability-aware system to the
long-term object-capability model described in [Capabilities](CAPABILITIES.md).

## Programs And APIs

SwiftOS user programs are static EL0 binaries. There are three main application
paths:

| Path | Use it for |
| --- | --- |
| Native Embedded Swift | New first-party tools and SwiftOS-native apps |
| Raw C syscalls | Tiny low-level utilities and ABI probes |
| C/newlib compatibility | Source ports that expect libc and POSIX-shaped APIs |

Native Swift programs use the bridge in:

```text
userland/lib/swift_user.h
```

Raw C programs use:

```text
userland/lib/syscall.h
```

The syscall ABI is SwiftOS-specific. Linux syscall numbers, Linux static
binaries, dynamic loaders, and shared-library plugin models are not part of the
current system.

See [Developer Guide](DEVELOPER_GUIDE.md),
[Application Cookbook](APPLICATION_COOKBOOK.md),
[Porting Guide](PORTING_GUIDE.md), and [API Reference](API_REFERENCE.md).

## Packages

Packages are the path for optional software that should not be baked into the
base `/bin` set.

Current package concepts:

| Term | Meaning |
| --- | --- |
| `.swpkg` | Host package artifact with manifest and payload |
| Payload image | Read-only package filesystem mounted at boot |
| Package store | Boot-activated store image with package generations |
| Local install flow | Current package-manager path for installing a local package into the store |

Package behavior is still evolving. Use [Package Guide](PACKAGE_GUIDE.md) for
the current runbook and [Package Management](PACKAGE_MANAGEMENT.md) for the
longer direction.

## Networking And Services

Networking requires both:

1. A QEMU virtio-net device.
2. A process with `capNet`.

Current networking includes UDP, TCP, DNS, IPv6 smoke paths, a static HTTP
server, echo tools, a TCP client, and a TLS demo client path.

Common service examples:

| Service | Command |
| --- | --- |
| Static HTTP | `/bin/httpd` |
| LLM serving | `/bin/llmd` |
| TCP echo | `/bin/tcpecho` |
| UDP echo | `/bin/udpecho` |

Services currently run in the foreground from the serial shell and inherit the
current login principal. There is no production service supervisor yet.

See [Networking Guide](NETWORKING_GUIDE.md) and [Service Guide](SERVICE_GUIDE.md).

## AI Hosting

SwiftOS includes a TinyStories inference path to prove application and AI
hosting primitives:

| Command | Purpose |
| --- | --- |
| `/bin/llm` | Local completion demo |
| `/bin/llmd` | HTTP inference service on guest TCP 8080 |

The serving path loads verified model bundle generations from `/models`. The
checked-in image intentionally includes a corrupt newest generation and a valid
older generation so tests prove rejection and fallback.

See [AI Hosting Guide](AI_HOSTING_GUIDE.md).

## Observability And Evidence

The primary evidence source today is serial output plus test logs. The kernel
also has structured log-ring groundwork and process/resource reporting.

Useful guest commands:

```sh
id
ps
top -b -n 1
```

Useful host checks:

```sh
./tests/boot_test.sh
./tests/httpd_test.sh
./tests/llm_serve_test.sh
```

See [Observability Guide](OBSERVABILITY_GUIDE.md),
[Testing Guide](TESTING_GUIDE.md), and [Support Guide](SUPPORT_GUIDE.md).

## Current Versus Roadmap

SwiftOS documentation separates current behavior from roadmap goals.

Current behavior includes:

- QEMU `virt` boot.
- UEFI/GPT disk boot.
- Serial console login.
- Static user programs.
- Immutable base image and `/tmp`.
- Capability-gated filesystem and networking operations.
- Read-only package payloads and package-store activation paths.
- TinyStories local and HTTP serving demos.
- A broad host and QEMU test suite.

Roadmap work includes:

- Stronger object-capability boundaries.
- More restartable userland services.
- Broader SMP hardening.
- Signed A/B OS image updates with rollback.
- Richer package repositories and persistent package management.
- Stronger production account and secret handling.
- Native Swift application runtime growth, then Node.js and JVM support.

Use [Release Notes](RELEASE_NOTES.md) for the checked-in product state and
[Risk Remediation Roadmap](RISK_REMEDIATION_ROADMAP.md) for active hardening
work.

## Glossary

| Term | Meaning |
| --- | --- |
| Base image | Read-only packed filesystem built as `build/base.img` |
| Capability | Coarse process authority bit such as filesystem read or networking |
| Cell | Future lightweight isolation/accounting domain; currently a tag |
| EL0 | AArch64 user mode |
| EL1 | AArch64 kernel mode |
| Handle | Process-local descriptor for a kernel object, with rights |
| Principal | Authenticated identity number carried by a process |
| Session | Login/session number carried with the principal |
| tmpfs | RAM-backed writable scratch filesystem under `/tmp` |
| UEFI path | Boot through AAVMF and `build/swift-os.img` |
| Direct path | QEMU `-kernel build/kernel.elf` boot |

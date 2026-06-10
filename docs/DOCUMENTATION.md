# SwiftOS Documentation

This page is the public documentation map for SwiftOS, the operating system
implemented in Embedded Swift and shipped as a small, static, capability-aware
AArch64 system image.

SwiftOS documentation is split by audience. Start with the guide that matches
what you are trying to do, then use the reference documents for exact ABI and
format details.

## Start Here

| Need | Document |
| --- | --- |
| Build, boot, log in, run commands, and use QEMU | [Getting Started](GETTING_STARTED.md) |
| Choose and verify a direct, UEFI, graphical, or VirtualBox boot profile | [Installation Guide](INSTALLATION_GUIDE.md) |
| Review shipped features, verification gates, and known limits | [Release Notes](RELEASE_NOTES.md) |
| Rebuild, update, validate, and roll back immutable SwiftOS artifacts | [Update And Rollback Guide](UPDATE_GUIDE.md) |
| Use the installed system from the serial console | [User Guide](USER_GUIDE.md) |
| Look up command syntax, examples, limits, and acceptance coverage | [Command Reference](COMMAND_REFERENCE.md) |
| Find build, boot, test, QEMU, board, and guest defaults | [Configuration Reference](CONFIGURATION_REFERENCE.md) |
| Operate boot profiles, networking demos, package overlays, and verification gates | [Operations Guide](OPERATIONS_GUIDE.md) |
| Run and verify virtio-net, host forwarding, DNS, TCP, UDP, TLS, and IPv6 paths | [Networking Guide](NETWORKING_GUIDE.md) |
| Run, observe, test, and design SwiftOS services | [Service Guide](SERVICE_GUIDE.md) |
| Host TinyStories inference with model bundles, health checks, and metrics | [AI Hosting Guide](AI_HOSTING_GUIDE.md) |
| Read boot health, service metrics, process snapshots, and log evidence | [Observability Guide](OBSERVABILITY_GUIDE.md) |
| Diagnose build, boot, login, filesystem, network, package, and test failures | [Troubleshooting](TROUBLESHOOTING.md) |
| Collect logs, evidence, severity, and report details for support handoff | [Support Guide](SUPPORT_GUIDE.md) |
| Answer common product, install, compatibility, package, networking, AI, and support questions | [FAQ](FAQ.md) |
| Follow copy-paste workflows for common demos | [Examples](EXAMPLES.md) |
| Check hardware, application, package, runtime, and network compatibility | [Compatibility Guide](COMPATIBILITY_GUIDE.md) |
| Understand current login, capabilities, handle rights, and security limits | [Security Guide](SECURITY_GUIDE.md) |
| Write native SwiftOS user programs | [Developer Guide](DEVELOPER_GUIDE.md) |
| Follow copy-paste application build and test recipes | [Application Cookbook](APPLICATION_COOKBOOK.md) |
| Call the EL0 syscall ABI or Swift bridge directly | [API Reference](API_REFERENCE.md) |
| Understand the system architecture and non-goals | [Architecture](ARCHITECTURE.md) |
| Understand handles, capabilities, and the isolation roadmap | [Capabilities](CAPABILITIES.md) |
| Understand the immutable base image | [Base Image](BASE_IMAGE.md) |
| Build, inspect, boot, test, and troubleshoot package artifacts | [Package Guide](PACKAGE_GUIDE.md) |
| Understand package format and package-manager direction | [Package Management](PACKAGE_MANAGEMENT.md) |
| Review the current hardening roadmap | [Risk Remediation Roadmap](RISK_REMEDIATION_ROADMAP.md) |
| Review detailed milestone history | [Notes](NOTES.md) |

## Documentation Contract

The consumer-facing documents describe the current checked-in system, not only
the long-term design. When the design and implementation differ, these documents
call out the current behavior and point to the roadmap for future work.

Normative API details live in:

- `userland/lib/syscall.h` for syscall numbers, low-level wrappers, mmap
  constants, and handle-right constants.
- `userland/lib/swift_user.h` for the native Embedded Swift bridge.
- `userland/lib/fs.h`, `userland/lib/termios.h`, and `userland/compat/*` for C
  and newlib-facing source layouts.
- `kernel/syscall/syscall.swift` for the kernel dispatcher.
- `kernel/vfs/handle.swift` for handle kinds, rights, and explicit spawn
  inheritance structures.

The API reference mirrors those sources so application authors can work from one
document, but the headers remain the build-time contract.

Installation and boot profile procedures live in
[INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md), operational procedures live in
[OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md), update and rollback runbooks live
in [UPDATE_GUIDE.md](UPDATE_GUIDE.md), networking runbooks live in
[NETWORKING_GUIDE.md](NETWORKING_GUIDE.md), service lifecycle rules live in
[SERVICE_GUIDE.md](SERVICE_GUIDE.md), and observability procedures live in
[OBSERVABILITY_GUIDE.md](OBSERVABILITY_GUIDE.md). Keep them aligned with the
acceptance tests under `tests/`; a command in the installation, operations,
networking, service, or observability guide should either be a normal manual
workflow or have a nearby test that proves the same path.

## Product State

SwiftOS is past bring-up and can boot under QEMU, authenticate users, run a
native Swift userland, serve files from a read-only base image, allocate tmpfs
scratch space, run a small TCP/IP stack, and execute user programs through its
own POSIX-like syscall surface.

Current product-shaping work is tracked in
[RISK_REMEDIATION_ROADMAP.md](RISK_REMEDIATION_ROADMAP.md). The most important
theme is turning the proven bring-up system into a stronger application-hosting
platform: tighter handle authority, SMP hardening, userland service boundaries,
and restartable services.

## Terminology

- **SwiftOS / swift-os**: The operating system. The repository and many files use
  `swift-os`; product-facing prose may use `SwiftOS`.
- **EL0**: User mode on AArch64.
- **EL1**: Kernel mode on AArch64.
- **Base image**: The immutable read-only filesystem image packed from `base/`
  plus staged `/bin` programs.
- **tmpfs**: Writable RAM scratch storage. Data is intentionally lost on reboot.
- **Handle**: A small per-process descriptor naming a kernel object and carrying
  rights.
- **Capability**: Coarse process authority such as filesystem read, tmpfs write,
  spawning, inspection, or networking.
- **Native Swift userland**: Programs compiled with Embedded Swift against
  `userland/lib/swift_user.*`.
- **newlib compat userland**: C or ported programs linked statically through the
  newlib bottom end and compatibility shims.

## Versioning Policy

There is no stable external ABI version number yet. Treat the current syscall
numbers and structure layouts as the ABI for this repository revision. When the
ABI is changed, update the headers, the API reference, tests, and the relevant
milestone notes in the same commit.

For package metadata, the documented ABI fields are in
[PACKAGE_MANAGEMENT.md](PACKAGE_MANAGEMENT.md) and
[SWPKG_FORMAT.md](SWPKG_FORMAT.md).

## Contributing Documentation

When adding public docs:

1. Prefer examples that are executable on the current system.
2. Link to the source header or implementation that defines the contract.
3. Separate current behavior from future roadmap language.
4. Keep all docs in English.
5. Run at least the relevant build or test target before committing.
6. For operational docs, name the acceptance test that proves each workflow when
   such a test exists.

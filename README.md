# swift-os

**A modern operating system written from scratch in [Embedded Swift](https://www.swift.org/get-started/embedded/) for 64-bit ARM** — a small, capability-isolated, fast-booting core, built by *removing* legacy rather than emulating it. Small enough to trust; real enough to run nginx and Node.js.

> 🌐 **The page at <https://swiftos.tech> is served by SwiftOS itself.** It runs on a bare-metal Hetzner Cloud ARM VM — nginx, statically linked against our own newlib port, on top of our own kernel, syscall ABI, and in-kernel TCP/IP stack. Not QEMU, not a container.

## What works today

- **Freestanding Embedded Swift kernel** — swift.org toolchain, target `aarch64-none-none-elf`, no Foundation, no full standard library. Value types and `Unsafe*` pointers at the metal; ARC and classes only above the heap.
- **Real MMU isolation** — one address space per process — with a **capability/principal** security model (authorization is principal + capability mask, never `uid == 0`).
- **A native Swift userland** — coreutils, an interactive shell, `ps`/`top`, `sshd` — on our own POSIX-like syscall ABI. No Linux ABI, static linking only, no dynamic loader.
- **An in-kernel TCP/IP stack** — DHCP, TCP, UDP, DNS, HTTP, TLS — with a sans-IO, pure-Swift protocol core.
- **SMP** — schedules across multiple cores (tested at `-smp 4`) with cross-CPU TLB shootdown and spinlock-protected kernel state (`make smp-test`, `make s5-test`).
- **A three-tier filesystem** — an immutable signed read-only base, a RAM `tmpfs` scratch tier, and a persistent, `fsync`-durable `/data` tier, durable enough to back SQLite (`make datafs-sqlite-test`).
- **Runs real software** — **nginx** serving HTTPS (`make nginx-test`, `make nginx-tls-test`), and **Node.js 24.16** brought up on V8 in `--v8-lite-mode` (jitless, so it needs no RWX pages): `node -e "console.log(6 * 7)"` prints `42`.
- **Boots on real hardware** — a bare Hetzner Cloud ARM VM via ACPI + GICv3 + PCIe ECAM/virtio-pci, not just QEMU `virt` (`make hetzner-deploy-test`).

It is a learning project: intentionally minimal, rough in places, and not production. Some pieces stay in C/asm on purpose — third-party code (busybox, the newlib port) and the MMIO / boot / syscall bridges — but the rule is **Swift by default**. The goal is a small, testable, modern core.

## Try it

```sh
# See it live — this site is served by SwiftOS itself:
#   https://swiftos.tech

# Or build and boot it yourself under QEMU (macOS Apple Silicon / Linux):
make newlib && make busybox     # one-time: cross-build the libc + bring-up shell
make build && make run          # boot the kernel under QEMU virt
make test                       # host unit tests + in-QEMU boot assertions
```

The project is not a Linux clone or a legacy-Unix compatibility exercise. The same minimalist core targets three profiles — **application & AI hosting** (flagship), **embedded/appliance**, and **desktop** (not excluded) — which differ mainly in which optional services and devices are present, not in the kernel.

## Current Status

The bring-up phase is complete; the system runs a native Swift userland with
networking, schedules across multiple cores (SMP), serves a persistent `/data`
tier, hosts nginx over HTTPS, and boots on real Hetzner Cloud ARM hardware.
Development continues under **Phase 1**: hardening for the product profile —
completing the capability/handle model and moving drivers toward restartable
userland services (see [docs/RISK_REMEDIATION_ROADMAP.md](docs/RISK_REMEDIATION_ROADMAP.md)).

What exists today, in the order it was built:

- **Phase 0 — bring-up (historical, M0–M8):** the kernel boots at EL1 on QEMU
  `virt`; UART, exceptions, GIC timer interrupts, the MMU, and preemptive EL0
  scheduling are up; each process has its own address space; fork/exec/waitpid
  work; a VFS exposes a read-only base FS plus a writable tmpfs; static ELF64
  programs load and execute from the VFS. The bring-up userland was a statically
  linked busybox `sh` (a legacy tool used to prove the syscall surface); the
  **native Swift userland is now the direction** (see below). `make test` covers
  host-side unit checks and QEMU boot assertions.

- **M9 — HAL + device tree:** the kernel reads its own DTB at boot and populates
  a global `Platform` struct; UART/GIC/RAM addresses come from the device tree
  instead of being hardcoded.

- **M10 (a/b/c) — UEFI boot from GPT disk:** a minimal AArch64 PE32+ EFI loader
  (`BOOTAA64.EFI`) calls `ExitBootServices` and hands off to the Swift kernel.
  `make disk` produces `build/swift-os.img`, a sparse GPT image with an EFI
  System Partition. `make disk-run` boots it under QEMU+AAVMF (edk2) with no
  `-kernel`. The direct `-kernel` path is kept as a fallback and both are tested
  by `make test`.

- **M10.5 — VirtualBox ARM prep:** the EFI loader emits diagnostics before
  handoff; a procedure for manually testing on VirtualBox ARM is in
  `docs/VIRTUALBOX.md`.

- **M11 (a–d) — virtio-blk + packed read-only base FS from disk:** a
  deterministic signed packed base image format (`SWOSBASE v3`); a host packer
  (`tools/basepack.swift`); a polled virtio 1.0 block driver; the VFS mounts the
  packed image at boot and serves `/bin`, `/etc`, and other base files directly
  from disk. The kernel no longer embeds any userland binary; the image shrank
  from ~1.4 MiB to ~208 KiB. Every `make run` / `make test` invocation attaches
  `build/base.img` as a virtio-blk device.

- **M12 (a–d) — capability/principal security + console-login as init:** a
  typed `ProcessSecurityContext` (principal, session, capability mask — not
  Unix uid==0); a base-image identity store `/etc/swos/passwd` with
  SHA-256-hashed passwords; `console-login` authenticates a principal, calls
  `SYS_LOGIN`, and `execve`s the shell with the adopted context; when a session
  ends, init loops back to a fresh login prompt.

- **M13 (a–c) + follow-ups — VFS capability enforcement, file ownership, shell
  redirection:** `vfsOpen` checks the caller's capability mask at open time
  (`capFsRead`, `capTmpWrite`); tmpfs namespace mutations (`mkdir`/`rm`/`mv`)
  require `capTmpWrite`; vnodes carry an owner (principal) and mode written at
  creation or packed from the base image; `ls -l` shows permission strings,
  owner names, sizes, and real timestamps (PL031 RTC); `fcntl` (`F_DUPFD_CLOEXEC`,
  `F_GETFD`/`F_SETFD`, `F_GETFL`) and close-on-exec semantics make shell I/O
  redirection (`echo > file`, `>>`, pipe-into-redirect) work correctly.

- **Native Swift userland coreutils:** a growing set of pure-Embedded-Swift EL0
  utilities over the `userland/lib/swift_user.*` bridge, all packed into the base
  image: `ls` (with `-l`), `cat`, `echo`, `pwd`, `ps`, `top`, `id`, `mkdir`,
  `rmdir`, `rm`, `mv`, `chmod`, `chown`, `head`, `touch`, `wc`, `date`, `calc`
  (an interactive expression REPL that exercises Swift `String`/`Array`/
  `Dictionary`/ARC), `kv` (an in-memory key-value REPL), and `console-login`.
  The userland free-capable allocator (K&R free-list over `sbrk`) backs ARC for
  these apps.

- **Network stack (N-series, in-kernel, sans-IO core):** a TCP/IP/UDP/ARP/ICMP/
  DNS stack in Embedded Swift. The protocol core (`kernel/net/`) is pure Swift
  (no MMIO/heap-per-packet), compiled into both the kernel and host unit tests.
  The virtio-net driver (`kernel/drivers/virtio_net.swift`) provides the DMA
  path. Capability-gated socket syscalls (`socket`/`bind`/`sendto`/`recvfrom`/
  `listen`/`accept`/`connect`/`resolve`) are exposed to EL0. Userland tools:
  `/bin/udpecho`, `/bin/tcpecho`, `/bin/tcpget`, `/bin/nslookup`, `/bin/httpd`
  (a concurrent poll()-driven static-file HTTP server with MIME types and
  directory listings), and `/bin/llmd` (TinyStories inference over HTTP). A
  ChaCha20-Poly1305 AEAD module (`kernel/crypto/`) is
  built and tested as TLS groundwork. DNS queries resolve against slirp's
  nameserver by default.

- **Restartable driver-service and device-discovery smoke:** the C5a-C5f path
  stages `/bin/drvsvcdemo` and `/bin/drvinputd`. The supervisor starts an
  input-driver service, exchanges endpoint IPC messages, discovers and claims
  `virtio-input.0` when QEMU exposes a keyboard device, falls back to
  `pseudo-input.0` in headless boots, surfaces virtio-mmio base/length as
  discovery metadata, proves future hardware-authority bits stay clear, keeps
  the current device grant metadata-only, transfers an opaque device handle,
  proves the grant moves, stays busy while the service owns it, is reclaimed
  after exit, and recovers with `C5a OK: restartable driver service recovered
  over IPC`, `C5b OK: opaque device handle transferred and released`, `C5c OK:
  virtio-input device grant discovered and matched`, `C5d OK: virtio input
  discovery metadata surfaced`, `C5e OK: device authority withheld until
  explicit handoff`, and `C5f OK: device grant rights stayed metadata-only`.
  The aggregate acceptance gate is `make c5-test`; real MMIO, IRQ, DMA, and
  virtio-input queue ownership are still roadmap work.

- **Threading runtime:** `thread_create`/`futex` (FUTEX_WAIT/FUTEX_WAKE)
  syscalls; EL0 threads share one address space; a futex-based mutex test proves
  correct concurrent increment across preemption.

- **Process teardown reclaims frames:** `address_space_destroy` walks and frees
  all user-half page tables and leaf frames on process exit/exec/reap; a boot-
  time reclaim test asserts zero leak across fork+exec+spawn round-trips.

- **Package and ports fixtures:** `.swpkg` packages, writable package-store
  images, signed static repository catalogs, and target-side `pkg install NAME`
  are covered by executable fixtures. The current ports path also cross-builds
  static AArch64 Lua, zlib, bzip2, zstd, xz, libarchive, OpenSSL, pcre2, nginx, and sqlite on the host,
  packages the pinned ca-certificates and tzdata bundles as data, publishes all
  twelve into one signed seed repository, emits a static-hostable repository
  root that can be served to QEMU, and proves install from a DNS-resolved
  hosted-style repository URL.

- **Product-profile hardening (post-M13):** **SMP** across cores (S0–S5: per-CPU
  scheduling, cross-CPU TLB shootdown, spinlock-protected kernel state; boots and
  runs the existing workloads at `-smp 4`); a persistent, `fsync`-durable **`/data`
  tier** (`datafs` on a dedicated virtio-blk disk, durable enough to back SQLite);
  **nginx** serving static HTTP and **HTTPS/TLS** from the base image and `/data`;
  **Node.js 24.16** cross-built for SwiftOS and running on V8 in `--v8-lite-mode`
  (jitless); and a bare-metal **Hetzner Cloud ARM** bring-up (ACPI tables, GICv3,
  PCIe ECAM + virtio-pci, DHCP, headless boot to `sshd`). Gates: `make smp-test`,
  `s5-test`, `datafs-sqlite-test`, `nginx-test`, `nginx-tls-test`,
  `hetzner-deploy-test`.

## Philosophy

The design is intentionally narrow:

1. **Lightweight by design.** Every always-on subsystem must justify its memory
   cost, CPU cost, boot-time cost, and security surface.
2. **Simple enough to trust.** Prefer explicit, testable mechanisms over clever
   machinery.
3. **Secure by construction.** Separate address spaces, capability-based handles,
   small privileged code. Kernel authorization is principal/capability, not
   uid==0.
4. **Correctness proven by tests.** Each milestone must build, boot, satisfy its
   acceptance criterion, and ship executable checks.
5. **Modern over legacy.** Rebuild tools against the swift-os ABI instead of
   importing Linux compatibility or old platform assumptions.

See [docs/PHILOSOPHY.md](docs/PHILOSOPHY.md) for the full project stance.

## Documentation

The public documentation starts at [docs/DOCUMENTATION.md](docs/DOCUMENTATION.md).
That map now includes role-based paths for first-time operators, deployment
owners, administrators, application developers, package maintainers, service
operators, AI hosting operators, support engineers, and security reviewers.

- [Getting Started](docs/GETTING_STARTED.md): build, boot, log in, run commands,
  and attach QEMU networking.
- [Concepts](docs/CONCEPTS.md): core SwiftOS terms, images, filesystem,
  identity, packages, services, testing, and roadmap boundaries.
- [Installation Guide](docs/INSTALLATION_GUIDE.md): choose and verify direct
  QEMU, UEFI/GPT, graphical smoke, and VirtualBox ARM boot profiles.
- [Deployment Guide](docs/DEPLOYMENT_GUIDE.md): prepare, validate, hand off,
  and roll back application, AI, package, and appliance deployment candidates.
- [Release Notes](docs/RELEASE_NOTES.md): shipped features, verification gates,
  known limits, and upgrade notes for the current checked-in snapshot.
- [Update And Rollback Guide](docs/UPDATE_GUIDE.md): rebuild immutable
  artifacts, update boot profiles, verify candidates, and roll back safely.
- [Update Store](docs/UPDATE_STORE.md): A/B update-store image layout, target
  commands, and rollback behavior.
- [User Guide](docs/USER_GUIDE.md): accounts, capabilities, filesystem,
  process tools, networking tools, and current system limits.
- [Administration Guide](docs/ADMINISTRATION_GUIDE.md): maintain accounts,
  capability masks, base configuration, package images, and services.
- [Command Reference](docs/COMMAND_REFERENCE.md): command syntax, examples,
  limits, and acceptance coverage for the current base image and package
  overlay.
- [Host Tool Reference](docs/HOST_TOOL_REFERENCE.md): host-side package,
  repository, ports catalog, static-host, hosted URL, base-image, and
  model-bundle tools.
- [Settings Guide](docs/SETTINGS_GUIDE.md): where each setting lives across the
  base image, `/data`, and `/tmp`, and how to change it when `/etc` is read-only.
- [Configuration Reference](docs/CONFIGURATION_REFERENCE.md): build variables,
  boot profiles, QEMU/test knobs, artifacts, and seeded guest defaults.
- [Testing Guide](docs/TESTING_GUIDE.md): choose focused gates, run the full
  suite, interpret failures, and add host or QEMU acceptance tests.
- [Operations Guide](docs/OPERATIONS_GUIDE.md): boot profiles, package overlays,
  network workflows, AI operation, logging evidence, and verification gates.
- [Networking Guide](docs/NETWORKING_GUIDE.md): virtio-net boot profiles,
  host forwarding, DNS, TCP/UDP, TLS, IPv6 smoke paths, and network tests.
- [Service Guide](docs/SERVICE_GUIDE.md): run, observe, test, and design
  SwiftOS services such as `httpd`, `llmd`, echo tools, and the C5a-C5f
  driver-service smoke.
- [AI Hosting Guide](docs/AI_HOSTING_GUIDE.md): run local TinyStories
  inference, serve completions over HTTP, and operate verified model bundles.
- [Performance And Sizing Guide](docs/PERFORMANCE_GUIDE.md): measure resource
  usage, throughput guards, service metrics, and current sizing limits.
- [Observability Guide](docs/OBSERVABILITY_GUIDE.md): read boot health,
  structured log markers, process snapshots, service metrics, and panic
  evidence.
- [Logging Reference](docs/LOGGING.md): understand kernel log lines, ring
  buffers, export samples, filtering, and log authority.
- [Troubleshooting](docs/TROUBLESHOOTING.md): build, boot, login, filesystem,
  network, package overlay, LLM, and QEMU test failure diagnosis.
- [Support Guide](docs/SUPPORT_GUIDE.md): evidence collection, support bundles,
  severity levels, report templates, and handoff checklists.
- [FAQ](docs/FAQ.md): common product, install, compatibility, package,
  networking, AI, and support questions.
- [Examples](docs/EXAMPLES.md): copy-paste workflows for common SwiftOS tasks.
- [Compatibility Guide](docs/COMPATIBILITY_GUIDE.md): supported platforms,
  application paths, porting constraints, packages, and non-goals.
- [Security Guide](docs/SECURITY_GUIDE.md): current login flow, capability
  bits, handle rights, confinement, immutable images, and security limits.
- [Base Image](docs/BASE_IMAGE.md): immutable packed filesystem contents,
  build inputs, and base-image verification.
- [Developer Guide](docs/DEVELOPER_GUIDE.md): write native Embedded Swift
  programs, port C/newlib programs, and stage binaries into the base image.
- [Porting Guide](docs/PORTING_GUIDE.md): evaluate and port source-built
  applications to the SwiftOS ABI, filesystem, package, and test model.
- [Application Cookbook](docs/APPLICATION_COOKBOOK.md): copy-paste recipes for
  SwiftOS commands, C utilities, package overlays, and tests.
- [Package Guide](docs/PACKAGE_GUIDE.md): build, inspect, boot, test, and
  troubleshoot `.swpkg`, repository, package-store, ports, static-host, and
  hosted URL artifacts.
- [Package Management](docs/PACKAGE_MANAGEMENT.md): package-system design,
  current implementation status, and roadmap boundaries.
- [Package Build Automation Guide](docs/PACKAGE_BUILD_AUTOMATION.md): package
  recipe, seed package fixtures, CI smoke-test, and repository publishing
  workflow for maintainers.
- [Package Ecosystem Goal](docs/PACKAGE_ECOSYSTEM_GOAL.md): end-state package
  ecosystem goals and current package roadmap.
- [Package Manager Implementation Plan](docs/PACKAGE_MANAGER_IMPLEMENTATION_PLAN.md):
  historical package-manager implementation plan.
- [Package Manager Session Prompts](docs/PACKAGE_MANAGER_SESSION_PROMPTS.md):
  reusable package-manager session and milestone prompts.
- [SWPKG Format](docs/SWPKG_FORMAT.md): `.swpkg` container layout, manifest,
  payload, and verification rules.
- [Package Store Format](docs/PKGSTORE_FORMAT.md): package-store image,
  activation record, and local install layout.
- [Static Package Repository](docs/PKGREPO_FORMAT.md): signed static HTTP
  catalog layout and repository install flow.
- [API Reference](docs/API_REFERENCE.md): API recipe index, syscall table,
  structure layouts, handle rights, native Swift bridge, and compatibility API
  notes.
- [Server Software Catalog](docs/SERVER_SOFTWARE_CATALOG.md): prioritized
  server packages, current package limits, and porting prerequisites.
- [Ports Seed Catalog](ports/README.md): seed ports catalog and recipe
  validation rules.
- [SMP Mutable State Audit](docs/SMP_STATE_AUDIT.md): machine-checked SMP
  mutable-state inventory.
- [Namespace Design](docs/NAMESPACE_DESIGN.md): recorded per-process namespace
  generalization (record-only design note).
- [OS Update Audit](docs/OS_UPDATE_AUDIT.md): Phase 0 design audit of the OS
  self-update (kernel + base image) surface.
- [Next Session](docs/NEXT_SESSION.md): current handoff notes for the next
  engineering session.
- [Hetzner Deployment](docs/HETZNER_DEPLOYMENT.md): bare-metal bring-up handoff
  for a Hetzner Cloud ARM (CAX) VM running SwiftOS as the actual OS.

## Architecture

```text
EL0  userland      native Swift coreutils + network tools; future Swift apps, Node.js, JVM (busybox: legacy bring-up)
      ----------   syscall boundary: swift-os POSIX-like ABI, not Linux ABI
EL1  kernel        Embedded Swift: runtime, mm, sched, vfs, drivers, net, security, tty
      arch/aarch64 boot (UEFI loader + direct -kernel fallback), exception vectors, context switch
```

Key architectural decisions:

- **Target:** `aarch64`, QEMU `virt` (primary), QEMU+AAVMF UEFI (primary boot path), VirtualBox ARM
  (best-effort). `make run` defaults to one CPU; SMP hardening has dedicated
  `-smp N` tests and readiness gates.
- **Boot:** UEFI (`BOOTAA64.EFI` on an ESP in a GPT disk image) is the primary path; direct `-kernel`
  is kept as a fallback.
- **Hardware discovery:** a boot-time DTB reader populates a global `Platform`; driver and PMM
  initialization read from it instead of hardcoded constants.
- **Kernel language:** Embedded Swift, freestanding, no Foundation, no full standard library.
- **Isolation:** real MMU-based process isolation, one address space per process.
- **Filesystem:** three-tier. A signed packed read-only base image (`SWOSBASE v3`) served off a
  virtio-blk device; a RAM tmpfs for writable scratch; and a persistent, `fsync`-durable `/data`
  tier (`datafs` on a dedicated virtio-blk disk) for state that must survive reboot. No FS
  journaling — crash-safety relies on honest `fsync` plus the application's own journaling.
- **Security:** capability/principal model. `/etc/swos/passwd` is the identity source; `/etc/passwd`
  is a generated compatibility view for busybox/newlib only.
- **ABI:** a small swift-os syscall surface, POSIX-like where useful, explicitly not the Linux
  syscall ABI.
- **Linking:** static userland only; no dynamic loader.
- **Network:** in-kernel, virtio-net, sans-IO pure-Swift protocol core; capability-gated socket ABI.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for subsystem boundaries, driver strategy,
long-horizon runtime constraints, and explicit non-goals. See
[docs/SWIFTCUBE_DESIGN.md](docs/SWIFTCUBE_DESIGN.md) for the recorded SwiftCube design — a
record-only note for a Swift-native cluster orchestrator that schedules applications as Cells.

## Repository Map

```text
boot/
  efi/            UEFI loader (AArch64 PE32+): loader.c, efi.h, kernel_blob.S
kernel/
  arch/aarch64/   boot.S, exception vectors, context switch, linker script, FDT reader, platform
  crypto/         ChaCha20-Poly1305 AEAD (TLS groundwork)
  drivers/        PL011 UART, GICv2, virtio-blk, virtio-net, virtio-input, framebuffer
  mm/             physical page allocator (PMM), virtual memory / address space management
  net/            sans-IO Ethernet/ARP/IPv4/ICMP/UDP/TCP/DNS core; socket layer
  runtime/        freestanding runtime support for Embedded Swift
  sched/          preemptive process/thread scheduler, futex
  security/       process security context, principal/capability model
  signal/         signal delivery, pending mask
  syscall/        syscall dispatch
  timer/          ARM generic timer, PL031 RTC
  tty/            line discipline, termios, canonical/raw mode
  user/           ELF loader, process/thread lifecycle, exec
  vfs/            VFS (disk-backed base + tmpfs), fcntl, capability enforcement
userland/
  lib/            swift_user bridge (svc ABI, allocator, atomic ops, putchar),
                  crt0, newlib syscall stubs, compat headers
  compat/         POSIX/Linux shim headers and stubs for busybox/newlib cross-build
  busybox/        busybox 1.38.0 build config
  *.swift         native Swift EL0 utilities: ls cat echo pwd ps top id mkdir rmdir
                  rm mv chmod chown head touch wc date calc kv nslookup udpecho
                  tcpecho tcpget httpd console-login threadsdemo …
  hello.c         original bring-up C program (kept for reference)
base/             host seed tree for the packed base image (etc, www, …)
tools/
  basepack.swift  host-side packed base image packer
scripts/          build-busybox.sh, build-newlib.sh, make-disk.sh, …
tests/            host unit tests (Swift) + QEMU boot assertion scripts (bash)
docs/             philosophy, architecture, package ecosystem, hardware/toolchain notes
```

## Build And Run

The default tool paths are pinned for the current macOS Apple Silicon bring-up
environment in [docs/NOTES.md](docs/NOTES.md). They can be overridden from
`make` if your local installation differs.

Prerequisites (run once):

```sh
make newlib    # cross-build newlib 4.6.0 into ./sysroot
make busybox   # cross-build busybox 1.38.0
```

Then:

```sh
make tools-check
make build
make run       # direct -kernel boot with base.img attached
```

UEFI boot (primary path):

```sh
make disk      # build BOOTAA64.EFI + GPT disk image (build/swift-os.img)
make disk-run  # boot under QEMU+AAVMF from the GPT disk
```

Other useful targets:

```sh
make test      # full test suite: host unit tests + QEMU boot assertions
               # (both -kernel and UEFI/disk paths are tested)
make uefi-run  # UEFI boot from a QEMU virtual FAT directory (quick, no GPT)
make debug     # boot QEMU paused with a gdbstub on :1234
make gdb       # attach aarch64-elf-gdb to the paused kernel
make base-image  # pack build/base.img from base/ + staged userland ELFs
make clean
```

`make run` starts:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=<dtb>,addr=...,force-raw=on \
  -drive file=build/base.img,...,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -kernel build/kernel.elf
```

`make disk-run` starts:

```sh
qemu-system-aarch64 -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic \
  -bios <AAVMF_CODE> \
  -drive file=build/swift-os.img,format=raw,if=virtio \
  <base.img as second virtio-blk>
```

Exit QEMU serial with `Ctrl-A X`.

## Toolchain Notes

The current pinned target is:

```text
aarch64-none-none-elf
```

The kernel is built with a swift.org Embedded Swift toolchain, LLVM `clang`,
`ld.lld`, `llvm-objcopy`, and QEMU. Exact versions and the rationale for the
current flags live in [docs/NOTES.md](docs/NOTES.md); do not guess or cargo-cult
Embedded Swift flags across toolchain versions.

## Roadmap

Work is organized in phases. Each milestone must remain buildable, bootable,
tested, and reviewable before moving on.

### Phase 0 — bring-up (done, historical)

The bring-up arc proved the kernel and syscall surface end to end. busybox was
the bring-up userland (a legacy tool); the native Swift userland is now the
direction.

- **M0:** boot skeleton and UART output. **Done.**
- **M1:** runtime hooks, exception vectors, heap, page allocator. **Done.**
- **M2:** GIC and timer interrupts. **Done.**
- **M3:** virtual memory and MMU. **Done.**
- **M4:** processes, scheduling, EL0 trap path. **Done.**
- **M5:** syscall entry and VFS skeleton. **Done.**
- **M6:** libc subset, ELF64 loader, spawn. **Done.**
- **M7:** TTY, termios, signals. **Done.**
- **M8:** static busybox `sh` with `ls`, `cat`, and `echo`. **Done.**
- **M9:** HAL + runtime hardware discovery from DTB. **Done.**
- **M10 (a/b/c):** UEFI boot from a GPT disk image under QEMU+AAVMF. **Done.**
- **M10.5:** VirtualBox ARM validation prep. **Done (prep only; manual run needed).**
- **M11 (a–d):** virtio-blk driver, packed `SWOSBASE` format + host packer,
  base FS served read-only from disk, disk-first executable lookup, embedded
  kernel blob removed. **Done.**
- **M12 (a–d):** capability/principal security core, identity store,
  console-login as init, SHA-256 password hashing. **Done.**
- **M13 (a–c):** VFS capability enforcement at open time, tmpfs mutation gating,
  file ownership + `ls -l`. **Done.**
- **Post-M13 follow-ups:** shell I/O redirection + `fcntl`; native Swift
  userland coreutils (`ls cat echo pwd ps top id mkdir rmdir rm mv chmod chown
  head touch wc date calc kv …`); busybox `vi`; PL031 RTC + per-file mtime;
  free-capable allocator for Swift ARC; threading (`thread_create` + `futex`);
  process teardown frame reclaim. **Done.**
- **N-series (networking):** virtio-net driver, sans-IO Ethernet/ARP/IPv4/ICMP/
  UDP/TCP/DNS core, capability-gated socket syscalls, `/bin/udpecho`,
  `/bin/tcpecho`, `/bin/tcpget`, `/bin/httpd` (concurrent poll-driven static-file
  HTTP server), `/bin/nslookup`, DNS resolver, TCP robustness + ephemeral-port
  allocator, ChaCha20-Poly1305 AEAD (TLS groundwork). **Done.**

### Phase 1 — hardening for the product profile (active)

The dedicated plan lives in `docs/RISK_REMEDIATION_ROADMAP.md`. It completes the
capability/handle model (C-arc), treats **SMP** as a required deliverable (S0–S5
series), moves drivers and the network stack toward the documented restartable
userland service model, and makes global kernel state concurrent-safe. Each
sub-milestone follows the strict rule: builds, boots (including `-smp N`), has
tests, is committed, then review. SMP and "restartable services" are tracked
work, not non-goals; C5a-C5f now prove the supervisor/service IPC shape,
virtio-input discovery metadata, fallback pseudo-device discovery, surfaced
virtio-mmio metadata, opaque device-handle transfer, withheld hardware
authority, and metadata-only grant rights before real device handoff lands.

### Phase 2 — full-OS capabilities (forward, record-don't-build-yet)

Toward a complete hosting/embedded OS: richer observability and metrics;
production update channels beyond the checked A/B validation paths; kernel-slot
health confirmation; the native Swift application runtime plus
Node.js and JVM hosting; the embedded footprint profile (small static image,
deterministic boot, fewer services); TLS 1.3 record layer and handshake; Cells
(kernel-native capability-based isolated execution domains); and a
hot-update-friendly kernel structure. Recorded, not implemented early.

## Non-Goals (minimalism by removing legacy)

These boundaries are deliberate. They are how the OS stays minimal — it removes
legacy surface rather than carrying it. They are not constraints on the
hosting/embedded/desktop profiles, which the same core already serves; they
constrain *how* it serves them.

- Linux ABI compatibility;
- dynamic linking;
- amd64/x86-64 support;
- full Cells isolation (the architecture is designed for it; the implementation
  is future work — see `docs/ARCHITECTURE.md` and `docs/CAPABILITIES.md`);
- Docker/OCI compatibility;
- journaling or persistent writable filesystem guarantees;
- broad loadable kernel-module ABI;
- GPU/NPU acceleration;
- graphics as the *primary* display path (a basic VT100 framebuffer console +
  virtio-input keyboard exist for QEMU graphical mode; desktop use is not
  excluded, but a rich display stack is Phase 2 work, not a current target).

(See the risk remediation roadmap for the current status of SMP and restartable
driver services — they are no longer blanket non-goals.)

**SMP is a delivered capability, not a non-goal.** The S0–S5 series in
`docs/RISK_REMEDIATION_ROADMAP.md` brought up per-CPU scheduling, cross-CPU TLB shootdown, and
spinlock-protected kernel state; the system boots and runs the existing workloads at `-smp N`
(tested at `-smp 4`). `make run` still defaults to one CPU for speed. Phase 1 continues with
completing the handle-based capability model and moving drivers toward restartable userland services.

Networking is **not** a non-goal: a TCP/UDP/ARP/ICMP/DNS stack and a set of
userland network tools are present and tested. The long-term target (userland network
service reachable only via capability-gated IPC, after the C-arc + basic SMP) is recorded
in the risk remediation roadmap. What remains future work today is TLS in userland,
high-pps optimizations, and the actual service-ization.

These boundaries are not accidental omissions. They keep the kernel surface
small enough to measure, test, and trust.

## License

swift-os is licensed under the **Apache License, Version 2.0** — see
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). New source files we author carry an
`// SPDX-License-Identifier: Apache-2.0` header.

Bundled third-party components keep their own licenses and are **not** covered by
the Apache license above: `userland/busybox` (GPL-2.0-only) and `libc/newlib`
(BSD-style / permissive). See `NOTICE` for details.

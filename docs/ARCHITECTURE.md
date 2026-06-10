# ARCHITECTURE

How swift-os is structured, and how the long-horizon goals shape early decisions.

## Layers

```
EL0  userland      native Swift coreutils + net tools · (future) Swift apps, Node.js, JVM · busybox (legacy bring-up)
      ───────────  syscall boundary (SVC) — our own POSIX-like ABI, NOT Linux
EL1  kernel        Embedded Swift: runtime · mm · sched · vfs · drivers
      arch/aarch64 boot stub (asm) · exception vectors · context switch
```

## Architecture support policy

swift-os is an **aarch64-first** operating system. The current implementation target is QEMU `virt` on
aarch64 only (with a UEFI+GPT disk boot path).

Rationale:

- aarch64 `virt` has a cleaner early boot path than legacy PC platforms;
- the project prioritizes fast boot, low complexity, and modern interfaces over broad hardware coverage;
- early amd64 support would force extra work around PC firmware, ACPI, APIC/xAPIC/x2APIC, legacy interrupt
  paths, and platform variation before the kernel has proven its core model;
- focusing one architecture keeps tests, documentation, and milestone acceptance criteria sharp.

The kernel should still keep architecture-specific code behind `arch/<target>/` boundaries, and generic
subsystems should not bake in aarch64 details unnecessarily. However, amd64/x86-64 is not a supported target.
It may be reconsidered once the Phase 1 hardening arc (capabilities + SMP + service-ization) is stable, since
the syscall model, VFS, scheduler, process model, and driver strategy are still in flux there.

## Kernel module map (`kernel/`)

- `arch/aarch64/` — boot stub, exception vector table, context switch, low-level CPU/MMU helpers (asm + Swift).
- `runtime/` — Embedded Swift runtime hooks (allocation, ARC support), `print`/log over UART.
- `mm/` — physical page allocator, kernel heap, virtual memory (translation tables, map/unmap).
- `sched/` — process/thread abstraction, context switching, preemptive round-robin scheduler.
- `vfs/` — vnode abstraction, read-only packed base FS, RAM tmpfs.
- `drivers/` — PL011 UART, GIC, virtio-mmio, timer.

## Swift protocol use

Protocols are part of the intended kernel architecture. Use them to describe small, capability-shaped
interfaces where the concrete type is known at compile time:

- driver capabilities: `SerialPort`, `BlockDevice`, `InterruptController`, `TimerSource`;
- filesystem capabilities: read-only image readers, tmpfs backends, directory emitters, inode allocators;
- HAL boundaries and host-test doubles for code that should not depend directly on QEMU `virt` constants.

Preferred shape:

```swift
protocol BlockDevice {
    mutating func readSector(_ lba: UInt64, into buffer: UnsafeMutableRawPointer) -> Int
}

func loadHeader<D: BlockDevice>(_ device: inout D) -> Int {
    // Statically dispatched under Embedded Swift.
    device.readSector(0, into: headerBuffer)
}
```

Avoid storing kernel objects as `any Protocol` unless the Embedded Swift toolchain and runtime costs have been
explicitly re-evaluated. Early kernel polymorphism should be visible in the data structure: an enum tag, a
fixed operation table, a vnode kind, or a handle registry. That keeps boot-critical drivers and the VFS easy to
reason about while still letting protocol constraints make generic helpers and tests type-safe.

## Driver loading model

swift-os uses a hybrid driver model:

- **Static in-kernel drivers for the boot-critical path.** The UART console, interrupt controller, timer,
  MMU/DMA substrate, minimal bus support, and any storage driver required to reach the initial userland are
  built into the kernel. These drivers must be small, deterministic, and easy to audit.
- **Restartable userland driver services for everything that can be isolated.** Non-critical and advanced
  drivers should run as supervised processes or cells with explicit device capabilities instead of being
  loaded into the kernel address space.
- **Kernel modules are not the default architecture.** Loadable in-kernel code may exist later as a tightly
  controlled escape hatch for architecture glue or experiments, but swift-os should not grow a broad,
  unstable kernel-module ABI as its primary driver mechanism.

Future driver service loading flow:

1. The kernel discovers a device from DTB, virtio-mmio, or another supported bus.
2. The device registry creates a typed `Device` object.
3. A driver manager matches the device against a manifest in the read-only base image.
4. The kernel grants only the required capabilities: MMIO ranges, IRQ endpoint, DMA/shared-memory windows,
   device ownership, logging, and supervision handles.
5. The driver service is spawned.
6. The driver registers readiness.
7. Clients communicate with it through handle-based IPC.

Current implementation slice: C5a-C5d ships a restartable driver-service
harness and device-discovery smoke, but not real hardware handoff.
`/bin/drvsvcdemo` supervises `/bin/drvinputd`, discovers the metadata-only
`virtio-input.0` registry entry when QEMU exposes a `virtio-keyboard-device`,
surfaces that transport's MMIO base and length as non-authoritative discovery
metadata, falls back to `pseudo-input.0` in headless boots, claims an opaque
grant, transfers that handle over endpoint IPC, observes the busy claim, and
reclaims the device after service exit. MMIO-range handles, IRQ endpoints, DMA
windows, and real virtio-input queue ownership remain future work.

This model supports fast boot, explicit security boundaries, driver restart, and future hot driver updates
without making arbitrary binary code part of the permanent kernel ABI.

## Design principles for performance

- **Value-type-first.** Prefer `struct` / `~Copyable` with `deinit` over classes to avoid ARC traffic on hot paths.
- **Zero-cost ownership.** Use move-only types for resources (page frames, locks, fds) so lifetimes are static.
- **Allocator design.** Buddy/bitmap physical allocator + a slab-style kernel heap for fixed-size objects;
  minimize per-alloc overhead and fragmentation. Page-granular, cache-line aware.
- **Scheduler.** O(1) round-robin to start; keep the hook points clean for a later priority/CFS-like policy.
- **No journaling FS.** RAM tmpfs writes are pointer bumps; the read-only base is mmap-friendly packed data.
- **Fast boot is a feature.** The kernel should reach the first user process as quickly as possible. Prefer
  minimal early initialization, deterministic device discovery, lazy service startup, and measured boot-time
  budgets over broad "initialize everything before init" designs.

## Filesystem and update storage model

swift-os uses specialized filesystems instead of a single general-purpose mutable disk filesystem.

Runtime layout:

```
active read-only base FS
  + RAM tmpfs scratch
  + VFS namespace
```

Update layout:

```
persistent update store
  + signed immutable image slots
  + signed patch bundles
  + atomic boot manifest
```

The active root is never modified in place. Normal system updates are staged as complete immutable images or
bundles in an inactive slot, verified, and then selected atomically through a small boot manifest. Rollback is
performed by selecting the previous known-good slot.

### Read-only base FS

The base filesystem should be a custom packed image optimized for swift-os:

- read-only and immutable while mounted;
- deterministic image layout;
- packed metadata and file data;
- extent-based reads;
- precomputed directory metadata;
- mmap- and page-cache-friendly data placement;
- shareable across future cells;
- no free-space management;
- no journaling or crash-recovery machinery;
- built by a host-side image tool and parsed by small kernel/VFS code.

The base FS exists to hold `/bin`, `/etc`, service manifests, driver manifests, identity policy, and other
boot/runtime files that should be versioned with the system image. It is not a mutable user data store.

### tmpfs scratch

Writable runtime state lives in tmpfs:

- `/tmp`;
- shell temporary files;
- logs and transient service state;
- per-cell private scratch later.

tmpfs is intentionally ephemeral. Data loss on reboot is acceptable by design.

### Persistent update store

Self-update requires persistence, but it does not require a traditional mutable root filesystem. The persistent
update store is a narrow storage layer for whole-system images, kernel images, driver/service bundles, patch
bundles, and boot manifests.

Expected structure:

```text
slot A:
  kernel image
  base FS image
  manifest.toml

slot B:
  kernel image
  base FS image
  manifest.toml

boot manifest:
  active slot
  fallback slot
  generation
  verified boot state
```

Normal update flow:

1. Receive or build an update bundle.
2. Verify signatures and hashes.
3. Write the new kernel/base images to an inactive slot.
4. Verify the written slot.
5. Atomically update the boot manifest.
6. Boot, reboot, or perform a future kernel handoff into the new generation.
7. Roll back to the previous slot if the new generation fails its health checks.

Live kernel patches are stored as signed patch bundles targeted to a specific kernel version or hash. The
filesystem stores and verifies those bundles; the kernel patch manager decides whether they are safe to apply
at a quiescent point. Full kernel handoff uses staged kernel images from the update store, but the state
transfer mechanism is a kernel responsibility, not a filesystem feature.

Explicit non-goals for the bring-up filesystem:

- ext2/ext4/FAT/UFS/ZFS compatibility;
- a general persistent writable POSIX filesystem;
- journaling;
- fsck;
- POSIX ACLs and extended attributes;
- mutable root updates;
- making `/etc/passwd` or other compatibility files the source of security policy.

## Boot-time requirements

> **Decision (2026-06-04):** after M8, the boot path gains a UEFI route so the OS can boot from a real
> disk image under firmware (target: VirtualBox ARM on Apple Silicon, validated on QEMU+AAVMF), while
> staying aarch64-only — amd64 remains a non-goal. The `-kernel` direct-boot path stays as a fallback.
> Runtime hardware discovery (device tree, then UEFI config tables) replaces hardcoded constants
> starting at M9. See the M9–M13 roadmap in `docs/NOTES.md`.

Boot speed is a primary system quality, not a cosmetic optimization. Each milestone should avoid adding
unbounded work to the path between kernel entry and the first runnable user process.

Design rules:

- initialize only the CPU, memory, interrupt, timer, console, and storage pieces required for the current
  boot target;
- defer optional drivers, services, filesystem scans, diagnostics, and policy setup until after the first
  user process can run;
- prefer packed, precomputed, sequentially readable metadata for boot-critical images;
- avoid probing loops with long timeouts on the normal QEMU `virt` path;
- record boot progress with cheap timestamped tracepoints once the timer exists;
- keep boot tests strict enough to catch accidental slowdowns.

## Initialization model

Initialization is staged and deterministic. The early boot path should be a short sequence of kernel-owned
steps that reaches the first user process quickly, without a large service manager or broad driver probing
blocking progress.

Bring-up flow:

```
QEMU -kernel
  -> arch entry
  -> early kernel
  -> memory isolation
  -> interrupts and timer
  -> scheduler and process substrate
  -> VFS/base image/tmpfs
  -> default cell/session
  -> first user process
```

Stage responsibilities:

- **Arch entry.** Enter EL1, set the stack, clear BSS, establish the minimal CPU state, and call the Swift
  kernel entry point.
- **Early kernel.** Bring up UART logging, panic output, exception vectors, early heap/runtime hooks, and the
  physical page allocator.
- **Memory isolation.** Build translation tables, enable the MMU, install kernel/device mappings, and expose
  the page map/unmap primitives needed by user processes.
- **Interrupts and timer.** Initialize the GIC and generic timer, then enable the system tick and preemption
  hooks.
- **Scheduler and process substrate.** Create kernel thread/process structures, establish EL0 entry/return,
  and enable the SVC/syscall path.
- **VFS/base image/tmpfs.** Mount the read-only base image, mount tmpfs scratch, and prepare the initial
  namespace.
- **Default cell/session.** Create the default/global cell and boot session, then grant only the capabilities
  needed for the first shell or init process.
- **First user process.** Today this is `/bin/console-login` (init), which authenticates a principal and
  `execve`s the shell with the adopted context in the default cell. Later it should become a small
  `/sbin/init` supervisor.

`/sbin/init` should remain small. It is not a systemd-style orchestration layer and should not become part of
the boot-critical kernel path. Its long-term responsibilities are:

- start essential userland services after the kernel can already run a user process;
- supervise restartable driver services;
- create console/login sessions;
- reap orphaned processes;
- report service and boot state through the observability model.

Services that are not required for the first interactive shell or declared boot target should start lazily or
under supervisor control after boot. Init receives capabilities like any other process; it does not get a
special all-powerful root identity.

## Configuration format guidance

swift-os should have one preferred human-authored configuration style, but this is guidance rather than a
hard rule for every application. The preferred format for OS-owned configuration is a **small TOML subset**.

Rationale:

- TOML is readable for humans and maps cleanly to typed data;
- it has less surprising implicit typing than YAML;
- it does not require anchors, aliases, custom tags, or indentation-sensitive object graphs;
- a strict subset can be parsed by small, auditable code;
- tables and arrays are enough for services, drivers, cells, identity policy, and boot profiles.

YAML is not the preferred system configuration format. It may be accepted by user applications, but swift-os
should not require a broad YAML parser in the trusted base or boot-critical path.

Guidelines:

- use `.toml` for human-authored OS configuration in the immutable base image;
- keep schemas explicit, versioned, and validated before use;
- prefer arrays of strings for capabilities and handles until richer typed manifests are needed;
- reject unknown required fields and invalid types loudly;
- do not parse OS configuration in the kernel unless it is unavoidable;
- compile or precompute boot-critical configuration into compact manifests when boot speed matters;
- use generated compatibility files only at the edges, such as `/etc/passwd` or `/etc/group` views.

Example style:

```toml
[service.console]
binary = "/sbin/console-login"
cell = "default"
capabilities = [
  "console:stdio",
  "fs:read:/",
  "fs:write:/tmp",
  "process:spawn",
]
restart = "on-failure"

[cell.default]
root = "base:/"
scratch = "tmpfs:/tmp"
memory_limit = "256M"
process_limit = 64
```

## Historical ideas worth stealing (record, don't build yet)

swift-os deliberately avoids legacy ABIs and compatibility traps, but old research and workstation/server
operating systems contain ideas that are modern again when stripped down and rebuilt around today's goals.
These ideas guide interfaces and data model choices, but they do not expand the M0-M8 implementation scope.

- **Solaris-style observability.** Build toward lightweight kernel counters, tracepoints, structured event
  buffers, and per-process/per-cell/per-driver accounting. The goal is not full DTrace early on; the goal is
  to keep the kernel explainable and measurable from the beginning.
- **Capability-based security.** Prefer explicit handles and rights over ambient authority. A POSIX-like
  surface can exist for porting, but kernel decisions should be based on capabilities such as file, device,
  IPC, clock, process, and network rights.
- **Typed kernel objects.** Use Swift's type system to keep kernel state explicit: `ProcessId`, `ThreadId`,
  `CellId`, `VmObject`, `FileHandle`, `DriverHandle`, `Capability`, and similar strong types. The syscall ABI
  may use integers, but the kernel should not devolve into untyped integer plumbing.
- **Per-process and per-cell namespaces.** Borrow the Plan 9/Solaris idea that a namespace is contextual,
  not one global truth. VFS lookup should eventually be rooted in the current process/cell context.
- **Mmap-friendly immutable storage.** Borrow the SGI/XFS instinct for locality and extent-oriented layout,
  without inheriting XFS complexity or journaling. The read-only base image should be packed, cache-friendly,
  shareable across cells, and friendly to zero-copy or mmap-backed reads.
- **Process contracts and supervision.** Borrow Solaris' notion that process lifecycle is a managed object,
  not only scattered `waitpid` state. Future process groups/jobs/contracts should support kill, wait,
  accounting, and restart supervision.
- **Resource controls.** Track memory, process count, file descriptor count, CPU time, and later I/O budgets.
  Accounting comes first; enforcement can follow once cells exist.
- **Fast local IPC.** Borrow from Solaris doors and QNX message passing: handle-based local RPC, shared memory
  pages, and a wake primitive. Keep it simple enough to use for driver services, logging, supervision, and
  future language runtime helpers.

## Reliability and control-plane model (record, don't build yet)

swift-os should borrow reliability discipline from mainframes, older operational systems, and spacecraft
software without inheriting their heavyweight process or legacy interfaces. The goal is explicit recovery
paths, not heroic debugging after an opaque failure.

Ideas to keep:

- **Controlled boot profiles.** Support explicit boot modes such as `normal`, `previous-good`, `safe`,
  `diagnostics`, and `recovery`. These profiles should select a boot slot, service set, and capability policy.
- **Safe mode.** Maintain a minimal configuration that should almost always boot: kernel, console, read-only
  base image, tmpfs, diagnostics shell, and no optional services.
- **A/B image discipline.** Treat the active system as one generation among signed slots. New generations must
  be verified before activation and confirmed healthy before the fallback slot is retired.
- **FDIR.** Build toward fault detection, isolation, and recovery: detect failed components, isolate the failed
  driver/service/cell, and recover through restart, rollback, or safe-mode transition.
- **Health states.** Critical objects should eventually expose lifecycle and health such as `starting`, `ready`,
  `degraded`, `failed`, `restarting`, and `stopped`.
- **Watchdogs with policy.** Use watchdogs for the kernel, init/supervisor, driver services, and cells, but tie
  each watchdog to an explicit recovery policy instead of blindly resetting the whole system.
- **Operator console.** Provide a small control plane for status, boot slots, cells, services, drivers, health,
  and recent events. This is separate from an interactive Unix shell.
- **Jobs/contracts.** Represent supervised work as jobs or contracts with processes, capabilities, resource
  limits, logs, health, and restart policy.
- **Command/telemetry split.** Keep control commands separate from telemetry streams. Commands change state;
  telemetry reports counters, events, logs, and health.
- **Typed update objects.** Treat kernel images, base images, patch bundles, driver bundles, manifests, and
  boot profiles as versioned, signed system objects instead of arbitrary mutable files.

Design constraints:

- every critical component should have a health state;
- every restartable component should have a supervisor;
- every update should have rollback;
- every boot path should have a safe-mode fallback;
- every resource boundary should have accounting;
- every privileged control action should require explicit authority;
- every failure path should be testable.

Things not to copy:

- heavyweight mainframe management stacks;
- batch-only operation models;
- JCL-like configuration languages;
- broad transactionality in every subsystem;
- triple modular redundancy as the default software model;
- certification bureaucracy in place of clear design and executable tests.

## Syscall ABI

Our own POSIX-like surface (NOT Linux ABI). SVC entry → dispatch table. Kept deliberately small at first
(`open/read/write/close/lseek/stat/fstat/getdents/chdir/getcwd`, then process/signal calls), but the *shape*
(fd-based I/O, `mmap`, threads, futex-like primitive) is chosen so the long-horizon runtimes can be ported.

The long-term syscall shape should prefer `spawn` and explicit inherited handles over making `fork` the
central process primitive. `fork` may be emulated or partially supported for compatibility with selected
ports, but swift-os should not make copy-on-write Unix process cloning the foundation of its design.

## Future isolation model: Cells (record, don't build yet)

swift-os will eventually use kernel-native, capability-based **Cells**: lightweight isolated execution domains
inspired by FreeBSD jails and Solaris zones, but designed around immutable base images, private tmpfs scratch,
explicit capabilities, resource accounting, and direct kernel lifecycle management.

See [CAPABILITIES.md](CAPABILITIES.md) for the handle/capability ABI and the Cell-as-composition decision.

Cells are not Docker compatibility. They do not depend on Linux namespaces, cgroups, overlayfs, privileged
containers, or a container daemon. Docker is an ecosystem and packaging model; Cells are an operating-system
security and resource boundary.

A cell owns or references:

- a group of processes and threads;
- a VFS namespace and root view;
- a read-only base image plus private tmpfs scratch;
- explicit device, file, IPC, clock, process, and later network capabilities;
- resource accounting and limits;
- lifecycle state (`created`, `running`, `stopping`, `dead`);
- observability counters and event streams.

Initial implementation constraints:

- M0-M8 run in a single default/global cell.
- M4 process structures should leave room for a `CellId` or security context.
- M5 VFS lookup should be designed around process/cell `root` and `cwd`, not global path state.
- M6 process launch should be shaped like `spawn(image, argv, env, inheritedHandles, limits)`.
- M7 signals, process groups, and terminal control should be cell-aware once multiple cells exist.
- the bring-up userland runs inside the default cell; full cells remain future work.

Explicitly postponed beyond bring-up (future cells / Phase 2 work): network isolation, OCI image
compatibility, image registries, overlay layers, seccomp-like policy VMs, multi-user accounting, nested cells,
live migration, and SMP-aware resource scheduling.

## Identity and login model

> **Decision (2026-06-04):** this capability/principal model is the chosen path for the post-M8 login
> milestone (M12). Traditional Unix `uid==0` authority was explicitly rejected; `/etc/passwd`/`/etc/group`
> are generated compatibility views only. See the M9–M13 roadmap in `docs/NOTES.md`.

swift-os should not build its security architecture around Unix `/etc/passwd`, `/etc/group`, numeric UIDs,
or a privileged `root` identity. Those concepts may be exposed later as compatibility views for ported tools,
but they are not the source of authority inside the kernel.

The long-term login model is:

```
principal -> session -> cell -> process tree -> explicit capabilities
```

A successful login or service launch should:

1. authenticate or otherwise identify a principal;
2. create a session object;
3. create or select a cell;
4. attach a namespace and root view;
5. grant explicit capabilities and inherited handles;
6. apply resource limits;
7. spawn the requested shell, service, or application.

Kernel authorization should be based on explicit capabilities and object ownership, not checks such as
`uid == 0`. Example capability categories include filesystem rights, console/TTY access, process spawning,
cell management, clock access, IPC endpoints, and later network rights.

The implemented model (M12/M13):

- `/bin/console-login` is init: it authenticates a principal against `/etc/swos/passwd` (SHA-256-hashed
  passwords), adopts its principal/session/capabilities via `SYS_LOGIN`, and `execve`s the shell.
- `/etc/passwd` and `/etc/group` are generated compatibility views (for tools that expect them), not the
  security policy.
- Still future work: roles, policy files, richer multi-session management, and a stronger password KDF.

Future identity data should live in a simple structured store in the immutable base image, with writable
session state in tmpfs or a dedicated service. Compatibility files such as `/etc/passwd` should be generated
from that store when needed, not treated as kernel security policy.

## Product profiles

swift-os serves three profiles from one minimalist core. They differ in which optional services and devices
are present, not in the kernel.

- **Application & AI hosting (flagship).** Isolated serving cells, fast boot, strong observability, explicit
  resource accounting, and hot reload — detailed below.
- **Embedded / appliance (co-primary).** A single-purpose deployment of the same core: a small static base
  image, deterministic fast boot, an immutable signed base + A/B updates with rollback, capability-confined
  drivers, predictable memory (no hidden allocation on hot paths), and only the services the appliance needs.
  Most hosting requirements (small TCB, immutable images, capability isolation, fast boot) are exactly the
  embedded requirements, so the two profiles share almost all of the roadmap.
- **Desktop (not excluded).** A basic VT100 framebuffer console + virtio-input keyboard already exist for
  QEMU graphical mode. Desktop use is not a goal we design *against*, but a rich display/input stack is Phase 2
  work, not a current target; serial/headless remains the primary path.

### Flagship hosting model (important; record, don't build yet)

The target is not to become a general Linux-compatible CUDA host early on. The target is a small, immutable,
capability-based hosting/inference appliance OS: model and application bundles, isolated serving cells, fast
boot, strong observability, hot reload, and explicit resource accounting.

The practical first AI target should be CPU-only inference:

```text
static llama.cpp-style server
GGUF-like model files
mmap-backed weights
HTTP or local RPC serving
one model server per cell
```

GPU/NPU acceleration is future work and depends on a mature device model, DMA safety, and accelerator drivers.
CUDA/ROCm compatibility should not be assumed as a core OS goal.

Required primitives to keep on the roadmap:

- large `mmap` support for model weights;
- huge pages or large mappings for model memory and runtime heaps;
- efficient page cache behavior for immutable model bundles;
- threads and futex-like synchronization;
- event/poll syscalls for serving loops;
- TLS and fast timers;
- W^X and executable mappings for JIT-capable runtimes;
- memory pressure reporting and admission control hooks.

Model storage should use signed immutable bundles:

```text
/models/<name>/<generation>/
  manifest.toml
  config
  tokenizer
  weights
  checksums
```

Model bundles should support atomic activation, health confirmation, rollback, and hot reload:

1. Stage model generation B.
2. Verify signatures and hashes.
3. Start or warm a new serving cell.
4. Route new requests to B.
5. Drain generation A.
6. Unmap A when no longer in use.
7. Roll back if B is unhealthy.

Serving isolation should use cells and explicit capabilities:

```text
cell: model-llama-7b
  caps:
    fs:read:/models/llama-7b
    net:listen:tcp:8080
    clock:read
    process:spawn
    accel:use:gpu0      # future
  limits:
    memory
    threads
    file descriptors
    accelerator quota   # future
```

Accelerator support should be designed as explicit device authority, not ambient access to all GPUs:

- DMA-safe buffers;
- pinned memory tracking;
- IOMMU support when available;
- command queues;
- userland accelerator driver services where practical;
- accelerator capabilities such as `accel:use`, `accel:memory`, and `accel:queue`.

AI-hosting requires networking — much of which now exists (virtio-net driver, sans-IO TCP/IP stack,
capability-gated sockets, a poll()-driven HTTP server). The remaining pieces are Phase 1/2 work:

- virtio-net or another minimal NIC path; **(done)**
- TCP/IP stack; **(done — in-kernel today, service-ization is Phase 1)**
- async accept/read/write; **(done via `poll()`)**
- backpressure;
- graceful reload and drain;
- TLS in userland;
- metrics and health endpoints.

Observability should include AI-serving metrics:

- request counts;
- latency percentiles;
- tokens/sec or equivalent throughput;
- model load and warmup time;
- mmap/page-cache behavior;
- memory pressure and OOM events;
- cell restarts;
- accelerator errors and utilization when accelerators exist.

Hosting build-out priority order (Phase 1/2):

1. CPU-only static inference server with mmap-backed model files.
2. Network serving and metrics.
3. One model server per cell with resource limits.
4. Hot model reload and rollback.
5. Accelerator service model.
6. GPU/NPU backend drivers.

## Future network stack model (record, don't build yet)

swift-os will need TCP/IP to host server and AI workloads (see the AI-hosting and metrics sections
above). The implementation strategy is decided, but no networking code is built during the M9–M13 arc;
networking is the next major arc only after identity/permissions land.

**Decision: write our own stack in Embedded Swift. Do NOT fork the FreeBSD in-kernel stack.** netgraph
is taken as *design inspiration* (a graph of typed nodes connected by hooks), not as code.

Why not fork FreeBSD's stack:

- it is not a separable module — it is fused to `mbuf`/`uma(9)`, SMP locking (`mtx`, `rwlock`,
  `NET_EPOCH`), `kobj`, `sysctl`, `callout`, kernel threads, and the socket↔VFS layer; compiling
  `tcp_input.c` effectively pulls in the FreeBSD kernel;
- it assumes SMP and decades of RCU-style concurrency we deliberately do not have (single core at the
  start) and cannot remove without rewriting the stack;
- it is C with large global mutable state, which defeats our Swift value-type / `~Copyable` /
  capability ownership model — "kernel in Swift" would become a fiction;
- it carries legacy ABI/options weight, conflicting with priority #1 (modern over legacy).

Architecture (matches restartable driver services + capabilities already in this doc):

- **virtio-net as a driver service**, not in the kernel — MMIO range, IRQ endpoint, DMA window
  capabilities, like other restartable drivers.
- **TCP/IP as a userland service**, reachable only through capabilities (e.g. `net:listen:tcp:8080`,
  already in the capability examples). This *is* netgraph re-imagined for a microkernel: a graph of
  services with typed hooks.
- **sans-IO core**: the protocol engine is a pure function `(bytes in, time) → (bytes out, events)`
  with no direct I/O — the driver and socket API live outside it. This is what makes it host-testable
  (priority #3, TDD) and portable, and it maps cleanly onto our event/poll syscall.
- Single core removes ~80% of FreeBSD-stack complexity (no `NET_EPOCH`, no mbuf-zone races), which is
  precisely why a from-scratch stack is *less* work than porting and fits our model.
- Layer scope: Ethernet / ARP / IPv4 + IPv6 (dual-stack foundation) / ICMP + ICMPv6 / UDP / TCP.
  NDP (NS/NA) for v6 address resolution (ARP equivalent); RA for router/prefix discovery; extension header
  skipping (Hop-by-Hop, Routing, DestOpts, Fragment) for correct L4 reachability; multicast acceptance for
  all-nodes and solicited-node. See the net-ipv6 section in `docs/NOTES.md` (implemented on the net/ipv6
  branch after the N-series base). **TLS in userland.** (The long-horizon "userland service" model for the
  stack itself is still recorded below; the current bring-up keeps the sans-IO core + driver in-kernel for
  simplicity, exactly as the N milestones did.)

Indicative future milestone sequence (N-series, after M13; one at a time, each builds/boots/tests):

- **N0 — virtio-net driver service.** Discovered via the M9 HAL; raw frame TX/RX; loopback/host test.
- **N1 — sans-IO L2/L3.** Ethernet/ARP/IPv4/ICMP as a pure engine; acceptance: `ping` replies.
- **N2 — UDP + socket syscall surface.** Datagram send/recv wired to the capability-gated service.
- **N3 — TCP.** sans-IO state machine: handshake, RTO, windows, basic congestion control; host unit
  tests for the state machine before any in-QEMU run.
- **N4 — socket API + capability gating + poll.** BSD-like sockets recompiled against our libc;
  `net:listen:*` / `net:connect:*` enforcement; integration with the event/poll mechanism.
- **N5 — TLS in userland.**

Constraints to keep open now (mostly already satisfied): an event/poll syscall, DMA-safe buffers for
virtio, capability strings for network rights, and not baking any networking assumptions into the
kernel core.

### Performance model — non-negotiables

Efficiency is decided by buffer/IPC design, NOT by sans-IO or the choice of Swift (both are ~free in
the hot path when the stack stays value-typed with no ARC). A userland stack done naively (synchronous
IPC + a copy per packet) can be multiples slower than an in-kernel monolith; done with the levers below
it matches or beats one (cf. Arrakis, IX, mTCP, Google Snap). The following are **requirements** for
N0–N4, not optimizations to add later — retrofitting them means rewriting the data path:

1. **Zero-copy, end to end.** One set of packet buffers flows by reference from the virtio DMA ring →
   driver service → stack service → application via shared memory. Only descriptors cross address
   spaces; payload is never copied. App-facing socket buffers map the same pages where possible.
2. **Batching everywhere.** Process N packets per address-space crossing and per notification. The
   per-crossing cost must amortize over many packets, never one.
3. **Async notification + poll rings, never sync IPC per packet.** Use virtio/io_uring-style shared
   rings with doorbells; wake rarely, drain in bulk. No rendezvous on the packet path. This is the
   single biggest throughput lever and must integrate with the event/poll syscall.
4. **Exploit host offloads via virtio-net.** Checksum offload, TSO/GSO, and mergeable RX buffers, so
   the stack handles large segments instead of many MTU-sized packets. Decisive for our profile.
5. **Value-typed hot path, no ARC, no allocation per packet.** Preallocated buffer pools; `~Copyable`
   ownership for buffer handles; classes/ARC stay out of per-packet code.

Single core is a deliberate constraint, not a bug: it removes `NET_EPOCH`/lock contention/cache-line
bouncing and keeps the hot path linear. We trade multi-core pps scaling (not our workload) for
simplicity. Our target profile is AI/server traffic — few long-lived connections, large bandwidth-bound
streams — where these levers let a single core sustain multi-gigabit TCP and the bottleneck is
inference, not the network. High-pps small-packet workloads are explicitly not optimized for.

Each N-milestone must ship a throughput/latency check (host-side where the sans-IO core allows, in-QEMU
for the integrated path) so regressions in the data path are caught, per priority #3.

## Future cloud elasticity model (record, don't build yet)

swift-os should keep a path open for cloud VM resize without rebooting the guest, but this is a long-horizon
goal and must not complicate the single-core bring-up path. Memory elasticity can arrive much earlier than CPU
elasticity.

Planned levels:

1. **Memory ballooning.** A paravirtual balloon driver can return unused pages to the hypervisor or reclaim
   them when capacity is restored. This is the first cloud-resize mechanism to target because it does not
   require discovering new physical address ranges or SMP.
2. **Memory hot-add and hot-remove.** The kernel can later accept new physical memory ranges, add them to the
   allocator, update accounting, and expose the capacity to cells. Hot-remove requires draining allocations
   from removable ranges, migrating movable pages, and rejecting removal when pinned kernel/DMA pages remain.
3. **vCPU hotplug.** Adding or removing cores requires SMP first: per-CPU state, scheduler run queues,
   interrupt routing, timer setup, locking, TLB shootdown, CPU startup, and CPU parking paths.

Design constraints to keep this possible:

- physical memory must be represented as a set of typed regions, not one baked-in contiguous range;
- memory regions should have states such as `reserved`, `online`, `offline`, `removable`, and `hotplugPending`;
- the page allocator should eventually add and remove regions at runtime;
- resource accounting and cell limits must handle capacity changes;
- drivers and services should receive resource-change events where needed;
- pinned DMA/kernel pages must be tracked well enough to decide whether a range can be removed;
- hypervisor-specific mechanisms should live behind small virtio/paravirtual drivers;
- boot-time RAM assumptions must not leak into generic memory management.

Bring-up policy:

- M0-M8 stay single-core and do not implement cloud resize.
- After M8, memory ballooning is the preferred first step.
- Later, implement memory hot-add/hot-remove.
- Much later, after SMP is stable, implement vCPU hotplug.

## Future hot update model (record, don't build yet)

swift-os should keep a path open for updating drivers and the kernel without rebooting the whole OS, but this
must not compromise simplicity or early milestone reliability.

The preferred driver strategy is **restartable driver services**, not a Linux-style pile of binary kernel
modules. The kernel keeps the minimal trusted substrate for MMU, interrupts, scheduling, and safe device
access. Drivers that can live outside the core should run as isolated services with explicit capabilities:

- MMIO range access;
- IRQ delivery endpoint;
- DMA or shared-memory windows;
- device ownership handles;
- logging and supervision endpoints.

Driver update flow should eventually look like:

1. Start the new driver service.
2. Quiesce the old driver.
3. Drain or fail outstanding requests through explicit completion paths.
4. Transfer device ownership/state where supported.
5. Resume service through the new driver.
6. Stop the old driver.

Kernel updates have two levels:

- **Live patching for small fixes.** Replace specific functions through a controlled patch table or
  indirection point after the kernel reaches a safe point. Single-core bring-up makes this easier, but data
  structure changes still require explicit migration hooks or are forbidden.
- **Kernel handoff for large updates.** Load a new kernel image and transfer typed kernel state without a
  hardware reboot. This is long-horizon work and should only be made possible by keeping global mutable state
  small, typed, and describable.

Design constraints that keep hot updates possible:

- kernel objects should have stable typed descriptors;
- driver ownership must be explicit and revocable;
- interrupt delivery should target registered endpoints rather than hard-wired driver code;
- requests need clear completion, cancellation, and error paths;
- mutable global state should be minimized;
- observability should expose driver and kernel object versions.

## Long-horizon goals and what they require (record, don't build yet)

These are **future work** (Phase 2). The bring-up arc (Phase 0) and the active hardening arc (Phase 1) do not
implement them, but we avoid decisions that foreclose them. The Phase 1 risk remediation arc (SMP + completion
of the C-capabilities plan) is the first deliberate step toward making several of these items practical rather
than theoretical.

See `docs/RISK_REMEDIATION_ROADMAP.md` for the current sequencing and decision record.

| Runtime    | Key requirements we must not foreclose                                                        |
|------------|-----------------------------------------------------------------------------------------------|
| Swift apps | Embedded or full Swift runtime in userland; heap, threads, TLS; `mmap`; possibly Foundation-lite |
| Node.js    | libuv (epoll/kqueue-like event loop → we need a poll/event mechanism), threads, `mmap`, V8 JIT (W^X, executable mmap) |
| JVM        | Threads + futex-like sync, large `mmap` heaps, signals, JIT (executable pages), `dlopen` optional |

Common denominators to keep on the roadmap: **threads + a futex-like primitive**, **`mmap` with executable
permission (W^X) for JIT**, an **event/poll syscall**, and a **TLS** mechanism. The syscall ABI and memory
model are designed with these in mind even though only a subset is implemented now.

## Explicit non-goals

These are deliberate boundaries — minimalism by removing legacy surface, not gaps to fill: the Swift server
app itself (as part of the OS), graphics as the primary display path, amd64/x86-64 support, dynamic linking,
Linux ABI, FS crash-consistency, full Cells, Docker/OCI compatibility, a broad kernel-module ABI, and hot
kernel updates. (A network stack is *not* a non-goal — a sans-IO core and capability-gated sockets exist
today.)

**SMP and restartable driver services are no longer blanket non-goals.** They are the subject of the active
Phase 1 risk remediation roadmap (see `docs/RISK_REMEDIATION_ROADMAP.md`). That work completes the C-arc
(explicit handles + IPC) and then delivers basic SMP (S0–S5) while moving at least one driver out of the
kernel. Until those milestones land, the practical system remains effectively single-core and the in-kernel
drivers/network stack remain the current reality.

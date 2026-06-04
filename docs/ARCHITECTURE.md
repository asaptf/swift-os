# ARCHITECTURE

How swift-os is structured, and how the long-horizon goals shape early decisions.

## Layers

```
EL0  userland      busybox · static C programs · (future) Swift apps, Node.js, JVM
      ───────────  syscall boundary (SVC) — our own POSIX-like ABI, NOT Linux
EL1  kernel        Embedded Swift: runtime · mm · sched · vfs · drivers
      arch/aarch64 boot stub (asm) · exception vectors · context switch
```

## Architecture support policy

swift-os is an **aarch64-first** operating system. The implementation target through M8 is QEMU `virt` on
aarch64 only.

Rationale:

- aarch64 `virt` has a cleaner early boot path than legacy PC platforms;
- the project prioritizes fast boot, low complexity, and modern interfaces over broad hardware coverage;
- early amd64 support would force extra work around PC firmware, ACPI, APIC/xAPIC/x2APIC, legacy interrupt
  paths, and platform variation before the kernel has proven its core model;
- focusing one architecture keeps tests, documentation, and milestone acceptance criteria sharp.

The kernel should still keep architecture-specific code behind `arch/<target>/` boundaries, and generic
subsystems should not bake in aarch64 details unnecessarily. However, amd64/x86-64 is not a supported target
for the bring-up roadmap. It may be reconsidered after M8, once the syscall model, VFS, scheduler, process
model, and driver strategy are stable.

## Kernel module map (`kernel/`)

- `arch/aarch64/` — boot stub, exception vector table, context switch, low-level CPU/MMU helpers (asm + Swift).
- `runtime/` — Embedded Swift runtime hooks (allocation, ARC support), `print`/log over UART.
- `mm/` — physical page allocator, kernel heap, virtual memory (translation tables, map/unmap).
- `sched/` — process/thread abstraction, context switching, preemptive round-robin scheduler.
- `vfs/` — vnode abstraction, read-only packed base FS, RAM tmpfs.
- `drivers/` — PL011 UART, GIC, virtio-mmio, timer.

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

## Boot-time requirements

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
- **First user process.** For M8 this may be an auto-login busybox `sh` in the default cell. Later it should be
  a small `/sbin/init` supervisor.

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
- M8 busybox runs inside the default cell; full cells remain future work.

Explicitly postponed until after the busybox milestone: network isolation, OCI image compatibility, image
registries, overlay layers, seccomp-like policy VMs, multi-user accounting, nested cells, live migration, and
SMP-aware resource scheduling.

## Future identity and login model (record, don't build yet)

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

Early milestones keep this deliberately simple:

- M8 may use a single auto-login console session in the default/global cell.
- `/etc/passwd` and `/etc/group` may be absent or minimal generated compatibility files if busybox/newlib
  expects them.
- Real authentication, identity storage, roles, policy files, and multi-session management are post-M8 work.

Future identity data should live in a simple structured store in the immutable base image, with writable
session state in tmpfs or a dedicated service. Compatibility files such as `/etc/passwd` should be generated
from that store when needed, not treated as kernel security policy.

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

These are **future work**. M0–M8 do not implement them, but we avoid decisions that foreclose them.

| Runtime    | Key requirements we must not foreclose                                                        |
|------------|-----------------------------------------------------------------------------------------------|
| Swift apps | Embedded or full Swift runtime in userland; heap, threads, TLS; `mmap`; possibly Foundation-lite |
| Node.js    | libuv (epoll/kqueue-like event loop → we need a poll/event mechanism), threads, `mmap`, V8 JIT (W^X, executable mmap) |
| JVM        | Threads + futex-like sync, large `mmap` heaps, signals, JIT (executable pages), `dlopen` optional |

Common denominators to keep on the roadmap: **threads + a futex-like primitive**, **`mmap` with executable
permission (W^X) for JIT**, an **event/poll syscall**, and a **TLS** mechanism. The syscall ABI and memory
model are designed with these in mind even though only the bring-up subset is implemented now.

## Explicit non-goals (this stage)

Network stack, the Swift server app itself, graphics, SMP, amd64/x86-64 support, dynamic linking, Linux ABI,
FS crash-consistency, full Cells, Docker/OCI compatibility, a broad kernel-module ABI, restartable driver
services, and hot kernel updates.

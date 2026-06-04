# PHILOSOPHY

swift-os is a small, modern operating system built to host server applications with a clear security and
performance model. The project is not trying to become a general-purpose legacy-compatible Unix. It chooses
clarity, speed, isolation, and testable correctness over broad compatibility.

## Core priorities

Priorities are ordered. When they conflict, the earlier priority wins unless the maintainer explicitly
decides otherwise.

1. **Lightweight by design.** Keep the kernel and default system small. Every always-on subsystem must justify
   its memory cost, CPU cost, boot-time cost, and security surface.
2. **Simple enough to trust.** Prefer designs that can be understood, tested, audited, and debugged. Avoid
   clever machinery when a smaller explicit mechanism is enough.
3. **Secure by construction.** Reduce ambient authority, global mutable state, unchecked sharing, and
   unnecessary privileged code. Fewer privileged components means fewer failure and attack points.
4. **Correctness proven by tests.** Each milestone must ship executable checks. Important invariants should be
   tested at the lowest practical layer and again through integration or QEMU boot assertions.
5. **Modern over legacy.** Support modern server workloads and intentionally rebuilt userland tools. Do not
   add legacy ABIs, old platform quirks, or compatibility layers unless they directly serve the project's
   goals and remain isolated.
6. **Fast boot and fast steady state.** Boot time is a product feature. Runtime paths should minimize
   allocation, locking, scheduler overhead, and avoidable copying.
7. **Modular, but not fragmented.** Keep clear ownership boundaries between architecture code, memory
   management, scheduler, VFS, drivers, runtime support, and userland services. Modularity must make the
   system easier to reason about, not add needless indirection.

## Swift as a systems language

The kernel is written in Embedded Swift, but it must meet the standards expected from a high-quality C kernel:

- predictable code generation and explicit low-level control;
- no Foundation and no full standard library in the kernel;
- value types and `Unsafe*` pointers for low-level data structures;
- move-only ownership (`~Copyable`) for resources such as pages, handles, locks, and mappings;
- classes only when the heap is available and the ARC cost is acceptable;
- no hidden allocation or reference-counting traffic on hot paths;
- clear boundaries around assembly and C helper code.

Swift is not an excuse for abstraction overhead. It is used because its type system, ownership model, and
modern tooling can make low-level code safer without giving up control.

## Security model

swift-os should move toward explicit authority:

- one address space per process;
- capability-like handles for files, devices, IPC endpoints, clocks, and process control;
- cells as future kernel-native isolation domains;
- identity as principals, sessions, cells, and capabilities rather than Unix `root` as the primary authority;
- private namespaces where isolation requires them;
- restartable userland driver services where possible;
- small trusted kernel core.

The system should avoid a design where "root can do everything" becomes the primary security mechanism.
POSIX-like APIs may exist for porting, but kernel internals should check explicit rights.

## Compatibility stance

swift-os is not a Linux clone and does not provide the Linux syscall ABI. Userland tools are rebuilt from
source against the swift-os syscall surface and libc port.

Compatibility is acceptable when it is narrow, testable, and useful:

- POSIX-like file and process concepts for porting;
- statically linked C programs for bring-up;
- newlib first, musl possible later;
- future support for Swift apps, Node.js, and JVM requirements when they do not distort the core model.

Compatibility is rejected when it imports legacy complexity:

- Linux ABI compatibility;
- broad amd64/x86-64 bring-up before the aarch64 system is proven;
- dynamic linking in the early system;
- broad kernel-module ABI;
- Docker/OCI compatibility as a core OS goal;
- filesystem crash-consistency machinery before the project needs persistent writable storage.

## Modularity model

Modularity should follow ownership and fault boundaries:

- architecture-specific code lives under `arch/<target>/`;
- memory management owns page allocation, virtual mappings, and heap policy;
- scheduler owns runnable entities and preemption policy;
- VFS owns path resolution and filesystem dispatch;
- boot-critical drivers may live in the kernel;
- non-critical drivers should become restartable userland services;
- future cells provide isolation and resource boundaries for groups of processes.

Avoid "module" designs that merely split files while preserving hidden global coupling.

## Observability

A small OS still needs deep visibility. Debuggability is part of reliability.

The system should grow:

- cheap boot progress markers;
- kernel counters;
- structured tracepoints;
- per-process and per-cell accounting;
- driver state and version reporting;
- boot tests that catch accidental behavioral and timing regressions.

Observability should be built into the architecture, not bolted on after the system becomes opaque.

## Decision rules

When choosing between designs:

- choose the smaller trusted surface;
- choose explicit ownership over implicit sharing;
- choose measured behavior over assumptions;
- choose static structure on boot-critical paths;
- choose staged initialization and lazy services over a large early service manager;
- choose restartable services over privileged in-kernel code when practical;
- choose a typed kernel object over an unstructured integer or pointer;
- choose one well-tested path over multiple partially working paths;
- choose post-M8 documentation over premature implementation for long-horizon features.

## Current focus

The current bring-up target is aarch64 QEMU `virt`. The minimum viable system is a statically linked busybox
`sh` that can run `ls`, `cat`, and `echo` on the swift-os filesystem inside QEMU.

Everything else is either support for that path or a recorded long-horizon constraint.

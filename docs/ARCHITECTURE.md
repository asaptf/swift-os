# ARCHITECTURE

How swift-os is structured, and how the long-horizon goals shape early decisions.

## Layers

```
EL0  userland      busybox · static C programs · (future) Swift apps, Node.js, JVM
      ───────────  syscall boundary (SVC) — our own POSIX-like ABI, NOT Linux
EL1  kernel        Embedded Swift: runtime · mm · sched · vfs · drivers
      arch/aarch64 boot stub (asm) · exception vectors · context switch
```

## Kernel module map (`kernel/`)

- `arch/aarch64/` — boot stub, exception vector table, context switch, low-level CPU/MMU helpers (asm + Swift).
- `runtime/` — Embedded Swift runtime hooks (allocation, ARC support), `print`/log over UART.
- `mm/` — physical page allocator, kernel heap, virtual memory (translation tables, map/unmap).
- `sched/` — process/thread abstraction, context switching, preemptive round-robin scheduler.
- `vfs/` — vnode abstraction, read-only packed base FS, RAM tmpfs.
- `drivers/` — PL011 UART, GIC, virtio-mmio, timer.

## Design principles for performance

- **Value-type-first.** Prefer `struct` / `~Copyable` with `deinit` over classes to avoid ARC traffic on hot paths.
- **Zero-cost ownership.** Use move-only types for resources (page frames, locks, fds) so lifetimes are static.
- **Allocator design.** Buddy/bitmap physical allocator + a slab-style kernel heap for fixed-size objects;
  minimize per-alloc overhead and fragmentation. Page-granular, cache-line aware.
- **Scheduler.** O(1) round-robin to start; keep the hook points clean for a later priority/CFS-like policy.
- **No journaling FS.** RAM tmpfs writes are pointer bumps; the read-only base is mmap-friendly packed data.

## Syscall ABI

Our own POSIX-like surface (NOT Linux ABI). SVC entry → dispatch table. Kept deliberately small at first
(`open/read/write/close/lseek/stat/fstat/getdents/chdir/getcwd`, then process/signal calls), but the *shape*
(fd-based I/O, `mmap`, threads, futex-like primitive) is chosen so the long-horizon runtimes can be ported.

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

Network stack, the Swift server app itself, graphics, SMP, dynamic linking, Linux ABI, FS crash-consistency.

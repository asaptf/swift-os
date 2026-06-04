# swift-os

swift-os is a minimal, modern operating system written in **Embedded Swift** for
`aarch64` on QEMU `virt`. It is built for one focused bring-up goal: boot a
small kernel, launch statically linked userland programs, and reach a busybox
`sh` that can run `ls`, `cat`, and `echo` on the swift-os filesystem.

The project is not a Linux clone, not a legacy Unix compatibility exercise, and
not a general-purpose desktop OS. It chooses a small trusted core, fast boot,
explicit isolation, and testable correctness over broad compatibility.

## Current Status

The repository is currently through **M6**:

- the kernel boots at EL1 on QEMU `virt`;
- UART, exceptions, GIC timer interrupts, the MMU, and basic scheduling are up;
- each process has its own address space;
- EL0 syscall entry works through `svc #0`;
- a tiny VFS exposes a read-only bring-up file and UART stdout/stderr;
- a static ELF64 user program is embedded, loaded, executed, and exits back to
  the kernel;
- `make test` runs host-side unit checks and QEMU boot assertions.

The headline target remains **M8**: a statically linked busybox `sh` running on
the project filesystem inside QEMU.

## Philosophy

The design is intentionally narrow:

1. **Lightweight by design.** Every always-on subsystem must justify its memory
   cost, CPU cost, boot-time cost, and security surface.
2. **Simple enough to trust.** Prefer explicit, testable mechanisms over clever
   machinery.
3. **Secure by construction.** Move toward separate address spaces,
   capability-like handles, restartable services, and small privileged code.
4. **Correctness proven by tests.** Each milestone must build, boot, satisfy its
   acceptance criterion, and ship executable checks.
5. **Modern over legacy.** Rebuild tools against the swift-os ABI instead of
   importing Linux compatibility or old platform assumptions.

See [docs/PHILOSOPHY.md](docs/PHILOSOPHY.md) for the full project stance.

## Architecture

```text
EL0  userland      busybox, static C programs, future Swift apps, Node.js, JVM
      ----------   syscall boundary: swift-os POSIX-like ABI, not Linux ABI
EL1  kernel        Embedded Swift: runtime, mm, sched, vfs, drivers
      arch/aarch64 boot, exception vectors, context switch
```

Early architecture decisions:

- **Target:** `aarch64`, QEMU `virt`, single core.
- **Kernel language:** Embedded Swift, freestanding, no Foundation, no full
  standard library.
- **Isolation:** real MMU-based process isolation, one address space per
  process.
- **Filesystem direction:** read-only packed base image plus RAM tmpfs scratch;
  no journaling in the bring-up design.
- **ABI:** a small swift-os syscall surface, POSIX-like where useful, explicitly
  not the Linux syscall ABI.
- **Linking:** static userland only; no dynamic loader at this stage.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for subsystem boundaries,
driver strategy, long-horizon runtime constraints, and explicit non-goals.

## Repository Map

```text
kernel/
  arch/aarch64/   boot code, vectors, context switch, linker script
  drivers/        PL011 UART, GIC
  mm/             physical pages, virtual memory
  runtime/        freestanding runtime support for Embedded Swift
  sched/          process/thread scheduling
  syscall/        syscall dispatch
  user/           EL0 entry, ELF loading, process launch
  vfs/            minimal VFS bring-up layer
userland/
  lib/            crt0, syscall wrappers, tiny libc subset
  hello.c         static ELF bring-up program
tests/            host and QEMU acceptance checks
docs/             philosophy, architecture, hardware/toolchain notes
```

## Build And Run

The default tool paths are pinned for the current macOS Apple Silicon bring-up
environment in [docs/NOTES.md](docs/NOTES.md). They can be overridden from
`make` if your local installation differs.

```sh
make tools-check
make build
make run
```

Useful targets:

```sh
make test     # host page allocator test + userland ELF check + QEMU boot asserts
make debug    # boot QEMU paused with a gdbstub on :1234
make gdb      # attach aarch64-elf-gdb to the paused kernel
make clean
```

`make run` starts:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -kernel build/kernel.elf
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

Milestones are developed in order, and each one must remain buildable,
bootable, tested, and reviewable before moving on.

- **M0:** boot skeleton and UART output.
- **M1:** runtime hooks, exception vectors, heap, page allocator.
- **M2:** GIC and timer interrupts.
- **M3:** virtual memory and MMU.
- **M4:** processes, scheduling, EL0 trap path.
- **M5:** syscall entry and VFS skeleton.
- **M6:** libc subset, ELF64 loader, spawn. **Done.**
- **M7:** TTY, termios, signals.
- **M8:** static busybox `sh` with `ls`, `cat`, and `echo`.

Longer-horizon goals are recorded, not implemented early: native Swift
applications, Node.js, the JVM, cells, restartable driver services, richer
observability, and hot-update-friendly kernel structure.

## Non-Goals At This Stage

- Linux ABI compatibility;
- dynamic linking;
- SMP;
- amd64/x86-64 support;
- network stack;
- graphics;
- Docker/OCI compatibility;
- journaling or persistent writable filesystem guarantees;
- broad loadable kernel-module ABI.

These are not accidental omissions. They keep the bring-up path small enough to
measure, test, and understand.

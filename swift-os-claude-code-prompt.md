# Prompt for Claude Code: a lightweight OS in Swift for hosting applications

> The upper section (Context → How to work) is suitable for the project's `CLAUDE.md`.
> The "Starting task" section at the end is where the first run begins.

---

## Role and goal

You are a systems engineer implementing, from scratch, a minimal operating system in **Swift**, intended for hosting server applications. The minimum-viable goal of the project: bring the system to the point where a statically linked **busybox `sh`** prints an interactive prompt and runs basic commands (`ls`, `cat`, `echo`) on top of our filesystem inside QEMU.

This is a research/learning project. The priorities are **performance and simplicity**, not storage fault tolerance. The architectural decisions have already been made (see below) — do not re-litigate them without a clear reason; if you spot a serious problem, ask first.

## Context and accepted architectural decisions

- **Kernel language:** Swift in **Embedded Swift** mode (freestanding, no Foundation, no full stdlib). Style: value types and `Unsafe*` pointers for the low level; `~Copyable` structs with `deinit` for resource ownership; classes only after the heap is up, and sparingly.
- **Application isolation:** real hardware isolation via the MMU (a separate address space per process). No SMP at the start (single core).
- **Filesystem — two-tier, built for performance, no journaling:**
  - a read-only base — a packed image, mounted read-only (start with a simple format: ramdisk/CPIO or a custom packed image);
  - a RAM scratch tier (tmpfs) for everything written (logs, `/tmp`, runtime state); loss on reboot is acceptable.
- **Linux ABI compatibility — we are NOT doing it.** Instead we provide our own POSIX-like interface and rebuild tools from source.
- **Userland tools:** compiled from source against our sysroot. The first target is **busybox** (sh + basic utilities in a single binary). **Static** linking only — no dynamic loader.
- **libc:** a port of **newlib** (a minimal set of syscall stubs) for bring-up; a move to musl is possible later.

## Target environment

- **Architecture:** `aarch64`, QEMU machine `virt` (`qemu-system-aarch64 -M virt`). Chosen for its clean boot path and built-in virtio devices; less legacy than x86-64.
- **Boot:** direct, via `-kernel <image>`; the kernel starts at EL1.
- **Devices (reference values, verify against current QEMU docs/source):** UART PL011 (MMIO ~`0x0900_0000`), GIC interrupt controller, disk and the rest via `virtio-mmio`. RAM base ~`0x4000_0000`.
- **Run/debug:** everything runs headless through the serial console; provide a target for attaching GDB (`-s -S`).

## Toolchain and tools

- A Swift toolchain with Embedded Swift support; `clang`/LLVM as the C cross-compiler (target triple + sysroot); an assembler for the boot stub.
- Build via a `Makefile` (or a script): targets `build`, `run` (launch in QEMU), `debug` (QEMU + GDB server), `clean`.
- **Check the environment first** and pin the tool versions. The exact Embedded Swift flags and target triple **must be confirmed against the installed toolchain** — they change between versions, do not rely on memory. If something is missing — report which packages are needed, and do not try to work around the network.

## Constraints and non-goals

- A single architecture (aarch64 virt), a single CPU core (no SMP) — at the start.
- Static linking only; no dynamic loader.
- No Linux syscall ABI compatibility; we do not run unmodified Linux binaries.
- A filesystem with no journal and no crash-consistency guarantees — this is a deliberate choice, not a "missing feature."
- Out of scope for this stage: a network stack, running the Swift server application itself, graphics. Record these as future work, do not implement.

## Code and repository conventions

- Repository structure (propose and create it at M0): `kernel/` (Swift + asm), `libc/` (newlib port + our stubs), `userland/` (busybox build and test programs), `build/`, `docs/NOTES.md`.
- Maintain `docs/NOTES.md`: accepted decisions, hardware addresses/constants, exact build and run commands.
- Clear commits on completing each milestone. No "dead" half-files.

## How to work

1. Implement **strictly one milestone at a time**, in order M0 → M8.
2. After each milestone: the code **builds** and **boots in QEMU**, the acceptance criterion is met, a short test/check is added, a commit is made.
3. Then **stop and give a brief report** (what was done, how to verify, what's next) and **wait for review** before the next milestone.
4. Keep the system bootable and verifiable at every step — no big, unstable "leaps."
5. When you hit a fork with serious consequences — ask, don't guess.

## Milestone plan (with acceptance criteria)

- **M0 — Environment and boot skeleton.** Verify the toolchain; build a freestanding image from an assembly boot stub + a minimal Embedded Swift kernel; set up the stack, BSS clearing, and the handoff to the Swift entry point; output to UART PL011.
  *Acceptance:* a line like `Hello from Swift kernel` appears on the QEMU serial console.

- **M1 — Runtime and memory.** Exception vector table (EL1); a physical page allocator; a kernel heap allocator; wire up the runtime hooks Swift needs (alloc/free) so that classes and ARC work; a primitive `print`/log over UART.
  *Acceptance:* instantiating a Swift class and working with the heap do not crash; logging works.

- **M2 — Interrupts and timer.** GIC initialization; a timer interrupt handler; a system tick.
  *Acceptance:* a periodic tick is logged steadily.

- **M3 — Virtual memory and MMU.** Translation tables; kernel mapping; enabling the MMU; map/unmap page functions.
  *Acceptance:* the MMU is enabled, the kernel keeps running; a page maps and unmaps correctly.

- **M4 — Processes and scheduler.** Process/thread abstraction; context switching; a simple preemptive round-robin; a separate address space per process; running code in user mode (EL0) with a return to the kernel.
  *Acceptance:* two kernel threads interleave; then a user process at EL0 executes in its own address space and traps back into the kernel.

- **M5 — System calls and a VFS skeleton.** A syscall entry point (SVC) and a dispatch table; a thin VFS with a vnode abstraction; the read-only base (ramdisk/packed) and the RAM tmpfs, both under the VFS; basic file calls (`open`, `read`, `write`, `close`, `lseek`, `stat`/`fstat`, `getdents`, `chdir`, `getcwd`).
  *Acceptance:* a user test program performs open/read/write/close on files via system calls.

- **M6 — libc port, ELF loader, spawn.** A static newlib port; implementation of the syscall stubs on top of M5; an ELF64 loader; a process-launch primitive (`posix_spawn` or `fork`+`execve` — pick one and justify it; a full COW `fork` is optional).
  *Acceptance:* a cross-built static C `hello world` loads, executes, and exits via `exit`.

- **M7 — TTY, termios, signals.** A console driver with a line discipline (canonical and raw modes, echo, line editing); `termios` (`tcgetattr`/`tcsetattr`); Ctrl-C → SIGINT; a minimum of `sigaction`/`kill`/`waitpid`/SIGCHLD/SIGPIPE.
  *Acceptance:* interactive input is echoed; Ctrl-C interrupts a running command.

- **M8 — busybox (the headline goal).** Cross-build a static busybox against our sysroot; run `sh`.
  *Acceptance:* an interactive busybox `sh` prompt that successfully runs `ls`, `cat`, `echo` on top of the read-only base and tmpfs.

## Starting task

Start with **M0**. First: propose the repository structure and create it; verify the presence and versions of the required tools (Swift with Embedded Swift, the clang/LLVM cross-compiler, `qemu-system-aarch64`, GDB) and confirm the exact Embedded Swift flags and target triple against the toolchain. If something is missing — list what's missing and stop. If everything is in place — build and boot the skeleton to the M0 acceptance criterion, set up a `Makefile` with `build`/`run`/`debug`/`clean` targets, record the commands in `docs/NOTES.md`, make a commit, and give a brief report. Then wait for review before M1.

---

## Project-specific amendments (added by the maintainer)

These conditions extend and, where noted, override the baseline above. They were added for this build.

1. **Documentation language is English.** All documentation — including this prompt — is written in English.
2. **Lightweight, fast, and modern is the top priority.** We must still be able to compile tools (`sh`, etc.), but when "support legacy" conflicts with "be modern," we choose modern. Prefer current conventions, formats, and toolchains over backward compatibility.
3. **Test everything thoroughly; use TDD.** Write tests first where practical. Every milestone ships with executable checks.
4. **Aggressively efficient memory and CPU-time management.** Memory and scheduler design should optimize for low overhead and high throughput.
5. **Application runtimes.** Beyond the busybox goal, the OS must eventually be able to launch:
   - native **Swift** applications,
   - the **Node.js** runtime,
   - the **JVM**.
   These are large, long-horizon goals recorded as future work; the bring-up path (M0–M8) is unchanged, but architectural decisions (libc surface, threading, syscall set, memory model) should not foreclose them. See `docs/ARCHITECTURE.md` and `docs/NOTES.md`.

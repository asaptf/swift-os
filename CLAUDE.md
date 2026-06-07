# CLAUDE.md — swift-os

A minimal, modern operating system written in **Embedded Swift** for `aarch64` (QEMU `virt`),
built to host server applications. Minimum-viable goal: a statically linked busybox `sh`
running `ls`/`cat`/`echo` on our filesystem inside QEMU.

## Priorities (in order)

1. **Modern over legacy.** When backward compatibility conflicts with a clean, modern design, choose modern. We rebuild tools from source rather than chase legacy ABIs.
2. **Lightweight & fast.** Low memory overhead, low scheduler overhead, fast boot.
3. **Correctness, proven by tests.** TDD where practical; every milestone ships executable checks.

## Hard architectural decisions (do not re-litigate without asking)

- **Language: Swift everywhere, by default.** swift-os is a Swift OS — kernel, userland utilities,
  and host-side tooling are written in Embedded Swift (or host Swift for build tools). This is a
  first principle, not a preference. Reaching for C or any other language requires a **strong,
  documented justification**, limited to:
  - third-party code we don't own (busybox, the newlib port);
  - low-level bridges Swift cannot express directly (volatile MMIO, the syscall/runtime shims in
    `kernel/arch/aarch64/io.h` and `userland/lib/swift_user.*`, boot/exception assembly);
  - a measured, recorded reason (e.g. a toolchain limitation) — note it in `docs/NOTES.md`.
  Default to writing Swift, and prefer rewriting existing C in Swift over extending it. New userland
  programs use the `userland/lib/swift_user.*` bridge, like `/bin/ps` and `/bin/console-login`.
- **Kernel Swift style:** freestanding, no Foundation, no full stdlib.
  - Value types + `Unsafe*` pointers at the low level.
  - `~Copyable` structs with `deinit` for resource ownership.
  - Classes only after the heap is up, and sparingly (ARC has a cost).
- **Isolation:** real MMU-based isolation; one address space per process. Single core (no SMP) at the start.
- **Filesystem:** two-tier, no journaling. Read-only packed base + RAM tmpfs scratch. Data loss on reboot is acceptable by design.
- **No Linux ABI.** Our own POSIX-like syscall surface; tools are recompiled.
- **Static linking only.** No dynamic loader.
- **libc:** newlib port for bring-up; musl possible later.

## Target / hardware

- `qemu-system-aarch64 -M virt`, kernel boots at **EL1**, loaded via `-kernel`.
- UART **PL011** @ MMIO `0x0900_0000`; **GIC** interrupt controller; disk/etc via **virtio-mmio**; RAM base `0x4000_0000`.
- Headless: serial console only. Debug via QEMU `-s -S` + GDB.
- Always verify hardware constants against current QEMU source — see `docs/NOTES.md`.

## Workflow (strict)

- Implement **one milestone at a time**, M0 → M8 (see the prompt / `docs/NOTES.md`).
- After each milestone: it **builds**, **boots in QEMU**, meets its acceptance criterion, has a test, and is committed.
- Then **stop, give a brief report, and wait for review** before the next milestone. No large unstable leaps.
- At a fork with serious consequences: **ask, don't guess.**

## Long-horizon goals (record, don't build yet)

Beyond busybox, the OS must eventually launch native **Swift** apps, the **Node.js** runtime, and the **JVM**.
Keep the libc surface, threading model, syscall set, and memory model from foreclosing these.
See `docs/ARCHITECTURE.md`.

## Build

- `make build` / `make run` / `make debug` / `make clean`.
- Test runner: `make test` (host-side unit tests + in-QEMU boot assertions).
- Exact Embedded Swift flags & target triple are **toolchain-version-specific** — confirm against the installed toolchain, do not rely on memory. Pinned in `docs/NOTES.md`.

## Conventions

- All docs and comments in **English**.
- Match surrounding code style; comment density matches neighbors.
- No dead/half files. Clear commits per milestone.
- **Write Swift by default** (see "Language" under hard decisions). C/asm only with a strong, documented
  reason — third-party code, low-level bridges, or a recorded toolchain limitation.
- **License header on every new source file.** Start each new source file we author with an SPDX
  identifier on the first line: `// SPDX-License-Identifier: Apache-2.0` for Swift/C/headers/assembly,
  `# SPDX-License-Identifier: Apache-2.0` for shell, Make, and linker scripts. Third-party / vendored
  files (busybox, newlib) keep their upstream headers untouched. See `LICENSE` and `NOTICE`.

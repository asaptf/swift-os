# CLAUDE.md — swift-os

A full-fledged, modern operating system written in **Embedded Swift** for `aarch64`. Its flagship
profile is **application & AI hosting**; **embedded/appliance** deployment is a co-primary profile;
**desktop use is not excluded**. The design value is *efficient, reliable minimalism* — a small
trusted core, capability-based isolation, fast deterministic boot, immutable signed images, and
testable correctness, achieved by **removing legacy** rather than emulating it.

The bring-up phase is done (M0–M13 + networking, see "history" below): the system boots on QEMU
`virt`, isolates processes with the MMU, runs a native Swift userland, and has an in-kernel network
stack. Current development hardens this for the product profile — see
`docs/RISK_REMEDIATION_ROADMAP.md`.

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
- **Isolation:** real MMU-based isolation; one address space per process. Single core (no SMP) at the start. SMP support is a planned post-M13 remediation series (S0–S5); see `docs/RISK_REMEDIATION_ROADMAP.md`.
- **Filesystem:** three-tier, no journaling. Read-only packed signed base + RAM
  tmpfs scratch (data loss on reboot acceptable for these two) + a **persistent
  writable `/data` tier** (datafs, on a dedicated virtio-blk disk, with
  `fsync`/`fdatasync`/`sync` durability) for state that must survive reboot — e.g.
  the SQLite database backing the hosted site. The base stays immutable; datafs is
  a small inode-table + block-bitmap FS with no journaling — crash-safety relies on
  honest `fsync` plus the application's own journaling (as SQLite's rollback journal
  does), not on FS journaling. See the D-series in `docs/RISK_REMEDIATION_ROADMAP.md`.
- **No Linux ABI.** Our own POSIX-like syscall surface; tools are recompiled.
- **Static linking only.** No dynamic loader.
- **libc:** newlib port for bring-up; musl possible later.

## Target / hardware

- `qemu-system-aarch64 -M virt`, kernel boots at **EL1**, loaded via `-kernel`.
- UART **PL011** @ MMIO `0x0900_0000`; **GIC** interrupt controller; disk/etc via **virtio-mmio**; RAM base `0x4000_0000`.
- Headless: serial console only. Debug via QEMU `-s -S` + GDB.
- Always verify hardware constants against current QEMU source — see `docs/NOTES.md`.

## Workflow (strict)

- Implement **one (sub)milestone at a time**. The active plan is **Phase 1** in
  `docs/RISK_REMEDIATION_ROADMAP.md` (complete the capability/handle model, deliver SMP, move drivers
  toward restartable userland services). The bring-up milestone history lives in `docs/NOTES.md`.
- After each milestone: it **builds**, **boots in QEMU** (single-core and `-smp N` where relevant),
  meets its acceptance criterion, has a test, and is committed.
- Then **stop, give a brief report, and wait for review** before the next milestone. No large unstable leaps.
- At a fork with serious consequences: **ask, don't guess.**

## Long-horizon goals (record, don't build yet)

Beyond the current userland, the OS must eventually launch native **Swift** apps, the **Node.js**
runtime, and the **JVM**, plus the full-OS capabilities of Phase 2 (observability, A/B signed-image
updates with rollback, the embedded footprint profile). Keep the libc surface, threading model,
syscall set, and memory model from foreclosing these. See `docs/ARCHITECTURE.md`.

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

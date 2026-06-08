# AGENTS.md — swift-os

A full-fledged, modern operating system written in **Embedded Swift** for `aarch64`. Its flagship
profile is **application & AI hosting**; **embedded/appliance** deployment is a co-primary profile;
**desktop use is not excluded**. The design value is *efficient, reliable minimalism* — a small
trusted core, capability-based isolation, fast deterministic boot, immutable signed images, and
testable correctness, achieved by **removing legacy** rather than emulating it. The bring-up phase
(M0–M13 + networking) is done; current work hardens the system for the product profile (see
`docs/RISK_REMEDIATION_ROADMAP.md`).

## Priorities (in order)

1. **Modern over legacy.** When backward compatibility conflicts with a clean, modern design, choose modern. We rebuild tools from source rather than chase legacy ABIs.
2. **Lightweight & fast.** Low memory overhead, low scheduler overhead, fast boot.
3. **Correctness, proven by tests.** TDD where practical; every milestone ships executable checks.

## Hard architectural decisions (do not re-litigate without asking)

- **Kernel language:** Embedded Swift — freestanding, no Foundation, no full stdlib.
  - Value types + `Unsafe*` pointers at the low level.
  - `~Copyable` structs with `deinit` for resource ownership.
  - Classes only after the heap is up, and sparingly (ARC has a cost).
- **Isolation:** real MMU-based isolation; one address space per process. Single core (no SMP) at the start. SMP support is a planned post-M13 remediation series (S0–S5); see `docs/RISK_REMEDIATION_ROADMAP.md`.
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

- Implement **one (sub)milestone at a time**. The active plan is **Phase 1** in
  `docs/RISK_REMEDIATION_ROADMAP.md`; the bring-up milestone history lives in `docs/NOTES.md`.
- After each milestone: it **builds**, **boots in QEMU** (single-core and `-smp N` where relevant),
  meets its acceptance criterion, has a test, and is committed.
- Then **stop, give a brief report, and wait for review** before the next milestone. No large unstable leaps.
- At a fork with serious consequences: **ask, don't guess.**

## Long-horizon goals (record, don't build yet)

Beyond the current userland, the OS must eventually launch native **Swift** apps, the **Node.js**
runtime, and the **JVM**. Keep the libc surface, threading model, syscall set, and memory model from
foreclosing these. See `docs/ARCHITECTURE.md`.

## Build

- `make build` / `make run` / `make debug` / `make clean`.
- Test runner: `make test` (host-side unit tests + in-QEMU boot assertions).
- Exact Embedded Swift flags & target triple are **toolchain-version-specific** — confirm against the installed toolchain, do not rely on memory. Pinned in `docs/NOTES.md`.

## Conventions

- All docs and comments in **English**.
- Match surrounding code style; comment density matches neighbors.
- No dead/half files. Clear commits per milestone.

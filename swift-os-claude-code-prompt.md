# Prompt for Claude Code: swift-os — a full OS in Swift for hosting and embedded

> This is the project's mission and working agreement. It supersedes the original
> M0–M8 "bring-up" prompt (that phase is complete). The live design docs are
> `docs/PHILOSOPHY.md`, `docs/ARCHITECTURE.md`, `docs/CAPABILITIES.md`,
> `docs/RISK_REMEDIATION_ROADMAP.md`, and the working log `docs/NOTES.md`.

---

## Role and goal

You are a systems engineer building **swift-os**: a full-fledged, modern operating system written in
**Embedded Swift** for `aarch64`. The mission is not a learning exercise that ends at a shell — it is a real
OS with a sustained direction.

Its flagship profile is **application & AI hosting**; **embedded/appliance** deployment is a co-primary
profile; **desktop use is not excluded**. The same minimalist core serves all three — they differ in which
optional services and devices are present, not in the kernel.

The guiding value is **efficient, reliable minimalism**: a small trusted core, capability-based isolation,
fast deterministic boot, immutable signed images, and testable correctness — achieved by **removing legacy**
rather than emulating it. When "support legacy" conflicts with "be modern and minimal," choose modern.

The major architectural decisions are made (below); do not re-litigate them without a clear reason. If you
spot a serious problem, **ask first**.

## Accepted architectural decisions (do not re-litigate without asking)

- **Language: Swift everywhere, by default.** Kernel, userland utilities, and host tooling are Embedded Swift
  (or host Swift for build tools). C/assembly only with a strong, documented reason: third-party code we
  don't own (busybox legacy bring-up, the newlib port), low-level bridges Swift cannot express (volatile
  MMIO, syscall/runtime shims, boot/exception assembly), or a recorded toolchain limitation. Prefer
  rewriting existing C in Swift over extending it.
- **Kernel Swift style:** freestanding, no Foundation, no full stdlib. Value types + `Unsafe*` pointers at
  the low level; `~Copyable` structs with `deinit` for resource ownership; classes only after the heap is up,
  and sparingly (ARC has a cost); no hidden allocation on hot paths.
- **Isolation:** real MMU-based isolation, one address space per process. The bring-up system is single-core;
  **SMP is a required Phase 1 deliverable** (see the risk remediation roadmap), not a permanent constraint.
- **Security:** capability/principal model, not Unix `root`. Identity is principals/sessions/capabilities;
  `/etc/swos/passwd` (SHA-256-hashed) is the source, `/etc/passwd` a generated compatibility view. The target
  is typed handles + IPC + spawn-with-handles (the C-arc).
- **Filesystem:** two-tier, no journaling. Read-only packed base image (`SWOSBASE`) served from disk + a RAM
  tmpfs for scratch. Data loss on reboot is acceptable by design. Updates are signed immutable images
  (A/B + rollback is Phase 2), not mutable-root mutation.
- **No Linux ABI.** Our own POSIX-like syscall surface; tools are recompiled from source. The native Swift
  userland is the direction; busybox was the legacy bring-up tool.
- **Static linking only.** No dynamic loader.
- **libc:** newlib port for bring-up; musl possible later.
- **Architecture:** **aarch64-first.** amd64/x86-64 is out of scope and may be reconsidered only after the
  Phase 1 core stabilizes.

## Target environment

- **Hardware:** `qemu-system-aarch64 -M virt`, kernel runs at **EL1**.
- **Boot:** UEFI (`BOOTAA64.EFI` on an ESP in a GPT disk image, under QEMU+AAVMF) is the primary path; direct
  `-kernel` is a fallback. Both are tested.
- **Devices (verify against current QEMU source — see `docs/NOTES.md`):** UART PL011 (`~0x0900_0000`), GIC,
  disk/net/input via `virtio-mmio`; RAM base `~0x4000_0000`. A boot-time DTB reader populates a `Platform`
  struct rather than hardcoding constants.
- **Run/debug:** headless serial console; GDB via QEMU `-s -S`.

## Toolchain

- A swift.org **Embedded Swift** toolchain, LLVM `clang`, `ld.lld`, `llvm-objcopy`, QEMU.
- Build via `make`: `build` / `run` / `disk` / `disk-run` / `debug` / `test` / `clean`.
- The exact Embedded Swift flags and target triple are **toolchain-version-specific** — confirm against the
  installed toolchain, do not rely on memory. Pinned in `docs/NOTES.md`.

## How to work (strict)

1. Implement **one (sub)milestone at a time**. The active plan is **Phase 1** in
   `docs/RISK_REMEDIATION_ROADMAP.md`.
2. After each: it **builds**, **boots in QEMU** (single-core and `-smp N` where relevant), meets its
   acceptance criterion, ships an executable test, and is committed.
3. Then **stop, give a brief report** (what was done, how to verify, what's next) and **wait for review**.
4. Keep the system bootable and verifiable at every step — no large, unstable leaps.
5. At a fork with serious consequences — **ask, don't guess.** Record the decision in `docs/NOTES.md`.
6. All docs and comments in **English**. New source files we author start with an SPDX license header.

## Phases

- **Phase 0 — bring-up (done, historical).** M0–M13 + the N-series network stack: boot, MMU isolation,
  preemptive EL0 scheduling, fork/exec/waitpid, VFS (disk-backed base + tmpfs), ELF64 loader, TTY/termios/
  signals, UEFI+GPT boot, capability/principal security + console-login init, a native Swift userland
  (coreutils + `calc`/`kv` + network tools), and an in-kernel sans-IO TCP/IP stack. The detailed milestone
  history is in `docs/NOTES.md`.
- **Phase 1 — hardening for the product profile (active).** Complete the capability/handle model (C-arc),
  deliver SMP (S0–S5), make global kernel state concurrency-safe, and move drivers + the network stack toward
  restartable userland services. See `docs/RISK_REMEDIATION_ROADMAP.md`.
- **Phase 2 — full-OS capabilities (forward, record-don't-build-yet).** Observability/metrics, A/B
  signed-image updates with rollback, the native Swift application runtime plus Node.js/JVM hosting, the
  embedded footprint profile, and richer device/display support.

## Starting task

Pick up **Phase 1**. Read `docs/RISK_REMEDIATION_ROADMAP.md` and `docs/NEXT_SESSION.md`, confirm the build is
green (`make test`), then propose the next concrete sub-milestone (most likely a C-arc piece or S0) with its
acceptance criteria. Implement it under the strict workflow above, then stop for review.

# OS self-update (kernel + base image) — Phase 0 audit

Goal: update **SwiftOS itself** (kernel + base image) on a running box, with no
Rescue/live-`dd` — deliver a signed bundle over HTTPS, stage into the inactive
A/B slot, atomically switch, health-confirm, auto-rollback on failure.

This document is the mandatory Phase-0 audit: what of the A/B skeleton is **real**
vs **stub/missing**, before any new code is written.

## TL;DR

The A/B *mechanism* is far more complete than the prompt assumes — both the kernel
(ESP) and the base image (data-disk update store) already have signed slots,
attempt-based rollback, confirm, and full QEMU test coverage. What is **missing** is
the **delivery + coordination + anti-rollback** layer the prompt actually asks for:

- a **signed system-update bundle** (kernel+base, monotonic version),
- a **download/stage path** that works on a live box (today base staging needs a
  physically-attached payload *disk*; kernel staging can only *duplicate the
  running kernel*, never install a new one),
- **one coordinated boot-selector** (kernel and base are selected independently
  today and can drift),
- **monotonic anti-rollback** (never enforced),
- `/bin/swupdate os <url>` + unified `confirm`, and `make os-update-test`.

## What is REAL (implemented, tested, in `make test`)

### Kernel A/B — ESP side (`boot/efi/loader.c`, `kernel/fs/esp.swift`)
- UEFI loader reads a **signed** `SWOSKERN` manifest (`kernelboot.swift` v3 =
  per-slot SHA-256 + Ed25519) and `kernelA.bin`/`kernelB.bin` from
  `\EFI\swift-os` on the GPT/ESP disk; verifies the slot hash before jumping.
- Writable **`kernel-state`** record (`SWOSKSTA`, SHA-256-protected, *not* signed):
  per-slot `attemptCount` + `state` (untried/confirmed), `seq`, `lastBooted`,
  mutable `active`. Loader bumps the attempt counter each boot.
- Loader **attempt-based rollback** (`KS_MAX_ATTEMPTS=3`): unconfirmed active slot
  that exhausts its attempts → boot the fallback. (`uefi_krollback_test.sh`.)
- Runtime syscalls (capConsole-gated):
  - `swos-kstage` (68) — FAT32 in-place copy **active→inactive** kernel slot + verify.
  - `swos-kactivate` (69) — flip active slot in `kernel-state`, mark untried.
  - `swos-kconfirm` (70) — mark booted kernel slot confirmed.
- Tests: `uefi_kernel_ab`, `uefi_kstage`, `uefi_kactivate`, `uefi_kattempt`,
  `uefi_kconfirm`, `uefi_krollback` — all wired into `make test`.

### Base-image A/B — data-disk update store (`kernel/fs/swosboot.swift`, `updatestore.swift`)
- `SWOSBOOT` manifest: CRC32-protected, **double-buffered** (LBA 0/1, torn-write
  safe, highest valid `sequence` wins). Two slots, each a full **signed
  `SWOSBASE`-v3** image, plus `active`/`fallback`, per-slot `state`/`attemptCount`/
  `generation`. Trust boundary documented: manifest is *not* a trust anchor; it only
  selects among self-authenticating signed images.
- Boot: `updateStoreInit` selects active slot, records the boot attempt, and does
  **attempt-based rollback** (`maxBootAttempts=3`, U1d) to the fallback;
  verified-fallback at mount if the active image fails Ed25519.
- Power-fail discipline already present: stage slot fully + `virtioBlkFlush`
  **before** the manifest write-back, and the manifest write goes to the *other*
  double-buffer copy then flushes (U1h).
- Runtime syscalls (capConsole-gated):
  - `swos-update` (67) — copy an attached **payload disk** into the inactive slot.
  - `swos-activate` (66) — flip active base slot (on trial, untried).
  - `swos-confirm` (65) — confirm booted base slot.
- Host builder `tools/updatestore.swift`; tests `ab_update/persist/confirm/rollback/
  activate/payload/stage/flush` — all in `make test`.

### Site updates (`/bin/swupdate`, SU-A/B/C) — reference pattern, already shipped
- `SWSITE` signed bundle (Ed25519 + SHA-256), fetched over **TLS 1.3** by
  `swupdate site <url>`, staged into `/data/www/next`, **atomically swapped**
  (current→prev, next→current) with crash recovery on next boot. This is exactly
  the delivery/stage/atomic-swap shape we need for the OS bundle — reuse it.

## GAPS vs the prompt (this is the work to do)

1. **No coordinated boot-selector.** Kernel slot (ESP `kernel-state`) and base slot
   (data-disk `SWOSBOOT`) are chosen **independently**; `swos-kactivate` and
   `swos-activate` are separate commands. Nothing guarantees kernel-A boots with
   base-A. Prompt requires **one atomic flip** selecting kernel+base together.

2. **No live delivery of a new OS.**
   - Base staging reads from a **physically-attached read-only payload disk**
     (`virtioBlkSelectPayload`) — not possible on a live Hetzner box.
   - Kernel staging (`swos-kstage`) only **duplicates the currently-running kernel**
     into the inactive slot — there is **no path to install a *new* kernel binary**.
   - `kernelA.bin`/`kernelB.bin` are both built from the *same* `$(KERNEL_BIN)` and
     the FAT32 writer does **same-size in-place copy only** (`ka.1 != kb.1` → EINVAL).
     A genuinely new kernel of a different size cannot be written in place →
     needs fixed/padded slot sizing or a FAT cluster (re)allocator. **Decision needed.**
   - `/bin/swupdate` has `seed`/`apply-local`/`site` only — **no `os` subcommand**.
   - No combined kernel+base **system-bundle** format (full or delta).

3. **No monotonic anti-rollback.** `generation`/`sequence` exist but are *not* a
   security version; an older, validly-signed (and possibly vulnerable) image is
   accepted. Prompt requires a monotonic version refused if ≤ the installed one.

4. **No kernel-mediated "write inactive slot from /data bytes" path.** The only
   privileged slot writes are payload-disk→slot (base) and active→inactive-copy
   (kernel). Neither takes bytes from a downloaded `/data` staging file.

5. **No unified `confirm` / auto-confirm.** Confirm is split (`swos-confirm` +
   `swos-kconfirm`), both manual. No `/bin/swupdate confirm` and no auto-confirm on
   "services healthy (sshd+nginx up)".

6. **No `make os-update-test`** and — critically — **no real-hardware validation**.
   Per this session's lesson (timer `netPump` passed QEMU, killed the NIC on real
   Ampere/KVM), every boot/driver-path change here must be checked on the live box
   via Console before we rely on it.

## Proposed staged plan (one submilestone at a time, build+boot+test+commit+stop)

- **OS-0 (this doc):** audit. ← done.
- **OS-1 Coordinated selector:** make the ESP `kernel-state` (already loader-read,
  hash-protected, atomically rewritten) the single authority that also names the
  **base** slot; `updateStoreInit` reads the base slot from it. One atomic flip
  picks both. (Design fork — see below.)
- **OS-2 System-update bundle format + host tool:** `SWSYS` bundle = monotonic
  `version` + signed (`IMG_SIGNING_SEED`/`PUB`) header over {kernel image, base
  image} (full first; delta later). Host builder under `tools/`, à la `sitepack`.
- **OS-3 Kernel-mediated stage-from-/data:** capability-gated syscalls that write
  the inactive **base** slot and inactive **kernel** slot from a verified `/data`
  staging file (resolve the kernel size-change question here), fsync before flip.
- **OS-4 `/bin/swupdate os <url>` + monotonic anti-rollback:** HTTPS fetch → verify
  signature **and** version > installed → stage both slots → coordinated atomic
  flip → trial-boot flag + reset attempts → reboot.
- **OS-5 Health + auto-rollback + `confirm`:** unify confirm (`swupdate confirm`),
  optional auto-confirm when sshd+nginx are up; rely on existing loader/kernel
  attempt-rollback for the no-boot case; verify the no-boot rollback end-to-end.
- **OS-6 `make os-update-test`** (QEMU) **+ real-Hetzner runbook** and Console check.

## Open decisions (need a call before OS-1/OS-3)

1. **Coordinated selector shape:**
   (a) *Single authority in ESP* — extend `kernel-state` to carry the base slot;
   the loader/kernel read both from it (matches "ONE selector" literally; one
   atomic 512-byte rewrite the loader already does). Recommended.
   (b) *Convention coupling* — keep both stores, have `swupdate os` always
   stage+activate+confirm A/B in lockstep with a two-phase commit + boot recovery.
   Less invasive, but two pointers can still drift on a torn write.

2. **New-kernel sizing:** (a) fixed/padded kernel slots sized to a max (simple,
   wastes ESP space) vs (b) a real FAT32 cluster allocator (general, more code).

3. **Bundle contents:** full kernel+base every time first; add delta later — OK?

## OS-1 design (coordinated selector) — decided + topology finding

**Finding (post OS-2..OS-5):** kernel A/B and base A/B currently live in *disjoint*
topologies — they never coexist, so there was nothing to "coordinate" yet:
- **UEFI/GPT disk-boot** (real-HW path): kernel A/B on the ESP (kernelA/B.bin +
  signed `kernel-boot` + writable `kernel-state`, loader selects + rolls back).
  The base is a **single** `base.img` (a readonly virtio-blk disk, or an ESP
  ramdisk) — **no base A/B**.
- **store-boot** (`-kernel` + virtio-blk SWOSBOOT store): base A/B (OS-2..OS-5).
  Kernel comes via `-kernel` — **no kernel A/B**.

**Decision (chosen): variant B — converge the topologies.** In UEFI-boot, attach
the SWOSBOOT store (OS-2..OS-5) as the base disk, and make the **ESP `kernel-state`
the single A/B authority** that drives both halves. The kernel reads the slot the
loader actually booted (`kernel-state.lastBooted`, *not* `active` — active is the
next-boot selection; lastBooted is what's running) and puts the base on that same
slot. One selector (`kernel-state`, which the loader already owns + rolls back)
moves kernel + base together.

Key constraints discovered:
- `vfsInit()`→`updateStoreInit()` runs *before* `espProbe()`, so the kernel reads
  kernel-state **on demand** (`espBootedKernelSlot()` does the ESP detour), not
  from a probe-populated global.
- **Rollback ownership:** the loader owns health/rollback for the coordinated
  generation (its attempt counter flips the booted kernel slot; the base follows
  on the next boot). So in the coordinated path the kernel only *selects* — it does
  **not** run the standalone U1d attempt-counting/rollback or write the SWOSBOOT
  boot-state. The U1d path stays intact for store-only (no-ESP) boxes.

**Sub-steps:**
- **OS-1a (done):** `espBootedKernelSlot()` + coordinated base selection in
  `updateStoreInit` (Swift-only; no-op without an ESP). Test
  `os_coordinate_test.sh`: under AAVMF, base follows the loader-booted kernel slot
  for both A and B (proving ESP kernel-state is authority over the store's own
  `active`). Store-boot tests unaffected (no ESP).
- **OS-1b (done):** `swupdate os` flips the single ESP selector (kernel_activate)
  when an ESP is present — so kernel + base activate together — else falls back to
  the SWOSBOOT selector on a store-only box. Also fixed the base *read* path
  (`vfsImageReadRange`): when an A/B store is in use the base is read from the
  selected store slot, not the loader's RAM ramdisk (the firmware-staged single
  base.img) — without this the coordinated slot was selected but reads bypassed it.
  Test `os_coordinate_activate_test.sh` (AAVMF + ESP + store, no network): boot ->
  shell -> `swupdate os-apply-local <tiny SWSYS>` -> base staged into slot B + ESP
  selector flipped to B. PASS; OS-1a / store-boot / UEFI-plain-base all still PASS.
  NOT yet done: making `make disk` carry a store base by default (the real-HW image
  layout — deferred to the real-HW batch with the Console check).
- **OS-1c:** new-kernel write into a padded ESP slot (the kernel half of a SWSYS
  bundle), so a single update moves both kernel and base.
- **Real-HW gate:** verify the whole flow on the Hetzner box via Console (QEMU
  can't catch the HW boot/driver bugs — the netPump lesson).

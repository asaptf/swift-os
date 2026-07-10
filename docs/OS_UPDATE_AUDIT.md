# OS self-update (kernel + base image) — Phase 0 audit

Goal: update **SwiftOS itself** (kernel + base image) on a running box, with no
Rescue/live-`dd` — deliver a signed bundle over HTTPS, stage into the inactive
A/B slot, atomically switch, health-confirm, auto-rollback on failure.

This document is the mandatory Phase-0 audit: what of the A/B skeleton is **real**
vs **stub/missing**, before any new code is written.

## TL;DR

The A/B *mechanism* is far more complete than the prompt assumes — both the kernel
(ESP) and the base image (data-disk update store) already have signed slots,
attempt-based rollback, confirm, and full QEMU test coverage. Much of the
**delivery + coordination + anti-rollback** layer has also landed since this audit
opened (OS-1a…OS-1c, OS-2…OS-5 staging paths — see the per-step sections below).

**Still open / product-facing gaps:**

- a single aggregate **OS-6** gate that exercises full trial-boot + rollback
  end-to-end across the coordinated topology (pieces already have per-path tests);
- **real-hardware Console validation** on Hetzner (QEMU cannot catch the
  boot/driver bugs that only appear on Ampere/KVM — the netPump lesson);
- optional polish (delta bundles, streaming verify for very large bases,
  init-driven `confirm --auto` after services come up).

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

## GAPS vs the prompt (original list; status as of OS-1c)

1. ~~**No coordinated boot-selector.**~~ **RESOLVED (OS-1a/1b).** ESP
   `kernel-state.lastBooted` is the single A/B authority; base follows it.
   `swupdate os` flips the ESP selector when present.

2. ~~**No live delivery of a new OS.**~~ **Mostly RESOLVED (OS-1c + OS-2…OS-4).**
   - SWSYS v2 signed bundle carries padded kernel + base (`tools/syspack`).
   - `swupdate os` / `os-apply-local` stream both halves from a file (or HTTPS URL)
     into inactive slots via kernel syscalls — no attached payload disk required
     for the live path.
   - OS-1c: padded ESP slots + `kernel_install_*` install a *new* host-signed
     kernel (not just `swos-kstage` duplicate). `swos-kstage` remains for the
     same-kernel-copy path.
   - Remaining: real-HW Console proof; optional delta bundles.

3. ~~**No monotonic anti-rollback.**~~ **RESOLVED (OS-4 stage path).** Kernel
   enforces `systemVersion` > floor at base stage-begin.

4. ~~**No kernel-mediated "write inactive slot from /data bytes" path.**~~
   **RESOLVED (OS-3 + OS-1c-2b).** Streaming stage for base + kernel install from
   userland buffers (swupdate holds the verified bundle in memory / `/data`).

5. ~~**No unified `confirm` / auto-confirm.**~~ **RESOLVED (OS-5, `f79e1c2`).**
   `swupdate confirm` confirms base (update_confirm) and kernel (kernel_confirm)
   best-effort; `confirm --auto` gates on process-presence of `sshd` + `nginx`.
   Confirm also raises the anti-rollback floor to the confirmed slot's
   `system_version`. Low-level tools (`swos-confirm` / `swos-kconfirm`) remain.
   Gate: `make os-confirm-test`. Attempt-based no-boot rollback stays on the
   existing U1d / UEFI loader paths (`ab_rollback_test`, `uefi_krollback_test`).

6. **Aggregate e2e + real-hardware validation** still open. Per-path QEMU tests
   exist; a single full trial-boot→confirm/rollback story across the coordinated
   topology and — critically — live Hetzner Console checks are **OS-6**.

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
- **OS-5 Health + auto-rollback + `confirm`:** DONE (`f79e1c2`) — see GAPS §5.
  `swupdate confirm` / `confirm --auto`; floor bump; `make os-confirm-test`.
  No-boot rollback covered by existing U1d / UEFI attempt-rollback tests.
- **OS-6 aggregate e2e + real-Hetzner runbook** and Console check (remaining).

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
  **OS-1b-Hetzner (done):** `make hetzner-deploy-build` now also emits
  `build/hetzner-update-store.img` (SWOSBOOT, both slots = prod `base.img`,
  active A) and records it in the deploy manifest. Opt-in gate
  `make hetzner-os-update-test` boots the Hetzner-faithful QEMU profile (virtio-
  gpu + NIC/RNG behind PCIe root ports; GPT on virtio-blk-pci + virtio-blk-pci
  store; `sshd-supervised` only) and proves headless `swupdate os-apply-local`
  over SSH stages the base + flips the ESP selector. (Production boots scsi; QEMU
  uses blk-pci for ESP kernel-state I/O.) Real-HW Console check still pending.
- **OS-1c (done):** new-kernel write into a padded ESP slot so one SWSYS bundle
  moves kernel + base. Landed as OS-1c-1 … OS-1c-3b:
  - **OS-1c-1:** `SWOSKERN` manifest **v4** — independent per-slot Ed25519
    signatures (`"SWOSKSLT" || u32 index || u64 size || sha256`), bound to the
    slot index so a slot-A entry cannot be replayed into slot B. Loader +
    `tools/kernelboot.swift` + host packer agree on the message format.
  - **OS-1c-2a:** fixed-size **padded** ESP slots (`KERNEL_SLOT_BYTES` = 4 MiB).
    Both `kernelA.bin` / `kernelB.bin` are the same length; in-place install
    needs no FAT allocator. Same-size constraint that blocked different-size
    kernels is gone by construction.
  - **OS-1c-2b:** streamed install of a *genuinely new* host-signed kernel into
    the inactive slot — syscalls `kernel_install_{begin,write,commit,abort}`
    (112–115), `/bin/swos-kinstall`, kernel re-hash + per-slot sig verify before
    writing the 104-byte manifest entry; flush slot bytes *before* the entry
    (power-fail safe). Gate: `make uefi-kinstall-test`.
  - **OS-1c-3a:** SWSYS bundle **format v2** carries the padded kernel + a full
    v4 `SWOSKERN` manifest (both slot entries cover the same image so install
    works for whichever slot is inactive). Host: `tools/syspack.swift`.
  - **OS-1c-3b:** `swupdate os` / `os-apply-local` installs **both** halves:
    base → inactive SWOSBOOT slot, kernel → inactive ESP slot (entry sliced from
    the bundle manifest), then one ESP selector flip. Store-only (no ESP):
    kernel half skipped (`ENODEV`). Gate: `make uefi-os-install-test`.
  - **OS-1c arc complete.** A single signed SWSYS bundle can move kernel + base
    together on the coordinated topology. Remaining OS work is outside 1c:
    health/auto-confirm (OS-5), full `os-update-test` + real-HW Console gate
    (OS-6 / Hetzner).
- **Real-HW gate (still open):** verify the whole OS-1 flow on the Hetzner box
  via Console (QEMU cannot catch the HW boot/driver bugs — the netPump lesson).

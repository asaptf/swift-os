# A/B Update Store (SWOSBOOT)

The update store is swift-os's persistent, writable storage layer for whole-system
A/B image updates, per ARCHITECTURE.md §"Persistent update store" and the
"A/B image discipline" design value. It is a *narrow* storage layer — no
filesystem, no journaling, no free-space management — carried on a dedicated
writable virtio-blk disk, separate from the read-only base-image disk.

U1a (this document) implements the **read side**: a boot manifest, two image
slots, and manifest-driven, signature-verified slot selection with fallback to
the known-good slot. Boot-state write-back (attempt counter, health confirm,
attempt-based rollback) and kernel-image A/B are later sub-milestones.

## Disk layout

```text
LBA 0      SWOSBOOT manifest, copy 0
LBA 1      SWOSBOOT manifest, copy 1   (double-buffered; reader picks the valid
                                        copy with the highest sequence number)
LBA 2..7   reserved (manifest region padded to 4 KiB)
LBA 8      slot 0 image  (a full signed SWOSBASE-v3 base image)
LBA 8+|A|  slot 1 image
```

Each slot holds a complete base image — the same artifact `basepack` produces —
so the kernel mounts and verifies a slot through the unchanged I8 path. The
store tool neither signs nor hashes the slots; **slot authenticity rides on each
image's own Ed25519 signature**.

## Manifest format (SWOSBOOT v1)

Exactly one 512-byte sector, stored in two copies. All integers little-endian.

```text
0    u8[8]  magic = "SWOSBOOT"
8    u32    version = 1
12   u32    flags (reserved, 0)
16   u32    slot_count (2)
20   u32    active_slot   (0 or 1)
24   u32    fallback_slot (0 or 1)
28   u32    sequence      (monotonic; higher wins among valid copies)
32   slot[0] (48 bytes)
80   slot[1] (48 bytes)
...  reserved zeros ...
508  u32    crc32 over bytes [0, 508)
```

Slot entry (48 bytes):

```text
+0   u32    present (1/0)
+4   u32    state   (0 untried, 1 confirmed, 2 failed)   — boot-state, U1b
+8   u64    base_lba         (sector offset of the slot's SWOSBASE image)
+16  u64    length_sectors   (slot image length in sectors)
+24  u32    generation
+28  u32    attempt_count                                — boot-state, U1b
+32  u8[16] reserved
```

The format core (parser + CRC32) is `kernel/fs/swosboot.swift`: I/O-free, no
mutable global state, compiled into both the kernel (Embedded Swift) and the
host tools/tests, so the bytes the host writes are exactly what the kernel
parses. CRC32 is the IEEE 802.3 reflected variant (poly `0xEDB88320`); the
canonical check value `crc32("123456789") == 0xCBF43926` is pinned by
`tests/updatestore_test.swift`.

## Trust boundary

The manifest is **CRC32-protected, not signed**. The kernel holds only the
*public* image-signing key, so it cannot sign the boot-state it will write at
runtime (U1b). This is sound: the manifest is not a trust anchor — it only
*selects among* self-authenticating signed images. A store-disk attacker can at
worst point `active_slot` at the other (still-signed) slot or induce a boot
loop, i.e. an availability/DoS concern, never a code-integrity bypass — a forged
or tampered image still fails its Ed25519 verification at mount. This matches the
trust posture the base-image disk already has.

## Boot flow

1. `virtioBlkInit` selects the disk, preferring a SWOSBOOT update-store disk over
   a bare SWOSBASE base disk over the first block device.
2. `updateStoreInit()` (called at the top of `vfsInit`) reads both manifest
   copies, picks the valid one with the highest sequence, selects the active
   slot, and points base-image reads at it (`virtioBlkSetBaseByteOffset`),
   recording the fallback slot's offset.
3. `vfsInit` mounts the active slot via the existing signed-image path. If the
   active slot's image fails its Ed25519 signature or per-file content hash, the
   kernel switches to the fallback slot (`virtioBlkUseFallbackBase`) and remounts
   the known-good image.

## Building a store image

```sh
make updatestore
build/updatestore <out.img> <active:A|B> <slot-A-image> <slot-B-image>
```

For example, an active-slot-A store from the current base image:

```sh
build/updatestore build/store.img A build/base.img build/base.img
```

Attach it to QEMU as a writable virtio-blk disk (no `readonly=on`):

```sh
-drive file=build/store.img,format=raw,if=none,id=swosstore \
-device virtio-blk-device,drive=swosstore
```

`tests/ab_update_test.sh` exercises slot selection (A and B) and verified
fallback (a tampered active slot rolls back to the known-good slot).

## Persistent boot-state (U1b)

The manifest is writable on disk. At boot, after selecting the active slot, the
kernel increments that slot's `attempt_count`, bumps `sequence`, and writes the
manifest to the *other* double-buffer copy (LBA 0 ↔ LBA 1). Because the reader
always picks the valid copy with the highest sequence, a write interrupted
mid-flight leaves the previous copy intact — torn-write safe without journaling.
`virtioBlkWriteSector` issues a `VIRTIO_BLK_T_OUT` to the manifest's absolute LBA
(outside the A/B slots, so it bypasses the slot offset). `tests/ab_persist_test.sh`
boots the same store 3× and asserts the counter persists 1→2→3 across reboots.

## Health-confirm (U1c)

An operator confirms a freshly-activated slot healthy by running
`/bin/swos-confirm` (capConsole-gated; root yes, guest EPERM). It calls
`SYS_UPDATE_CONFIRM` (60) → `updateStoreConfirm()`, which marks the slot booted
this session (tracked in `updateStoreActiveSlot`) `CONFIRMED` and resets its
attempt counter, persisted via the same double-buffered write-back. A CONFIRMED
slot is trusted: `updateStoreInit` stops recording boot attempts for it and
never rolls it back (see below). `tests/ab_confirm_test.sh` confirms a slot from
a shell and verifies the state persists across a reboot with no new attempt
recorded.

## Attempt-based rollback (U1d)

`updateStoreInit` decides, before committing to a slot: if the active slot is not
`CONFIRMED` and its `attempt_count` has reached `maxBootAttempts` (3) and a
distinct present fallback exists, the slot is presumed unhealthy — it booted but
was never confirmed. The kernel marks it `FAILED`, swaps active↔fallback in the
manifest, and boots the fallback, persisting the swap with the same write-back.
This is the "boots but never confirmed" failover; a bad *image* (signature or
content verification failure) is caught earlier, at mount time in `vfsInit`
(U1a). `tests/ab_rollback_test.sh` boots an unconfirmed slot until its attempts
are exhausted and asserts the failover to the fallback persists across reboots.

The read + write + confirm + rollback halves of A/B are now complete.

## Promote the inactive slot (U1e)

`/bin/swos-activate` (capConsole-gated; root yes, guest EPERM) calls
`SYS_UPDATE_ACTIVATE` (61) → `updateStoreActivateOther()`, which makes the
inactive slot the active slot for the next boot (the current slot becomes the
fallback) and marks it UNTRIED with its attempt counter reset, so it boots "on
trial" under U1d's rollback. The full operator promotion workflow, for slots that
already hold images: activate → reboot → boots on trial → `/bin/swos-confirm` if
healthy, else attempt-based rollback returns to the fallback.
`tests/ab_activate_test.sh` activates from a shell and verifies slot B is active
and on trial after a reboot.

## Update payload disk (U1f-1)

The chosen image source for staging from a running system is a **read-only
payload disk** — a second virtio-blk disk holding a signed SWOSBASE image,
attached alongside the store. `virtioBlkInit` classifies every block device by
its sector-0 magic and records such a disk as the payload (`blkPayloadMmio`); the
single-device hardware path reaches it by re-bringing-up between the store and
the payload (`virtioBlkSelectPayload` / `virtioBlkReselectStore`), which is safe
because I/O is serial on the one CPU. At boot `updateStorePayloadProbe()` reads
the payload header and confirms it is a signed v3 base image.
`tests/ab_payload_test.sh` covers discovery + read.

## Multi-sector transfers (U1f-2a)

The virtio-blk driver moved one 512-byte sector per request — too slow to copy a
multi-MB image under TCG. U1f-2a adds a variable-length data descriptor so one
request transfers up to 128 consecutive sectors (64 KiB) through a contiguous DMA
region (`blkMultiBase`). `virtioBlkReadRange` (which backs every base-image read)
now pulls whole sector runs per request; the base image's own Ed25519 signature
and per-file content hashes end-to-end verify the path. New no-copy primitives
(`virtioBlkFillMulti` / `virtioBlkFlushMulti`) let U1f-2b copy disk-to-disk
through the driver's own buffer without an intermediate kernel copy.
`tests/multisector_test.sh` proves byte-exact reads across the signed metadata, a
payload file, and a ~1.1 MB busybox ELF.

## Stage the payload into the inactive slot (U1f-2b)

`/bin/swos-update` (capConsole-gated; root yes, guest EPERM) calls
`SYS_UPDATE_STAGE` (62) → `updateStoreStagePayload()`, which copies the attached
read-only payload disk (a signed SWOSBASE image, U1f-1) into the **inactive**
slot. It reads the payload's header, requires a signed v3 image, and rejects one
that is truncated on disk (EINVAL) or larger than the slot's `length_sectors`
(EFBIG). The copy moves 64 KiB runs disk-to-disk through the driver's own
multi-sector DMA buffer (U1f-2a's `virtioBlkFillMulti`/`FlushMulti`) with no
intermediate kernel buffer, then marks the slot present + UNTRIED, attempts 0,
generation++ via the same double-buffered write-back. It copies **bytes only** —
the staged image's own Ed25519 signature is verified at the next boot's mount, so
a corrupt payload simply fails on trial and rolls back (U1a/U1d) to the
known-good slot.

The full operator update workflow is now: `swos-update` (stage) → `swos-activate`
(promote) → reboot (boots on trial) → `swos-confirm` if healthy, else
attempt-based rollback returns to the fallback. `tests/ab_stage_test.sh` stages a
valid payload over a deliberately-corrupt inactive slot and asserts the slot
verifies and boots after activate + reboot.

## Durable writes via FLUSH (U1h)

The kernel negotiates `VIRTIO_BLK_F_FLUSH` at bring-up and calls
`virtioBlkFlush()` (a `VIRTIO_BLK_T_FLUSH` request) after every commit:
`updateStoreWriteBack` flushes the manifest sector (and fails the write-back if
the flush is rejected), and `updateStoreStagePayload` flushes the staged slot
data before pointing the manifest at it. Boot-state is therefore durable under a
normal write-back cache, without depending on a `cache=writethrough` host
backend. `updateStoreInit` logs "write durability via virtio FLUSH".
`tests/ab_flush_test.sh` proves the path with the default write-back cache.

## Kernel-image A/B via the loader (U1g, in progress)

The base-image A/B above covers the userland/system image. The kernel image
itself is A/B'd through the UEFI loader, which is being built in slices.

- **U1g-1 (done):** the loader reads the kernel from a file on the ESP via
  `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL` instead of an embedded blob, decoupling the
  kernel image from the loader binary (a prerequisite for A/B). The embedded blob
  remains as a fallback.
- **U1g-2 (done):** the loader reads a **SWOSKERN** boot manifest
  (`\EFI\swift-os\kernel-boot`: magic, version, active/fallback slot, generation)
  and loads the active slot (`kernelA.bin` / `kernelB.bin`), rolling back to the
  fallback slot when the active file is missing/unopenable.
- **U1g-3a (done):** SWOSKERN **v2** carries each slot's SHA-256; the loader
  hashes the loaded image and rolls back to the other slot on a mismatch
  (integrity, catching a corrupt/truncated kernel). SHA-256 in the loader is
  host-tested (`tests/loader_sha256_test.c`).
- **U1g-3b (done):** SWOSKERN **v3** appends a 64-byte Ed25519 signature over the
  manifest body; the loader verifies it against its compiled-in image-signing key
  (`boot/efi/efi_pubkey.S`, the same root the kernel embeds) and honors the
  manifest only if the signature is valid — otherwise it boots its own embedded
  blob, never an attacker-chosen slot. Ed25519+SHA-512 verify in the loader is a
  host-tested C port of the kernel's Swift crypto (`tests/loader_ed25519_test.c`,
  RFC 8032 vectors). `tests/uefi_kernel_ab_test.sh` adds a tampered-signature case.
  Signing stays host-side (`tools/kernelboot.swift`). The kernel-image A/B trust
  chain (sign → verify → integrity → fallback) is complete.

- **U1g-4a (done):** runtime-staging foundation. The ESP/GPT boot disk is now on
  virtio-mmio (not PCI) so the running kernel can reach it; the virtio-blk scan
  recognizes it by the "EFI PART" GPT magic, and `kernel/fs/esp.swift` parses the
  GPT to locate the ESP partition at boot. Trust model decided: runtime staging
  follows U1f's courier model (the OS writes pre-signed artifacts; it never signs).
- **U1g-4b (done):** a minimal read-only FAT32 in `kernel/fs/esp.swift` (BPB,
  cluster chains, LFN/8.3 directory walk) reads the signed `kernel-boot` manifest
  off the ESP and reports the active slot — the read half of runtime staging.
- **U1g-4c (done):** the FAT32 *write* half. `/bin/swos-kstage` (syscall 63,
  capConsole) has the kernel copy the active kernel image over the inactive slot
  in place (same-size, no FAT/dir changes) and verify it sector-by-sector. Safe:
  a bad write only spoils the inactive slot, which the loader's hash check rejects.
- **U1g-4d (done):** the activate flow. `/bin/swos-kactivate` (syscall 64,
  capConsole) installs the pre-signed alternate manifest (`kernel-boot-alt`,
  active = other slot, signed offline at build) over `kernel-boot` on the ESP. On
  reboot the loader verifies it and boots the new slot. The OS never signs — it
  courier-copies an already-signed manifest. **Kernel-image A/B is now complete
  end-to-end** (operator flow: `swos-kstage` → `swos-kactivate` → reboot),
  mirroring the system-image U1f flow.

- **U1g-5a (done):** the writable boot-state half of the signed-selection split.
  The loader records a per-slot boot-attempt counter in a hash-protected
  `\EFI\swift-os\kernel-state` file (its first EFI write; self-managed, created on
  first boot), persisted across reboots. Kernel images stay independently signed,
  so the boot-state is only hash-guarded (torn-write protection), not signed.
  `tests/uefi_kattempt_test.sh` asserts the counter persists 1→2→3.

- **U1g-5b (done):** attempt-based kernel rollback (the U1d analogue). The loader
  reads the boot-attempt counter; an unconfirmed active slot that has exhausted
  its attempts (≥3) is presumed unhealthy → the loader boots the other slot and
  marks the original FAILED, persisted. `tests/uefi_krollback_test.sh` drives slot
  A to exhaustion and asserts the fail-over to slot B.

## Not implemented yet

- U1g-5c: `/bin/swos-kconfirm` (mark booted slot CONFIRMED so it stops accruing
  attempts) + move `active` into the writable boot-state (so activate needs no
  pre-signed alternate manifest).
- A real new-kernel *payload* source (today both kernel slots are the same build).
- Key rotation / revocation.
- Key rotation / revocation.

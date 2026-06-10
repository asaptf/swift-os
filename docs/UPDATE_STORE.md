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

## Not implemented yet

- Attempt-based rollback: switch active↔fallback when an unconfirmed slot exceeds
  a max-attempts threshold (U1c).
- Health confirm: a capability-gated `/bin/swos-confirm` + syscall that marks the
  active slot CONFIRMED and resets its attempt counter (U1c).
- Staging a new generation into the inactive slot + atomic active-slot flip (U1c).
- Kernel-image A/B via the loader (Ed25519 + EFI Block I/O in the loader).
- virtio-blk FLUSH (durability without `cache=writethrough`); key rotation /
  revocation.

# A/B Update Store (SWOSBOOT)

The update store is SwiftOS's checked persistent update lane for whole-system
image updates. It is intentionally narrow: no filesystem, no journal, no package
database, and no mutable root. A dedicated writable virtio-blk disk carries two
complete signed base-image slots, while the UEFI ESP carries the equivalent
kernel-image slots. The design keeps update state writable but keeps executable
code self-authenticating.

Use this reference when you need to build an update-store image, reason about
rollback, inspect the on-disk format, or connect the operator commands to the
kernel and loader implementation. Use [Update And Rollback Guide](UPDATE_GUIDE.md)
for the day-to-day runbook.

## Current Capability

SwiftOS has two checked update planes:

| Plane | Storage | Selector | Runtime commands | Current status |
| --- | --- | --- | --- | --- |
| Base image | Writable SWOSBOOT virtio-blk store | CRC-protected SWOSBOOT manifest, with signed SWOSBASE images in each slot | `swos-update`, `swos-activate`, `swos-confirm` | Staging, activation, health confirmation, boot-attempt rollback, and FLUSH-backed durability are implemented |
| Kernel image | UEFI ESP under `\EFI\swift-os` | Signed `kernel-boot` metadata plus hash-protected `kernel-state` boot state | `swos-kstage`, `swos-kactivate`, `swos-kconfirm` | Signed manifest verification, in-place staging, activation, health confirmation, attempt counting, and rollback are implemented |

The update store is a validation-grade product path, not a networked OTA
service. Artifacts are built and signed on the host. The running OS can courier
already-signed bytes into an inactive slot and update boot state, but it never
signs new trusted code.

## Choose An Update-Store Workflow

Pick the update plane first, then collect the state that proves activation,
confirmation, or rollback behaved as expected.

| Task | Plane | Operator commands | Focused proof | Evidence to keep |
| --- | --- | --- | --- | --- |
| Stage and activate a new base image | SWOSBOOT base-image slots | `swos-update`, `swos-activate`, reboot | `./tests/ab_stage_test.sh`, `./tests/ab_activate_test.sh` | Store image, payload image, stage/activate output |
| Confirm a healthy base-image trial | SWOSBOOT base-image slots | `swos-confirm` after the trial boot | `./tests/ab_confirm_test.sh` | Trial boot serial log and confirm output |
| Prove base-image rollback | SWOSBOOT base-image slots | Leave a trial unconfirmed or stage a bad image in the test harness | `./tests/ab_rollback_test.sh` | Attempt-count markers and fallback boot log |
| Prove store durability | SWOSBOOT base-image slots | Let the test harness force FLUSH-backed state writes | `./tests/ab_flush_test.sh` | Manifest sequence/slot state from test output |
| Stage and activate a kernel slot | UEFI ESP kernel slots | `swos-kstage`, `swos-kactivate`, reboot through UEFI | `./tests/uefi_kstage_test.sh`, `./tests/uefi_kactivate_test.sh` | ESP disk image, loader log, command output |
| Confirm the booted kernel slot | UEFI ESP kernel slots | `swos-kconfirm` after UEFI trial boot | `./tests/uefi_kconfirm_test.sh` | `kernel-state` context and confirm output |
| Prove kernel-slot rollback | UEFI ESP kernel slots | Leave a kernel trial unconfirmed in the test harness | `./tests/uefi_kattempt_test.sh`, `./tests/uefi_krollback_test.sh` | Loader attempt lines and selected slot marker |
| Debug the on-disk format | SWOSBOOT parser or kernel-state parser | Host tests and targeted inspection | `tests/updatestore_test.swift`, `./tests/uefi_kernel_ab_test.sh` | Serialized manifest or loader state excerpt |

## Guarantees

- Code integrity comes from signed artifacts: SWOSBASE v3 for base-image slots
  and signed SWOSKERN v3 metadata plus slot hashes for kernel slots.
- Mutable boot state is not a trust anchor. It can select among trusted slots,
  record attempts, and mark health, but it cannot make an unsigned image valid.
- Base-image manifest writes are double-buffered. The reader chooses the valid
  copy with the highest sequence number, so an interrupted manifest write leaves
  the previous copy usable.
- Store writes are flushed with `VIRTIO_BLK_F_FLUSH` when available. The kernel
  flushes staged slot bytes before publishing a manifest that points at them.
- Trial slots roll back automatically after three unconfirmed boot attempts.
- A confirmed slot stops accruing attempts and is not rolled back by the
  attempt counter.

## Base-Image Operator Flow

Build the base image and the host store builder:

```sh
make base-image updatestore
```

Create a two-slot store image. This example starts on slot A and uses the same
signed image in both slots:

```sh
build/updatestore build/store.img A build/base.img build/base.img
```

Attach the store as a writable virtio-blk disk:

```sh
-drive file=build/store.img,format=raw,if=none,id=swosstore \
-device virtio-blk-device,drive=swosstore
```

For a target-side update, also attach a read-only payload disk containing a
signed SWOSBASE v3 image. From a root shell in the guest:

```sh
swos-update
swos-activate
```

Reboot the same store disk. The newly activated slot boots on trial. If the
system is healthy, confirm the slot:

```sh
swos-confirm
```

If the trial slot fails signature or content verification, the kernel falls back
to the known-good slot during mount. If the trial slot boots but is never
confirmed, the boot-attempt counter reaches three and the next boot rolls back
to the fallback slot.

## Kernel-Image Operator Flow

Kernel-image A/B is handled by the UEFI loader and the ESP. The signed
`\EFI\swift-os\kernel-boot` file authenticates slot metadata and SHA-256 hashes
for `kernelA.bin` and `kernelB.bin`. Mutable selection lives in
`\EFI\swift-os\kernel-state`.

From a root shell in the guest, stage and activate the inactive kernel slot:

```sh
swos-kstage
swos-kactivate
```

Reboot the same writable UEFI disk. The loader reads `kernel-state`, selects the
trial slot, verifies the selected kernel image against the signed manifest, and
records a boot attempt. After a healthy boot, confirm the slot:

```sh
swos-kconfirm
```

An unconfirmed kernel slot rolls back after three attempts. `kernel-boot-alt` is
no longer part of the current flow; activation updates `kernel-state` instead of
rewriting the signed `kernel-boot` manifest.

## Base-Image Store Layout

The SWOSBOOT disk is a raw virtio-blk image.

```text
LBA 0      SWOSBOOT manifest, copy 0
LBA 1      SWOSBOOT manifest, copy 1
LBA 2..7   reserved; manifest region padded to 4 KiB
LBA 8      slot 0 image, a full signed SWOSBASE v3 base image
LBA 8+|A|  slot 1 image, a full signed SWOSBASE v3 base image
```

Each slot holds the same kind of artifact produced by `basepack`. The store tool
does not sign or hash slot contents; slot authenticity comes from each image's
own Ed25519 signature and per-file content hashes.

`virtioBlkInit` prefers a SWOSBOOT store disk over a bare SWOSBASE disk when
both are attached. If both manifest copies are invalid, `updateStoreInit()` logs
the failure and leaves base reads at sector 0.

## SWOSBOOT Manifest Format

The manifest is exactly one 512-byte sector, stored in two copies. All integers
are little-endian.

```text
0    u8[8]  magic = "SWOSBOOT"
8    u32    version = 1
12   u32    flags; reserved, zero
16   u32    slot_count = 2
20   u32    active_slot; 0 or 1
24   u32    fallback_slot; 0 or 1
28   u32    sequence; higher wins among valid copies
32   slot[0]; 48 bytes
80   slot[1]; 48 bytes
...  reserved zeros
508  u32    CRC32 over bytes [0, 508)
```

Slot entry:

```text
+0   u32    present; 1 or 0
+4   u32    state; 0 untried, 1 confirmed, 2 failed
+8   u64    base_lba; sector offset of the slot's SWOSBASE image
+16  u64    length_sectors; slot capacity in sectors
+24  u32    generation
+28  u32    attempt_count
+32  u8[16] reserved
```

The shared parser, serializer, and CRC32 implementation live in
`kernel/fs/swosboot.swift`. That file is I/O-free and is compiled into the
kernel, host tool, and host tests. The CRC32 variant is IEEE 802.3 reflected
polynomial `0xEDB88320`; `tests/updatestore_test.swift` pins the canonical
`crc32("123456789") == 0xCBF43926` check.

## Manifest Selection And Write-Back

At boot the kernel reads both manifest copies and chooses the valid copy with
the highest sequence number.

When it must update boot state, the kernel serializes a fresh manifest and
writes it to the other copy:

```text
chosen copy LBA 0 -> write LBA 1
chosen copy LBA 1 -> write LBA 0
```

The updated manifest receives a new sequence number and CRC. A torn write leaves
the older copy valid. After a successful write, the kernel issues a virtio-blk
FLUSH when supported.

The manifest is CRC-protected, not signed. This is deliberate. The kernel only
has the public image-signing key, so it cannot sign mutable boot state at
runtime. A modified manifest can at worst choose another already-signed slot or
cause an availability failure; it cannot make forged code pass signature
verification.

## Base-Image Boot Flow

1. `virtioBlkInit` classifies attached block devices and selects the SWOSBOOT
   store when present.
2. `updateStoreInit()` reads both manifest copies and chooses the newest valid
   copy.
3. If the active slot is unconfirmed and its `attempt_count` is already three or
   higher, the kernel marks it failed, swaps active and fallback, and persists
   the rollback.
4. The kernel points base-image reads at the selected slot with
   `virtioBlkSetBaseByteOffset`.
5. If a distinct fallback slot is present, the kernel records its byte offset.
6. `vfsInit` mounts the selected SWOSBASE image through the normal signed-image
   path.
7. If the selected image fails Ed25519 or content-hash verification, `vfsInit`
   switches to the fallback slot and retries the mount.
8. If the selected slot is not confirmed, the kernel records one boot attempt
   and persists it through the double-buffered manifest write-back.

## Base-Image Runtime Commands

The base-image commands require `capConsole` and are normally run as `root`.

| Command | Syscall | Effect | Success line | Coverage |
| --- | --- | --- | --- | --- |
| `swos-update` | `SYS_UPDATE_STAGE` 67 | Copy the attached signed SWOSBASE payload disk into the inactive slot, mark it present and untried, and bump its generation | `swos-update: payload staged into the inactive slot; run swos-activate then reboot` | `tests/ab_stage_test.sh` |
| `swos-activate` | `SYS_UPDATE_ACTIVATE` 66 | Promote the inactive slot for the next boot and make the current slot the fallback | `swos-activate: inactive slot activated (on trial); reboot to use it` | `tests/ab_activate_test.sh` |
| `swos-confirm` | `SYS_UPDATE_CONFIRM` 65 | Mark the slot booted this session confirmed and reset its attempt counter | `swos-confirm: active slot confirmed healthy` | `tests/ab_confirm_test.sh` |

`swos-update` copies bytes only. It validates that the payload disk contains a
signed SWOSBASE v3 header and that the image fits the inactive slot, but the
staged image is fully verified on the next boot. A corrupt staged payload should
therefore fail safely during the trial boot.

## Payload Disk Rules

The payload disk is a separate read-only virtio-blk disk. It is attached beside
the writable store.

At boot, `updateStorePayloadProbe()` reports whether the payload disk contains a
signed SWOSBASE v3 image. During `swos-update`, the kernel copies the payload
into the inactive slot using the virtio-blk multi-sector path:

- up to 128 sectors per request, or 64 KiB per transfer
- no intermediate heap buffer
- payload disk selected for reads, store disk reselected for writes
- FLUSH after staged slot data, before the manifest points at it

Expected error cases:

| Condition | Result |
| --- | --- |
| No update-store boot | `ENODEV` |
| No payload disk | `ENODEV` |
| Payload is not signed SWOSBASE v3 | `EINVAL` |
| Payload is truncated on disk | `EINVAL` |
| Payload is larger than the inactive slot | `EFBIG` |
| Disk read, write, verify, or flush failure | `EIO` |

## Kernel-Image ESP Format

Kernel-image A/B lives under the ESP directory `\EFI\swift-os`:

```text
\EFI\swift-os\kernelA.bin
\EFI\swift-os\kernelB.bin
\EFI\swift-os\kernel-boot
\EFI\swift-os\kernel-state
```

`kernel-boot` is a signed SWOSKERN v3 manifest built by `tools/kernelboot.swift`:

```text
0    u8[8]  magic = "SWOSKERN"
8    u32    version = 3
12   u32    default active slot; 0 or 1
16   u32    default fallback slot; 0 or 1
20   u32    generation
24   u64    slot A byte size
32   u8[32] slot A SHA-256
64   u64    slot B byte size
72   u8[32] slot B SHA-256
104  u8[64] Ed25519 signature over bytes [0, 104)
```

The loader ignores unsigned or badly signed manifests and boots its embedded
fallback kernel blob instead of trusting attacker-chosen slot metadata.

`kernel-state` is a self-managed 512-byte loader record:

```text
0    u8[8]  magic = "SWOSKSTA"
8    u32    version = 1
12   u32    sequence
16   u32    attempt A
20   u32    attempt B
24   u32    state A; 0 untried, 1 confirmed, 2 failed
28   u32    state B; 0 untried, 1 confirmed, 2 failed
32   u32    last booted slot, or 0xFFFFFFFF
36   u32    active slot, or 0xFFFFFFFF to use `kernel-boot` default
40..479     reserved
480  u8[32] SHA-256 over bytes [0, 480)
```

`kernel-state` is not signed. The SHA-256 protects against torn or garbage
writes; the selected kernel image is still checked against the signed
`kernel-boot` hashes before handoff.

## Kernel-Image Runtime Commands

The kernel-image commands require `capConsole` and a writable UEFI ESP disk.

| Command | Syscall | Effect | Success line | Coverage |
| --- | --- | --- | --- | --- |
| `swos-kstage` | `SYS_KERNEL_STAGE` 68 | Copy the active ESP kernel image into the inactive kernel slot in place and verify the copy | `swos-kstage: active kernel image staged into the inactive ESP slot (verified)` | `tests/uefi_kstage_test.sh` |
| `swos-kactivate` | `SYS_KERNEL_ACTIVATE` 69 | Set the inactive slot as active in `kernel-state`, reset its attempt counter, and mark it untried | `swos-kactivate: inactive kernel slot activated; reboot to use it` | `tests/uefi_kactivate_test.sh` |
| `swos-kconfirm` | `SYS_KERNEL_CONFIRM` 70 | Mark the kernel slot booted by the loader confirmed in `kernel-state` | `swos-kconfirm: booted kernel slot confirmed healthy` | `tests/uefi_kconfirm_test.sh` |

The loader owns attempt counting and rollback. On each boot it reads
`kernel-state`, resolves the active slot, applies the three-attempt rollback
rule, verifies the selected kernel file against the signed manifest hash, writes
back boot state, and then hands off to the kernel.

## Verification Matrix

Run the narrowest relevant proof for the area you changed.

| Area | Command |
| --- | --- |
| SWOSBOOT parser, serializer, CRC32 | Targeted host check below; `make test` also runs it |
| Host store builder | `make updatestore` |
| Base slot selection and bad-image fallback | `./tests/ab_update_test.sh` |
| Persistent boot-attempt write-back | `./tests/ab_persist_test.sh` |
| Base health confirmation | `./tests/ab_confirm_test.sh` |
| Base attempt-based rollback | `./tests/ab_rollback_test.sh` |
| Base slot activation | `./tests/ab_activate_test.sh` |
| Payload disk discovery | `./tests/ab_payload_test.sh` |
| Multi-sector disk reads | `./tests/multisector_test.sh` |
| Payload staging into inactive base slot | `./tests/ab_stage_test.sh` |
| FLUSH-backed durability | `./tests/ab_flush_test.sh` |
| Signed kernel manifest, slot hashes, loader fallback | `./tests/uefi_kernel_ab_test.sh` |
| Kernel slot staging | `./tests/uefi_kstage_test.sh` |
| Kernel active-slot selection | `./tests/uefi_kactivate_test.sh` |
| Kernel attempt persistence | `./tests/uefi_kattempt_test.sh` |
| Kernel health confirmation | `./tests/uefi_kconfirm_test.sh` |
| Kernel attempt-based rollback | `./tests/uefi_krollback_test.sh` |

For documentation-only changes, always run:

```sh
make docs-test
```

For a host-only SWOSBOOT format check:

```sh
/usr/bin/swiftc tests/updatestore_test.swift kernel/fs/swosboot.swift -o build/updatestore_test
build/updatestore_test
```

## Troubleshooting

`swos-update` returns `ENODEV`.

: Booted without a SWOSBOOT store, without the payload disk, or from a profile
  that did not classify those virtio-blk devices. Rebuild `build/updatestore`,
  attach the writable store, and attach a signed SWOSBASE payload disk.

`swos-update` returns `EINVAL`.

: The payload disk is not a signed SWOSBASE v3 image, or the disk is shorter
  than the length advertised by its header.

`swos-update` returns `EFBIG`.

: The payload image is larger than the inactive slot. Recreate the store with
  larger slot images so the inactive slot has enough sector capacity.

The base image keeps rolling back.

: The trial slot either fails signed-image verification or boots but is never
  confirmed. Run `swos-confirm` only after the trial boot is healthy.

`swos-kactivate` appears to succeed, but the next boot stays on the same kernel.

: Reboot the same writable UEFI disk image. Activation is stored in
  `\EFI\swift-os\kernel-state`; booting a fresh disk image discards that state.

The loader ignores `kernel-boot`.

: The manifest is absent, malformed, not version 3, or has an invalid Ed25519
  signature. The safe behavior is to boot the loader's embedded kernel blob
  instead of trusting unverified slot metadata.

## Current Limits

- There is no network OTA service or target-side downloader.
- There is no target-side signer. Signing remains a host/release operation.
- Kernel runtime staging currently copies the active kernel image into the
  inactive slot; a real new-kernel payload source is still future work.
- Key rotation and revocation are not implemented yet.
- The package manager has its own package-store and repository formats; package
  transaction rollback is separate from this whole-image A/B path.
- The writable root remains RAM-backed. `/tmp` does not survive reboot.

## Source Of Truth

- Base-image manifest format: `kernel/fs/swosboot.swift`
- Base-image kernel I/O glue: `kernel/fs/updatestore.swift`
- Store builder: `tools/updatestore.swift`
- Kernel manifest builder: `tools/kernelboot.swift`
- UEFI loader selection and kernel-state write-back: `boot/efi/loader.c`
- Runtime ESP staging and confirmation: `kernel/fs/esp.swift`
- User commands: `userland/swos-update.swift`, `userland/swos-activate.swift`,
  `userland/swos-confirm.swift`, `userland/swos-kstage.swift`,
  `userland/swos-kactivate.swift`, `userland/swos-kconfirm.swift`

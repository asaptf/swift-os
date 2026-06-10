// SPDX-License-Identifier: Apache-2.0
// updatestore.swift — kernel I/O glue for the A/B update store (U1a).
//
// Reads the SWOSBOOT boot manifest from the selected update-store disk and
// points the virtio-blk base-image reads at the active slot's image. The
// manifest format + CRC validation live in the I/O-free kernel/fs/swosboot.swift
// (shared with the host tool/test). The verified-fallback retry itself lives in
// vfsInit: if the active slot's image fails its Ed25519/SHA-256 verification,
// vfsInit calls virtioBlkUseFallbackBase() and remounts the known-good slot.
//
// This file holds no mutable global state — the active/fallback slot offsets
// live in the driver (kernel/drivers/virtio_blk.swift) so the read path is
// slot-relative without any caller changes.

@inline(__always) private func updateStoreLogSlot(_ slot: Int) {
    uartPuts(slot == 0 ? "A" : "B")
}

/// Select the active A/B slot from the SWOSBOOT manifest, if an update-store
/// disk is the selected block device. A no-op (base reads stay at sector 0) on
/// a legacy single-image disk or no disk. Called early in vfsInit, before the
/// base image is mounted.
func updateStoreInit() {
    if !virtioBlkAvailable() || !virtioBlkIsUpdateStore() { return }

    // Read both manifest copies (LBA 0 and LBA 1) into one stack buffer and pick
    // the valid copy with the highest sequence (torn-write safe; U1b rewrites in
    // place). parseSwosbootManifest copies fields out, so reusing the buffer for
    // the second read does not invalidate the first parse.
    var buf = InlineArray<512, UInt8>(repeating: 0)
    var m0: SwosbootManifest? = nil
    var m1: SwosbootManifest? = nil
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.baseAddress!
        if virtioBlkRead(0, p) == 0 { m0 = parseSwosbootManifest(UnsafeRawPointer(p), 512) }
        if virtioBlkRead(1, p) == 0 { m1 = parseSwosbootManifest(UnsafeRawPointer(p), 512) }
    }

    let chosen: SwosbootManifest
    var chosenLBA: UInt64 = 0 // which copy we read (write the attempt back to the other)
    if let a = m0, let b = m1 {
        if b.sequence > a.sequence { chosen = b; chosenLBA = 1 } else { chosen = a; chosenLBA = 0 }
    } else if let a = m0 {
        chosen = a; chosenLBA = 0
    } else if let b = m1 {
        chosen = b; chosenLBA = 1
    } else {
        uartPuts("update-store: SWOSBOOT manifest invalid on both copies — using sector 0\n")
        return
    }

    let active = chosen.activeSlot
    let fallback = chosen.fallbackSlot
    virtioBlkSetBaseByteOffset(chosen.slotByteOffset(active))
    if fallback != active && chosen.slot(fallback).present {
        virtioBlkSetFallbackByteOffset(chosen.slotByteOffset(fallback))
    }

    uartPuts("update-store: SWOSBOOT manifest valid, active slot ")
    updateStoreLogSlot(active)
    uartPuts(" gen ")
    uartPutUInt(UInt64(chosen.slot(active).generation))
    if fallback != active && chosen.slot(fallback).present {
        uartPuts(", fallback slot ")
        updateStoreLogSlot(fallback)
    } else {
        uartPuts(", no fallback")
    }
    uartPuts("\n")

    // U1b: record this boot attempt for the active slot, persisted to the OTHER
    // manifest copy with a bumped sequence (double-buffered: the reader picks the
    // highest valid sequence, so an interrupted write leaves the old copy intact).
    // The boot-state this establishes is what U1c's attempt-based rollback +
    // health-confirm will consume. A CONFIRMED slot stops accumulating attempts.
    if chosen.slot(active).state == SwosbootFormat.stateConfirmed { return }
    var updated = chosen
    if active == 0 { updated.slot0.attemptCount &+= 1 } else { updated.slot1.attemptCount &+= 1 }
    updated.sequence = chosen.sequence &+ 1
    let attempts = active == 0 ? updated.slot0.attemptCount : updated.slot1.attemptCount
    let writeLBA: UInt64 = chosenLBA == 0 ? 1 : 0
    withUnsafeMutableBytes(of: &buf) { raw in
        serializeSwosbootManifest(updated, into: raw.baseAddress!)
        if virtioBlkWriteSector(writeLBA, UnsafeRawPointer(raw.baseAddress!)) == 0 {
            uartPuts("update-store: recorded boot attempt ")
            uartPutUInt(UInt64(attempts))
            uartPuts(" for active slot ")
            updateStoreLogSlot(active)
            uartPuts("\n")
        } else {
            uartPuts("update-store: WARNING failed to persist boot attempt\n")
        }
    }
}

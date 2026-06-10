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
    if let a = m0, let b = m1 {
        chosen = b.sequence > a.sequence ? b : a
    } else if let a = m0 {
        chosen = a
    } else if let b = m1 {
        chosen = b
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
}

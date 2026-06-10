// SPDX-License-Identifier: Apache-2.0
// updatestore.swift — kernel I/O glue for the A/B update store.
//
// U1a (read side): reads the SWOSBOOT boot manifest from the selected
// update-store disk and points virtio-blk base-image reads at the active slot.
// The verified-fallback retry lives in vfsInit (virtioBlkUseFallbackBase).
// U1b (write side): on boot, records a per-slot boot-attempt counter, persisted
// to the manifest's other double-buffer copy (torn-write safe).
// U1c (health-confirm): updateStoreConfirm() (syscall 60, capConsole-gated, via
// /bin/swos-confirm) marks the booted slot CONFIRMED so it stops accruing
// attempts. Attempt-based rollback that consumes the counter is U1d.
//
// The manifest format/CRC/serialization live in the I/O-free swosboot.swift
// (shared with the host tool/test). The only mutable global here is which slot
// was booted this session, so the confirm syscall knows what to mark.

// The A/B slot booted from the store this session (0 or 1), or -1 if the system
// did not boot from an update-store disk. SMP: set once at boot before EL0.
var updateStoreActiveSlot: Int = -1

@inline(__always) private func updateStoreLogSlot(_ slot: Int) {
    uartPuts(slot == 0 ? "A" : "B")
}
@inline(__always) private func updateStoreLogState(_ state: UInt32) {
    if state == SwosbootFormat.stateConfirmed { uartPuts("confirmed") }
    else if state == SwosbootFormat.stateFailed { uartPuts("failed") }
    else { uartPuts("untried") }
}

// Read both manifest copies (LBA 0 and LBA 1) and return the valid one with the
// highest sequence, plus which LBA it came from (so a write-back targets the
// OTHER copy). parseSwosbootManifest copies fields out, so reusing the buffer
// for the second read does not invalidate the first parse.
private func updateStoreReadChosen() -> (SwosbootManifest, UInt64)? {
    var buf = InlineArray<512, UInt8>(repeating: 0)
    var m0: SwosbootManifest? = nil
    var m1: SwosbootManifest? = nil
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.baseAddress!
        if virtioBlkRead(0, p) == 0 { m0 = parseSwosbootManifest(UnsafeRawPointer(p), 512) }
        if virtioBlkRead(1, p) == 0 { m1 = parseSwosbootManifest(UnsafeRawPointer(p), 512) }
    }
    if let a = m0, let b = m1 { return b.sequence > a.sequence ? (b, 1) : (a, 0) }
    if let a = m0 { return (a, 0) }
    if let b = m1 { return (b, 1) }
    return nil
}

// Serialize `updated` and write it to the OTHER double-buffer copy (1-currentLBA)
// so the reader, which picks the highest valid sequence, sees it next. An
// interrupted write leaves the prior copy intact. Returns true on success.
private func updateStoreWriteBack(_ updated: SwosbootManifest, currentLBA: UInt64) -> Bool {
    var buf = InlineArray<512, UInt8>(repeating: 0)
    var ok = false
    withUnsafeMutableBytes(of: &buf) { raw in
        serializeSwosbootManifest(updated, into: raw.baseAddress!)
        let writeLBA: UInt64 = currentLBA == 0 ? 1 : 0
        ok = virtioBlkWriteSector(writeLBA, UnsafeRawPointer(raw.baseAddress!)) == 0
    }
    return ok
}

/// Select the active A/B slot from the SWOSBOOT manifest, if an update-store
/// disk is the selected block device, and record this boot attempt. A no-op
/// (base reads stay at sector 0) on a legacy single-image disk or no disk.
/// Called early in vfsInit, before the base image is mounted.
func updateStoreInit() {
    updateStoreActiveSlot = -1
    if !virtioBlkAvailable() || !virtioBlkIsUpdateStore() { return }

    guard let (chosen, chosenLBA) = updateStoreReadChosen() else {
        uartPuts("update-store: SWOSBOOT manifest invalid on both copies — using sector 0\n")
        return
    }

    let active = chosen.activeSlot
    let fallback = chosen.fallbackSlot
    updateStoreActiveSlot = active // remembered so updateStoreConfirm can mark it
    virtioBlkSetBaseByteOffset(chosen.slotByteOffset(active))
    if fallback != active && chosen.slot(fallback).present {
        virtioBlkSetFallbackByteOffset(chosen.slotByteOffset(fallback))
    }

    uartPuts("update-store: SWOSBOOT manifest valid, active slot ")
    updateStoreLogSlot(active)
    uartPuts(" gen ")
    uartPutUInt(UInt64(chosen.slot(active).generation))
    uartPuts(" ")
    updateStoreLogState(chosen.slot(active).state)
    if fallback != active && chosen.slot(fallback).present {
        uartPuts(", fallback slot ")
        updateStoreLogSlot(fallback)
    } else {
        uartPuts(", no fallback")
    }
    uartPuts("\n")

    // U1b: record this boot attempt for the active slot. A CONFIRMED slot is
    // trusted and stops accumulating attempts (set by updateStoreConfirm, U1c).
    if chosen.slot(active).state == SwosbootFormat.stateConfirmed { return }
    var updated = chosen
    if active == 0 { updated.slot0.attemptCount &+= 1 } else { updated.slot1.attemptCount &+= 1 }
    updated.sequence = chosen.sequence &+ 1
    let attempts = active == 0 ? updated.slot0.attemptCount : updated.slot1.attemptCount
    if updateStoreWriteBack(updated, currentLBA: chosenLBA) {
        uartPuts("update-store: recorded boot attempt ")
        uartPutUInt(UInt64(attempts))
        uartPuts(" for active slot ")
        updateStoreLogSlot(active)
        uartPuts("\n")
    } else {
        uartPuts("update-store: WARNING failed to persist boot attempt\n")
    }
}

/// U1c: mark the slot booted this session CONFIRMED and reset its attempt
/// counter, persisted to the manifest. A health-check pass: a CONFIRMED slot is
/// trusted and never rolled back (and stops accruing boot attempts). Gated on
/// capConsole (the boot/admin context), like login. Returns 0 on success, or a
/// negative errno-style code. Invoked from EL0 via syscall 60 (/bin/swos-confirm).
func updateStoreConfirm() -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return -1 } // EPERM
    if updateStoreActiveSlot < 0 { return -19 }               // ENODEV: not store-booted
    if !virtioBlkAvailable() || !virtioBlkIsUpdateStore() { return -19 }
    guard let (chosen, chosenLBA) = updateStoreReadChosen() else { return -5 } // EIO

    let s = updateStoreActiveSlot
    var updated = chosen
    if s == 0 {
        updated.slot0.state = SwosbootFormat.stateConfirmed
        updated.slot0.attemptCount = 0
    } else {
        updated.slot1.state = SwosbootFormat.stateConfirmed
        updated.slot1.attemptCount = 0
    }
    updated.sequence = chosen.sequence &+ 1
    if !updateStoreWriteBack(updated, currentLBA: chosenLBA) {
        uartPuts("update-store: confirm write failed\n")
        return -5
    }
    uartPuts("update-store: slot ")
    updateStoreLogSlot(s)
    uartPuts(" confirmed healthy\n")
    return 0
}

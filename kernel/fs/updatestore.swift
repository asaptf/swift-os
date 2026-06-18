// SPDX-License-Identifier: Apache-2.0
// updatestore.swift — kernel I/O glue for the A/B update store.
//
// U1a (read side): reads the SWOSBOOT boot manifest from the selected
// update-store disk and points virtio-blk base-image reads at the active slot.
// The verified-fallback retry lives in vfsInit (virtioBlkUseFallbackBase).
// U1b (write side): on boot, records a per-slot boot-attempt counter, persisted
// to the manifest's other double-buffer copy (torn-write safe).
// U1c (health-confirm): updateStoreConfirm() (syscall 65, capConsole-gated, via
// /bin/swos-confirm) marks the booted slot CONFIRMED so it stops accruing
// attempts. Attempt-based rollback that consumes the counter is U1d.
//
// The manifest format/CRC/serialization live in the I/O-free swosboot.swift
// (shared with the host tool/test). The only mutable global here is which slot
// was booted this session, so the confirm syscall knows what to mark.

// The A/B slot booted from the store this session (0 or 1), or -1 if the system
// did not boot from an update-store disk. SMP: set once at boot before EL0.
var updateStoreActiveSlot: Int = -1

// U1d: a freshly-activated, unconfirmed slot gets this many boot attempts before
// it is presumed unhealthy and rolled back to the fallback. /bin/swos-confirm
// (U1c) marks a slot CONFIRMED, which exempts it from counting and rollback.
private let maxBootAttempts: UInt32 = 3

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
    // U1h: push the manifest write through any volatile device/host write cache so
    // it survives a crash without relying on a cache=writethrough backend.
    if ok && virtioBlkFlush() != 0 { ok = false }
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

    var manifest = chosen
    var active = chosen.activeSlot
    var fallback = chosen.fallbackSlot

    // U1d: attempt-based rollback. An unconfirmed active slot that has used up
    // its boot attempts is presumed unhealthy (it booted but was never confirmed
    // via /bin/swos-confirm); mark it FAILED and switch to the known-good
    // fallback. This is the "boots but never confirmed" path; the BAD-IMAGE path
    // (signature/content verification failure) is handled separately at mount
    // time in vfsInit. The swap + FAILED mark are persisted with the boot-state
    // write-back below.
    var rolledBack = false
    if manifest.slot(active).state != SwosbootFormat.stateConfirmed
        && manifest.slot(active).attemptCount >= maxBootAttempts
        && fallback != active && manifest.slot(fallback).present {
        if active == 0 { manifest.slot0.state = SwosbootFormat.stateFailed }
        else { manifest.slot1.state = SwosbootFormat.stateFailed }
        let old = active
        active = fallback
        fallback = old
        manifest.activeSlot = active
        manifest.fallbackSlot = fallback
        rolledBack = true
        uartPuts("update-store: active slot ")
        updateStoreLogSlot(old)
        uartPuts(" exhausted ")
        uartPutUInt(UInt64(maxBootAttempts))
        uartPuts(" attempts — rolling back to slot ")
        updateStoreLogSlot(active)
        uartPuts("\n")
    }

    updateStoreActiveSlot = active // remembered so updateStoreConfirm can mark it
    virtioBlkSetBaseByteOffset(manifest.slotByteOffset(active))
    if fallback != active && manifest.slot(fallback).present {
        virtioBlkSetFallbackByteOffset(manifest.slotByteOffset(fallback))
    }

    uartPuts("update-store: SWOSBOOT manifest valid, active slot ")
    updateStoreLogSlot(active)
    uartPuts(" gen ")
    uartPutUInt(UInt64(manifest.slot(active).generation))
    uartPuts(" ")
    updateStoreLogState(manifest.slot(active).state)
    if fallback != active && manifest.slot(fallback).present {
        uartPuts(", fallback slot ")
        updateStoreLogSlot(fallback)
    } else {
        uartPuts(", no fallback")
    }
    uartPuts("\n")

    // U1h: report how boot-state writes reach stable media. With FLUSH the kernel
    // flushes after each manifest/stage write, so durability does not depend on a
    // cache=writethrough host backend.
    uartPuts(virtioBlkFlushSupported()
        ? "update-store: write durability via virtio FLUSH\n"
        : "update-store: device has no write cache (writes are durable on completion)\n")

    // Record this boot attempt for the (possibly new) active slot, and persist
    // any rollback swap. A CONFIRMED slot is trusted: it does not accumulate
    // attempts (U1c). If nothing changed (confirmed active, no rollback), there
    // is nothing to write.
    let activeConfirmed = manifest.slot(active).state == SwosbootFormat.stateConfirmed
    if !rolledBack && activeConfirmed { return }
    var updated = manifest
    if !activeConfirmed {
        if active == 0 { updated.slot0.attemptCount &+= 1 } else { updated.slot1.attemptCount &+= 1 }
    }
    updated.sequence = chosen.sequence &+ 1
    let attempts = active == 0 ? updated.slot0.attemptCount : updated.slot1.attemptCount
    if updateStoreWriteBack(updated, currentLBA: chosenLBA) {
        if !activeConfirmed {
            uartPuts("update-store: recorded boot attempt ")
            uartPutUInt(UInt64(attempts))
            uartPuts(" for active slot ")
            updateStoreLogSlot(active)
            uartPuts("\n")
        } else {
            uartPuts("update-store: persisted rollback to confirmed slot ")
            updateStoreLogSlot(active)
            uartPuts("\n")
        }
    } else {
        uartPuts("update-store: WARNING failed to persist boot-state\n")
    }
}

/// U1c: mark the slot booted this session CONFIRMED and reset its attempt
/// counter, persisted to the manifest. A health-check pass: a CONFIRMED slot is
/// trusted and never rolled back (and stops accruing boot attempts). Gated on
/// capConsole (the boot/admin context), like login. Returns 0 on success, or a
/// negative errno-style code. Invoked from EL0 via syscall 65 (/bin/swos-confirm).
func updateStoreConfirm() -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.perm.code } // EPERM
    if updateStoreActiveSlot < 0 { return Errno.noDev.code }               // ENODEV: not store-booted
    if !virtioBlkAvailable() || !virtioBlkIsUpdateStore() { return Errno.noDev.code }
    guard let (chosen, chosenLBA) = updateStoreReadChosen() else { return Errno.io.code } // EIO

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
        return Errno.io.code
    }
    uartPuts("update-store: slot ")
    updateStoreLogSlot(s)
    uartPuts(" confirmed healthy\n")
    return 0
}

/// U1e: promote the inactive slot — make it the active slot for the next boot
/// (the current slot becomes the fallback), marked UNTRIED with its attempt
/// counter reset so it boots "on trial" under U1d's attempt-based rollback. The
/// operator runs this after staging a new image into the inactive slot. Gated on
/// capConsole. Returns 0 on success, or a negative errno-style code. Invoked
/// from EL0 via syscall 66 (/bin/swos-activate).
func updateStoreActivateOther() -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.perm.code } // EPERM
    if updateStoreActiveSlot < 0 { return Errno.noDev.code }               // ENODEV: not store-booted
    if !virtioBlkAvailable() || !virtioBlkIsUpdateStore() { return Errno.noDev.code }
    guard let (chosen, chosenLBA) = updateStoreReadChosen() else { return Errno.io.code } // EIO

    let cur = updateStoreActiveSlot
    let other = 1 - cur
    if other < 0 || other >= SwosbootFormat.slotCount || !chosen.slot(other).present {
        return Errno.noEntry.code // ENOENT: no inactive slot to activate
    }

    var updated = chosen
    updated.activeSlot = other
    updated.fallbackSlot = cur
    // The newly-activated slot boots on trial: untried, attempt counter reset.
    if other == 0 {
        updated.slot0.state = SwosbootFormat.stateUntried
        updated.slot0.attemptCount = 0
    } else {
        updated.slot1.state = SwosbootFormat.stateUntried
        updated.slot1.attemptCount = 0
    }
    updated.sequence = chosen.sequence &+ 1
    if !updateStoreWriteBack(updated, currentLBA: chosenLBA) {
        uartPuts("update-store: activate write failed\n")
        return Errno.io.code
    }
    uartPuts("update-store: activated slot ")
    updateStoreLogSlot(other)
    uartPuts(" (on trial), fallback slot ")
    updateStoreLogSlot(cur)
    uartPuts("\n")
    return 0
}

// Little-endian field loads from a raw header buffer (SWOSBASE layout).
@inline(__always) private func usLoad32(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
    UInt32(p.load(fromByteOffset: o, as: UInt8.self))
        | (UInt32(p.load(fromByteOffset: o + 1, as: UInt8.self)) << 8)
        | (UInt32(p.load(fromByteOffset: o + 2, as: UInt8.self)) << 16)
        | (UInt32(p.load(fromByteOffset: o + 3, as: UInt8.self)) << 24)
}
@inline(__always) private func usLoad64(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
    UInt64(usLoad32(p, o)) | (UInt64(usLoad32(p, o + 4)) << 32)
}

/// U1f-2b: copy the attached read-only payload disk (a signed SWOSBASE image)
/// into the INACTIVE A/B slot, then mark that slot present + UNTRIED so the
/// operator can `/bin/swos-activate` + reboot onto it. Gated on capConsole.
///
/// The payload must be a signed v3 SWOSBASE image and fit the inactive slot's
/// length_sectors (the slot was sized by the store tool). The copy moves whole
/// 64 KiB runs disk-to-disk through the driver's own multi-sector DMA buffer
/// (U1f-2a's virtioBlkFill/FlushMulti) with no intermediate kernel buffer:
/// read a run from the payload into blkMultiBase, re-select the store, flush it
/// to the slot. This routine copies BYTES; it does not verify them — the staged
/// image's own Ed25519 signature is checked at the next boot's mount (the
/// unchanged I8 path), so a payload that copies but is corrupt simply fails to
/// boot on trial and U1a/U1d return to the known-good slot.
///
/// Returns 0 on success, or a negative errno-style code. Invoked from EL0 via
/// syscall 67 (/bin/swos-update).
func updateStoreStagePayload() -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.perm.code } // EPERM
    if updateStoreActiveSlot < 0 { return Errno.noDev.code }               // ENODEV: not store-booted
    if !virtioBlkAvailable() || !virtioBlkIsUpdateStore() { return Errno.noDev.code }
    if !virtioBlkHasPayload() { return Errno.noDev.code }                  // ENODEV: no payload disk
    guard let (chosen, chosenLBA) = updateStoreReadChosen() else { return Errno.io.code } // EIO

    let target = 1 - updateStoreActiveSlot
    if target < 0 || target >= SwosbootFormat.slotCount { return Errno.noEntry.code } // ENOENT
    let storeBaseSec = chosen.slot(target).baseLBA
    let slotSectors = chosen.slot(target).lengthSectors

    // Bring up the payload and read its header: confirm a signed v3 SWOSBASE
    // image and compute its length (dataOffset + payloadLen, rounded up).
    let payCap = virtioBlkSelectPayload()
    if payCap == 0 { virtioBlkReselectStore(); return Errno.noDev.code }
    var imageSectors: UInt64 = 0
    var headerOK = false
    var hdr = InlineArray<512, UInt8>(repeating: 0)
    withUnsafeMutableBytes(of: &hdr) { raw in
        let p = raw.baseAddress!
        if virtioBlkReadCurrent(0, p) == 0 {
            let magic: StaticString = "SWOSBASE"
            var m = true
            magic.withUTF8Buffer { mm in
                var i = 0
                while i < 8 { if p.load(fromByteOffset: i, as: UInt8.self) != mm[i] { m = false }; i += 1 }
            }
            let total = usLoad64(UnsafeRawPointer(p), 48) &+ usLoad64(UnsafeRawPointer(p), 56)
            imageSectors = (total &+ 511) / 512
            headerOK = m && usLoad32(UnsafeRawPointer(p), 8) == 3 && total > 0
        }
    }
    if !headerOK { virtioBlkReselectStore(); return Errno.invalid.code }              // EINVAL: not a signed v3 image
    if imageSectors > payCap { virtioBlkReselectStore(); return Errno.invalid.code }  // payload truncated on disk
    if imageSectors > slotSectors {                                   // EFBIG: image too big for slot
        virtioBlkReselectStore()
        uartPuts("update-store: payload ")
        uartPutUInt(imageSectors)
        uartPuts(" sectors does not fit slot ")
        updateStoreLogSlot(target)
        uartPuts(" (")
        uartPutUInt(slotSectors)
        uartPuts(" sectors)\n")
        return Errno.fileTooBig.code
    }

    // Copy payload[0, imageSectors) -> store[storeBaseSec, +imageSectors).
    let maxChunk = UInt64(virtioBlkMultiMax())
    var done: UInt64 = 0
    var copyOK = true
    while done < imageSectors {
        var n = imageSectors - done
        if n > maxChunk { n = maxChunk }
        if virtioBlkSelectPayload() == 0 { copyOK = false; break }
        if virtioBlkFillMulti(done, Int(n)) != 0 { copyOK = false; break }
        virtioBlkReselectStore()
        if virtioBlkFlushMulti(storeBaseSec &+ done, Int(n)) != 0 { copyOK = false; break }
        done &+= n
    }
    virtioBlkReselectStore()
    if !copyOK {
        uartPuts("update-store: stage copy failed\n")
        return Errno.io.code
    }
    // U1h: make the staged slot data durable before the manifest is pointed at it
    // (the manifest write-back below flushes itself), so a crash can never leave a
    // committed manifest referencing half-written slot bytes.
    if virtioBlkFlush() != 0 {
        uartPuts("update-store: stage flush failed\n")
        return Errno.io.code
    }

    // Mark the freshly-staged slot present + UNTRIED with attempts reset and a
    // bumped generation, persisted via the double-buffered write-back. The
    // operator then runs /bin/swos-activate to boot it on trial.
    var updated = chosen
    if target == 0 {
        updated.slot0.present = true
        updated.slot0.state = SwosbootFormat.stateUntried
        updated.slot0.attemptCount = 0
        updated.slot0.generation &+= 1
    } else {
        updated.slot1.present = true
        updated.slot1.state = SwosbootFormat.stateUntried
        updated.slot1.attemptCount = 0
        updated.slot1.generation &+= 1
    }
    updated.sequence = chosen.sequence &+ 1
    if !updateStoreWriteBack(updated, currentLBA: chosenLBA) {
        uartPuts("update-store: stage write-back failed\n")
        return Errno.io.code
    }
    uartPuts("update-store: staged payload (")
    uartPutUInt(imageSectors)
    uartPuts(" sectors) into slot ")
    updateStoreLogSlot(target)
    uartPuts(" gen ")
    uartPutUInt(UInt64(target == 0 ? updated.slot0.generation : updated.slot1.generation))
    uartPuts("\n")
    return 0
}

// --- OS-3b: streamed staging of a base image into the inactive slot ----------
//
// The reflash-free path: /bin/swupdate downloads a signed SWSYS bundle to /data,
// verifies it in userland (signature + monotonic version), then streams the base
// image half into the INACTIVE A/B slot through this capability-gated, single-
// owner sequence — begin / write* / commit — which is the ONLY privileged way to
// write a slot (not a general FS write). Unlike updateStoreStagePayload (U1f-2b),
// the source is a userland buffer, not an attached payload disk, so it works on a
// live box with no extra disk. Power-fail-safe: the slot bytes are written and
// flushed in full before the single manifest write-back marks the slot present
// (the active slot is never touched — activation is a separate step). Mirrors the
// pkg-store stream syscalls (kernel/pkg/store.swift).

private let stageChunkMax = 64 * 1024     // max bytes per write syscall

private var stageActive = false
private var stageOwnerPid: Int = -1
private var stageTargetSlot = -1
private var stageSlotBaseByte: UInt64 = 0    // absolute byte offset of the slot on the store
private var stageDeclaredBytes: UInt64 = 0   // declared base-image length
private var stageDeclaredVersion: UInt64 = 0 // monotonic system version of this image
private var stageWritten: UInt64 = 0
private var stageFirst = InlineArray<64, UInt8>(repeating: 0) // header bytes for commit checks
private var stageFirstCount = 0

@inline(__always) private func stageReset() {
    stageActive = false
    stageOwnerPid = -1
    stageTargetSlot = -1
    stageSlotBaseByte = 0
    stageDeclaredBytes = 0
    stageDeclaredVersion = 0
    stageWritten = 0
    stageFirstCount = 0
}

/// OS-3b begin: validate the request and reserve the inactive slot for streaming.
/// `version` is the monotonic OS version of the image; it must exceed the store's
/// anti-rollback floor. `totalBytes` is the image length; it must fit the slot.
/// capConsole-gated. Returns 0, or a negative errno. Syscall 83 (/bin/swupdate via
/// the swos bridge). Does NOT mutate the manifest — only commit does.
func updateStoreStageBegin(version: UInt64, totalBytes: UInt64) -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.perm.code }
    if updateStoreActiveSlot < 0 { return Errno.noDev.code }
    if !virtioBlkAvailable() || !virtioBlkIsUpdateStore() { return Errno.noDev.code }
    guard let (chosen, _) = updateStoreReadChosen() else { return Errno.io.code }

    let target = 1 - updateStoreActiveSlot
    if target < 0 || target >= SwosbootFormat.slotCount { return Errno.noEntry.code }
    let slotCapBytes = chosen.slot(target).lengthSectors &* 512
    if totalBytes == 0 || totalBytes > slotCapBytes { return Errno.fileTooBig.code }

    // Anti-rollback: a freshly staged image must be strictly newer than the floor
    // (the highest version confirmed healthy). Refuse 0 (the floor's own value).
    if version == 0 || version <= chosen.minSystemVersion { return Errno.perm.code }

    stageReset()
    stageActive = true
    stageOwnerPid = processCurrentPid()
    stageTargetSlot = target
    stageSlotBaseByte = chosen.slotByteOffset(target)
    stageDeclaredBytes = totalBytes
    stageDeclaredVersion = version
    return 0
}

/// OS-3b write: append `count` bytes from the userland buffer at `bufVA` to the
/// inactive slot at the current cursor (read-modify-write tolerates any chunking).
/// capConsole-gated, single-owner. Returns 0, or a negative errno. Syscall 84.
func updateStoreStageWrite(bufVA: UInt, count: UInt) -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.perm.code }
    if !stageActive || stageOwnerPid != processCurrentPid() { return Errno.again.code }
    if count == 0 { return 0 }
    if count > UInt(stageChunkMax) { stageReset(); return Errno.invalid.code }
    let remaining = stageDeclaredBytes - stageWritten
    if UInt64(count) > remaining { stageReset(); return Errno.invalid.code }
    guard let src = userReadableBuffer(bufVA, count) else { stageReset(); return Errno.fault.code }

    // Capture the first 64 bytes for the commit-time header check.
    var i = 0
    while i < Int(count) && stageFirstCount < 64 {
        stageFirst[stageFirstCount] = src[i]
        stageFirstCount += 1
        i += 1
    }

    let rc = virtioBlkStoreWriteRange(stageSlotBaseByte &+ stageWritten, UnsafeRawPointer(src), UInt32(count))
    if rc != 0 { stageReset(); return Errno.io.code }
    stageWritten &+= UInt64(count)
    return 0
}

/// OS-3b commit: require the full image was written, confirm it begins with a
/// signed v3 SWOSBASE header whose length matches what was declared, flush the
/// slot durably, then mark the slot present + UNTRIED with a bumped generation and
/// the staged system version recorded — persisted via the double-buffered manifest
/// write-back. The active slot is untouched; the operator runs /bin/swos-activate
/// next. capConsole-gated, single-owner. Returns 0, or a negative errno. Syscall 85.
func updateStoreStageCommit() -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.perm.code }
    if !stageActive || stageOwnerPid != processCurrentPid() { return Errno.again.code }
    if stageWritten != stageDeclaredBytes { stageReset(); return Errno.invalid.code }

    // Header check: signed v3 SWOSBASE, and its self-described length
    // (dataOffset + payloadLen, which equals a packfs image's exact byte size)
    // matches the declared byte count — the same header shape U1f-2b validates.
    var headerOK = false
    withUnsafeBytes(of: &stageFirst) { raw in
        let p = raw.baseAddress!
        if stageFirstCount >= 64 {
            let magic: StaticString = "SWOSBASE"
            var m = true
            magic.withUTF8Buffer { mm in
                var i = 0
                while i < 8 { if p.load(fromByteOffset: i, as: UInt8.self) != mm[i] { m = false }; i += 1 }
            }
            let total = usLoad64(p, 48) &+ usLoad64(p, 56)
            headerOK = m && usLoad32(p, 8) == 3 && total > 0 && total == stageDeclaredBytes
        }
    }
    if !headerOK { stageReset(); return Errno.invalid.code }

    // Durability: the slot bytes must hit stable media before the manifest names
    // them, so a crash can never leave a present slot half-written.
    if virtioBlkFlush() != 0 { stageReset(); return Errno.io.code }

    guard let (chosen, chosenLBA) = updateStoreReadChosen() else { stageReset(); return Errno.io.code }
    let target = stageTargetSlot
    let version = stageDeclaredVersion
    var updated = chosen
    if target == 0 {
        updated.slot0.present = true
        updated.slot0.state = SwosbootFormat.stateUntried
        updated.slot0.attemptCount = 0
        updated.slot0.generation &+= 1
        updated.slot0.systemVersion = version
    } else {
        updated.slot1.present = true
        updated.slot1.state = SwosbootFormat.stateUntried
        updated.slot1.attemptCount = 0
        updated.slot1.generation &+= 1
        updated.slot1.systemVersion = version
    }
    updated.sequence = chosen.sequence &+ 1
    if !updateStoreWriteBack(updated, currentLBA: chosenLBA) { stageReset(); return Errno.io.code }

    uartPuts("update-store: staged base image (")
    uartPutUInt(stageDeclaredBytes)
    uartPuts(" bytes, version ")
    uartPutUInt(version)
    uartPuts(") into slot ")
    updateStoreLogSlot(target)
    uartPuts("\n")
    stageReset()
    return 0
}

/// OS-3b abort: discard an in-progress stage. The inactive slot may hold partial
/// bytes but is not marked present, so it is harmless. capConsole-gated. Syscall 86.
func updateStoreStageAbort() -> Int {
    if (processCurrentCaps() & capConsole) == 0 { return Errno.perm.code }
    if !stageActive { return 0 }
    if stageOwnerPid != processCurrentPid() { return Errno.again.code }
    stageReset()
    return 0
}

/// U1f: report an A/B update payload disk attached alongside the store, by
/// reading its sector-0 header through the secondary virtio-blk path and
/// checking it is a signed v3 SWOSBASE base image. This proves the multi-device
/// read path before U1f-2 stages the payload into the inactive slot. A no-op
/// when no payload disk is present. Leaves the store disk re-selected so the
/// subsequent base mount reads the store.
func updateStorePayloadProbe() {
    if !virtioBlkHasPayload() { return }
    let cap = virtioBlkSelectPayload()
    var ok = false
    var version: UInt32 = 0
    var buf = InlineArray<512, UInt8>(repeating: 0)
    withUnsafeMutableBytes(of: &buf) { raw in
        let p = raw.baseAddress!
        if virtioBlkReadCurrent(0, p) == 0 {
            let magic: StaticString = "SWOSBASE"
            var m = true
            magic.withUTF8Buffer { mm in
                var i = 0
                while i < 8 {
                    if p.load(fromByteOffset: i, as: UInt8.self) != mm[i] { m = false }
                    i += 1
                }
            }
            version = UInt32(p.load(fromByteOffset: 8, as: UInt8.self))
                | (UInt32(p.load(fromByteOffset: 9, as: UInt8.self)) << 8)
                | (UInt32(p.load(fromByteOffset: 10, as: UInt8.self)) << 16)
                | (UInt32(p.load(fromByteOffset: 11, as: UInt8.self)) << 24)
            ok = m
        }
    }
    virtioBlkReselectStore()

    if ok && version == 3 {
        uartPuts("update-store: update payload disk present, ")
        uartPutUInt(cap)
        uartPuts(" sectors, signed v3 base image\n")
    } else {
        uartPuts("update-store: payload disk present but not a signed v3 base image\n")
    }
}

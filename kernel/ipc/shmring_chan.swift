// SPDX-License-Identifier: Apache-2.0
// shmring_chan.swift — kernel binding for the sans-IO SPSC ring (LA3 step 2).
//
// A small fixed table of shared-memory channels. Each channel owns N physically
// contiguous PMM pages laid out as a FULL-DUPLEX pair of rings: ring0 in the
// first half, ring1 in the second, each initialized via shmRingInit. A process
// maps a channel's pages read/write into its address space (shmRingChannelMap)
// and then drives the rings directly from userland — no syscall per record.
//
// Locking: the channel TABLE is guarded by its own spinlock in the netLock style
// (irq_save + a CAS'd lock word), NOT netLock/vfsLock. The ring data path itself
// is lock-free SPSC (see shmring.swift); the table lock only protects slot
// allocation/teardown, which is rare. Frame allocation/free is done OUTSIDE the
// table lock (the PMM has its own lock and is never taken while holding this one).
//
// Page lifetime rides the PMM reference count:
//   * create  -> pmm_alloc_pages gives each frame refcount 1 (the channel's base
//                reference, held by the table),
//   * map     -> processMapSharedFrames bumps each frame (+1 per mapping process),
//   * teardown-> address_space_destroy / munmap call pmm_frame_release (-1),
//   * close / owner-exit -> drop the table's base reference (-1); the frames free
//                on the last drop, so a peer that still maps the channel keeps it
//                alive until that peer also exits.

private let maxShmRings = 64
private let maxShmRingPages: UInt = 8   // bound a single channel's physical footprint

private var shmInUse = [Bool](repeating: false, count: maxShmRings)
private var shmBasePA = [UInt](repeating: 0, count: maxShmRings)
private var shmPages = [UInt](repeating: 0, count: maxShmRings)
private var shmOwner = [Int](repeating: -1, count: maxShmRings)   // creator process slot

private var shmRingLockWord: UInt64 = 0

@inline(__always)
private func shmRingLockAcquire() -> UInt64 {
    let daif = irq_save()
    while true {
        var expected: UInt64 = 0
        let got = withUnsafeMutablePointer(to: &shmRingLockWord) { word in
            smpAtomicCompareExchange(word, expected: &expected, desired: 1)
        }
        if got { smpMemoryBarrier(); return daif }
        smpLoadBarrier()
    }
}

@inline(__always)
private func shmRingLockRelease(_ daif: UInt64) {
    smpMemoryBarrier()
    withUnsafeMutablePointer(to: &shmRingLockWord) { word in
        smpAtomicStore(word, 0)
    }
    irq_restore(daif)
}

// Current process slot used as the channel owner key. processCurrentPid()
// returns slot + 1 (0 when no process is current), matching the `slot` the
// zombie reaper passes to shmRingReapOwner. Returns -1 outside any process.
@inline(__always)
private func shmRingCurrentOwner() -> Int {
    processCurrentPid() - 1
}

// Drop the base reference to each of a channel's frames (frees on the last drop).
private func shmRingFreeFrames(_ basePA: UInt, _ pages: UInt) {
    var i: UInt = 0
    while i < pages {
        pmmFrameRelease(basePA + i * PageAllocator.pageSize)
        i += 1
    }
}

/// Create a shared-memory channel of `pages` physically-contiguous frames laid
/// out as two equal-size rings. `pages` must be even and in [2, maxShmRingPages].
/// Returns the channel id (>= 0), or a negative errno.
func shmRingChannelCreate(pages: UInt) -> Int {
    if pages < 2 || pages > maxShmRingPages || (pages & 1) != 0 { return Errno.invalid.code }
    let owner = shmRingCurrentOwner()
    if owner < 0 { return Errno.invalid.code }

    // Allocate + initialize the frames before claiming a table slot (PMM has its
    // own lock; do not nest it under the table lock).
    let basePA = pmmAllocPages(Int(pages))
    if basePA == 0 { return Errno.noMem.code }
    let bytes = Int(pages) * Int(PageAllocator.pageSize)
    guard let region = UnsafeMutableRawPointer(bitPattern: basePA) else {
        shmRingFreeFrames(basePA, pages)
        return Errno.noMem.code
    }
    var z = 0
    while z < bytes { region.storeBytes(of: UInt64(0), toByteOffset: z, as: UInt64.self); z += 8 }
    let half = bytes / 2
    if !shmRingInit(region: region, bytes: half) ||
       !shmRingInit(region: region.advanced(by: half), bytes: half) {
        shmRingFreeFrames(basePA, pages)
        return Errno.invalid.code
    }

    let daif = shmRingLockAcquire()
    var id = -1
    for i in 0..<maxShmRings where !shmInUse[i] {
        shmInUse[i] = true
        shmBasePA[i] = basePA
        shmPages[i] = pages
        shmOwner[i] = owner
        id = i
        break
    }
    shmRingLockRelease(daif)

    if id < 0 {
        shmRingFreeFrames(basePA, pages)   // table full
        return Errno.noMem.code
    }
    return id
}

/// Map channel `id`'s pages read/write into the current process. Returns the
/// base user VA, or a negative errno encoded in the UInt (the syscall returns it
/// verbatim, like mmap).
func shmRingChannelMap(id: Int) -> UInt {
    func err(_ e: Int) -> UInt { UInt(bitPattern: e) }
    if id < 0 || id >= maxShmRings { return err(Errno.invalid.code) }
    let daif = shmRingLockAcquire()
    if !shmInUse[id] { shmRingLockRelease(daif); return err(Errno.noEntry.code) }
    let basePA = shmBasePA[id]
    let pages = shmPages[id]
    shmRingLockRelease(daif)
    // Map outside the table lock: processMapSharedFrames touches per-process VM
    // state and the PMM, and bumps each frame's reference count.
    return processMapSharedFrames(basePA, pages)
}

/// Drop the creating process's base reference to channel `id` and free the slot.
/// Only the owner may close. Frames still mapped by a peer survive on the peer's
/// reference until it exits. Returns 0 or a negative errno.
func shmRingChannelClose(id: Int) -> Int {
    let me = shmRingCurrentOwner()
    if id < 0 || id >= maxShmRings { return Errno.invalid.code }
    let daif = shmRingLockAcquire()
    if !shmInUse[id] { shmRingLockRelease(daif); return Errno.noEntry.code }
    if shmOwner[id] != me { shmRingLockRelease(daif); return Errno.perm.code }
    let basePA = shmBasePA[id]
    let pages = shmPages[id]
    shmInUse[id] = false; shmBasePA[id] = 0; shmPages[id] = 0; shmOwner[id] = -1
    shmRingLockRelease(daif)
    shmRingFreeFrames(basePA, pages)
    return 0
}

/// Release every channel created by process slot `slot`. Called from the zombie
/// reaper as the process's address space is torn down, so its base references do
/// not leak. One channel is snapshotted+cleared under the table lock per pass and
/// freed with the lock dropped (short critical section, no heap).
func shmRingReapOwner(_ slot: Int) {
    while true {
        let daif = shmRingLockAcquire()
        var base: UInt = 0
        var pages: UInt = 0
        var found = false
        for i in 0..<maxShmRings where shmInUse[i] && shmOwner[i] == slot {
            base = shmBasePA[i]; pages = shmPages[i]
            shmInUse[i] = false; shmBasePA[i] = 0; shmPages[i] = 0; shmOwner[i] = -1
            found = true
            break
        }
        shmRingLockRelease(daif)
        if !found { return }
        shmRingFreeFrames(base, pages)
    }
}

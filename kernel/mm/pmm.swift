// SPDX-License-Identifier: Apache-2.0
// pmm.swift — physical memory manager.
//
// Wires the host-tested `PageAllocator` bitmap to real RAM and exposes a tiny
// C-callable interface (pmm_alloc_page / pmm_free_page / ...) so both Swift
// kernel code and the C page-table walker (vm.c) draw 4 KiB frames from one
// authority. The small-object kernel heap (heap.c) stays separate; this owns
// page-granular memory: page tables, process stacks, and user pages.
//
// Memory map (QEMU `virt`, -m 256M):
//   [0x4008_0000 .. __image_end)   kernel image + boot stack + early heap
//   [__image_end  .. ramEnd)       managed by the PMM (bitmap lives at its head)
// where ramEnd = platform.ramBase + platform.ramSize, discovered from the DTB
// by platformInit (default RAM base 0x4000_0000 + 256 MiB = 0x5000_0000).

private var pmm: PageAllocator? = nil
private var pmmLockWord: UInt64 = 0
private var pmmLockAcquireCount: UInt64 = 0
private var pmmLockContentionCount: UInt64 = 0

@inline(__always)
private func pmmLock() -> UInt64 {
    let daif = irq_save()
    var contended = false
    while true {
        var expected: UInt64 = 0
        let acquired = withUnsafeMutablePointer(to: &pmmLockWord) { word in
            smpAtomicCompareExchange(word, expected: &expected, desired: 1)
        }
        if acquired {
            if contended {
                withUnsafeMutablePointer(to: &pmmLockContentionCount) { count in
                    _ = smpAtomicFetchAdd(count, 1)
                }
            }
            withUnsafeMutablePointer(to: &pmmLockAcquireCount) { count in
                _ = smpAtomicFetchAdd(count, 1)
            }
            smpMemoryBarrier()
            return daif
        }
        contended = true
        smpLoadBarrier()
    }
}

@inline(__always)
private func pmmUnlock(_ daif: UInt64) {
    smpMemoryBarrier()
    withUnsafeMutablePointer(to: &pmmLockWord) { word in
        smpAtomicStore(word, 0)
    }
    irq_restore(daif)
}

@inline(__always)
private func pmmWithAllocator<T>(default defaultValue: T,
                                 _ body: (inout PageAllocator) -> T) -> T {
    let daif = pmmLock()
    defer { pmmUnlock(daif) }
    guard pmm != nil else { return defaultValue }
    return body(&pmm!)
}

@inline(__always)
private func pmmLockAtomicLoad(_ word: inout UInt64) -> UInt64 {
    withUnsafeMutablePointer(to: &word) { ptr in
        smpAtomicLoad(ptr)
    }
}

/// Initialise the PMM over all RAM past the kernel image. Must run once, early
/// (after platformInit so the RAM size is known).
@_cdecl("pmm_init")
func pmmInit() {
    let ramEnd = platform.ramBase + platform.ramSize
    let regionStart = (swiftos_image_end() + 4095) & ~UInt(4095)
    guard regionStart < ramEnd else {
        uartPuts("panic: pmm_init found no free RAM\n")
        while true {}
    }

    let pageCount = Int((ramEnd - regionStart) / PageAllocator.pageSize)
    let bitmap = UnsafeMutablePointer<UInt64>(bitPattern: regionStart)!

    // The bitmap (1 bit/frame) and COW reference-count table (UInt16/frame)
    // both live at the head of the managed region. The allocator reserves their
    // frames immediately below, so normal PMM clients never receive metadata.
    let bitmapWords = (pageCount + 63) / 64
    let bitmapBytes = UInt(bitmapWords) * 8
    let refsStart = (regionStart + bitmapBytes + (PageAllocator.pageSize - 1))
                  & ~(PageAllocator.pageSize - 1)
    let refs = UnsafeMutablePointer<UInt16>(bitPattern: refsStart)!
    var allocator = PageAllocator(base: regionStart, pageCount: pageCount, bitmap: bitmap, refs: refs)

    // Protect the bitmap + refcount table frames.
    let refsBytes = UInt(pageCount) * 2
    let metaEnd = refsStart + refsBytes
    let metaPages = Int((metaEnd - regionStart + (PageAllocator.pageSize - 1)) / PageAllocator.pageSize)
    allocator.reserve(base: regionStart, count: metaPages)

    // Protect the GOP framebuffer (if any) — it sits in this RAM block, and the
    // display scans it directly, so the PMM must not hand its frames out.
    let fbBase = UInt(fb_phys_base())
    let fbSize = UInt(fb_phys_size())
    if fbBase != 0 && fbSize != 0 {
        let fbStart = fbBase & ~UInt(4095)
        let fbEnd = (fbBase + fbSize + 4095) & ~UInt(4095)
        let s = fbStart < regionStart ? regionStart : fbStart
        let e = fbEnd > ramEnd ? ramEnd : fbEnd
        if e > s {
            allocator.reserve(base: s, count: Int((e - s) / PageAllocator.pageSize))
        }
    }

    withUnsafeMutablePointer(to: &pmmLockWord) { word in
        smpAtomicStore(word, 0)
    }
    withUnsafeMutablePointer(to: &pmmLockAcquireCount) { count in
        smpAtomicStore(count, 0)
    }
    withUnsafeMutablePointer(to: &pmmLockContentionCount) { count in
        smpAtomicStore(count, 0)
    }
    pmm = allocator

    uartPuts("M4.5 pmm: ")
    uartPutUInt(UInt64(allocator.freePages))
    uartPuts(" free frames\n")
}

@_cdecl("pmm_alloc_page")
func pmmAllocPage() -> UInt {
    pmmWithAllocator(default: UInt(0)) { allocator in
        allocator.allocate() ?? 0
    }
}

@_cdecl("pmm_alloc_pages")
func pmmAllocPages(_ count: Int) -> UInt {
    pmmWithAllocator(default: UInt(0)) { allocator in
        allocator.allocateContiguous(count) ?? 0
    }
}

@_cdecl("pmm_free_page")
func pmmFreePage(_ addr: UInt) {
    let _: Void = pmmWithAllocator(default: ()) { allocator in
        allocator.free(addr)
    }
}

/// A second address space now shares `addr`; bump its COW reference count.
@_cdecl("pmm_frame_ref")
func pmmFrameRef(_ addr: UInt) {
    let _: Void = pmmWithAllocator(default: ()) { allocator in
        allocator.ref(addr)
    }
}

/// Drop one COW reference to `addr`. Returns true when this was the last
/// reference and the caller should raw-free the frame with pmm_free_page().
@_cdecl("pmm_frame_unref")
func pmmFrameUnref(_ addr: UInt) -> Bool {
    pmmWithAllocator(default: false) { allocator in
        allocator.unref(addr)
    }
}

/// Drop one COW reference and raw-free the frame when it was the last owner.
/// This keeps the last-unref -> free transition under one PMM lock.
@_cdecl("pmm_frame_release")
func pmmFrameRelease(_ addr: UInt) {
    let _: Void = pmmWithAllocator(default: ()) { allocator in
        if allocator.unref(addr) {
            allocator.free(addr)
        }
    }
}

/// Current COW reference count for `addr`, or 0 if it is free/untracked.
@_cdecl("pmm_frame_refcount")
func pmmFrameRefcount(_ addr: UInt) -> Int {
    pmmWithAllocator(default: 0) { allocator in
        allocator.refcount(addr)
    }
}

@_cdecl("pmm_free_count")
func pmmFreeCount() -> Int {
    pmmWithAllocator(default: 0) { allocator in
        allocator.freePages
    }
}

/// Total managed frames (the PMM's bitmap size). Used by /bin/top to report the
/// physical memory footprint; the unmanaged hole below the kernel image and the
/// kernel image itself are not counted here (they are never free frames).
@_cdecl("pmm_total_count")
func pmmTotalCount() -> Int {
    pmmWithAllocator(default: 0) { allocator in
        allocator.pageCount
    }
}

/// Allocate a zeroed 4 KiB frame. Returns 0 on failure.
func pmmAllocZeroedPage() -> UInt {
    let addr = pmmAllocPage()
    if addr == 0 { return 0 }
    let words = UnsafeMutablePointer<UInt64>(bitPattern: addr)!
    for i in 0..<Int(PageAllocator.pageSize / 8) { words[i] = 0 }
    return addr
}

func pmmS4aLockAcquireCount() -> UInt64 {
    pmmLockAtomicLoad(&pmmLockAcquireCount)
}

func pmmS4aLockContentionCount() -> UInt64 {
    pmmLockAtomicLoad(&pmmLockContentionCount)
}

func pmmS4aLockBoundaryHeldSelfTest() -> Bool {
    pmmLockAtomicLoad(&pmmLockWord) == 0 && pmmS4aLockAcquireCount() != 0
}

private func pmmS4aExerciseOnePage() -> Bool {
    let page = pmmAllocPage()
    if page == 0 { return false }

    pmmFrameRef(page)
    let sharedCount = pmmFrameRefcount(page)
    let sharedDropWasLast = pmmFrameUnref(page)
    let finalCount = pmmFrameRefcount(page)
    pmmFrameRelease(page)

    return sharedCount == 2 &&
           !sharedDropWasLast &&
           finalCount == 1
}

func pmmS4aBoundedStressForCurrentCpu() -> Bool {
    var i = 0
    while i < 8 {
        if !pmmS4aExerciseOnePage() { return false }
        i += 1
    }

    return true
}

func pmmS4aConcurrencySelfTest() -> Bool {
    let before = pmmFreeCount()
    if !pmmS4aBoundedStressForCurrentCpu() { return false }
    return pmmFreeCount() == before && pmmS4aLockBoundaryHeldSelfTest()
}

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
    var allocator = PageAllocator(base: regionStart, pageCount: pageCount, bitmap: bitmap)

    // Protect the bitmap's own frames, which sit at the head of the region.
    let bitmapWords = (pageCount + 63) / 64
    let bitmapBytes = UInt(bitmapWords) * 8
    let bitmapPages = Int((bitmapBytes + (PageAllocator.pageSize - 1)) / PageAllocator.pageSize)
    allocator.reserve(base: regionStart, count: bitmapPages)

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

    pmm = allocator

    uartPuts("M4.5 pmm: ")
    uartPutUInt(UInt64(allocator.freePages))
    uartPuts(" free frames\n")
}

@_cdecl("pmm_alloc_page")
func pmmAllocPage() -> UInt {
    if pmm == nil { return 0 }
    return pmm!.allocate() ?? 0
}

@_cdecl("pmm_alloc_pages")
func pmmAllocPages(_ count: Int) -> UInt {
    if pmm == nil { return 0 }
    return pmm!.allocateContiguous(count) ?? 0
}

@_cdecl("pmm_free_page")
func pmmFreePage(_ addr: UInt) {
    if pmm == nil { return }
    pmm!.free(addr)
}

@_cdecl("pmm_free_count")
func pmmFreeCount() -> Int {
    return pmm?.freePages ?? 0
}

/// Total managed frames (the PMM's bitmap size). Used by /bin/top to report the
/// physical memory footprint; the unmanaged hole below the kernel image and the
/// kernel image itself are not counted here (they are never free frames).
@_cdecl("pmm_total_count")
func pmmTotalCount() -> Int {
    return pmm?.pageCount ?? 0
}

/// Allocate a zeroed 4 KiB frame. Returns 0 on failure.
func pmmAllocZeroedPage() -> UInt {
    let addr = pmmAllocPage()
    if addr == 0 { return 0 }
    let words = UnsafeMutablePointer<UInt64>(bitPattern: addr)!
    for i in 0..<Int(PageAllocator.pageSize / 8) { words[i] = 0 }
    return addr
}

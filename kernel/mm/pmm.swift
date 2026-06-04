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
//   [__image_end  .. 0x5000_0000)  managed by the PMM (bitmap lives at its head)

private let ramEnd: UInt = 0x5000_0000   // RAM base 0x4000_0000 + 256 MiB.

private var pmm: PageAllocator? = nil

/// Initialise the PMM over all RAM past the kernel image. Must run once, early.
@_cdecl("pmm_init")
func pmmInit() {
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

/// Allocate a zeroed 4 KiB frame. Returns 0 on failure.
func pmmAllocZeroedPage() -> UInt {
    let addr = pmmAllocPage()
    if addr == 0 { return 0 }
    let words = UnsafeMutablePointer<UInt64>(bitPattern: addr)!
    for i in 0..<Int(PageAllocator.pageSize / 8) { words[i] = 0 }
    return addr
}

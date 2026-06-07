// vm.swift — per-process AArch64 stage-1 address spaces (MMU-on half).
//
// C2: Swift port of the per-process half of the former vm.c. The early, MMU-off
// bring-up tables and the VA-0x8000_0000 probe helpers stay in C
// (kernel/mm/vm_early.c). The functions here run with the MMU on, drawing 4 KiB
// page-table frames from the PMM (kernel/mm/pmm.swift). RAM is identity-mapped,
// so a physical frame address doubles as its kernel pointer.
//
// This is a behaviour-preserving port: descriptor bit encodings, the L0->L3
// walk, the 1 GiB/2 MiB block handling in translate, the user-half free walk
// (L1 index >= 2) in destroy, and the switch-to-kernel-first safety in destroy
// are identical to the C original. Symbols are exported with C ABI via @_cdecl
// so the io.h prototypes resolve for Swift callers (process.swift, exec.swift),
// exactly as pmm.swift pairs pmm_alloc_page with its io.h prototype.

private let PAGE_SIZE: UInt = 4096
private let ENTRIES_PER_TABLE = 512

private let DESC_VALID: UInt64    = 1 << 0
private let DESC_TABLE: UInt64    = 1 << 1
private let DESC_AF: UInt64       = 1 << 10
private let DESC_SH_INNER: UInt64 = 3 << 8
private let DESC_AP_EL1_RW: UInt64 = 0 << 6
private let DESC_AP_EL0_RW: UInt64 = 1 << 6
private let DESC_AP_EL0_RO: UInt64 = 3 << 6
private let DESC_ATTR_SHIFT: UInt64 = 2
private let DESC_UXN: UInt64 = 1 << 54
private let DESC_PXN: UInt64 = 1 << 53

private let ATTR_NORMAL: UInt32 = 0
private let ATTR_DEVICE: UInt32 = 1

private let BLOCK_1G_MASK: UInt64 = 0x0000_ffff_c000_0000
private let BLOCK_2M_MASK: UInt64 = 0x0000_ffff_ffe0_0000
private let PAGE_4K_MASK: UInt64  = 0x0000_ffff_ffff_f000

// --- page-table entry access -----------------------------------------------
// A table is a 4 KiB frame; RAM is identity-mapped so its PA is its pointer.
// Entry `idx` is a little-endian UInt64 at byte offset idx*8.
@inline(__always)
private func tableLoad(_ table: UInt, _ idx: Int) -> UInt64 {
    UnsafeRawPointer(bitPattern: table)!.load(fromByteOffset: idx * 8, as: UInt64.self)
}
@inline(__always)
private func tableStore(_ table: UInt, _ idx: Int, _ value: UInt64) {
    UnsafeMutableRawPointer(bitPattern: table)!.storeBytes(of: value, toByteOffset: idx * 8, as: UInt64.self)
}

// --- descriptor builders (bit-for-bit as vm_early.c) ------------------------
private func tableDesc(_ tableAddr: UInt64) -> UInt64 {
    (tableAddr & PAGE_4K_MASK) | DESC_TABLE | DESC_VALID
}

private func memAttrs(_ attrIndex: UInt32, _ executable: Bool, _ userAccess: Bool, _ userReadOnly: Bool) -> UInt64 {
    var desc = DESC_AF
    if userReadOnly {
        desc |= DESC_AP_EL0_RO
    } else if userAccess {
        desc |= DESC_AP_EL0_RW
    } else {
        desc |= DESC_AP_EL1_RW
    }
    if !executable {
        desc |= DESC_UXN | DESC_PXN
    } else if userAccess {
        desc |= DESC_PXN
    }
    desc |= UInt64(attrIndex) << DESC_ATTR_SHIFT
    if attrIndex == ATTR_NORMAL {
        desc |= DESC_SH_INNER
    }
    return desc
}

private func blockDesc1G(_ pa: UInt64, _ attrIndex: UInt32) -> UInt64 {
    let executable = attrIndex == ATTR_NORMAL
    return (pa & BLOCK_1G_MASK) | memAttrs(attrIndex, executable, false, false) | DESC_VALID
}

private func permPageDesc(_ pa: UInt, _ perm: Int32) -> UInt64 {
    let executable: Bool, user: Bool, readOnly: Bool
    switch perm {
    case 1: executable = true;  user = true;  readOnly = true   // USER_CODE
    case 2: executable = false; user = true;  readOnly = false  // USER_DATA
    default: executable = true; user = false; readOnly = false  // KERNEL_RW
    }
    return (UInt64(pa) & PAGE_4K_MASK)
         | memAttrs(ATTR_NORMAL, executable, user, readOnly)
         | DESC_TABLE | DESC_VALID
}

// --- mmap/mprotect leaf descriptors (Track B) -------------------------------
// PROT bitmask (matches userland/lib/swift_user.h / mman.h): the mmap/mprotect
// surface that JIT runtimes (V8, the JVM) and large Swift apps need.
let PROT_READ: Int32  = 1
let PROT_WRITE: Int32 = 2
let PROT_EXEC: Int32  = 4

// Build a 4 KiB leaf descriptor for `pa` from a PROT bitmask, mapped into the
// EL0 (user) half. memAttrs already encodes the W^X levers: executable drives
// UXN/PXN, userReadOnly drives AP. A page is user-accessible, executable iff
// PROT_EXEC, and read-only unless PROT_WRITE — exactly mmap/mprotect semantics.
//
// W^X is enforced defensively here as well as at the syscall boundary: a leaf is
// never simultaneously writable and executable. PROT_WRITE|PROT_EXEC returns 0
// (an invalid descriptor, DESC_VALID clear), which callers treat as EINVAL.
// PROT_NONE (no bits) also yields 0 — there is no "mapped but inaccessible" leaf
// in this minimal surface, so callers reject it rather than map a present page
// the process cannot touch.
func protPageDesc(_ pa: UInt, _ prot: Int32) -> UInt64 {
    if (prot & PROT_WRITE) != 0 && (prot & PROT_EXEC) != 0 { return 0 } // W^X
    if (prot & (PROT_READ | PROT_WRITE | PROT_EXEC)) == 0 { return 0 }  // PROT_NONE
    let executable = (prot & PROT_EXEC) != 0
    let readOnly = (prot & PROT_WRITE) == 0
    return (UInt64(pa) & PAGE_4K_MASK)
         | memAttrs(ATTR_NORMAL, executable, /*userAccess*/ true, readOnly)
         | DESC_TABLE | DESC_VALID
}

private func zeroTable(_ table: UInt) {
    for i in 0..<ENTRIES_PER_TABLE {
        tableStore(table, i, 0)
    }
}

// Return the next-level table for `idx`, allocating+linking it if absent.
// Returns 0 on allocation failure (matches the C NULL return).
private func nextTable(_ table: UInt, _ idx: Int) -> UInt {
    let desc = tableLoad(table, idx)
    if (desc & DESC_VALID) != 0 {
        return UInt(desc & PAGE_4K_MASK)
    }
    let frame = pmm_alloc_page()
    if frame == 0 {
        return 0
    }
    zeroTable(frame)
    tableStore(table, idx, tableDesc(UInt64(frame)))
    return frame
}

// Descend L0->L1->L2 for `va` and return the L3 table base that holds its
// 4 KiB leaf. With allocate=true the intermediate tables are created on demand
// (the path map() and clone() take); returns 0 if a level is missing/cannot be
// allocated. This is the single-VA allocating walk shared by map and clone.
// translate() keeps its own block-aware walk (it must combine a 1 GiB/2 MiB
// block base with the low offset), and destroy() does a full-tree sweep, so
// neither routes through here.
private func walkToL3(_ ttbr0: UInt, _ va: UInt, allocate: Bool) -> UInt {
    var table = ttbr0
    // L0, L1, L2 shifts {39, 30, 21} == 39 - 9*level for level 0..2.
    for level in 0..<3 {
        let idx = Int((va >> UInt(39 - 9 * level)) & 0x1ff)
        let next: UInt
        if allocate {
            next = nextTable(table, idx)
        } else {
            let desc = tableLoad(table, idx)
            next = (desc & DESC_VALID) != 0 ? UInt(desc & PAGE_4K_MASK) : 0
        }
        if next == 0 { return 0 }
        table = next
    }
    return table
}

// Walk-allocate to L3 and write `leafDesc` for `va`. Returns false if the walk
// could not allocate a table. The leaf descriptor is supplied by the caller so
// the bit pattern stays exact: map() builds it with permPageDesc(); clone()
// rebases the parent leaf onto a fresh frame, preserving its perm/attr bits.
// No barrier here — callers issue the appropriate dsb/tlbi (per-page in map,
// one bulk flush in clone).
private func linkPage(_ ttbr0: UInt, _ va: UInt, _ leafDesc: UInt64) -> Bool {
    let l3 = walkToL3(ttbr0, va, allocate: true)
    if l3 == 0 { return false }
    tableStore(l3, Int((va >> 12) & 0x1ff), leafDesc)
    return true
}

// Allocate a fresh frame and copy `srcPA`'s 4 KiB into it; returns the new PA,
// or 0 on allocation failure. The eager-fork per-page copy. (A later track will
// swap this for a copy-on-write share.)
private func copyFrame(_ srcPA: UInt) -> UInt {
    let dstPA = pmm_alloc_page()
    if dstPA == 0 { return 0 }
    UnsafeMutableRawPointer(bitPattern: dstPA)!
        .copyMemory(from: UnsafeRawPointer(bitPattern: srcPA)!, byteCount: Int(PAGE_SIZE))
    return dstPA
}

@_cdecl("mmu_kernel_ttbr0")
func mmuKernelTtbr0() -> UInt {
    return vm_kernel_l0_table()
}

@_cdecl("address_space_create")
func addressSpaceCreate() -> UInt {
    let l0 = pmm_alloc_page()
    let l1 = pmm_alloc_page()
    if l0 == 0 || l1 == 0 {
        return 0
    }
    zeroTable(l0)
    zeroTable(l1)

    tableStore(l0, 0, tableDesc(UInt64(l1)))
    // Identity-map the kernel and device 1 GiB blocks into every space. The
    // split is board-specific (see mmu_init_identity_map): the kernel must stay
    // executable (normal) while MMIO stays device after a TTBR0 switch.
#if BOARD_VIRTUALBOX
    tableStore(l1, 0, blockDesc1G(0x0000_0000, ATTR_NORMAL))
    tableStore(l1, 3, blockDesc1G(0xC000_0000, ATTR_DEVICE))
#else
    tableStore(l1, 0, blockDesc1G(0x0000_0000, ATTR_DEVICE))
    tableStore(l1, 1, blockDesc1G(0x4000_0000, ATTR_NORMAL))
#endif
    return l0
}

@_cdecl("address_space_map")
func addressSpaceMap(_ ttbr0: UInt, _ va: UInt, _ pa: UInt, _ perm: Int32) -> Int32 {
    if (va & (PAGE_SIZE - 1)) != 0 || (pa & (PAGE_SIZE - 1)) != 0 {
        return -1
    }
    if !linkPage(ttbr0, va, permPageDesc(pa, perm)) {
        return -2
    }
    dsb_sy()
    tlbi_va(va)
    return 0
}

// --- mmap / munmap / mprotect (Track B) -------------------------------------
// Anonymous mmap: map `pageCount` fresh, zero-filled frames at [va, va+n*4K)
// with PROT bits `prot`, in the EL0 half of `ttbr0`. The caller (process.swift)
// owns the VA cursor and page accounting and supplies an aligned base `va`.
// Returns 0 on success, or a negative errno. On any mid-map failure every frame
// already linked here is rolled back, so a failed mmap leaves no partial region.
// Frames are zeroed because anonymous memory must read as 0.
@_cdecl("address_space_mmap")
func addressSpaceMmap(_ ttbr0: UInt, _ va: UInt, _ pageCount: UInt, _ prot: Int32) -> Int32 {
    if (va & (PAGE_SIZE - 1)) != 0 { return -22 } // EINVAL
    if pageCount == 0 { return -22 }
    // Reject PROT_WRITE|PROT_EXEC (W^X) and PROT_NONE up front: protPageDesc
    // would return an invalid descriptor for both.
    if protPageDesc(0, prot) == 0 { return -22 }

    var i: UInt = 0
    while i < pageCount {
        let cur = va + i * PAGE_SIZE
        let frame = pmm_alloc_page()
        if frame == 0 {
            unmapRange(ttbr0, va, i) // roll back the frames mapped so far
            return -12 // ENOMEM
        }
        zeroFrame(frame)
        if !linkPage(ttbr0, cur, protPageDesc(frame, prot)) {
            pmm_free_page(frame)
            unmapRange(ttbr0, va, i)
            return -12
        }
        i += 1
    }
    dsb_sy()
    tlbi_all() // one bulk flush for the whole region
    return 0
}

// munmap: clear the leaf descriptors over [va, va+n*4K), free each backing
// frame, and flush. Pages with no live mapping are skipped (munmap of a hole is
// not an error). The page tables themselves are kept (cheap, and the region is
// typically re-mmap'd); address_space_destroy reclaims them at process exit.
@_cdecl("address_space_munmap")
func addressSpaceMunmap(_ ttbr0: UInt, _ va: UInt, _ pageCount: UInt) -> Int32 {
    if (va & (PAGE_SIZE - 1)) != 0 { return -22 }
    unmapRange(ttbr0, va, pageCount)
    dsb_sy()
    tlbi_all()
    return 0
}

// mprotect: change the PROT bits over [va, va+n*4K), preserving each page's
// backing frame. Walks to the existing L3 leaf (no allocation), rebuilds the
// descriptor from the same PA with the new prot, and rewrites it. A hole (no
// live leaf) in the range is rejected (ENOMEM, as POSIX). The W^X / PROT_NONE
// rejection lives in protPageDesc, so a bad prot fails before any leaf is
// touched. Returns 0 on success or a negative errno.
@_cdecl("address_space_mprotect")
func addressSpaceMprotect(_ ttbr0: UInt, _ va: UInt, _ pageCount: UInt, _ prot: Int32) -> Int32 {
    if (va & (PAGE_SIZE - 1)) != 0 { return -22 }
    if pageCount == 0 { return -22 }
    if protPageDesc(0, prot) == 0 { return -22 } // W^X + PROT_NONE guard

    // Pre-validate: every page in the range must already be mapped, so we never
    // change a prefix and then fail on a hole.
    var i: UInt = 0
    while i < pageCount {
        let cur = va + i * PAGE_SIZE
        let l3 = walkToL3(ttbr0, cur, allocate: false)
        if l3 == 0 { return -12 } // ENOMEM: address not mapped
        if (tableLoad(l3, Int((cur >> 12) & 0x1ff)) & DESC_VALID) == 0 { return -12 }
        i += 1
    }

    i = 0
    while i < pageCount {
        let cur = va + i * PAGE_SIZE
        let l3 = walkToL3(ttbr0, cur, allocate: false)
        let leafIdx = Int((cur >> 12) & 0x1ff)
        let oldDesc = tableLoad(l3, leafIdx)
        let pa = UInt(oldDesc & PAGE_4K_MASK)
        tableStore(l3, leafIdx, protPageDesc(pa, prot))
        i += 1
    }
    dsb_sy()
    tlbi_all()
    return 0
}

// Clear and free up to `pageCount` live leaf frames starting at `va`. Shared by
// munmap and by mmap's rollback path. No barrier — the caller flushes.
private func unmapRange(_ ttbr0: UInt, _ va: UInt, _ pageCount: UInt) {
    var i: UInt = 0
    while i < pageCount {
        let cur = va + i * PAGE_SIZE
        let l3 = walkToL3(ttbr0, cur, allocate: false)
        if l3 != 0 {
            let leafIdx = Int((cur >> 12) & 0x1ff)
            let desc = tableLoad(l3, leafIdx)
            if (desc & DESC_VALID) != 0 {
                tableStore(l3, leafIdx, 0)
                pmm_free_page(UInt(desc & PAGE_4K_MASK))
            }
        }
        i += 1
    }
}

@inline(__always)
private func zeroFrame(_ frame: UInt) {
    let p = UnsafeMutableRawPointer(bitPattern: frame)!
    var off = 0
    while off < Int(PAGE_SIZE) {
        p.storeBytes(of: UInt64(0), toByteOffset: off, as: UInt64.self)
        off += 8
    }
}

@_cdecl("address_space_switch")
func addressSpaceSwitch(_ ttbr0: UInt) {
    write_ttbr0_el1(UInt64(ttbr0))
    dsb_sy()
    isb()
    tlbi_all()
}

@_cdecl("address_space_translate")
func addressSpaceTranslate(_ ttbr0: UInt, _ va: UInt) -> UInt {
    var table = ttbr0
    // Level shifts {39, 30, 21, 12} == 39 - 9*level for level 0..3.
    for level in 0..<4 {
        let shift = UInt(39 - 9 * level)
        let idx = Int((va >> shift) & 0x1ff)
        let desc = tableLoad(table, idx)
        if (desc & DESC_VALID) == 0 {
            return 0
        }
        if level < 3 && (desc & DESC_TABLE) == 0 {
            // 1 GiB or 2 MiB block: combine block base with the low offset.
            let mask: UInt64 = (level == 1) ? BLOCK_1G_MASK : BLOCK_2M_MASK
            let blockSize: UInt = (level == 1) ? 0x4000_0000 : 0x20_0000
            return UInt(desc & mask) | (va & (blockSize - 1))
        }
        if level == 3 {
            return UInt(desc & PAGE_4K_MASK) | (va & (PAGE_SIZE - 1))
        }
        table = UInt(desc & PAGE_4K_MASK)
    }
    return 0
}

// Tear down a per-process address space created by address_space_create() /
// address_space_clone(): free every USER leaf frame (VA >= 0x8000_0000, i.e. L1
// index >= 2) and the L3/L2 page tables that map them, then the L1 and L0
// frames. The kernel/device identity entries (L1 indices 0,1) are 1 GiB *block*
// descriptors, not tables — they own no frames and are skipped by the
// DESC_TABLE test, so the shared kernel mapping is never freed. Eager fork
// gives each space private leaf frames (no COW sharing), so a flat free is
// correct — no refcounting needed.
//
// Frame reclamation is the inverse of the leak that made the OS unusable for
// long-running workloads (~2 MiB lost per busybox command). Safe to call on a
// partially built space (failed createProcess) — it frees whatever exists.
//
// If the doomed space is the currently installed TTBR0 (the common case when
// the kernel scheduler reaps a just-exited top-level process, whose tables are
// still live in the register), switch to the kernel identity map first so the
// MMU never walks frames we are about to hand back to the PMM.
@_cdecl("address_space_destroy")
func addressSpaceDestroy(_ ttbr0: UInt) {
    if ttbr0 == 0 || ttbr0 == vm_kernel_l0_table() {
        return
    }

    let cur = read_ttbr0_el1()
    if UInt(cur & PAGE_4K_MASK) == ttbr0 {
        addressSpaceSwitch(vm_kernel_l0_table())
    }

    let l0 = ttbr0
    let d0 = tableLoad(l0, 0)
    if (d0 & DESC_VALID) != 0 && (d0 & DESC_TABLE) != 0 {
        let l1 = UInt(d0 & PAGE_4K_MASK)
        for i1 in 2..<ENTRIES_PER_TABLE {
            let d1 = tableLoad(l1, i1)
            if (d1 & DESC_VALID) == 0 || (d1 & DESC_TABLE) == 0 { continue }
            let l2 = UInt(d1 & PAGE_4K_MASK)
            for i2 in 0..<ENTRIES_PER_TABLE {
                let d2 = tableLoad(l2, i2)
                if (d2 & DESC_VALID) == 0 || (d2 & DESC_TABLE) == 0 { continue }
                let l3 = UInt(d2 & PAGE_4K_MASK)
                for i3 in 0..<ENTRIES_PER_TABLE {
                    let d3 = tableLoad(l3, i3)
                    if (d3 & DESC_VALID) != 0 {
                        pmm_free_page(UInt(d3 & PAGE_4K_MASK)) // leaf user frame
                    }
                }
                pmm_free_page(l3) // L3 table
            }
            pmm_free_page(l2) // L2 table
        }
        pmm_free_page(l1) // L1 table
    }
    pmm_free_page(ttbr0) // L0 table
}

// Eager fork: create a new address space and copy every mapped USER page
// (VA >= 0x8000_0000, i.e. L1 index >= 2) from `parent`, preserving each page's
// permission/attribute bits. The kernel/device identity blocks come fresh from
// address_space_create(). Returns the child TTBR0, or 0 on failure.
@_cdecl("address_space_clone")
func addressSpaceClone(_ parent: UInt) -> UInt {
    let child = addressSpaceCreate()
    if child == 0 {
        return 0
    }
    let pl0 = parent
    let cl0 = child
    if (tableLoad(pl0, 0) & DESC_VALID) == 0 {
        return child
    }
    let pl1 = UInt(tableLoad(pl0, 0) & PAGE_4K_MASK)

    for i1 in 2..<ENTRIES_PER_TABLE {
        let d1 = tableLoad(pl1, i1)
        if (d1 & DESC_VALID) == 0 || (d1 & DESC_TABLE) == 0 { continue }
        let pl2 = UInt(d1 & PAGE_4K_MASK)
        for i2 in 0..<ENTRIES_PER_TABLE {
            let d2 = tableLoad(pl2, i2)
            if (d2 & DESC_VALID) == 0 || (d2 & DESC_TABLE) == 0 { continue }
            let pl3 = UInt(d2 & PAGE_4K_MASK)
            for i3 in 0..<ENTRIES_PER_TABLE {
                let d3 = tableLoad(pl3, i3)
                if (d3 & DESC_VALID) == 0 { continue }

                let va: UInt = (UInt(i1) << 30) | (UInt(i2) << 21) | (UInt(i3) << 12)
                let srcpa = UInt(d3 & PAGE_4K_MASK)
                let dstpa = copyFrame(srcpa)
                if dstpa == 0 { return 0 }
                // Rebase the parent leaf onto the fresh frame, preserving its
                // perm/attr bits exactly (no permPageDesc round-trip).
                let leafDesc = (d3 & ~PAGE_4K_MASK) | (UInt64(dstpa) & PAGE_4K_MASK)
                if !linkPage(cl0, va, leafDesc) { return 0 }
            }
        }
    }
    dsb_sy()
    tlbi_all()
    return child
}

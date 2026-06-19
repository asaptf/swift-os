// SPDX-License-Identifier: Apache-2.0
// elf.swift — minimal static ELF64 loader for AArch64 EL0 programs.
//
// Parses an in-memory ET_EXEC image and maps its PT_LOAD segments into a target
// address space (TTBR0), drawing frames from the PMM. Loading is page-driven,
// not segment-driven: two segments may share a page (our hello.elf packs text
// and rodata into one), so we allocate a frame per distinct virtual page and
// copy each segment's bytes into place. Per-page permission is "executable wins"
// (a page touched by any PF_X segment is mapped user-RX, otherwise user-RW).
//
// Returns the entry virtual address, or 0 on any validation/allocation failure.
//
// Swift rewrite of the former elf.c: pure parsing/copy logic, no MMIO or asm. It
// calls the address-space and PMM bridges (io.h) just as the C version did. The
// kernel runs at EL1 with SCTLR_EL1.A clear (see vm.c mmu_enable_sctlr), so the
// `.load` reads below tolerate any in-image field alignment, exactly like the C
// struct-pointer casts they replace.

private let PT_LOAD: UInt32 = 1
private let PF_X: UInt32 = 1
private let ET_EXEC: UInt16 = 2
private let EM_AARCH64: UInt16 = 183
private let ELF_PAGE: UInt = 4096

// Number of distinct user pages the most recent elfLoad mapped (for /bin/top's
// per-process resident-memory accounting). Set at the start of each elfLoad.
private var elfLoadPages: UInt = 0

func elfLastLoadPages() -> UInt { elfLoadPages }

private func elfPageDown(_ v: UInt) -> UInt { v & ~(ELF_PAGE - 1) }
private func elfPageUp(_ v: UInt) -> UInt { (v + ELF_PAGE - 1) & ~(ELF_PAGE - 1) }

// Zero a freshly allocated physical (identity-mapped) frame; covers .bss.
private func elfZeroFrame(_ pa: UInt) {
    let p = UnsafeMutableRawPointer(bitPattern: pa)!
    var i = 0
    while i < Int(ELF_PAGE) { p.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self); i += 1 }
}

// Copy `len` bytes to virtual address `va` in `ttbr0`, walking page by page and
// resolving each page to its physical (identity-mapped) frame.
private func elfCopyToUser(_ ttbr0: UInt, _ va: UInt, _ src: UnsafeRawPointer, _ len: UInt) -> Bool {
    var va = va
    var src = src
    var len = len
    while len > 0 {
        let off = va & (ELF_PAGE - 1)
        var chunk = ELF_PAGE - off
        if chunk > len { chunk = len }
        let pa = address_space_translate(ttbr0, va)
        if pa == 0 { return false }
        let dst = UnsafeMutableRawPointer(bitPattern: pa)!
        var i = 0
        while i < Int(chunk) {
            dst.storeBytes(of: src.load(fromByteOffset: i, as: UInt8.self),
                           toByteOffset: i, as: UInt8.self)
            i += 1
        }
        va += chunk
        src = src + Int(chunk)
        len -= chunk
    }
    return true
}

func elfLoad(_ ttbr0: UInt, _ image: UnsafeRawPointer?, _ size: UInt) -> UInt {
    guard let base = image else { return 0 }
    if size < 64 { return 0 }   // sizeof(Elf64_Ehdr)
    elfLoadPages = 0

    // e_ident: magic + 64-bit, little-endian class. Byte reads, always aligned.
    if base.load(fromByteOffset: 0, as: UInt8.self) != 0x7f { return 0 }
    if base.load(fromByteOffset: 1, as: UInt8.self) != UInt8(ascii: "E") { return 0 }
    if base.load(fromByteOffset: 2, as: UInt8.self) != UInt8(ascii: "L") { return 0 }
    if base.load(fromByteOffset: 3, as: UInt8.self) != UInt8(ascii: "F") { return 0 }
    if base.load(fromByteOffset: 4, as: UInt8.self) != 2 { return 0 } // ELFCLASS64
    if base.load(fromByteOffset: 5, as: UInt8.self) != 1 { return 0 } // little-endian

    let eType = base.load(fromByteOffset: 16, as: UInt16.self)
    let eMachine = base.load(fromByteOffset: 18, as: UInt16.self)
    if eType != ET_EXEC || eMachine != EM_AARCH64 { return 0 }

    let eEntry = base.load(fromByteOffset: 24, as: UInt64.self)
    let ePhoff = base.load(fromByteOffset: 32, as: UInt64.self)
    let ePhentsize = base.load(fromByteOffset: 54, as: UInt16.self)
    let ePhnum = base.load(fromByteOffset: 56, as: UInt16.self)

    // Overflow-safe bound: ePhoff is attacker-controlled, so never form
    // `ePhoff + table` — Swift traps on UInt64 overflow, which a malformed image
    // could use to crash EL1. Compare the table size against the space remaining
    // after ePhoff instead (ePhnum*ePhentsize fits in UInt64; both are u16).
    let phTableBytes = UInt64(ePhnum) * UInt64(ePhentsize)
    if ePhoff > UInt64(size) || phTableBytes > UInt64(size) - ePhoff { return 0 }

    var i: UInt16 = 0
    while i < ePhnum {
        let ph = base + Int(ePhoff) + Int(i) * Int(ePhentsize)
        i += 1
        let pType = ph.load(fromByteOffset: 0, as: UInt32.self)
        let pMemsz = ph.load(fromByteOffset: 40, as: UInt64.self)
        if pType != PT_LOAD || pMemsz == 0 { continue }

        let pFlags = ph.load(fromByteOffset: 4, as: UInt32.self)
        let pOffset = ph.load(fromByteOffset: 8, as: UInt64.self)
        let pVaddr = ph.load(fromByteOffset: 16, as: UInt64.self)
        let pFilesz = ph.load(fromByteOffset: 32, as: UInt64.self)
        // Same overflow discipline: pOffset/pFilesz/pMemsz are attacker-controlled.
        if pOffset > UInt64(size) || pFilesz > UInt64(size) - pOffset
            || pFilesz > pMemsz { return 0 }
        // pVaddr + pMemsz (rounded up to a page) must not overflow the address
        // space — otherwise forming vaEnd below would trap EL1. Reject such a
        // segment; the legitimate user VA window is far below UInt.max.
        if pMemsz > UInt64(UInt.max) - UInt64(ELF_PAGE) { return 0 }
        if pVaddr > UInt64(UInt.max) - UInt64(ELF_PAGE) - pMemsz { return 0 }

        let perm = (pFlags & PF_X) != 0 ? Int32(VM_PERM_USER_CODE) : Int32(VM_PERM_USER_DATA)
        let vaStart = elfPageDown(UInt(pVaddr))
        let vaEnd = elfPageUp(UInt(pVaddr) + UInt(pMemsz))

        var va = vaStart
        while va < vaEnd {
            var pa = address_space_translate(ttbr0, va)
            if pa == 0 {
                pa = pmm_alloc_page()
                if pa == 0 { return 0 }
                elfZeroFrame(pa)
                if address_space_map(ttbr0, va, pa, perm) != 0 {
                    pmm_free_page(pa)
                    return 0
                }
                elfLoadPages += 1 // a fresh frame (not a perm upgrade of a shared page)
            } else if perm == Int32(VM_PERM_USER_CODE) {
                // A previous (data) segment already mapped this page; executable wins.
                if address_space_map(ttbr0, va, pa, Int32(VM_PERM_USER_CODE)) != 0 { return 0 }
            }
            va += ELF_PAGE
        }

        if !elfCopyToUser(ttbr0, UInt(pVaddr), base + Int(pOffset), UInt(pFilesz)) { return 0 }
    }

    return UInt(eEntry)
}

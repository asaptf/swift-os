// SPDX-License-Identifier: Apache-2.0
// elf_loader_test.swift — aggressive host unit test for kernel/user/elf.swift.
//
// elfLoad() parses an attacker-controllable ET_EXEC image (it comes from disk /
// the package store) and maps its PT_LOAD segments. In the OS it only ever runs
// on the trusted binaries we ship, so its REJECT paths are never exercised. This
// test links elfLoad directly against a fake address space + PMM (frames are real
// host pages so copy-to-user actually writes), feeds it malformed and HOSTILE
// images, and asserts it returns 0 (reject) instead of over-reading, mis-mapping,
// or trapping EL1.
//
// It specifically pins the integer-overflow guards: e_phoff, p_offset, and
// p_vaddr+p_memsz are u64 fields a crafted image can set near UInt.max; without
// the bounds being written overflow-safe, `ePhoff + table` / `pOffset + pFilesz`
// / `pVaddr + pMemsz` trap on overflow in EL1 — a remote-ish DoS on any box that
// is handed a bad binary.
//
//   compiled as:  swiftc tests/elf_loader_test.swift kernel/user/elf.swift

import Foundation

// ---- bridges elf.swift expects (normally from io.h); fakes for the host -----

let VM_PERM_USER_CODE: Int32 = 1
let VM_PERM_USER_DATA: Int32 = 2

let FAKE_PAGE = 4096
var fakeFrames: [UInt: UnsafeMutableRawPointer] = [:]   // page-base VA -> host frame
var fakeMapPerm: [UInt: Int32] = [:]                    // page-base VA -> last perm mapped
var allocatedFrames: [UnsafeMutableRawPointer] = []
var pmmRemaining = Int.max

func resetFakeVM(pmm: Int = Int.max) {
    for f in allocatedFrames { f.deallocate() }
    allocatedFrames.removeAll()
    fakeFrames.removeAll()
    fakeMapPerm.removeAll()
    pmmRemaining = pmm
}

func pmm_alloc_page() -> UInt {
    if pmmRemaining <= 0 { return 0 }
    pmmRemaining -= 1
    let f = UnsafeMutableRawPointer.allocate(byteCount: FAKE_PAGE, alignment: FAKE_PAGE)
    allocatedFrames.append(f)
    return UInt(bitPattern: f)
}
func pmm_free_page(_ pa: UInt) { /* host frames are reclaimed by resetFakeVM */ }

func address_space_map(_ ttbr0: UInt, _ va: UInt, _ pa: UInt, _ perm: Int32) -> Int32 {
    let pb = va & ~UInt(FAKE_PAGE - 1)
    fakeFrames[pb] = UnsafeMutableRawPointer(bitPattern: pa)
    fakeMapPerm[pb] = perm
    return 0
}
func address_space_translate(_ ttbr0: UInt, _ va: UInt) -> UInt {
    let pb = va & ~UInt(FAKE_PAGE - 1)
    guard let f = fakeFrames[pb] else { return 0 }
    return UInt(bitPattern: f) + (va & UInt(FAKE_PAGE - 1))
}

// ---- harness ----------------------------------------------------------------

var failures = 0
func check(_ cond: Bool, _ what: String) {
    if cond { print("ok: \(what)") }
    else { failures += 1; FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8)) }
}

func putU16(_ b: inout [UInt8], _ off: Int, _ v: UInt16) {
    b[off] = UInt8(v & 0xff); b[off + 1] = UInt8((v >> 8) & 0xff)
}
func putU32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
    for i in 0..<4 { b[off + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) }
}
func putU64(_ b: inout [UInt8], _ off: Int, _ v: UInt64) {
    for i in 0..<8 { b[off + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
}

let ENTRY: UInt64 = 0x8000_0000

// A known-good single-PT_LOAD ELF64: 64B Ehdr, one 56B Phdr at 64, 16B content at
// 120. Maps one R|X page at ENTRY filled with 0xAA.
func validELF() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 136)
    b[0] = 0x7f; b[1] = UInt8(ascii: "E"); b[2] = UInt8(ascii: "L"); b[3] = UInt8(ascii: "F")
    b[4] = 2; b[5] = 1; b[6] = 1                                   // class64, LE, version
    putU16(&b, 16, 2)                                             // e_type = ET_EXEC
    putU16(&b, 18, 183)                                          // e_machine = AArch64
    putU64(&b, 24, ENTRY)                                        // e_entry
    putU64(&b, 32, 64)                                           // e_phoff
    putU16(&b, 52, 64)                                          // e_ehsize
    putU16(&b, 54, 56)                                          // e_phentsize
    putU16(&b, 56, 1)                                           // e_phnum
    // Phdr @ 64
    putU32(&b, 64, 1)                                           // p_type = PT_LOAD
    putU32(&b, 68, 5)                                           // p_flags = R|X
    putU64(&b, 72, 120)                                         // p_offset
    putU64(&b, 80, ENTRY)                                       // p_vaddr
    putU64(&b, 96, 16)                                          // p_filesz
    putU64(&b, 104, 16)                                         // p_memsz
    for i in 0..<16 { b[120 + i] = 0xAA }                       // content
    return b
}

// A two-segment ELF where a data segment and a code segment share one page, to
// exercise the "executable wins" per-page permission upgrade.
func overlapELF() -> [UInt8] {
    let page: UInt64 = 0x9000_0000
    var b = [UInt8](repeating: 0, count: 192)                   // 64 + 2*56 + 16 content
    b[0] = 0x7f; b[1] = UInt8(ascii: "E"); b[2] = UInt8(ascii: "L"); b[3] = UInt8(ascii: "F")
    b[4] = 2; b[5] = 1; b[6] = 1
    putU16(&b, 16, 2); putU16(&b, 18, 183)
    putU64(&b, 24, page)
    putU64(&b, 32, 64); putU16(&b, 52, 64); putU16(&b, 54, 56); putU16(&b, 56, 2)
    // Seg 0: data (R), vaddr page+0, 8 bytes at file 176
    putU32(&b, 64, 1); putU32(&b, 68, 4)
    putU64(&b, 72, 176); putU64(&b, 80, page); putU64(&b, 96, 8); putU64(&b, 104, 8)
    // Seg 1: code (R|X), vaddr page+16 (same page), 8 bytes at file 184
    putU32(&b, 120, 1); putU32(&b, 124, 5)
    putU64(&b, 128, 184); putU64(&b, 136, page + 16); putU64(&b, 152, 8); putU64(&b, 160, 8)
    for i in 0..<16 { b[176 + i] = 0xBB }
    return b
}

func load(_ image: [UInt8], pmm: Int = Int.max) -> UInt {
    resetFakeVM(pmm: pmm)
    return image.withUnsafeBytes { elfLoad(0x1000, $0.baseAddress, UInt($0.count)) }
}

@main
struct ELFLoaderTest {
    static func main() {
        // 1. Valid image loads: entry returned, one page mapped R|X, content copied.
        do {
            let r = load(validELF())
            check(r == UInt(ENTRY), "valid ELF returns its entry")
            check(elfLastLoadPages() == 1, "valid ELF maps exactly one page")
            check(fakeMapPerm[UInt(ENTRY)] == VM_PERM_USER_CODE, "R|X segment mapped USER_CODE")
            if let frame = fakeFrames[UInt(ENTRY)] {
                let ok = (0..<16).allSatisfy { frame.load(fromByteOffset: $0, as: UInt8.self) == 0xAA }
                check(ok, "segment bytes copied into the mapped frame")
            } else { check(false, "entry page is mapped") }
        }

        // 2. Structural rejects (must all return 0).
        check(load(Array(validELF().prefix(32))) == 0, "truncated (<64B) header rejected")
        do { var b = validELF(); b[0] = 0; check(load(b) == 0, "bad magic rejected") }
        do { var b = validELF(); b[4] = 1; check(load(b) == 0, "ELFCLASS32 rejected") }
        do { var b = validELF(); b[5] = 2; check(load(b) == 0, "big-endian rejected") }
        do { var b = validELF(); putU16(&b, 16, 3); check(load(b) == 0, "non-ET_EXEC rejected") }
        do { var b = validELF(); putU16(&b, 18, 62); check(load(b) == 0, "wrong e_machine rejected") }

        // 3. Bounds rejects.
        do { var b = validELF(); putU64(&b, 32, 130)             // phoff+56 > 136
             check(load(b) == 0, "phdr table past EOF rejected") }
        do { var b = validELF(); putU64(&b, 96, 200)             // filesz past EOF
             check(load(b) == 0, "p_filesz past EOF rejected") }
        do { var b = validELF(); putU64(&b, 104, 8)              // memsz 8 < filesz 16
             check(load(b) == 0, "p_filesz > p_memsz rejected") }

        // 4. Integer-overflow rejects — these TRAP EL1 without the overflow-safe
        //    bounds, so they are the highest-value cases.
        do { var b = validELF(); putU64(&b, 32, 0xFFFF_FFFF_FFFF_FFFF)
             check(load(b) == 0, "max e_phoff rejected (would overflow-trap ePhoff+table)") }
        do { var b = validELF(); putU64(&b, 72, 0xFFFF_FFFF_FFFF_FFFF)
             check(load(b) == 0, "max p_offset rejected (would overflow-trap pOffset+filesz)") }
        do { var b = validELF(); putU64(&b, 104, 0xFFFF_FFFF_FFFF_FFFF)
             check(load(b) == 0, "max p_memsz rejected (would overflow-trap pVaddr+memsz)") }

        // 5. PMM exhaustion mid-load returns 0, not a partial/garbage mapping.
        check(load(validELF(), pmm: 0) == 0, "allocation failure rejected")

        // 6. "Executable wins": a page shared by a data and a code segment ends RX.
        do {
            let r = load(overlapELF())
            check(r != 0, "two-segment overlap loads")
            check(fakeMapPerm[0x9000_0000] == VM_PERM_USER_CODE,
                  "shared page upgraded to USER_CODE (executable wins)")
        }

        // 7. A PT_LOAD with p_memsz == 0 is skipped, not mapped (still valid image).
        do { var b = validELF(); putU64(&b, 104, 0)              // memsz 0
             let r = load(b)
             check(r == UInt(ENTRY) && elfLastLoadPages() == 0, "empty PT_LOAD skipped") }

        resetFakeVM()
        if failures == 0 {
            print("PASS: elfLoad rejects malformed/hostile binaries without over-read or overflow trap")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("FAIL: \(failures) elf assertion(s) failed\n".utf8))
            exit(1)
        }
    }
}

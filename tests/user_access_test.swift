// SPDX-License-Identifier: Apache-2.0
// user_access_test.swift — host unit test for kernel/user/user_access.swift.
//
// Every syscall that copies to/from EL0 goes through userReadableBuffer/
// userWritableBuffer/userCString. They are the kernel's guard against a user
// process handing in a kernel pointer, an unmapped page, a length that overflows
// va+count, or a range that straddles a mapped→unmapped boundary. In the OS these
// reject paths only fire on a buggy/hostile process, so they are barely exercised.
// This test links the guards against a fake address space and pins every rejection
// (and the few accept cases) so a regression that widens the window or drops an
// overflow check is caught on the host in milliseconds.
//
// NOTE: the helpers return a pointer at the user VA but never dereference it; this
// test only inspects nil-ness, so no fake VA is ever read.
//
//   compiled as:  swiftc tests/user_access_test.swift kernel/user/user_access.swift

import Foundation

// ---- fakes for the bridges user_access.swift depends on ---------------------

enum PageAllocator { static let pageSize: UInt = 4096 }

var uaMapped: Set<UInt> = []      // page-base VAs that translate succeeds on
var uaWritable: Set<UInt> = []    // page-base VAs that prepare-write succeeds on
var uaTtbr: UInt = 0x1000

func processCurrentAddressSpace() -> UInt { uaTtbr }
func processCurrentAddressSpaceActiveCpuMask() -> UInt64 { 1 }
func address_space_translate(_ ttbr0: UInt, _ va: UInt) -> UInt {
    let pb = va & ~(PageAllocator.pageSize - 1)
    return uaMapped.contains(pb) ? (pb | 0x1) : 0     // any nonzero "PA"
}
func addressSpacePrepareWriteForActiveCpuMask(_ ttbr0: UInt, _ va: UInt, _ mask: UInt64) -> Bool {
    let pb = va & ~(PageAllocator.pageSize - 1)
    return uaWritable.contains(pb)
}

// ---- harness ----------------------------------------------------------------

var failures = 0
func check(_ cond: Bool, _ what: String) {
    if cond { print("ok: \(what)") }
    else { failures += 1; FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8)) }
}

let MINVA: UInt = 0x8000_0000
let MAXVA: UInt = 0x4_0000_0000
let PAGE: UInt = 4096

@main
struct UserAccessTest {
    static func main() {
        uaMapped = []; uaWritable = []

        // ---- reject: kernel / device / out-of-window addresses --------------
        check(userReadableBuffer(0x4008_0000, 16) == nil, "kernel-range VA rejected")
        check(userReadableBuffer(0x0000_1000, 16) == nil, "low/device VA rejected")
        check(userReadableBuffer(MAXVA, 16) == nil, "VA at top of window rejected")
        check(userReadableBuffer(MAXVA + 0x1000, 16) == nil, "VA past window rejected")

        // ---- reject: overflow / oversized length ----------------------------
        check(userReadableBuffer(MINVA, UInt(Int.max) + 1) == nil, "count > Int.max rejected")
        // va+count would run past the window; guarded *before* forming va+count.
        check(userReadableBuffer(MAXVA - 0x10, 0x20) == nil, "range overrunning window rejected")
        check(userReadableBuffer(MAXVA - 0x1000, UInt.max) == nil, "near-UInt.max count rejected")

        // ---- reject: unmapped page ------------------------------------------
        check(userReadableBuffer(MINVA, 16) == nil, "unmapped user page rejected")

        // ---- accept: a fully mapped range -----------------------------------
        uaMapped = [MINVA]
        check(userReadableBuffer(MINVA, 16) != nil, "mapped user page accepted")
        check(userReadableBuffer(MINVA + 0x100, 0x80) != nil, "mapped sub-range accepted")

        // ---- straddling boundary: 2nd page unmapped must reject -------------
        // va in the last 16 bytes of page 0, count spills into page 1.
        let straddleVA = MINVA + PAGE - 16
        uaMapped = [MINVA]                                   // page 1 (MINVA+PAGE) NOT mapped
        check(userReadableBuffer(straddleVA, 0x20) == nil, "range crossing into unmapped page rejected")
        uaMapped = [MINVA, MINVA + PAGE]                     // map both pages
        check(userReadableBuffer(straddleVA, 0x20) != nil, "range crossing two mapped pages accepted")

        // ---- count == 0 is a valid empty buffer (never dereferenced) --------
        check(userReadableBuffer(MINVA, 0) != nil, "zero-length buffer at a VA accepted")
        check(userReadableBuffer(0, 0) != nil, "zero-length buffer at NULL accepted")

        // ---- writable buffer: must resolve the COW/write path ---------------
        uaMapped = [MINVA]; uaWritable = []
        check(userWritableBuffer(MINVA, 16) == nil, "mapped-but-unwritable page rejected for write")
        uaWritable = [MINVA]
        check(userWritableBuffer(MINVA, 16) != nil, "writable page accepted for write")
        check(userWritableBuffer(0x4008_0000, 16) == nil, "kernel-range VA rejected for write")

        // ---- userCString rejects (return before any dereference) ------------
        check(userCString(0) == nil, "NULL C-string rejected")
        check(userCString(MINVA, maxLen: 0) == nil, "non-positive maxLen rejected")
        check(userCString(0x4008_0000) == nil, "kernel-range C-string rejected")

        if failures == 0 {
            print("PASS: user_access guards reject kernel/unmapped/overflow/straddling ranges")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("FAIL: \(failures) user_access assertion(s) failed\n".utf8))
            exit(1)
        }
    }
}

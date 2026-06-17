// SPDX-License-Identifier: Apache-2.0
// user_access.swift — checked EL0 memory access helpers.
//
// Syscalls must not dereference user pointers directly. These helpers first
// reject kernel/device addresses, integer-overflowed ranges, huge lengths, and
// unmapped user pages in the current process address space. Writable buffers
// also resolve COW leaves before returning: kernel copies write through the
// current user VA, so they must not bypass the EL0 write-fault path.

private let userAccessMinVA: UInt = 0x8000_0000
// Top of the valid user VA window. T0SZ=16 gives a 48-bit TTBR0 space, so this
// is policy, not a hardware limit. Raised to 16 GiB so V8 (Node) can reserve its
// large — mostly virtual, committed on demand — heap/code arenas; the old 768 MiB
// window left only a 128 MiB mmap arena, which V8 intermittently exhausted and
// reported as a fatal OOM. See the user-VA map in kernel/user/process.swift.
private let userAccessMaxVA: UInt = 0x4_0000_0000
private let userAccessPageMask: UInt = PageAllocator.pageSize - 1
let userAccessMaxCString = 4096

private func userRangeMapped(_ va: UInt, _ count: UInt) -> Bool {
    if count == 0 { return true }
    if count > UInt(Int.max) { return false }
    // Bound before forming `va + count`: malformed user pointers must return an
    // errno, not trigger a Swift overflow trap in EL1.
    if va < userAccessMinVA || va >= userAccessMaxVA { return false }
    if count > userAccessMaxVA - va { return false }
    let last = va + count - 1

    let ttbr0 = processCurrentAddressSpace()
    if ttbr0 == 0 { return false }

    var page = va & ~userAccessPageMask
    let lastPage = last & ~userAccessPageMask
    while true {
        if address_space_translate(ttbr0, page) == 0 { return false }
        if page == lastPage { break }
        page += PageAllocator.pageSize
    }
    return true
}

private func userRangeWritable(_ va: UInt, _ count: UInt) -> Bool {
    if count == 0 { return true }
    if count > UInt(Int.max) { return false }
    // Same overflow discipline as userRangeMapped for copyout/COW paths.
    if va < userAccessMinVA || va >= userAccessMaxVA { return false }
    if count > userAccessMaxVA - va { return false }
    let last = va + count - 1

    let ttbr0 = processCurrentAddressSpace()
    if ttbr0 == 0 { return false }

    var page = va & ~userAccessPageMask
    let lastPage = last & ~userAccessPageMask
    let activeMask = processCurrentAddressSpaceActiveCpuMask()
    while true {
        if !addressSpacePrepareWriteForActiveCpuMask(ttbr0, page, activeMask) { return false }
        if page == lastPage { break }
        page += PageAllocator.pageSize
    }
    return true
}

func userReadableBuffer(_ va: UInt, _ count: UInt) -> UnsafePointer<UInt8>? {
    if count == 0 {
        return UnsafePointer<UInt8>(bitPattern: va == 0 ? userAccessMinVA : va)
    }
    guard userRangeMapped(va, count) else { return nil }
    return UnsafePointer<UInt8>(bitPattern: va)
}

func userWritableBuffer(_ va: UInt, _ count: UInt) -> UnsafeMutablePointer<UInt8>? {
    if count == 0 {
        return UnsafeMutablePointer<UInt8>(bitPattern: va == 0 ? userAccessMinVA : va)
    }
    guard userRangeWritable(va, count) else { return nil }
    return UnsafeMutablePointer<UInt8>(bitPattern: va)
}

func userCString(_ va: UInt, maxLen: Int = userAccessMaxCString) -> UnsafePointer<UInt8>? {
    if va == 0 || maxLen <= 0 { return nil }
    var off: UInt = 0
    while off < UInt(maxLen) {
        let cur = va + off
        if !userRangeMapped(cur, 1) { return nil }
        let p = UnsafePointer<UInt8>(bitPattern: cur)!
        if p.pointee == 0 {
            return UnsafePointer<UInt8>(bitPattern: va)
        }
        off += 1
    }
    return nil
}

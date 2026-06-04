// user_access.swift — checked EL0 memory access helpers.
//
// Syscalls must not dereference user pointers directly. These helpers first
// reject kernel/device addresses, integer-overflowed ranges, huge lengths, and
// unmapped user pages in the current process address space.

private let userAccessMinVA: UInt = 0x8000_0000
private let userAccessMaxVA: UInt = 0xB000_0000
private let userAccessPageMask: UInt = PageAllocator.pageSize - 1
let userAccessMaxCString = 4096

private func userRangeMapped(_ va: UInt, _ count: UInt) -> Bool {
    if count == 0 { return true }
    if count > UInt(Int.max) { return false }
    if va < userAccessMinVA { return false }
    let last = va + count - 1
    if last < va || last >= userAccessMaxVA { return false }

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
    guard userRangeMapped(va, count) else { return nil }
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

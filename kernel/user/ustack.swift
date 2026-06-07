// SPDX-License-Identifier: Apache-2.0
// ustack.swift — build the initial EL0 stack (argc/argv/envp/auxv).
//
// Lays out the SysV AArch64 process-entry stack at the top of a process's
// mapped user stack, in the process's own address space. Arguments arrive
// packed as NUL-separated strings ("a\0b\0c\0"); we copy them to the stack top,
// then build the pointer block the C runtime expects:
//
//   sp -> [ argc ][ argv[0..argc-1] ][ NULL ][ envp NULL ][ auxv AT_NULL x2 ]
//         [ ... strings ... ]
//
// crt0 reads argc from [sp] and argv from sp+8. Pointers stored are user VAs.
//
// Swift rewrite of the former ustack.c: pure stack-layout logic, no asm. Writes
// land in freshly mapped user pages, resolved to their identity-mapped physical
// frames through the address-space bridge in io.h.

private let USTACK_MAX_ARGS = 32

private func ustackWriteU64(_ ttbr0: UInt, _ va: UInt, _ value: UInt64) {
    let pa = address_space_translate(ttbr0, va)
    if pa != 0 {
        UnsafeMutableRawPointer(bitPattern: pa)!.storeBytes(of: value, toByteOffset: 0, as: UInt64.self)
    }
}

private func ustackCopyBytes(_ ttbr0: UInt, _ va: UInt, _ src: UnsafePointer<CChar>, _ len: UInt) {
    var i: UInt = 0
    while i < len {
        let pa = address_space_translate(ttbr0, va + i)
        if pa != 0 {
            let byte = UInt8(bitPattern: src[Int(i)])
            UnsafeMutableRawPointer(bitPattern: pa)!.storeBytes(of: byte, toByteOffset: 0, as: UInt8.self)
        }
        i += 1
    }
}

// Returns the user SP (VA), 16-byte aligned, or 0 on error.
func userStackBuild(_ ttbr0: UInt, _ stackTop: UInt,
                    _ packed: UnsafePointer<CChar>?, _ packedLen: UInt, _ argc: Int32) -> UInt {
    guard let packed = packed else { return 0 }
    if argc < 0 || argc > Int32(USTACK_MAX_ARGS) { return 0 }
    let argcInt = Int(argc)

    // Copy the packed strings to the top of the stack.
    let strBase = (stackTop - packedLen) & ~UInt(15)
    ustackCopyBytes(ttbr0, strBase, packed, packedLen)

    // Resolve each argument's user VA by scanning NUL boundaries.
    var argvVA = [UInt](repeating: 0, count: USTACK_MAX_ARGS)
    var off: UInt = 0
    for k in 0..<argcInt {
        argvVA[k] = strBase + off
        while off < packedLen && packed[Int(off)] != 0 { off += 1 }
        off += 1 // skip the NUL
    }

    // Pointer block: argc + argv[argc] + NULL + envp NULL + auxv(AT_NULL pair).
    let slots = UInt(1 + (argcInt + 1) + 1 + 2)
    let sp = (strBase - slots * 8) & ~UInt(15)

    var cur = sp
    ustackWriteU64(ttbr0, cur, UInt64(argc)); cur += 8
    for k in 0..<argcInt {
        ustackWriteU64(ttbr0, cur, UInt64(argvVA[k])); cur += 8
    }
    ustackWriteU64(ttbr0, cur, 0); cur += 8 // argv terminator
    ustackWriteU64(ttbr0, cur, 0); cur += 8 // envp terminator
    ustackWriteU64(ttbr0, cur, 0); cur += 8 // auxv type AT_NULL
    ustackWriteU64(ttbr0, cur, 0); cur += 8 // auxv value

    return sp
}

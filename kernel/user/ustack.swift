// SPDX-License-Identifier: Apache-2.0
// ustack.swift — build the initial EL0 stack (argc/argv/envp/auxv).
//
// Lays out the SysV AArch64 process-entry stack at the top of a process's
// mapped user stack, in the process's own address space. Arguments and
// environment strings arrive packed as NUL-separated strings ("a\0b\0c\0"); we
// copy them to the stack top, then build the pointer block the C runtime
// expects:
//
//   sp -> [ argc ][ argv[0..argc-1] ][ NULL ][ envp[0..envc-1] ][ NULL ]
//         [ auxv AT_NULL x2 ]
//         [ ... strings ... ]
//
// crt0 reads argc from [sp] and argv from sp+8. Pointers stored are user VAs.
//
// Swift rewrite of the former ustack.c: pure stack-layout logic, no asm. Writes
// land in freshly mapped user pages, resolved to their identity-mapped physical
// frames through the address-space bridge in io.h.

private let USTACK_MAX_STRINGS = 32

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
                    _ argvPacked: UnsafePointer<CChar>?, _ argvPackedLen: UInt, _ argc: Int32,
                    _ envPacked: UnsafePointer<CChar>?, _ envPackedLen: UInt, _ envc: Int32) -> UInt {
    if argc < 0 || argc > Int32(USTACK_MAX_STRINGS) { return 0 }
    if envc < 0 || envc > Int32(USTACK_MAX_STRINGS) { return 0 }
    let argcInt = Int(argc)
    let envcInt = Int(envc)
    if argcInt > 0 && (argvPacked == nil || argvPackedLen == 0) { return 0 }
    if envcInt > 0 && (envPacked == nil || envPackedLen == 0) { return 0 }

    // Copy envp nearest the stack top, then argv below it. The pointer block is
    // built below both copied string regions.
    var envBase = stackTop
    if envPackedLen > 0 {
        guard let envPacked = envPacked else { return 0 }
        envBase = (stackTop - envPackedLen) & ~UInt(15)
        ustackCopyBytes(ttbr0, envBase, envPacked, envPackedLen)
    }

    var argvBase = envBase
    if argvPackedLen > 0 {
        guard let argvPacked = argvPacked else { return 0 }
        argvBase = (envBase - argvPackedLen) & ~UInt(15)
        ustackCopyBytes(ttbr0, argvBase, argvPacked, argvPackedLen)
    }

    // Resolve each argument's user VA by scanning NUL boundaries.
    var argvVA = [UInt](repeating: 0, count: USTACK_MAX_STRINGS)
    var off: UInt = 0
    if argcInt > 0 {
        guard let argvPacked = argvPacked else { return 0 }
        for k in 0..<argcInt {
            if off >= argvPackedLen { return 0 }
            argvVA[k] = argvBase + off
            while off < argvPackedLen && argvPacked[Int(off)] != 0 { off += 1 }
            if off >= argvPackedLen { return 0 }
            off += 1 // skip the NUL
        }
    }

    var envVA = [UInt](repeating: 0, count: USTACK_MAX_STRINGS)
    off = 0
    if envcInt > 0 {
        guard let envPacked = envPacked else { return 0 }
        for k in 0..<envcInt {
            if off >= envPackedLen { return 0 }
            envVA[k] = envBase + off
            while off < envPackedLen && envPacked[Int(off)] != 0 { off += 1 }
            if off >= envPackedLen { return 0 }
            off += 1 // skip the NUL
        }
    }

    // Pointer block: argc + argv + NULL + envp + NULL + auxv(AT_NULL pair).
    let slots = UInt(1 + (argcInt + 1) + (envcInt + 1) + 2)
    let sp = (argvBase - slots * 8) & ~UInt(15)

    var cur = sp
    ustackWriteU64(ttbr0, cur, UInt64(argc)); cur += 8
    for k in 0..<argcInt {
        ustackWriteU64(ttbr0, cur, UInt64(argvVA[k])); cur += 8
    }
    ustackWriteU64(ttbr0, cur, 0); cur += 8 // argv terminator
    for k in 0..<envcInt {
        ustackWriteU64(ttbr0, cur, UInt64(envVA[k])); cur += 8
    }
    ustackWriteU64(ttbr0, cur, 0); cur += 8 // envp terminator
    ustackWriteU64(ttbr0, cur, 0); cur += 8 // auxv type AT_NULL
    ustackWriteU64(ttbr0, cur, 0); cur += 8 // auxv value

    return sp
}

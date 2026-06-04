// exec.swift — resolve a program path to an embedded ELF and marshal argv.
//
// Until the VFS can serve executables (M8b+), spawn() resolves a small built-in
// table of paths to the ELF blobs baked into the kernel image. argv is read
// from the caller's address space (active during the syscall) and packed into a
// kernel buffer, so it survives the switch into the child's address space.

/// Compare the NUL-terminated C string at user VA `va` to `expected`.
private func userPathEquals(_ va: UInt, _ expected: StaticString) -> Bool {
    guard let p = UnsafePointer<UInt8>(bitPattern: va) else { return false }
    var ok = true
    expected.withUTF8Buffer { e in
        var i = 0
        while i < e.count {
            if p[i] != e[i] { ok = false; return }
            i += 1
        }
        if p[e.count] != 0 { ok = false }
    }
    return ok
}

/// Resolve a program path to (ELF address, length), or (0, 0) if unknown.
func execResolve(_ pathVA: UInt) -> (UInt, UInt) {
    if userPathEquals(pathVA, "/bin/hello") {
        return (hello_elf_addr(), UInt(hello_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/argvdemo") {
        return (argvdemo_elf_addr(), UInt(argvdemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/ttydemo") {
        return (ttydemo_elf_addr(), UInt(ttydemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/spawndemo") {
        return (spawndemo_elf_addr(), UInt(spawndemo_elf_len()))
    }
    return (0, 0)
}

/// Read a NULL-terminated argv array (of user VAs) from the caller's address
/// space and pack the strings as NUL-separated bytes in a kernel buffer.
/// Returns (buffer address, total length, argc).
func packUserArgv(_ argvVA: UInt) -> (UInt, UInt, Int) {
    guard argvVA != 0, let arr = UnsafePointer<UInt>(bitPattern: argvVA) else {
        return (0, 0, 0)
    }

    // First pass: count args and total byte length.
    var argc = 0
    var total = 0
    while argc < 64, arr[argc] != 0 {
        guard let s = UnsafePointer<UInt8>(bitPattern: arr[argc]) else { break }
        var len = 0
        while s[len] != 0 { len += 1 }
        total += len + 1
        argc += 1
    }
    if argc == 0 { return (0, 0, 0) }

    guard let raw = swiftos_kernel_alloc(UInt(total), 16) else { return (0, 0, 0) }
    let buf = raw.bindMemory(to: UInt8.self, capacity: total)
    var off = 0
    for i in 0..<argc {
        guard let s = UnsafePointer<UInt8>(bitPattern: arr[i]) else { break }
        var j = 0
        while s[j] != 0 { buf[off] = s[j]; off += 1; j += 1 }
        buf[off] = 0
        off += 1
    }
    return (UInt(bitPattern: raw), UInt(total), argc)
}

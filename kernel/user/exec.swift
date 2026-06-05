// exec.swift — resolve a program path to an ELF image and marshal argv.
//
// spawn()/execve() resolve a small built-in table of program paths. M11d makes
// the loader prefer the packed base image on disk: a path that exists there as
// a disk-backed file is read into a reusable kernel buffer and run from disk;
// only when the disk has no such file (e.g. the -kernel test paths with no
// packed disk) do we fall back to the ELF blob baked into the kernel image.
// argv is read from the caller's address space (active during the syscall) and
// packed into a kernel buffer, so it survives the switch into the child's space.

// Reusable staging buffer for an ELF read off disk. Loads are sequential (one
// exec resolves, loads, and elf_load-copies into the new address space before
// the next), so a single buffer is safe; it is allocated lazily on first use.
// It comes from the PMM (physically contiguous, identity-mapped) rather than the
// tiny 256 KiB bump heap, since busybox is ~1.1 MiB.
private var elfBuf: UInt = 0
private let elfBufMax = 2 * 1024 * 1024 // 2 MiB comfortably covers busybox

/// Resolve an absolute kernel path on the packed disk and read its ELF into the
/// staging buffer. Returns (buffer, length) on success, or (0, 0) if the path
/// is not a disk-backed file or the read fails.
private func loadElfFromDisk(_ path: StaticString) -> (UInt, UInt) {
    var name = [UInt8](repeating: 0, count: path.utf8CodeUnitCount + 1)
    path.withUTF8Buffer { b in for i in 0..<b.count { name[i] = b[i] } }
    let (found, off, len) = name.withUnsafeBufferPointer { vfsDiskImageExtent($0.baseAddress!) }
    if !found || len <= 0 || len > elfBufMax { return (0, 0) }

    if elfBuf == 0 {
        let pa = pmmAllocPages(elfBufMax / 4096)
        if pa == 0 { return (0, 0) }
        elfBuf = pa
    }
    let rc = virtio_blk_read_range(UInt64(off), UnsafeMutableRawPointer(bitPattern: elfBuf), UInt32(len))
    if rc != 0 { return (0, 0) }
    return (elfBuf, UInt(len))
}

/// Disk-first resolution: try the packed image at `diskPath`, else the embedded
/// blob at (`embAddr`, `embLen`).
private func diskOrEmbedded(_ diskPath: StaticString, _ embAddr: UInt, _ embLen: UInt) -> (UInt, UInt) {
    let (a, l) = loadElfFromDisk(diskPath)
    if a != 0 {
        uartPuts("M11d: exec loaded from disk ")
        uartPuts(diskPath)
        uartPuts("\n")
        return (a, l)
    }
    return (embAddr, embLen)
}

/// Load the busybox image, preferring the packed disk copy. Used by the kernel's
/// own shell launcher (main.swift). Logs once which source served it.
func resolveBusyboxImage() -> (UInt, UInt) {
    let (a, l) = loadElfFromDisk("/bin/busybox")
    if a != 0 {
        uartPuts("M11d: busybox loaded from disk (/bin/busybox)\n")
        return (a, l)
    }
    return (busybox_elf_addr(), UInt(busybox_elf_len()))
}

/// Compare the NUL-terminated C string at user VA `va` to `expected`.
private func userPathEquals(_ va: UInt, _ expected: StaticString) -> Bool {
    guard let p = userCString(va) else { return false }
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
/// Each program prefers its packed disk copy and falls back to the embedded blob.
func execResolve(_ pathVA: UInt) -> (UInt, UInt) {
    if userPathEquals(pathVA, "/bin/hello") {
        return diskOrEmbedded("/bin/hello", hello_elf_addr(), UInt(hello_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/argvdemo") {
        return diskOrEmbedded("/bin/argvdemo", argvdemo_elf_addr(), UInt(argvdemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/ttydemo") {
        return diskOrEmbedded("/bin/ttydemo", ttydemo_elf_addr(), UInt(ttydemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/spawndemo") {
        return diskOrEmbedded("/bin/spawndemo", spawndemo_elf_addr(), UInt(spawndemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/fsdemo") {
        return diskOrEmbedded("/bin/fsdemo", fsdemo_elf_addr(), UInt(fsdemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/brkdemo") {
        return diskOrEmbedded("/bin/brkdemo", brkdemo_elf_addr(), UInt(brkdemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/newlibtest") {
        return diskOrEmbedded("/bin/newlibtest", newlibtest_elf_addr(), UInt(newlibtest_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/coproc") {
        return diskOrEmbedded("/bin/coproc", coproc_elf_addr(), UInt(coproc_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/forkdemo") {
        return diskOrEmbedded("/bin/forkdemo", forkdemo_elf_addr(), UInt(forkdemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/execdemo") {
        return diskOrEmbedded("/bin/execdemo", execdemo_elf_addr(), UInt(execdemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/fdopsdemo") {
        return diskOrEmbedded("/bin/fdopsdemo", fdopsdemo_elf_addr(), UInt(fdopsdemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/securitydemo") {
        return diskOrEmbedded("/bin/securitydemo", securitydemo_elf_addr(), UInt(securitydemo_elf_len()))
    }
    if userPathEquals(pathVA, "/bin/ps") {
        return diskOrEmbedded("/bin/ps", ps_elf_addr(), UInt(ps_elf_len()))
    }
    // busybox + its standalone re-exec path: re-exec'ing /proc/self/exe (or
    // /bin/busybox or /bin/sh) reloads busybox, which dispatches to the applet
    // named by argv[0]. This is how the standalone shell runs ls/cat/echo.
    if userPathEquals(pathVA, "/proc/self/exe")
        || userPathEquals(pathVA, "/bin/busybox")
        || userPathEquals(pathVA, "/bin/sh")
        || userPathEquals(pathVA, "/bin/ls")
        || userPathEquals(pathVA, "/bin/cat")
        || userPathEquals(pathVA, "/bin/echo")
        || userPathEquals(pathVA, "/bin/pwd") {
        return diskOrEmbedded("/bin/busybox", busybox_elf_addr(), UInt(busybox_elf_len()))
    }
    return (0, 0)
}

/// Read a NULL-terminated argv array (of user VAs) from the caller's address
/// space and pack the strings as NUL-separated bytes in a kernel buffer.
/// Returns (buffer address, total length, argc).
func packUserArgv(_ argvVA: UInt) -> (UInt, UInt, Int) {
    guard argvVA != 0, let arr8 = userReadableBuffer(argvVA, 8) else {
        return (0, 0, 0)
    }
    let arr = UnsafeRawPointer(arr8).assumingMemoryBound(to: UInt.self)

    // First pass: count args and total byte length.
    var argc = 0
    var total = 0
    while argc < 64, arr[argc] != 0 {
        guard userReadableBuffer(argvVA + UInt(argc * 8), 8) != nil,
              let s = userCString(arr[argc]) else { break }
        var len = 0
        while s[len] != 0 { len += 1 }
        total += len + 1
        if total > userAccessMaxCString { break }
        argc += 1
    }
    if argc == 0 { return (0, 0, 0) }

    guard let raw = swiftos_kernel_alloc(UInt(total), 16) else { return (0, 0, 0) }
    let buf = raw.bindMemory(to: UInt8.self, capacity: total)
    var off = 0
    for i in 0..<argc {
        guard let s = userCString(arr[i]) else { break }
        var j = 0
        while s[j] != 0 { buf[off] = s[j]; off += 1; j += 1 }
        buf[off] = 0
        off += 1
    }
    return (UInt(bitPattern: raw), UInt(total), argc)
}

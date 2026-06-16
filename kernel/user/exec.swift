// SPDX-License-Identifier: Apache-2.0
// exec.swift — resolve a program path to an ELF image and marshal argv.
//
// spawn()/execve() resolve executable paths through the packed base image and
// package overlays. A disk-backed executable is read into a reusable kernel
// buffer and run from disk. argv is read from the caller's address space (active
// during the syscall) and packed into a kernel buffer, so it survives the switch
// into the child's space.

// Reusable staging buffer for an ELF read off disk. Loads are sequential (one
// exec resolves, loads, and elfLoad-copies into the new address space before
// the next), so a single buffer is safe; it is allocated lazily on first use.
// It comes from the PMM (physically contiguous, identity-mapped) rather than the
// small bump heap. Server-package binaries are already larger than busybox:
// the first static nginx package is ~2.7 MiB.
private var elfBuf: UInt = 0
private let elfBufMax = 8 * 1024 * 1024

private func loadElfFromCString(_ path: UnsafePointer<UInt8>)
    -> (addr: UInt, len: UInt, setuid: Bool, owner: UInt32) {
    let ext = vfsDiskImageExtent(path)
    if !ext.found || ext.len <= 0 || ext.len > elfBufMax { return (0, 0, false, 0) }

    if elfBuf == 0 {
        let pa = pmmAllocPages(elfBufMax / 4096)
        if pa == 0 { return (0, 0, false, 0) }
        elfBuf = pa
    }
    let rc = vfsImageReadRange(ext.image, UInt64(ext.offset),
                               UnsafeMutableRawPointer(bitPattern: elfBuf), UInt32(ext.len))
    if rc != 0 { return (0, 0, false, 0) }
    return (elfBuf, UInt(ext.len), ext.setuid, ext.owner)
}

/// Resolve an absolute kernel path on a packed image and read its ELF into the
/// staging buffer. Returns (buffer, length) on success, or (0, 0) if the path
/// is not a disk-backed file or the read fails.
private func loadElfFromDisk(_ path: StaticString) -> (UInt, UInt) {
    var name = [UInt8](repeating: 0, count: path.utf8CodeUnitCount + 1)
    path.withUTF8Buffer { b in for i in 0..<b.count { name[i] = b[i] } }
    let r = name.withUnsafeBufferPointer { loadElfFromCString($0.baseAddress!) }
    return (r.addr, r.len) // kernel-shell / busybox launchers run as root; setuid is irrelevant here
}

/// Load a program ELF from the packed base image, logging the source. Returns
/// (0, 0) if the path is not present on disk. This is the only program source
/// now that the embedded blob is gone — every boot medium supplies a base image.
func loadProgramImage(_ path: StaticString) -> (UInt, UInt) {
    let (a, l) = loadElfFromDisk(path)
    if a != 0 {
        uartPuts("M11d: exec loaded from disk ")
        uartPuts(path)
        uartPuts("\n")
    }
    return (a, l)
}

/// Load the busybox image from the packed disk. Used by the kernel's own shell
/// launcher (main.swift).
func resolveBusyboxImage() -> (UInt, UInt) {
    let (a, l) = loadElfFromDisk("/bin/busybox")
    if a != 0 {
        uartPuts("M11d: busybox loaded from disk (/bin/busybox)\n")
    }
    return (a, l)
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

private func uartPutsCString(_ p: UnsafePointer<UInt8>) {
    var i = 0
    while p[i] != 0 {
        uartPutc(p[i])
        i += 1
    }
}

/// Resolve a program path to (ELF address, length, setuid, owner), or a zero
/// address if unknown. Normal executable paths are read from the VFS, so package
/// overlays can expose `/usr/bin/*`. Busybox's synthetic re-exec paths still map
/// to `/bin/busybox` (never setuid). `setuid`/`owner` carry the file's
/// setuid-on-exec elevation for processExec/spawn to apply.
func execResolve(_ pathVA: UInt) -> (addr: UInt, len: UInt, setuid: Bool, owner: UInt32) {
    // busybox + its standalone re-exec path: re-exec'ing /proc/self/exe (or
    // /bin/busybox or /bin/sh) reloads busybox, which dispatches to the applet
    // named by argv[0]. This is how the standalone shell runs ls/cat/echo.
    if userPathEquals(pathVA, "/proc/self/exe")
        || userPathEquals(pathVA, "/bin/busybox")
        || userPathEquals(pathVA, "/bin/sh")
        || userPathEquals(pathVA, "/bin/vi") {
        let (a, l) = loadProgramImage("/bin/busybox")
        return (a, l, false, 0)
    }
    guard let path = userCString(pathVA) else { return (0, 0, false, 0) }
    let loaded = loadElfFromCString(path)
    if loaded.addr != 0 {
        uartPuts("M11d: exec loaded from disk ")
        uartPutsCString(path)
        uartPuts("\n")
        return loaded
    }
    return (0, 0, false, 0)
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
    while argc < 64 {
        guard userReadableBuffer(argvVA + UInt(argc) * 8, 8) != nil else { break }
        let entry = arr[argc]
        if entry == 0 { break }
        guard let s = userCString(entry) else { break }
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

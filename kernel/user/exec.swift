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

/// Resolve a program path to (ELF address, length), or (0, 0) if unknown.
/// Every program is read from the packed base image on disk.
func execResolve(_ pathVA: UInt) -> (UInt, UInt) {
    if userPathEquals(pathVA, "/bin/hello") { return loadProgramImage("/bin/hello") }
    if userPathEquals(pathVA, "/bin/argvdemo") { return loadProgramImage("/bin/argvdemo") }
    if userPathEquals(pathVA, "/bin/ttydemo") { return loadProgramImage("/bin/ttydemo") }
    if userPathEquals(pathVA, "/bin/spawndemo") { return loadProgramImage("/bin/spawndemo") }
    if userPathEquals(pathVA, "/bin/fsdemo") { return loadProgramImage("/bin/fsdemo") }
    if userPathEquals(pathVA, "/bin/brkdemo") { return loadProgramImage("/bin/brkdemo") }
    if userPathEquals(pathVA, "/bin/newlibtest") { return loadProgramImage("/bin/newlibtest") }
    if userPathEquals(pathVA, "/bin/coproc") { return loadProgramImage("/bin/coproc") }
    if userPathEquals(pathVA, "/bin/forkdemo") { return loadProgramImage("/bin/forkdemo") }
    if userPathEquals(pathVA, "/bin/execdemo") { return loadProgramImage("/bin/execdemo") }
    if userPathEquals(pathVA, "/bin/fdopsdemo") { return loadProgramImage("/bin/fdopsdemo") }
    if userPathEquals(pathVA, "/bin/securitydemo") { return loadProgramImage("/bin/securitydemo") }
    if userPathEquals(pathVA, "/bin/identitydemo") { return loadProgramImage("/bin/identitydemo") }
    if userPathEquals(pathVA, "/bin/ps") { return loadProgramImage("/bin/ps") }
    if userPathEquals(pathVA, "/bin/id") { return loadProgramImage("/bin/id") }
    if userPathEquals(pathVA, "/bin/ls") { return loadProgramImage("/bin/ls") }
    if userPathEquals(pathVA, "/bin/cat") { return loadProgramImage("/bin/cat") }
    if userPathEquals(pathVA, "/bin/echo") { return loadProgramImage("/bin/echo") }
    if userPathEquals(pathVA, "/bin/pwd") { return loadProgramImage("/bin/pwd") }
    if userPathEquals(pathVA, "/bin/mkdir") { return loadProgramImage("/bin/mkdir") }
    if userPathEquals(pathVA, "/bin/rmdir") { return loadProgramImage("/bin/rmdir") }
    if userPathEquals(pathVA, "/bin/rm") { return loadProgramImage("/bin/rm") }
    if userPathEquals(pathVA, "/bin/mv") { return loadProgramImage("/bin/mv") }
    if userPathEquals(pathVA, "/bin/chmod") { return loadProgramImage("/bin/chmod") }
    if userPathEquals(pathVA, "/bin/chown") { return loadProgramImage("/bin/chown") }
    if userPathEquals(pathVA, "/bin/date") { return loadProgramImage("/bin/date") }
    if userPathEquals(pathVA, "/bin/calc") { return loadProgramImage("/bin/calc") }
    if userPathEquals(pathVA, "/bin/kv") { return loadProgramImage("/bin/kv") }
    if userPathEquals(pathVA, "/bin/head") { return loadProgramImage("/bin/head") }
    if userPathEquals(pathVA, "/bin/touch") { return loadProgramImage("/bin/touch") }
    if userPathEquals(pathVA, "/bin/wc") { return loadProgramImage("/bin/wc") }
    if userPathEquals(pathVA, "/bin/console-login") { return loadProgramImage("/bin/console-login") }
    // busybox + its standalone re-exec path: re-exec'ing /proc/self/exe (or
    // /bin/busybox or /bin/sh) reloads busybox, which dispatches to the applet
    // named by argv[0]. This is how the standalone shell runs ls/cat/echo.
    if userPathEquals(pathVA, "/proc/self/exe")
        || userPathEquals(pathVA, "/bin/busybox")
        || userPathEquals(pathVA, "/bin/sh")
        || userPathEquals(pathVA, "/bin/vi") {
        return loadProgramImage("/bin/busybox")
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

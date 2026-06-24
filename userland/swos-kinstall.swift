// SPDX-License-Identifier: Apache-2.0
// swos-kinstall.swift — install a NEW kernel into the inactive ESP slot (OS-1c-2b).
//
// Where /bin/swos-kstage only DUPLICATES the running kernel into the inactive
// slot, this installs a genuinely NEW, host-signed kernel: it streams a padded
// kernel image (KERNEL_SLOT_BYTES) into the INACTIVE ESP slot, then commits that
// slot's 104-byte host-signed manifest entry. The kernel verifies the entry —
// full slot written, size match, on-disk re-hash == entry.sha256, and the
// per-slot Ed25519 signature bound to this slot index — before writing it into
// the signed manifest, so a compromised userland cannot install a kernel the host
// did not sign for this slot. The active slot is never touched; the operator runs
// /bin/swos-kactivate + reboot to boot the new kernel on trial.
//
//   usage: swos-kinstall <kernel-image-file> <entry-file>
//
// Needs CAP_CONSOLE. This is the file-driven exerciser for the install syscalls;
// /bin/swupdate os (OS-1c-3) drives the same syscalls from a fetched SWSYS bundle
// that carries both the padded image and the per-slot entry.

private let oRdOnly: Int32 = 0
private let chunk = 64 * 1024
private let entryLen = 104

private func put(_ s: StaticString) {
    swiftos_puts(UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: CChar.self))
}

private func cpath(_ p: UnsafeMutablePointer<CChar>) -> [CChar] {
    var path: [CChar] = []
    var i = 0
    while p[i] != 0 { path.append(p[i]); i += 1 }
    path.append(0)
    return path
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc >= 3, let ip = argv[1], let ep = argv[2] else {
        put("usage: swos-kinstall <kernel-image-file> <entry-file>\n")
        return 2
    }
    let imgPath = cpath(ip)
    let entryPath = cpath(ep)

    // Read the 104-byte signed manifest entry up front.
    var entry = [UInt8](repeating: 0, count: entryLen)
    let efd = entryPath.withUnsafeBufferPointer { swiftos_open($0.baseAddress!, oRdOnly) }
    if efd < 0 { put("swos-kinstall: cannot open entry file\n"); return 1 }
    var got = 0
    while got < entryLen {
        let r = entry.withUnsafeMutableBytes { swiftos_read(efd, $0.baseAddress! + got, UInt(entryLen - got)) }
        if r <= 0 { break }
        got += Int(r)
    }
    _ = swiftos_close(efd)
    if got != entryLen { put("swos-kinstall: entry file must be 104 bytes\n"); return 1 }

    // Stream the kernel image into the inactive slot.
    let fd = imgPath.withUnsafeBufferPointer { swiftos_open($0.baseAddress!, oRdOnly) }
    if fd < 0 { put("swos-kinstall: cannot open kernel image file\n"); return 1 }
    defer { _ = swiftos_close(fd) }

    // begin returns the inactive slot index (0/1) on success, negative errno on error.
    let brc = swiftos_kernel_install_begin()
    if brc < 0 {
        if brc == -1 { put("swos-kinstall: rejected — need CAP_CONSOLE\n") }
        else if brc == -19 { put("swos-kinstall: no ESP/GPT boot disk\n") }
        else if brc == -22 { put("swos-kinstall: inactive slot is not the expected fixed size\n") }
        else { put("swos-kinstall: install begin failed\n") }
        return 1
    }

    var buf = [UInt8](repeating: 0, count: chunk)
    while true {
        // Fill the buffer before writing: the kernel requires 512-multiple writes,
        // and a padded slot image is a multiple of the chunk size, so every write
        // is a full chunk (except a final short read, which only a malformed image
        // would produce — the kernel then rejects it).
        var filled = 0
        while filled < chunk {
            let r = buf.withUnsafeMutableBytes { swiftos_read(fd, $0.baseAddress! + filled, UInt(chunk - filled)) }
            if r < 0 { put("swos-kinstall: read error\n"); _ = swiftos_kernel_install_abort(); return 1 }
            if r == 0 { break }
            filled += Int(r)
        }
        if filled == 0 { break }
        let wrc = buf.withUnsafeBytes { swiftos_kernel_install_write($0.baseAddress!, UInt(filled)) }
        if wrc != 0 { put("swos-kinstall: install write failed\n"); _ = swiftos_kernel_install_abort(); return 1 }
        if filled < chunk { break }
    }

    let crc = entry.withUnsafeBytes { swiftos_kernel_install_commit($0.baseAddress!) }
    if crc != 0 {
        if crc == -1 { put("swos-kinstall: commit rejected — entry signature invalid (or wrong slot index)\n") }
        else if crc == -22 { put("swos-kinstall: commit rejected — size/hash mismatch or short image\n") }
        else if crc == -11 { put("swos-kinstall: no active install (begin/write/commit out of order)\n") }
        else { put("swos-kinstall: install commit failed\n") }
        return 1
    }
    put("swos-kinstall: new kernel installed into the inactive ESP slot (verified); run swos-kactivate then reboot\n")
    return 0
}

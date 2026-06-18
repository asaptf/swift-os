// SPDX-License-Identifier: Apache-2.0
// swos-stagebase.swift — stream a base image from a file into the inactive A/B
// slot (swift-os, OS-3b).
//
// The kernel-mediated, capability-gated slot-write path: this opens a signed
// SWOSBASE image already on disk (e.g. extracted to /data by /bin/swupdate),
// declares its size + monotonic version to the kernel, streams the bytes into
// the INACTIVE slot, and commits. The active slot is never touched; the operator
// then runs /bin/swos-activate + reboot to boot the new image on trial.
//
//   usage: swos-stagebase <image-file> <version>
//
// Needs CAP_CONSOLE. This is the file-driven exerciser for the streaming syscalls
// (OS-3b); /bin/swupdate os (OS-4) drives the same syscalls from a fetched bundle.

private let oRdOnly: Int32 = 0
private let chunk = 64 * 1024

private func put(_ s: StaticString) {
    swiftos_puts(UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: CChar.self))
}

// Parse a non-negative decimal from a C string; returns nil on any non-digit.
private func parseU64(_ p: UnsafeMutablePointer<CChar>) -> UInt64? {
    var v: UInt64 = 0
    var i = 0
    if p[0] == 0 { return nil }
    while p[i] != 0 {
        let c = UInt8(bitPattern: p[i])
        if c < 0x30 || c > 0x39 { return nil }
        v = v &* 10 &+ UInt64(c - 0x30)
        i += 1
    }
    return v
}

// stat the file for its byte size, or nil if it does not exist.
private func fileSize(_ path: [CChar]) -> UInt64? {
    var mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0, nlink: UInt32 = 0
    var size: UInt = 0, mtime: UInt = 0
    let rc = path.withUnsafeBufferPointer {
        swiftos_stat($0.baseAddress!, &mode, &uid, &gid, &nlink, &size, &mtime)
    }
    return rc == 0 ? UInt64(size) : nil
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc >= 3, let fp = argv[1], let vp = argv[2] else {
        put("usage: swos-stagebase <image-file> <version>\n")
        return 2
    }
    guard let version = parseU64(vp), version > 0 else {
        put("swos-stagebase: version must be a positive integer\n")
        return 2
    }

    var path: [CChar] = []
    var i = 0
    while fp[i] != 0 { path.append(fp[i]); i += 1 }
    path.append(0)

    guard let total = fileSize(path), total > 0 else {
        put("swos-stagebase: cannot stat image file (or empty)\n")
        return 1
    }
    let fd = path.withUnsafeBufferPointer { swiftos_open($0.baseAddress!, oRdOnly) }
    if fd < 0 { put("swos-stagebase: cannot open image file\n"); return 1 }
    defer { _ = swiftos_close(fd) }

    let brc = swiftos_update_stage_begin(UInt(version), UInt(total))
    if brc != 0 {
        if brc == -1 { put("swos-stagebase: rejected — need CAP_CONSOLE or version not newer than the installed floor\n") }
        else if brc == -19 { put("swos-stagebase: not booted from an A/B update store\n") }
        else if brc == -27 { put("swos-stagebase: image too large for the inactive slot\n") }
        else { put("swos-stagebase: stage begin failed\n") }
        return 1
    }

    var buf = [UInt8](repeating: 0, count: chunk)
    var streamed: UInt64 = 0
    while streamed < total {
        let r = buf.withUnsafeMutableBytes { swiftos_read(fd, $0.baseAddress!, UInt(chunk)) }
        if r < 0 { put("swos-stagebase: read error\n"); _ = swiftos_update_stage_abort(); return 1 }
        if r == 0 { break }
        let wrc = buf.withUnsafeBytes { swiftos_update_stage_write($0.baseAddress!, UInt(r)) }
        if wrc != 0 { put("swos-stagebase: stage write failed\n"); _ = swiftos_update_stage_abort(); return 1 }
        streamed &+= UInt64(r)
    }
    if streamed != total {
        put("swos-stagebase: short read before EOF\n"); _ = swiftos_update_stage_abort(); return 1
    }

    let crc = swiftos_update_stage_commit()
    if crc != 0 {
        if crc == -22 { put("swos-stagebase: commit rejected — not a signed v3 SWOSBASE image (or size mismatch)\n") }
        else { put("swos-stagebase: stage commit failed\n") }
        return 1
    }
    put("swos-stagebase: staged image into the inactive slot; run swos-activate then reboot\n")
    return 0
}

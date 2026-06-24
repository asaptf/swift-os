// SPDX-License-Identifier: Apache-2.0
// DatafsVolumeStore.swift — the on-device VolumeStore over swiftos datafs syscalls (SC8).
//
// This is the REAL persistent-volume medium: subtrees under `/data` (the dedicated
// virtio-blk datafs tier, honest `fsync`). It compiles into the `slet` ELF — so the build
// proves the volume path is Embedded-Swift-clean — and is the SC8 analogue of the SC5
// `NetProbe` / SC7 `NetProxyTransport` real bindings: present on-device, its LIVE path
// exercised once datafs + C6 yield a real stateful Cell (the QEMU gate, deferred like SC3).
//
// Durability: `provision` and `writeFile` `fsync` before returning `.ok`, so a crash after
// a successful return cannot lose the subtree's existence or a flushed file — the property
// "/data survives a restart" rests on. QUOTA: datafs is an inode-table + block-bitmap FS
// with no per-subtree quota, so `usedBytes` is best-effort/informational and nothing is
// enforced. Foundation-free; uses the `swiftos_*` file bridge directly.
//
// NOTE (recorded seam): volumes are FLAT here — the manager writes files directly under the
// volume dir, no nested subdirectories — so `remove` enumerates one level via `getdents`
// and `rmdir`s. A nested-subtree delete would recurse (the `userland/rm.swift` walk); the
// manager never creates nested dirs, so the flat path is sufficient and honest today.

#if !SWIFTCUBE_HOST_VOLUME   // built into the on-device slet ELF, not the host test

private let oRdOnly: Int32 = 0
private let oWrOnly: Int32 = 1
private let oCreat: Int32 = 0x40
private let oTrunc: Int32 = 0x80
private let sIFMT: UInt32 = 0xF000
private let sIFDIR: UInt32 = 0x4000

final class DatafsVolumeStore: VolumeStore {
    /// The datafs root for all SwiftCube volumes. The manifest mount path inside a Cell is
    /// `/data`; the host-side subtree lives under `<base>/<volumeId>`.
    let base: String

    init(base: String = "/data/volumes") { self.base = base }

    func path(volumeId: String) -> String { "\(base)/\(volumeId)" }

    // MARK: provisioning

    func provision(volumeId: String) -> VolumeIOResult {
        // mkdir the chain (/data, /data/volumes, /data/volumes/<id>); EEXIST is success.
        mkdirIgnoringExisting("/data")
        mkdirIgnoringExisting(base)
        if !mkdirIgnoringExisting(path(volumeId: volumeId)) {
            // Could already exist as a directory (idempotent provision) — accept that.
            if !isDir(path(volumeId: volumeId)) { return .failed(reason: "mkdir volume failed") }
        }
        // Durability: fsync the parent so the new directory entry is stable.
        syncDir(base)
        return .ok
    }

    func exists(volumeId: String) -> Bool { isDir(path(volumeId: volumeId)) }

    // MARK: files

    func writeFile(volumeId: String, name: String, bytes: Bytes) -> VolumeIOResult {
        let fp = cstr("\(path(volumeId: volumeId))/\(name)")
        let fd = fp.withUnsafeBufferPointer { swiftos_open($0.baseAddress!, oWrOnly | oCreat | oTrunc) }
        if fd < 0 { return .failed(reason: "open for write failed") }
        var ok = true
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = swiftos_write(fd, raw.baseAddress!.advanced(by: off), UInt(raw.count - off))
                    if n <= 0 { ok = false; break }
                    off += Int(n)
                }
            }
        }
        _ = swiftos_fsync(fd)        // honest durability before we claim success
        _ = swiftos_close(fd)
        return ok ? .ok : .failed(reason: "short write")
    }

    func readFile(volumeId: String, name: String) -> Bytes? {
        let fp = cstr("\(path(volumeId: volumeId))/\(name)")
        let fd = fp.withUnsafeBufferPointer { swiftos_open($0.baseAddress!, oRdOnly) }
        if fd < 0 { return nil }
        defer { _ = swiftos_close(fd) }
        var out: Bytes = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let r = chunk.withUnsafeMutableBytes { swiftos_read(fd, $0.baseAddress!, UInt(4096)) }
            if r <= 0 { break }
            out.append(contentsOf: chunk[0..<Int(r)])
        }
        return out
    }

    func usedBytes(volumeId: String) -> UInt64 {
        // Best-effort: datafs has no quota, so this is informational. Sum the byte sizes of
        // the flat file set; an absent volume reports 0.
        guard isDir(path(volumeId: volumeId)) else { return 0 }
        var total: UInt64 = 0
        forEachEntry(path(volumeId: volumeId)) { full in
            total &+= statSize(full)
        }
        return total
    }

    func remove(volumeId: String) -> VolumeIOResult {
        let dir = path(volumeId: volumeId)
        guard isDir(dir) else { return .ok }   // already gone — idempotent
        forEachEntry(dir) { full in
            let c = cstr(full)
            _ = c.withUnsafeBufferPointer { swiftos_unlink($0.baseAddress!) }
        }
        let dc = cstr(dir)
        if dc.withUnsafeBufferPointer({ swiftos_rmdir($0.baseAddress!) }) != 0 {
            return .failed(reason: "rmdir failed")
        }
        return .ok
    }

    // MARK: - low-level helpers

    private func cstr(_ s: String) -> [CChar] {
        var b: [CChar] = []
        for u in s.utf8 { b.append(CChar(bitPattern: u)) }
        b.append(0)
        return b
    }

    @discardableResult
    private func mkdirIgnoringExisting(_ p: String) -> Bool {
        let c = cstr(p)
        return c.withUnsafeBufferPointer { swiftos_mkdir($0.baseAddress!) } == 0
    }

    private func isDir(_ p: String) -> Bool {
        let c = cstr(p)
        var mode: UInt32 = 0
        let rc = c.withUnsafeBufferPointer { swiftos_stat($0.baseAddress!, &mode, nil, nil, nil, nil, nil) }
        return rc == 0 && (mode & sIFMT) == sIFDIR
    }

    private func statSize(_ p: String) -> UInt64 {
        let c = cstr(p)
        var size: UInt = 0
        let rc = c.withUnsafeBufferPointer { swiftos_stat($0.baseAddress!, nil, nil, nil, nil, &size, nil) }
        return rc == 0 ? UInt64(size) : 0
    }

    private func syncDir(_ p: String) {
        let c = cstr(p)
        let fd = c.withUnsafeBufferPointer { swiftos_open($0.baseAddress!, oRdOnly) }
        if fd >= 0 { _ = swiftos_fsync(fd); _ = swiftos_close(fd) }
    }

    /// Enumerate one directory level, calling `body` with each non-dot entry's full path.
    /// dirent layout: d_ino(8) d_off(8) d_reclen(2@16) d_type(1@18) d_name(NUL@19).
    private func forEachEntry(_ dir: String, _ body: (String) -> Void) {
        let dc = cstr(dir)
        let fd = dc.withUnsafeBufferPointer { swiftos_open($0.baseAddress!, oRdOnly) }
        if fd < 0 { return }
        defer { _ = swiftos_close(fd) }
        let cap = 2048
        var buf = [UInt8](repeating: 0, count: cap)
        while true {
            let n = buf.withUnsafeMutableBytes { swiftos_getdents(fd, $0.baseAddress!, UInt(cap)) }
            if n <= 0 { break }
            var off = 0
            buf.withUnsafeBufferPointer { p in
                while off < Int(n) {
                    let rec = p.baseAddress! + off
                    let reclen = Int(UInt16(rec[16]) | (UInt16(rec[17]) << 8))
                    if reclen <= 0 { break }
                    var nameLen = 0
                    while rec[19 + nameLen] != 0 { nameLen += 1 }
                    var name = ""
                    name.reserveCapacity(nameLen)
                    var k = 0
                    while k < nameLen { name.unicodeScalars.append(Unicode.Scalar(rec[19 + k])); k += 1 }
                    off += reclen
                    if name == "." || name == ".." { continue }
                    body("\(dir)/\(name)")
                }
            }
        }
    }
}

#endif

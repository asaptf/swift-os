// SPDX-License-Identifier: Apache-2.0
// HostDirVolumeStore.swift — a host directory standing in for datafs (NOT core, test-only).
//
// The SC8 acceptance tests need a real, durable persistent-volume medium without a kernel
// or a virtio-blk disk. This binds the `VolumeStore` seam to a host directory with honest
// POSIX `fsync` — the same "honest fsync" durability the on-device datafs assumes — so a
// test can write to a PV, drop and rebuild the manager (modelling a Cell/slet restart), and
// see the data survive (case 2). It lives outside the Foundation-free core deliberately
// (like cubestore's host `PosixFileSink`); only the host `volume-test` links it.
//
// "Restart" in the host tests is modelled by constructing a NEW VolumeManager over the SAME
// HostDirVolumeStore root: the in-memory mount table resets (as a real slet's would), but
// the on-disk subtree persists — exactly the node-local-sticky property.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation

final class HostDirVolumeStore: VolumeStore {
    let root: String

    init(root: String) {
        self.root = root
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func path(volumeId: String) -> String { "\(root)/\(volumeId)" }

    func provision(volumeId: String) -> VolumeIOResult {
        let dir = path(volumeId: volumeId)
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .failed(reason: "createDirectory failed")
        }
        syncDir(root)   // make the new directory entry durable
        return .ok
    }

    func exists(volumeId: String) -> Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: path(volumeId: volumeId), isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    func writeFile(volumeId: String, name: String, bytes: Bytes) -> VolumeIOResult {
        let fp = "\(path(volumeId: volumeId))/\(name)"
        let fd = open(fp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd < 0 { return .failed(reason: "open failed") }
        var ok = true
        bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { ok = false; break }
                off += n
            }
        }
        _ = fsync(fd)        // honest durability before claiming success
        close(fd)
        return ok ? .ok : .failed(reason: "short write")
    }

    func readFile(volumeId: String, name: String) -> Bytes? {
        let fp = "\(path(volumeId: volumeId))/\(name)"
        guard let data = FileManager.default.contents(atPath: fp) else { return nil }
        return Bytes(data)
    }

    func usedBytes(volumeId: String) -> UInt64 {
        let dir = path(volumeId: volumeId)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return 0 }
        var total: UInt64 = 0
        for n in names {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(n)"),
               let sz = attrs[.size] as? UInt64 { total &+= sz }
        }
        return total
    }

    func remove(volumeId: String) -> VolumeIOResult {
        let dir = path(volumeId: volumeId)
        if !FileManager.default.fileExists(atPath: dir) { return .ok }
        do { try FileManager.default.removeItem(atPath: dir) } catch { return .failed(reason: "removeItem failed") }
        return .ok
    }

    private func syncDir(_ p: String) {
        let fd = open(p, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
}

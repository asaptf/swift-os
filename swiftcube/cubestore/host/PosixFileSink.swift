// SPDX-License-Identifier: Apache-2.0
// PosixFileSink.swift — host POSIX-file StorageSink for cubestore (NOT core).
//
// This is the SC0 durability backend for host testing/benchmarking. It lives
// outside the Foundation-free core deliberately: it uses POSIX file I/O with a
// real fsync, which is the "honest fsync" the recovery model assumes. The
// swift-os datafs implementation is a later milestone and satisfies the same
// AppendLog / SnapshotStore seams without touching the core.
//
// On-disk layout under <dir>:
//   wal.log         the append-only write-ahead log (cubestore WAL framing)
//   snap-<rev>.bin  snapshots, one per checkpoint; latest() picks the highest.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation

/// Append-only WAL backed by a single file with an honest fsync.
final class PosixAppendLog: AppendLog {
    private let path: String
    private let fd: Int32

    init(path: String) {
        self.path = path
        // O_APPEND keeps every write at end-of-file regardless of the read
        // cursor, so readAll() can lseek to 0 freely.
        fd = open(path, O_RDWR | O_CREAT | O_APPEND, 0o644)
        precondition(fd >= 0, "cubestore: cannot open WAL at \(path)")
    }

    deinit { close(fd) }

    func append(_ bytes: Bytes) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                precondition(n > 0, "cubestore: WAL write failed")
                off += n
            }
        }
    }

    func sync() { _ = fsync(fd) }

    func readAll() -> Bytes {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return [] }
        let size = Int(st.st_size)
        var buf = Bytes(repeating: 0, count: size)
        lseek(fd, 0, SEEK_SET)
        var got = 0
        buf.withUnsafeMutableBytes { raw in
            while got < size {
                let n = read(fd, raw.baseAddress!.advanced(by: got), size - got)
                if n <= 0 { break }
                got += n
            }
        }
        if got < size { buf.removeLast(size - got) }
        return buf
    }

    func reset() {
        _ = ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        _ = fsync(fd)
    }
}

/// Snapshot store backed by per-revision files in a directory. Writes go to a
/// temp file then atomically rename into place, with an fsync before rename.
final class PosixSnapshotStore: SnapshotStore {
    private let dir: String

    init(dir: String) {
        self.dir = dir
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
    }

    func put(_ bytes: Bytes, atRevision revision: Revision) {
        let final = "\(dir)/snap-\(String(format: "%020llu", revision)).bin"
        let tmp = final + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        precondition(fd >= 0, "cubestore: cannot open snapshot temp \(tmp)")
        bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                precondition(n > 0, "cubestore: snapshot write failed")
                off += n
            }
        }
        _ = fsync(fd)
        close(fd)
        rename(tmp, final)
    }

    func latest() -> (revision: Revision, bytes: Bytes)? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var best: Revision? = nil
        for name in names where name.hasPrefix("snap-") && name.hasSuffix(".bin") {
            let mid = name.dropFirst("snap-".count).dropLast(".bin".count)
            if let rev = Revision(mid), best == nil || rev > best! { best = rev }
        }
        guard let rev = best else { return nil }
        let path = "\(dir)/snap-\(String(format: "%020llu", rev)).bin"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (rev, Bytes(data))
    }
}

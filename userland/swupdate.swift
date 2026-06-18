// SPDX-License-Identifier: Apache-2.0
// swupdate.swift — native Swift `/bin/swupdate` for swift-os.
//
// Reflash-free static-site updates: the nginx production docroot lives on the
// persistent /data tier at /data/www/current, swapped atomically between
// generations rather than rebuilt into the read-only base image.
//
// This milestone (M-A) implements the `seed` subcommand only — run at every boot
// by swos-init (before any service starts). It:
//   1. seeds /data/www/current from the baked default site on a fresh / empty
//      /data, so a freshly-flashed box still serves a site, and
//   2. recovers a crash-interrupted atomic swap (see the layout note below),
//      leaving a *fully* current generation, never a half-applied docroot.
//
// Layout under /data/www/ (no symlinks in datafs — `current` is a real dir,
// swapped by rename, never renamed *onto* a populated dir which datafs rejects
// with ENOTEMPTY; renames always target a fresh, non-existent name and are O(1)):
//   current/  — the live docroot (nginx `root`)
//   next/     — staging for an in-progress update (M-B/M-C)
//   prev/     — the previous generation, retained for rollback
//
// The signed-bundle apply path (`apply-local` / `site`) lands in later milestones.
//
// Implementation note: this is freestanding Embedded Swift with no full stdlib,
// so we deliberately avoid Swift `String` (its `==`/interpolation pull in Unicode
// normalization tables that aren't linked) and work with NUL-terminated [CChar]
// paths and raw [UInt8] name bytes, like /bin/ls and /bin/cat.

// open(2) flag bits matching the kernel ABI (kernel/vfs/vfs.swift).
private let oRdOnly: Int32 = 0
private let oWrOnly: Int32 = 1
private let oCreat:  Int32 = 0x40
private let oTrunc:  Int32 = 0x80

// stat st_mode type bits.
private let sIFMT:  UInt32 = 0xF000
private let sIFDIR: UInt32 = 0x4000

// dirent d_type for a directory (kernel/vfs/vfs.swift).
private let dtDir: UInt8 = 4

// Persistent docroot paths.
private let pWww:   StaticString = "/data/www"
private let pData:  StaticString = "/data"
private let pCur:   StaticString = "/data/www/current"
private let pNext:  StaticString = "/data/www/next"
private let pPrev:  StaticString = "/data/www/prev"
private let pBaked: StaticString = "/usr/share/nginx/html"

// Baked site-signing public key — the trust anchor for SWSITE bundles (SU-B).
private let pSiteRootPub: StaticString = "/etc/swupdate/site-root.pub"

// SWSITE signed-bundle layout (must match tools/sitepack.swift).
private let sigSize = 64           // leading Ed25519 detached signature
private let hdrSize = 64           // body header
private let entrySize = 24         // per-entry record
// Inode budget: datafs holds 256 inodes total across current+next+prev (~3x the
// site) plus /data overhead, so cap a single site's entry count well under 256/3.
private let maxSiteEntries = 64
private let maxBundleBytes = 8 * 1024 * 1024
private let siteMagic: StaticString = "SWSITE01"

// ---- small helpers ---------------------------------------------------------

private func put(_ s: StaticString) {
    swiftos_puts(UnsafeRawPointer(s.utf8Start).assumingMemoryBound(to: CChar.self))
}

// A NUL-terminated C string (as [CChar]) from a StaticString literal.
private func cz(_ s: StaticString) -> [CChar] {
    var a: [CChar] = []
    let n = s.utf8CodeUnitCount
    var i = 0
    while i < n { a.append(CChar(bitPattern: s.utf8Start[i])); i += 1 }
    a.append(0)
    return a
}

// Compare a C string (from argv) to a literal, byte for byte.
private func cstrEq(_ p: UnsafeMutablePointer<CChar>, _ lit: StaticString) -> Bool {
    let n = lit.utf8CodeUnitCount
    var i = 0
    while i < n {
        if p[i] == 0 || UInt8(bitPattern: p[i]) != lit.utf8Start[i] { return false }
        i += 1
    }
    return p[i] == 0
}

// Join "dir/name" into a fresh NUL-terminated [CChar]. `dir` is NUL-terminated;
// `name` is raw bytes (no terminator).
private func joinPath(_ dir: [CChar], _ name: [UInt8]) -> [CChar] {
    var out: [CChar] = []
    var i = 0
    while i < dir.count && dir[i] != 0 { out.append(dir[i]); i += 1 }
    out.append(CChar(bitPattern: 0x2F))     // '/'
    for b in name { out.append(CChar(bitPattern: b)) }
    out.append(0)
    return out
}

// ---- syscall wrappers over the C bridge (C-string paths) -------------------

private func sOpen(_ path: [CChar], _ flags: Int32) -> Int32 {
    path.withUnsafeBufferPointer { swiftos_open($0.baseAddress!, flags) }
}
private func sMkdir(_ path: [CChar]) -> Int32 {
    path.withUnsafeBufferPointer { swiftos_mkdir($0.baseAddress!) }
}
private func sRmdir(_ path: [CChar]) -> Int32 {
    path.withUnsafeBufferPointer { swiftos_rmdir($0.baseAddress!) }
}
private func sUnlink(_ path: [CChar]) -> Int32 {
    path.withUnsafeBufferPointer { swiftos_unlink($0.baseAddress!) }
}
private func sRename(_ from: [CChar], _ to: [CChar]) -> Int32 {
    from.withUnsafeBufferPointer { f in
        to.withUnsafeBufferPointer { t in
            swiftos_rename(f.baseAddress!, t.baseAddress!)
        }
    }
}

// Stat `path`; returns its st_mode, or nil if it does not exist.
private func statMode(_ path: [CChar]) -> UInt32? {
    var mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0, nlink: UInt32 = 0
    var size: UInt = 0, mtime: UInt = 0
    let rc = path.withUnsafeBufferPointer {
        swiftos_stat($0.baseAddress!, &mode, &uid, &gid, &nlink, &size, &mtime)
    }
    return rc == 0 ? mode : nil
}

private func isDirMode(_ mode: UInt32) -> Bool { (mode & sIFMT) == sIFDIR }

// Flush /data to stable media. datafs fsync flushes the whole device write
// cache (kernel/fs/datafs.swift datafsFlush), so syncing any /data fd is enough.
private func syncData() {
    let fd = sOpen(cz(pWww), oRdOnly)
    if fd >= 0 { _ = swiftos_fsync(fd); _ = swiftos_close(fd) }
}

// ---- directory traversal ---------------------------------------------------

// Read every entry of directory `path` into a list of (name bytes, isDir). The
// directory is *not* mutated during the drain, so the getdents cursor stays
// valid across batches. Returns nil if `path` cannot be opened as a directory.
private func listDir(_ path: [CChar]) -> [(name: [UInt8], isDir: Bool)]? {
    let fd = sOpen(path, oRdOnly)
    if fd < 0 { return nil }
    defer { _ = swiftos_close(fd) }

    var out: [(name: [UInt8], isDir: Bool)] = []
    let cap = 2048
    var buf = [UInt8](repeating: 0, count: cap)
    while true {
        let n = buf.withUnsafeMutableBytes {
            swiftos_getdents(fd, $0.baseAddress!, UInt(cap))
        }
        if n <= 0 { break }
        var off = 0
        while off + 19 < Int(n) {
            // dirent: d_ino(8) d_off(8) d_reclen(2) d_type(1) d_name[](NUL).
            let reclen = Int(UInt16(buf[off + 16]) | (UInt16(buf[off + 17]) << 8))
            if reclen <= 0 { break }
            let dtype = buf[off + 18]
            var name: [UInt8] = []
            var k = off + 19
            while buf[k] != 0 { name.append(buf[k]); k += 1 }
            out.append((name, dtype == dtDir))
            off += reclen
        }
    }
    return out
}

private func isNonEmptyDir(_ path: [CChar]) -> Bool {
    guard let m = statMode(path), isDirMode(m) else { return false }
    guard let entries = listDir(path) else { return false }
    return !entries.isEmpty
}

// Recursively delete a directory tree (files first, then the dir). Best-effort:
// keeps going on per-entry errors so a partial tree is still cleared.
private func deleteTree(_ path: [CChar]) {
    if let entries = listDir(path) {
        for e in entries {
            let child = joinPath(path, e.name)
            if e.isDir { deleteTree(child) } else { _ = sUnlink(child) }
        }
    }
    _ = sRmdir(path)
}

private let copyChunk = 4096

// Copy a single file src -> dst (dst created/truncated) and fsync it.
private func copyFile(_ src: [CChar], _ dst: [CChar]) -> Bool {
    let inFd = sOpen(src, oRdOnly)
    if inFd < 0 { return false }
    defer { _ = swiftos_close(inFd) }
    let outFd = sOpen(dst, oWrOnly | oCreat | oTrunc)
    if outFd < 0 { return false }
    defer { _ = swiftos_close(outFd) }

    var buf = [UInt8](repeating: 0, count: copyChunk)
    while true {
        let r = buf.withUnsafeMutableBytes {
            swiftos_read(inFd, $0.baseAddress!, UInt(copyChunk))
        }
        if r < 0 { return false }
        if r == 0 { break }
        var off = 0
        let total = Int(r)
        while off < total {
            let w = buf.withUnsafeBytes {
                swiftos_write(outFd, $0.baseAddress!.advanced(by: off), UInt(total - off))
            }
            if w <= 0 { return false }
            off += Int(w)
        }
    }
    _ = swiftos_fsync(outFd)
    return true
}

// Recursively copy the contents of src into dst. dst must already exist.
private func copyTree(_ src: [CChar], _ dst: [CChar]) -> Bool {
    guard let entries = listDir(src) else { return false }
    var ok = true
    for e in entries {
        let s = joinPath(src, e.name)
        let d = joinPath(dst, e.name)
        if e.isDir {
            if sMkdir(d) < 0 && statMode(d) == nil { ok = false; continue }
            if !copyTree(s, d) { ok = false }
        } else {
            if !copyFile(s, d) { ok = false }
        }
    }
    return ok
}

// ---- seed + recovery -------------------------------------------------------

// Promote a staged generation `from` (next or prev) to be the live `current`.
// `current` must be absent or empty for the rename to succeed (datafs rejects a
// rename onto a populated directory). Returns true on success.
private func promote(_ from: [CChar]) -> Bool {
    if statMode(cz(pCur)) != nil { deleteTree(cz(pCur)) }   // clear empty/partial current
    if sRename(from, cz(pCur)) != 0 { return false }
    syncData()
    return true
}

private func seed() -> Int32 {
    // /data must be mounted (datafs present), or there is nowhere durable to seed.
    guard let dm = statMode(cz(pData)), isDirMode(dm) else {
        put("swupdate: seed: /data not mounted; skipping\n")
        return 0
    }
    _ = sMkdir(cz(pWww))   // idempotent; ignore EEXIST

    // A live docroot already exists — normal reboot. Clear any stray staging dir
    // left by a crash *before* the swap began, then we are done.
    if isNonEmptyDir(cz(pCur)) {
        if statMode(cz(pNext)) != nil { deleteTree(cz(pNext)) }
        put("swupdate: seed: /data/www/current present\n")
        return 0
    }

    // current is missing or empty. Finish a swap that was interrupted between its
    // two renames (current already moved to prev, next ready to become current).
    if isNonEmptyDir(cz(pNext)) {
        if promote(cz(pNext)) {
            put("swupdate: seed: completed interrupted update (next -> current)\n")
            return 0
        }
        put("swupdate: seed: failed to promote next\n")
    }

    // Otherwise fall back to the retained previous generation (rollback).
    if isNonEmptyDir(cz(pPrev)) {
        if promote(cz(pPrev)) {
            put("swupdate: seed: rolled back to previous generation (prev -> current)\n")
            return 0
        }
        put("swupdate: seed: failed to promote prev\n")
    }

    // Fresh box / empty /data: seed current from the baked default site.
    guard let bm = statMode(cz(pBaked)), isDirMode(bm) else {
        put("swupdate: seed: no baked default site to seed from\n")
        return 1
    }
    if statMode(cz(pCur)) != nil { deleteTree(cz(pCur)) }
    if sMkdir(cz(pCur)) < 0 && statMode(cz(pCur)) == nil {
        put("swupdate: seed: mkdir current failed\n")
        return 1
    }
    if !copyTree(cz(pBaked), cz(pCur)) {
        put("swupdate: seed: copy from baked default failed\n")
        return 1
    }
    syncData()
    put("swupdate: seed: seeded /data/www/current from baked default\n")
    return 0
}

// ---- signed bundle apply (SU-B) --------------------------------------------

private func le32(_ b: [UInt8], _ off: Int) -> Int {
    Int(UInt32(b[off]) | (UInt32(b[off + 1]) << 8)
        | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24))
}

// Read an entire file into memory, refusing anything larger than `maxBytes`.
private func readFileFully(_ path: [CChar], _ maxBytes: Int) -> [UInt8]? {
    let fd = sOpen(path, oRdOnly)
    if fd < 0 { return nil }
    defer { _ = swiftos_close(fd) }
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let r = chunk.withUnsafeMutableBytes {
            swiftos_read(fd, $0.baseAddress!, UInt($0.count))
        }
        if r < 0 { return nil }
        if r == 0 { break }
        var i = 0
        while i < Int(r) { out.append(chunk[i]); i += 1 }
        if out.count > maxBytes { return nil }
    }
    return out
}

// Load the baked 32-byte site-signing public key.
private func loadPubkey() -> [UInt8]? {
    guard let raw = readFileFully(cz(pSiteRootPub), 64), raw.count == 32 else { return nil }
    return raw
}

private func magicMatches(_ b: [UInt8], _ at: Int) -> Bool {
    let n = siteMagic.utf8CodeUnitCount
    var i = 0
    while i < n { if b[at + i] != siteMagic.utf8Start[i] { return false }; i += 1 }
    return true
}

// A relative entry name must stay within the docroot: no absolute paths and no
// ".." traversal. Defense-in-depth; sitepack only emits clean relative names.
private func safeName(_ name: [UInt8]) -> Bool {
    if name.isEmpty { return false }
    if name[0] == 0x2F { return false }                 // leading '/'
    var i = 0
    while i + 1 < name.count {
        // reject "/.." and a leading ".." (the only ways to escape upward)
        if name[i] == 0x2E && name[i + 1] == 0x2E {
            let prevSlash = (i == 0) || name[i - 1] == 0x2F
            let nextEndOrSlash = (i + 2 == name.count) || name[i + 2] == 0x2F
            if prevSlash && nextEndOrSlash { return false }
        }
        i += 1
    }
    return true
}

// Write `len` bytes of `bundle` starting at `off` to fd, fully.
private func writeBlob(_ fd: Int32, _ bundle: [UInt8], _ off: Int, _ len: Int) -> Bool {
    if len == 0 { return true }
    return bundle.withUnsafeBytes { raw -> Bool in
        var done = 0
        while done < len {
            let w = swiftos_write(fd, raw.baseAddress!.advanced(by: off + done), UInt(len - done))
            if w <= 0 { return false }
            done += Int(w)
        }
        return true
    }
}

// Verify a SWSITE bundle's Ed25519 signature (against the baked pubkey) and its
// payload SHA-256, validate the layout, and unpack it into /data/www/next, then
// atomically swap it in (current->prev, next->current). A bad bundle is rejected
// before `next` is touched, so `current` is never left half-updated. Returns 0
// on success, nonzero (with a message) on rejection.
private func applyBundleBytes(_ bundle: [UInt8]) -> Int32 {
    if bundle.count < sigSize + hdrSize { put("swupdate: bundle too small\n"); return 1 }
    guard let pub = loadPubkey() else {
        put("swupdate: missing/invalid site-signing key\n"); return 1
    }
    let bodyOff = sigSize
    let bodyLen = bundle.count - sigSize

    // 1. Ed25519 signature over the body — the trust anchor.
    let sigOK = bundle.withUnsafeBytes { bb in
        pub.withUnsafeBytes { pb in
            ed25519Verify(message: bb.baseAddress!.advanced(by: bodyOff), bodyLen,
                          signature: bb.baseAddress!, publicKey: pb.baseAddress!)
        }
    }
    if !sigOK { put("swupdate: bundle signature INVALID — rejected\n"); return 1 }

    // 2. Header magic + version.
    if !magicMatches(bundle, bodyOff) { put("swupdate: bad bundle magic\n"); return 1 }
    if le32(bundle, bodyOff + 8) != 1 { put("swupdate: unsupported bundle version\n"); return 1 }

    // 3. Payload SHA-256 cross-check (covers body[hdr..]).
    let payloadOff = bodyOff + hdrSize
    let payloadLen = bundle.count - payloadOff
    var sha = [UInt8](repeating: 0, count: 32)
    bundle.withUnsafeBytes { bb in
        sha.withUnsafeMutableBytes { ob in
            sha256(bb.baseAddress!.advanced(by: payloadOff), payloadLen, ob.baseAddress!)
        }
    }
    var k = 0
    while k < 32 { if sha[k] != bundle[bodyOff + 32 + k] { put("swupdate: payload sha256 mismatch\n"); return 1 }; k += 1 }

    // 4. Layout bounds (body-relative offsets).
    let entryCount = le32(bundle, bodyOff + 12)
    let stringsOff = le32(bundle, bodyOff + 16)
    let stringsLen = le32(bundle, bodyOff + 20)
    let blobsOff = le32(bundle, bodyOff + 24)
    let blobsLen = le32(bundle, bodyOff + 28)
    if entryCount < 1 || entryCount > maxSiteEntries {
        put("swupdate: bundle entry count out of range (inode budget)\n"); return 1
    }
    let entriesEnd = hdrSize + entryCount * entrySize
    if entriesEnd > stringsOff || stringsOff + stringsLen > blobsOff
        || blobsOff + blobsLen > bodyLen {
        put("swupdate: bundle layout out of bounds\n"); return 1
    }

    // 5. Stage into a fresh /data/www/next.
    _ = sMkdir(cz(pWww))
    deleteTree(cz(pNext))
    if sMkdir(cz(pNext)) < 0 && statMode(cz(pNext)) == nil {
        put("swupdate: cannot create staging dir\n"); return 1
    }
    var i = 0
    while i < entryCount {
        let e = bodyOff + hdrSize + i * entrySize
        let nameOff = le32(bundle, e + 0)
        let nameLen = le32(bundle, e + 4)
        let blobOff = le32(bundle, e + 8)
        let blobLen = le32(bundle, e + 12)
        let type = le32(bundle, e + 16)
        if nameLen < 1 || nameOff + nameLen > stringsLen { put("swupdate: bad entry name\n"); return 1 }
        if type == 0 && blobOff + blobLen > blobsLen { put("swupdate: bad entry blob\n"); return 1 }
        var name: [UInt8] = []
        var j = 0
        let nameBase = bodyOff + stringsOff + nameOff
        while j < nameLen { name.append(bundle[nameBase + j]); j += 1 }
        if !safeName(name) { put("swupdate: unsafe entry name — rejected\n"); return 1 }
        let dst = joinPath(cz(pNext), name)
        if type == 1 {
            if sMkdir(dst) < 0 && statMode(dst) == nil { put("swupdate: mkdir failed in staging\n"); return 1 }
        } else {
            let fd = sOpen(dst, oWrOnly | oCreat | oTrunc)
            if fd < 0 { put("swupdate: cannot create file in staging\n"); return 1 }
            let ok = writeBlob(fd, bundle, bodyOff + blobsOff + blobOff, blobLen)
            _ = swiftos_fsync(fd)
            _ = swiftos_close(fd)
            if !ok { put("swupdate: write failed in staging\n"); return 1 }
        }
        i += 1
    }
    syncData()

    // 6. Atomic swap: retire current to prev, promote next to current. Both
    //    renames target a fresh (non-existent) name, so each is O(1) and the
    //    only gap is between them — recovered on the next boot by `seed`.
    deleteTree(cz(pPrev))
    if statMode(cz(pCur)) != nil {
        if sRename(cz(pCur), cz(pPrev)) != 0 { put("swupdate: could not retire current\n"); return 1 }
    }
    if sRename(cz(pNext), cz(pCur)) != 0 { put("swupdate: could not promote next\n"); return 1 }
    syncData()
    put("swupdate: applied site bundle; /data/www/current updated\n")
    return 0
}

private func applyLocal(_ path: [CChar]) -> Int32 {
    guard let bundle = readFileFully(path, maxBundleBytes) else {
        put("swupdate: cannot read bundle file\n"); return 1
    }
    return applyBundleBytes(bundle)
}

// ---- entry point -----------------------------------------------------------

private func usage() {
    put("usage: swupdate seed | swupdate apply-local <bundle.swsite>\n")
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc >= 2, let cmdp = argv[1] else {
        usage()
        return 2
    }
    if cstrEq(cmdp, "seed") {
        return seed()
    }
    if cstrEq(cmdp, "apply-local") {
        guard argc >= 3, let p = argv[2] else { usage(); return 2 }
        var path: [CChar] = []
        var i = 0
        while p[i] != 0 { path.append(p[i]); i += 1 }
        path.append(0)
        return applyLocal(path)
    }
    usage()
    return 2
}

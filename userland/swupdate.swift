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

// SWSITE signed-bundle layout constants and pure parsers (sigSize, hdrSize,
// entrySize, maxSiteEntries, siteMagic, le32, magicMatches, safeName,
// swsiteParseEntries, parseIPv4Bytes, parseHTTPSURL, httpBody) live in
// userland/lib/swsite.swift so they can be host-tested without QEMU.
private let maxBundleBytes = 8 * 1024 * 1024

// OS-4: baked image-signing public key — the trust anchor for SWSYS OS bundles
// (the same key, IMG_SIGNING_PUB, the kernel uses for base/kernel images). The
// `os` subcommand verifies a SWSYS bundle against it before staging the base
// image into the inactive A/B slot. The bundle format lives in
// userland/lib/sysbundle.swift (shared with the host packer tools/syspack.swift).
private let pOsRootPub: StaticString = "/etc/swupdate/os-root.pub"
// A SWSYS bundle carries a full kernel + full base image; allow a large fetch.
// (Held in memory for the Ed25519 verify, which needs the whole body contiguous;
// a streaming/prehashed verify for very large bases is future work.)
private let maxOsBundleBytes = 96 * 1024 * 1024
private let osStageChunk = 64 * 1024

// TLS opt-out: set by a `--insecure` argument. HTTPS cert verification (against
// the system trust store) is on by default; --insecure is for mock/bring-up
// servers only. See httpsGet().
private var gInsecure = false

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

    // 4. Validate the layout + every entry name (bounds, inode budget, no path
    //    traversal) before touching the filesystem. swsiteParseEntries is pure and
    //    host-tested (tests/swsite_test.swift); a bad bundle returns an error here.
    let (entries, layoutErr) = swsiteParseEntries(bundle)
    switch layoutErr {
    case .ok: break
    case .entryCountRange: put("swupdate: bundle entry count out of range (inode budget)\n"); return 1
    case .layoutBounds:    put("swupdate: bundle layout out of bounds\n"); return 1
    case .badEntryName:    put("swupdate: bad entry name\n"); return 1
    case .badEntryBlob:    put("swupdate: bad entry blob\n"); return 1
    case .unsafeName:      put("swupdate: unsafe entry name — rejected\n"); return 1
    }

    // 5. Stage the validated entries into a fresh /data/www/next.
    _ = sMkdir(cz(pWww))
    deleteTree(cz(pNext))
    if sMkdir(cz(pNext)) < 0 && statMode(cz(pNext)) == nil {
        put("swupdate: cannot create staging dir\n"); return 1
    }
    for entry in entries {
        let dst = joinPath(cz(pNext), entry.name)
        if entry.isDir {
            if sMkdir(dst) < 0 && statMode(dst) == nil { put("swupdate: mkdir failed in staging\n"); return 1 }
        } else {
            let fd = sOpen(dst, oWrOnly | oCreat | oTrunc)
            if fd < 0 { put("swupdate: cannot create file in staging\n"); return 1 }
            let ok = writeBlob(fd, bundle, entry.blobFileOff, entry.blobLen)
            _ = swiftos_fsync(fd)
            _ = swiftos_close(fd)
            if !ok { put("swupdate: write failed in staging\n"); return 1 }
        }
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

// ---- HTTPS fetch (SU-C) -----------------------------------------------------
//
// `swupdate site <url>` pulls a SWSITE bundle over TLS 1.3 and applies it. TLS
// here provides confidentiality only — the tls13 engine does not yet verify the
// server certificate — but that is acceptable because the bundle's Ed25519
// signature (checked in applyBundleBytes against the baked pubkey) is the real
// authenticity anchor: a MITM serving a different bundle fails signature verify.

// Fill `buf` with kernel entropy (falls back to a dev PRNG without virtio-rng);
// copied from /bin/tlsget — acceptable while cert checks are deferred.
private func fillRandom(_ buf: UnsafeMutableRawPointer, _ n: Int) {
    var off = 0
    while off < n {
        let r = swiftos_random(buf + off, UInt(n - off))
        if r <= 0 { break }
        off += Int(r)
    }
    if off == n { return }
    var probe: UInt64 = 0
    var x = UInt64(swiftos_time())
        ^ (UInt64(bitPattern: Int64(swiftos_getpid())) &* 0x9E37_79B9_7F4A_7C15)
        ^ withUnsafeMutablePointer(to: &probe) { UInt64(UInt(bitPattern: $0)) }
        ^ UInt64(off)
    if x == 0 { x = 0x9E37_79B9_7F4A_7C15 }
    var i = off
    while i < n {
        x = x &* 6364136223846793005 &+ 1442695040888963407
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        buf.storeBytes(of: UInt8((z >> 24) & 0xFF), toByteOffset: i, as: UInt8.self)
        i += 1
    }
}

// Fetch the body of GET https://host:port/path over TLS 1.3 into memory.
private func httpsGet(ip: UInt32, port: UInt16, host: [UInt8], path: [UInt8], maxBytes: Int) -> [UInt8]? {
    let fd = swiftos_socket_stream()
    if fd < 0 { put("swupdate: socket failed\n"); return nil }
    if swiftos_connect(fd, ip, port) != 0 { put("swupdate: connect failed\n"); _ = swiftos_close(fd); return nil }
    defer { _ = swiftos_close(fd) }

    let client = TLS13Client()
    // TLS server-certificate verification is ON by default, anchored at the system
    // trust store (/etc/ssl/cert.pem). The SWSYS/SWSITE payloads are Ed25519-signed
    // regardless, so this is defense-in-depth; --insecure disables it for mock/
    // bring-up servers.
    if !gInsecure {
        let roots = loadSystemTrustRoots()
        if roots.isEmpty {
            put("swupdate: no trust roots (need /etc/ssl/cert.pem or --insecure)\n")
            return nil
        }
        var hostBytes: [UInt8] = []
        for b in host { if b == 0 { break }; hostBytes.append(b) }
        client.enableVerification(rootsDER: roots,
                                  hostname: String(decoding: hostBytes, as: UTF8.self),
                                  now: unixToYYYYMMDDHHMMSS(UInt64(swiftos_time())))
    }
    var sk = [UInt8](repeating: 0, count: 32)
    var ch = [UInt8](repeating: 0, count: 32)
    sk.withUnsafeMutableBytes { fillRandom($0.baseAddress!, 32) }
    ch.withUnsafeMutableBytes { fillRandom($0.baseAddress!, 32) }
    sk.withUnsafeBytes { skp in ch.withUnsafeBytes { chp in
        client.startHandshake(randomSK: skp.baseAddress!, randomCH: chp.baseAddress!)
    } }

    let rxCap = tlsMaxRecord
    let buf = UnsafeMutableRawPointer.allocate(byteCount: rxCap, alignment: 16)
    defer { buf.deallocate() }

    func flushOut() -> Bool {
        while client.pendingOut > 0 {
            let ok = withUnsafeTemporaryAllocation(byteCount: tlsMaxRecord, alignment: 16) { raw -> Bool in
                let n = client.takeTLS(raw.baseAddress!, raw.count)
                if n <= 0 { return true }
                var off = 0
                while off < n {
                    let w = swiftos_write(fd, raw.baseAddress!.advanced(by: off), UInt(n - off))
                    if w <= 0 { return false }
                    off += Int(w)
                }
                return true
            }
            if !ok { return false }
        }
        return true
    }

    if !flushOut() { return nil }
    var done = false, failed = false
    switch client.advance() {
    case .handshakeComplete: done = true
    case .failed: failed = true
    case .needMoreData: break
    }
    while !done && !failed {
        let r = swiftos_read(fd, buf, UInt(rxCap))
        if r <= 0 { failed = true; break }
        client.feedTLS(buf, Int(r))
        switch client.advance() {
        case .handshakeComplete: done = true
        case .failed: failed = true
        case .needMoreData: break
        }
        if !flushOut() { failed = true; break }
    }
    if failed || !done { put("swupdate: TLS handshake failed\n"); return nil }
    if !flushOut() { return nil }

    // Encrypted HTTP/1.1 GET.
    var req: [UInt8] = []
    req.append(contentsOf: Array("GET ".utf8))
    req.append(contentsOf: path)
    req.append(contentsOf: Array(" HTTP/1.1\r\nHost: ".utf8))
    req.append(contentsOf: host)
    req.append(contentsOf: Array("\r\nConnection: close\r\n\r\n".utf8))
    req.withUnsafeBytes { client.sendAppData($0.baseAddress!, $0.count) }
    if !flushOut() { return nil }

    // Read + decrypt the whole response into memory.
    var resp: [UInt8] = []
    while true {
        let r = swiftos_read(fd, buf, UInt(rxCap))
        if r <= 0 { break }                      // server closed (EOF)
        client.feedTLS(buf, Int(r))
        _ = client.advance()
        while client.pendingAppData > 0 {
            let n = client.receiveAppData(buf, rxCap)
            if n <= 0 { break }
            let bp = buf.assumingMemoryBound(to: UInt8.self)
            var j = 0
            while j < n { resp.append(bp[j]); j += 1 }
            if resp.count > maxBytes + 65536 { put("swupdate: response too large\n"); return nil }
        }
        if client.lastError != 0 { break }
    }
    return resp
}

private func site(_ url: UnsafeMutablePointer<CChar>) -> Int32 {
    guard let (host, port, path) = parseHTTPSURL(url) else {
        put("swupdate: usage: swupdate site https://host[:port]/path\n"); return 2
    }
    // Resolve the host: a literal IPv4 is used directly, otherwise via DNS.
    var ip: UInt32 = 0
    if let v = parseIPv4Bytes(host) {
        ip = v
    } else {
        var hostC = host.map { CChar(bitPattern: $0) }
        hostC.append(0)
        ip = hostC.withUnsafeBufferPointer { swiftos_resolve($0.baseAddress!, 0, 0) }
        if ip == 0 { put("swupdate: cannot resolve host\n"); return 1 }
    }
    guard let resp = httpsGet(ip: ip, port: port, host: host, path: path, maxBytes: maxBundleBytes) else { return 1 }
    guard let body = httpBody(resp), body.count >= sigSize + hdrSize else {
        put("swupdate: fetch did not return a bundle\n"); return 1
    }
    return applyBundleBytes(body)
}

// ---- OS self-update (OS-4): SWSYS kernel+base bundle ------------------------
//
// `swupdate os <url>` / `swupdate os-apply-local <file>` apply a signed SWSYS
// system-update bundle (tools/syspack.swift): verify its Ed25519 signature and
// payload SHA against the baked OS-signing key, then stream BOTH halves into the
// INACTIVE A/B slot via the capability-gated kernel syscalls — the base image into
// the SWOSBOOT store slot (OS-3b) and, when an ESP kernel A/B is present, the
// padded kernel into the inactive ESP slot with its per-slot signed manifest entry
// (OS-1c-2b/3) — then flip the single coordinated selector so kernel + base
// activate together (OS-1). The kernel enforces the monotonic anti-rollback floor
// at base stage-begin and re-verifies the per-slot kernel signature at install
// commit, so an older or unsigned OS is refused. On a store-only box (no ESP) the
// kernel half is skipped and only the base is updated.

private func loadOsPubkey() -> [UInt8]? {
    guard let raw = readFileFully(cz(pOsRootPub), 64), raw.count == 32 else { return nil }
    return raw
}

// Verify a SWSYS bundle, then stream its base image into the inactive slot and
// activate it. Returns 0 on success; nonzero (with a message) on any rejection.
private func applyOsBundleBytes(_ bundle: [UInt8]) -> Int32 {
    guard let pub = loadOsPubkey() else {
        put("swupdate: missing/invalid OS-signing key\n"); return 1
    }
    // 1. Authenticity + integrity + format (the kernel re-checks anti-rollback).
    let result = bundle.withUnsafeBytes { bb in
        pub.withUnsafeBytes { pb in
            verifySysBundle(bb.baseAddress!, bundle.count, publicKey: pb.baseAddress!, minVersion: 0)
        }
    }
    let hdr: SysBundleHeader
    switch result {
    case .ok(let h): hdr = h
    case .badSize: put("swupdate: os bundle too small\n"); return 1
    case .badSignature: put("swupdate: os bundle signature INVALID — rejected\n"); return 1
    case .badMagic: put("swupdate: bad os bundle magic\n"); return 1
    case .badFormatVersion: put("swupdate: unsupported os bundle format version\n"); return 1
    case .badLayout: put("swupdate: os bundle layout out of bounds\n"); return 1
    case .badPayloadSha: put("swupdate: os bundle payload sha256 mismatch\n"); return 1
    case .tooOld: put("swupdate: os bundle below the anti-rollback floor — rejected\n"); return 1
    }

    // 2. Reserve the inactive slot (kernel enforces version > floor + slot fit).
    let baseFileOff = sigSize + hdr.baseOff   // base bytes within the whole bundle
    let brc = swiftos_update_stage_begin(UInt(hdr.systemVersion), UInt(hdr.baseLen))
    if brc != 0 {
        if brc == -1 { put("swupdate: os update refused — anti-rollback (version not newer) or missing CAP_CONSOLE\n") }
        else if brc == -19 { put("swupdate: not booted from an A/B update store\n") }
        else if brc == -27 { put("swupdate: base image too large for the inactive slot\n") }
        else { put("swupdate: os stage begin failed\n") }
        return 1
    }

    // 3. Stream the base image into the slot.
    var off = 0
    var wroteOK = true
    bundle.withUnsafeBytes { raw in
        let basep = raw.baseAddress!.advanced(by: baseFileOff)
        while off < hdr.baseLen {
            var n = hdr.baseLen - off
            if n > osStageChunk { n = osStageChunk }
            if swiftos_update_stage_write(basep.advanced(by: off), UInt(n)) != 0 { wroteOK = false; break }
            off += n
        }
    }
    if !wroteOK {
        _ = swiftos_update_stage_abort()
        put("swupdate: os stage write failed\n"); return 1
    }

    // 4. Commit (kernel validates the SWOSBASE header + flushes), then activate.
    if swiftos_update_stage_commit() != 0 {
        put("swupdate: os stage commit rejected (base is not a signed v3 image)\n"); return 1
    }

    // 4b. (OS-1c-3) Install the kernel half into the inactive ESP slot too, when an
    // ESP kernel A/B is present, so the coordinated activate below moves kernel +
    // base together. Stream the padded kernel image, then commit the per-slot signed
    // entry sliced from the bundle's v4 manifest for the slot the kernel reserved
    // (the kernel re-verifies that entry's signature + the on-disk re-hash). On a
    // store-only box (no ESP) begin returns ENODEV and we skip — base-only activate
    // below handles it. Neither half is activated until step 5's selector flip, so a
    // failure here leaves the box on the current slot (the staged base is inert).
    let kSlot = swiftos_kernel_install_begin()
    if kSlot >= 0 {
        var koff = 0
        var kOK = true
        bundle.withUnsafeBytes { raw in
            let kp = raw.baseAddress!.advanced(by: sigSize + hdr.kernelOff)
            while koff < hdr.kernelLen {
                var n = hdr.kernelLen - koff
                if n > osStageChunk { n = osStageChunk }
                if swiftos_kernel_install_write(kp.advanced(by: koff), UInt(n)) != 0 { kOK = false; break }
                koff += n
            }
        }
        if !kOK {
            _ = swiftos_kernel_install_abort()
            put("swupdate: kernel stage write failed\n"); return 1
        }
        // Slice the 104-byte per-slot entry for the reserved slot (A@24, B@128).
        let entryOff = sigSize + hdr.kmanifestOff + (kSlot == 0 ? 24 : 128)
        let kcrc = bundle.withUnsafeBytes { raw in
            swiftos_kernel_install_commit(raw.baseAddress!.advanced(by: entryOff))
        }
        if kcrc != 0 {
            put("swupdate: kernel install commit rejected (entry sig/hash) — kernel NOT updated\n"); return 1
        }
        put("swupdate: new kernel installed into the inactive ESP slot (verified)\n")
    } else if kSlot != -19 {   // -19 ENODEV = store-only box (no ESP); anything else is fatal
        put("swupdate: kernel install begin failed\n"); return 1
    }

    // 5. Coordinated activate (OS-1). When an ESP kernel-state is present it is the
    // single A/B authority: flip it so the loader boots the other kernel slot and
    // the base follows it on the next boot — kernel + base activate together. On a
    // store-only box (no ESP) kernel_activate returns ENODEV; fall back to flipping
    // the SWOSBOOT base selector directly.
    let krc = swiftos_kernel_activate()
    if krc == 0 {
        put("swupdate: OS staged + ESP selector flipped (kernel+base activate together); reboot to boot the new system (on trial)\n")
        return 0
    }
    if krc == -19 {   // ENODEV: no ESP — store-only box
        if swiftos_update_activate() != 0 {
            put("swupdate: base image staged but activate failed — run /bin/swos-activate\n"); return 1
        }
        put("swupdate: OS base image staged + activated; reboot to boot the new system (on trial)\n")
        return 0
    }
    put("swupdate: base image staged but ESP selector flip failed — run /bin/swos-kactivate\n")
    return 1
}

private func osApplyLocal(_ path: [CChar]) -> Int32 {
    guard let bundle = readFileFully(path, maxOsBundleBytes) else {
        put("swupdate: cannot read os bundle file\n"); return 1
    }
    return applyOsBundleBytes(bundle)
}

private func osUpdate(_ url: UnsafeMutablePointer<CChar>) -> Int32 {
    guard let (host, port, path) = parseHTTPSURL(url) else {
        put("swupdate: usage: swupdate os https://host[:port]/path\n"); return 2
    }
    var ip: UInt32 = 0
    if let v = parseIPv4Bytes(host) {
        ip = v
    } else {
        var hostC = host.map { CChar(bitPattern: $0) }
        hostC.append(0)
        ip = hostC.withUnsafeBufferPointer { swiftos_resolve($0.baseAddress!, 0, 0) }
        if ip == 0 { put("swupdate: cannot resolve host\n"); return 1 }
    }
    guard let resp = httpsGet(ip: ip, port: port, host: host, path: path, maxBytes: maxOsBundleBytes) else { return 1 }
    guard let body = httpBody(resp), body.count >= SysBundleFormat.sigSize + SysBundleFormat.headerSize else {
        put("swupdate: fetch did not return an os bundle\n"); return 1
    }
    return applyOsBundleBytes(body)
}

// ---- confirm (OS-5): health-confirm the booted slot ------------------------
//
// `swupdate confirm` marks the A/B slot booted this session healthy: it stops
// accruing boot attempts and is never rolled back, and the kernel raises the
// anti-rollback floor to this slot's version. `confirm --auto` only does so when
// the box looks healthy (sshd + nginx are running) — so a trial boot that never
// reaches a healthy state is left to the attempt-based rollback instead.

// Substring match of `needle` within a NUL-terminated C string.
private func cstrHas(_ hay: UnsafePointer<CChar>, _ needle: StaticString) -> Bool {
    let nlen = needle.utf8CodeUnitCount
    if nlen == 0 { return true }
    var i = 0
    while hay[i] != 0 {
        var j = 0
        while j < nlen && hay[i + j] != 0
            && UInt8(bitPattern: hay[i + j]) == needle.utf8Start[j] { j += 1 }
        if j == nlen { return true }
        i += 1
    }
    return false
}

// True if a running process's name contains `needle`.
private func serviceRunning(_ needle: StaticString) -> Bool {
    let n = swiftos_ps_refresh()
    if n <= 0 { return false }
    var idx: Int32 = 0
    while idx < n {
        if let nm = swiftos_ps_name(idx), cstrHas(nm, needle) { return true }
        idx += 1
    }
    return false
}

private func confirm(auto: Bool) -> Int32 {
    if auto {
        let sshUp = serviceRunning("sshd")
        let webUp = serviceRunning("nginx")
        if !(sshUp && webUp) {
            put("swupdate: confirm --auto: services not healthy (need sshd + nginx running); leaving slot on trial\n")
            return 1
        }
        put("swupdate: confirm --auto: sshd + nginx up\n")
    }
    // Confirm both halves; ENODEV (-19) just means that half is not an A/B store
    // in this boot topology (e.g. no ESP kernel A/B on a store-only box).
    let baseRc = swiftos_update_confirm()
    let kernRc = swiftos_kernel_confirm()
    if baseRc == 0 { put("swupdate: base A/B slot confirmed healthy\n") }
    if kernRc == 0 { put("swupdate: kernel A/B slot confirmed healthy\n") }
    if baseRc == 0 || kernRc == 0 { return 0 }
    if baseRc == -1 || kernRc == -1 {
        put("swupdate: confirm: permission denied (need CAP_CONSOLE)\n"); return 1
    }
    put("swupdate: confirm: not booted from an A/B update store\n")
    return 1
}

// ---- entry point -----------------------------------------------------------

private func usage() {
    put("usage: swupdate seed | swupdate apply-local <bundle.swsite> | swupdate site <https-url>\n")
    put("       swupdate os <https-url> | swupdate os-apply-local <bundle.swsys>\n")
    put("       swupdate confirm [--auto]\n")
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
    // Global TLS opt-out: any `--insecure` arg disables HTTPS cert verification
    // for this run (mock servers / bring-up only). On by default otherwise.
    var ti = 2
    while ti < Int(argc) { if let a = argv[ti], cstrEq(a, "--insecure") { gInsecure = true }; ti += 1 }
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
    if cstrEq(cmdp, "site") {
        guard argc >= 3, let p = argv[2] else { usage(); return 2 }
        return site(p)
    }
    if cstrEq(cmdp, "os") {
        guard argc >= 3, let p = argv[2] else { usage(); return 2 }
        return osUpdate(p)
    }
    if cstrEq(cmdp, "os-apply-local") {
        guard argc >= 3, let p = argv[2] else { usage(); return 2 }
        var path: [CChar] = []
        var i = 0
        while p[i] != 0 { path.append(p[i]); i += 1 }
        path.append(0)
        return osApplyLocal(path)
    }
    if cstrEq(cmdp, "confirm") {
        var auto = false
        if argc >= 3, let a = argv[2], cstrEq(a, "--auto") { auto = true }
        return confirm(auto: auto)
    }
    usage()
    return 2
}

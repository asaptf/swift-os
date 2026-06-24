// SPDX-License-Identifier: Apache-2.0
// swos_identity.swift — crash-safe credential overlay for the immutable base
// image (Phase 1, password-change submilestone P1).
//
// The base image is read-only and signed, so /etc/swos/passwd cannot be edited
// in place. Mutable credentials therefore live as an *overlay* on the persistent
// /data tier and are merged over the base at authentication time. Because datafs
// has no journal and no atomic rename (only honest fsync — see
// kernel/fs/datafs.swift), crash-safety is built here, at the application layer,
// exactly as CLAUDE.md prescribes ("honest fsync plus the application's own
// journaling, not FS journaling").
//
// Two mechanisms combine:
//
//   1. Dual-bank ping-pong. The passwd overlay is stored in TWO fixed-size,
//      self-checksummed, generation-stamped banks (passwd.0 / passwd.1). A change
//      is written to whichever bank is NOT the current winner, then fsync'd; the
//      fsync is the single commit point. A crash mid-write only ever tears the
//      non-winning bank (detected by checksum and ignored), so the last committed
//      credential always survives. No single crash can revert a committed
//      non-default password to the base default.
//
//   2. Provisioned anchor. A separate dual-bank pair (anchor.0 / anchor.1) records
//      a monotonic high-water generation once any password has been committed.
//      If, after provisioning, BOTH passwd banks are lost or corrupt (disk rot or
//      an attacker mutating /data — never a single crash), or a stale lower-
//      generation overlay is restored (rollback), authentication FAILS CLOSED
//      rather than falling back to the factory default. Recovery is a separate,
//      physically-gated path (submilestone P4).
//
// Pure Swift: no Foundation, no syscalls, no heap-per-op — same discipline as
// kernel/crypto/sha256.swift, which this module is compiled alongside. The file
// therefore builds both into userland ELFs (/bin/passwd, /bin/console-login) and
// into the host unit test (tests/identity_test.swift). All file I/O — reading the
// four bank files and writing/fsync'ing a new bank — lives in the callers, so
// every policy decision here is exercised on the host with synthetic buffers.

// Byte accessors, kept local so the module is self-contained.
@inline(__always) private func idLd(_ p: UnsafeRawPointer, _ o: Int) -> UInt8 {
    p.load(fromByteOffset: o, as: UInt8.self)
}
@inline(__always) private func idSt(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt8) {
    p.storeBytes(of: v, toByteOffset: o, as: UInt8.self)
}
@inline(__always) private func idMin(_ a: Int, _ b: Int) -> Int { a < b ? a : b }

// MARK: - PBKDF2-HMAC-SHA256 (RFC 8018 §5.2)

/// Default work factor for newly hashed passwords. Stored per-hash in the field,
/// so it can be raised later without a format change; calibrate against the
/// target's software SHA-256 (no AES/SHA hardware acceleration in the freestanding
/// build). Kept modest so interactive login on emulated hardware stays responsive.
let identityDefaultIterations = 50_000

/// Derived-key length in bytes (one HMAC-SHA256 block).
let identityDkLen = 32

/// PBKDF2-HMAC-SHA256: derive `dkLen` bytes into `out` from `password`/`salt` over
/// `iterations` rounds. Implements the T_1 ‖ T_2 ‖ … construction (RFC 8018 §5.2)
/// with the U_j = PRF(P, U_{j-1}) recurrence done in place. Stack-only.
func pbkdf2HmacSha256(_ password: UnsafeRawPointer, _ passwordLen: Int,
                      _ salt: UnsafeRawPointer, _ saltLen: Int,
                      _ iterations: Int,
                      _ out: UnsafeMutableRawPointer, _ dkLen: Int) {
    let hLen = 32
    let blocks = (dkLen + hLen - 1) / hLen
    // saltBlock = salt ‖ INT32BE(i); reused across blocks (only the last 4 bytes
    // change), and as the message for the first PRF call of each block.
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: saltLen + 4) { sb in
        let saltBlock = sb.baseAddress!
        for i in 0..<saltLen { idSt(saltBlock, i, idLd(salt, i)) }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: hLen) { ub in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: hLen) { tb in
                let U = ub.baseAddress!
                let T = tb.baseAddress!
                var block = 1
                while block <= blocks {
                    idSt(saltBlock, saltLen,     UInt8((block >> 24) & 0xFF))
                    idSt(saltBlock, saltLen + 1, UInt8((block >> 16) & 0xFF))
                    idSt(saltBlock, saltLen + 2, UInt8((block >> 8) & 0xFF))
                    idSt(saltBlock, saltLen + 3, UInt8(block & 0xFF))
                    // U_1 = PRF(P, salt ‖ INT32BE(block)); T = U_1.
                    hmacSha256(password, passwordLen, saltBlock, saltLen + 4, U)
                    for k in 0..<hLen { idSt(T, k, idLd(U, k)) }
                    var it = 1
                    while it < iterations {
                        // U_j = PRF(P, U_{j-1}); HMAC reads the whole message before
                        // writing its output, so the in-place U → U aliasing is safe.
                        hmacSha256(password, passwordLen, U, hLen, U)
                        for k in 0..<hLen { idSt(T, k, idLd(T, k) ^ idLd(U, k)) }
                        it += 1
                    }
                    let off = (block - 1) * hLen
                    let n = idMin(hLen, dkLen - off)
                    for k in 0..<n { idSt(out, off + k, idLd(T, k)) }
                    block += 1
                }
            }
        }
    }
}

// MARK: - Password field codec
//
// New format:    pbkdf2-sha256$<iters>$<salthex>$<dkhex>
// Legacy format: <salthex>$<sha256hex>   (SHA-256(salt+password); base-image seed)
//
// `identityVerifyField` accepts both so existing base entries keep working while
// changed passwords are written in the modern format. Comparisons are
// constant-time over the digest to avoid leaking a match prefix.

@inline(__always) private func idHexNibble(_ b: UInt8) -> Int {
    if b >= 0x30 && b <= 0x39 { return Int(b - 0x30) }
    if b >= 0x61 && b <= 0x66 { return Int(b - 0x61) + 10 }
    if b >= 0x41 && b <= 0x46 { return Int(b - 0x41) + 10 }
    return -1
}

/// Decode `len` hex characters at `src` into `out` (len/2 bytes). Returns the byte
/// count, or -1 on an odd length or a non-hex character.
private func idHexDecode(_ src: UnsafeRawPointer, _ len: Int, _ out: UnsafeMutableRawPointer, _ outCap: Int) -> Int {
    if len % 2 != 0 || len / 2 > outCap { return -1 }
    var i = 0
    while i < len {
        let hi = idHexNibble(idLd(src, i))
        let lo = idHexNibble(idLd(src, i + 1))
        if hi < 0 || lo < 0 { return -1 }
        idSt(out, i / 2, UInt8((hi << 4) | lo))
        i += 2
    }
    return len / 2
}

@inline(__always) private func idHexChar(_ nibble: UInt8) -> UInt8 {
    nibble < 10 ? 0x30 &+ nibble : 0x61 &+ (nibble &- 10)
}

/// Encode `len` bytes at `src` as lowercase hex into `out` (2*len chars).
private func idHexEncode(_ src: UnsafeRawPointer, _ len: Int, _ out: UnsafeMutableRawPointer) {
    for i in 0..<len {
        let byte = idLd(src, i)
        idSt(out, i * 2,     idHexChar(byte >> 4))
        idSt(out, i * 2 + 1, idHexChar(byte & 0xF))
    }
}

/// Constant-time equality of two byte ranges.
private func idConstEq(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ len: Int) -> Bool {
    var diff: UInt8 = 0
    for i in 0..<len { diff |= idLd(a, i) ^ idLd(b, i) }
    return diff == 0
}

/// Parse a decimal integer at `src[0..<len]`.
private func idParseUInt(_ src: UnsafeRawPointer, _ len: Int) -> Int {
    var v = 0
    var i = 0
    while i < len {
        let c = idLd(src, i)
        if c < 0x30 || c > 0x39 { break }
        v = v * 10 + Int(c - 0x30)
        i += 1
    }
    return v
}

/// The (start, length) of the n-th `$`-separated segment of field[0..<len].
private func idDollarSeg(_ field: UnsafeRawPointer, _ len: Int, _ n: Int) -> (start: Int, len: Int) {
    var idx = 0
    var start = 0
    var i = 0
    while true {
        if i == len || idLd(field, i) == 0x24 { // '$'
            if idx == n { return (start, i - start) }
            idx += 1
            start = i + 1
        }
        if i == len { break }
        i += 1
    }
    return (-1, 0)
}

/// True if field[0..<len] starts with the literal `pbkdf2-sha256$`.
private func idIsPbkdf2(_ field: UnsafeRawPointer, _ len: Int) -> Bool {
    let tag: [UInt8] = [0x70,0x62,0x6b,0x64,0x66,0x32,0x2d,0x73,0x68,0x61,0x32,0x35,0x36,0x24] // "pbkdf2-sha256$"
    if len < tag.count { return false }
    for i in 0..<tag.count { if idLd(field, i) != tag[i] { return false } }
    return true
}

/// Verify `password` against a password field. Supports both the modern
/// pbkdf2-sha256 format and the legacy salt$sha256hex format. Returns false on any
/// malformed field rather than trapping.
func identityVerifyField(_ field: UnsafeRawPointer, _ fieldLen: Int,
                         _ password: UnsafeRawPointer, _ passwordLen: Int) -> Bool {
    if idIsPbkdf2(field, fieldLen) {
        let segIters = idDollarSeg(field, fieldLen, 1)
        let segSalt  = idDollarSeg(field, fieldLen, 2)
        let segHash  = idDollarSeg(field, fieldLen, 3)
        if segIters.start < 0 || segSalt.start < 0 || segHash.start < 0 { return false }
        let iters = idParseUInt(field + segIters.start, segIters.len)
        if iters < 1 { return false }
        if segHash.len != identityDkLen * 2 { return false }   // 32-byte digest, hex
        var ok = false
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { saltb in   // up to 64-byte salt
            let saltLen = idHexDecode(field + segSalt.start, segSalt.len, saltb.baseAddress!, 64)
            if saltLen < 0 { return }
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: identityDkLen) { wantb in
                if idHexDecode(field + segHash.start, segHash.len, wantb.baseAddress!, identityDkLen) != identityDkLen { return }
                withUnsafeTemporaryAllocation(of: UInt8.self, capacity: identityDkLen) { gotb in
                    pbkdf2HmacSha256(password, passwordLen, saltb.baseAddress!, saltLen,
                                     iters, gotb.baseAddress!, identityDkLen)
                    ok = idConstEq(gotb.baseAddress!, wantb.baseAddress!, identityDkLen)
                }
            }
        }
        return ok
    }
    // Legacy: salt$sha256hex (one '$', 64-hex digest of salt‖password).
    let segSalt = idDollarSeg(field, fieldLen, 0)
    let segHash = idDollarSeg(field, fieldLen, 1)
    if segSalt.start < 0 || segHash.start < 0 || segHash.len != 64 { return false }
    if idDollarSeg(field, fieldLen, 2).start >= 0 { return false } // exactly one '$'
    let saltLen = segHash.start - 1 - segSalt.start
    var ok = false
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: saltLen + passwordLen) { m in
        for k in 0..<saltLen { idSt(m.baseAddress!, k, idLd(field + segSalt.start, k)) }
        for k in 0..<passwordLen { idSt(m.baseAddress!, saltLen + k, idLd(password, k)) }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { hex in
            sha256Hex(m.baseAddress!, saltLen + passwordLen, hex.baseAddress!)
            ok = idConstEq(hex.baseAddress!, field + segHash.start, 64)
        }
    }
    return ok
}

/// Build a modern `pbkdf2-sha256$<iters>$<salthex>$<dkhex>` field into `out`,
/// returning its length, or -1 if it would not fit in `outCap`. Used by /bin/passwd.
func identityBuildPbkdf2Field(_ password: UnsafeRawPointer, _ passwordLen: Int,
                              _ salt: UnsafeRawPointer, _ saltLen: Int,
                              _ iterations: Int,
                              _ out: UnsafeMutableRawPointer, _ outCap: Int) -> Int {
    let prefix: [UInt8] = [0x70,0x62,0x6b,0x64,0x66,0x32,0x2d,0x73,0x68,0x61,0x32,0x35,0x36,0x24] // "pbkdf2-sha256$"
    var pos = 0
    @inline(__always) func emit(_ b: UInt8) -> Bool { if pos >= outCap { return false }; idSt(out, pos, b); pos += 1; return true }
    for b in prefix { if !emit(b) { return -1 } }
    // iterations, decimal
    var divisor = 1
    while iterations / divisor >= 10 { divisor *= 10 }
    var rest = iterations
    while divisor > 0 { if !emit(0x30 &+ UInt8(rest / divisor)) { return -1 }; rest %= divisor; divisor /= 10 }
    if !emit(0x24) { return -1 } // '$'
    if pos + saltLen * 2 > outCap { return -1 }
    idHexEncode(salt, saltLen, out + pos); pos += saltLen * 2
    if !emit(0x24) { return -1 } // '$'
    if pos + identityDkLen * 2 > outCap { return -1 }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: identityDkLen) { dk in
        pbkdf2HmacSha256(password, passwordLen, salt, saltLen, iterations, dk.baseAddress!, identityDkLen)
        idHexEncode(dk.baseAddress!, identityDkLen, out + pos)
    }
    pos += identityDkLen * 2
    return pos
}

// MARK: - Bank format
//
//   offset 0   magic       "SWPW"      (4)
//   offset 4   version     u8 = 1      (1)
//   offset 5   kind        u8          (1)  1 = passwd overlay, 2 = provisioned anchor
//   offset 6   reserved    u16 = 0     (2)
//   offset 8   generation  u64 LE      (8)
//   offset 16  payloadLen  u32 LE      (4)
//   offset 20  payload     bytes
//   …          zero padding
//   offset 4064 checksum   SHA-256 over bytes [0, 4064)   (32)
//
// A bank is exactly identityBankSize bytes so it sits in one datafs block and a
// rewrite never allocates — it only overwrites existing block(s), keeping the
// block bitmap untouched (no orphan-block window). A torn write fails the
// checksum and is ignored.

let identityBankSize = 4096
let identityBankKindPasswd: UInt8 = 1
let identityBankKindAnchor: UInt8 = 2

private let idOffVersion = 4
private let idOffKind = 5
private let idOffGeneration = 8
private let idOffPayloadLen = 16
private let idOffPayload = 20
private let idOffChecksum = 4064   // identityBankSize - sha256DigestLen
let identityMaxPayload = 4044      // idOffChecksum - idOffPayload

@inline(__always) private func idStU64LE(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt64) {
    var b = 0
    while b < 8 { idSt(p, o + b, UInt8((v >> (UInt64(b) &* 8)) & 0xFF)); b += 1 }
}
@inline(__always) private func idLdU64LE(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
    var v: UInt64 = 0
    var b = 0
    while b < 8 { v |= UInt64(idLd(p, o + b)) << (UInt64(b) &* 8); b += 1 }
    return v
}
@inline(__always) private func idStU32LE(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt32) {
    var b = 0
    while b < 4 { idSt(p, o + b, UInt8((v >> (UInt32(b) &* 8)) & 0xFF)); b += 1 }
}
@inline(__always) private func idLdU32LE(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
    var v: UInt32 = 0
    var b = 0
    while b < 4 { v |= UInt32(idLd(p, o + b)) << (UInt32(b) &* 8); b += 1 }
    return v
}

/// Serialize a bank into `out` (must hold identityBankSize bytes). Returns false if
/// `payloadLen` exceeds identityMaxPayload. The checksum is computed last over the
/// fully-formed, zero-padded body so any later mutation is detectable.
func identityBankWrite(_ out: UnsafeMutableRawPointer, kind: UInt8, generation: UInt64,
                       payload: UnsafeRawPointer?, payloadLen: Int) -> Bool {
    if payloadLen < 0 || payloadLen > identityMaxPayload { return false }
    for i in 0..<identityBankSize { idSt(out, i, 0) }
    idSt(out, 0, 0x53); idSt(out, 1, 0x57); idSt(out, 2, 0x50); idSt(out, 3, 0x57) // "SWPW"
    idSt(out, idOffVersion, 1)
    idSt(out, idOffKind, kind)
    idStU64LE(out, idOffGeneration, generation)
    idStU32LE(out, idOffPayloadLen, UInt32(payloadLen))
    if let src = payload { for i in 0..<payloadLen { idSt(out, idOffPayload + i, idLd(src, i)) } }
    sha256(out, idOffChecksum, out + idOffChecksum)
    return true
}

/// Result of parsing a bank buffer. `payloadOff`/`payloadLen` are valid only when
/// `valid` is true.
struct IdentityBank {
    var valid: Bool = false
    var kind: UInt8 = 0
    var generation: UInt64 = 0
    var payloadOff: Int = 0
    var payloadLen: Int = 0
}

/// Validate a bank buffer: magic, version, payload-length bound, and the SHA-256
/// checksum. A torn or tampered bank returns `valid == false`.
func identityBankParse(_ buf: UnsafeRawPointer, _ len: Int) -> IdentityBank {
    var r = IdentityBank()
    if len < identityBankSize { return r }
    if idLd(buf, 0) != 0x53 || idLd(buf, 1) != 0x57 || idLd(buf, 2) != 0x50 || idLd(buf, 3) != 0x57 { return r }
    if idLd(buf, idOffVersion) != 1 { return r }
    let plen = Int(idLdU32LE(buf, idOffPayloadLen))
    if plen > identityMaxPayload { return r }
    var want = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
    var match = false
    withUnsafeMutableBytes(of: &want) { w in
        sha256(buf, idOffChecksum, w.baseAddress!)
        match = idConstEq(w.baseAddress!, buf + idOffChecksum, sha256DigestLen)
    }
    if !match { return r }
    r.valid = true
    r.kind = idLd(buf, idOffKind)
    r.generation = idLdU64LE(buf, idOffGeneration)
    r.payloadOff = idOffPayload
    r.payloadLen = plen
    return r
}

// MARK: - Dual-bank selection and the resolve policy

/// The winning bank of a ping-pong pair. `anyPresent` distinguishes "no overlay
/// file exists yet" (factory) from "files exist but none validates" (corrupt).
struct IdentityBankSel {
    var anyPresent: Bool = false
    var valid: Bool = false
    var generation: UInt64 = 0
    var payloadOff: Int = 0
    var payloadLen: Int = 0
    var which: Int32 = -1
}

/// Pick the highest-generation valid bank of `kind` from two buffers. A nil buffer
/// means the file is absent; a non-nil buffer that fails parsing is present-but-
/// invalid (e.g. torn by a crash).
func identitySelect(_ b0: UnsafeRawPointer?, _ l0: Int,
                    _ b1: UnsafeRawPointer?, _ l1: Int, _ kind: UInt8) -> IdentityBankSel {
    var sel = IdentityBankSel()
    if b0 != nil || b1 != nil { sel.anyPresent = true }
    if let p0 = b0 {
        let pb = identityBankParse(p0, l0)
        if pb.valid && pb.kind == kind {
            sel.valid = true; sel.generation = pb.generation
            sel.payloadOff = pb.payloadOff; sel.payloadLen = pb.payloadLen; sel.which = 0
        }
    }
    if let p1 = b1 {
        let pb = identityBankParse(p1, l1)
        if pb.valid && pb.kind == kind && (!sel.valid || pb.generation > sel.generation) {
            sel.valid = true; sel.generation = pb.generation
            sel.payloadOff = pb.payloadOff; sel.payloadLen = pb.payloadLen; sel.which = 1
        }
    }
    return sel
}

// Resolve status codes.
let identityUseEntry: Int32 = 0      // matched; outLine holds the authoritative passwd line
let identityNotFound: Int32 = 1      // user not present in overlay or base — reprompt
let identityWrongPassword: Int32 = 2 // user found, password mismatch
let identityFailClosed: Int32 = 3    // provisioned but overlay lost/corrupt/rolled-back — recovery only

/// Find the (start, len) of the line whose 0th `:`-field equals `name` in a
/// passwd-format buffer. Skips empty and '#'-comment lines. Returns (-1, 0) if not
/// found.
private func idFindUserLine(_ buf: UnsafeRawPointer, _ bufLen: Int,
                            _ name: UnsafeRawPointer, _ nameLen: Int) -> (start: Int, len: Int) {
    var i = 0
    while i < bufLen {
        var j = i
        while j < bufLen && idLd(buf, j) != 0x0A { j += 1 }
        let ls = i, ll = j - i
        i = j + 1
        if ll == 0 || idLd(buf, ls) == 0x23 { continue } // empty or '#'
        // 0th field = up to first ':'.
        var f = ls
        while f < ls + ll && idLd(buf, f) != 0x3A { f += 1 }
        let f0len = f - ls
        if f0len == nameLen {
            var same = true
            for k in 0..<nameLen where idLd(buf, ls + k) != idLd(name, k) { same = false }
            if same { return (ls, ll) }
        }
    }
    return (-1, 0)
}

/// The (start, len) of the n-th ':'-field within line[lineStart..<lineStart+lineLen].
private func idLineField(_ buf: UnsafeRawPointer, _ lineStart: Int, _ lineLen: Int, _ n: Int) -> (start: Int, len: Int) {
    var idx = 0
    var start = lineStart
    let end = lineStart + lineLen
    var i = lineStart
    while true {
        if i == end || idLd(buf, i) == 0x3A {
            if idx == n { return (start, i - start) }
            idx += 1
            start = i + 1
        }
        if i == end { break }
        i += 1
    }
    return (-1, 0)
}

/// Authenticate `name`/`password` against the credential overlay merged over the
/// base. The four bank buffers are nil when absent. On useEntry/wrongPassword the
/// authoritative passwd line is copied into `outLine` (NUL-terminated) so the
/// caller can parse principal/session/caps/shell with its own helpers.
///
/// Policy (see the file header for the crash analysis):
///   • valid overlay, not rolled back → look up the user there; users absent from
///     the overlay fall through to the base (merge). A user present in the overlay
///     is judged ONLY against the overlay — a wrong attempt never reaches the base
///     default.
///   • no usable overlay but the anchor proves provisioning → FAIL CLOSED.
///   • never provisioned → base default.
func identityResolve(name: UnsafeRawPointer, nameLen: Int,
                     password: UnsafeRawPointer, passwordLen: Int,
                     passwd0: UnsafeRawPointer?, passwd0Len: Int,
                     passwd1: UnsafeRawPointer?, passwd1Len: Int,
                     anchor0: UnsafeRawPointer?, anchor0Len: Int,
                     anchor1: UnsafeRawPointer?, anchor1Len: Int,
                     base: UnsafeRawPointer, baseLen: Int,
                     outLine: UnsafeMutableRawPointer, outLineCap: Int,
                     outLineLen: inout Int) -> Int32 {
    outLineLen = 0
    let pw = identitySelect(passwd0, passwd0Len, passwd1, passwd1Len, identityBankKindPasswd)
    let anc = identitySelect(anchor0, anchor0Len, anchor1, anchor1Len, identityBankKindAnchor)
    let provisioned = anc.valid
    let watermark: UInt64 = anc.valid ? anc.generation : 0

    // Source line resolution.
    var srcBuf: UnsafeRawPointer = base
    var line = (start: -1, len: 0)

    if pw.valid && pw.generation >= watermark {
        // Trustworthy overlay (committed and not rolled back below the watermark).
        let winBuf: UnsafeRawPointer = pw.which == 0 ? passwd0! : passwd1!
        let payload = winBuf + pw.payloadOff
        let hit = idFindUserLine(payload, pw.payloadLen, name, nameLen)
        if hit.start >= 0 {
            srcBuf = payload; line = hit
        } else {
            // Not changed: merge through to the base entry.
            srcBuf = base; line = idFindUserLine(base, baseLen, name, nameLen)
        }
    } else if provisioned {
        // Overlay missing, corrupt, or rolled back, yet the system is provisioned:
        // refuse rather than silently restoring the factory default.
        return identityFailClosed
    } else {
        // Factory state — never provisioned. Base default applies.
        srcBuf = base; line = idFindUserLine(base, baseLen, name, nameLen)
    }

    if line.start < 0 { return identityNotFound }

    // Copy the authoritative line out (NUL-terminated) for the caller to parse.
    let n = idMin(line.len, outLineCap - 1)
    for k in 0..<n { idSt(outLine, k, idLd(srcBuf, line.start + k)) }
    idSt(outLine, n, 0)
    outLineLen = n

    let f4 = idLineField(srcBuf, line.start, line.len, 4)
    if f4.start < 0 { return identityWrongPassword }
    if identityVerifyField(srcBuf + f4.start, f4.len, password, passwordLen) {
        return identityUseEntry
    }
    return identityWrongPassword
}

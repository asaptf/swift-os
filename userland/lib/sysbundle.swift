// SPDX-License-Identifier: Apache-2.0
// sysbundle.swift — the SWSYS system-update bundle: an I/O-free parser/verifier
// for reflash-free OS (kernel + base image) updates (OS-2).
//
// A SWSYS bundle is what `/bin/swupdate os <url>` fetches over HTTPS and stages
// into the inactive A/B slot. It carries a *full* kernel image and a *full*
// signed SWOSBASE base image, a monotonic `systemVersion` (the anti-rollback
// anchor), and a single Ed25519 signature over the whole body — verified against
// the baked image-signing public key (IMG_SIGNING_PUB). The body also carries a
// SHA-256 over its payload region as a cheap integrity cross-check.
//
// Trust model: the bundle signature + monotonic version are the trust anchor for
// *which* OS may be installed. The carried images remain self-authenticating in
// their own right (the kernel slot by the loader's SWOSKERN hash check, the base
// by its embedded SWOSBASE Ed25519 signature) — so a bundle that passes here but
// carries a corrupt image still fails to boot and the A/B rollback returns to the
// known-good slot. The monotonic version additionally refuses an older,
// validly-signed (and possibly vulnerable) OS — rollback-attack protection the
// per-image signatures alone cannot provide.
//
// This file is I/O-free and holds no mutable global state, so it compiles into
// both the host tool (tools/syspack.swift) and the userland updater
// (userland/swupdate.swift, OS-4) unchanged — like kernel/fs/swosboot.swift. It
// depends only on ed25519Verify + sha256 (Swift crypto available in both).
//
// File layout: [64-byte Ed25519 signature over body][body].
//   body (little-endian):
//     off  0  magic "SWSYS001"        (8 bytes)
//     off  8  u32 formatVersion (= 1)
//     off 12  u32 flags          (0 = full image; deltas reserve bit 0)
//     off 16  u64 systemVersion  (monotonic; anti-rollback)
//     off 24  u32 kernelOff      (body-relative offset of the kernel image)
//     off 28  u32 kernelLen
//     off 32  u32 baseOff        (body-relative offset of the SWOSBASE image)
//     off 36  u32 baseLen
//     off 40  payloadSha256      (32 bytes; SHA-256 of body[72..])
//     off 72  payload: kernel image bytes, then base image bytes

enum SysBundleFormat {
    static let magicLen = 8
    static let sigSize = 64        // leading detached Ed25519 signature
    static let headerSize = 72     // body header (payload begins here)
    static let formatVersion: UInt32 = 1
    static let flagFull: UInt32 = 0

    // Body field offsets.
    static let offFormatVersion = 8
    static let offFlags = 12
    static let offSystemVersion = 16
    static let offKernelOff = 24
    static let offKernelLen = 28
    static let offBaseOff = 32
    static let offBaseLen = 36
    static let offPayloadSha = 40
}

/// A parsed, layout-validated SWSYS body header (signature/SHA checked separately).
struct SysBundleHeader {
    var formatVersion: UInt32
    var flags: UInt32
    var systemVersion: UInt64
    var kernelOff: Int          // body-relative
    var kernelLen: Int
    var baseOff: Int
    var baseLen: Int
}

/// Outcome of verifying a full SWSYS file (signature + magic + layout + payload
/// SHA + monotonic version). A specific reason on failure so callers can report.
enum SysBundleVerify {
    case ok(SysBundleHeader)
    case badSize
    case badSignature
    case badMagic
    case badFormatVersion
    case badLayout
    case badPayloadSha
    case tooOld          // systemVersion < minVersion (anti-rollback)
}

// Little-endian byte readers (byte-wise, no alignment assumption — +strict-align).
@inline(__always) private func sysLd8(_ p: UnsafeRawPointer, _ o: Int) -> UInt8 {
    p.loadUnaligned(fromByteOffset: o, as: UInt8.self)
}
@inline(__always) private func sysLd32(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
    UInt32(sysLd8(p, o)) | (UInt32(sysLd8(p, o + 1)) << 8)
        | (UInt32(sysLd8(p, o + 2)) << 16) | (UInt32(sysLd8(p, o + 3)) << 24)
}
@inline(__always) private func sysLd64(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
    UInt64(sysLd32(p, o)) | (UInt64(sysLd32(p, o + 4)) << 32)
}

@inline(__always) private func sysMagicOK(_ body: UnsafeRawPointer) -> Bool {
    let magic: StaticString = "SWSYS001"
    var ok = true
    magic.withUTF8Buffer { m in
        var i = 0
        while i < SysBundleFormat.magicLen {
            if sysLd8(body, i) != m[i] { ok = false }
            i += 1
        }
    }
    return ok
}

/// Parse and validate a SWSYS body's header (magic, format version, and that the
/// kernel/base regions are non-empty and lie within [headerSize, bodyLen) without
/// overflow). Returns nil on any mismatch — no field is trusted past validation.
/// `body` points at the bytes *after* the 64-byte signature; `bodyLen` is their count.
func parseSysBundleHeader(_ body: UnsafeRawPointer, _ bodyLen: Int) -> SysBundleHeader? {
    if bodyLen < SysBundleFormat.headerSize { return nil }
    if !sysMagicOK(body) { return nil }
    if sysLd32(body, SysBundleFormat.offFormatVersion) != SysBundleFormat.formatVersion { return nil }

    let kOff = Int(sysLd32(body, SysBundleFormat.offKernelOff))
    let kLen = Int(sysLd32(body, SysBundleFormat.offKernelLen))
    let bOff = Int(sysLd32(body, SysBundleFormat.offBaseOff))
    let bLen = Int(sysLd32(body, SysBundleFormat.offBaseLen))

    // Both regions must be non-empty, start at/after the header, and end within
    // the body. Checks are written to avoid Int overflow (offsets are u32-derived,
    // so each fits and the sum fits in Int on a 64-bit host/kernel).
    let h = SysBundleFormat.headerSize
    if kLen < 1 || bLen < 1 { return nil }
    if kOff < h || kOff > bodyLen || kLen > bodyLen - kOff { return nil }
    if bOff < h || bOff > bodyLen || bLen > bodyLen - bOff { return nil }

    return SysBundleHeader(formatVersion: SysBundleFormat.formatVersion,
                           flags: sysLd32(body, SysBundleFormat.offFlags),
                           systemVersion: sysLd64(body, SysBundleFormat.offSystemVersion),
                           kernelOff: kOff, kernelLen: kLen,
                           baseOff: bOff, baseLen: bLen)
}

/// Verify a complete SWSYS file end to end: Ed25519 signature over the body
/// (against `pub`, a 32-byte key), magic + format version + layout, the payload
/// SHA-256 cross-check, and the monotonic-version floor (`systemVersion >=
/// minVersion`). Pure: no I/O, no allocation beyond a 32-byte stack digest.
///
/// `file`/`fileLen` is the whole bundle (sig + body); `pub` is 32 bytes. Pass the
/// installed system version as `minVersion` to reject an equal-or-older OS; pass 0
/// to accept any version (e.g. a host `verify` with no floor).
func verifySysBundle(_ file: UnsafeRawPointer, _ fileLen: Int,
                     publicKey pub: UnsafeRawPointer, minVersion: UInt64) -> SysBundleVerify {
    let sigN = SysBundleFormat.sigSize
    if fileLen < sigN + SysBundleFormat.headerSize { return .badSize }
    let body = file.advanced(by: sigN)
    let bodyLen = fileLen - sigN

    // 1. Signature over the body — the trust anchor.
    if !ed25519Verify(message: body, bodyLen, signature: file, publicKey: pub) {
        return .badSignature
    }
    // 2. Magic / format version.
    if !sysMagicOK(body) { return .badMagic }
    if sysLd32(body, SysBundleFormat.offFormatVersion) != SysBundleFormat.formatVersion {
        return .badFormatVersion
    }
    // 3. Layout.
    guard let hdr = parseSysBundleHeader(body, bodyLen) else { return .badLayout }
    // 4. Payload SHA-256 over body[headerSize..].
    let payloadOff = SysBundleFormat.headerSize
    let payloadLen = bodyLen - payloadOff
    var digest = InlineArray<32, UInt8>(repeating: 0)
    var shaOK = true
    withUnsafeMutableBytes(of: &digest) { raw in
        sha256(body.advanced(by: payloadOff), payloadLen, raw.baseAddress!)
        var i = 0
        while i < 32 {
            if raw.load(fromByteOffset: i, as: UInt8.self)
                != sysLd8(body, SysBundleFormat.offPayloadSha + i) { shaOK = false }
            i += 1
        }
    }
    if !shaOK { return .badPayloadSha }
    // 5. Monotonic anti-rollback floor.
    if hdr.systemVersion < minVersion { return .tooOld }
    return .ok(hdr)
}

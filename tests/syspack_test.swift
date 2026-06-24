// SPDX-License-Identifier: Apache-2.0
// syspack_test.swift — host unit test for the SWSYS system-update bundle core
// (userland/lib/sysbundle.swift), the shared verifier the host packer
// (tools/syspack.swift) and the on-box updater (userland/swupdate.swift, OS-4)
// both use.
//
// Run by `make test`. Covers, against a real Ed25519 keypair derived from a fixed
// seed (no external reference needed — the signer and verifier are the unit):
//   1. A well-formed, correctly-signed bundle verifies OK and round-trips fields.
//   2. The monotonic anti-rollback floor (systemVersion >= minVersion).
//   3. Every rejection path: bad size / signature / magic / format version /
//      layout / payload sha — each isolated by re-signing the malformed body so
//      only the field under test is at fault (the signature check comes first).

import Foundation

private func putLE32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8((v >> 8) & 0xFF)
    b[o + 2] = UInt8((v >> 16) & 0xFF); b[o + 3] = UInt8((v >> 24) & 0xFF)
}
private func putLE64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
    putLE32(&b, o, UInt32(v & 0xFFFF_FFFF)); putLE32(&b, o + 4, UInt32((v >> 32) & 0xFFFF_FFFF))
}

// A fixed 32-byte dev seed, and the public key derived from it.
private let seed: [UInt8] = (0..<32).map { UInt8($0) }
private func derivedPub() -> [UInt8] {
    var pub = [UInt8](repeating: 0, count: 32)
    pub.withUnsafeMutableBytes { pb in
        seed.withUnsafeBytes { sb in ed25519PublicKey(seed: sb.baseAddress!, publicKey: pb.baseAddress!) }
    }
    return pub
}

private func sha256Of(_ b: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    out.withUnsafeMutableBytes { ob in
        if b.isEmpty {
            var dummy: UInt8 = 0
            sha256(&dummy, 0, ob.baseAddress!)
        } else {
            b.withUnsafeBytes { db in sha256(db.baseAddress!, b.count, ob.baseAddress!) }
        }
    }
    return out
}

// Build a SWSYS body. Knobs let each test corrupt exactly one field; the body is
// then signed so the signature stays valid and only that field is at fault.
private func makeBody(version: UInt64,
                      kernel: [UInt8], base: [UInt8], kmanifest: [UInt8],
                      magic: String = "SWSYS001",
                      formatVersion: UInt32 = 2,
                      kernelOffOverride: Int? = nil,
                      kernelLenOverride: Int? = nil,
                      kmanifestLenOverride: Int? = nil,
                      corruptSha: Bool = false) -> [UInt8] {
    let headerSize = 80
    let kernelOff = headerSize
    let baseOff = kernelOff + kernel.count
    let kmOff = baseOff + base.count

    var payload = [UInt8]()
    payload.append(contentsOf: kernel)
    payload.append(contentsOf: base)
    payload.append(contentsOf: kmanifest)
    var sha = sha256Of(payload)
    if corruptSha { sha[0] ^= 0xFF }

    var body = [UInt8](repeating: 0, count: headerSize)
    let mbytes = Array(magic.utf8)
    for i in 0..<min(8, mbytes.count) { body[i] = mbytes[i] }
    putLE32(&body, 8, formatVersion)
    putLE32(&body, 12, 0)                                   // flags
    putLE64(&body, 16, version)
    putLE32(&body, 24, UInt32(kernelOffOverride ?? kernelOff))
    putLE32(&body, 28, UInt32(kernelLenOverride ?? kernel.count))
    putLE32(&body, 32, UInt32(baseOff))
    putLE32(&body, 36, UInt32(base.count))
    putLE32(&body, 40, UInt32(kmOff))
    putLE32(&body, 44, UInt32(kmanifestLenOverride ?? kmanifest.count))
    for i in 0..<32 { body[48 + i] = sha[i] }
    body.append(contentsOf: payload)
    return body
}

// Prepend a valid 64-byte Ed25519 signature over the body.
private func signed(_ body: [UInt8]) -> [UInt8] {
    var sig = [UInt8](repeating: 0, count: 64)
    sig.withUnsafeMutableBytes { gb in
        body.withUnsafeBytes { bb in
            seed.withUnsafeBytes { sb in
                ed25519Sign(message: bb.baseAddress!, body.count, seed: sb.baseAddress!, signature: gb.baseAddress!)
            }
        }
    }
    return sig + body
}

private func verify(_ bundle: [UInt8], minVersion: UInt64 = 0) -> SysBundleVerify {
    let pub = derivedPub()
    return bundle.withUnsafeBytes { bb in
        pub.withUnsafeBytes { pb in
            verifySysBundle(bb.baseAddress!, bundle.count, publicKey: pb.baseAddress!, minVersion: minVersion)
        }
    }
}

@main
struct SysPackTest {
    static var failures = 0
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); failures += 1 }
    }

    static func main() {
        let kernel = [UInt8](repeating: 0xAB, count: 5000)   // stand-in (padded) kernel image
        let base = [UInt8](repeating: 0xCD, count: 9000)     // stand-in base image
        let kmanifest = [UInt8](repeating: 0xEE, count: 232) // stand-in v4 SWOSKERN manifest

        // 1. Well-formed bundle verifies OK and round-trips fields.
        let good = signed(makeBody(version: 5, kernel: kernel, base: base, kmanifest: kmanifest))
        switch verify(good) {
        case .ok(let h):
            check(h.systemVersion == 5, "round-trip systemVersion")
            check(h.formatVersion == 2, "round-trip formatVersion")
            check(h.kernelOff == 80 && h.kernelLen == 5000, "round-trip kernel region")
            check(h.baseOff == 80 + 5000 && h.baseLen == 9000, "round-trip base region")
            check(h.kmanifestOff == 80 + 5000 + 9000 && h.kmanifestLen == 232, "round-trip kernel-manifest region")
        default: check(false, "well-formed bundle should verify OK")
        }

        // 2. Monotonic anti-rollback floor.
        check(isTooOld(verify(good, minVersion: 6)), "version 5 must be rejected below floor 6")
        check(isOK(verify(good, minVersion: 5)), "version 5 must pass floor 5 (idempotent reflash)")
        check(isOK(verify(good, minVersion: 4)), "version 5 must pass floor 4")

        // 3a. Too small.
        check(isBadSize(verify([UInt8](repeating: 0, count: 32))), "tiny buffer must be badSize")

        // 3b. Corrupt signature (flip a sig byte, body intact) -> badSignature.
        var badSig = good; badSig[0] ^= 0xFF
        check(isBadSignature(verify(badSig)), "corrupt signature must be rejected")

        // 3c. Bad magic, re-signed so only magic is at fault -> badMagic.
        let badMagic = signed(makeBody(version: 5, kernel: kernel, base: base, kmanifest: kmanifest, magic: "XXXXX001"))
        check(isBadMagic(verify(badMagic)), "bad magic must be rejected")

        // 3d. Bad format version, re-signed -> badFormatVersion.
        let badFmt = signed(makeBody(version: 5, kernel: kernel, base: base, kmanifest: kmanifest, formatVersion: 99))
        check(isBadFormatVersion(verify(badFmt)), "unknown format version must be rejected")

        // 3e. Out-of-bounds kernel region, re-signed -> badLayout.
        let badLayout = signed(makeBody(version: 5, kernel: kernel, base: base, kmanifest: kmanifest,
                                        kernelLenOverride: 10_000_000))
        check(isBadLayout(verify(badLayout)), "out-of-bounds layout must be rejected")

        // 3f. Kernel offset inside the header, re-signed -> badLayout.
        let badLayout2 = signed(makeBody(version: 5, kernel: kernel, base: base, kmanifest: kmanifest,
                                         kernelOffOverride: 8))
        check(isBadLayout(verify(badLayout2)), "kernel offset inside header must be rejected")

        // 3g. Payload sha mismatch, re-signed -> badPayloadSha.
        let badSha = signed(makeBody(version: 5, kernel: kernel, base: base, kmanifest: kmanifest, corruptSha: true))
        check(isBadPayloadSha(verify(badSha)), "payload sha mismatch must be rejected")

        // 3h. Wrong-size kernel manifest region (v4 manifest is fixed at 232 B) -> badLayout.
        let badManifestLen = signed(makeBody(version: 5, kernel: kernel, base: base, kmanifest: kmanifest,
                                             kmanifestLenOverride: 100))
        check(isBadLayout(verify(badManifestLen)), "wrong-size kernel manifest must be rejected")

        // 3i. A wrong signing key must be rejected (sign with the dev seed, verify
        //     against a different pubkey).
        let otherPub = (0..<32).map { UInt8(($0 + 7) & 0xFF) }
        let wrongKey = good.withUnsafeBytes { bb in
            otherPub.withUnsafeBytes { pb in
                verifySysBundle(bb.baseAddress!, good.count, publicKey: pb.baseAddress!, minVersion: 0)
            }
        }
        check(isBadSignature(wrongKey), "verification under a wrong key must fail")

        if failures == 0 {
            print("PASS: SWSYS bundle core (sign/verify, anti-rollback floor, all rejection paths)")
        } else {
            print("FAILED: \(failures) check(s)")
            exit(1)
        }
    }

    // Small matchers (Embedded-free enum has no Equatable synthesis we rely on).
    static func isOK(_ r: SysBundleVerify) -> Bool { if case .ok = r { return true }; return false }
    static func isTooOld(_ r: SysBundleVerify) -> Bool { if case .tooOld = r { return true }; return false }
    static func isBadSize(_ r: SysBundleVerify) -> Bool { if case .badSize = r { return true }; return false }
    static func isBadSignature(_ r: SysBundleVerify) -> Bool { if case .badSignature = r { return true }; return false }
    static func isBadMagic(_ r: SysBundleVerify) -> Bool { if case .badMagic = r { return true }; return false }
    static func isBadFormatVersion(_ r: SysBundleVerify) -> Bool { if case .badFormatVersion = r { return true }; return false }
    static func isBadLayout(_ r: SysBundleVerify) -> Bool { if case .badLayout = r { return true }; return false }
    static func isBadPayloadSha(_ r: SysBundleVerify) -> Bool { if case .badPayloadSha = r { return true }; return false }
}

// SPDX-License-Identifier: Apache-2.0
// ImageResolver.swift — content-addressed signed-image verification for Cells (SC3).
//
// Before a Cell is created, slet must resolve the content-addressed image ref to a
// local read-only base and VERIFY it. SC3 reuses swift-os's existing image-trust
// primitives — `ed25519Verify` + `sha256` — rather than rolling a second signature
// scheme (the same Ed25519-over-a-digest model as SWSYS/SWOSBASE; see sysbundle.swift).
//
// Two checks, both required:
//   1. Content address — the staged bytes must hash (SHA-256) to `ref.digest`, so the
//      bytes are exactly what the ref names (integrity + on-disk dedup).
//   2. Authenticity — a detached Ed25519 signature over `ref.digest` must verify under
//      the trusted image-signing key, so only signed images run.
//
// SC3 assumes the base is ALREADY STAGED LOCALLY (pre-staged). The network pull /
// registry that fetches it is the explicit out-of-scope seam: `ImageStore.resolve`
// returns `nil` when the digest is not present locally, and the reconciler reflects
// that as a status the scheduler/registry layer (later) can act on. Foundation-free.

/// A local read-only base store: maps a content-addressed digest to the staged bytes.
/// Returns nil if the image is not present locally — the network-pull seam (SC3 does
/// not fetch). Class-bound for a single existential under Embedded Swift.
protocol ImageStore: AnyObject {
    func resolve(digest: [UInt8]) -> [UInt8]?
}

/// The outcome of verifying an `ImageRef` against a local store. A specific reason so
/// the reconciler can reflect it in the Cell status message.
enum ImageVerifyResult: Equatable {
    case ok                // staged, content-addressed, signed → safe to launch
    case notStaged         // not present locally (network-pull seam, SC3 out of scope)
    case digestMismatch    // staged bytes do not hash to the ref digest
    case badSignature      // signature does not verify under the trusted key

    var ok: Bool { self == .ok }
}

/// Verifies content-addressed signed image refs. Holds the trusted 32-byte Ed25519
/// image-signing public key (baked, like swift-os's `IMG_SIGNING_PUB`). Pure: the only
/// allocation is a 32-byte stack digest.
struct ImageVerifier {
    let trustedKey: [UInt8]    // 32-byte Ed25519 public key

    init(trustedKey: [UInt8]) { self.trustedKey = trustedKey }

    func verify(_ ref: ImageRef, store: ImageStore) -> ImageVerifyResult {
        if ref.digest.count != 32 || ref.signature.count != 64 || trustedKey.count != 32 {
            return .badSignature
        }
        guard let bytes = store.resolve(digest: ref.digest) else { return .notStaged }

        // 1. Content address: SHA-256(bytes) must equal the ref digest.
        var got = [UInt8](repeating: 0, count: 32)
        if bytes.isEmpty {
            // SHA-256 of the empty string, computed over a valid (zero-length) buffer.
            var dummy: UInt8 = 0
            withUnsafePointer(to: &dummy) { p in
                got.withUnsafeMutableBytes { d in sha256(p, 0, d.baseAddress!) }
            }
        } else {
            bytes.withUnsafeBytes { bp in
                got.withUnsafeMutableBytes { d in sha256(bp.baseAddress!, bytes.count, d.baseAddress!) }
            }
        }
        if got != ref.digest { return .digestMismatch }

        // 2. Authenticity: Ed25519 over the digest under the trusted key.
        let valid = ref.digest.withUnsafeBytes { mp in
            ref.signature.withUnsafeBytes { sp in
                trustedKey.withUnsafeBytes { kp in
                    ed25519Verify(message: mp.baseAddress!, 32,
                                  signature: sp.baseAddress!, publicKey: kp.baseAddress!)
                }
            }
        }
        return valid ? .ok : .badSignature
    }
}

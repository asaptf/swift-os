// SPDX-License-Identifier: Apache-2.0
// Schema.swift — SwiftCube cubestore key schema + clock/random seams (SC2).
//
// The control plane stores everything as desired/observed state in cubestore
// (etcd-style). SC2 introduces three object families, each under an ordered key
// prefix so a watcher can subscribe by prefix exactly as SC0/SC1 do:
//
//   /nodes/<id>    — a registered worker node (NodeRecord)
//   /leases/<id>   — a node's TTL liveness lease (LeaseRecord); renewed by
//                    heartbeat, reaped on expiry, taking its attached keys with it
//   /tokens/<id>   — a hashed bootstrap token (TokenRecord); a bearer secret with
//                    a TTL + limited uses + revocation, spent on a successful join
//
// Times are whole seconds from an injected clock (deterministic in host tests,
// the wall clock on-device). Randomness is an injected fill closure (a seeded
// PRNG in tests, swiftos_random on-device) — kept as closures, not protocols, so
// the control plane monomorphizes with no existential boxing under Embedded Swift.

// MARK: - Key prefixes / builders

enum CubeKeys {
    static let nodesPrefix: Bytes  = Array("/nodes/".utf8)
    static let leasesPrefix: Bytes = Array("/leases/".utf8)
    static let tokensPrefix: Bytes = Array("/tokens/".utf8)

    static func node(_ id: String) -> Bytes  { nodesPrefix + Array(id.utf8) }
    static func lease(_ id: String) -> Bytes  { leasesPrefix + Array(id.utf8) }
    static func token(_ id: String) -> Bytes  { tokensPrefix + Array(id.utf8) }

    /// The id suffix of a key under `prefix`, or nil if it is not in that range.
    static func suffix(_ key: Bytes, under prefix: Bytes) -> String? {
        guard key.count >= prefix.count else { return nil }
        for i in 0..<prefix.count where key[i] != prefix[i] { return nil }
        return String(decoding: key[prefix.count...], as: UTF8.self)
    }
}

// MARK: - Clock seam

/// A monotonic-enough clock in whole seconds. The control plane never reads a
/// real clock directly — it asks this seam, so host tests advance time by hand.
protocol CubeClock: AnyObject {
    func nowSeconds() -> UInt64
}

/// A test clock advanced explicitly; deterministic lease/TTL behavior.
final class ManualClock: CubeClock {
    private var t: UInt64
    init(_ start: UInt64) { t = start }
    func nowSeconds() -> UInt64 { t }
    func advance(_ secs: UInt64) { t &+= secs }
    func set(_ secs: UInt64) { t = secs }
}

// MARK: - Hex helpers (token ids/secrets are exchanged as hex; no Foundation)

enum Hex {
    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0x0F)]) }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ s: String) -> [UInt8]? {
        let cs = Array(s.utf8)
        if cs.count % 2 != 0 { return nil }
        func v(_ c: UInt8) -> Int? {
            if c >= 0x30 && c <= 0x39 { return Int(c - 0x30) }
            if c >= 0x61 && c <= 0x66 { return Int(c - 0x61 + 10) }
            if c >= 0x41 && c <= 0x46 { return Int(c - 0x41 + 10) }
            return nil
        }
        var out = [UInt8](); out.reserveCapacity(cs.count / 2)
        var i = 0
        while i < cs.count {
            guard let hi = v(cs[i]), let lo = v(cs[i + 1]) else { return nil }
            out.append(UInt8(hi << 4 | lo)); i += 2
        }
        return out
    }
}

/// Constant-time equality for secret/hash comparison.
func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    if a.count != b.count { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}

/// SHA-256 over a byte array → 32-byte array (small wrapper over the crypto module).
func sha256Bytes(_ data: [UInt8]) -> [UInt8] {
    var h = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { dp in
        h.withUnsafeMutableBytes { hp in sha256(dp.baseAddress!, data.count, hp.baseAddress!) }
    }
    return h
}

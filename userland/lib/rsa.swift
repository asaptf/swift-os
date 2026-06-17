// SPDX-License-Identifier: Apache-2.0
//
// rsa.swift — RSA PKCS#1 v1.5 signature *verification* (SHA-256) for X.509
// chain validation. Let's Encrypt's default chain is RSA (ISRG Root X1 →
// R10/R11 → leaf), so authenticating a real LE server needs an RSA public-key
// verify; the ECDSA leaf signature reuses kernel/crypto/p256.swift.
//
// Self-contained and Embedded-compatible: a variable-width big integer as
// little-endian UInt32 limbs with Separated-Operand-Scanning Montgomery
// multiplication (the same shape as p256.swift, generalized to k limbs), used
// only for the public modular exponentiation s^e mod n. Verification is not a
// secret-dependent path, so it need not be constant-time. Pinned by
// tests/rsa_test.swift to an openssl-produced RSA-2048 signature.

private func rsaInv32(_ x: UInt32) -> UInt32 {
    var y = x
    for _ in 0..<5 { y = y &* (2 &- x &* y) }
    return y
}

/// Unsigned compare of two equal-length limb arrays: -1, 0, 1.
private func cmpK(_ a: [UInt32], _ b: [UInt32]) -> Int {
    var i = a.count - 1
    while i >= 0 { if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }; i -= 1 }
    return 0
}

private func subK(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
    var o = [UInt32](repeating: 0, count: a.count)
    var borrow: UInt64 = 0
    for i in 0..<a.count {
        let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
        o[i] = UInt32(truncatingIfNeeded: d)
        borrow = (d >> 63) & 1
    }
    return o
}

/// (a + b) mod m for a, b < m.
private func addModK(_ a: [UInt32], _ b: [UInt32], _ m: [UInt32]) -> [UInt32] {
    let k = m.count
    var o = [UInt32](repeating: 0, count: k)
    var c: UInt64 = 0
    for i in 0..<k {
        let s = UInt64(a[i]) + UInt64(b[i]) + c
        o[i] = UInt32(truncatingIfNeeded: s)
        c = s >> 32
    }
    if c != 0 || cmpK(o, m) >= 0 { return subK(o, m) }
    return o
}

/// Montgomery multiplication (SOS): a * b * R^{-1} mod m, with R = 2^(32k).
private func montMulK(_ a: [UInt32], _ b: [UInt32], _ m: [UInt32], _ n0: UInt32) -> [UInt32] {
    let k = m.count
    var t = [UInt32](repeating: 0, count: 2 * k + 1)
    for i in 0..<k {
        var carry: UInt64 = 0
        for j in 0..<k {
            let p = UInt64(a[i]) * UInt64(b[j]) + UInt64(t[i + j]) + carry
            t[i + j] = UInt32(truncatingIfNeeded: p)
            carry = p >> 32
        }
        t[i + k] = UInt32(truncatingIfNeeded: UInt64(t[i + k]) + carry)
    }
    for i in 0..<k {
        let mi = t[i] &* n0
        var carry: UInt64 = 0
        for j in 0..<k {
            let p = UInt64(mi) * UInt64(m[j]) + UInt64(t[i + j]) + carry
            t[i + j] = UInt32(truncatingIfNeeded: p)
            carry = p >> 32
        }
        var idx = i + k
        while carry != 0 {
            let p = UInt64(t[idx]) + carry
            t[idx] = UInt32(truncatingIfNeeded: p)
            carry = p >> 32
            idx += 1
        }
    }
    var res = [UInt32](repeating: 0, count: k)
    for i in 0..<k { res[i] = t[i + k] }
    if t[2 * k] != 0 || cmpK(res, m) >= 0 { return subK(res, m) }
    return res
}

private func bytesToLimbsBE(_ be: [UInt8], _ k: Int) -> [UInt32] {
    var l = [UInt32](repeating: 0, count: k)
    var bytePos = be.count - 1
    var limb = 0, shift: UInt32 = 0
    while bytePos >= 0 && limb < k {
        l[limb] |= UInt32(be[bytePos]) << shift
        shift += 8
        if shift == 32 { shift = 0; limb += 1 }
        bytePos -= 1
    }
    return l
}

private func limbsToBytesBE(_ l: [UInt32], _ nBytes: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: nBytes)
    for i in 0..<nBytes {
        let limb = i / 4
        let bitsh = UInt32((i % 4) * 8)
        let v: UInt8 = limb < l.count ? UInt8(truncatingIfNeeded: l[limb] >> bitsh) : 0
        out[nBytes - 1 - i] = v
    }
    return out
}

/// s^e mod n, all big-endian byte strings; result is `nBytes` big-endian.
private func rsaModExp(_ baseBE: [UInt8], _ expBE: [UInt8], _ modBE: [UInt8]) -> [UInt8] {
    let nBytes = modBE.count
    let k = (nBytes + 3) / 4
    let m = bytesToLimbsBE(modBE, k)
    let base = bytesToLimbsBE(baseBE, k)
    let exp = bytesToLimbsBE(expBE, (expBE.count + 3) / 4)
    let n0 = 0 &- rsaInv32(m[0])

    var one = [UInt32](repeating: 0, count: k); one[0] = 1
    var r2 = one                                  // R^2 mod m = 2^(2*32*k) mod m
    for _ in 0..<(2 * 32 * k) { r2 = addModK(r2, r2, m) }
    let oneMont = montMulK(one, r2, m, n0)        // R mod m
    let baseMont = montMulK(base, r2, m, n0)

    var result = oneMont
    var bit = exp.count * 32 - 1
    while bit >= 0 {
        result = montMulK(result, result, m, n0)
        if (exp[bit >> 5] >> UInt32(bit & 31)) & 1 == 1 {
            result = montMulK(result, baseMont, m, n0)
        }
        bit -= 1
    }
    let r = montMulK(result, one, m, n0)          // out of Montgomery form
    return limbsToBytesBE(r, nBytes)
}

// SHA-256 DigestInfo prefix (RFC 8017 §9.2): the DER of the AlgorithmIdentifier
// and the OCTET STRING header that precede the 32-byte hash.
private let SHA256_DIGESTINFO: [UInt8] = [
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
]

/// Verify an RSASSA-PKCS1-v1_5 signature over SHA-256(message). `modulusBE` and
/// `exponentBE` are the public key (big-endian, no sign byte); `signatureBE` is
/// the signature (big-endian, modulus length).
func rsaVerifyPKCS1SHA256(modulusBE: [UInt8], exponentBE: [UInt8],
                          message: [UInt8], signatureBE: [UInt8]) -> Bool {
    let nBytes = modulusBE.count
    if nBytes < 62 || signatureBE.count > nBytes { return false }   // 3 + 51 + >=8 PS

    let em = rsaModExp(signatureBE, exponentBE, modulusBE)

    var h = [UInt8](repeating: 0, count: 32)
    message.withUnsafeBytes { mp in
        h.withUnsafeMutableBytes { hp in sha256(mp.baseAddress!, message.count, hp.baseAddress!) }
    }

    // Expected EM = 0x00 0x01 PS(0xFF…) 0x00 DigestInfo H
    var expected: [UInt8] = [0x00, 0x01]
    let psLen = nBytes - 3 - SHA256_DIGESTINFO.count - 32
    if psLen < 8 { return false }
    for _ in 0..<psLen { expected.append(0xFF) }
    expected.append(0x00)
    expected += SHA256_DIGESTINFO
    expected += h

    if em.count != expected.count { return false }
    var diff: UInt8 = 0
    for i in 0..<em.count { diff |= em[i] ^ expected[i] }
    return diff == 0
}

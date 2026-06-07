// crypto_test.swift — host unit test for kernel/crypto/chacha20poly1305.swift.
//
// Compiled with the host Swift toolchain against the same pure crypto module the
// kernel links (no MMIO/syscalls/heap-per-op), then run with no arguments. It
// asserts the implementation against the published RFC 8439 test vectors:
//   §2.4.2 ChaCha20 encryption, §2.5.2 Poly1305, §2.8.2 the AEAD seal/open.
// Mirrors tests/net_test.swift's style and its check(_:_:) helper.

import Foundation

@main
struct CryptoTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    /// Run `body` with raw pointers to fresh copies of the given byte arrays.
    static func withBufs(_ arrays: [[UInt8]],
                         _ body: ([UnsafeMutableRawPointer]) -> Void) {
        var bufs: [UnsafeMutableRawPointer] = []
        for a in arrays {
            let p = UnsafeMutableRawPointer.allocate(byteCount: max(1, a.count), alignment: 16)
            for i in 0..<a.count { p.storeBytes(of: a[i], toByteOffset: i, as: UInt8.self) }
            bufs.append(p)
        }
        body(bufs)
        for p in bufs { p.deallocate() }
    }

    static func bytesEqual(_ p: UnsafeRawPointer, _ expected: [UInt8]) -> Bool {
        for i in 0..<expected.count {
            if p.load(fromByteOffset: i, as: UInt8.self) != expected[i] { return false }
        }
        return true
    }

    static func main() {
        // ---- 1. ChaCha20 encryption — RFC 8439 §2.4.2 --------------------
        // key = 00 01 .. 1f, nonce = 00:00:00:00:00:00:00:4a:00:00:00:00,
        // initial counter = 1, the "Ladies and Gentlemen..." plaintext.
        let key2_4: [UInt8] = Array(0...31)
        let nonce2_4: [UInt8] = [0,0,0,0, 0,0,0,0x4a, 0,0,0,0]
        let plain2_4: [UInt8] = Array(
            "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let cipher2_4: [UInt8] = [
            0x6e,0x2e,0x35,0x9a,0x25,0x68,0xf9,0x80,0x41,0xba,0x07,0x28,0xdd,0x0d,0x69,0x81,
            0xe9,0x7e,0x7a,0xec,0x1d,0x43,0x60,0xc2,0x0a,0x27,0xaf,0xcc,0xfd,0x9f,0xae,0x0b,
            0xf9,0x1b,0x65,0xc5,0x52,0x47,0x33,0xab,0x8f,0x59,0x3d,0xab,0xcd,0x62,0xb3,0x57,
            0x16,0x39,0xd6,0x24,0xe6,0x51,0x52,0xab,0x8f,0x53,0x0c,0x35,0x9f,0x08,0x61,0xd8,
            0x07,0xca,0x0d,0xbf,0x50,0x0d,0x6a,0x61,0x56,0xa3,0x8e,0x08,0x8a,0x22,0xb6,0x5e,
            0x52,0xbc,0x51,0x4d,0x16,0xcc,0xf8,0x06,0x81,0x8c,0xe9,0x1a,0xb7,0x79,0x37,0x36,
            0x5a,0xf9,0x0b,0xbf,0x74,0xa3,0x5b,0xe6,0xb4,0x0b,0x8e,0xed,0xf2,0x78,0x5e,0x42,
            0x87,0x4d]
        withBufs([key2_4, nonce2_4, plain2_4, Array(repeating: 0, count: plain2_4.count)]) { b in
            chacha20Encrypt(key: b[0], counter: 1, nonce: b[1],
                            input: b[2], output: b[3], len: plain2_4.count)
            check(bytesEqual(b[3], cipher2_4), "ChaCha20 §2.4.2 ciphertext")
            // The cipher is symmetric: re-encrypting the ciphertext recovers plaintext.
            chacha20Encrypt(key: b[0], counter: 1, nonce: b[1],
                            input: b[3], output: b[3], len: plain2_4.count)
            check(bytesEqual(b[3], plain2_4), "ChaCha20 §2.4.2 round-trips")
        }

        // ---- 2. Poly1305 — RFC 8439 §2.5.2 -------------------------------
        let polyKey: [UInt8] = [
            0x85,0xd6,0xbe,0x78,0x57,0x55,0x6d,0x33,0x7f,0x44,0x52,0xfe,0x42,0xd5,0x06,0xa8,
            0x01,0x03,0x80,0x8a,0xfb,0x0d,0xb2,0xfd,0x4a,0xbf,0xf6,0xaf,0x41,0x49,0xf5,0x1b]
        let polyMsg: [UInt8] = Array("Cryptographic Forum Research Group".utf8)
        let polyTag: [UInt8] = [
            0xa8,0x06,0x1d,0xc1,0x30,0x51,0x36,0xc6,0xc2,0x2b,0x8b,0xaf,0x0c,0x01,0x27,0xa9]
        withBufs([polyKey, polyMsg, Array(repeating: 0, count: 16)]) { b in
            poly1305Mac(key: b[0], msg: b[1], len: polyMsg.count, tagOut: b[2])
            check(bytesEqual(b[2], polyTag), "Poly1305 §2.5.2 tag")
        }

        // ---- 3. AEAD_CHACHA20_POLY1305 — RFC 8439 §2.8.2 -----------------
        let aeadKey: [UInt8] = Array(0x80...0x9f)
        let aeadNonce: [UInt8] = [0x07,0x00,0x00,0x00, 0x40,0x41,0x42,0x43,0x44,0x45,0x46,0x47]
        let aeadAad: [UInt8] = [0x50,0x51,0x52,0x53, 0xc0,0xc1,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7]
        let aeadPlain: [UInt8] = Array(
            "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let aeadCipher: [UInt8] = [
            0xd3,0x1a,0x8d,0x34,0x64,0x8e,0x60,0xdb,0x7b,0x86,0xaf,0xbc,0x53,0xef,0x7e,0xc2,
            0xa4,0xad,0xed,0x51,0x29,0x6e,0x08,0xfe,0xa9,0xe2,0xb5,0xa7,0x36,0xee,0x62,0xd6,
            0x3d,0xbe,0xa4,0x5e,0x8c,0xa9,0x67,0x12,0x82,0xfa,0xfb,0x69,0xda,0x92,0x72,0x8b,
            0x1a,0x71,0xde,0x0a,0x9e,0x06,0x0b,0x29,0x05,0xd6,0xa5,0xb6,0x7e,0xcd,0x3b,0x36,
            0x92,0xdd,0xbd,0x7f,0x2d,0x77,0x8b,0x8c,0x98,0x03,0xae,0xe3,0x28,0x09,0x1b,0x58,
            0xfa,0xb3,0x24,0xe4,0xfa,0xd6,0x75,0x94,0x55,0x85,0x80,0x8b,0x48,0x31,0xd7,0xbc,
            0x3f,0xf4,0xde,0xf0,0x8e,0x4b,0x7a,0x9d,0xe5,0x76,0xd2,0x65,0x86,0xce,0xc6,0x4b,
            0x61,0x16]
        let aeadTagVec: [UInt8] = [
            0x1a,0xe1,0x0b,0x59,0x4f,0x09,0xe2,0x6a,0x7e,0x90,0x2e,0xcb,0xd0,0x60,0x06,0x91]
        // scratch must hold aad+pad ‖ ct+pad ‖ 16, generously sized here.
        let scratchLen = aeadAad.count + aeadPlain.count + 64
        withBufs([aeadKey, aeadNonce, aeadAad, aeadPlain,
                  Array(repeating: 0, count: aeadPlain.count),     // ciphertext out
                  Array(repeating: 0, count: 16),                  // tag out
                  Array(repeating: 0, count: scratchLen),          // scratch
                  Array(repeating: 0, count: aeadPlain.count)]) { b in
            aeadSeal(key: b[0], nonce: b[1], aad: b[2], aadLen: aeadAad.count,
                     plaintext: b[3], ptLen: aeadPlain.count,
                     ciphertext: b[4], tagOut: b[5], scratch: b[6])
            check(bytesEqual(b[4], aeadCipher), "AEAD §2.8.2 ciphertext")
            check(bytesEqual(b[5], aeadTagVec), "AEAD §2.8.2 tag")

            // aeadOpen accepts the valid tag and recovers the plaintext.
            let okGood = aeadOpen(key: b[0], nonce: b[1], aad: b[2], aadLen: aeadAad.count,
                                  ciphertext: b[4], ctLen: aeadPlain.count, tag: b[5],
                                  plaintext: b[7], scratch: b[6])
            check(okGood, "AEAD §2.8.2 open accepts the valid tag")
            check(bytesEqual(b[7], aeadPlain), "AEAD §2.8.2 open recovers plaintext")

            // Corrupt one tag byte: aeadOpen must reject.
            let badByte = b[5].load(fromByteOffset: 0, as: UInt8.self) ^ 0x01
            b[5].storeBytes(of: badByte, toByteOffset: 0, as: UInt8.self)
            let okBad = aeadOpen(key: b[0], nonce: b[1], aad: b[2], aadLen: aeadAad.count,
                                 ciphertext: b[4], ctLen: aeadPlain.count, tag: b[5],
                                 plaintext: b[7], scratch: b[6])
            check(!okBad, "AEAD open rejects a corrupted tag")
        }

        if failed {
            FileHandle.standardError.write(Data("crypto_test: FAILURES\n".utf8))
            exit(1)
        }
        print("crypto_test: PASS (RFC 8439 ChaCha20 / Poly1305 / AEAD vectors)")
    }
}

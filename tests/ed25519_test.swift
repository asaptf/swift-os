// SPDX-License-Identifier: Apache-2.0
//
// ed25519_test.swift — host unit test for kernel/crypto/{sha512,ed25519}.swift.
//
// Compiled with the host Swift toolchain against the same pure sources the
// signing tool and /bin/llmd link. Pins:
//   - SHA-512 to the FIPS 180-4 vectors ("", "abc", and the standard
//     two-block 112-byte message), digests cross-checked with python3 hashlib;
//   - Ed25519 to RFC 8032 §7.1 TEST 1, TEST 2, TEST 3, and TEST SHA(abc):
//     public-key derivation, deterministic signatures byte-for-byte, and
//     verification — plus tampered-signature / tampered-message / wrong-key
//     rejection. Mirrors tests/x25519_test.swift in style.

import Foundation

@main
struct Ed25519Test {
    static var failed = false

    static func check(_ cond: Bool, _ msg: String) {
        if !cond {
            FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
            failed = true
        }
    }

    static func unhex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var iter = s.makeIterator()
        while let a = iter.next(), let b = iter.next() {
            out.append(UInt8(String([a, b]), radix: 16)!)
        }
        return out
    }

    static func hex(_ b: [UInt8]) -> String {
        return b.map { String(format: "%02x", $0) }.joined()
    }

    static func sha512Hex(_ msg: [UInt8]) -> String {
        var out = [UInt8](repeating: 0, count: 64)
        msg.withUnsafeBytes { mb in
            out.withUnsafeMutableBytes { ob in
                sha512(mb.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, msg.count, ob.baseAddress!)
            }
        }
        return hex(out)
    }

    struct Vector {
        let name: String
        let seed: String
        let pub: String
        let msg: String
        let sig: String
    }

    // RFC 8032 §7.1 (fetched from rfc-editor.org, not transcribed from memory).
    static let vectors: [Vector] = [
        Vector(name: "TEST1",
               seed: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
               pub: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
               msg: "",
               sig: "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
        Vector(name: "TEST2",
               seed: "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
               pub: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
               msg: "72",
               sig: "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        Vector(name: "TEST3",
               seed: "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
               pub: "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
               msg: "af82",
               sig: "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
        Vector(name: "TEST-SHA(abc)",
               seed: "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
               pub: "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
               msg: "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
               sig: "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704"),
    ]

    static func main() {
        // --- SHA-512 (FIPS 180-4; digests cross-checked with python3) ---
        check(sha512Hex([]) ==
              "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
              "SHA-512(empty) wrong")
        check(sha512Hex(Array("abc".utf8)) ==
              "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
              "SHA-512(abc) wrong")
        check(sha512Hex(Array("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".utf8)) ==
              "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909",
              "SHA-512(two-block) wrong")

        // --- Ed25519 RFC 8032 vectors ---
        for v in vectors {
            let seed = unhex(v.seed)
            let msg = unhex(v.msg)
            var pub = [UInt8](repeating: 0, count: 32)
            seed.withUnsafeBytes { sb in
                pub.withUnsafeMutableBytes { pb in
                    ed25519PublicKey(seed: sb.baseAddress!, publicKey: pb.baseAddress!)
                }
            }
            check(hex(pub) == v.pub, "\(v.name): public key mismatch (got \(hex(pub)))")

            var sig = [UInt8](repeating: 0, count: 64)
            msg.withUnsafeBytes { mb in
                seed.withUnsafeBytes { sb in
                    sig.withUnsafeMutableBytes { gb in
                        ed25519Sign(message: mb.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                                    msg.count, seed: sb.baseAddress!,
                                    signature: gb.baseAddress!)
                    }
                }
            }
            check(hex(sig) == v.sig, "\(v.name): signature mismatch (got \(hex(sig)))")

            func verifies(_ m: [UInt8], _ s: [UInt8], _ p: [UInt8]) -> Bool {
                return m.withUnsafeBytes { mb in
                    s.withUnsafeBytes { sb in
                        p.withUnsafeBytes { pb in
                            ed25519Verify(message: mb.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                                          m.count, signature: sb.baseAddress!,
                                          publicKey: pb.baseAddress!)
                        }
                    }
                }
            }
            check(verifies(msg, sig, pub), "\(v.name): genuine signature did not verify")

            var badSig = sig; badSig[0] ^= 1
            check(!verifies(msg, badSig, pub), "\(v.name): tampered signature (R) accepted")
            var badSig2 = sig; badSig2[63] ^= 0x20
            check(!verifies(msg, badSig2, pub), "\(v.name): tampered signature (S) accepted")
            if !msg.isEmpty {
                var badMsg = msg; badMsg[0] ^= 1
                check(!verifies(badMsg, sig, pub), "\(v.name): tampered message accepted")
            } else {
                check(!verifies([0x00], sig, pub), "\(v.name): different message accepted")
            }
        }

        // Wrong key: TEST2's signature must not verify under TEST1's key.
        let s2 = unhex(vectors[1].sig), m2 = unhex(vectors[1].msg), p1 = unhex(vectors[0].pub)
        let cross = m2.withUnsafeBytes { mb in
            s2.withUnsafeBytes { sb in
                p1.withUnsafeBytes { pb in
                    ed25519Verify(message: mb.baseAddress!, m2.count,
                                  signature: sb.baseAddress!, publicKey: pb.baseAddress!)
                }
            }
        }
        check(!cross, "cross-key verification accepted")

        if failed {
            FileHandle.standardError.write(Data("ed25519_test: FAILURES\n".utf8))
            exit(1)
        }
        print("ed25519_test: PASS (SHA-512 FIPS vectors + RFC 8032 §7.1 sign/verify + tamper rejection)")
    }
}

// tls_handshake_test.swift — host unit test for userland/lib/tls13.swift.
//
// Compiled with the host Swift toolchain against the same pure sources the
// /bin/tlsget ELF links (tls13.swift + kernel/crypto/{sha256,x25519,
// chacha20poly1305}.swift), then run with no arguments. It checks, against
// RFC 8448 §3 "Simple 1-RTT Handshake" vectors where the value is AEAD-agnostic:
//   - HKDF-Expand-Label key/iv/finished derivation (the §7.1 schedule),
//   - the early/derived/handshake-secret chain,
// and exercises the real record layer (tlsRecordSeal / tlsRecordOpen) with a
// seal→open round-trip plus a tampering-rejection check. (The AEAD itself is
// vector-tested in tests/crypto_test.swift; RFC 8448 uses AES-128-GCM, not
// ChaCha20-Poly1305, so the record KAT here is self-consistent on our suite.)
// Mirrors tests/hkdf_test.swift / tests/x25519_test.swift in style.

import Foundation

@main
struct TLSHandshakeTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    static func hex(_ s: String) -> [UInt8] {
        let c = Array(s.utf8)
        var out = [UInt8]()
        var i = 0
        func nib(_ b: UInt8) -> UInt8 {
            if b >= 0x30 && b <= 0x39 { return b - 0x30 }
            if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
            return b - 0x41 + 10
        }
        while i + 1 < c.count { out.append((nib(c[i]) << 4) | nib(c[i + 1])); i += 2 }
        return out
    }

    static func toHex(_ b: [UInt8]) -> String {
        var s = ""
        for x in b {
            let hi = x >> 4, lo = x & 0xF
            s.append(Character(UnicodeScalar(hi < 10 ? 0x30 + hi : 0x61 + hi - 10)))
            s.append(Character(UnicodeScalar(lo < 10 ? 0x30 + lo : 0x61 + lo - 10)))
        }
        return s
    }

    /// HKDF-Expand-Label(secret, label, "", outLen) — empty context.
    static func el(_ secret: [UInt8], _ label: String, _ outLen: Int) -> [UInt8] {
        let lab = Array(label.utf8)
        var out = [UInt8](repeating: 0, count: outLen)
        secret.withUnsafeBytes { s in
            lab.withUnsafeBytes { l in
                out.withUnsafeMutableBytes { o in
                    hkdfExpandLabel(secret: s.baseAddress!, label: l.baseAddress!, labelLen: lab.count,
                                    context: l.baseAddress!, contextLen: 0,
                                    out: o.baseAddress!, outLen: outLen)
                }
            }
        }
        return out
    }

    /// HKDF-Extract(salt, ikm) -> 32 bytes.
    static func extract(_ salt: [UInt8], _ ikm: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { s in
            ikm.withUnsafeBytes { k in
                out.withUnsafeMutableBytes { o in
                    hkdfExtract(salt: s.baseAddress!, saltLen: salt.count,
                                ikm: k.baseAddress!, ikmLen: ikm.count, prkOut: o.baseAddress!)
                }
            }
        }
        return out
    }

    /// Derive-Secret(secret, label, emptyTranscript) — context = Hash("").
    static func deriveEmpty(_ secret: [UInt8], _ label: String) -> [UInt8] {
        var emptyHash = [UInt8](repeating: 0, count: 32)
        emptyHash.withUnsafeMutableBytes { sha256($0.baseAddress!, 0, $0.baseAddress!) }
        let lab = Array(label.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        secret.withUnsafeBytes { s in
            lab.withUnsafeBytes { l in
                emptyHash.withUnsafeBytes { eh in
                    out.withUnsafeMutableBytes { o in
                        hkdfExpandLabel(secret: s.baseAddress!, label: l.baseAddress!, labelLen: lab.count,
                                        context: eh.baseAddress!, contextLen: 32,
                                        out: o.baseAddress!, outLen: 32)
                    }
                }
            }
        }
        return out
    }

    static func main() {
        let zeros = [UInt8](repeating: 0, count: 32)

        // ---- 1. RFC 8448 §3 early / derived / handshake-secret chain -------
        let early = extract(zeros, zeros)
        check(early == hex("33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a"),
              "RFC 8448 early_secret (got \(toHex(early)))")
        let derived = deriveEmpty(early, "derived")
        check(derived == hex("6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba"),
              "RFC 8448 derived secret (got \(toHex(derived)))")
        // ECDHE from RFC 8448 §3.
        let ecdhe = hex("8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d")
        let hs = extract(derived, ecdhe)
        check(hs == hex("1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac"),
              "RFC 8448 handshake_secret (got \(toHex(hs)))")

        // ---- 2. RFC 8448 §3 key/iv/finished via HKDF-Expand-Label ----------
        // Documented server/client handshake traffic secrets (their derivation
        // needs the exact CH..SH transcript hash, which RFC 8448 fixes; we take
        // the published secrets as inputs and verify the Expand-Label step).
        let sHs = hex("b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38")
        let cHs = hex("b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21")
        check(el(sHs, "key", 16) == hex("3fce516009c21727d0f2e4e86ee403bc"),
              "RFC 8448 server_write_key")
        check(el(sHs, "iv", 12) == hex("5d313eb2671276ee13000b30"),
              "RFC 8448 server_write_iv")
        check(el(cHs, "key", 16) == hex("dbfaa693d1762c5b666af5d950258d01"),
              "RFC 8448 client_write_key")
        check(el(cHs, "iv", 12) == hex("5bd3c71b836e0b76bb73265f"),
              "RFC 8448 client_write_iv")
        check(el(sHs, "finished", 32) ==
              hex("008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8"),
              "RFC 8448 server finished_key")

        // ---- 3. Per-record nonce (RFC 8446 §5.3) ---------------------------
        let iv = hex("5d313eb2671276ee13000b30")
        var nonce = [UInt8](repeating: 0, count: 12)
        iv.withUnsafeBytes { ivp in
            nonce.withUnsafeMutableBytes { tlsRecordNonce(iv: ivp.baseAddress!, seq: 0, out: $0.baseAddress!) }
        }
        check(nonce == iv, "record nonce seq=0 equals iv")
        iv.withUnsafeBytes { ivp in
            nonce.withUnsafeMutableBytes { tlsRecordNonce(iv: ivp.baseAddress!, seq: 1, out: $0.baseAddress!) }
        }
        check(nonce == hex("5d313eb2671276ee13000b31"), "record nonce seq=1 (got \(toHex(nonce)))")

        // ---- 4. Record layer round-trip (real seal/open) -------------------
        // Seal application data with the server key/iv at seq 0, then open with
        // the same parameters; the recovered plaintext + content type must match.
        let key = el(sHs, "key", 16) + [UInt8](repeating: 0, count: 16)   // pad to 32-byte ChaCha key
        let recIV = el(sHs, "iv", 12)
        let msg = Array("GET / HTTP/1.0\r\n\r\n".utf8)
        var sealed = [UInt8]()
        key.withUnsafeBytes { kp in
            recIV.withUnsafeBytes { ivp in
                msg.withUnsafeBytes { mp in
                    tlsRecordSeal(key: kp.baseAddress!, iv: ivp.baseAddress!, seq: 0,
                                  contentType: 23, plaintext: mp.baseAddress!, plen: msg.count,
                                  out: &sealed)
                }
            }
        }
        // Wire record = header(5) + ciphertext(msg.count + 1) + tag(16).
        check(sealed.count == 5 + msg.count + 1 + 16, "sealed record length")
        check(sealed[0] == 23 && sealed[1] == 0x03 && sealed[2] == 0x03, "sealed outer header is app-data/0303")
        // Open the body (everything after the 5-byte header).
        let body = Array(sealed[5...])
        var outBuf = [UInt8](repeating: 0, count: body.count)
        var outLen = 0
        let innerType: UInt8? = key.withUnsafeBytes { kp in
            recIV.withUnsafeBytes { ivp in
                body.withUnsafeBytes { bp in
                    outBuf.withUnsafeMutableBytes { op in
                        tlsRecordOpen(key: kp.baseAddress!, iv: ivp.baseAddress!, seq: 0,
                                      body: bp.baseAddress!, bodyLen: body.count,
                                      out: op.baseAddress!, outLen: &outLen)
                    }
                }
            }
        }
        check(innerType == 23, "opened record inner content type == application_data")
        check(outLen == msg.count && Array(outBuf[0..<outLen]) == msg,
              "opened record plaintext round-trips")

        // ---- 5. Tampering is rejected --------------------------------------
        var tampered = body
        tampered[0] ^= 0x01                        // flip one ciphertext bit
        var junk = [UInt8](repeating: 0, count: tampered.count)
        var junkLen = 0
        let badType: UInt8? = key.withUnsafeBytes { kp in
            recIV.withUnsafeBytes { ivp in
                tampered.withUnsafeBytes { bp in
                    junk.withUnsafeMutableBytes { op in
                        tlsRecordOpen(key: kp.baseAddress!, iv: ivp.baseAddress!, seq: 0,
                                      body: bp.baseAddress!, bodyLen: tampered.count,
                                      out: op.baseAddress!, outLen: &junkLen)
                    }
                }
            }
        }
        check(badType == nil, "tampered record fails authentication")

        // ---- 6. Wrong sequence number is rejected --------------------------
        let wrongSeq: UInt8? = key.withUnsafeBytes { kp in
            recIV.withUnsafeBytes { ivp in
                body.withUnsafeBytes { bp in
                    junk.withUnsafeMutableBytes { op in
                        tlsRecordOpen(key: kp.baseAddress!, iv: ivp.baseAddress!, seq: 1,
                                      body: bp.baseAddress!, bodyLen: body.count,
                                      out: op.baseAddress!, outLen: &junkLen)
                    }
                }
            }
        }
        check(wrongSeq == nil, "record opened at the wrong sequence number fails")

        if failed {
            FileHandle.standardError.write(Data("tls_handshake_test: FAILURES\n".utf8))
            exit(1)
        }
        print("tls_handshake_test: PASS (RFC 8448 key schedule + record seal/open round-trip)")
    }
}

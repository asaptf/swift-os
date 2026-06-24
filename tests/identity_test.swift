// SPDX-License-Identifier: Apache-2.0
// identity_test.swift — host unit test for userland/lib/swos_identity.swift.
//
// Compiled with the host Swift toolchain against the same pure modules a userland
// ELF links (kernel/crypto/sha256.swift + swos_identity.swift), then run with no
// arguments. Mirrors tests/hkdf_test.swift's style and its check(_:_:) helper.
//
// Coverage:
//   1. PBKDF2-HMAC-SHA256 against published vectors (RFC 8018 PRF, dkLen 32 & 40).
//   2. Password-field codec: pbkdf2 build/verify roundtrip + legacy salt$sha256hex.
//   3. Bank serialization: write/parse roundtrip, checksum tamper detection, bounds.
//   4. Dual-bank selection: highest valid generation wins; torn banks ignored.
//   5. The resolve POLICY across every crash/rollback permutation — this is the
//      security core: a committed non-default password is never reverted to the
//      base default by a crash, and a provisioned-but-corrupt overlay fails closed.

import Foundation

@main
struct IdentityTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    // ---- pointer plumbing (buffers live for the whole test; process exits) ----

    static func pin(_ a: [UInt8]) -> UnsafeMutableRawPointer {
        let p = UnsafeMutableRawPointer.allocate(byteCount: max(1, a.count), alignment: 16)
        for i in 0..<a.count { p.storeBytes(of: a[i], toByteOffset: i, as: UInt8.self) }
        return p
    }
    static func pinOpt(_ a: [UInt8]?) -> UnsafeRawPointer? {
        guard let a = a else { return nil }
        return UnsafeRawPointer(pin(a))
    }
    static func grab(_ p: UnsafeRawPointer, _ n: Int) -> [UInt8] {
        var r = [UInt8]()
        for i in 0..<n { r.append(p.load(fromByteOffset: i, as: UInt8.self)) }
        return r
    }
    static func hex(_ s: String) -> [UInt8] {
        let c = Array(s.utf8); var out = [UInt8](); var i = 0
        func nib(_ b: UInt8) -> UInt8 {
            if b >= 0x30 && b <= 0x39 { return b - 0x30 }
            if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
            return b - 0x41 + 10
        }
        while i + 1 < c.count { out.append((nib(c[i]) << 4) | nib(c[i + 1])); i += 2 }
        return out
    }

    // ---- crypto helpers ----

    static func pbkdf2(_ pw: String, _ salt: String, _ iters: Int, _ dk: Int) -> [UInt8] {
        let pwp = pin(Array(pw.utf8)), sp = pin(Array(salt.utf8))
        let out = UnsafeMutableRawPointer.allocate(byteCount: dk, alignment: 16)
        pbkdf2HmacSha256(pwp, pw.utf8.count, sp, salt.utf8.count, iters, out, dk)
        return grab(out, dk)
    }
    static func sha256hex(_ s: String) -> [UInt8] {
        let sp = pin(Array(s.utf8))
        let out = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        sha256Hex(sp, s.utf8.count, out)
        return grab(out, 64)
    }
    static func verify(_ field: [UInt8], _ pass: String) -> Bool {
        let fp = pin(field), pp = pin(Array(pass.utf8))
        return identityVerifyField(fp, field.count, pp, pass.utf8.count)
    }

    // ---- passwd-line / bank construction ----

    static let testSalt: [UInt8] = Array("0123456789abcdef".utf8)  // 16-byte salt

    static func buildField(_ password: String, _ iters: Int) -> [UInt8] {
        let pw = Array(password.utf8)
        let pwp = pin(pw), sp = pin(testSalt)
        let cap = 256
        let out = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        let n = identityBuildPbkdf2Field(pwp, pw.count, sp, testSalt.count, iters, out, cap)
        check(n > 0, "buildField produced a field")
        return grab(out, max(0, n))
    }

    static func line(_ name: String, _ pr: Int, _ se: Int, _ caps: Int, _ field: [UInt8], _ shell: String) -> [UInt8] {
        var l = Array("\(name):\(pr):\(se):\(caps):".utf8)
        l.append(contentsOf: field)
        l.append(contentsOf: Array(":\(shell)\n".utf8))
        return l
    }

    static func bank(_ kind: UInt8, _ gen: UInt64, _ payload: [UInt8]) -> [UInt8] {
        let out = UnsafeMutableRawPointer.allocate(byteCount: identityBankSize, alignment: 16)
        let pp = pin(payload)
        let ok = identityBankWrite(out, kind: kind, generation: gen, payload: pp, payloadLen: payload.count)
        check(ok, "bank write fit payload")
        return grab(out, identityBankSize)
    }

    // ---- resolve wrapper ----

    static func resolve(_ name: String, _ pass: String, base: [UInt8],
                        p0: [UInt8]? = nil, p1: [UInt8]? = nil,
                        a0: [UInt8]? = nil, a1: [UInt8]? = nil) -> Int32 {
        let np = pin(Array(name.utf8)), pp = pin(Array(pass.utf8)), bp = pin(base)
        let cap = 512
        let outp = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
        var outLen = 0
        return identityResolve(
            name: np, nameLen: name.utf8.count, password: pp, passwordLen: pass.utf8.count,
            passwd0: pinOpt(p0), passwd0Len: p0?.count ?? 0,
            passwd1: pinOpt(p1), passwd1Len: p1?.count ?? 0,
            anchor0: pinOpt(a0), anchor0Len: a0?.count ?? 0,
            anchor1: pinOpt(a1), anchor1Len: a1?.count ?? 0,
            base: bp, baseLen: base.count,
            outLine: outp, outLineCap: cap, outLineLen: &outLen)
    }

    static func main() {
        // ---- 1. PBKDF2-HMAC-SHA256 vectors -------------------------------
        // Published PBKDF2-HMAC-SHA256 test vectors (P="password", S="salt").
        check(pbkdf2("password", "salt", 1, 32) ==
              hex("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
              "PBKDF2-HMAC-SHA256 c=1")
        check(pbkdf2("password", "salt", 2, 32) ==
              hex("ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
              "PBKDF2-HMAC-SHA256 c=2")
        check(pbkdf2("password", "salt", 4096, 32) ==
              hex("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
              "PBKDF2-HMAC-SHA256 c=4096")
        // Multi-block (dkLen=40 spans two HMAC blocks) — exercises T_2 + truncation.
        check(pbkdf2("passwordPASSWORDpassword",
                     "saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096, 40) ==
              hex("348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9"),
              "PBKDF2-HMAC-SHA256 c=4096 dkLen=40 (multi-block)")

        // ---- 2. Password-field codec -------------------------------------
        let fieldA = buildField("hunter2", 1000)
        check(verify(fieldA, "hunter2"), "pbkdf2 field verifies correct password")
        check(!verify(fieldA, "hunter3"), "pbkdf2 field rejects wrong password")
        check(!verify(fieldA, "Hunter2"), "pbkdf2 field rejects case change")
        // Different work factors produce distinct, independently-verifiable fields.
        let fieldB = buildField("hunter2", 2000)
        check(fieldA != fieldB, "iteration count is part of the field")
        check(verify(fieldB, "hunter2"), "higher-iteration field still verifies")
        // Legacy salt$sha256hex compatibility (the base-image seed format).
        var legacy = Array("abc$".utf8); legacy.append(contentsOf: sha256hex("abcsecret"))
        check(verify(legacy, "secret"), "legacy salt$sha256hex verifies")
        check(!verify(legacy, "secre"), "legacy field rejects wrong password")
        // Malformed fields must not trap and must not authenticate.
        check(!verify(Array("garbage".utf8), "x"), "malformed field rejected")
        check(!verify([], "x"), "empty field rejected")

        // ---- 3. Bank serialization ---------------------------------------
        let payload = Array("root:1:1:63:x:/bin/sh\n".utf8)
        let b = bank(identityBankKindPasswd, 7, payload)
        check(b.count == identityBankSize, "bank is exactly one block")
        let bp = pin(b)
        let parsed = identityBankParse(bp, b.count)
        check(parsed.valid, "valid bank parses")
        check(parsed.kind == identityBankKindPasswd, "bank kind preserved")
        check(parsed.generation == 7, "bank generation preserved")
        check(parsed.payloadLen == payload.count, "bank payload length preserved")
        check(grab(bp + parsed.payloadOff, parsed.payloadLen) == payload, "bank payload bytes preserved")
        // Tamper anywhere in the checksum-covered body → invalid.
        var torn = b; torn[100] ^= 0xFF
        check(!identityBankParse(pin(torn), torn.count).valid, "torn bank fails checksum")
        // Tamper the generation field → invalid (checksum covers the header).
        var bumped = b; bumped[8] ^= 0x01
        check(!identityBankParse(pin(bumped), bumped.count).valid, "generation tamper fails checksum")
        // A short buffer is not a valid bank.
        check(!identityBankParse(pin(Array(b[0..<2048])), 2048).valid, "short buffer rejected")
        // Oversized payload is refused at write time.
        let outBig = UnsafeMutableRawPointer.allocate(byteCount: identityBankSize, alignment: 16)
        let big = pin([UInt8](repeating: 0x41, count: identityMaxPayload + 1))
        check(!identityBankWrite(outBig, kind: identityBankKindPasswd, generation: 1,
                                 payload: big, payloadLen: identityMaxPayload + 1),
              "oversized payload refused")

        // ---- 4. Dual-bank selection --------------------------------------
        let bGen1 = bank(identityBankKindPasswd, 1, payload)
        let bGen2 = bank(identityBankKindPasswd, 2, payload)
        var tornBank = bGen1; tornBank[200] ^= 0xFF
        // Higher generation wins regardless of slot order.
        var sel = identitySelect(pin(bGen1), bGen1.count, pin(bGen2), bGen2.count, identityBankKindPasswd)
        check(sel.valid && sel.generation == 2 && sel.which == 1, "select picks higher generation (slot 1)")
        sel = identitySelect(pin(bGen2), bGen2.count, pin(bGen1), bGen1.count, identityBankKindPasswd)
        check(sel.valid && sel.generation == 2 && sel.which == 0, "select picks higher generation (slot 0)")
        // A torn bank is ignored in favor of the intact one.
        sel = identitySelect(pin(tornBank), tornBank.count, pin(bGen2), bGen2.count, identityBankKindPasswd)
        check(sel.valid && sel.generation == 2 && sel.which == 1, "select skips torn bank")
        // Both torn but present → present-but-invalid.
        var torn2 = bGen2; torn2[200] ^= 0xFF
        sel = identitySelect(pin(tornBank), tornBank.count, pin(torn2), torn2.count, identityBankKindPasswd)
        check(sel.anyPresent && !sel.valid, "both torn → present but invalid")
        // Absent files → not present.
        sel = identitySelect(nil, 0, nil, 0, identityBankKindPasswd)
        check(!sel.anyPresent && !sel.valid, "no files → absent")
        // Kind mismatch is rejected (a passwd bank never satisfies an anchor select).
        sel = identitySelect(pin(bGen2), bGen2.count, nil, 0, identityBankKindAnchor)
        check(!sel.valid, "kind mismatch rejected")

        // ---- 5. Resolve policy (the security core) -----------------------
        // Base image: root (factory password "factory"), alice ("alicepw").
        let rootBase  = line("root", 1, 1, 63, buildField("factory", 1000), "/bin/zsh")
        let aliceBase = line("alice", 2, 2, 14, buildField("alicepw", 1000), "/bin/sh")
        let base = rootBase + aliceBase

        // 5a. Factory state — no overlay, no anchor. Base default applies.
        check(resolve("root", "factory", base: base) == identityUseEntry, "factory: default accepted")
        check(resolve("root", "newroot", base: base) == identityWrongPassword, "factory: only default works")
        check(resolve("bob", "x", base: base) == identityNotFound, "factory: unknown user not found")

        // 5b. Committed change — passwd gen1 + anchor gen1 both valid.
        //     root now uses "newroot"; the factory default must be rejected.
        let overlay1 = line("root", 1, 1, 63, buildField("newroot", 1000), "/bin/zsh")
        let pw1 = bank(identityBankKindPasswd, 1, overlay1)
        let anc1 = bank(identityBankKindAnchor, 1, [])
        check(resolve("root", "newroot", base: base, p0: pw1, a0: anc1) == identityUseEntry,
              "committed: new password accepted")
        check(resolve("root", "factory", base: base, p0: pw1, a0: anc1) == identityWrongPassword,
              "committed: factory default REJECTED (no rollback to default)")
        // Merge: alice was never changed, so she still resolves from the base.
        check(resolve("alice", "alicepw", base: base, p0: pw1, a0: anc1) == identityUseEntry,
              "committed: unchanged user merges from base")

        // 5c. ANTI-ROLLBACK CORE — provisioned, but both passwd banks corrupt.
        //     This is disk rot / tampering, never a single crash. Must fail closed,
        //     NOT fall back to the factory default.
        var pw1torn = pw1; pw1torn[300] ^= 0xFF
        var pw1torn2 = pw1; pw1torn2[400] ^= 0xFF
        check(resolve("root", "factory", base: base, p0: pw1torn, p1: pw1torn2, a0: anc1) == identityFailClosed,
              "provisioned + corrupt overlay: factory default refused (fail closed)")
        check(resolve("root", "newroot", base: base, p0: pw1torn, p1: pw1torn2, a0: anc1) == identityFailClosed,
              "provisioned + corrupt overlay: fail closed for all")
        // Overlay missing entirely (deleted) but anchor survives → still fail closed.
        check(resolve("root", "factory", base: base, a0: anc1) == identityFailClosed,
              "provisioned + missing overlay: fail closed")

        // 5d. Uncommitted first change — passwd torn, NO anchor yet. The change
        //     never committed, so the factory default is legitimately still in
        //     force. Must accept it (no brick), not fail closed.
        check(resolve("root", "factory", base: base, p0: pw1torn) == identityUseEntry,
              "uncommitted first change: factory default still valid")

        // 5e. Rollback — a stale valid overlay (gen1) restored under a higher
        //     anchor watermark (gen5). Must fail closed.
        let anc5 = bank(identityBankKindAnchor, 5, [])
        check(resolve("root", "newroot", base: base, p0: pw1, a0: anc5) == identityFailClosed,
              "rollback below watermark: fail closed")

        // 5f. Ping-pong across two changes — gen2 supersedes gen1.
        let overlay2 = line("root", 1, 1, 63, buildField("newest", 1000), "/bin/zsh")
        let pw2 = bank(identityBankKindPasswd, 2, overlay2)
        let anc2 = bank(identityBankKindAnchor, 2, [])
        check(resolve("root", "newest", base: base, p0: pw1, p1: pw2, a0: anc2) == identityUseEntry,
              "ping-pong: highest generation wins")
        check(resolve("root", "newroot", base: base, p0: pw1, p1: pw2, a0: anc2) == identityWrongPassword,
              "ping-pong: superseded generation rejected")
        // Crash during the gen2 write: gen2 torn, gen1 (committed) intact → gen1 holds.
        var pw2torn = pw2; pw2torn[250] ^= 0xFF
        check(resolve("root", "newroot", base: base, p0: pw1, p1: pw2torn, a0: anc1) == identityUseEntry,
              "crash mid-change: previous committed password survives")

        if failed {
            FileHandle.standardError.write(Data("identity_test: FAILURES\n".utf8))
            exit(1)
        }
        print("identity_test: PASS (PBKDF2 / field codec / bank / dual-bank resolve policy)")
    }
}

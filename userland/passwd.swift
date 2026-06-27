// SPDX-License-Identifier: Apache-2.0
// passwd.swift — change the calling principal's password (Phase 1, K2).
//
// The identity store /etc/swos/passwd is in the read-only, signed base image, so
// the new password is written as a crash-safe overlay on the persistent /data
// tier and merged over the base at login (see userland/lib/swos_identity.swift for
// the full design + crash analysis). This program is the writer; console-login is
// the reader (wired in K3).
//
// Self-service only: it changes the password of whoever is running it, identified
// by the security context (principal) adopted at login. Administrative reset of
// another user's password is a privileged path that belongs with K4 recovery.
//
// Commit protocol (the order is the crash-safety contract):
//   1. Verify the current password against the merged identity.
//   2. Build the new overlay (all previously-changed users, with this user's entry
//      replaced) and write it to the NON-winning passwd bank, then fsync. This
//      fsync is the single commit point — a crash before it leaves the previous
//      credential in force; after it the new password is durable.
//   3. Advance the monotonic "provisioned" anchor (non-winning anchor bank, fsync)
//      so a later lost/rolled-back overlay fails closed instead of reverting to
//      the base default.
//
// Compiled in Swift on the swift_user bridge, alongside swos_identity.swift and
// kernel/crypto/sha256.swift, like /bin/console-login.

private let oRdOnly: Int32 = 0
private let oWrOnly: Int32 = 1
private let oCreat: Int32 = 0x40
private let oTrunc: Int32 = 0x80

private let lineMax = 256

// ---- small byte/c-string helpers ------------------------------------------

@inline(__always) private func ld(_ p: UnsafeRawPointer, _ o: Int) -> UInt8 { p.load(fromByteOffset: o, as: UInt8.self) }
@inline(__always) private func st(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt8) { p.storeBytes(of: v, toByteOffset: o, as: UInt8.self) }

private func cstrToInt(_ s: UnsafePointer<CChar>) -> Int {
    var v = 0, i = 0
    while s[i] != 0 {
        let c = s[i]
        if c < 0x30 || c > 0x39 { break }
        v = v * 10 + Int(c - 0x30)
        i += 1
    }
    return v
}

/// Read a whole file into `buf` (capacity `cap`). Returns the byte count, or -1 if
/// the file does not exist (open failed) — the caller distinguishes "absent" (nil
/// bank) from "present" for the dual-bank policy.
private func readFile(_ path: UnsafePointer<CChar>, _ buf: UnsafeMutableRawPointer, _ cap: Int) -> Int {
    let fd = swiftos_open(path, oRdOnly)
    if fd < 0 { return -1 }
    var total = 0
    while total < cap {
        let r = swiftos_read(fd, buf + total, UInt(cap - total))
        if r <= 0 { break }
        total += Int(r)
    }
    _ = swiftos_close(fd)
    return total
}

/// Write exactly one bank (identityBankSize bytes) to `path` and fsync it. Returns
/// true only if both the full write and the fsync succeeded — the caller treats a
/// false here as "not committed".
private func writeBank(_ path: UnsafePointer<CChar>, _ bank: UnsafeRawPointer) -> Bool {
    let fd = swiftos_open(path, oWrOnly | oCreat | oTrunc)
    if fd < 0 { return false }
    var total = 0
    while total < identityBankSize {
        let w = swiftos_write(fd, bank + total, UInt(identityBankSize - total))
        if w <= 0 { _ = swiftos_close(fd); return false }
        total += Int(w)
    }
    let fs = swiftos_fsync(fd)   // honest flush to stable media (datafs → virtio FLUSH)
    _ = swiftos_close(fd)
    return fs == 0
}

/// Fill `out[0..<n]` with random bytes from the kernel RNG (the same
/// getrandom-style source /bin/sshd and /bin/tlsget use). Returns false on failure.
private func readRandom(_ out: UnsafeMutableRawPointer, _ n: Int) -> Bool {
    var total = 0
    while total < n {
        let r = swiftos_random(out + total, UInt(n - total))
        if r <= 0 { break }
        total += Int(r)
    }
    return total == n
}

/// Read one line from the tty into `buf` (NUL-terminated), with echo optionally
/// suppressed (for passwords). Returns length, or -1 on EOF.
private func readSecret(_ prompt: UnsafePointer<CChar>, _ buf: UnsafeMutableRawPointer, _ cap: Int, echo: Bool) -> Int {
    swiftos_puts(prompt)
    if !echo { swiftos_set_echo(0) }
    let n = swiftos_read(0, buf, UInt(cap - 1))
    if !echo { swiftos_set_echo(1); swiftos_puts("\n") }
    if n <= 0 { return -1 }
    var len = Int(n)
    if len > 0 && ld(buf, len - 1) == 0x0A { len -= 1 }
    st(buf, len, 0)
    return len
}

// ---- passwd-line field helpers (on a single line, ':'-separated) ----------

private func lineField(_ p: UnsafeRawPointer, _ len: Int, _ n: Int) -> (start: Int, len: Int) {
    var idx = 0, start = 0, i = 0
    while true {
        if i == len || ld(p, i) == 0x3A {
            if idx == n { return (start, i - start) }
            idx += 1
            start = i + 1
        }
        if i == len { break }
        i += 1
    }
    return (-1, 0)
}

private func parseUInt(_ p: UnsafeRawPointer, _ start: Int, _ len: Int) -> UInt64 {
    var v: UInt64 = 0, i = 0
    while i < len { let c = ld(p, start + i); if c < 0x30 || c > 0x39 { break }; v = v &* 10 &+ UInt64(c - 0x30); i += 1 }
    return v
}

/// Find the line in a passwd-format buffer whose principal (field 1) equals
/// `principal`; copy its name (field 0) into `nameOut`. Returns the name length or
/// -1 if no such principal exists.
private func nameForPrincipal(_ buf: UnsafeRawPointer, _ bufLen: Int, _ principal: UInt32,
                              _ nameOut: UnsafeMutableRawPointer, _ nameCap: Int) -> Int {
    var i = 0
    while i < bufLen {
        var j = i
        while j < bufLen && ld(buf, j) != 0x0A { j += 1 }
        let ls = i, ll = j - i
        i = j + 1
        if ll == 0 || ld(buf, ls) == 0x23 { continue }
        let f1 = lineField(buf + ls, ll, 1)
        if f1.start < 0 { continue }
        if UInt32(truncatingIfNeeded: parseUInt(buf + ls, f1.start, f1.len)) == principal {
            let f0 = lineField(buf + ls, ll, 0)
            let n = f0.len < nameCap - 1 ? f0.len : nameCap - 1
            for k in 0..<n { st(nameOut, k, ld(buf + ls, f0.start + k)) }
            st(nameOut, n, 0)
            return n
        }
    }
    return -1
}

// ---- scratch layout (one big stack buffer, carved by offset) --------------
//
// Avoids deeply nested withUnsafeTemporaryAllocation closures. All regions are
// sized for the worst case (a bank is identityBankSize = 4096).

private let R_BASE      = 0          // 8192: /etc/swos/passwd
private let R_PW0       = 8192       // 4096
private let R_PW1       = 12288      // 4096
private let R_PV0       = 16384      // 4096
private let R_PV1       = 20480      // 4096
private let R_PAYLOAD   = 24576      // 4096: new overlay payload
private let R_BANK      = 28672      // 4096: serialized bank to write
private let R_OUTLINE   = 32768      // 512:  authoritative entry from resolve
private let R_NEWLINE   = 33280      // 512:  rebuilt entry line
private let R_FIELD     = 33792      // 256:  new pbkdf2 field
private let SCRATCH_CAP = 34048

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp

    // Optional "-i <iters>" to tune (and let tests lower) the PBKDF2 work factor.
    var iters = identityDefaultIterations
    if let argv = argv {
        var k = 1
        while k < Int(argc) {
            if let a = argv[k], a[0] == 0x2D, a[1] == 0x69, a[2] == 0 { // "-i"
                if k + 1 < Int(argc), let nptr = argv[k + 1] {
                    let v = cstrToInt(nptr); if v > 0 { iters = v }
                    k += 1
                }
            }
            k += 1
        }
    }

    var pr: UInt32 = 0, se: UInt32 = 0, cp: UInt = 0
    if swiftos_context(&pr, &se, &cp) != 0 {
        swiftos_puts("passwd: cannot read security context\n")
        return 1
    }

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: SCRATCH_CAP) { sb in
        let s = UnsafeMutableRawPointer(sb.baseAddress!)

        // 1. Resolve our own username from the base store (name is immutable).
        let baseLen = readFile("/etc/swos/passwd", s + R_BASE, 8192)
        if baseLen <= 0 {
            swiftos_puts("passwd: cannot open /etc/swos/passwd\n")
            return 1
        }
        var nameBuf = (UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0)) // 64 bytes
        let nameLen = withUnsafeMutableBytes(of: &nameBuf) { nb in
            nameForPrincipal(s + R_BASE, baseLen, pr, nb.baseAddress!, 64)
        }
        if nameLen <= 0 {
            swiftos_puts("passwd: no identity for the current principal\n")
            return 1
        }

        return withUnsafeMutableBytes(of: &nameBuf) { nb -> Int32 in
            let namePtr = nb.baseAddress!

            // 2. Load the four overlay banks (absent → treated as nil).
            let n0 = readFile("/data/swos/passwd.0", s + R_PW0, identityBankSize)
            let n1 = readFile("/data/swos/passwd.1", s + R_PW1, identityBankSize)
            let a0 = readFile("/data/swos/prov.0",   s + R_PV0, identityBankSize)
            let a1 = readFile("/data/swos/prov.1",   s + R_PV1, identityBankSize)
            let pw0p: UnsafeRawPointer? = n0 >= 0 ? UnsafeRawPointer(s + R_PW0) : nil
            let pw1p: UnsafeRawPointer? = n1 >= 0 ? UnsafeRawPointer(s + R_PW1) : nil
            let pv0p: UnsafeRawPointer? = a0 >= 0 ? UnsafeRawPointer(s + R_PV0) : nil
            let pv1p: UnsafeRawPointer? = a1 >= 0 ? UnsafeRawPointer(s + R_PV1) : nil

            // 3. Prompt for and verify the current password.
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { oldb -> Int32 in
                let oldp = UnsafeMutableRawPointer(oldb.baseAddress!)
                let oldLen = readSecret("Current password: ", oldp, lineMax, echo: false)
                if oldLen < 0 { return 1 }

                var outLen = 0
                let st0 = identityResolve(
                    name: namePtr, nameLen: nameLen, password: oldp, passwordLen: oldLen,
                    passwd0: pw0p, passwd0Len: max(0, n0), passwd1: pw1p, passwd1Len: max(0, n1),
                    anchor0: pv0p, anchor0Len: max(0, a0), anchor1: pv1p, anchor1Len: max(0, a1),
                    base: UnsafeRawPointer(s + R_BASE), baseLen: baseLen,
                    outLine: s + R_OUTLINE, outLineCap: 512, outLineLen: &outLen)

                if st0 == identityFailClosed {
                    swiftos_puts("passwd: credential store is in a recovery state; cannot change password\n")
                    return 1
                }
                if st0 != identityUseEntry {
                    swiftos_puts("passwd: authentication failure\n")
                    return 1
                }
                let curLine = UnsafeRawPointer(s + R_OUTLINE)
                let curLen = outLen

                // 4. Prompt for the new password twice.
                return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { n1b -> Int32 in
                    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { n2b -> Int32 in
                        let new1 = UnsafeMutableRawPointer(n1b.baseAddress!)
                        let new2 = UnsafeMutableRawPointer(n2b.baseAddress!)
                        let l1 = readSecret("New password: ", new1, lineMax, echo: false)
                        if l1 < 0 { return 1 }
                        if l1 == 0 { swiftos_puts("passwd: empty password rejected\n"); return 1 }
                        let l2 = readSecret("Retype new password: ", new2, lineMax, echo: false)
                        if l2 < 0 { return 1 }
                        var same = l1 == l2
                        if same { for k in 0..<l1 where ld(new1, k) != ld(new2, k) { same = false } }
                        if !same { swiftos_puts("passwd: passwords do not match\n"); return 1 }

                        // 5. Hash the new password (random salt) into a modern field.
                        var saltBuf = (UInt64(0), UInt64(0))   // 16-byte salt
                        let okRand = withUnsafeMutableBytes(of: &saltBuf) { readRandom($0.baseAddress!, 16) }
                        if !okRand { swiftos_puts("passwd: no entropy source\n"); return 1 }
                        let fieldLen = withUnsafeBytes(of: &saltBuf) { saltRaw -> Int in
                            identityBuildPbkdf2Field(new1, l1, saltRaw.baseAddress!, 16, iters, s + R_FIELD, 256)
                        }
                        if fieldLen <= 0 { swiftos_puts("passwd: hash error\n"); return 1 }

                        // 6. Rebuild this user's entry line (replace field 4 only).
                        let newLineLen = rebuildEntry(curLine, curLen, s + R_FIELD, fieldLen, s + R_NEWLINE, 512)
                        if newLineLen <= 0 { swiftos_puts("passwd: entry too long\n"); return 1 }

                        // 7. Compose the new overlay payload: every existing overlay
                        //    line except ours, then our rebuilt line.
                        let pwSel = identitySelect(pw0p, max(0, n0), pw1p, max(0, n1), identityBankKindPasswd)
                        let pvSel = identitySelect(pv0p, max(0, a0), pv1p, max(0, a1), identityBankKindAnchor)
                        var payLen = 0
                        if pwSel.valid {
                            let win: UnsafeRawPointer = pwSel.which == 0 ? pw0p! : pw1p!
                            payLen = copyOverlayExcept(win + pwSel.payloadOff, pwSel.payloadLen,
                                                       namePtr, nameLen, s + R_PAYLOAD, identityMaxPayload)
                        }
                        // Append our line + newline.
                        if payLen + newLineLen + 1 > identityMaxPayload { swiftos_puts("passwd: overlay full\n"); return 1 }
                        for k in 0..<newLineLen { st(s + R_PAYLOAD, payLen + k, ld(s + R_NEWLINE, k)) }
                        payLen += newLineLen
                        st(s + R_PAYLOAD, payLen, 0x0A); payLen += 1

                        // 8. Write the new passwd bank to the NON-winning slot, fsync.
                        let newGen = (pwSel.generation > pvSel.generation ? pwSel.generation : pvSel.generation) &+ 1
                        if !identityBankWrite(s + R_BANK, kind: identityBankKindPasswd, generation: newGen,
                                              payload: s + R_PAYLOAD, payloadLen: payLen) {
                            swiftos_puts("passwd: overlay full\n"); return 1
                        }
                        _ = swiftos_mkdir("/data/swos")
                        let pwOK = (pwSel.which == 0)
                            ? writeBank("/data/swos/passwd.1", s + R_BANK)
                            : writeBank("/data/swos/passwd.0", s + R_BANK)
                        if !pwOK {
                            swiftos_puts("passwd: unable to write credential store (password unchanged)\n")
                            return 1
                        }
                        // --- commit point passed: the new password is now durable ---

                        // 9. Advance the provisioned anchor (non-winning slot, fsync).
                        //    A failure here does not unset the new password; the next
                        //    change re-advances the watermark.
                        if identityBankWrite(s + R_BANK, kind: identityBankKindAnchor, generation: newGen,
                                             payload: nil, payloadLen: 0) {
                            let pvOK = (pvSel.which == 0)
                                ? writeBank("/data/swos/prov.1", s + R_BANK)
                                : writeBank("/data/swos/prov.0", s + R_BANK)
                            if !pvOK { swiftos_puts("passwd: warning: rollback anchor not updated\n") }
                        }

                        swiftos_puts("passwd: password updated\n")
                        return 0
                    }
                }
            }
        }
    }
}

/// Rebuild a passwd line, replacing field 4 (the password) with `field`. Writes
/// "f0:f1:f2:f3:<field>:f5" into `out`; returns its length or -1 if it does not fit.
private func rebuildEntry(_ line: UnsafeRawPointer, _ lineLen: Int,
                          _ field: UnsafeRawPointer, _ fieldLen: Int,
                          _ out: UnsafeMutableRawPointer, _ outCap: Int) -> Int {
    var pos = 0
    @inline(__always) func emit(_ b: UInt8) -> Bool { if pos >= outCap { return false }; st(out, pos, b); pos += 1; return true }
    @inline(__always) func emitField(_ n: Int) -> Bool {
        let f = lineField(line, lineLen, n)
        if f.start < 0 { return false }
        for k in 0..<f.len { if !emit(ld(line, f.start + k)) { return false } }
        return true
    }
    if !emitField(0) || !emit(0x3A) { return -1 }
    if !emitField(1) || !emit(0x3A) { return -1 }
    if !emitField(2) || !emit(0x3A) { return -1 }
    if !emitField(3) || !emit(0x3A) { return -1 }
    for k in 0..<fieldLen { if !emit(ld(field, k)) { return -1 } }
    if !emit(0x3A) { return -1 }
    if !emitField(5) { return -1 }
    return pos
}

/// Copy every line of an overlay payload EXCEPT the one whose field 0 equals
/// `name`, preserving newlines. Returns the bytes written into `out`.
private func copyOverlayExcept(_ payload: UnsafeRawPointer, _ payLen: Int,
                               _ name: UnsafeRawPointer, _ nameLen: Int,
                               _ out: UnsafeMutableRawPointer, _ outCap: Int) -> Int {
    var pos = 0, i = 0
    while i < payLen {
        var j = i
        while j < payLen && ld(payload, j) != 0x0A { j += 1 }
        let ls = i, ll = j - i
        i = j + 1
        if ll == 0 { continue }
        var f = ls
        while f < ls + ll && ld(payload, f) != 0x3A { f += 1 }
        let f0len = f - ls
        var isMine = f0len == nameLen
        if isMine { for k in 0..<nameLen where ld(payload, ls + k) != ld(name, k) { isMine = false } }
        if isMine { continue }
        if pos + ll + 1 > outCap { break }
        for k in 0..<ll { st(out, pos + k, ld(payload, ls + k)) }
        pos += ll
        st(out, pos, 0x0A); pos += 1
    }
    return pos
}

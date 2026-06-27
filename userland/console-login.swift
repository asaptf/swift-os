// SPDX-License-Identifier: Apache-2.0
// console-login.swift — authenticate a principal from the identity store, then
// hand off to the user's shell (M12b; overlay-aware as of K3).
//
// The base-image store /etc/swos/passwd is read-only and signed, so password
// changes are written as a crash-safe overlay on the persistent /data tier
// (/bin/passwd, K2). This program now resolves credentials through the shared
// identity resolver (userland/lib/swos_identity.swift), which merges the overlay
// banks over the base, applies the dual-bank ping-pong + provisioned-anchor
// policy, and verifies the password (PBKDF2 or legacy salt$sha256hex). On a match
// it calls login() to adopt that principal/session/capability context before
// execve()'ing the shell. If the overlay proves the system was provisioned but the
// banks are lost/corrupt/rolled-back, the resolver fails closed and we refuse the
// login rather than silently restoring the factory default.
//
// Written in Swift on the swift_user bridge, like /bin/ps and /bin/passwd.

private let lineMax = 128

// Scratch layout: the base store plus the four overlay banks, read fresh per
// authentication attempt (passwd may have rewritten them since boot).
private let R_BASE = 0        // 8192: /etc/swos/passwd
private let R_PW0  = 8192     // 4096: /data/swos/passwd.0
private let R_PW1  = 12288    // 4096: /data/swos/passwd.1
private let R_PV0  = 16384    // 4096: /data/swos/prov.0
private let R_PV1  = 20480    // 4096: /data/swos/prov.1
private let SCRATCH_CAP = 24576

private func putUInt(_ value: UInt64) {
    var divisor: UInt64 = 1
    while value / divisor >= 10 { divisor *= 10 }
    var rest = value
    while divisor > 0 {
        swiftos_putc(0x30 + UInt8(rest / divisor))
        rest %= divisor
        divisor /= 10
    }
}

/// Read a whole file into `buf` (capacity `cap`). Returns the byte count, or -1 if
/// the file does not exist (open failed) — the caller passes nil for an absent bank.
private func readFileInto(_ path: UnsafePointer<CChar>, _ buf: UnsafeMutableRawPointer, _ cap: Int) -> Int {
    let fd = swiftos_open(path, 0)
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

/// Read one line from fd 0 into `buf` (canonical tty: one read == one line).
/// Strips a trailing newline, NUL-terminates. Returns length, or -1 on EOF.
private func readLine(_ buf: UnsafeMutableBufferPointer<UInt8>) -> Int {
    let n = swiftos_read(0, UnsafeMutableRawPointer(buf.baseAddress!), UInt(buf.count - 1))
    if n <= 0 { return -1 }
    var len = Int(n)
    if len > 0 && buf[len - 1] == 0x0A { len -= 1 }
    buf[len] = 0
    return len
}

/// The (start, length) of the n-th ':'-separated field within store[ls..<ls+ll].
private func nthField(_ store: UnsafeRawPointer, _ ls: Int, _ ll: Int, _ n: Int)
    -> (start: Int, len: Int) {
    var idx = 0
    var start = ls
    let end = ls + ll
    var i = ls
    while true {
        if i == end || store.load(fromByteOffset: i, as: UInt8.self) == 0x3A { // ':'
            if idx == n { return (start, i - start) }
            idx += 1
            start = i + 1
        }
        if i == end { break }
        i += 1
    }
    return (-1, 0)
}

private func parseUInt(_ store: UnsafeRawPointer, _ start: Int, _ len: Int) -> UInt64 {
    var v: UInt64 = 0
    var i = 0
    while i < len {
        let c = store.load(fromByteOffset: start + i, as: UInt8.self)
        if c < 0x30 || c > 0x39 { break }
        v = v * 10 + UInt64(c - 0x30)
        i += 1
    }
    return v
}

/// Resolve `name`/`pass` through the overlay-aware identity resolver and, on a
/// match, adopt the context and exec the shell. Returns -1 to reprompt (wrong
/// password / unknown user), -2 on a fail-closed store (recovery required), or a
/// non-negative exit code if a matched login's exec path returned (an error).
private func tryAuthenticate(_ s: UnsafeMutableRawPointer, _ baseLen: Int,
                             _ name: UnsafeMutablePointer<UInt8>, _ nameLen: Int,
                             _ pass: UnsafeMutablePointer<UInt8>, _ passLen: Int) -> Int32 {
    // Read the four overlay banks fresh (absent → nil).
    let n0 = readFileInto("/data/swos/passwd.0", s + R_PW0, identityBankSize)
    let n1 = readFileInto("/data/swos/passwd.1", s + R_PW1, identityBankSize)
    let a0 = readFileInto("/data/swos/prov.0",   s + R_PV0, identityBankSize)
    let a1 = readFileInto("/data/swos/prov.1",   s + R_PV1, identityBankSize)
    let pw0: UnsafeRawPointer? = n0 >= 0 ? UnsafeRawPointer(s + R_PW0) : nil
    let pw1: UnsafeRawPointer? = n1 >= 0 ? UnsafeRawPointer(s + R_PW1) : nil
    let pv0: UnsafeRawPointer? = a0 >= 0 ? UnsafeRawPointer(s + R_PV0) : nil
    let pv1: UnsafeRawPointer? = a1 >= 0 ? UnsafeRawPointer(s + R_PV1) : nil

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { outb -> Int32 in
        let outLine = UnsafeMutableRawPointer(outb.baseAddress!)
        var outLen = 0
        let st = identityResolve(
            name: UnsafeRawPointer(name), nameLen: nameLen,
            password: UnsafeRawPointer(pass), passwordLen: passLen,
            passwd0: pw0, passwd0Len: max(0, n0), passwd1: pw1, passwd1Len: max(0, n1),
            anchor0: pv0, anchor0Len: max(0, a0), anchor1: pv1, anchor1Len: max(0, a1),
            base: UnsafeRawPointer(s + R_BASE), baseLen: baseLen,
            outLine: outLine, outLineCap: 512, outLineLen: &outLen)

        if st == identityFailClosed { return -2 }
        if st != identityUseEntry { return -1 }

        // Authenticated. Adopt the principal from the authoritative line, report
        // it, and exec the shell.
        let f1 = nthField(outLine, 0, outLen, 1)
        let f2 = nthField(outLine, 0, outLen, 2)
        let f3 = nthField(outLine, 0, outLen, 3)
        let principal = UInt32(truncatingIfNeeded: parseUInt(outLine, f1.start, f1.len))
        let session = UInt32(truncatingIfNeeded: parseUInt(outLine, f2.start, f2.len))
        let caps = UInt(truncatingIfNeeded: parseUInt(outLine, f3.start, f3.len))

        if swiftos_login(principal, session, caps) != 0 {
            swiftos_puts("console-login: login() denied\n")
            return 1
        }
        swiftos_puts("Welcome to swift-os, ")
        swiftos_puts(UnsafeRawPointer(name).assumingMemoryBound(to: CChar.self))
        swiftos_puts("\n")

        var p: UInt32 = 0, ss: UInt32 = 0, c: UInt = 0
        if swiftos_context(&p, &ss, &c) == 0 {
            swiftos_puts("session: principal=")
            putUInt(UInt64(p))
            swiftos_puts(" session=")
            putUInt(UInt64(ss))
            swiftos_puts(" caps=")
            putUInt(UInt64(c))
            swiftos_puts("\n")
        }

        // Copy the shell path (field 5) into a NUL-terminated buffer and exec it.
        let f5 = nthField(outLine, 0, outLen, 5)
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { shell -> Int32 in
            let n = f5.len < lineMax - 1 ? f5.len : lineMax - 1
            for k in 0..<n { shell[k] = outLine.load(fromByteOffset: f5.start + k, as: UInt8.self) }
            shell[n] = 0
            // Emit the "shell ready" marker BEFORE exec so test harnesses can detect
            // a successful login regardless of which shell is launched.
            swiftos_puts("M12c: shell ready\n")
            _ = swiftos_exec_shell(UnsafeRawPointer(shell.baseAddress!).assumingMemoryBound(to: CChar.self))
            swiftos_puts("console-login: exec of shell failed\n")
            return 1
        }
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: SCRATCH_CAP) { sb in
        let s = UnsafeMutableRawPointer(sb.baseAddress!)
        let baseLen = readFileInto("/etc/swos/passwd", s + R_BASE, 8192)
        if baseLen <= 0 {
            swiftos_puts("console-login: cannot open /etc/swos/passwd\n")
            return 1
        }

        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { name in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { pass in
                while true {
                    swiftos_set_echo(1) // ensure echo is on (a prior prompt may have left it off)
                    swiftos_puts("\nswift-os login: ")
                    let nl = readLine(name)
                    if nl < 0 { return 0 }
                    if name[0] == 0 { continue }
                    swiftos_puts("Password: ")
                    swiftos_set_echo(0)              // don't echo the password
                    let pr = readLine(pass)
                    swiftos_set_echo(1)
                    swiftos_puts("\n")              // the Enter was not echoed
                    if pr < 0 { return 0 }
                    let rc = tryAuthenticate(s, baseLen, name.baseAddress!, nl, pass.baseAddress!, pr)
                    if rc >= 0 { return rc } // matched: success execs; non-zero only on error
                    if rc == -2 {
                        swiftos_puts("console-login: credential store unavailable; recovery required\n")
                        continue
                    }
                    swiftos_puts("Login incorrect\n")
                }
            }
        }
    }
}

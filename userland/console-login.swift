// SPDX-License-Identifier: Apache-2.0
// console-login.swift — authenticate a principal from the base-image identity
// store, then hand off to the user's shell (M12b).
//
// Reads /etc/swos/passwd (name:principal:session:caps:password:shell), prompts
// for a login name and password, and on a match calls login() to adopt that
// principal/session/capability context before execve()'ing the shell. login()
// is privileged (needs CAP_CONSOLE), inherited from the boot context; the shell
// then runs with the authenticated context. Passwords are plaintext for
// bring-up; the prompt echoes for now.
//
// Written in Swift (the project's first-class language) on the swift_user.c
// bridge, like /bin/ps.

private let storeCap = 4096
private let lineMax = 128

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

// ---- Password verification ------------------------------------------------
//
// SHA-256 itself lives in kernel/crypto/sha256.swift (the shared, pure crypto
// module also linked into /bin/tlsget); this program compiles that source in via
// its Makefile rule and calls the public sha256Hex(_:_:_:) below.

/// Verify a password against a `salt$sha256hex` field: hash = SHA-256(salt+pass).
private func passwordMatches(_ store: UnsafeMutablePointer<UInt8>, _ fstart: Int, _ flen: Int,
                             _ pass: UnsafeMutablePointer<UInt8>) -> Bool {
    // Split the field at '$' into salt and the expected hex hash.
    var dollar = -1
    var i = 0
    while i < flen { if store[fstart + i] == 0x24 { dollar = fstart + i; break }; i += 1 }
    if dollar < 0 { return false }
    let saltLen = dollar - fstart
    let hashStart = dollar + 1
    let hashLen = (fstart + flen) - hashStart
    if hashLen != 64 { return false }

    var passLen = 0
    while pass[passLen] != 0 { passLen += 1 }

    var ok = false
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: saltLen + passLen) { m in
        for k in 0..<saltLen { m[k] = store[fstart + k] }
        for k in 0..<passLen { m[saltLen + k] = pass[k] }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { hex in
            sha256Hex(m.baseAddress!, saltLen + passLen, hex.baseAddress!)
            var same = true
            for k in 0..<64 where hex[k] != store[hashStart + k] { same = false }
            ok = same
        }
    }
    return ok
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
private func nthField(_ store: UnsafeMutablePointer<UInt8>, _ ls: Int, _ ll: Int, _ n: Int)
    -> (start: Int, len: Int) {
    var idx = 0
    var start = ls
    let end = ls + ll
    var i = ls
    while true {
        if i == end || store[i] == 0x3A { // ':'
            if idx == n { return (start, i - start) }
            idx += 1
            start = i + 1
        }
        if i == end { break }
        i += 1
    }
    return (-1, 0)
}

/// True if the NUL-terminated `input` equals store[start..<start+len] exactly.
private func fieldEquals(_ store: UnsafeMutablePointer<UInt8>, _ start: Int, _ len: Int,
                         _ input: UnsafeMutablePointer<UInt8>) -> Bool {
    if start < 0 { return false }
    var i = 0
    while i < len {
        if input[i] == 0 || input[i] != store[start + i] { return false }
        i += 1
    }
    return input[i] == 0
}

private func parseUInt(_ store: UnsafeMutablePointer<UInt8>, _ start: Int, _ len: Int) -> UInt64 {
    var v: UInt64 = 0
    var i = 0
    while i < len {
        let c = store[start + i]
        if c < 0x30 || c > 0x39 { break }
        v = v * 10 + UInt64(c - 0x30)
        i += 1
    }
    return v
}

/// Try to authenticate `name`/`pass` against the store. Returns -1 if no line
/// matched (caller should reprompt); on a match it adopts the context and execs
/// the shell — if that path returns at all it is an error and the function
/// returns an exit code (>= 0) for main to propagate.
private func tryAuthenticate(_ store: UnsafeMutablePointer<UInt8>, _ total: Int,
                             _ name: UnsafeMutablePointer<UInt8>,
                             _ pass: UnsafeMutablePointer<UInt8>) -> Int32 {
    var i = 0
    while i < total {
        var j = i
        while j < total && store[j] != 0x0A { j += 1 }
        let ls = i
        let ll = j - i
        i = j + 1
        if ll == 0 || store[ls] == 0x23 { continue } // empty or '#'

        let f0 = nthField(store, ls, ll, 0)
        let f4 = nthField(store, ls, ll, 4)
        if f4.start < 0 { continue } // not enough fields
        if !fieldEquals(store, f0.start, f0.len, name) { continue }
        if !passwordMatches(store, f4.start, f4.len, pass) { continue }

        // Authenticated. Adopt the principal, report it, exec the shell.
        let f1 = nthField(store, ls, ll, 1)
        let f2 = nthField(store, ls, ll, 2)
        let f3 = nthField(store, ls, ll, 3)
        let principal = UInt32(truncatingIfNeeded: parseUInt(store, f1.start, f1.len))
        let session = UInt32(truncatingIfNeeded: parseUInt(store, f2.start, f2.len))
        let caps = UInt(truncatingIfNeeded: parseUInt(store, f3.start, f3.len))

        if swiftos_login(principal, session, caps) != 0 {
            swiftos_puts("console-login: login() denied\n")
            return 1
        }
        swiftos_puts("Welcome to swift-os, ")
        swiftos_puts(UnsafeRawPointer(name).assumingMemoryBound(to: CChar.self))
        swiftos_puts("\n")

        var p: UInt32 = 0, s: UInt32 = 0, c: UInt = 0
        if swiftos_context(&p, &s, &c) == 0 {
            swiftos_puts("session: principal=")
            putUInt(UInt64(p))
            swiftos_puts(" session=")
            putUInt(UInt64(s))
            swiftos_puts(" caps=")
            putUInt(UInt64(c))
            swiftos_puts("\n")
        }

        // Copy the shell path (field 5) into a NUL-terminated buffer and exec it.
        let f5 = nthField(store, ls, ll, 5)
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { shell in
            let n = f5.len < lineMax - 1 ? f5.len : lineMax - 1
            for k in 0..<n { shell[k] = store[f5.start + k] }
            shell[n] = 0
            // Emit the "shell ready" marker BEFORE exec so test harnesses can
            // detect a successful login regardless of which shell is launched.
            swiftos_puts("M12c: shell ready\n")
            _ = swiftos_exec_shell(UnsafeRawPointer(shell.baseAddress!).assumingMemoryBound(to: CChar.self))
        }
        swiftos_puts("console-login: exec of shell failed\n")
        return 1
    }
    return -1
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: storeCap) { store in
        let base = store.baseAddress!
        let fd = swiftos_open("/etc/swos/passwd", 0)
        if fd < 0 {
            swiftos_puts("console-login: cannot open /etc/swos/passwd\n")
            return 1
        }
        var total = 0
        while total < storeCap - 1 {
            let r = swiftos_read(fd, UnsafeMutableRawPointer(base + total), UInt(storeCap - 1 - total))
            if r <= 0 { break }
            total += Int(r)
        }
        _ = swiftos_close(fd)

        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { name in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { pass in
                while true {
                    swiftos_set_echo(1) // ensure echo is on (a prior prompt may have left it off)
                    swiftos_puts("\nswift-os login: ")
                    if readLine(name) < 0 { return 0 }
                    if name[0] == 0 { continue }
                    swiftos_puts("Password: ")
                    swiftos_set_echo(0)              // don't echo the password
                    let pr = readLine(pass)
                    swiftos_set_echo(1)
                    swiftos_puts("\n")              // the Enter was not echoed
                    if pr < 0 { return 0 }
                    let rc = tryAuthenticate(base, total, name.baseAddress!, pass.baseAddress!)
                    if rc >= 0 { return rc } // matched: success execs; non-zero only on error
                    swiftos_puts("Login incorrect\n")
                }
            }
        }
    }
}

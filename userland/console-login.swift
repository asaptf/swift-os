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

// ---- SHA-256 (FIPS 180-4) -------------------------------------------------

private let sha256K: [UInt32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

@inline(__always) private func rotr32(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x >> n) | (x << (32 &- n))
}

private func putWordHex(_ word: UInt32, _ out: UnsafeMutablePointer<UInt8>, _ pos: Int) {
    var shift: Int = 28
    var p = pos
    while shift >= 0 {
        let nib = UInt8((word >> UInt32(shift)) & 0xF)
        out[p] = nib < 10 ? 0x30 + nib : 0x61 + (nib - 10)
        p += 1
        shift -= 4
    }
}

/// Compute SHA-256 of msg[0..<msgLen] and write 64 lowercase hex bytes to outHex.
private func sha256Hex(_ msg: UnsafeMutablePointer<UInt8>, _ msgLen: Int,
                       _ outHex: UnsafeMutablePointer<UInt8>) {
    var h0: UInt32 = 0x6a09e667, h1: UInt32 = 0xbb67ae85, h2: UInt32 = 0x3c6ef372, h3: UInt32 = 0xa54ff53a
    var h4: UInt32 = 0x510e527f, h5: UInt32 = 0x9b05688c, h6: UInt32 = 0x1f83d9ab, h7: UInt32 = 0x5be0cd19

    var padded = msgLen + 1
    while padded % 64 != 56 { padded += 1 }
    padded += 8

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: padded) { buf in
        for i in 0..<msgLen { buf[i] = msg[i] }
        buf[msgLen] = 0x80
        var i = msgLen + 1
        while i < padded - 8 { buf[i] = 0; i += 1 }
        let bits = UInt64(msgLen) * 8
        var b = 0
        while b < 8 { buf[padded - 1 - b] = UInt8((bits >> (UInt64(b) * 8)) & 0xFF); b += 1 }

        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            var off = 0
            while off < padded {
                for t in 0..<16 {
                    let o = off + t * 4
                    w[t] = (UInt32(buf[o]) << 24) | (UInt32(buf[o + 1]) << 16)
                         | (UInt32(buf[o + 2]) << 8) | UInt32(buf[o + 3])
                }
                for t in 16..<64 {
                    let s0 = rotr32(w[t-15], 7) ^ rotr32(w[t-15], 18) ^ (w[t-15] >> 3)
                    let s1 = rotr32(w[t-2], 17) ^ rotr32(w[t-2], 19) ^ (w[t-2] >> 10)
                    w[t] = w[t-16] &+ s0 &+ w[t-7] &+ s1
                }
                var a = h0, bb = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
                for t in 0..<64 {
                    let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = h &+ s1 &+ ch &+ sha256K[t] &+ w[t]
                    let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
                    let maj = (a & bb) ^ (a & c) ^ (bb & c)
                    let t2 = s0 &+ maj
                    h = g; g = f; f = e; e = d &+ t1; d = c; c = bb; bb = a; a = t1 &+ t2
                }
                h0 = h0 &+ a; h1 = h1 &+ bb; h2 = h2 &+ c; h3 = h3 &+ d
                h4 = h4 &+ e; h5 = h5 &+ f; h6 = h6 &+ g; h7 = h7 &+ h
                off += 64
            }
        }
    }
    putWordHex(h0, outHex, 0);  putWordHex(h1, outHex, 8)
    putWordHex(h2, outHex, 16); putWordHex(h3, outHex, 24)
    putWordHex(h4, outHex, 32); putWordHex(h5, outHex, 40)
    putWordHex(h6, outHex, 48); putWordHex(h7, outHex, 56)
}

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
                    swiftos_puts("\nswift-os login: ")
                    if readLine(name) < 0 { return 0 }
                    if name[0] == 0 { continue }
                    swiftos_puts("Password: ")
                    if readLine(pass) < 0 { return 0 }
                    let rc = tryAuthenticate(base, total, name.baseAddress!, pass.baseAddress!)
                    if rc >= 0 { return rc } // matched: success execs; non-zero only on error
                    swiftos_puts("Login incorrect\n")
                }
            }
        }
    }
}

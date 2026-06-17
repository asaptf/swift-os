// SPDX-License-Identifier: Apache-2.0
// sudo.swift — run a command as another principal (default root) after
// authenticating the invoking user and checking /etc/swos/sudoers policy.
//
// /bin/sudo is packed setuid-root in the signed base image (see tools/packfs.swift
// and kernel/security/security.swift `modeSetuid`). On exec the kernel elevates
// this process's *effective* identity to root while preserving the invoker as the
// *real* identity. sudo then:
//   1. reads the real (invoking) identity via security_info_ex;
//   2. looks the invoker up in /etc/swos/passwd (name + salted SHA-256 hash);
//   3. checks /etc/swos/sudoers: is the invoker allowed to run this command?
//   4. prompts for the invoker's own password (Unix default) and verifies it;
//   5. login()s to the target identity (root, or `-u name`) and execve()s the
//      command — which then becomes the process the parent shell is waiting on.
//
// root is always permitted and never prompted. Written in Swift on the
// swift_user.c bridge, like /bin/console-login and /bin/id; SHA-256 comes from
// the shared kernel/crypto/sha256.swift compiled into this binary.

private let storeCap = 4096
private let lineMax = 256
private let nameMax = 64

private let capConsole: UInt = 1 << 0
private let rootCaps: UInt = 63 // console|spawn|fsread|tmpwrite|inspect|net

// ---- small output helpers -------------------------------------------------

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

private func errPuts(_ s: StaticString) {
    s.withUTF8Buffer { b in _ = swiftos_write(2, b.baseAddress!, UInt(b.count)) }
}

private func errBytes(_ p: UnsafePointer<UInt8>, _ len: Int) {
    if len > 0 { _ = swiftos_write(2, UnsafeRawPointer(p), UInt(len)) }
}

// ---- byte / field helpers (passwd & sudoers are colon/space delimited) -----

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

/// Slurp a whole file into `buf` (NUL not appended). Returns bytes read, or -1.
private func readFile(_ path: StaticString, _ buf: UnsafeMutablePointer<UInt8>, _ cap: Int) -> Int {
    var fd: Int32 = -1
    path.withUTF8Buffer { b in
        // The path is a StaticString literal, already NUL-terminated in the binary.
        fd = swiftos_open(UnsafeRawPointer(b.baseAddress!).assumingMemoryBound(to: CChar.self), 0)
    }
    if fd < 0 { return -1 }
    var total = 0
    while total < cap {
        let r = swiftos_read(fd, UnsafeMutableRawPointer(buf + total), UInt(cap - total))
        if r <= 0 { break }
        total += Int(r)
    }
    _ = swiftos_close(fd)
    return total
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

/// True if the NUL-terminated `input` equals store[start..<start+len] exactly.
private func fieldEquals(_ store: UnsafeMutablePointer<UInt8>, _ start: Int, _ len: Int,
                         _ input: UnsafePointer<UInt8>) -> Bool {
    if start < 0 { return false }
    var i = 0
    while i < len {
        if input[i] == 0 || input[i] != store[start + i] { return false }
        i += 1
    }
    return input[i] == 0
}

/// Verify a password against a `salt$sha256hex` field: hash = SHA-256(salt+pass).
private func passwordMatches(_ store: UnsafeMutablePointer<UInt8>, _ fstart: Int, _ flen: Int,
                             _ pass: UnsafeMutablePointer<UInt8>) -> Bool {
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

// ---- passwd / sudoers lookups ---------------------------------------------

/// One parsed passwd account.
private struct Account {
    var found = false
    var nameStart = 0, nameLen = 0
    var principal: UInt32 = 0
    var session: UInt32 = 0
    var caps: UInt = 0
    var passStart = 0, passLen = 0
}

/// Iterate passwd lines, invoking `body(lineStart, lineLen)`; stop when it
/// returns true.
private func forEachLine(_ store: UnsafeMutablePointer<UInt8>, _ total: Int,
                         _ body: (Int, Int) -> Bool) {
    var i = 0
    while i < total {
        var j = i
        while j < total && store[j] != 0x0A { j += 1 }
        let ls = i, ll = j - i
        i = j + 1
        if ll == 0 || store[ls] == 0x23 { continue } // empty or '#'
        if body(ls, ll) { return }
    }
}

/// Parse the passwd line whose field[fieldIndex] matches `match` (a predicate),
/// returning the account.
private func lookupPasswd(_ store: UnsafeMutablePointer<UInt8>, _ total: Int,
                          where match: (Int, Int) -> Bool) -> Account {
    var acct = Account()
    forEachLine(store, total) { ls, ll in
        let f0 = nthField(store, ls, ll, 0)
        let f4 = nthField(store, ls, ll, 4)
        if f4.start < 0 { return false } // not enough fields
        if !match(ls, ll) { return false }
        let f1 = nthField(store, ls, ll, 1)
        let f2 = nthField(store, ls, ll, 2)
        let f3 = nthField(store, ls, ll, 3)
        acct.found = true
        acct.nameStart = f0.start; acct.nameLen = f0.len
        acct.principal = UInt32(truncatingIfNeeded: parseUInt(store, f1.start, f1.len))
        acct.session = UInt32(truncatingIfNeeded: parseUInt(store, f2.start, f2.len))
        acct.caps = UInt(truncatingIfNeeded: parseUInt(store, f3.start, f3.len))
        acct.passStart = f4.start; acct.passLen = f4.len
        return true
    }
    return acct
}

/// True if the StaticString `s` equals store[start..<start+len].
private func tokenEquals(_ store: UnsafeMutablePointer<UInt8>, _ start: Int, _ len: Int,
                         _ s: StaticString) -> Bool {
    var ok = false
    s.withUTF8Buffer { b in
        if b.count != len { ok = false; return }
        var i = 0
        while i < len { if store[start + i] != b[i] { ok = false; return }; i += 1 }
        ok = true
    }
    return ok
}

/// Check /etc/swos/sudoers: is `name` (NUL-terminated) allowed to run the
/// command at `cmd` (NUL-terminated absolute path)? Returns true if permitted.
/// Format per line: `name commands`, commands = ALL or comma-separated paths.
private func sudoersAllows(_ store: UnsafeMutablePointer<UInt8>, _ total: Int,
                           _ name: UnsafePointer<UInt8>, _ cmd: UnsafePointer<UInt8>) -> Bool {
    var allowed = false
    forEachLine(store, total) { ls, ll in
        let end = ls + ll
        // token 0: name (whitespace-delimited)
        var p = ls
        while p < end && (store[p] == 0x20 || store[p] == 0x09) { p += 1 }
        let nameStart = p
        while p < end && store[p] != 0x20 && store[p] != 0x09 { p += 1 }
        let nameLen = p - nameStart
        if !fieldEquals(store, nameStart, nameLen, name) { return false }
        // token 1: commands
        while p < end && (store[p] == 0x20 || store[p] == 0x09) { p += 1 }
        let cmdsStart = p
        while p < end && store[p] != 0x20 && store[p] != 0x09 { p += 1 }
        let cmdsLen = p - cmdsStart
        if cmdsLen == 0 { return true } // matched name, no commands → ALL by leniency
        if tokenEquals(store, cmdsStart, cmdsLen, "ALL") { allowed = true; return true }
        // comma-separated absolute paths: match any against cmd
        var q = cmdsStart
        while q < cmdsStart + cmdsLen {
            let segStart = q
            while q < cmdsStart + cmdsLen && store[q] != 0x2C { q += 1 } // ','
            if fieldEquals(store, segStart, q - segStart, cmd) { allowed = true; return true }
            q += 1
        }
        return true // name matched but command not listed → deny (stop scanning)
    }
    return allowed
}

// ---- main -----------------------------------------------------------------

private func usage() {
    errPuts("usage: sudo [-u user] command [args...]\n")
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = envp
    guard let argv else { usage(); return 1 }

    // Parse a single supported option: -u <user> selects the target identity.
    var ci = 1
    var targetName: UnsafePointer<UInt8>? = nil
    if let a1 = argv[1] {
        let b = UnsafeRawPointer(a1).assumingMemoryBound(to: UInt8.self)
        if b[0] == 0x2D && b[1] == 0x75 && b[2] == 0 { // "-u"
            guard let t = argv[2] else { usage(); return 1 }
            targetName = UnsafePointer(UnsafeRawPointer(t).assumingMemoryBound(to: UInt8.self))
            ci = 3
        }
    }
    guard let cmdArg = argv[ci] else { usage(); return 1 }
    let cmdBytes = UnsafePointer(UnsafeRawPointer(cmdArg).assumingMemoryBound(to: UInt8.self))

    // Effective + real identity. We must be running setuid-root (effective has
    // capConsole) so we can login() to the target; the real identity is the
    // invoker we authenticate.
    var eff: UInt32 = 0, effS: UInt32 = 0, effC: UInt = 0
    var realP: UInt32 = 0, realS: UInt32 = 0, realC: UInt = 0
    if swiftos_context_ex(&eff, &effS, &effC, &realP, &realS, &realC) != 0 {
        errPuts("sudo: cannot read security context\n")
        return 1
    }
    if (effC & capConsole) == 0 {
        errPuts("sudo: not installed setuid root\n")
        return 1
    }

    // Build the resolved absolute command path: bare names resolve under /bin.
    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { pathBuf in
        let path = pathBuf.baseAddress!
        var hasSlash = false
        var n = 0
        while cmdBytes[n] != 0 { if cmdBytes[n] == 0x2F { hasSlash = true }; n += 1 }
        var plen = 0
        if !hasSlash {
            let prefix: [UInt8] = [0x2F, 0x62, 0x69, 0x6E, 0x2F] // "/bin/"
            for c in prefix { path[plen] = c; plen += 1 }
        }
        var k = 0
        while cmdBytes[k] != 0 && plen < lineMax - 1 { path[plen] = cmdBytes[k]; plen += 1; k += 1 }
        path[plen] = 0
        let pathC = UnsafeRawPointer(path).assumingMemoryBound(to: CChar.self)

        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: storeCap) { store in
            let sb = store.baseAddress!
            let total = readFile("/etc/swos/passwd", sb, storeCap)
            if total < 0 {
                errPuts("sudo: cannot read /etc/swos/passwd\n")
                return 1
            }

            // The invoking account, by real principal.
            let invoker = lookupPasswd(sb, total, where: { ls, ll in
                let f1 = nthField(sb, ls, ll, 1)
                return parseUInt(sb, f1.start, f1.len) == UInt64(realP)
            })
            if !invoker.found {
                errPuts("sudo: unknown invoking principal\n")
                return 1
            }

            // Copy the invoker's name out (the store buffer is reused for sudoers).
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: nameMax) { nameBuf in
                let name = nameBuf.baseAddress!
                let nlen = invoker.nameLen < nameMax - 1 ? invoker.nameLen : nameMax - 1
                for j in 0..<nlen { name[j] = sb[invoker.nameStart + j] }
                name[nlen] = 0

                // Resolve the target identity: default root, or -u <user>.
                var tPrincipal: UInt32 = 1
                var tSession: UInt32 = 1
                var tCaps: UInt = rootCaps
                if let tn = targetName {
                    let tgt = lookupPasswd(sb, total, where: { ls, ll in
                        let f0 = nthField(sb, ls, ll, 0)
                        return fieldEquals(sb, f0.start, f0.len, tn)
                    })
                    if !tgt.found {
                        errPuts("sudo: unknown target user\n")
                        return 1
                    }
                    tPrincipal = tgt.principal; tSession = tgt.session; tCaps = tgt.caps
                }

                // Policy + authentication are skipped for root (real principal 1).
                if realP != 1 {
                    // Check /etc/swos/sudoers (reuse `store` after we no longer need
                    // passwd — but we still need the invoker's hash, so copy it first).
                    let passStart = invoker.passStart, passLen = invoker.passLen
                    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 96) { hashBuf in
                        let hb = hashBuf.baseAddress!
                        let hlen = passLen < 95 ? passLen : 95
                        for j in 0..<hlen { hb[j] = sb[passStart + j] }

                        let sudoTotal = readFile("/etc/swos/sudoers", sb, storeCap)
                        if sudoTotal < 0 || !sudoersAllows(sb, sudoTotal, name, path) {
                            errPuts("sudo: ")
                            errBytes(name, nlen)
                            errPuts(" is not allowed to run this command\n")
                            return 1
                        }

                        // Prompt for the invoker's own password (up to 3 tries).
                        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: lineMax) { pass in
                            var tries = 0
                            var authed = false
                            while tries < 3 {
                                errPuts("[sudo] password for ")
                                errBytes(name, nlen)
                                errPuts(": ")
                                swiftos_set_echo(0)
                                let pr = readLine(pass)
                                swiftos_set_echo(1)
                                errPuts("\n")
                                if pr < 0 { return 1 }
                                if passwordMatches(hb, 0, hlen, pass.baseAddress!) {
                                    authed = true
                                    break
                                }
                                errPuts("Sorry, try again.\n")
                                tries += 1
                            }
                            if !authed {
                                errPuts("sudo: authentication failure\n")
                                return 1
                            }
                            return runTarget(tPrincipal, tSession, tCaps, pathC, argv, ci)
                        }
                    }
                }
                return runTarget(tPrincipal, tSession, tCaps, pathC, argv, ci)
            }
        }
    }
}

/// Adopt the target identity and become the command. Does not return on success.
private func runTarget(_ principal: UInt32, _ session: UInt32, _ caps: UInt,
                       _ path: UnsafePointer<CChar>,
                       _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                       _ ci: Int) -> Int32 {
    if swiftos_login(principal, session, caps) != 0 {
        errPuts("sudo: login() to target identity denied\n")
        return 1
    }
    // argv from the command index onward becomes the new argv (argv[0] = the
    // command name the user typed); it is already NULL-terminated.
    let childArgv = argv + ci
    _ = swiftos_execv(path, childArgv)
    errPuts("sudo: command not found\n")
    return 127
}

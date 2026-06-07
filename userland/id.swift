// SPDX-License-Identifier: Apache-2.0
// id.swift — print the calling process's security identity (swift-os).
//
// Reports the kernel security context (principal/session/capability mask) via
// the security_info syscall, and resolves the principal's name from the
// identity store /etc/swos/passwd when readable (needs capFsRead). Capless
// principals still see their numeric context, since security_info touches no FS.

private let storeCap = 4096

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

private func putHex(_ value: UInt64) {
    swiftos_putc(0x30); swiftos_putc(0x78) // "0x"
    if value == 0 { swiftos_putc(0x30); return }
    var started = false
    var shift = 60
    while shift >= 0 {
        let nib = UInt8((value >> UInt64(shift)) & 0xF)
        if nib != 0 || started {
            swiftos_putc(nib < 10 ? 0x30 + nib : 0x61 + (nib - 10))
            started = true
        }
        shift -= 4
    }
}

/// Print the name whose principal field (column 1) equals `principal`, looking
/// it up in /etc/swos/passwd. Returns true if a name was printed.
private func putPrincipalName(_ principal: UInt32) -> Bool {
    let fd = swiftos_open("/etc/swos/passwd", 0)
    if fd < 0 { return false } // unreadable (e.g. no capFsRead)
    var found = false
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: storeCap) { buf in
        let base = buf.baseAddress!
        var total = 0
        while total < storeCap - 1 {
            let r = swiftos_read(fd, UnsafeMutableRawPointer(base + total), UInt(storeCap - 1 - total))
            if r <= 0 { break }
            total += Int(r)
        }
        _ = swiftos_close(fd)

        var i = 0
        while i < total && !found {
            var j = i
            while j < total && base[j] != 0x0A { j += 1 }
            let ls = i, ll = j - i
            i = j + 1
            if ll == 0 || base[ls] == 0x23 { continue } // empty or '#'

            // field 0 = name, field 1 = principal (decimal).
            var c0e = ls
            while c0e < ls + ll && base[c0e] != 0x3A { c0e += 1 }
            var c1s = c0e + 1
            var c1e = c1s
            while c1e < ls + ll && base[c1e] != 0x3A { c1e += 1 }

            var p: UInt32 = 0
            var k = c1s
            while k < c1e { p = p * 10 + UInt32(base[k] - 0x30); k += 1 }
            if p == principal {
                swiftos_putc(0x28) // "("
                k = ls
                while k < c0e { swiftos_putc(base[k]); k += 1 }
                swiftos_putc(0x29) // ")"
                found = true
            }
        }
    }
    return found
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    var principal: UInt32 = 0, session: UInt32 = 0, caps: UInt = 0
    if swiftos_context(&principal, &session, &caps) != 0 {
        swiftos_puts("id: security_info failed\n")
        return 1
    }

    swiftos_puts("principal=")
    putUInt(UInt64(principal))
    _ = putPrincipalName(principal) // appends "(name)" when the store is readable
    swiftos_puts(" session=")
    putUInt(UInt64(session))
    swiftos_puts(" caps=")
    putHex(UInt64(caps))
    swiftos_puts("\n")
    return 0
}

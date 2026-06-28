// SPDX-License-Identifier: Apache-2.0
// mountprobe.swift — V3 runtime mount/unmount driver for the v3-mount-test gate.
//
// Invokes the capability-gated SYS_mount / SYS_unmount via the userland bridge and
// prints the raw return code so the boot test can assert on it. Usage:
//   mountprobe mount    <selector> <mountpoint> [ro|persist|format]
//   mountprobe unmount  <mountpoint>
//   mountprobe denytest <selector> <mountpoint>   (drop capConsole; expect EACCES)
// `selector` names a datafs volume by 32-hex UUID or by label; `mountpoint` must
// be /mnt/<name>. The verb's rc is reported as `MP: <verb> rc=<n>` (a negative n
// is a -errno: -13 EACCES, -2 ENOENT, -16 EBUSY, -22 EINVAL).

// Flag bits — must match SWIFTOS_MOUNT_* in userland/lib/syscall.h.
private let mountRO: UInt = 0x1
private let mountPersist: UInt = 0x2
private let mountFormatIfBlank: UInt = 0x4

private func putUInt(_ value: UInt) {
    if value == 0 { swiftos_putc(0x30); return }
    var digits = [UInt8](repeating: 0, count: 20)
    var n = value
    var count = 0
    while n > 0 {
        digits[count] = UInt8(0x30 + Int(n % 10))
        n /= 10
        count += 1
    }
    while count > 0 {
        count -= 1
        swiftos_putc(digits[count])
    }
}

private func putInt(_ value: Int) {
    if value < 0 { swiftos_putc(0x2D); putUInt(UInt(-value)); return }   // '-'
    putUInt(UInt(value))
}

// Compare a NUL-terminated C string to a StaticString, byte for byte.
private func streq(_ p: UnsafePointer<CChar>, _ s: StaticString) -> Bool {
    var match = true
    s.withUTF8Buffer { b in
        var i = 0
        while i < b.count {
            if UInt8(bitPattern: p[i]) != b[i] { match = false; return }
            i += 1
        }
        if p[b.count] != 0 { match = false }   // C string must end exactly here
    }
    return match
}

private func reportRC(_ verb: StaticString, _ rc: Int32) {
    swiftos_puts("MP: ")
    verb.withUTF8Buffer { b in for c in b { swiftos_putc(c) } }
    swiftos_puts(" rc=")
    putInt(Int(rc))
    swiftos_putc(0x0A)
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp
    guard let argv = argv, argc >= 2, let verb = argv[1] else {
        swiftos_puts("MP: usage: mountprobe mount <selector> <mountpoint> [ro|persist|format] | mountprobe unmount <mountpoint>\n")
        return 2
    }

    if streq(verb, "mount") {
        guard argc >= 4, let selector = argv[2], let mountpoint = argv[3] else {
            swiftos_puts("MP: mount needs <selector> <mountpoint>\n")
            return 2
        }
        var flags: UInt = 0
        if argc >= 5, let mode = argv[4] {
            if streq(mode, "ro") { flags |= mountRO }
            else if streq(mode, "persist") { flags |= mountPersist }
            else if streq(mode, "format") { flags |= mountFormatIfBlank }
        }
        let rc = swiftos_mount(UnsafePointer(selector), UnsafePointer(mountpoint), flags)
        reportRC("mount", rc)
        return rc == 0 ? 0 : 1
    }

    if streq(verb, "unmount") {
        guard argc >= 3, let mountpoint = argv[2] else {
            swiftos_puts("MP: unmount needs <mountpoint>\n")
            return 2
        }
        let rc = swiftos_unmount(UnsafePointer(mountpoint))
        reportRC("unmount", rc)
        return rc == 0 ? 0 : 1
    }

    // V3c: prove the capability gate. Drop capConsole (login to a non-console
    // principal that still holds the other root caps), then mount + unmount must
    // both be refused with EACCES (-13). Usage: mountprobe denytest <sel> <mp>.
    if streq(verb, "denytest") {
        guard argc >= 4, let selector = argv[2], let mountpoint = argv[3] else {
            swiftos_puts("MP: denytest needs <selector> <mountpoint>\n")
            return 2
        }
        // capAllRoot without capConsole (bit 0) — see kernel/security/security.swift.
        let noConsole: UInt = 0x3E
        if swiftos_login(2, 2, noConsole) != 0 {
            swiftos_puts("MP: denytest could not drop privilege (login failed)\n")
            return 1
        }
        let mrc = swiftos_mount(UnsafePointer(selector), UnsafePointer(mountpoint), 0)
        reportRC("mount", mrc)
        let urc = swiftos_unmount(UnsafePointer(mountpoint))
        reportRC("unmount", urc)
        // EACCES = -13. Success means BOTH were refused with exactly that.
        return (mrc == -13 && urc == -13) ? 0 : 1
    }

    swiftos_puts("MP: unknown verb (expected mount|unmount|denytest)\n")
    return 2
}

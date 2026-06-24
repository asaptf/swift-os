// SPDX-License-Identifier: Apache-2.0
// ptyprobe.swift — native Swift self-test for the HC34 pseudo-terminal object.
//
// Allocates a PTY pair via openpty() and exercises the line discipline end to
// end from userland: canonical line assembly (master write -> slave read),
// echo back to the master, ONLCR on slave output (slave write -> master read),
// backspace editing, and EOF when the master end closes. Prints one "ptyprobe:
// ... OK" marker per check and a final "PTYPROBE-OK"; tests/pty_test.sh asserts
// on these lines.

private func fail(_ msg: StaticString) {
    swiftos_puts("ptyprobe: FAIL ")
    msg.withUTF8Buffer { b in for c in b { swiftos_putc(c) } }
    swiftos_putc(0x0A)
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    return bytes.withUnsafeBufferPointer { buf in
        while off < buf.count {
            let n = swiftos_write(fd, buf.baseAddress! + off, UInt(buf.count - off))
            if n <= 0 { return false }
            off += Int(n)
        }
        return true
    }
}

// Read exactly `count` bytes into `out` (count <= out.count). Returns false on
// short read / EOF / error.
private func readExact(_ fd: Int32, _ out: inout [UInt8], _ count: Int) -> Bool {
    var off = 0
    return out.withUnsafeMutableBufferPointer { buf in
        while off < count {
            let n = swiftos_read(fd, buf.baseAddress! + off, UInt(count - off))
            if n <= 0 { return false }
            off += Int(n)
        }
        return true
    }
}

private func equals(_ a: [UInt8], _ n: Int, _ b: [UInt8]) -> Bool {
    if n != b.count { return false }
    for i in 0..<n where a[i] != b[i] { return false }
    return true
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    var master: Int32 = -1
    var slave: Int32 = -1
    if swiftos_openpty(&master, &slave) != 0 || master < 0 || slave < 0 {
        fail("openpty failed"); return 1
    }

    var buf = [UInt8](repeating: 0, count: 32)

    // 1) Canonical line: master write "hello\n" -> slave reads cooked "hello\n".
    if !writeAll(master, [0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x0A]) { fail("master write"); return 1 }
    if !readExact(slave, &buf, 6) || !equals(buf, 6, [0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x0A]) {
        fail("canonical line"); return 1
    }
    swiftos_puts("ptyprobe: canonical line OK\n")

    // 2) Echo: the same write echoed "hello\r\n" back to the master.
    if !readExact(master, &buf, 7) ||
        !equals(buf, 7, [0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x0D, 0x0A]) {
        fail("echo"); return 1
    }
    swiftos_puts("ptyprobe: echo OK\n")

    // 3) ONLCR: slave write "world\n" -> master reads "world\r\n".
    if !writeAll(slave, [0x77, 0x6F, 0x72, 0x6C, 0x64, 0x0A]) { fail("slave write"); return 1 }
    if !readExact(master, &buf, 7) ||
        !equals(buf, 7, [0x77, 0x6F, 0x72, 0x6C, 0x64, 0x0D, 0x0A]) {
        fail("onlcr"); return 1
    }
    swiftos_puts("ptyprobe: slave output ONLCR OK\n")

    // 4) Backspace editing: "ab\bc\n" -> cooked "ac\n".
    if !writeAll(master, [0x61, 0x62, 0x08, 0x63, 0x0A]) { fail("master write 2"); return 1 }
    if !readExact(slave, &buf, 3) || !equals(buf, 3, [0x61, 0x63, 0x0A]) {
        fail("backspace"); return 1
    }
    swiftos_puts("ptyprobe: backspace OK\n")
    // Drain the echo bytes the edit produced so they don't linger.
    _ = swiftos_read(master, &buf, UInt(buf.count))

    // 5) termios per-fd routing: tcsetattr on the pty slave must change THIS
    // pty's line-discipline flags, not the console's. Before the fix, tcget/
    // tcsetattr ignored the fd and always touched the global console lflag, so a
    // program on a pty (mc over sshd) that switched to raw mode flipped the
    // console while its own pty stayed canonical. We only ever read fd 0 here.
    let icanon: UInt32 = 1 << 0
    let consoleBefore = swiftos_tcget_lflag(0)
    let slaveDefault = swiftos_tcget_lflag(slave)   // a fresh pty: ICANON|ECHO|ISIG
    _ = swiftos_tcset_lflag(slave, 0)               // clear all flags on the slave
    let slaveAfter = swiftos_tcget_lflag(slave)
    let consoleAfter = swiftos_tcget_lflag(0)
    if (slaveDefault & icanon) == 0 { fail("pty slave default lflag missing ICANON"); return 1 }
    if slaveAfter != 0 { fail("tcsetattr on pty slave had no effect"); return 1 }
    if consoleAfter != consoleBefore { fail("tcsetattr on pty slave clobbered the console"); return 1 }
    swiftos_puts("ptyprobe: termios per-fd routing OK\n")

    // 6) EOF: closing the master makes a subsequent slave read return 0.
    _ = swiftos_close(master)
    let n = swiftos_read(slave, &buf, UInt(buf.count))
    if n != 0 { fail("slave EOF"); return 1 }
    swiftos_puts("ptyprobe: slave EOF OK\n")
    _ = swiftos_close(slave)

    swiftos_puts("PTYPROBE-OK\n")
    return 0
}

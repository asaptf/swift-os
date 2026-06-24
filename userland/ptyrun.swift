// SPDX-License-Identifier: Apache-2.0
// ptyrun.swift — run a program on a pseudo-terminal slave and report how it
// exits. This mirrors the EXACT path /bin/sshd uses for an interactive session
// (openpty + swiftos_pty_spawn_shell), so it reproduces "run MC on a PTY" — the
// way the box is reached over SSH — without needing the network or an SSH
// client. It exists to debug Midnight Commander crashing immediately on launch
// over SSH while it runs fine on the serial console (`make mc-test`).
//
// Usage: /bin/ptyrun [program]      (default: /bin/mc)
//
// Prints "PTYRUN:" markers. If the child is killed by a signal (e.g. SIGSEGV)
// the kernel ALSO logs "EL0 fault -> terminate proc by signal <n> ESR_EL1=...
// ELR_EL1=... FAR_EL1=..." to the console, which pinpoints the faulting PC and
// address for postmortem against the program's symbol table.

private func putDec(_ v: UInt32) {
    if v == 0 { swiftos_putc(0x30); return }
    var digits = [UInt8](repeating: 0, count: 10)
    var n = v
    var i = 0
    while n > 0 { digits[i] = UInt8(0x30 + Int(n % 10)); n /= 10; i += 1 }
    while i > 0 { i -= 1; swiftos_putc(digits[i]) }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = envp

    var master: Int32 = -1
    var slave: Int32 = -1
    if swiftos_openpty(&master, &slave) != 0 || master < 0 || slave < 0 {
        swiftos_puts("PTYRUN: openpty failed\n"); return 1
    }

    swiftos_puts("PTYRUN: spawning child on pty slave\n")
    let pid: Int32
    if argc > 1, let prog = argv?[1] {
        pid = swiftos_pty_spawn_shell(prog, slave)
    } else {
        pid = swiftos_pty_spawn_shell("/bin/mc", slave)
    }
    if pid <= 0 { swiftos_puts("PTYRUN: spawn failed\n"); return 1 }

    // Parent drops its slave reference so read(master) returns EOF once the
    // child closes the slave (i.e. exits or is killed).
    _ = swiftos_close(slave)

    // Best-effort drive sequence so a HEALTHY MC quits instead of blocking on
    // input: Enter (dismiss the one-time "Default skin has been loaded"
    // dialog), then ESC '0' (== F10, Quit), then Enter (confirm). Harmless if
    // the child already crashed on launch — the bytes just sit unread.
    let drive: [UInt8] = [0x0D, 0x1B, 0x30, 0x0D]
    _ = drive.withUnsafeBufferPointer { swiftos_write(master, $0.baseAddress!, UInt($0.count)) }

    // Relay child output to our stdout (also keeps the PTY output ring from
    // filling and blocking the child) until the slave side closes.
    var buf = [UInt8](repeating: 0, count: 256)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { swiftos_read(master, $0.baseAddress!, UInt($0.count)) }
        if n <= 0 { break }
        _ = buf.withUnsafeBufferPointer { swiftos_write(1, $0.baseAddress!, UInt(n)) }
    }

    var status: Int32 = 0
    _ = swiftos_waitpid(pid, &status)
    let st = UInt32(bitPattern: status)
    // waitpid status encoding (kernel/user/process.swift): killed-by-signal ->
    // the bare signal number (< 128); clean/erroring exit -> (exitcode << 8).
    if st == 0 {
        swiftos_puts("PTYRUN: child exited cleanly (status 0)\n")
    } else if st < 128 {
        swiftos_puts("PTYRUN: child KILLED by signal ")
        putDec(st)
        swiftos_puts(" (11=SIGSEGV 4=SIGILL 7=SIGBUS 5=SIGTRAP 6=SIGABRT)\n")
    } else {
        swiftos_puts("PTYRUN: child exited code ")
        putDec(st >> 8)
        swiftos_puts("\n")
    }
    swiftos_puts("PTYRUN-DONE\n")
    return 0
}

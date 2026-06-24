// SPDX-License-Identifier: Apache-2.0
// cellnsprobe.swift — C6c per-cell namespace-root supervisor probe.
//
// Runs as a capConsole boot principal in globalCell (unconfined). It proves the
// C6c namespace model:
//   1. the default cell is unconfined — the supervisor can open /etc/motd;
//   2. cell_create("/www", ...) makes a cell whose VFS root is /www;
//   3. a child launched into that cell (/bin/cellnschild) is confined: a file
//      inside /www resolves, but /etc and the global root are refused — the child
//      exits 0 only if every namespace check held.
// The boot test (tests/c6_cell_namespace_test.sh) asserts on the "C6c OK" marker.

private let rightWrite: UInt32 = 1 << 1

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

// Launch /bin/cellnschild into `cellFd`, handing it the supervisor's stdout (fd 1)
// so its CELLNS markers reach the console. Returns the child pid or <0.
private func spawnChildIntoCell(cellFd: Int32) -> Int {
    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 16) { nameBuf -> Int in
        let name = nameBuf.baseAddress!
        var i = 0
        for c in "cellnschild".utf8 { name[i] = CChar(bitPattern: c); i += 1 }
        name[i] = 0
        return withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: 2) { argv -> Int in
            argv[0] = name; argv[1] = nil
            return withUnsafeTemporaryAllocation(byteCount: 16, alignment: 4) { specs -> Int in
                let sp = specs.baseAddress!
                sp.storeBytes(of: Int32(1), toByteOffset: 0, as: Int32.self)   // src fd 1
                sp.storeBytes(of: Int32(1), toByteOffset: 4, as: Int32.self)   // dst fd 1
                sp.storeBytes(of: rightWrite, toByteOffset: 8, as: UInt32.self)
                sp.storeBytes(of: UInt32(0), toByteOffset: 12, as: UInt32.self)
                return Int(swiftos_cell_spawn(cellFd, "/bin/cellnschild",
                            UnsafeMutableRawPointer(argv.baseAddress!), sp, 1))
            }
        }
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    // 1. Default cell is unconfined: the supervisor (globalCell) can reach /etc.
    let f = swiftos_open("/etc/motd", 0)
    if f < 0 {
        swiftos_puts("C6c FAIL: default cell was unexpectedly confined\n")
        return 1
    }
    _ = swiftos_close(f)
    swiftos_puts("C6c probe: default cell unconfined (/etc/motd readable)\n")

    // 2. Create a cell rooted at /www.
    var cell: UInt32 = 0
    let cellFd = swiftos_cell_create("/www", 0, &cell)
    if cellFd < 0 || cell < 2 {
        swiftos_puts("C6c FAIL: cell_create(/www) did not return a fresh cell + handle\n")
        return 1
    }
    swiftos_puts("C6c probe: created cell=")
    putUInt(UInt(cell))
    swiftos_puts(" rooted at /www\n")

    // 3. Launch the child into the cell and require a clean (exit 0) namespace report.
    let childPid = spawnChildIntoCell(cellFd: cellFd)
    if childPid <= 0 {
        swiftos_puts("C6c FAIL: cell_spawn into the rooted cell failed\n")
        return 1
    }
    var status: Int32 = 0
    _ = swiftos_waitpid(Int32(childPid), &status)
    let exitCode = (Int(status) >> 8) & 0xff
    if exitCode != 0 {
        swiftos_puts("C6c FAIL: child reported a namespace violation\n")
        return 1
    }

    swiftos_puts("C6c OK: cell namespace root confined the child; default cell unconfined\n")
    return 0
}

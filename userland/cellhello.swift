// SPDX-License-Identifier: Apache-2.0
// cellhello.swift — a real request/reply service hosted inside a C6 cell.
//
// This is the C6e payoff workload: a small IPC service launched by a cell
// supervisor INTO a cell that confines its namespace, restricts its handles, and
// caps its resources. On startup it proves its own isolation, then serves "ping"
// requests with a "pong" reply over the granted endpoints until told to stop.
//
// Handles it is GRANTED (and nothing else — explicit inheritance via cell_spawn):
//   fd 1 = stdout, fd 3 = command recv end, fd 4 = reply send end.
// It deliberately holds no fd 0, no device grant, no ambient authority.

private let cmdRecvFD: Int32 = 3
private let replySendFD: Int32 = 4

private func is4(_ buf: UnsafeMutablePointer<UInt8>, _ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
    buf[0] == a && buf[1] == b && buf[2] == c && buf[3] == d
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp

    // Isolation proof 1 — confined namespace: a path outside the cell root is denied.
    let escFd = swiftos_open("/etc/motd", 0)
    if escFd >= 0 {
        _ = swiftos_close(escFd)
        swiftos_puts("CELLHELLO FAIL: escaped the cell root\n")
        return 1
    }
    swiftos_puts("CELLHELLO: namespace confined (/etc denied)\n")

    // Isolation proof 2 — restricted handles: it was never granted fd 0, so a read
    // of it must fail (no ambient authority leaked in).
    var probe: UInt8 = 0
    if swiftos_read(0, &probe, 1) >= 0 {
        swiftos_puts("CELLHELLO FAIL: held an ungranted handle (fd 0)\n")
        return 1
    }
    swiftos_puts("CELLHELLO: only granted handles (no ambient fd 0)\n")
    swiftos_puts("CELLHELLO: serving on the granted endpoint\n")

    // Serve loop: reply "pong" to any request; exit on "stop" or endpoint EOF.
    var running = true
    while running {
        running = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buf -> Bool in
            var handle: Int32 = -1
            let n = swiftos_ipc_recv(cmdRecvFD, buf.baseAddress!, 32, &handle)
            if handle >= 0 { _ = swiftos_close(handle) }
            if n < 0 { return false } // endpoint closed → stop
            if n == 4 && is4(buf.baseAddress!, UInt8(ascii: "s"), UInt8(ascii: "t"),
                             UInt8(ascii: "o"), UInt8(ascii: "p")) {
                return false
            }
            let reply: StaticString = "pong"
            reply.withUTF8Buffer { c in
                _ = swiftos_ipc_send(replySendFD, c.baseAddress!, UInt(c.count), -1)
            }
            return true
        }
    }
    swiftos_puts("CELLHELLO: stopped\n")
    return 0
}

// SPDX-License-Identifier: Apache-2.0
// cell-svc.swift — the demo request/reply service the C7c persistent cell supervisor
// (/bin/cell-supervisor) hosts inside a cell, one generation at a time.
//
// It is deliberately small; C7c is about the supervisor's restart/FDIR machinery, not
// the service. argv[1] selects a mode so the supervisor can drive both a healthy
// generation and a crash loop deterministically:
//   "serve" — reply "pong" to "ping" over the granted endpoints; exit 7 on "die"
//             (a simulated fault the supervisor detects via waitpid), 0 on "stop"/EOF.
//   "crash" — exit 9 immediately, before serving (the bounded-restart / crash-loop case).
//
// Handles it is GRANTED in serve mode (explicit inheritance via cell_spawn, nothing
// else): fd 1 = stdout, fd 3 = command recv end, fd 4 = reply send end.

private let cmdRecvFD: Int32 = 3
private let replySendFD: Int32 = 4
private let exitFault: Int32 = 7    // "die" — a simulated crash the supervisor detects
private let exitCrash: Int32 = 9    // crash-mode immediate failure

private func eq(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int, _ want: StaticString) -> Bool {
    var ok = false
    want.withUTF8Buffer { w in
        if n != w.count { ok = false; return }
        var i = 0
        while i < w.count { if buf[i] != w[i] { ok = false; return }; i += 1 }
        ok = true
    }
    return ok
}

private func argIs(_ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ want: StaticString) -> Bool {
    guard let a = argv, let s = a[1] else { return false }
    var ok = false
    want.withUTF8Buffer { w in
        var i = 0
        while i < w.count {
            if s[i] == 0 || UInt8(bitPattern: s[i]) != w[i] { ok = false; return }
            i += 1
        }
        ok = s[w.count] == 0
    }
    return ok
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = envp

    // Crash mode: fail immediately, before serving — the supervisor's crash-loop case.
    if argIs(argv, "crash") {
        swiftos_puts("CELLSVC: crash mode, exiting immediately\n")
        return exitCrash
    }

    swiftos_puts("CELLSVC: serving on the granted endpoint\n")

    // Serve loop: reply "pong" to "ping"; exit on "die" (fault) / "stop" / endpoint EOF.
    while true {
        let verdict = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { buf -> Int32 in
            var handle: Int32 = -1
            let n = swiftos_ipc_recv(cmdRecvFD, buf.baseAddress!, 32, &handle)
            if handle >= 0 { _ = swiftos_close(handle) }
            if n < 0 { return 0 } // endpoint closed → clean exit
            if eq(buf.baseAddress!, Int(n), "die") {
                swiftos_puts("CELLSVC: die (simulated fault)\n")
                return exitFault
            }
            if eq(buf.baseAddress!, Int(n), "stop") { return 0 }
            let reply: StaticString = "pong"
            reply.withUTF8Buffer { c in
                _ = swiftos_ipc_send(replySendFD, c.baseAddress!, UInt(c.count), -1)
            }
            return -1 // sentinel: keep serving
        }
        if verdict >= 0 { return verdict }
    }
}

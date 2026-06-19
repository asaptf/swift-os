// SPDX-License-Identifier: Apache-2.0
// userland_service.swift — reusable receive-loop skeleton for native Swift
// userland services (LA1), in the L4/seL4-family "single UserlandService
// protocol + default run() loop" shape. A service author conforms to
// UserlandService and implements ONLY handle(); the default run() owns the
// ipc_recv → dispatch → ipc_send receive loop.
//
// Embedded Swift discipline: UserlandService is used ONLY as a generic
// constraint (run() is generic over Self), so it monomorphizes with no
// existential boxing, no reflection, and no per-request ARC. The loop is
// allocation-free — two reused stack buffers, Unsafe* pointers only.

// Matches the kernel endpoint message slot (endpointMsgCap in vfs.swift).
let userlandServiceBufCap = 256

protocol UserlandService {
    // The author implements only this. `command`/`reply` are caller-owned stack
    // buffers (never escape); `receivedHandle` is any transferred handle's fd
    // (-1 if none — the handler owns closing it). Return value convention:
    //   >= 0 : number of reply bytes to send on replyFD (0 = send nothing), keep looping.
    //   <  0 : stop the loop. run() returns the exit code encoded as (-1 - value),
    //          so return -1 => exit 0, and return -(code + 1) => exit `code`.
    mutating func handle(command: UnsafePointer<UInt8>, count: Int,
                         reply: UnsafeMutablePointer<UInt8>, replyCap: Int,
                         receivedHandle: Int32) -> Int
}

extension UserlandService {
    // Default receive loop. Generic over Self, so it inlines the concrete
    // handle() with no dynamic dispatch. Allocation-free: one stack region split
    // into a command buffer and a reply buffer, reused for every request.
    mutating func run(commandFD: Int32, replyFD: Int32) -> Int32 {
        return withUnsafeTemporaryAllocation(of: UInt8.self,
                                             capacity: userlandServiceBufCap * 2) { scratch -> Int32 in
            let cmd = scratch.baseAddress!
            let reply = cmd + userlandServiceBufCap
            while true {
                var received: Int32 = -1
                let n = swiftos_ipc_recv(commandFD, cmd, UInt(userlandServiceBufCap), &received)
                if n < 0 {
                    // The command channel closed or errored (e.g. the supervisor
                    // went away): stop the loop cleanly.
                    return 0
                }
                let r = handle(command: cmd, count: Int(n), reply: reply,
                               replyCap: userlandServiceBufCap, receivedHandle: received)
                if r < 0 {
                    return Int32(truncatingIfNeeded: (-r) - 1)
                }
                if r > 0 {
                    _ = swiftos_ipc_send(replyFD, reply, UInt(r), -1)
                }
            }
        }
    }
}

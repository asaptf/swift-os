// SPDX-License-Identifier: Apache-2.0
// sctld.swift — the SwiftCube control-plane daemon (/bin/sctld), SC2.
//
// sctld embeds cubestore and the control plane (the Controller: token-authenticated
// join + CA-signed mTLS identity, TTL leases, the leader-gated reaper, and the
// framed/resumable watch wire). Its production form serves the SC2 RPCs to remote
// `slet` agents over mTLS-TCP; that real-NIC server loop (bind/listen/accept +
// swiftos_read/write driving the MutualTLS engine) is the daemon-ization seam
// recorded in FORMAT.md, paired with the SC2b Raft peer transport over the same
// TLS + framing.
//
// For the SC2 on-device acceptance gate this binary runs the in-process self-test
// (sc2BootSelfTest): a full join → register → heartbeat → expiry → watch lifecycle
// over the real MutualTLS engine with an injected clock, printing markers the QEMU
// boot assertion greps. Built on the swift_user bridge like /bin/tlsget.

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    swiftos_puts("sctld: SwiftCube control plane (SC2) — running on-device acceptance self-test\n")
    let rc = sc2BootSelfTest()
    if rc == 0 { swiftos_puts("sctld: self-test OK\n") } else { swiftos_puts("sctld: self-test FAILED\n") }
    return rc
}

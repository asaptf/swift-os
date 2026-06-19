// SPDX-License-Identifier: Apache-2.0
// slet.swift — the SwiftCube node agent (/bin/slet), SC2.
//
// slet is the per-node agent: it joins a controller with a bootstrap token, gets a
// CA-signed node certificate, registers a Node + lease, and keeps the lease alive
// by heartbeat while watching its assignments (SC3+). Its production form connects
// to a remote `sctld` over mTLS-TCP (swiftos_socket_stream / connect + the
// MutualTLS engine over swiftos_read/write); that real-NIC client loop is the
// daemon-ization seam recorded in FORMAT.md.
//
// For SC2 this binary boots and exercises the node-side identity path on-device —
// generate an EC P-256 key, build a PKCS#10 CSR (proof of possession), and verify
// it parses back to the same key — proving the agent's crypto/identity code runs
// under Embedded Swift on real aarch64. The end-to-end join/register/lease
// lifecycle is exercised by /bin/sctld's self-test. Built on the swift_user bridge.

private func bootRNG(_ buf: inout [UInt8]) {
    buf.withUnsafeMutableBytes { p in
        if let a = p.baseAddress, p.count > 0 { _ = swiftos_random(a, UInt(p.count)) }
    }
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    swiftos_puts("slet: SwiftCube node agent (SC2) — node identity self-check\n")

    guard let key = generateECKeyPair(bootRNG) else { swiftos_puts("slet: FAIL keygen\n"); return 1 }
    guard let csr = acmeCSR(dnsNames: [Array("node-1".utf8)], pubX: key.pubX, pubY: key.pubY, priv32: key.priv) else {
        swiftos_puts("slet: FAIL csr\n"); return 1
    }
    guard let parsed = parseAndVerifyCSR(csr), parsed.point65 == key.point65 else {
        swiftos_puts("slet: FAIL csr-verify\n"); return 1
    }
    swiftos_puts("slet: node identity OK (P-256 key + verified CSR)\n")
    return 0
}

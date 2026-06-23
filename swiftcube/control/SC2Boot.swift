// SPDX-License-Identifier: Apache-2.0
// SC2Boot.swift — on-device SC2 acceptance self-test (QEMU boot gate, case 8).
//
// This is the swift-os/Embedded-Swift counterpart of the host control-test: it
// drives the FULL SC2 control plane — bootstrap-token join + CA-signed mTLS
// identity, TTL leases, the leader-gated reaper, and the framed/resumable watch
// wire — end to end inside one booted userland process, proving every piece (the
// TLS 1.3 mutual handshake, ECDSA-P256 / X25519 / ChaCha20-Poly1305, X.509
// issuance, cubestore, leases) runs under Embedded Swift on real aarch64 in QEMU.
//
// Entropy is the kernel CSPRNG (swiftos_random); the clock is injected (a
// ManualClock advanced by hand) so lease expiry is observed deterministically
// without waiting on the wall clock. The mTLS bytes move over an in-process
// loopback channel rather than virtio-net: guest-local TCP cannot loop back
// through QEMU slirp, so the real-NIC split-process transport (sctld server fd +
// slet client fd over swiftos_read/write) is the daemon-ization seam documented
// in FORMAT.md — the same byte pump, bridged to a socket. Markers are printed on
// the serial console for the boot assertion to grep. This file uses the swift_user
// bridge (swiftos_puts/swiftos_random); it is NOT part of the host control-test.

/// Fill `buf` from the kernel CSPRNG.
private func bootRNG(_ buf: inout [UInt8]) {
    buf.withUnsafeMutableBytes { p in
        if let a = p.baseAddress, p.count > 0 { _ = swiftos_random(a, UInt(p.count)) }
    }
}

/// Run the SC2 acceptance self-test. Returns 0 on PASS, 1 on the first failure.
func sc2BootSelfTest() -> Int32 {
    let base: UInt64 = 1_700_000_000
    let clock = ManualClock(base)
    let nb = base &- 1000
    let na = base &+ 10 &* 365 &* 24 &* 3600

    // CA + controller TLS server identity.
    guard let ca = ControllerCA.create(commonName: "swiftcube-ca", notBefore: nb, notAfter: na,
                                        serial: [0xCA, 0x01], bootRNG) else {
        swiftos_puts("SC2: FAIL ca\n"); return 1
    }
    guard let serverKey = generateECKeyPair(bootRNG),
          let serverCert = ca.sign(subjectCN: "sctld", sanDNS: "sctld",
                                    subjectKeyPoint65: serverKey.point65, serial: [0x53],
                                    notBefore: nb, notAfter: na),
          let caRoot = parseX509(ca.caCertDER) else {
        swiftos_puts("SC2: FAIL server-cert\n"); return 1
    }
    let serverId = TLSIdentity(certChain: [serverCert], privateKey: serverKey.priv)
    let controller = Controller(store: openRamCubeStore(), ca: ca, clock: clock, bootRNG)

    func nowYMD() -> UInt64 { unixToYYYYMMDDHHMMSS(clock.nowSeconds()) }
    func serverChannel() -> TLSChannel {
        TLSChannel(MutualTLS(role: .server,
                             config: TLSConfig(identity: serverId, caRoots: [caRoot],
                                               now: nowYMD(), requireClientCert: false), bootRNG))
    }
    func pump(_ c: TLSChannel, _ s: TLSChannel) {
        for _ in 0..<800 {
            var moved = false
            let x = c.takeWire(); if !x.isEmpty { s.feedWire(x); moved = true }
            while let f = s.nextFrame() { controller.process(frame: f, channel: s); moved = true }
            let y = s.takeWire(); if !y.isEmpty { c.feedWire(y); moved = true }
            if !moved { break }
        }
    }
    func connect(_ cfg: TLSConfig) -> (TLSChannel, TLSChannel) {
        let c = TLSChannel(MutualTLS(role: .client, config: cfg, bootRNG))
        let s = serverChannel()
        c.start(); s.start(); pump(c, s)
        return (c, s)
    }

    guard let agent = Agent(nodeName: "node-1", caCertDER: ca.caCertDER, serverName: "sctld", bootRNG) else {
        swiftos_puts("SC2: FAIL agent\n"); return 1
    }
    let token = controller.tokens.create(ttlSeconds: 3600, uses: 1, bootRNG).presented

    // Join (token-authenticated, server cert verified, no client cert yet).
    let (jc, js) = connect(agent.bootstrapClientConfig(now: nowYMD()))
    if !(jc.handshakeComplete && js.handshakeComplete) { swiftos_puts("SC2: FAIL join-handshake\n"); return 1 }
    guard let id = agent.join(channel: jc, token: token, { pump(jc, js) }), id == "node-1" else {
        swiftos_puts("SC2: FAIL join\n"); return 1
    }
    swiftos_puts("SC2: cert issued for node-1\n")

    // Watch /nodes/ over full mTLS (registered before register, to see the live add).
    let (wc, ws) = connect(agent.mutualClientConfig(now: nowYMD()))
    if ws.peerIdentity != "node-1" { swiftos_puts("SC2: FAIL mtls-auth\n"); return 1 }
    swiftos_puts("SC2: mTLS authenticated node-1\n")
    _ = agent.startWatch(channel: wc, start: CubeKeys.nodesPrefix,
                         end: prefixEnd(CubeKeys.nodesPrefix), from: 0, { pump(wc, ws) })

    // Register → node + lease appear.
    let (rc, rs) = connect(agent.mutualClientConfig(now: nowYMD()))
    guard agent.register(channel: rc, address: "10.0.2.15:7700", ttlSeconds: 30, { pump(rc, rs) }) != nil else {
        swiftos_puts("SC2: FAIL register\n"); return 1
    }
    if controller.store.get(CubeKeys.node("node-1")) == nil { swiftos_puts("SC2: FAIL node-absent\n"); return 1 }
    swiftos_puts("SC2: node-1 registered (lease granted)\n")

    // Watch sees the add.
    pump(wc, ws)
    var sawAdd = false
    for e in agent.drainWatchEvents(channel: wc) {
        if case .put = e.kind, e.key == CubeKeys.node("node-1") { sawAdd = true }
    }
    if !sawAdd { swiftos_puts("SC2: FAIL watch-add\n"); return 1 }
    swiftos_puts("SC2: watch observed node-1 add\n")

    // Heartbeat renews the lease.
    clock.advance(10)
    let (hc, hs) = connect(agent.mutualClientConfig(now: nowYMD()))
    guard let hb = agent.heartbeat(channel: hc, { pump(hc, hs) }), hb.alive else {
        swiftos_puts("SC2: FAIL heartbeat\n"); return 1
    }
    swiftos_puts("SC2: heartbeat renewed lease\n")

    // Stop heartbeating → after TTL the reaper expires the lease and removes the node.
    clock.advance(31)
    var didReap = false
    for r in controller.reapOnce() where r == "node-1" { didReap = true }
    if !didReap || controller.store.get(CubeKeys.node("node-1")) != nil {
        swiftos_puts("SC2: FAIL reap\n"); return 1
    }
    swiftos_puts("SC2: lease expired, node-1 removed by reaper\n")

    // Watch sees the delete.
    pump(wc, ws)
    var sawDelete = false
    for e in agent.drainWatchEvents(channel: wc) {
        if case .delete = e.kind, e.key == CubeKeys.node("node-1") { sawDelete = true }
    }
    if !sawDelete { swiftos_puts("SC2: FAIL watch-delete\n"); return 1 }
    swiftos_puts("SC2: watch observed node-1 delete\n")

    swiftos_puts("SC2: SELFTEST PASS\n")
    return 0
}

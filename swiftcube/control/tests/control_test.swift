// SPDX-License-Identifier: Apache-2.0
// control_test.swift — SC2 host acceptance (cases 1–7), deterministic.
//
// Drives the full control plane over a host LOOPBACK transport carrying a REAL
// mutual-TLS handshake (the same MutualTLS engine that runs on-device) with an
// injected clock, so every case — token join + cert issuance, mTLS enforcement,
// TTL leases, the leader-gated reaper, and the framed/resumable watch wire — is
// exercised end to end with no network and no wall clock. Foundation is used only
// here in the harness (printing/exit), never in the control plane.
//
// Cases (per the SC2 ladder):
//   1  join with a valid token → cert issued; Node + lease appear; watcher sees add
//   2  join with invalid/expired/revoked token → rejected; nothing written
//   3  mTLS enforced: no client cert, or a cert not signed by the CA, is rejected
//   4  heartbeat renews the lease; the node stays present
//   5  lease expiry → node removed; a watcher sees the delete
//   6  watch wire: revision-ordered events; resume replays only modRevision > R;
//      a resume below the compaction floor returns Compacted
//   7  reconnect: a dropped agent re-authenticates (mTLS) and resumes with no gaps

import Foundation

// Deterministic PRNG (counter-based) — the injected entropy seam.
final class SeededRNG {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed }
    func fill(_ b: inout [UInt8]) {
        for i in 0..<b.count {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            b[i] = UInt8((s >> 33) & 0xFF) &+ UInt8(i)
        }
    }
}

let startUnix: UInt64 = 1_700_000_000

@main struct ControlTest {
    static var failed = false
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    // Shared fixtures.
    static let rngBox = SeededRNG(0xC0FFEE)
    static func rng(_ b: inout [UInt8]) { rngBox.fill(&b) }

    static var clock = ManualClock(startUnix)
    static var controller: Controller!
    static var serverIdentity: TLSIdentity!
    static var caCertDER: [UInt8] = []

    /// A loopback connection: a client channel + a controller-served server channel,
    /// pumped together while driving the controller on inbound frames.
    final class Conn {
        let client: TLSChannel
        let server: TLSChannel
        init(client: TLSChannel, server: TLSChannel) { self.client = client; self.server = server }
        func handshake() { client.start(); server.start(); pump() }
        func pump() {
            for _ in 0..<400 {
                var moved = false
                let c = client.takeWire(); if !c.isEmpty { server.feedWire(c); moved = true }
                while let f = server.nextFrame() { controller.process(frame: f, channel: server); moved = true }
                let s = server.takeWire(); if !s.isEmpty { client.feedWire(s); moved = true }
                if !moved { break }
            }
        }
    }

    static func serverChannel(now: UInt64) -> TLSChannel {
        let cfg = TLSConfig(identity: serverIdentity, caRoots: [parseX509(caCertDER)!],
                            now: now, requireClientCert: false)   // optional client auth; per-RPC gate
        return TLSChannel(MutualTLS(role: .server, config: cfg, rng))
    }
    static func clientChannel(_ cfg: TLSConfig) -> TLSChannel {
        TLSChannel(MutualTLS(role: .client, config: cfg, rng))
    }
    static func conn(_ clientCfg: TLSConfig) -> Conn {
        let c = Conn(client: clientChannel(clientCfg), server: serverChannel(now: controller.nowYMD))
        c.handshake(); return c
    }

    static func setup() {
        let nb = startUnix - 1000, na = startUnix + 10 * 365 * 24 * 3600
        var s = [UInt8](repeating: 0, count: 8); rng(&s)
        let ca = ControllerCA.create(commonName: "swiftcube-ca", notBefore: nb, notAfter: na, serial: s, rng)!
        caCertDER = ca.caCertDER
        // Controller TLS server cert ("sctld"), signed by the CA.
        let serverKey = generateECKeyPair(rng)!
        let serverCert = ca.sign(subjectCN: "sctld", sanDNS: "sctld", subjectKeyPoint65: serverKey.point65,
                                 serial: [0x53], notBefore: nb, notAfter: na)!
        serverIdentity = TLSIdentity(certChain: [serverCert], privateKey: serverKey.priv)
        controller = Controller(store: openRamCubeStore(), ca: ca, clock: clock, rng)
    }

    static func newAgent(_ name: String) -> Agent { Agent(nodeName: name, caCertDER: caCertDER, serverName: "sctld", rng)! }

    static func main() {
        setup()
        case1_joinAddsNode()
        case2_badTokensRejected()
        case3_mtlsEnforced()
        case4_heartbeatRenews()
        case5_leaseExpiryRemoves()
        case6_watchWireOrderResumeCompacted()
        case7_reconnectResumes()

        if failed { FileHandle.standardError.write(Data("control-test: FAILED\n".utf8)); exit(1) }
        print("control-test: all SC2 cases (1–7) passed")
    }

    // 1. Valid token → cert issued; Node + lease appear; a live watcher sees the add.
    static func case1_joinAddsNode() {
        let token = controller.tokens.create(ttlSeconds: 3600, uses: 1, rng).presented
        let agent = newAgent("node-1")

        // Join over a bootstrap (no client cert) channel.
        let joinConn = conn(agent.bootstrapClientConfig(now: controller.nowYMD))
        check(joinConn.client.handshakeComplete && joinConn.server.handshakeComplete, "1: bootstrap handshake")
        check(joinConn.server.peerIdentity == nil, "1: join presents no client cert")
        let id = agent.join(channel: joinConn.client, token: token, joinConn.pump)
        check(id == "node-1", "1: join returns node id (\(String(describing: id)))")
        check(agent.joined, "1: agent has a cert")
        if let leaf = parseX509(agent.certDER) {
            check(leaf.dnsNames.first == "node-1", "1: issued cert SAN is the node id")
            check(x509VerifyChainLink(child: leaf, issuer: parseX509(caCertDER)!), "1: cert chains to CA")
        } else { check(false, "1: issued cert parses") }

        // A watcher on /nodes/ (full mTLS) registered BEFORE the node registers.
        let watchConn = conn(agent.mutualClientConfig(now: controller.nowYMD))
        check(watchConn.server.peerIdentity == "node-1", "1: mTLS authenticates node-1")
        let hdr = agent.startWatch(channel: watchConn.client, start: CubeKeys.nodesPrefix,
                                   end: prefixEnd(CubeKeys.nodesPrefix), from: 0, watchConn.pump)
        if case .ready? = hdr {} else { check(false, "1: watch ready header") }

        // Register over its own mTLS channel → node + lease appear.
        let regConn = conn(agent.mutualClientConfig(now: controller.nowYMD))
        let reg = agent.register(channel: regConn.client, address: "10.0.2.15:7700", ttlSeconds: 30, regConn.pump)
        check(reg != nil, "1: register ok")
        check(controller.store.get(CubeKeys.node("node-1")) != nil, "1: /nodes/node-1 present")
        check(controller.store.get(CubeKeys.lease("node-1")) != nil, "1: /leases/node-1 present")

        // Flush the live watch and confirm the add event.
        watchConn.pump()
        let events = agent.drainWatchEvents(channel: watchConn.client)
        let addedNode = events.contains { ev in
            if case .put = ev.kind, ev.key == CubeKeys.node("node-1") { return true }; return false
        }
        check(addedNode, "1: watcher sees the node add (\(events.count) events)")
    }

    // 2. Invalid / expired / revoked tokens → rejected; nothing written.
    static func case2_badTokensRejected() {
        let before = controller.store.range([], nil).count

        func tryJoin(_ name: String, _ token: String) -> String? {
            let agent = newAgent(name)
            let c = conn(agent.bootstrapClientConfig(now: controller.nowYMD))
            return agent.join(channel: c.client, token: token, c.pump)
        }

        check(tryJoin("bad-1", "deadbeef.0011223344") == nil, "2: unknown token rejected")
        check(tryJoin("bad-2", "not-a-token") == nil, "2: malformed token rejected")

        // Expired token.
        let expTok = controller.tokens.create(ttlSeconds: 10, uses: 1, rng)
        clock.advance(11)
        check(tryJoin("bad-3", expTok.presented) == nil, "2: expired token rejected")
        clock.set(startUnix)   // restore time

        // Revoked token.
        let revTok = controller.tokens.create(ttlSeconds: 3600, uses: 1, rng)
        let (rid, _) = BootstrapToken.parse(revTok.presented)!
        controller.tokens.revoke(id: rid)
        check(tryJoin("bad-4", revTok.presented) == nil, "2: revoked token rejected")

        check(controller.store.get(CubeKeys.node("bad-1")) == nil
              && controller.store.get(CubeKeys.node("bad-3")) == nil, "2: no node written for rejects")
        // Only token records (created above) may have been added; no /nodes/ entries.
        let nodesNow = controller.store.prefix(CubeKeys.nodesPrefix).count
        check(nodesNow == 1, "2: still exactly one node (node-1) after rejects (\(nodesNow))")
        _ = before
    }

    // 3. mTLS enforced: no client cert, or a cert not signed by the CA, is rejected.
    static func case3_mtlsEnforced() {
        let agent = newAgent("node-1")
        // (a) Channel with NO client cert completes the handshake but cannot register.
        let noCert = conn(agent.bootstrapClientConfig(now: controller.nowYMD))
        check(noCert.server.peerIdentity == nil, "3a: no client identity")
        let reg = agent.register(channel: noCert.client, address: "x", ttlSeconds: 30, noCert.pump)
        check(reg == nil, "3a: unauthenticated register rejected")
        // The reply must be an explicit unauthorized error.
        if let f = noCert.client.nextFrame() ?? lastReply(noCert) {
            check(f.first == RpcStatus.unauthorized.rawValue, "3a: unauthorized status")
        }

        // (b) A client cert signed by a ROGUE CA fails the mTLS handshake outright.
        let nb = startUnix - 1000, na = startUnix + 10 * 365 * 24 * 3600
        let rogue = ControllerCA.create(commonName: "rogue", notBefore: nb, notAfter: na, serial: [0x9], rng)!
        let rk = generateECKeyPair(rng)!
        let rogueCert = rogue.sign(subjectCN: "node-9", sanDNS: "node-9", subjectKeyPoint65: rk.point65,
                                   serial: [0x9], notBefore: nb, notAfter: na)!
        let rogueCfg = TLSConfig(identity: TLSIdentity(certChain: [rogueCert], privateKey: rk.priv),
                                 caRoots: [parseX509(caCertDER)!], verifyHostname: "sctld", now: controller.nowYMD)
        let bad = Conn(client: clientChannel(rogueCfg), server: serverChannel(now: controller.nowYMD))
        bad.handshake()
        check(!(bad.client.handshakeComplete && bad.server.handshakeComplete), "3b: rogue-CA handshake fails")
        check(bad.server.peerIdentity == nil, "3b: rogue client not authenticated")
    }

    // Helper: re-pump and grab a reply if present.
    static func lastReply(_ c: Conn) -> [UInt8]? { c.pump(); return c.client.nextFrame() }

    // 4. Heartbeat renews the lease; the node stays present past the original TTL.
    static func case4_heartbeatRenews() {
        let agent = enrolled("node-hb", ttl: 30)
        let hbConn = conn(agent.mutualClientConfig(now: controller.nowYMD))
        clock.advance(20)                                   // 20s < 30s ttl
        let hb = agent.heartbeat(channel: hbConn.client, hbConn.pump)
        check(hb?.alive == true, "4: heartbeat renews")
        clock.advance(20)                                   // 40s since register, 20s since renew
        let reaped = controller.reapOnce()
        check(!reaped.contains("node-hb"), "4: renewed node not reaped (\(reaped))")
        check(controller.store.get(CubeKeys.node("node-hb")) != nil, "4: node still present")
    }

    // 5. Lease expiry: stop heartbeating → node removed; a watcher sees the delete.
    static func case5_leaseExpiryRemoves() {
        let agent = enrolled("node-die", ttl: 30)
        // Watch /nodes/node-die.
        let watchConn = conn(agent.mutualClientConfig(now: controller.nowYMD))
        let key = CubeKeys.node("node-die")
        _ = agent.startWatch(channel: watchConn.client, start: key, end: prefixEnd(key),
                             from: 0, watchConn.pump)
        watchConn.pump(); _ = agent.drainWatchEvents(channel: watchConn.client)  // drain the replayed add

        clock.advance(31)                                   // past the 30s ttl
        let reaped = controller.reapOnce()
        check(reaped.contains("node-die"), "5: expired node reaped (\(reaped))")
        check(controller.store.get(key) == nil, "5: node removed")
        check(controller.store.get(CubeKeys.lease("node-die")) == nil, "5: lease removed")

        watchConn.pump()
        let events = agent.drainWatchEvents(channel: watchConn.client)
        let sawDelete = events.contains { if case .delete = $0.kind, $0.key == key { return true }; return false }
        check(sawDelete, "5: watcher sees the delete (\(events.count) events)")
    }

    // 6. Watch wire: revision-ordered events; resume replays only modRevision > R;
    //    resume below the compaction floor returns Compacted.
    static func case6_watchWireOrderResumeCompacted() {
        let agent = enrolled("node-w", ttl: 3600)
        // Write three keys under a watched test prefix via the Put RPC.
        let putConn = conn(agent.mutualClientConfig(now: controller.nowYMD))
        let pfx = Array("/t/".utf8)
        var revs: [Revision] = []
        for k in ["a", "b", "c"] {
            putConn.client.writeFrame(PutRequest(key: pfx + Array(k.utf8), value: Array(k.utf8)).encode())
            putConn.pump()
            if let f = putConn.client.nextFrame() { var r = ByteReader(f); _ = r.u8(); revs.append(PutResponse.decodeBody(&r)!.revision) }
        }
        check(revs.count == 3 && revs[0] < revs[1] && revs[1] < revs[2], "6: monotonic put revisions")

        // Full replay from 0: events in strict (revision, key) order.
        let wc = conn(agent.mutualClientConfig(now: controller.nowYMD))
        _ = agent.startWatch(channel: wc.client, start: pfx, end: prefixEnd(pfx), from: 0, wc.pump)
        wc.pump()
        let all = agent.drainWatchEvents(channel: wc.client)
        check(all.count == 3, "6: replay yields 3 events (\(all.count))")
        check(all.map { $0.modRevision } == revs, "6: events in revision order")

        // Resume from revs[1]: only the third event (modRevision > R).
        let rc = newAgent("node-w2")
        let agent2 = enrolledAgent(rc, ttl: 3600)
        let resume = conn(agent2.mutualClientConfig(now: controller.nowYMD))
        let hdr = agent2.startWatch(channel: resume.client, start: pfx, end: prefixEnd(pfx),
                                    from: revs[1], resume.pump)
        if case .ready? = hdr {} else { check(false, "6: resume ready header") }
        resume.pump()
        let tail = agent2.drainWatchEvents(channel: resume.client)
        check(tail.count == 1 && tail[0].modRevision == revs[2], "6: resume replays only modRevision > R (\(tail.count))")

        // Compaction: raise the floor, then a watch from below it returns Compacted.
        controller.store.compact(upTo: revs[0])
        let cc = conn(agent.mutualClientConfig(now: controller.nowYMD))
        let chdr = agent.startWatch(channel: cc.client, start: pfx, end: prefixEnd(pfx), from: 0, cc.pump)
        if case .compacted(let floor)? = chdr { check(floor == revs[0], "6: Compacted floor (\(floor))") }
        else { check(false, "6: watch below floor returns Compacted (got \(String(describing: chdr)))") }
    }

    // 7. Reconnect: a dropped agent re-authenticates (mTLS) and resumes its watch
    //    from its last revision with no gaps or duplicates.
    static func case7_reconnectResumes() {
        let agent = enrolled("node-rc", ttl: 3600)
        let pfx = Array("/r/".utf8)

        // Live watch from the current revision (the store has been compacted earlier,
        // so resume starts at "now", not 0 — the realistic agent behavior).
        let baseRev = controller.store.revision
        let w = conn(agent.mutualClientConfig(now: controller.nowYMD))
        let h0 = agent.startWatch(channel: w.client, start: pfx, end: prefixEnd(pfx), from: baseRev, w.pump)
        if case .ready? = h0 {} else { check(false, "7: initial watch ready") }
        _ = agent.drainWatchEvents(channel: w.client)            // nothing yet

        // Write x; the live watcher observes it and advances the cursor.
        let put1 = conn(agent.mutualClientConfig(now: controller.nowYMD))
        put1.client.writeFrame(PutRequest(key: pfx + Array("x".utf8), value: [1]).encode()); put1.pump(); _ = put1.client.nextFrame()
        w.pump()
        let first = agent.drainWatchEvents(channel: w.client)
        check(first.count == 1, "7: live watch sees 1 event (\(first.count))")
        let cursor = agent.lastWatchRevision
        check(cursor > baseRev, "7: cursor advanced past base")

        // "Drop" the watch connection; write y and z while disconnected.
        var dropped: TLSChannel? = w.client; dropped = nil; _ = dropped
        for k in ["y", "z"] {
            let p = conn(agent.mutualClientConfig(now: controller.nowYMD))
            p.client.writeFrame(PutRequest(key: pfx + Array(k.utf8), value: [2]).encode()); p.pump(); _ = p.client.nextFrame()
        }

        // Reconnect: brand-new mTLS handshake (re-auth) + resume from the cursor.
        let rc = conn(agent.mutualClientConfig(now: controller.nowYMD))
        check(rc.server.peerIdentity == "node-rc", "7: reconnect re-authenticates via mTLS")
        let hdr = agent.startWatch(channel: rc.client, start: pfx, end: prefixEnd(pfx), from: cursor, rc.pump)
        if case .ready? = hdr {} else { check(false, "7: resume ready") }
        rc.pump()
        let resumed = agent.drainWatchEvents(channel: rc.client)
        check(resumed.count == 2, "7: resume replays exactly the 2 missed events (\(resumed.count))")
        check(resumed.allSatisfy { $0.modRevision > cursor }, "7: no duplicates (all > cursor)")
    }

    // MARK: helpers

    /// Enroll a fresh agent (join + register) and return it.
    static func enrolled(_ name: String, ttl: UInt64) -> Agent {
        let a = newAgent(name); return enrolledAgent(a, ttl: ttl)
    }
    static func enrolledAgent(_ a: Agent, ttl: UInt64) -> Agent {
        let token = controller.tokens.create(ttlSeconds: 3600, uses: 1, rng).presented
        let jc = conn(a.bootstrapClientConfig(now: controller.nowYMD))
        _ = a.join(channel: jc.client, token: token, jc.pump)
        let rc = conn(a.mutualClientConfig(now: controller.nowYMD))
        _ = a.register(channel: rc.client, address: "10.0.2.15:7700", ttlSeconds: ttl, rc.pump)
        return a
    }
}

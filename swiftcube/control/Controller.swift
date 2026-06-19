// SPDX-License-Identifier: Apache-2.0
// Controller.swift — the sctld control-plane logic (SC2).
//
// The controller embeds cubestore and answers the SC2 RPCs over an authenticated
// mTLS channel. Authentication is two-tier, kubeadm-style:
//   - Join is authenticated by a bootstrap TOKEN (the joining node has no cert
//     yet), over a server-authenticated TLS channel (client cert optional). On a
//     valid token the controller signs a node certificate from the node's CSR.
//   - Every other RPC requires a valid client cert: the channel's mTLS peer
//     identity (the node id in the client cert SAN) is the caller; an unauthenticated
//     caller is rejected. A node therefore cannot act as another node.
//
// The reaper is leader-gated: only the leader scans leases and deletes expired
// nodes, so once multiple controllers exist (SC2b) exactly one reaps. Watch is the
// network form of SC0's watch: the controller registers an in-process cubestore
// watcher whose every event is framed onto the requesting channel — including the
// deletes the reaper produces — replayable from a revision cursor. Foundation-free.

/// Tunables for issued node certs and defaults.
struct ControllerConfig {
    var nodeCertTTLSeconds: UInt64 = 365 * 24 * 3600   // long-lived node identity
    var certSkewSeconds: UInt64 = 300                  // notBefore backdate for clock skew
}

final class Controller {
    let store: CubeStore<RamLog, RamSnapshot>
    let ca: ControllerCA
    let clock: CubeClock
    let tokens: TokenAuthority<RamLog, RamSnapshot>
    let leases: LeaseManager<RamLog, RamSnapshot>
    let cfg: ControllerConfig
    private let rng: (inout [UInt8]) -> Void

    /// Leader gate for the reaper (always true for a single controller; SC2b makes
    /// this follow Raft leadership).
    var isLeader: Bool = true

    /// Live cubestore watch handles, one per streaming watch channel, kept alive so
    /// their callbacks keep firing for the channel's lifetime.
    private var watchHandles: [WatchHandle] = []

    init(store: CubeStore<RamLog, RamSnapshot>, ca: ControllerCA, clock: CubeClock,
         config: ControllerConfig = ControllerConfig(), _ rng: @escaping (inout [UInt8]) -> Void) {
        self.store = store; self.ca = ca; self.clock = clock; self.cfg = config; self.rng = rng
        self.tokens = TokenAuthority(store: store, clock: clock)
        self.leases = LeaseManager(store: store, clock: clock)
    }

    /// The current clock as the YYYYMMDDHHMMSS used for cert validity checks.
    var nowYMD: UInt64 { unixToYYYYMMDDHHMMSS(clock.nowSeconds()) }

    // MARK: - Connection serving

    /// Process one inbound request frame on `channel`. Unary RPCs reply on the same
    /// channel; a Watch turns the channel into an event stream. The caller has
    /// already completed the mTLS handshake, so `channel.peerIdentity` is the
    /// authenticated node (nil if the client presented no cert).
    func process(frame: Bytes, channel: TLSChannel) {
        guard let op = frame.first, let rpc = RpcOp(rawValue: op) else {
            reply(channel, ErrorResponse(status: .badRequest, message: "bad opcode").encode()); return
        }
        var r = ByteReader(frame); _ = r.u8()    // consume opcode
        switch rpc {
        case .join:         handleJoin(&r, channel)
        case .registerNode: handleRegister(&r, channel)
        case .heartbeat:    handleHeartbeat(channel)
        case .watch:        handleWatch(&r, channel)
        case .put:          handlePut(&r, channel)
        case .range:        handleRange(&r, channel)
        }
    }

    private func reply(_ channel: TLSChannel, _ payload: Bytes) { channel.writeFrame(payload) }

    private func requireAuth(_ channel: TLSChannel) -> String? {
        guard let id = channel.peerIdentity else {
            reply(channel, ErrorResponse(status: .unauthorized, message: "client cert required").encode())
            return nil
        }
        return id
    }

    // MARK: - Join

    private func handleJoin(_ r: inout ByteReader, _ channel: TLSChannel) {
        guard let req = JoinRequest.decodeBody(&r) else {
            reply(channel, ErrorResponse(status: .badRequest, message: "bad join").encode()); return
        }
        // 1) Validate the bootstrap token (constant-time, unexpired/unrevoked/uses>0).
        guard case .success(let tv) = tokens.validate(req.token) else {
            reply(channel, ErrorResponse(status: .tokenRejected, message: "token rejected").encode()); return
        }
        // 2) Verify the CSR (proof of possession) and extract the node's public key.
        guard !req.nodeName.isEmpty, let csr = parseAndVerifyCSR(req.csrDER) else {
            reply(channel, ErrorResponse(status: .badRequest, message: "bad csr").encode()); return
        }
        // 3) Spend one token use atomically; lose the race ⇒ reject (nothing issued).
        guard tokens.spend(id: tv.id, atRevision: tv.rev) else {
            reply(channel, ErrorResponse(status: .tokenRejected, message: "token spent").encode()); return
        }
        // 4) Sign a node certificate binding the chosen name to the CSR key.
        let now = clock.nowSeconds()
        var serial = [UInt8](repeating: 0, count: 16); rng(&serial)
        guard let cert = ca.sign(subjectCN: req.nodeName, sanDNS: req.nodeName,
                                 subjectKeyPoint65: csr.point65, serial: serial,
                                 notBefore: now &- cfg.certSkewSeconds,
                                 notAfter: now &+ cfg.nodeCertTTLSeconds) else {
            reply(channel, ErrorResponse(status: .internalError, message: "sign failed").encode()); return
        }
        reply(channel, JoinResponse(certDER: cert, caCertDER: ca.caCertDER, nodeId: req.nodeName).encode())
    }

    // MARK: - RegisterNode

    private func handleRegister(_ r: inout ByteReader, _ channel: TLSChannel) {
        guard let id = requireAuth(channel) else { return }
        guard let req = RegisterNodeRequest.decodeBody(&r) else {
            reply(channel, ErrorResponse(status: .badRequest, message: "bad register").encode()); return
        }
        let ttl = req.ttlSeconds == 0 ? 30 : req.ttlSeconds
        // Grant the lease first (so the node's liveness exists the instant it
        // appears), attaching the node key so expiry removes the node atomically.
        let nodeKey = CubeKeys.node(id)
        let expiry = leases.grant(id: id, ttlSeconds: ttl, attachedKeys: [nodeKey])
        let node = NodeRecord(id: id, status: .ready, leaseId: id, address: req.address,
                              registeredRev: store.revision)
        let rev = store.apply([.put(key: nodeKey, value: node.encode())])
        reply(channel, RegisterNodeResponse(revision: rev, leaseExpiry: expiry).encode())
    }

    // MARK: - Heartbeat

    private func handleHeartbeat(_ channel: TLSChannel) {
        guard let id = requireAuth(channel) else { return }
        if let expiry = leases.renew(id: id) {
            reply(channel, HeartbeatResponse(alive: true, expiry: expiry).encode())
        } else {
            // Lease gone (already reaped): the node must re-register.
            reply(channel, HeartbeatResponse(alive: false, expiry: 0).encode())
        }
    }

    // MARK: - Watch (streaming)

    private func handleWatch(_ r: inout ByteReader, _ channel: TLSChannel) {
        guard requireAuth(channel) != nil else { return }
        guard let req = WatchRequest.decodeBody(&r) else {
            reply(channel, ErrorResponse(status: .badRequest, message: "bad watch").encode()); return
        }
        // Resuming below the compaction floor cannot replay without gaps — tell the
        // agent to re-range and re-watch (SC0 semantics).
        if req.fromRevision < store.compactedRevision {
            reply(channel, WatchCompacted(compactedRevision: store.compactedRevision).encode()); return
        }
        // Header first (the revision the agent is caught up to), THEN history replay
        // (modRevision > fromRevision, delivered synchronously by watchRange via the
        // callback), then live — so the wire order is ready, history…, live…, with
        // no gaps or duplicates at the boundary.
        reply(channel, WatchReady(currentRevision: store.revision).encode())
        do {
            // The callback retains the channel for the watch's lifetime (Embedded
            // Swift has no `weak`); a real daemon cancels the handle on disconnect —
            // a seam noted in FORMAT.md. For SC2 the watch lives with the connection.
            let handle = try store.watchRange(req.start, req.end, fromRevision: req.fromRevision) { ev in
                channel.writeFrame(WatchEvent.from(ev).encode())
            }
            watchHandles.append(handle)
        } catch {
            reply(channel, ErrorResponse(status: .internalError, message: "watch failed").encode())
            return
        }
    }

    // MARK: - Put / Range passthrough

    private func handlePut(_ r: inout ByteReader, _ channel: TLSChannel) {
        guard requireAuth(channel) != nil else { return }
        guard let req = PutRequest.decodeBody(&r) else {
            reply(channel, ErrorResponse(status: .badRequest, message: "bad put").encode()); return
        }
        let rev = store.apply([.put(key: req.key, value: req.value)])
        reply(channel, PutResponse(revision: rev).encode())
    }

    private func handleRange(_ r: inout ByteReader, _ channel: TLSChannel) {
        guard requireAuth(channel) != nil else { return }
        guard let req = RangeRequest.decodeBody(&r) else {
            reply(channel, ErrorResponse(status: .badRequest, message: "bad range").encode()); return
        }
        let entries = store.range(req.start, req.end)
        let mapped = entries.map { (key: $0.key, value: $0.value, modRevision: $0.modRevision) }
        reply(channel, RangeResponse(entries: mapped, revision: store.revision).encode())
    }

    // MARK: - Reaper (leader-gated)

    /// One reaper pass: delete expired leases and their attached node keys. The
    /// deletes broadcast to every live watch, so watching agents observe a node
    /// vanish. No-op on a follower.
    @discardableResult
    func reapOnce() -> [String] {
        guard isLeader else { return [] }
        return leases.reapExpired()
    }
}

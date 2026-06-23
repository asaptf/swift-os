// SPDX-License-Identifier: Apache-2.0
// Agent.swift — the slet node-agent control logic (SC2).
//
// The agent drives the join → register → heartbeat → watch lifecycle against the
// controller, transport-agnostically: every RPC is "write a request frame, pump
// the channel, read the reply", where `pump` is supplied by the caller (a host
// loopback pump in tests, a TCP flush/read on-device). The agent is pre-seeded
// out-of-band with the controller CA cert (the trust anchor) and a bootstrap
// token, exactly like the cert/token are distributed in kubeadm.
//
// Join runs over a server-authenticated channel with NO client cert (the node has
// none yet) and is authorized by the token; the controller returns a signed node
// cert. Every later RPC runs over a full mTLS channel presenting that cert, so the
// controller authenticates the node by its certificate identity. Foundation-free.

final class Agent {
    let nodeName: String
    let key: ECKeyPair
    let caCertDER: [UInt8]
    let caRoot: X509Cert
    let serverName: String                  // expected server cert SAN (e.g. "sctld")
    private let rng: (inout [UInt8]) -> Void

    // Populated by a successful join.
    private(set) var certDER: [UInt8] = []
    private(set) var nodeId: String = ""
    var joined: Bool { !certDER.isEmpty }

    // Highest watch revision seen, for resume-from-revision on reconnect.
    private(set) var lastWatchRevision: Revision = 0

    init?(nodeName: String, caCertDER: [UInt8], serverName: String,
          _ rng: @escaping (inout [UInt8]) -> Void) {
        guard let key = generateECKeyPair(rng), let root = parseX509(caCertDER) else { return nil }
        self.nodeName = nodeName; self.key = key
        self.caCertDER = caCertDER; self.caRoot = root
        self.serverName = serverName; self.rng = rng
    }

    // MARK: - TLS configs (built by the daemon to construct channels)

    /// Bootstrap client config: verify the server against the CA, present no client
    /// cert (the node is not yet enrolled).
    func bootstrapClientConfig(now: UInt64) -> TLSConfig {
        TLSConfig(identity: TLSIdentity(certChain: [], privateKey: key.priv),
                  caRoots: [caRoot], verifyHostname: serverName, now: now)
    }

    /// Mutual client config: present the issued node cert for full mTLS. Valid only
    /// after a successful join.
    func mutualClientConfig(now: UInt64) -> TLSConfig {
        TLSConfig(identity: TLSIdentity(certChain: [certDER], privateKey: key.priv),
                  caRoots: [caRoot], verifyHostname: serverName, now: now)
    }

    // MARK: - RPC helper

    /// One request/response round-trip: queue the request, pump the transport, read
    /// the reply frame.
    private func rpc(_ channel: TLSChannel, _ requestFrame: Bytes, _ pump: () -> Void) -> Bytes? {
        channel.writeFrame(requestFrame)
        pump()
        return channel.nextFrame()
    }

    // MARK: - Join

    /// Build the PKCS#10 CSR proving possession of the node key.
    func buildCSR() -> Bytes? {
        acmeCSR(dnsNames: [Array(nodeName.utf8)], pubX: key.pubX, pubY: key.pubY, priv32: key.priv)
    }

    /// Present the bootstrap token + CSR over a server-authenticated channel and
    /// store the returned node cert. Returns the assigned node id, or nil on
    /// rejection.
    @discardableResult
    func join(channel: TLSChannel, token: String, _ pump: () -> Void) -> String? {
        guard let csr = buildCSR() else { return nil }
        let req = JoinRequest(token: token, nodeName: nodeName, csrDER: csr)
        guard let respFrame = rpc(channel, req.encode(), pump),
              let status = respFrame.first, status == RpcStatus.ok.rawValue else { return nil }
        var r = ByteReader(respFrame); _ = r.u8()
        guard let resp = JoinResponse.decodeBody(&r) else { return nil }
        certDER = resp.certDER; nodeId = resp.nodeId
        return resp.nodeId
    }

    // MARK: - RegisterNode / Heartbeat

    @discardableResult
    func register(channel: TLSChannel, address: String, ttlSeconds: UInt64, _ pump: () -> Void) -> RegisterNodeResponse? {
        let req = RegisterNodeRequest(address: address, ttlSeconds: ttlSeconds)
        guard let frame = rpc(channel, req.encode(), pump),
              let status = frame.first, status == RpcStatus.ok.rawValue else { return nil }
        var r = ByteReader(frame); _ = r.u8()
        return RegisterNodeResponse.decodeBody(&r)
    }

    @discardableResult
    func heartbeat(channel: TLSChannel, _ pump: () -> Void) -> HeartbeatResponse? {
        guard let frame = rpc(channel, HeartbeatRequest().encode(), pump),
              let status = frame.first, status == RpcStatus.ok.rawValue else { return nil }
        var r = ByteReader(frame); _ = r.u8()
        return HeartbeatResponse.decodeBody(&r)
    }

    // MARK: - Range / Put / CAS-put (SC3 reconcile loop)

    /// Range over `[start, end)` (end nil = open upper bound). Returns the entries and
    /// the store revision they were read at, or nil on a transport/auth error.
    func range(channel: TLSChannel, start: Bytes, end: Bytes?, _ pump: () -> Void) -> RangeResponse? {
        let req = RangeRequest(start: start, end: end)
        guard let frame = rpc(channel, req.encode(), pump),
              let status = frame.first, status == RpcStatus.ok.rawValue else { return nil }
        var r = ByteReader(frame); _ = r.u8()
        return RangeResponse.decodeBody(&r)
    }

    /// Compare-and-put `key=value`, guarded on the key's current modRevision
    /// (`expect == nil` ⇒ require the key absent). Returns the CAS outcome, or nil on a
    /// transport/auth error.
    func casPut(channel: TLSChannel, key: Bytes, value: Bytes, expect: Revision?, _ pump: () -> Void) -> CasPutResponse? {
        let req = CasPutRequest(key: key, value: value, expect: expect)
        guard let frame = rpc(channel, req.encode(), pump),
              let status = frame.first, status == RpcStatus.ok.rawValue else { return nil }
        var r = ByteReader(frame); _ = r.u8()
        return CasPutResponse.decodeBody(&r)
    }

    // MARK: - Watch

    /// Begin a watch from `fromRevision` (defaults to the agent's resume cursor).
    /// Returns the opening header: `.ready(currentRevision)` or `.compacted(floor)`.
    func startWatch(channel: TLSChannel, start: Bytes, end: Bytes?, from: Revision?,
                    _ pump: () -> Void) -> WatchFrame? {
        let fromRev = from ?? lastWatchRevision
        let req = WatchRequest(start: start, end: end, fromRevision: fromRev)
        guard let frame = rpc(channel, req.encode(), pump) else { return nil }
        return WatchFrame.decode(frame)
    }

    /// Drain any watch event frames currently buffered on the channel, advancing the
    /// resume cursor to the highest modRevision seen. Call after pumping.
    func drainWatchEvents(channel: TLSChannel) -> [WatchEvent] {
        var events: [WatchEvent] = []
        while let frame = channel.nextFrame() {
            guard case .event(let ev)? = WatchFrame.decode(frame) else { continue }
            events.append(ev)
            if ev.modRevision > lastWatchRevision { lastWatchRevision = ev.modRevision }
        }
        return events
    }
}

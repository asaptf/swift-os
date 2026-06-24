// SPDX-License-Identifier: Apache-2.0
// NodeProxy.swift — the per-node userspace L4 forwarder (kube-proxy-lite), SC7.
//
// One node-proxy runs on every node. It watches the east-west registry — /services/<name>
// (the materialized services, written by the SC7 leader reconciler) and /endpoints/<service>
// (the SC5 ready backend set) — and for each service it owns a node-local listener and load-
// balances accepted TCP connections across the service's READY endpoints. This closes the
// east-west half of design §6: app A reaches app B by service NAME (it connects to B's node-
// local proxy port, learned from the resolver) and the proxy forwards to one of B's ready Cells.
//
// Like every reconciler in the system the target management is LEVEL-triggered: `refresh()`
// re-reads the whole /services + /endpoints world each pass and rebuilds the listeners + target
// sets from scratch, so a missed/duplicate watch event, a reconnect, or a slet restart never
// matters. Reads go through the SC3 StoreClient seam, so the proxy runs over the in-process
// cubestore in host tests and the SC2 mTLS Agent on-device unchanged.
//
// Per-connection behavior (handle → ConnectionPump):
//   • round-robin over ready endpoints (per-service cursor; optional affinity / locality);
//   • dial-failover: if a backend connect fails, try the next ready endpoint;
//   • fast-fail: zero ready (or all failing) ⇒ the client conn is closed immediately, never hung;
//   • drain: a removed endpoint simply leaves the target set — new connections never pick it, but
//     an already-dialed in-flight connection to it is NOT torn down (the proxy holds no kill
//     switch over live backend conns), so it drains naturally.
//
// Foundation-free; Dictionary-free parallel-array state, like the other SwiftCube loops.

/// One in-flight (or fast-failed) forwarded connection. `endpoint` is the chosen backend, or nil
/// if the connection fast-failed (no ready/working endpoint). Driving `step()`/`run()` splices
/// bytes both ways until both half-closes are seen.
final class ConnectionPump {
    let endpoint: Endpoint?            // the backend this connection was balanced to (nil ⇒ fast-fail)
    private let client: ProxyConn
    private let backend: ProxyConn?
    private var clientOpen = true
    private var backendOpen: Bool
    private var buf: [UInt8]
    private(set) var finished = false

    init(client: ProxyConn, backend: ProxyConn?, endpoint: Endpoint?, bufSize: Int = 4096) {
        self.client = client; self.backend = backend; self.endpoint = endpoint
        self.backendOpen = backend != nil
        self.buf = [UInt8](repeating: 0, count: bufSize)
        if backend == nil {
            // Fast-fail: refuse the client immediately, never hang.
            client.close()
            finished = true
        }
    }

    /// Advance the splice by one iteration. Returns true while more work remains, false once the
    /// connection is fully drained and torn down. Safe to call after completion (returns false).
    @discardableResult
    func step() -> Bool {
        if finished { return false }
        guard let backend = backend else { finished = true; return false }

        if clientOpen {
            let n = client.read(into: &buf, max: buf.count)
            if n > 0 { backend.write(Array(buf[0..<n])) }
            else if n == 0 { clientOpen = false; backend.shutdownWrite() }
        }
        if backendOpen {
            let n = backend.read(into: &buf, max: buf.count)
            if n > 0 { client.write(Array(buf[0..<n])) }
            else if n == 0 { backendOpen = false; client.shutdownWrite() }
        }

        if !clientOpen && !backendOpen {
            client.close(); backend.close(); finished = true; return false
        }
        return true   // still open (a real event loop reschedules; the bounded run() drives fakes)
    }

    /// Splice to completion. Bounded so a misbehaving fake can never wedge a test.
    func run(maxIterations: Int = 1_000_000) {
        var i = 0
        while !finished && i < maxIterations { if !step() { break }; i += 1 }
    }
}

final class NodeProxy {
    let store: StoreClient
    let transport: ProxyTransport
    var balancer: Balancer

    /// The node-local host the proxy listens on / the resolver hands back. Same on every node.
    let proxyHost: String

    /// Per-service runtime state (parallel arrays; service counts are small).
    private struct ServiceProxy {
        var name: String
        var selector: String          // the /endpoints group backing this service
        var proxyPort: UInt16
        var listener: ProxyListener?
        var targets: [Endpoint]       // current ready endpoints (sorted by Endpoint.less)
        var cursor: UInt64            // round-robin cursor
    }
    private var services: [ServiceProxy] = []

    init(store: StoreClient, transport: ProxyTransport, proxyHost: String = "127.0.0.1",
         balancer: Balancer = Balancer()) {
        self.store = store; self.transport = transport
        self.proxyHost = proxyHost; self.balancer = balancer
    }

    // MARK: - Level-triggered target management

    /// Re-derive listeners + target sets from /services + /endpoints. Adds a listener for a new
    /// service, drops one whose service vanished, and refreshes every target set (ready-only).
    func refresh() {
        // Desired services from the registry.
        var liveNames: [String] = []
        for e in store.list(prefix: ServiceKeys.servicesPrefix) {
            guard ServiceKeys.nameOfServiceKey(e.key) != nil, let svc = Service.decode(e.value) else { continue }
            liveNames.append(svc.name)
            ensureService(svc)
        }
        // Drop services no longer in the registry (close their listener).
        var keep: [ServiceProxy] = []
        for sp in services {
            if contains(liveNames, sp.name) { keep.append(sp) } else { sp.listener?.close() }
        }
        services = keep
    }

    /// Ensure a ServiceProxy exists for `svc` with an open listener, and refresh its targets.
    private func ensureService(_ svc: Service) {
        var sp: ServiceProxy
        if let i = idx(svc.name) {
            sp = services[i]
            sp.selector = svc.selector
            // A re-allocated proxy port (rare) means re-binding the listener.
            if sp.proxyPort != svc.proxyPort { sp.listener?.close(); sp.listener = nil; sp.proxyPort = svc.proxyPort }
        } else {
            sp = ServiceProxy(name: svc.name, selector: svc.selector, proxyPort: svc.proxyPort,
                              listener: nil, targets: [], cursor: 0)
        }
        if sp.listener == nil { sp.listener = transport.listen(port: svc.proxyPort) }
        sp.targets = readReadyEndpoints(svc.selector)
        save(sp)
    }

    /// The ready endpoints backing a service (its /endpoints group). Empty when the service has
    /// no ready Cell yet — a legal set the proxy fast-fails against.
    private func readReadyEndpoints(_ selector: String) -> [Endpoint] {
        guard let e = store.get(EndpointKeys.endpoints(selector)),
              let set = EndpointSet.decode(e.value) else { return [] }
        return set.endpoints     // already sorted by Endpoint.less by the endpoints loop
    }

    // MARK: - Per-connection forwarding (LB pick + dial-failover + fast-fail)

    /// Balance + dial a backend for `service` and return a pump that splices `client` ↔ backend.
    /// Walks the round-robin/affinity try-order, skipping endpoints whose connect fails; if none
    /// connects (or there are zero ready), fast-fails (the pump closes the client). `affinityKey`
    /// empty ⇒ round-robin.
    func accept(service: String, client: ProxyConn, affinityKey: String = "") -> ConnectionPump {
        guard let i = idx(service) else { return ConnectionPump(client: client, backend: nil, endpoint: nil) }
        let (tryOrder, nextCursor) = balancer.order(ready: services[i].targets, cursor: services[i].cursor,
                                                    affinityKey: affinityKey)
        services[i].cursor = nextCursor

        for ep in tryOrder {
            if let backend = transport.dial(host: ep.address, port: ep.port) {
                return ConnectionPump(client: client, backend: backend, endpoint: ep)
            }
            // connect failed ⇒ try the next ready endpoint (resilience)
        }
        // Zero ready, or every ready endpoint failed to connect ⇒ fast-fail (never hang).
        return ConnectionPump(client: client, backend: nil, endpoint: nil)
    }

    // MARK: - Introspection (tests / observability)

    /// The proxy port a service listens on (what the resolver hands clients), or nil if unknown.
    func proxyPort(of service: String) -> UInt16? {
        guard let i = idx(service) else { return nil }
        return services[i].proxyPort
    }
    /// The current ready target set for a service (for assertions).
    func targets(of service: String) -> [Endpoint] {
        guard let i = idx(service) else { return [] }
        return services[i].targets
    }
    var serviceNames: [String] { services.map { $0.name } }

    // MARK: - Helpers

    private func idx(_ name: String) -> Int? {
        for i in 0..<services.count where services[i].name == name { return i }
        return nil
    }
    private func save(_ sp: ServiceProxy) {
        if let i = idx(sp.name) { services[i] = sp } else { services.append(sp) }
    }
    private func contains(_ xs: [String], _ x: String) -> Bool {
        for v in xs where v == x { return true }
        return false
    }
}

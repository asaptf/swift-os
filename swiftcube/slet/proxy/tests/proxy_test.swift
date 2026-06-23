// SPDX-License-Identifier: Apache-2.0
// proxy_test.swift — SC7 host acceptance for the east-west service registry + node-proxy.
//
// Drives the real SC7 control logic against an in-process cubestore: the SC5 EndpointsLoop +
// the SC7 ServiceReconciler populate /endpoints + /services; a Resolver turns a name into the
// node-local proxy address; a NodeProxy load-balances accepted connections across the ready
// endpoints. The sockets are an in-memory ProxyTransport (FakeTransport) with fake backend
// servers, so bytes actually flow end-to-end with no kernel and no real network — exactly the
// FakeProber/FakeApplier pattern of SC5/SC6. Foundation is used only by this harness.
//
// Cases (per the SC7 ladder, 1–9):
//   1  resolve + connect: client resolves "B" → proxy addr → node-proxy → a ready backend of B;
//      bytes flow end-to-end ("A reaches B by name")
//   2  load balancing: many connections over 3 ready endpoints are spread across all three
//   3  live add: a newly-ready endpoint starts receiving new connections
//   4  live remove + drain: a removed endpoint gets no new connections; an in-flight connection
//      to it is not torn down (drains)
//   5  only-ready targets: a not-ready Cell (SC5) is never a target
//   6  backend-connect failure: a failing endpoint is skipped and another ready one is used
//   7  empty set: zero ready endpoints → connections fast-fail (refused), no hang
//   8  vIP/port allocation: deterministic + stable per service; leader-only writes (2-controller sim)
//   9  session affinity: a client's connections stick to one backend within the window
//  10  explicit spec overrides a synthesized service (operator pins port/selector)
//  11  reclamation: a no-longer-desired service is deleted, its slot freed and reused, kept
//      services keep their allocation
//  12  resolver misses: an unregistered name → nil; a registered name → full ServiceAddr
//      (incl. clusterIP); a service that disappears resolves to nil again (level-triggered)

import Foundation

// MARK: - Fake transport (in-memory full-duplex conns + fake backend servers)

/// A fake backend server identified by "host:port". Responds to a request with a tagged reply so
/// the test can tell which backend served a connection. `up == false` ⇒ dials fail (connect error).
final class FakeBackend {
    let id: String
    var up = true
    private(set) var conns: [FakeBackendConn] = []
    init(_ id: String) { self.id = id }
    var dialCount: Int { conns.count }
    func handle(_ request: [UInt8]) -> [UInt8] { Array("\(id):".utf8) + request }
    func newConn() -> FakeBackendConn { let c = FakeBackendConn(self); conns.append(c); return c }
}

/// The proxy's view of a client connection: preloaded with the request (read drains it then EOFs),
/// collecting whatever the proxy writes back as `received`.
final class FakeClientConn: ProxyConn {
    private var toSend: [UInt8]
    private var sentEOF = false
    private(set) var received: [UInt8] = []
    private(set) var closed = false
    init(request: [UInt8]) { toSend = request }

    func read(into buf: inout [UInt8], max: Int) -> Int {
        if !toSend.isEmpty { let n = Swift.min(max, toSend.count); let c = Array(toSend[0..<n]); toSend.removeFirst(n); copy(c, &buf); return n }
        if !sentEOF { sentEOF = true; return 0 }
        return -1
    }
    @discardableResult func write(_ bytes: [UInt8]) -> Int { received += bytes; return bytes.count }
    func shutdownWrite() {}
    func close() { closed = true }
    private func copy(_ src: [UInt8], _ dst: inout [UInt8]) { for i in 0..<src.count { dst[i] = src[i] } }
}

/// The proxy's view of a backend connection: collects the forwarded request, computes the reply
/// when the request half-closes (shutdownWrite), then serves the reply (read drains it then EOFs).
final class FakeBackendConn: ProxyConn {
    let backend: FakeBackend
    private var request: [UInt8] = []
    private var response: [UInt8] = []
    private var responded = false
    private var sentEOF = false
    private(set) var closed = false
    init(_ backend: FakeBackend) { self.backend = backend }

    func read(into buf: inout [UInt8], max: Int) -> Int {
        if !responded { return -1 }                       // reply not ready until the request EOFs
        if !response.isEmpty { let n = Swift.min(max, response.count); let c = Array(response[0..<n]); response.removeFirst(n); for i in 0..<c.count { buf[i] = c[i] }; return n }
        if !sentEOF { sentEOF = true; return 0 }
        return -1
    }
    @discardableResult func write(_ bytes: [UInt8]) -> Int { request += bytes; return bytes.count }
    func shutdownWrite() { if !responded { response = backend.handle(request); responded = true } }
    func close() { closed = true }
}

/// In-memory ProxyTransport: listeners just record bound ports; dials resolve a backend by
/// "host:port" (nil if absent or down — a connect failure the proxy fails over from).
final class FakeListener: ProxyListener {
    let port: UInt16
    private(set) var closed = false
    init(_ port: UInt16) { self.port = port }
    func accept() -> ProxyConn? { nil }                   // the test drives accept(service:client:) directly
    func close() { closed = true }
}
final class FakeTransport: ProxyTransport {
    private var backends: [String: FakeBackend] = [:]
    private(set) var bound: [UInt16] = []

    func register(host: String, port: UInt16) -> FakeBackend {
        let b = FakeBackend("\(host):\(port)"); backends["\(host):\(port)"] = b; return b
    }
    func backend(host: String, port: UInt16) -> FakeBackend? { backends["\(host):\(port)"] }

    func listen(port: UInt16) -> ProxyListener? { bound.append(port); return FakeListener(port) }
    func dial(host: String, port: UInt16) -> ProxyConn? {
        guard let b = backends["\(host):\(port)"], b.up else { return nil }
        return b.newConn()
    }
}

@main struct ProxyTest {
    static var failed = false
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    static func main() {
        case1_resolveAndConnect()
        case2_loadBalancing()
        case3_liveAdd()
        case4_removeAndDrain()
        case5_onlyReady()
        case6_backendFailure()
        case7_emptyFastFail()
        case8_allocation()
        case9_affinity()
        case10_explicitOverride()
        case11_reclamation()
        case12_resolverMisses()

        if failed { FileHandle.standardError.write(Data("proxy-test: FAILED\n".utf8)); exit(1) }
        print("proxy-test: all SC7 east-west cases (1–12) passed")
    }

    // MARK: - Fixture

    final class Fixture {
        let store = openRamCubeStore()
        lazy var client = LocalStoreClient(store)

        /// Write /endpoints/<service> directly (as the endpoints loop would), ready set sorted.
        func setEndpoints(_ service: String, _ eps: [Endpoint]) {
            var sorted = eps; sorted.sort(by: Endpoint.less)
            let set = EndpointSet(service: service, endpoints: sorted)
            _ = store.apply([.put(key: EndpointKeys.endpoints(service), value: set.encode())])
        }
        func putStatus(_ st: CellStatusRecord) {
            _ = store.apply([.put(key: SletKeys.status(st.cellId), value: st.encode())])
        }
        func reconcileServices(isLeader: Bool = true) {
            ServiceReconciler(store: store, isLeader: isLeader).step()
        }
        func runEndpointsLoop() { EndpointsLoop(store: store).step() }
        func resolver(host: String = "127.0.0.1") -> Resolver { Resolver(store: client, proxyHost: host) }
        func proxy(_ transport: FakeTransport, balancer: Balancer = Balancer(), host: String = "127.0.0.1") -> NodeProxy {
            NodeProxy(store: client, transport: transport, proxyHost: host, balancer: balancer)
        }
    }

    static func ep(_ cellId: String, _ address: String, _ port: UInt16 = 8080) -> Endpoint {
        Endpoint(cellId: cellId, address: address, port: port)
    }

    /// Register a backend per endpoint on a transport and return the transport.
    static func transportFor(_ eps: [Endpoint]) -> FakeTransport {
        let t = FakeTransport()
        for e in eps { _ = t.register(host: e.address, port: e.port) }
        return t
    }

    /// Run one full forwarded connection and return the response bytes (or nil if fast-failed).
    static func roundTrip(_ proxy: NodeProxy, service: String, request: String,
                          affinityKey: String = "") -> [UInt8]? {
        let client = FakeClientConn(request: Array(request.utf8))
        let pump = proxy.accept(service: service, client: client, affinityKey: affinityKey)
        pump.run()
        if pump.endpoint == nil { return nil }     // fast-failed
        return client.received
    }

    // MARK: - Case 1: resolve + connect end-to-end

    static func case1_resolveAndConnect() {
        let f = Fixture()
        let eps = [ep("b0", "10.0.0.1"), ep("b1", "10.0.0.2")]
        f.setEndpoints("B", eps)
        f.reconcileServices()                       // synthesize service B from its endpoints

        // Resolve "B" → node-local proxy address.
        guard let addr = f.resolver().resolve("B") else { check(false, "1: resolve B"); return }
        check(addr.host == "127.0.0.1", "1: resolver returns node-local proxy host")
        check(addr.port >= 30000, "1: resolver returns the allocated proxy port (got \(addr.port))")
        check(addr.servicePort == 8080, "1: service port derived from endpoints")

        // Connect through the proxy listening on that port; bytes flow to a ready backend of B.
        let t = transportFor(eps)
        let proxy = f.proxy(t)
        proxy.refresh()
        check(proxy.proxyPort(of: "B") == addr.port, "1: proxy listens on the resolved port")
        guard let resp = roundTrip(proxy, service: "B", request: "ping") else { check(false, "1: connection served"); return }
        let s = String(decoding: resp, as: UTF8.self)
        check(s.hasSuffix(":ping"), "1: bytes flow end-to-end through the proxy (got \"\(s)\")")
        check(s.hasPrefix("10.0.0.1:") || s.hasPrefix("10.0.0.2:"), "1: served by a ready endpoint of B")
    }

    // MARK: - Case 2: load balancing across all ready endpoints

    static func case2_loadBalancing() {
        let f = Fixture()
        let eps = [ep("a", "10.0.0.1"), ep("b", "10.0.0.2"), ep("c", "10.0.0.3")]
        f.setEndpoints("svc", eps); f.reconcileServices()
        let t = transportFor(eps); let proxy = f.proxy(t); proxy.refresh()

        for i in 0..<9 { _ = roundTrip(proxy, service: "svc", request: "r\(i)") }
        let a = t.backend(host: "10.0.0.1", port: 8080)!.dialCount
        let b = t.backend(host: "10.0.0.2", port: 8080)!.dialCount
        let c = t.backend(host: "10.0.0.3", port: 8080)!.dialCount
        check(a > 0 && b > 0 && c > 0, "2: all three ready endpoints receive traffic (\(a),\(b),\(c))")
        check(a == 3 && b == 3 && c == 3, "2: round-robin distributes evenly (\(a),\(b),\(c))")
    }

    // MARK: - Case 3: live add

    static func case3_liveAdd() {
        let f = Fixture()
        var eps = [ep("a", "10.0.0.1"), ep("b", "10.0.0.2")]
        f.setEndpoints("svc", eps); f.reconcileServices()
        let t = FakeTransport(); for e in eps { _ = t.register(host: e.address, port: e.port) }
        let proxy = f.proxy(t); proxy.refresh()
        for i in 0..<4 { _ = roundTrip(proxy, service: "svc", request: "r\(i)") }
        check(t.backend(host: "10.0.0.3", port: 8080) == nil, "3: c not present before add")

        // Add a third ready endpoint, refresh; new connections must reach it.
        let c = ep("c", "10.0.0.3"); eps.append(c)
        _ = t.register(host: c.address, port: c.port)
        f.setEndpoints("svc", eps); proxy.refresh()
        check(proxy.targets(of: "svc").count == 3, "3: target set grows to 3 after refresh")
        for i in 0..<6 { _ = roundTrip(proxy, service: "svc", request: "n\(i)") }
        check(t.backend(host: "10.0.0.3", port: 8080)!.dialCount > 0, "3: the new endpoint receives new connections")
    }

    // MARK: - Case 4: live remove + drain

    static func case4_removeAndDrain() {
        let f = Fixture()
        let eps = [ep("a", "10.0.0.1"), ep("b", "10.0.0.2")]
        f.setEndpoints("svc", eps); f.reconcileServices()
        let t = transportFor(eps); let proxy = f.proxy(t); proxy.refresh()

        // Open a connection that round-robins to "a" (cursor 0 → first ready), but DON'T finish it.
        let client = FakeClientConn(request: Array("hold".utf8))
        let pump = proxy.accept(service: "svc", client: client)
        check(pump.endpoint?.address == "10.0.0.1", "4: in-flight connection went to a")
        let aConn = t.backend(host: "10.0.0.1", port: 8080)!.conns.last!

        // Remove "a"; new connections must never pick it.
        f.setEndpoints("svc", [ep("b", "10.0.0.2")]); proxy.refresh()
        check(proxy.targets(of: "svc").count == 1 && proxy.targets(of: "svc")[0].address == "10.0.0.2",
              "4: removed endpoint left the target set")
        for i in 0..<4 {
            let resp = roundTrip(proxy, service: "svc", request: "x\(i)")!
            check(String(decoding: resp, as: UTF8.self).hasPrefix("10.0.0.2:"), "4: new connections only to b")
        }
        check(!aConn.closed, "4: the in-flight connection to a was not torn down (drain)")

        // The drained connection still completes successfully.
        pump.run()
        check(aConn.closed, "4: the drained connection completes and closes normally")
        check(String(decoding: client.received, as: UTF8.self) == "10.0.0.1:8080:hold", "4: drained bytes flowed")
    }

    // MARK: - Case 5: only-ready targets (a not-ready Cell is never a target)

    static func case5_onlyReady() {
        let f = Fixture()
        // Drive the real SC5 endpoints loop from Cell statuses: one ready, one not ready.
        f.putStatus(status("ready0", service: "svc", address: "10.0.0.1", ready: true))
        f.putStatus(status("notready0", service: "svc", address: "10.0.0.9", ready: false))
        f.runEndpointsLoop()                        // builds /endpoints/svc = {ready0} only
        f.reconcileServices()

        let t = FakeTransport()
        _ = t.register(host: "10.0.0.1", port: 8080)
        let notReady = t.register(host: "10.0.0.9", port: 8080)   // present but must never be dialed
        let proxy = f.proxy(t); proxy.refresh()

        check(proxy.targets(of: "svc").count == 1, "5: only the ready Cell is a target")
        check(proxy.targets(of: "svc")[0].address == "10.0.0.1", "5: the target is the ready Cell")
        for i in 0..<5 { _ = roundTrip(proxy, service: "svc", request: "r\(i)") }
        check(notReady.dialCount == 0, "5: the not-ready Cell is never dialed")
    }

    // MARK: - Case 6: backend-connect failure → skip to another ready endpoint

    static func case6_backendFailure() {
        let f = Fixture()
        let eps = [ep("a", "10.0.0.1"), ep("b", "10.0.0.2")]
        f.setEndpoints("svc", eps); f.reconcileServices()
        let t = transportFor(eps)
        t.backend(host: "10.0.0.1", port: 8080)!.up = false    // a refuses connections
        let proxy = f.proxy(t); proxy.refresh()

        // Every connection still succeeds — the failing endpoint is skipped, b is used.
        for i in 0..<4 {
            guard let resp = roundTrip(proxy, service: "svc", request: "r\(i)") else {
                check(false, "6: connection served despite a failing endpoint"); continue
            }
            check(String(decoding: resp, as: UTF8.self).hasPrefix("10.0.0.2:"), "6: failover to the healthy endpoint")
        }
        check(t.backend(host: "10.0.0.2", port: 8080)!.dialCount == 4, "6: all connections went to b")
    }

    // MARK: - Case 7: empty ready set → fast-fail, no hang

    static func case7_emptyFastFail() {
        let f = Fixture()
        f.setEndpoints("svc", [])                  // zero ready endpoints (a legal set)
        // No explicit spec + no usable endpoint port ⇒ no service synthesized; register the
        // service explicitly so the proxy still has a listener that fast-fails.
        _ = f.store.apply([.put(key: ServiceKeys.svcSpec("svc"),
                                value: ServiceSpec(name: "svc", servicePort: 8080).encode())])
        f.reconcileServices()
        let t = FakeTransport(); let proxy = f.proxy(t); proxy.refresh()
        check(proxy.targets(of: "svc").count == 0, "7: empty target set")

        let client = FakeClientConn(request: Array("ping".utf8))
        let pump = proxy.accept(service: "svc", client: client)
        check(pump.endpoint == nil, "7: no backend chosen for an empty set")
        check(pump.finished, "7: fast-fail completes immediately (no hang)")
        check(client.closed, "7: the client connection is refused (closed), not left hanging")
        check(client.received.isEmpty, "7: no bytes served when there are no ready endpoints")
    }

    // MARK: - Case 8: deterministic + stable vIP/port allocation; leader-only

    static func case8_allocation() {
        let f = Fixture()
        _ = f.store.apply([.put(key: ServiceKeys.svcSpec("alpha"), value: ServiceSpec(name: "alpha", servicePort: 80).encode())])
        _ = f.store.apply([.put(key: ServiceKeys.svcSpec("bravo"), value: ServiceSpec(name: "bravo", servicePort: 80).encode())])

        // Leader allocates; deterministic by sorted name (alpha index 0, bravo index 1).
        f.reconcileServices()
        let alpha1 = svc(f, "alpha"); let bravo1 = svc(f, "bravo")
        check(alpha1 != nil && bravo1 != nil, "8: both services materialized")
        check(alpha1!.proxyPort == 30000 && alpha1!.clusterIP == "10.96.0.0", "8: alpha gets slot 0 deterministically")
        check(bravo1!.proxyPort == 30001 && bravo1!.clusterIP == "10.96.0.1", "8: bravo gets slot 1 deterministically")

        // Re-running is idempotent (no churn) and stable (same allocation).
        let revBefore = f.store.get(ServiceKeys.service("alpha"))!.modRevision
        f.reconcileServices()
        check(svc(f, "alpha")! == alpha1! && svc(f, "bravo")! == bravo1!, "8: allocation stable across passes")
        check(f.store.get(ServiceKeys.service("alpha"))!.modRevision == revBefore, "8: no churn on a stable pass")

        // Add a third service: existing allocations are preserved, the new one gets the next slot.
        _ = f.store.apply([.put(key: ServiceKeys.svcSpec("charlie"), value: ServiceSpec(name: "charlie", servicePort: 80).encode())])
        f.reconcileServices()
        check(svc(f, "alpha")!.proxyPort == 30000 && svc(f, "bravo")!.proxyPort == 30001, "8: existing services keep their port")
        check(svc(f, "charlie")!.proxyPort == 30002, "8: a new service gets the next free slot")

        // Leader-only: a follower writes nothing (2-controller sim).
        let g = Fixture()
        _ = g.store.apply([.put(key: ServiceKeys.svcSpec("x"), value: ServiceSpec(name: "x", servicePort: 80).encode())])
        g.reconcileServices(isLeader: false)
        check(g.store.get(ServiceKeys.service("x")) == nil, "8: a follower allocates/writes nothing")
        g.reconcileServices(isLeader: true)
        check(g.store.get(ServiceKeys.service("x")) != nil, "8: the leader does write")
    }

    // MARK: - Case 9: session affinity

    static func case9_affinity() {
        let f = Fixture()
        let eps = [ep("a", "10.0.0.1"), ep("b", "10.0.0.2"), ep("c", "10.0.0.3")]
        f.setEndpoints("svc", eps); f.reconcileServices()
        let t = transportFor(eps)
        let proxy = f.proxy(t, balancer: Balancer(BalancerConfig(affinity: true)))
        proxy.refresh()

        // The same client key sticks to one backend across repeated connections.
        var served = Set<String>()
        for _ in 0..<6 {
            let resp = roundTrip(proxy, service: "svc", request: "x", affinityKey: "client-42")!
            let tag = String(decoding: resp, as: UTF8.self).split(separator: ":").first.map(String.init) ?? ""
            served.insert(tag)
        }
        check(served.count == 1, "9: one client key sticks to a single backend (hit \(served.count))")

        // A different key may land on a different backend (different hash slot).
        var served2 = Set<String>()
        for _ in 0..<6 {
            let resp = roundTrip(proxy, service: "svc", request: "y", affinityKey: "client-7")!
            served2.insert(String(decoding: resp, as: UTF8.self).split(separator: ":").first.map(String.init) ?? "")
        }
        check(served2.count == 1, "9: a second client key also sticks to one backend")
    }

    // MARK: - Case 10: explicit spec overrides a synthesized service

    static func case10_explicitOverride() {
        let f = Fixture()
        // B has ready endpoints on 8080 (would synthesize servicePort 8080, selector "B")...
        f.setEndpoints("B", [ep("b0", "10.0.0.1", 8080)])
        // ...but an operator pins an explicit spec: a different port and selector.
        _ = f.store.apply([.put(key: ServiceKeys.svcSpec("B"),
                                value: ServiceSpec(name: "B", selector: "backend", servicePort: 9090).encode())])
        f.reconcileServices()

        guard let b = svc(f, "B") else { check(false, "10: service B materialized"); return }
        check(b.servicePort == 9090, "10: explicit spec wins on servicePort (got \(b.servicePort), not the synthesized 8080)")
        check(b.selector == "backend", "10: explicit spec wins on selector (got \"\(b.selector)\")")

        // Exactly one /services/B is written (the explicit spec did not create a second).
        var count = 0
        for e in f.store.prefix(ServiceKeys.servicesPrefix) where ServiceKeys.nameOfServiceKey(e.key) == "B" { count += 1 }
        check(count == 1, "10: a single materialized service for B (got \(count))")
    }

    // MARK: - Case 11: reclamation — delete a no-longer-desired service, free + reuse its slot

    static func case11_reclamation() {
        let f = Fixture()
        for n in ["alpha", "bravo", "charlie"] {
            _ = f.store.apply([.put(key: ServiceKeys.svcSpec(n), value: ServiceSpec(name: n, servicePort: 80).encode())])
        }
        f.reconcileServices()
        check(svc(f, "alpha")!.allocIndex == 0 && svc(f, "bravo")!.allocIndex == 1 && svc(f, "charlie")!.allocIndex == 2,
              "11: initial deterministic allocation 0/1/2")

        // bravo is no longer desired (its spec is removed; it has no endpoints to synthesize from).
        _ = f.store.apply([.delete(key: ServiceKeys.svcSpec("bravo"))])
        f.reconcileServices()
        check(svc(f, "bravo") == nil, "11: a no-longer-desired service is deleted from /services")
        check(svc(f, "alpha")!.allocIndex == 0 && svc(f, "charlie")!.allocIndex == 2,
              "11: kept services keep their allocation across the deletion")

        // A new service reuses bravo's freed slot (lowest free), not the next-highest.
        _ = f.store.apply([.put(key: ServiceKeys.svcSpec("delta"), value: ServiceSpec(name: "delta", servicePort: 80).encode())])
        f.reconcileServices()
        guard let delta = svc(f, "delta") else { check(false, "11: delta materialized"); return }
        check(delta.allocIndex == 1, "11: a new service reuses the freed slot (got index \(delta.allocIndex), expected 1)")
        check(delta.proxyPort == 30001 && delta.clusterIP == "10.96.0.1", "11: derived port/vIP follow the reused slot")
        check(svc(f, "alpha")!.allocIndex == 0 && svc(f, "charlie")!.allocIndex == 2, "11: existing services still stable")
    }

    // MARK: - Case 12: resolver misses + level-triggered disappearance

    static func case12_resolverMisses() {
        let f = Fixture()
        let r = f.resolver()
        check(r.resolve("nope") == nil, "12: an unregistered service resolves to nil")

        // Register an explicit service; resolve returns the full address incl. the recorded vIP.
        _ = f.store.apply([.put(key: ServiceKeys.svcSpec("api"),
                                value: ServiceSpec(name: "api", servicePort: 8080).encode())])
        f.reconcileServices()
        guard let addr = r.resolve("api") else { check(false, "12: registered service resolves"); return }
        check(addr.host == "127.0.0.1" && addr.port == 30000, "12: proxy host/port from the allocation")
        check(addr.servicePort == 8080 && addr.clusterIP == "10.96.0.0", "12: servicePort + recorded clusterIP carried through")

        // Level-triggered: remove the service and it resolves to nil again (no stale cache).
        _ = f.store.apply([.delete(key: ServiceKeys.svcSpec("api"))])
        f.reconcileServices()
        check(r.resolve("api") == nil, "12: a disappeared service resolves to nil (level-triggered)")
    }

    // MARK: - helpers

    static func svc(_ f: Fixture, _ name: String) -> Service? {
        guard let e = f.store.get(ServiceKeys.service(name)) else { return nil }
        return Service.decode(e.value)
    }
    static func status(_ cid: String, service: String, address: String, ready: Bool) -> CellStatusRecord {
        CellStatusRecord(cellId: cid, node: "node-a", phase: .running, ready: ready, restartCount: 0,
                         imageDigest: [UInt8](repeating: 0, count: 32), startedAtSeconds: 1, message: "",
                         service: service, address: address, port: 8080)
    }
}

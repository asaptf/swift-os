// SPDX-License-Identifier: Apache-2.0
// Resolver.swift — node-local service-name resolution for east-west discovery (SC7).
//
// So a Cell can `connect("B")` and reach service B, it must turn the name "B" into the address
// of B's node-local proxy listener. The resolver is that map: it reads the SC7 registry
// (/services/<name>) and returns the (proxyHost, proxyPort) the local node-proxy listens on for
// the service. Because the swift-os stack has no routable per-service vIP (see Service.swift /
// FORMAT.md), resolution returns an address+PORT pair, not a bare IP — the allocated node-local
// port IS the per-service identity today. A classic wire-DNS A record (IP only) cannot express
// that port; the on-device responder seam below would need SRV records or a routable vIP range
// to do so — that is the documented follow-on.
//
// The core (`resolve`) is pure and Foundation-free, driven directly by host tests over the
// in-process cubestore through the SC3 StoreClient seam. The on-device DNS-responder wiring (a
// UDP listener that answers a Cell's lookups, and slet injecting the resolver+proxy into the
// Cell's namespace at creation — the C6 seam) is described in FORMAT.md; this file is the
// resolution logic both share.

/// A resolved service address: the node-local proxy endpoint a client connects to.
struct ServiceAddr: Equatable {
    var host: String
    var port: UInt16          // the proxy port (the per-service identity in the node-local model)
    var servicePort: UInt16   // the logical cluster port (informational; the routable-vIP seam)
    var clusterIP: String     // the recorded vIP (informational; not routable today)
}

final class Resolver {
    let store: StoreClient
    /// The node-local host the proxy listens on (same on every node).
    let proxyHost: String

    init(store: StoreClient, proxyHost: String = "127.0.0.1") {
        self.store = store; self.proxyHost = proxyHost
    }

    /// Resolve a service name to its node-local proxy address, or nil if no such service is
    /// registered. Level-triggered: every call re-reads /services/<name>, so a service that
    /// appears/disappears is reflected immediately with no cache to invalidate.
    func resolve(_ name: String) -> ServiceAddr? {
        guard let e = store.get(ServiceKeys.service(name)), let svc = Service.decode(e.value) else { return nil }
        return ServiceAddr(host: proxyHost, port: svc.proxyPort,
                           servicePort: svc.servicePort, clusterIP: svc.clusterIP)
    }
}

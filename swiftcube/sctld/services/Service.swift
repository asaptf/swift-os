// SPDX-License-Identifier: Apache-2.0
// Service.swift — the SC7 east-west service registry: the `Service` object the node-proxy
// programs against, the desired `ServiceSpec` seam, and the deterministic vIP/port allocator.
//
// East-west discovery (design §6, "flat L3 + node-local proxy") lets app A reach app B by
// service NAME instead of chasing B's individual Cell addresses. The registry is two object
// families in cubestore (SC2 owns /nodes,/leases,/tokens; SC3 /assignments,/status/cells;
// SC4 /apps,/pending; SC5 /endpoints; SC6 /expose,/lb):
//
//   /svcspec/<name>   — DESIRED (optional, the explicit-service seam): a `ServiceSpec`
//                       {name, selector, servicePort}. Written by sctl/SC9. A service that
//                       has ready endpoints but no explicit spec is SYNTHESIZED by the
//                       reconciler from its endpoints — so "A reaches B by name" needs zero
//                       manual config (B's ready Cells imply a service B on B's port).
//   /services/<name>  — MATERIALIZED: a `Service` the leader reconciler writes. It pins the
//                       allocation (clusterIP/proxyPort) the node-proxy + resolver read.
//
// Networking reality (verified against the swift-os stack, swift_user.h): there is NO
// DNAT/netfilter and NO way to bind/route a per-service virtual IP (`swiftos_bind` takes a
// port only). So SC7 uses the model the milestone anticipates as the fallback: a USERSPACE
// L4 proxy at a node-local proxy address + a STABLE per-service port. The `clusterIP` (vIP)
// is still allocated and recorded — deterministic and stable per service — as the routing
// seam for when a routable vIP range exists; what is LIVE today is `proxyPort` (the node-
// local port the proxy listens on). The resolver therefore returns (proxyHost, proxyPort),
// not a bare IP — see Resolver.swift / FORMAT.md.
//
// Foundation-free; little-endian ByteIO, like every other cubestore record.

// MARK: - Key schema

enum ServiceKeys {
    static let svcSpecPrefix:  Bytes = Array("/svcspec/".utf8)
    static let servicesPrefix: Bytes = Array("/services/".utf8)

    /// `/svcspec/<name>` — an explicit desired service.
    static func svcSpec(_ name: String) -> Bytes { svcSpecPrefix + Array(name.utf8) }
    /// `/services/<name>` — the materialized service the proxy/resolver read.
    static func service(_ name: String) -> Bytes { servicesPrefix + Array(name.utf8) }

    /// The service name from a `/svcspec/<name>` key, or nil if not in that range.
    static func nameOfSpecKey(_ key: Bytes) -> String? { name(of: key, prefix: svcSpecPrefix) }
    /// The service name from a `/services/<name>` key, or nil if not in that range.
    static func nameOfServiceKey(_ key: Bytes) -> String? { name(of: key, prefix: servicesPrefix) }

    private static func name(of key: Bytes, prefix pfx: Bytes) -> String? {
        guard key.count > pfx.count else { return nil }
        for i in 0..<pfx.count where key[i] != pfx[i] { return nil }
        return String(decoding: key[pfx.count...], as: UTF8.self)
    }
}

// MARK: - ServiceSpec (desired state — the explicit-service seam)

/// What a user (sctl/SC9) declares, or what the reconciler synthesizes from endpoints.
/// `selector` is the endpoints group name backing this service (== `name` for now; the seam
/// for real label selectors is the field itself). `servicePort` is the logical cluster port
/// clients address the service on (the manifest container port).
struct ServiceSpec: Equatable {
    var name: String
    var selector: String
    var servicePort: UInt16

    init(name: String, selector: String = "", servicePort: UInt16) {
        self.name = name
        self.selector = selector.isEmpty ? name : selector
        self.servicePort = servicePort
    }

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)                          // record version
        w.blob(Array(name.utf8))
        w.blob(Array(selector.utf8))
        w.u32(UInt32(servicePort))
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> ServiceSpec? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let nB = r.blob(), let selB = r.blob(),
              let sp = r.u32() else { return nil }
        return ServiceSpec(name: String(decoding: nB, as: UTF8.self),
                           selector: String(decoding: selB, as: UTF8.self),
                           servicePort: UInt16(truncatingIfNeeded: sp))
    }
}

// MARK: - Service (materialized state — the value at /services/<name>)

/// The reconciled service the node-proxy + resolver program against. `allocIndex` is the
/// stable allocation slot the leader assigned (kept across passes); `clusterIP` and
/// `proxyPort` are derived from it deterministically and stored so a reader needs no
/// allocator constants. `clusterIP` is the recorded vIP (routing seam — not bound today);
/// `proxyPort` is the LIVE node-local port the proxy listens on. `selector` is the endpoints
/// group; `servicePort` the logical cluster port.
struct Service: Equatable {
    var name: String
    var selector: String
    var servicePort: UInt16
    var clusterIP: String      // recorded vIP from the service range (routing seam)
    var proxyPort: UInt16      // the LIVE node-local listen port (the real mapping)
    var allocIndex: UInt32     // the stable allocation slot (for reclamation)

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)                          // record version
        w.blob(Array(name.utf8))
        w.blob(Array(selector.utf8))
        w.u32(UInt32(servicePort))
        w.blob(Array(clusterIP.utf8))
        w.u32(UInt32(proxyPort))
        w.u32(allocIndex)
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> Service? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let nB = r.blob(), let selB = r.blob(),
              let sp = r.u32(), let ipB = r.blob(), let pp = r.u32(), let ai = r.u32() else { return nil }
        return Service(name: String(decoding: nB, as: UTF8.self),
                       selector: String(decoding: selB, as: UTF8.self),
                       servicePort: UInt16(truncatingIfNeeded: sp),
                       clusterIP: String(decoding: ipB, as: UTF8.self),
                       proxyPort: UInt16(truncatingIfNeeded: pp), allocIndex: ai)
    }
}

// MARK: - Deterministic vIP/port allocator (from a service range)

/// Maps an allocation index to a (clusterIP, proxyPort) pair, deterministically. The leader
/// reconciler assigns the lowest free index to each new service (existing services keep their
/// index), so allocation is deterministic AND stable per service. Defaults: vIP range
/// 10.96.0.0/16 (the service range), node-local proxy ports from 30000.
struct ServiceAllocator: Equatable {
    var ipBase: UInt32 = 0x0A_60_00_00     // 10.96.0.0, host order
    var portBase: UInt16 = 30000
    var capacity: UInt32 = 2048            // slots in the range

    func clusterIP(_ index: UInt32) -> String { ServiceAllocator.ipv4(ipBase &+ index) }
    func proxyPort(_ index: UInt32) -> UInt16 { portBase &+ UInt16(truncatingIfNeeded: index) }

    /// Format a host-order IPv4 as a dotted quad (Foundation-free).
    static func ipv4(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }
}

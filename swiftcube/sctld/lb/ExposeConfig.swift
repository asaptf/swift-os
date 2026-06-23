// SPDX-License-Identifier: Apache-2.0
// ExposeConfig.swift — the SC6 LB schema: the per-service `expose` config the LB programmer
// loop consumes, and the `/lb/<service>` status it writes back.
//
// SC6 programs an EXTERNAL load balancer so a service's listener forwards to its ready
// endpoints. The loop's two inputs are the SC5 `/endpoints/<service>` set (the backend pool)
// and the service's listener/health config — the `expose:` block of the manifest (design §10).
// SC9's manifest parser (`sctl apply`) will write the expose config; until then it is a
// first-class cubestore object so SC6 is independently testable. Two object families enter the
// schema here (SC2 owns /nodes,/leases,/tokens; SC3 owns /assignments,/status/cells; SC4 owns
// /apps,/pending; SC5 owns /endpoints):
//
//   /expose/<service> — DESIRED: a `ServiceExpose` (listener port/protocol, optional TLS-cert
//                       ref, health-check config, and the provider that programs it). Written
//                       by sctl (SC9 seam); read by the LB programmer loop.
//   /lb/<service>     — OBSERVED: an `LBStatusRecord` the loop writes after each reconcile —
//                       the applied config generation, whether the backend is healthy, and the
//                       last error (a failed `nginx -t`/reload surfaces here, never silently).
//
// Foundation-free; little-endian ByteIO, like every other cubestore record.

// MARK: - Key schema

enum LBKeys {
    static let exposePrefix: Bytes = Array("/expose/".utf8)
    static let lbPrefix: Bytes     = Array("/lb/".utf8)

    /// `/expose/<service>` — the listener + health config for one service.
    static func expose(_ service: String) -> Bytes {
        exposePrefix + Array(service.utf8)
    }

    /// `/lb/<service>` — the LB programmer status for one service.
    static func lb(_ service: String) -> Bytes {
        lbPrefix + Array(service.utf8)
    }

    /// The service name from an `/expose/<service>` key, or nil if not in that range.
    static func serviceOfExposeKey(_ key: Bytes) -> String? {
        service(of: key, prefix: exposePrefix)
    }
    /// The service name from an `/lb/<service>` key, or nil if not in that range.
    static func serviceOfLBKey(_ key: Bytes) -> String? {
        service(of: key, prefix: lbPrefix)
    }
    private static func service(of key: Bytes, prefix pfx: Bytes) -> String? {
        guard key.count > pfx.count else { return nil }
        for i in 0..<pfx.count where key[i] != pfx[i] { return nil }
        return String(decoding: key[pfx.count...], as: UTF8.self)
    }
}

// MARK: - Listener protocol

/// The L7/L4 protocol a listener speaks. `https` carries a TLS-cert ref (provisioned by the
/// secrets/SC9 seam — SC6 only threads the reference through, it does not mint certs). `tcp` is
/// the L4 pass-through form (no `proxy_pass http://`).
enum ListenProtocol: UInt8, Equatable {
    case http  = 0
    case https = 1
    case tcp   = 2
}

// MARK: - ServiceExpose (the value at /expose/<service>)

struct ServiceExpose: Equatable {
    var service: String
    var provider: String            // which LBProvider programs this service, e.g. "nginx"
    var listenPort: UInt16          // the port the LB listens on (e.g. 80, 443)
    var proto: ListenProtocol
    var tlsCertRef: String          // https only; "" = none (secrets/SC9 seam)
    var healthPath: String          // passive-health annotation / http readiness path; "" = TCP
    var healthPort: UInt16          // 0 ⇒ probe the backend's own port

    init(service: String, provider: String = "nginx", listenPort: UInt16,
         proto: ListenProtocol = .http, tlsCertRef: String = "",
         healthPath: String = "", healthPort: UInt16 = 0) {
        self.service = service; self.provider = provider; self.listenPort = listenPort
        self.proto = proto; self.tlsCertRef = tlsCertRef
        self.healthPath = healthPath; self.healthPort = healthPort
    }

    /// The listener half of the desired state passed to a provider.
    var listener: LBListener { LBListener(port: listenPort, proto: proto, tlsCertRef: tlsCertRef) }
    /// The health-check half of the desired state passed to a provider.
    var health: LBHealthCheck { LBHealthCheck(path: healthPath, port: healthPort) }

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)                          // record version
        w.blob(Array(service.utf8))
        w.blob(Array(provider.utf8))
        w.u32(UInt32(listenPort))
        w.u8(proto.rawValue)
        w.blob(Array(tlsCertRef.utf8))
        w.blob(Array(healthPath.utf8))
        w.u32(UInt32(healthPort))
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> ServiceExpose? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let svcB = r.blob(), let provB = r.blob(),
              let lp = r.u32(), let protoB = r.u8(), let proto = ListenProtocol(rawValue: protoB),
              let certB = r.blob(), let pathB = r.blob(), let hp = r.u32() else { return nil }
        return ServiceExpose(service: String(decoding: svcB, as: UTF8.self),
                             provider: String(decoding: provB, as: UTF8.self),
                             listenPort: UInt16(truncatingIfNeeded: lp), proto: proto,
                             tlsCertRef: String(decoding: certB, as: UTF8.self),
                             healthPath: String(decoding: pathB, as: UTF8.self),
                             healthPort: UInt16(truncatingIfNeeded: hp))
    }
}

// MARK: - LBStatusRecord (the value at /lb/<service>)

/// What the LB programmer loop reports after a reconcile. `generation` is the CRC32 of the
/// config that is actually ACTIVE on the LB (so it is stable across no-op reconciles and only
/// changes when the live config changes). `healthy` is false while the last apply failed;
/// `lastError` carries the validator/reload failure verbatim — a bad config is never made
/// active and the reason is visible here.
struct LBStatusRecord: Equatable {
    var service: String
    var generation: UInt32          // CRC32 of the active config (0 = nothing applied yet)
    var backends: UInt32            // number of ready endpoints in the active pool
    var healthy: Bool
    var lastError: String

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)
        w.blob(Array(service.utf8))
        w.u32(generation)
        w.u32(backends)
        w.u8(healthy ? 1 : 0)
        w.blob(Array(lastError.utf8))
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> LBStatusRecord? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let svcB = r.blob(), let gen = r.u32(),
              let backends = r.u32(), let healthyB = r.u8(), let errB = r.blob() else { return nil }
        return LBStatusRecord(service: String(decoding: svcB, as: UTF8.self), generation: gen,
                              backends: backends, healthy: healthyB != 0,
                              lastError: String(decoding: errB, as: UTF8.self))
    }
}

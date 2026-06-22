// SPDX-License-Identifier: Apache-2.0
// LBProvider.swift — the SC6 load-balancer provider interface (design §8).
//
// SwiftCube does not ship its own load balancer (design §1); it PROGRAMS an external one. A
// provider is a plugin behind one interface: given a service and its desired state — the
// listener, the backend pool (the SC5 ready endpoints), and the health-check config — make the
// LB match. SC6 ships the interface plus the first provider, nginx; the shape is deliberately
// generic so Hetzner/AWS slot in unchanged (each implements `reconcile`/`remove` against its
// own API instead of nginx config + reload).
//
// Contract every provider upholds:
//   - idempotent: diff the live config against desired, apply only the delta; an unchanged
//     desired state causes no rewrite and no reload (`changed == false`).
//   - validate-before-commit: a config that does not validate is never made active; the
//     previous config stays and the error is reported (never take the LB down with a bad config).
//   - reports status, never throws: failure comes back as `error != nil`, so the loop can record
//     it in /lb/<service> and retry with backoff. Rate-limiting / retry-with-backoff is the
//     loop's job (it owns the clock); the provider is the single idempotent apply step.
//
// Foundation-free: the interface and the nginx renderer/provider run inside sctld. Only the
// concrete applier that shells out to a local nginx (and the host test fakes) use Foundation.

// MARK: - Desired state (the input to reconcile)

/// The listener a provider must ensure exists: a port, its protocol, and (for https) the TLS
/// cert reference. Cert PROVISIONING is the secrets/SC9 seam; SC6 only threads the ref through.
struct LBListener: Equatable {
    var port: UInt16
    var proto: ListenProtocol
    var tlsCertRef: String          // https only; "" = none
}

/// How the LB checks a backend. `path` non-empty ⇒ an HTTP readiness path; empty ⇒ a TCP
/// connect check. `port == 0` ⇒ probe the backend's own port. (Open-source nginx renders this
/// as passive health — `max_fails`/`fail_timeout` — since active `health_check` is nginx-plus;
/// the field set is provider-agnostic so an API provider can program an active check.)
struct LBHealthCheck: Equatable {
    var path: String
    var port: UInt16
}

/// Everything a provider needs to make one service's listener forward to its ready endpoints.
/// `backends` are the SC5 ready endpoints; an empty pool is legal and MUST still produce a valid
/// config (a provider renders an explicit no-backends form, never a broken empty upstream).
struct LBDesiredState: Equatable {
    var service: String
    var listener: LBListener
    var backends: [Endpoint]        // the SC5 ready endpoints (kept sorted by Endpoint.less)
    var health: LBHealthCheck

    /// A deterministic fingerprint of the desired state (listener + sorted backends + health),
    /// used by the loop to detect change and debounce. Independent of any provider's rendering.
    func fingerprint() -> UInt32 {
        var w = ByteWriter()
        w.blob(Array(service.utf8))
        w.u32(UInt32(listener.port)); w.u8(listener.proto.rawValue); w.blob(Array(listener.tlsCertRef.utf8))
        w.blob(Array(health.path.utf8)); w.u32(UInt32(health.port))
        var eps = backends
        eps.sort(by: Endpoint.less)
        w.u32(UInt32(eps.count))
        for e in eps { w.blob(Array(e.cellId.utf8)); w.blob(Array(e.address.utf8)); w.u32(UInt32(e.port)) }
        return cubeCrc32(w.bytes)
    }
}

// MARK: - Reconcile result (the output)

/// What a provider reports back. `generation` is the CRC32 of the config now ACTIVE on the LB
/// (stable across no-op reconciles; changes only when the live config changes). `changed` is
/// true iff this reconcile actually rewrote+reloaded. `error == nil` ⇒ success; otherwise the
/// active config is unchanged and `error` explains why (e.g. a failed `nginx -t`).
struct LBReconcileResult: Equatable {
    var generation: UInt32
    var changed: Bool
    var healthy: Bool
    var error: String?

    static func ok(generation: UInt32, changed: Bool) -> LBReconcileResult {
        LBReconcileResult(generation: generation, changed: changed, healthy: true, error: nil)
    }
    static func failure(generation: UInt32, _ message: String) -> LBReconcileResult {
        LBReconcileResult(generation: generation, changed: false, healthy: false, error: message)
    }
}

// MARK: - The provider interface

/// One external load balancer, programmed idempotently. Implemented by the nginx provider here;
/// the Hetzner/AWS providers implement the same two calls against their cloud APIs.
protocol LBProvider: AnyObject {
    /// The provider name this implementation answers to (matched against `ServiceExpose.provider`).
    var name: String { get }

    /// Make the LB's listener for `desired.service` forward to exactly `desired.backends`,
    /// validating before committing. Idempotent: an unchanged desired state reloads nothing.
    func reconcile(_ desired: LBDesiredState) -> LBReconcileResult

    /// Remove a service's listener/pool entirely (its expose config was deleted). Idempotent:
    /// removing an already-absent service succeeds.
    func remove(service: String) -> LBReconcileResult
}

// SPDX-License-Identifier: Apache-2.0
// ConfigApplier.swift — the seam between the nginx provider and a concrete nginx install.
//
// The provider is a pure orchestrator: render → diff → (validate → swap → reload). It never
// touches the filesystem or shells out directly; it drives this seam. That keeps the provider
// Foundation-free and testable, and lets the real applier (NginxApplier, which writes temp
// files, runs `nginx -t`, atomically swaps, and `nginx -s reload`s a LOCAL nginx) be replaced
// by an in-memory fake when nginx is absent in CI, or — later — by a remote-delivery applier
// (SSH / agent / API) that programs a non-local nginx (the SC6 transport seam).
//
// The apply contract the seam guarantees (and the fake must honor to be a faithful stand-in):
//   - validate-before-swap: a config that fails validation is NEVER made active; `active`
//     still returns the previous config and `apply` returns ok=false with the error.
//   - atomic swap: temp → validate → atomic rename; a crash mid-apply leaves the previously
//     active config intact (never a partial/active broken config).
//
// Foundation-free seam definition; concrete appliers may use Foundation.

/// The outcome of an apply/remove: `ok` plus, on failure, the validator/reload error verbatim.
struct ApplyOutcome: Equatable {
    var ok: Bool
    var error: String?

    static let success = ApplyOutcome(ok: true, error: nil)
    static func failed(_ message: String) -> ApplyOutcome { ApplyOutcome(ok: false, error: message) }
}

/// Programs one nginx with per-service config fragments. Keyed by service so each service's
/// config is swapped independently (one `<confDir>/<service>.conf`), while validation/reload
/// act on the whole nginx config tree.
protocol ConfigApplier: AnyObject {
    /// Validate `config` for `service` and, if valid, atomically make it active and reload.
    /// On validation failure the active config is unchanged and the error is returned.
    func apply(service: String, config: String) -> ApplyOutcome

    /// Remove a service's config fragment and reload. Idempotent.
    func remove(service: String) -> ApplyOutcome

    /// The config currently active for a service, or nil if none — the source of truth the
    /// provider diffs against (so a fresh provider after a restart re-syncs from reality).
    func active(service: String) -> String?
}

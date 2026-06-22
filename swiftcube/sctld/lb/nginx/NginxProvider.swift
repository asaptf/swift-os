// SPDX-License-Identifier: Apache-2.0
// NginxProvider.swift — the nginx LBProvider: pure renderer + applier seam, idempotent (SC6).
//
// `reconcile` is the single idempotent apply step the LB programmer loop calls:
//   1. render  — service + ready endpoints → nginx config (NginxRenderer, pure).
//   2. diff    — hash-compare against the config currently active on nginx (via the applier).
//                Equal ⇒ nothing to do: no rewrite, no reload (`changed == false`). This is the
//                "no needless reloads" rule, enforced at the rendered-config level.
//   3. apply   — otherwise hand the config to the applier, which validates (`nginx -t`), then
//                atomically swaps and gracefully reloads (`nginx -s reload`, draining old
//                workers so a backend removed by a rollout finishes its in-flight requests).
//
// validate-before-swap lives in the applier; the provider just reports its outcome. The
// `generation` it returns is the CRC32 of the config that is ACTUALLY active afterward (read
// back from the applier), so on a failed apply the generation reflects the still-serving config,
// not the rejected candidate. Foundation-free — it only drives the renderer and the seam.

final class NginxProvider: LBProvider {
    let name = "nginx"
    private let applier: ConfigApplier

    init(applier: ConfigApplier) { self.applier = applier }

    func reconcile(_ desired: LBDesiredState) -> LBReconcileResult {
        let config = NginxRenderer.render(desired)

        // Idempotent diff: if the rendered config already matches what is active, reload nothing.
        if let cur = applier.active(service: desired.service), cur == config {
            return .ok(generation: cubeCrc32(Array(config.utf8)), changed: false)
        }

        let outcome = applier.apply(service: desired.service, config: config)
        let generation = activeGeneration(desired.service)
        if outcome.ok {
            return .ok(generation: generation, changed: true)
        } else {
            // Validate/reload failed: the active config is unchanged; surface the error.
            return .failure(generation: generation, outcome.error ?? "nginx apply failed")
        }
    }

    func remove(service: String) -> LBReconcileResult {
        let outcome = applier.remove(service: service)
        let generation = activeGeneration(service)
        if outcome.ok {
            return .ok(generation: generation, changed: true)
        } else {
            return .failure(generation: generation, outcome.error ?? "nginx remove failed")
        }
    }

    /// CRC32 of whatever config is active for the service now (0 if none) — the honest
    /// "applied generation" for status, independent of whether the last apply succeeded.
    private func activeGeneration(_ service: String) -> UInt32 {
        guard let cur = applier.active(service: service) else { return 0 }
        return cubeCrc32(Array(cur.utf8))
    }
}

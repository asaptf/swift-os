// SPDX-License-Identifier: Apache-2.0
// Probe.swift — the SC5 probe spec, prober seam, and outcome type.
//
// A probe turns "a Cell is running" into "a Cell is ready/alive". SC5 ships two probe
// kinds — `http` (GET a path:port, 2xx/3xx ⇒ healthy) and `tcp` (a connect succeeds) —
// plus an EXEC seam left for C6 (in-Cell command execution is not yet available; see the
// `.exec` case below, which the runner treats as unconfigured until C6 lands).
//
// Readiness vs liveness is the contract everything downstream stands on (SWIFTCUBE_DESIGN
// §8, the SC5 milestone):
//   • readiness — does the Cell want traffic right now? A readiness failure sets
//     `ready=false` so the endpoints loop drops the Cell from `/endpoints/<service>`, but
//     it does NOT restart the Cell. Recovery flips it back with no churn.
//   • liveness  — is the Cell wedged and unrecoverable? A liveness failure past its
//     threshold triggers SC3's restart machinery (the Cell is out of endpoints while it
//     restarts, because the fresh generation re-enters its readiness window).
// Both are debounced by consecutive success/failure thresholds so a single blip never
// flips state, and neither fails before the per-probe `initialDelay` startup window.
//
// Foundation-free; little-endian ByteIO, like every other cubestore record. `ProbeSpec`
// rides along in `CellSpec`'s SC5 trailing section (see CellSpec.swift), so `slet` reads
// it straight off the Assignment it already watches.

/// How a probe checks health. `.none` ⇒ no probe configured (the Cell is then ready as
/// soon as it runs / never fails liveness). `.exec` is the C6 seam — recorded so the wire
/// format is stable, but the SC5 runner treats it as unconfigured (no in-Cell exec yet).
enum ProbeKind: UInt8, Equatable {
    case none = 0
    case http = 1
    case tcp  = 2
    case exec = 3   // SC5 seam: needs in-Cell command execution via C6 — not run yet
}

/// One probe's full specification (a manifest `health.readiness` / `health.liveness`).
///
/// `successThreshold` / `failureThreshold` are CONSECUTIVE counts: state flips only after
/// that many same-outcome results in a row, which is what debounces flapping. A probe that
/// exceeds `timeoutSeconds` counts as one failure. Defaults match the manifest sketch
/// (§10): a 1s readiness period, a single success to become ready, three failures to drop.
struct ProbeSpec: Equatable {
    var kind: ProbeKind = .none
    var port: UInt16 = 0                 // the port to hit (http GET / tcp connect)
    var httpPath: String = ""            // http only, e.g. "/healthz"; ignored for tcp
    var periodSeconds: UInt32 = 10       // how often to run the probe
    var timeoutSeconds: UInt32 = 1       // a probe hanging past this counts as a failure
    var initialDelaySeconds: UInt32 = 0  // startup grace: no probe runs (and none fails) before this
    var successThreshold: UInt32 = 1     // consecutive successes to flip healthy
    var failureThreshold: UInt32 = 3     // consecutive failures to flip unhealthy

    /// True iff this probe is actually exercised by the SC5 runner (http or tcp). `.none`
    /// and the `.exec` seam are inert: the runner leaves the Cell ready / never trips it.
    var isActive: Bool { kind == .http || kind == .tcp }

    func encode(into w: inout ByteWriter) {
        w.u8(kind.rawValue)
        w.u32(UInt32(port))
        w.blob(Array(httpPath.utf8))
        w.u32(periodSeconds)
        w.u32(timeoutSeconds)
        w.u32(initialDelaySeconds)
        w.u32(successThreshold)
        w.u32(failureThreshold)
    }

    static func decode(_ r: inout ByteReader) -> ProbeSpec? {
        guard let k = r.u8(), let kind = ProbeKind(rawValue: k), let p = r.u32(),
              let pathB = r.blob(), let per = r.u32(), let to = r.u32(), let id = r.u32(),
              let st = r.u32(), let ft = r.u32() else { return nil }
        return ProbeSpec(kind: kind, port: UInt16(truncatingIfNeeded: p),
                         httpPath: String(decoding: pathB, as: UTF8.self),
                         periodSeconds: per, timeoutSeconds: to, initialDelaySeconds: id,
                         successThreshold: st, failureThreshold: ft)
    }
}

/// The outcome of one probe attempt. `.timeout` is kept distinct from `.failure` for
/// observability, but the runner counts both as a failure against `failureThreshold`.
enum ProbeOutcome: Equatable {
    case success
    case failure
    case timeout
}

/// The seam the probe runner executes one attempt through. Two implementations sit behind
/// it: a deterministic host `FakeProber` (the acceptance tests' fake http/tcp servers) and
/// the on-device `NetProbe` over the SC2 network stack. Class-bound (`AnyObject`) so it
/// monomorphizes to a single existential under Embedded Swift, like the `CellSupervisor`
/// and `CubeClock` seams.
protocol ProbeProber: AnyObject {
    /// Run one probe attempt described by `spec` against the Cell at `address` (the Cell's
    /// reachable host, as reported by slet). Returns `.success` for a healthy result
    /// (tcp connect / http 2xx-3xx), `.failure` otherwise, `.timeout` if it hung past
    /// `spec.timeoutSeconds`.
    func probe(_ spec: ProbeSpec, address: String) -> ProbeOutcome
}

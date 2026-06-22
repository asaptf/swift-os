// SPDX-License-Identifier: Apache-2.0
// FakeProber.swift — a deterministic host ProbeProber for the SC5 acceptance tests.
//
// The fake stands in for the http/tcp servers a probe would hit: a test scripts the
// outcome per route (an http path:port, or a tcp port) and flips it over time to drive the
// readiness/liveness state machine — pass → ready, fail → not ready, hang → timeout. It
// records each call so a test can assert a probe actually ran (or did NOT, inside the
// startup window). It is NOT wired into the on-device `slet` (only `NetProbe` is); it lives
// beside the seam it implements and is compiled only into the probe test. Foundation-free.

final class FakeProber: ProbeProber {
    /// Default outcome for any route a test did not script.
    var fallback: ProbeOutcome = .success

    private var outcomes: [String: ProbeOutcome] = [:]   // routeKey → outcome
    private(set) var callCount = 0
    private(set) var lastAddress = ""

    init(fallback: ProbeOutcome = .success) { self.fallback = fallback }

    /// A stable key identifying a probe's target: http distinguishes by path (readiness and
    /// liveness commonly share a port but differ by path, e.g. /healthz vs /livez); tcp by port.
    static func routeKey(_ s: ProbeSpec) -> String {
        s.kind == .http ? "http \(s.port) \(s.httpPath)" : "tcp \(s.port)"
    }

    /// Script the outcome for the route described by `spec`.
    func set(_ spec: ProbeSpec, _ outcome: ProbeOutcome) {
        outcomes[FakeProber.routeKey(spec)] = outcome
    }
    /// Script an http route directly.
    func setHTTP(port: UInt16, path: String, _ outcome: ProbeOutcome) {
        outcomes["http \(port) \(path)"] = outcome
    }
    /// Script a tcp route directly.
    func setTCP(port: UInt16, _ outcome: ProbeOutcome) {
        outcomes["tcp \(port)"] = outcome
    }

    func probe(_ spec: ProbeSpec, address: String) -> ProbeOutcome {
        callCount += 1
        lastAddress = address
        return outcomes[FakeProber.routeKey(spec)] ?? fallback
    }
}

// SPDX-License-Identifier: Apache-2.0
// lb_test.swift — SC6 host acceptance for the LB provider interface + nginx provider.
//
// Two fakes stand in for the deferred real dependencies (per the milestone):
//   - FakeApplier: an in-memory ConfigApplier that faithfully models validate-before-swap and
//     atomic-swap, with injectable rejection (a failing `nginx -t`) and a mid-apply crash — so
//     the nginx PROVIDER is tested with no real nginx in CI.
//   - FakeProvider: a counting LBProvider with injectable transient failure — so the LB LOOP
//     (leader gate, debounce, backoff, status) is tested independent of nginx rendering.
//
// Cases (per the SC6 ladder, 1–10):
//   1  endpoints {A,B} + expose nginx :80 → config rendered (upstream{A,B} + :80 server) and
//      applied (validated + reloaded), end-to-end through the loop
//   2  golden: the rendered config matches the expected upstream/server/proxy_pass/health bytes
//   3  idempotency: reconcile with unchanged endpoints → no rewrite, no reload
//   4  rolling: {A,B} → {B,C} → upstream becomes {B,C} with exactly one reload (A drained)
//   5  validate gating: a config failing the validator is not swapped; the previous stays; error
//   6  atomic swap: a crash simulated mid-apply leaves the previously-active config intact
//   7  debounce: rapid endpoint changes within the window produce one reconcile/reload
//   8  retry/backoff: a transient apply failure is retried; status error → success; loop survives
//   9  leader-only: under a 2-controller sim, only the leader programs nginx — no dueling reloads
//   10 empty pool: zero ready endpoints → a valid no-backends config (503), not a broken upstream
//
// Foundation is used only by this harness.

import Foundation

// MARK: - Fakes

/// In-memory ConfigApplier modeling validate-before-swap + atomic swap.
final class FakeApplier: ConfigApplier {
    private var configs: [String: String] = [:]
    private(set) var reloads = 0
    private(set) var validations = 0
    var reject = false              // model a failing `nginx -t` (validate-before-swap)
    var crashBeforeSwap = false     // model a crash after validate, before the atomic swap

    func apply(service: String, config: String) -> ApplyOutcome {
        validations += 1
        if reject { return .failed("nginx -t: [emerg] configuration test failed") }  // active unchanged
        if crashBeforeSwap { return .failed("crash: process died mid-apply") }        // no swap, active unchanged
        configs[service] = config       // atomic swap
        reloads += 1                     // graceful reload
        return .success
    }
    func remove(service: String) -> ApplyOutcome {
        if configs[service] != nil { configs[service] = nil; reloads += 1 }
        return .success
    }
    func active(service: String) -> String? { configs[service] }
}

/// Counting LBProvider with injectable transient failure, for loop-level tests.
final class FakeProvider: LBProvider {
    let name = "nginx"
    private(set) var reconciles = 0
    private(set) var removes = 0
    private(set) var lastBackends: [Endpoint] = []
    var failNext = 0                // fail the next N reconciles (transient apply failure)
    private var gen: UInt32 = 0

    func reconcile(_ desired: LBDesiredState) -> LBReconcileResult {
        reconciles += 1
        lastBackends = desired.backends
        if failNext > 0 { failNext -= 1; return .failure(generation: gen, "transient apply failure") }
        gen = desired.fingerprint()
        return .ok(generation: gen, changed: true)
    }
    func remove(service: String) -> LBReconcileResult {
        removes += 1
        return .ok(generation: 0, changed: true)
    }
}

@main struct LBTest {
    static var failed = false
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    static func main() {
        case1_renderAndApply()
        case2_golden()
        case3_idempotency()
        case4_rollingFlip()
        case5_validateGating()
        case6_atomicSwap()
        case7_debounce()
        case8_retryBackoff()
        case9_leaderOnly()
        case10_emptyPool()

        if failed { FileHandle.standardError.write(Data("lb-test: FAILED\n".utf8)); exit(1) }
        print("lb-test: all SC6 cases (1–10) passed")
    }

    // MARK: - Builders

    static func ep(_ cid: String, _ addr: String, _ port: UInt16 = 8080) -> Endpoint {
        Endpoint(cellId: cid, address: addr, port: port)
    }
    static func desired(_ service: String, _ eps: [Endpoint], port: UInt16 = 80,
                        proto: ListenProtocol = .http, path: String = "", hport: UInt16 = 0) -> LBDesiredState {
        LBDesiredState(service: service, listener: LBListener(port: port, proto: proto, tlsCertRef: ""),
                       backends: eps, health: LBHealthCheck(path: path, port: hport))
    }

    /// Seed the store with an expose config + an endpoint set (the way sctl/SC5 would).
    final class Fixture {
        let store = openRamCubeStore()
        func putExpose(_ ex: ServiceExpose) { _ = store.apply([.put(key: LBKeys.expose(ex.service), value: ex.encode())]) }
        func delExpose(_ svc: String) { _ = store.apply([.delete(key: LBKeys.expose(svc))]) }
        func putEndpoints(_ svc: String, _ eps: [Endpoint]) {
            var s = eps; s.sort(by: Endpoint.less)
            _ = store.apply([.put(key: EndpointKeys.endpoints(svc), value: EndpointSet(service: svc, endpoints: s).encode())])
        }
        func lbStatus(_ svc: String) -> LBStatusRecord? {
            guard let e = store.get(LBKeys.lb(svc)) else { return nil }
            return LBStatusRecord.decode(e.value)
        }
    }

    // MARK: - Case 1: render + apply end-to-end through the loop

    static func case1_renderAndApply() {
        let f = Fixture()
        f.putExpose(ServiceExpose(service: "web", listenPort: 80))
        f.putEndpoints("web", [ep("web--r1-s0-g1", "10.0.0.1"), ep("web--r1-s1-g1", "10.0.0.2")])

        let applier = FakeApplier()
        let clock = ManualClock(100)
        let loop = LBLoop(store: f.store, clock: clock, provider: NginxProvider(applier: applier), debounceWindow: 0)
        loop.step()

        guard let cfg = applier.active(service: "web") else { check(false, "1: config applied"); return }
        check(cfg.contains("upstream web_pool {"), "1: upstream block rendered")
        check(cfg.contains("server 10.0.0.1:8080"), "1: backend A in pool")
        check(cfg.contains("server 10.0.0.2:8080"), "1: backend B in pool")
        check(cfg.contains("listen 80;"), "1: :80 listener rendered")
        check(cfg.contains("proxy_pass http://web_pool;"), "1: proxy_pass into the pool")
        check(applier.reloads == 1, "1: applied exactly once (validated + reloaded)")
        check(applier.validations == 1, "1: validated before swap")
        guard let st = f.lbStatus("web") else { check(false, "1: /lb/web status written"); return }
        check(st.healthy && st.lastError.isEmpty, "1: status healthy, no error")
        check(st.backends == 2 && st.generation == cubeCrc32(Array(cfg.utf8)), "1: status records generation + backend count")
    }

    // MARK: - Case 2: golden config

    static func case2_golden() {
        let d = desired("web", [ep("web--r1-s0-g1", "10.0.0.1"), ep("web--r1-s1-g1", "10.0.0.2")],
                        port: 80, path: "/healthz", hport: 8080)
        let expected = """
        # managed by sctld — service web
        # generated by the SwiftCube LB programmer loop (SC6); do not edit by hand
        upstream web_pool {
            server 10.0.0.1:8080 max_fails=3 fail_timeout=10s;  # web--r1-s0-g1
            server 10.0.0.2:8080 max_fails=3 fail_timeout=10s;  # web--r1-s1-g1
        }
        server {
            listen 80;
            # health: readiness /healthz on 8080 (probed by slet/SC5; passive here)
            location / {
                proxy_pass http://web_pool;
                proxy_next_upstream error timeout http_502 http_503 http_504;
                proxy_set_header Host $host;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            }
        }

        """
        let got = NginxRenderer.render(d)
        check(got == expected, "2: rendered config matches the golden bytes")
        if got != expected {
            FileHandle.standardError.write(Data("---- got ----\n\(got)\n---- expected ----\n\(expected)\n".utf8))
        }
    }

    // MARK: - Case 3: idempotency (unchanged endpoints → no rewrite, no reload)

    static func case3_idempotency() {
        let applier = FakeApplier()
        let provider = NginxProvider(applier: applier)
        let d = desired("web", [ep("a", "10.0.0.1"), ep("b", "10.0.0.2")])

        let r1 = provider.reconcile(d)
        check(r1.changed && applier.reloads == 1, "3: first reconcile applies")
        let r2 = provider.reconcile(d)              // identical desired
        check(!r2.changed && applier.reloads == 1, "3: unchanged desired → no rewrite, no reload")
        check(r2.generation == r1.generation, "3: generation stable across a no-op reconcile")
    }

    // MARK: - Case 4: rolling flips backends with exactly one reload

    static func case4_rollingFlip() {
        let applier = FakeApplier()
        let provider = NginxProvider(applier: applier)
        _ = provider.reconcile(desired("web", [ep("a", "10.0.0.1"), ep("b", "10.0.0.2")]))
        let before = applier.reloads

        let r = provider.reconcile(desired("web", [ep("b", "10.0.0.2"), ep("c", "10.0.0.3")]))
        check(r.changed, "4: the flip changes the config")
        check(applier.reloads - before == 1, "4: {A,B}→{B,C} is exactly one reload (A drained by graceful reload)")
        guard let cfg = applier.active(service: "web") else { check(false, "4: config present"); return }
        check(cfg.contains("server 10.0.0.2:8080") && cfg.contains("server 10.0.0.3:8080"),
              "4: pool is now {B,C}")
        check(!cfg.contains("server 10.0.0.1:8080"), "4: A removed from the pool")
    }

    // MARK: - Case 5: validate gating (bad config never swapped; previous stays; error reported)

    static func case5_validateGating() {
        let applier = FakeApplier()
        let provider = NginxProvider(applier: applier)
        // Establish a good, active config first.
        _ = provider.reconcile(desired("web", [ep("a", "10.0.0.1")]))
        let good = applier.active(service: "web")
        let reloadsAfterGood = applier.reloads

        // Now the validator rejects the next candidate.
        applier.reject = true
        let r = provider.reconcile(desired("web", [ep("a", "10.0.0.1"), ep("b", "10.0.0.2")]))
        check(r.error != nil, "5: a config failing nginx -t is reported as an error")
        check(!r.changed, "5: a rejected config is not applied")
        check(applier.active(service: "web") == good, "5: the previous config stays active")
        check(applier.reloads == reloadsAfterGood, "5: no reload happened on rejection")
        check(r.generation == cubeCrc32(Array((good ?? "").utf8)), "5: generation still reflects the active config")
    }

    // MARK: - Case 6: atomic swap (crash mid-apply leaves previous config intact)

    static func case6_atomicSwap() {
        let applier = FakeApplier()
        let provider = NginxProvider(applier: applier)
        _ = provider.reconcile(desired("web", [ep("a", "10.0.0.1")]))
        let good = applier.active(service: "web")
        let reloadsBefore = applier.reloads

        applier.crashBeforeSwap = true
        let r = provider.reconcile(desired("web", [ep("a", "10.0.0.1"), ep("b", "10.0.0.2")]))
        check(r.error != nil, "6: a crash mid-apply is surfaced as an error")
        check(applier.active(service: "web") == good, "6: the previously-active config is intact after a mid-apply crash")
        check(applier.reloads == reloadsBefore, "6: no partial reload")
    }

    // MARK: - Case 7: debounce (a burst of changes → one reconcile)

    static func case7_debounce() {
        let f = Fixture()
        f.putExpose(ServiceExpose(service: "web", listenPort: 80))
        f.putEndpoints("web", [ep("a", "10.0.0.1")])
        let provider = FakeProvider()
        let clock = ManualClock(100)
        let loop = LBLoop(store: f.store, clock: clock, provider: provider, debounceWindow: 2)

        loop.step()                                              // t=100: change pending, not settled
        check(provider.reconciles == 0, "7: first change is debounced (not yet settled)")
        clock.advance(1); f.putEndpoints("web", [ep("b", "10.0.0.2")]); loop.step()   // t=101: change again, resets timer
        check(provider.reconciles == 0, "7: a change within the window resets the timer")
        clock.advance(1); f.putEndpoints("web", [ep("c", "10.0.0.3")]); loop.step()   // t=102: change again
        check(provider.reconciles == 0, "7: still coalescing")

        clock.advance(2); loop.step()                           // t=104: settled (no change for the window)
        check(provider.reconciles == 1, "7: the burst coalesces into exactly one reconcile")
        check(provider.lastBackends.map { $0.cellId } == ["c"], "7: the one reconcile applies the final set")
        loop.step()                                             // steady state
        check(provider.reconciles == 1, "7: a converged set reconciles no further")
    }

    // MARK: - Case 8: retry / backoff (transient failure retried; status error → success)

    static func case8_retryBackoff() {
        let f = Fixture()
        f.putExpose(ServiceExpose(service: "web", listenPort: 80))
        f.putEndpoints("web", [ep("a", "10.0.0.1")])
        let provider = FakeProvider()
        provider.failNext = 2                                    // first two applies fail transiently
        let clock = ManualClock(0)
        let loop = LBLoop(store: f.store, clock: clock, provider: provider,
                          debounceWindow: 0, backoffBase: 1, backoffMax: 30)

        loop.step()                                             // t=0: attempt 1 → fail, backoff to t=1
        check(provider.reconciles == 1, "8: first attempt runs")
        check(f.lbStatus("web")?.healthy == false && !(f.lbStatus("web")?.lastError.isEmpty ?? true),
              "8: failure surfaced in /lb status")
        loop.step()                                             // t=0: backing off, no attempt
        check(provider.reconciles == 1, "8: backoff suppresses an immediate retry")

        clock.advance(1); loop.step()                           // t=1: attempt 2 → fail, backoff to t=3
        check(provider.reconciles == 2, "8: retried after backoff elapsed")
        clock.advance(2); loop.step()                           // t=3: attempt 3 → success
        check(provider.reconciles == 3, "8: retried again")
        check(f.lbStatus("web")?.healthy == true && (f.lbStatus("web")?.lastError.isEmpty ?? false),
              "8: status recovers to healthy with no error (loop survived)")
    }

    // MARK: - Case 9: leader-only (only the leader programs nginx)

    static func case9_leaderOnly() {
        let f = Fixture()
        f.putExpose(ServiceExpose(service: "web", listenPort: 80))
        f.putEndpoints("web", [ep("a", "10.0.0.1")])
        let leaderP = FakeProvider(), followerP = FakeProvider()
        let clock = ManualClock(0)
        let leader = LBLoop(store: f.store, clock: clock, provider: leaderP, isLeader: true, debounceWindow: 0)
        let follower = LBLoop(store: f.store, clock: clock, provider: followerP, isLeader: false, debounceWindow: 0)

        for _ in 0..<3 { follower.step(); leader.step() }
        check(followerP.reconciles == 0, "9: a follower never programs the LB (no dueling reloads)")
        check(leaderP.reconciles >= 1, "9: the leader programs the LB")
        check(f.lbStatus("web") != nil, "9: only the leader wrote /lb status")
    }

    // MARK: - Case 10: empty pool (valid no-backends config, not a broken upstream)

    static func case10_emptyPool() {
        let applier = FakeApplier()
        let provider = NginxProvider(applier: applier)
        let r = provider.reconcile(desired("web", []))         // zero ready endpoints
        check(r.error == nil && r.changed, "10: an empty pool still produces a valid, applied config")
        guard let cfg = applier.active(service: "web") else { check(false, "10: config applied"); return }
        check(!cfg.contains("upstream"), "10: no (broken) empty upstream block is emitted")
        check(cfg.contains("listen 80;"), "10: the listener is still up")
        check(cfg.contains("return 503;"), "10: explicit no-backends 503 response")
    }
}

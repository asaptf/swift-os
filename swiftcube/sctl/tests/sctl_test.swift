// SPDX-License-Identifier: Apache-2.0
// sctl_test.swift — SC9a host acceptance for the `sctl` command layer (case 2).
//
// Drives the command dispatcher over a `StoreControlClient` backed by an in-process cubestore —
// the milestone's "fake control client" — with no transport, no clock, no kernel. It proves the
// apply→get→scale→delete round-trip and the revision discipline the rollout (SC9b) stands on:
//   • apply upserts the Deployment/Service/Expose objects and assigns revision 1;
//   • a TEMPLATE change bumps the revision; a pure replica change (re-apply or `scale`) keeps it;
//   • an unchanged manifest is a no-op;
//   • get/describe/scale/delete behave and `rollout status` reflects store state.
// Foundation is used only by the harness (printing/exit).

import Foundation

@main struct SctlTest {
    static var failed = false
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    static let digestHex = String(repeating: "9f2c", count: 16)
    static let digestHex2 = String(repeating: "abcd", count: 16)

    /// Build a manifest with adjustable image digest / replicas / cpu.
    static func manifest(app: String = "web-api", digest: String = digestHex,
                         replicas: Int = 4, cpu: String = "100m") -> [UInt8] {
        Array("""
        app: \(app)
        image: registry.local/\(app)@sha256:\(digest)
        replicas: \(replicas)
        command: [ /bin/app ]
        update: { strategy: rolling, maxSurge: 1, maxUnavailable: 0 }
        resources: { cpu: \(cpu), memory: 64Mi }
        ports:
          - name: http
            container: 8080
            expose: { via: lb, provider: nginx, listen: 443, protocol: https, tlsCertRef: web-tls }
        capabilities: [ net.listen:8080 ]
        health:
          readiness: { http: /healthz, port: 8080, period: 1s }
        placement: { spread: node, nodeSelector: { zone: eu-central } }
        """.utf8)
    }

    final class Fixture {
        let store = openRamCubeStore()
        lazy var client = StoreControlClient(store: store)
        func run(_ args: [String], manifest: [UInt8]? = nil) -> CommandResult {
            dispatch(args, client: client, manifest: manifest)
        }
        func dep(_ app: String) -> DeploymentSpec? {
            client.get(SchedulerKeys.appSpec(app)).flatMap { DeploymentSpec.decode($0.value) }
        }
    }

    static func main() {
        case2_applyCreates()
        case2_applyIdempotentAndBump()
        case2_scaleKeepsRevision()
        case2_getAndDescribe()
        case2_rolloutStatus()
        case2_delete()
        case2_errors()
        case2_config()

        if failed { FileHandle.standardError.write(Data("sctl-test: FAILED\n".utf8)); exit(1) }
        print("sctl-test: all SC9a CLI round-trip cases passed")
    }

    // MARK: - apply creates all three objects at revision 1

    static func case2_applyCreates() {
        let f = Fixture()
        let r = f.run(["apply", "-f", "web.yaml"], manifest: manifest())
        check(r.exitCode == 0, "2: apply succeeds (got \(r.output))")
        check(contains(r.output, "created") && contains(r.output, "revision 1"), "2: apply reports created revision 1")

        guard let d = f.dep("web-api") else { check(false, "2: deployment written"); return }
        check(d.replicas == 4 && d.revision == 1, "2: deployment header")
        check(f.client.get(ServiceKeys.svcSpec("web-api")) != nil, "2: svcspec written")
        guard let ek = f.client.get(LBKeys.expose("web-api")), let ex = ServiceExpose.decode(ek.value) else {
            check(false, "2: expose written"); return
        }
        check(ex.listenPort == 443 && ex.proto == .https, "2: expose listener mapped")
    }

    // MARK: - idempotency + revision bump on a template change

    static func case2_applyIdempotentAndBump() {
        let f = Fixture()
        _ = f.run(["apply", "-f", "w"], manifest: manifest())
        let again = f.run(["apply", "-f", "w"], manifest: manifest())
        check(contains(again.output, "unchanged") && contains(again.output, "revision 1"),
              "2: re-applying the same manifest is a no-op (got \(again.output))")
        check(f.dep("web-api")?.revision == 1, "2: revision stays 1 on no-op")

        // A pure replica change keeps the revision (not a template change).
        let scaledApply = f.run(["apply", "-f", "w"], manifest: manifest(replicas: 6))
        check(scaledApply.exitCode == 0, "2: apply with new replicas ok")
        check(f.dep("web-api")?.revision == 1 && f.dep("web-api")?.replicas == 6,
              "2: replica-only apply keeps revision 1, updates replicas")

        // A template change (new image digest) bumps the revision.
        let bumped = f.run(["apply", "-f", "w"], manifest: manifest(digest: digestHex2, replicas: 6))
        check(contains(bumped.output, "configured") && contains(bumped.output, "revision 2"),
              "2: template change bumps to revision 2 (got \(bumped.output))")
        check(f.dep("web-api")?.revision == 2, "2: revision is now 2")
    }

    // MARK: - scale keeps the revision

    static func case2_scaleKeepsRevision() {
        let f = Fixture()
        _ = f.run(["apply", "-f", "w"], manifest: manifest(replicas: 4))
        let r = f.run(["scale", "web-api", "--replicas=2"])
        check(r.exitCode == 0 && contains(r.output, "scaled to 2"), "2: scale succeeds (got \(r.output))")
        check(f.dep("web-api")?.replicas == 2 && f.dep("web-api")?.revision == 1,
              "2: scale sets replicas=2, keeps revision 1")
        // Scaling to the same count is a no-op.
        let same = f.run(["scale", "web-api", "--replicas=2"])
        check(contains(same.output, "unchanged"), "2: scaling to the same count is a no-op")
        // Scaling a missing app errors.
        let missing = f.run(["scale", "ghost", "--replicas=3"])
        check(missing.exitCode == 1 && contains(missing.output, "not found"), "2: scale missing app errors")
    }

    // MARK: - get / describe

    static func case2_getAndDescribe() {
        let f = Fixture()
        check(contains(f.run(["get", "deployments"]).output, "no deployments"), "2: empty get")
        _ = f.run(["apply", "-f", "w"], manifest: manifest())
        let g = f.run(["get", "deployments"])
        check(contains(g.output, "web-api") && contains(g.output, "NAME"), "2: get deployments lists the app")
        let svc = f.run(["get", "services"])
        check(contains(svc.output, "web-api") && contains(svc.output, "8080"), "2: get services")
        let ds = f.run(["describe", "deployment", "web-api"])
        check(contains(ds.output, "revision:") && contains(ds.output, "readiness:"), "2: describe deployment")
        check(contains(f.run(["describe", "deployment", "ghost"]).output, "not found"), "2: describe missing")
    }

    // MARK: - rollout status reflects store state

    static func case2_rolloutStatus() {
        let f = Fixture()
        _ = f.run(["apply", "-f", "w"], manifest: manifest(replicas: 2))
        // Seed two ready endpoints (as the SC5 endpoints loop would).
        let set = EndpointSet(service: "web-api", endpoints: [
            Endpoint(cellId: "web-api--r1-s0-g1", address: "10.0.0.1", port: 8080),
            Endpoint(cellId: "web-api--r1-s1-g1", address: "10.0.0.2", port: 8080),
        ])
        _ = f.client.put(EndpointKeys.endpoints("web-api"), set.encode())
        let st = f.run(["rollout", "status", "web-api"])
        check(contains(st.output, "revision:  1") && contains(st.output, "ready:     2"),
              "2: rollout status shows revision + ready count (got \(st.output))")
        check(contains(st.output, "Complete"), "2: 2/2 ready ⇒ Complete")
        check(contains(f.run(["rollout", "undo", "web-api"]).output, "SC9b"), "2: undo surfaces the SC9b seam")
    }

    // MARK: - delete

    static func case2_delete() {
        let f = Fixture()
        _ = f.run(["apply", "-f", "w"], manifest: manifest())
        let del = f.run(["delete", "deployment", "web-api"])
        check(del.exitCode == 0 && contains(del.output, "deleted"), "2: delete succeeds")
        check(f.dep("web-api") == nil, "2: /apps spec removed")
        check(f.client.get(ServiceKeys.svcSpec("web-api")) == nil, "2: svcspec removed")
        check(f.client.get(LBKeys.expose("web-api")) == nil, "2: expose removed")
        let again = f.run(["delete", "deployment", "web-api"])
        check(again.exitCode == 1 && contains(again.output, "not found"), "2: deleting twice reports not found")
    }

    // MARK: - error paths

    static func case2_errors() {
        let f = Fixture()
        // Invalid manifest → non-zero, lists the field error.
        let bad = f.run(["apply", "-f", "w"], manifest: Array("app: web\nresources: { cpu: 100m, memory: 64Mi }".utf8))
        check(bad.exitCode == 1 && contains(bad.output, "image"), "2: invalid manifest rejected with reason")
        // apply without -f.
        check(f.run(["apply"], manifest: manifest()).exitCode == 1, "2: apply requires -f")
        // Unknown kind / verb.
        check(f.run(["get", "widgets"]).exitCode == 1, "2: unknown kind errors")
        check(f.run(["frobnicate"]).exitCode == 1, "2: unknown verb errors")
    }

    // MARK: - config parsing (the kubeconfig analog)

    static func case2_config() {
        switch parseConfig(Array("local: /var/lib/sctl".utf8)) {
        case .ok(let c): check(c.isLocal && c.localStateDir == "/var/lib/sctl", "2: local config")
        case .error(let m): check(false, "2: local config should parse (\(m))")
        }
        switch parseConfig(Array("endpoint: https://10.0.0.1:7700\nca: /etc/ca.crt".utf8)) {
        case .ok(let c): check(!c.isLocal && c.endpoint == "https://10.0.0.1:7700" && c.ca == "/etc/ca.crt", "2: remote config")
        case .error(let m): check(false, "2: remote config should parse (\(m))")
        }
        // A config with neither local nor endpoint is rejected.
        if case .ok = parseConfig(Array("ca: /etc/ca.crt".utf8)) { check(false, "2: empty-target config must be rejected") }
    }
}

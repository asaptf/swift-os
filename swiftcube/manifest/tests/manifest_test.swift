// SPDX-License-Identifier: Apache-2.0
// manifest_test.swift — SC9a host acceptance for the manifest parser/validator (case 1).
//
// Golden-parses a representative §10 manifest into the typed `Manifest`, checks every field and
// the mapping onto the cubestore objects the reconcilers already consume (DeploymentSpec /
// ServiceExpose / ServiceSpec), and confirms that a battery of malformed manifests are rejected
// with clear, field-scoped errors. Pure and deterministic: the parser reads only bytes, so there
// is no clock, store, or transport here. Foundation is used only by the harness (printing/exit).

import Foundation

@main struct ManifestTest {
    static var failed = false
    static func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failed = true }
    }

    // A 32-byte (64 hex) content digest.
    static let digestHex = String(repeating: "9f2c", count: 16)

    static let golden = """
    # SwiftCube demo manifest
    app: web-api
    image: registry.local/web-api@sha256:\(digestHex)
    replicas: 4
    command: [ /bin/web-api, --serve ]
    update: { strategy: rolling, maxSurge: 1, maxUnavailable: 0, progressDeadlineSeconds: 300 }
    resources: { cpu: 100m, memory: 64Mi }
    ports:
      - name: http
        container: 8080
        expose: { via: lb, provider: nginx, listen: 443, protocol: https, tlsCertRef: web-api-tls }
    env: { LOG_LEVEL: info, REGION: eu-central }
    secrets: [ db-password ]
    volumes:
      - { name: data, mount: /data, persistent: true, size: 1Gi }
    capabilities: [ net.listen:8080, fs.read:/etc/app ]
    health:
      readiness: { http: /healthz, port: 8080, period: 1s, failureThreshold: 3 }
      liveness: { http: /livez, port: 8080, period: 5s }
    placement: { spread: node, nodeSelector: { zone: eu-central } }
    """

    static func main() {
        case1_goldenParse()
        case1_mapping()
        case1_roundTrip()
        case1_invalidManifests()
        case2_moreInvalidManifests()
        case3_errorAccumulation()
        case4_canaryDefaultRamp()
        case5_scalarParsers()

        if failed { FileHandle.standardError.write(Data("manifest-test: FAILED\n".utf8)); exit(1) }
        print("manifest-test: all SC9a manifest cases passed")
    }

    // MARK: - Golden parse → typed Manifest

    static func parse(_ s: String) -> ManifestResult { parseManifest(Array(s.utf8)) }

    static func case1_goldenParse() {
        guard case .success(let m) = parse(golden) else {
            check(false, "1: golden manifest must parse (got \(parse(golden)))"); return
        }
        check(m.app == "web-api", "1: app")
        check(m.image.algorithm == "sha256", "1: image algorithm")
        check(m.image.digest.count == 32, "1: image digest is 32 bytes")
        check(m.replicas == 4, "1: replicas")
        check(m.command == ["/bin/web-api", "--serve"], "1: command (got \(m.command))")
        check(m.update.strategy == .rolling, "1: update strategy")
        check(m.update.maxSurge == 1 && m.update.maxUnavailable == 0, "1: surge/unavailable")
        check(m.update.progressDeadlineSeconds == 300, "1: progress deadline")
        check(m.resources.cpuMillis == 100, "1: cpu 100m → 100 millicpu")
        check(m.resources.memBytes == 64 << 20, "1: memory 64Mi → bytes")
        check(m.ports.count == 1 && m.ports[0].name == "http" && m.ports[0].container == 8080, "1: ports")
        guard let ex = m.ports.first?.expose else { check(false, "1: expose present"); return }
        check(ex.via == "lb" && ex.provider == "nginx" && ex.listen == 443 && ex.proto == .https
              && ex.tlsCertRef == "web-api-tls", "1: expose block")
        check(m.env == ["LOG_LEVEL=info", "REGION=eu-central"], "1: env (got \(m.env))")
        check(m.secrets == ["db-password"], "1: secrets")
        check(m.volumes.count == 1 && m.volumes[0].name == "data" && m.volumes[0].mount == "/data"
              && m.volumes[0].persistent && m.volumes[0].sizeBytes == 1 << 30, "1: volume")
        check(m.capabilities == ["net.listen:8080", "fs.read:/etc/app"], "1: capabilities")
        check(m.health.readiness.kind == .http && m.health.readiness.httpPath == "/healthz"
              && m.health.readiness.port == 8080 && m.health.readiness.periodSeconds == 1
              && m.health.readiness.failureThreshold == 3, "1: readiness probe")
        check(m.health.liveness.kind == .http && m.health.liveness.httpPath == "/livez"
              && m.health.liveness.periodSeconds == 5, "1: liveness probe")
        check(m.placement.spread == "node" && m.placement.nodeSelector == ["zone=eu-central"],
              "1: placement nodeSelector")
    }

    // MARK: - Mapping → cubestore objects

    static func case1_mapping() {
        guard case .success(let m) = parse(golden) else { check(false, "1m: parse"); return }

        let dep = m.toDeployment(revision: 7)
        check(dep.app == "web-api" && dep.replicas == 4 && dep.revision == 7, "1m: deployment header")
        check(dep.request.cpuMillis == 100 && dep.request.memBytes == 64 << 20, "1m: scheduling request")
        check(dep.nodeSelector == ["zone=eu-central"], "1m: deployment selector")
        check(dep.template.image.digest.count == 32 && dep.template.image.signature.isEmpty,
              "1m: image ref (signature is the registry seam)")
        check(dep.template.args == ["/bin/web-api", "--serve"], "1m: template args")
        check(dep.template.env == ["LOG_LEVEL=info", "REGION=eu-central"], "1m: template env")
        check(dep.template.capabilities == ["net.listen:8080", "fs.read:/etc/app"], "1m: template caps")
        check(dep.template.volume?.mountPath == "/data" && dep.template.volume?.sizeBytes == 1 << 30,
              "1m: template volume")
        check(dep.template.service == "web-api" && dep.template.port == 8080, "1m: service/port wiring")
        check(dep.template.readiness.kind == .http && dep.template.liveness.kind == .http,
              "1m: probes carried onto the template")

        guard let expose = m.toExpose() else { check(false, "1m: expose mapping present"); return }
        check(expose.service == "web-api" && expose.provider == "nginx" && expose.listenPort == 443
              && expose.proto == .https && expose.tlsCertRef == "web-api-tls", "1m: ServiceExpose")
        check(expose.healthPath == "/healthz" && expose.healthPort == 8080, "1m: expose health from readiness")

        let svc = m.toServiceSpec()
        check(svc.name == "web-api" && svc.selector == "web-api" && svc.servicePort == 8080, "1m: ServiceSpec")
    }

    // MARK: - DeploymentSpec encode/decode round-trip (the SC9 template trailing section survives)

    static func case1_roundTrip() {
        guard case .success(let m) = parse(golden) else { check(false, "1r: parse"); return }
        let dep = m.toDeployment(revision: 12)
        guard let back = DeploymentSpec.decode(dep.encode()) else { check(false, "1r: decode"); return }
        check(back == dep, "1r: DeploymentSpec survives encode→decode (incl. service/port/probes)")
    }

    // MARK: - Invalid manifests are rejected with clear errors

    static func expectError(_ yaml: String, _ needle: String, _ label: String) {
        switch parse(yaml) {
        case .success:
            check(false, "\(label): expected rejection, but it parsed")
        case .failure(let errs):
            let joined = errs.joined(separator: " | ")
            check(contains(joined, needle), "\(label): error must mention '\(needle)' (got: \(joined))")
        }
    }

    static func case1_invalidManifests() {
        // Missing required app.
        expectError("""
        image: registry.local/x@sha256:\(digestHex)
        resources: { cpu: 100m, memory: 64Mi }
        """, "app", "invalid:missing-app")

        // Malformed image (not content-addressed).
        expectError("""
        app: web
        image: registry.local/web:latest
        resources: { cpu: 100m, memory: 64Mi }
        """, "image", "invalid:bad-image")

        // Bad cpu quantity.
        expectError("""
        app: web
        image: registry.local/web@sha256:\(digestHex)
        resources: { cpu: lots, memory: 64Mi }
        """, "cpu", "invalid:bad-cpu")

        // Port out of range.
        expectError("""
        app: web
        image: registry.local/web@sha256:\(digestHex)
        resources: { cpu: 100m, memory: 64Mi }
        ports:
          - { name: http, container: 70000 }
        """, "container", "invalid:bad-port")

        // Bad capability syntax (no category.action).
        expectError("""
        app: web
        image: registry.local/web@sha256:\(digestHex)
        resources: { cpu: 100m, memory: 64Mi }
        capabilities: [ root ]
        """, "capability", "invalid:bad-cap")

        // Unknown rollout strategy.
        expectError("""
        app: web
        image: registry.local/web@sha256:\(digestHex)
        resources: { cpu: 100m, memory: 64Mi }
        update: { strategy: warpspeed }
        """, "strategy", "invalid:bad-strategy")

        // https without a cert ref.
        expectError("""
        app: web
        image: registry.local/web@sha256:\(digestHex)
        resources: { cpu: 100m, memory: 64Mi }
        ports:
          - { name: http, container: 8080, expose: { via: lb, listen: 443, protocol: https } }
        """, "tlsCertRef", "invalid:https-no-cert")

        // Tab indentation is a parse error.
        expectError("app: web\n\timage: x", "tab", "invalid:tab-indent")

        // Digest with the wrong width.
        expectError("""
        app: web
        image: registry.local/web@sha256:abcd
        resources: { cpu: 100m, memory: 64Mi }
        """, "32 bytes", "invalid:short-digest")
    }

    // MARK: - Case 2: more malformed manifests (field branches not in case 1)

    /// A well-formed header so each case below isolates the single field under test.
    static let head = """
    app: web
    image: registry.local/web@sha256:\(digestHex)
    resources: { cpu: 100m, memory: 64Mi }
    """

    static func case2_moreInvalidManifests() {
        // root must be a mapping (a top-level sequence document is rejected).
        expectError("- a\n- b", "mapping", "invalid:root-sequence")

        // app validation branches.
        expectError("app: \"\"\nimage: registry.local/web@sha256:\(digestHex)\nresources: { cpu: 100m, memory: 64Mi }",
                    "empty", "invalid:app-empty")
        expectError("app: web--api\nimage: registry.local/web@sha256:\(digestHex)\nresources: { cpu: 100m, memory: 64Mi }",
                    "--", "invalid:app-double-dash")
        expectError("app: Web_API\nimage: registry.local/web@sha256:\(digestHex)\nresources: { cpu: 100m, memory: 64Mi }",
                    "valid name", "invalid:app-uppercase")

        // resources block: missing entirely, missing sub-fields, bad memory, zero values.
        expectError("app: web\nimage: registry.local/web@sha256:\(digestHex)", "resources", "invalid:resources-missing")
        expectError("\(head.replacingOccurrences(of: "resources: { cpu: 100m, memory: 64Mi }", with: "resources: { memory: 64Mi }"))",
                    "cpu", "invalid:resources-no-cpu")
        expectError("\(head.replacingOccurrences(of: "resources: { cpu: 100m, memory: 64Mi }", with: "resources: { cpu: 100m }"))",
                    "memory", "invalid:resources-no-memory")
        expectError("\(head.replacingOccurrences(of: "memory: 64Mi", with: "memory: heaps"))",
                    "memory quantity", "invalid:resources-bad-memory")
        expectError("\(head.replacingOccurrences(of: "cpu: 100m", with: "cpu: 0"))",
                    "must be > 0", "invalid:resources-zero-cpu")
        expectError("\(head.replacingOccurrences(of: "memory: 64Mi", with: "memory: 0"))",
                    "must be > 0", "invalid:resources-zero-memory")

        // update strategy cross-field + canary terminal checks.
        expectError("\(head)\nupdate: { strategy: rolling, maxSurge: 0, maxUnavailable: 0 }",
                    "non-zero", "invalid:rolling-no-progress")
        expectError("\(head)\nupdate: { strategy: canary, canarySteps: [ 25, 50 ] }",
                    "reach 100", "invalid:canary-not-terminal")
        expectError("\(head)\nupdate: { strategy: canary, canarySteps: [ 25, 150 ] }",
                    "1–100", "invalid:canary-step-range")

        // volumes: non-absolute mount, empty name.
        expectError("\(head)\nvolumes:\n  - { name: data, mount: data }", "absolute", "invalid:volume-rel-mount")
        expectError("\(head)\nvolumes:\n  - { mount: /data }", "name", "invalid:volume-no-name")

        // expose: unsupported protocol / provider / via.
        expectError("\(head)\nports:\n  - { name: http, container: 8080, expose: { via: lb, listen: 443, protocol: ftp } }",
                    "http|https|tcp", "invalid:expose-bad-proto")
        expectError("\(head)\nports:\n  - { name: http, container: 8080, expose: { via: lb, provider: aws, listen: 443 } }",
                    "nginx", "invalid:expose-bad-provider")
        expectError("\(head)\nports:\n  - { name: http, container: 8080, expose: { via: ingress, listen: 443 } }",
                    "lb", "invalid:expose-bad-via")
    }

    // MARK: - Case 3: the validator accumulates ALL errors, not just the first

    static func case3_errorAccumulation() {
        // Missing app, bad image, AND bad cpu — every problem should surface in one pass.
        let bad = """
        image: registry.local/web:latest
        resources: { cpu: lots, memory: 64Mi }
        capabilities: [ root ]
        """
        guard case .failure(let errs) = parse(bad) else {
            check(false, "3: a multi-problem manifest must be rejected"); return
        }
        check(errs.count >= 3, "3: every problem is accumulated (got \(errs.count): \(errs))")
        let joined = errs.joined(separator: " | ")
        check(contains(joined, "app"), "3: missing app surfaced")
        check(contains(joined, "image"), "3: bad image surfaced")
        check(contains(joined, "cpu"), "3: bad cpu surfaced")
        check(contains(joined, "capability"), "3: bad capability surfaced")
    }

    // MARK: - Case 4: canary with no explicit steps gets the default ramp (positive)

    static func case4_canaryDefaultRamp() {
        guard case .success(let m) = parse("\(head)\nupdate: { strategy: canary }") else {
            check(false, "4: canary with no steps must still parse"); return
        }
        check(m.update.strategy == .canary, "4: strategy is canary")
        check(m.update.canaryStepPercents == [25, 50, 100], "4: default ramp applied (got \(m.update.canaryStepPercents))")
    }

    // MARK: - Case 5: the Foundation-free scalar parsers (direct unit tests)

    static func case5_scalarParsers() {
        // millicpu
        check(parseMillicpu("100m") == 100, "5: 100m → 100 millicpu")
        check(parseMillicpu("1") == 1000, "5: 1 core → 1000 millicpu")
        check(parseMillicpu("1.5") == 1500, "5: 1.5 → 1500")
        check(parseMillicpu("0.25") == 250, "5: 0.25 → 250")
        check(parseMillicpu("2.5") == 2500, "5: 2.5 → 2500")
        check(parseMillicpu("1.2.3") == nil, "5: a second decimal point is rejected")
        check(parseMillicpu("xm") == nil, "5: non-numeric millicpu rejected")
        check(parseMillicpu("") == nil, "5: empty cpu rejected")

        // bytes (binary + decimal suffixes)
        check(parseBytes("64Mi") == 64 << 20, "5: 64Mi")
        check(parseBytes("1Gi") == 1 << 30, "5: 1Gi")
        check(parseBytes("512Ki") == 512 << 10, "5: 512Ki")
        check(parseBytes("1Ti") == 1 << 40, "5: 1Ti")
        check(parseBytes("1000") == 1000, "5: bare bytes")
        check(parseBytes("2M") == 2_000_000, "5: decimal M = 1e6")
        check(parseBytes("3G") == 3_000_000_000, "5: decimal G = 1e9")
        check(parseBytes("10Xi") == nil, "5: unknown suffix rejected")
        check(parseBytes("Mi") == nil, "5: missing numeric prefix rejected")

        // seconds (ms must be rejected — probe periods are whole seconds)
        check(parseSeconds("5s") == 5, "5: 5s")
        check(parseSeconds("2m") == 120, "5: 2m → 120s")
        check(parseSeconds("1h") == 3600, "5: 1h → 3600s")
        check(parseSeconds("30") == 30, "5: bare seconds")
        check(parseSeconds("500ms") == nil, "5: sub-second ms rejected")

        // hex decode
        check(hexDecode("00ff") ?? [] == [0x00, 0xFF], "5: hex round-trip")
        check(hexDecode("abc") == nil, "5: odd-length hex rejected")
        check(hexDecode("zz") == nil, "5: non-hex digit rejected")

        // DNS-ish names
        check(isDNSName("web-api"), "5: valid dns name")
        check(!isDNSName("-web"), "5: leading dash rejected")
        check(!isDNSName("web-"), "5: trailing dash rejected")
        check(!isDNSName("Web"), "5: uppercase rejected")
        check(!isDNSName(""), "5: empty name rejected")

        // capability syntax: category.action[:arg]
        check(isValidCapability("net.listen"), "5: bare category.action")
        check(isValidCapability("net.listen:8080"), "5: category.action:arg")
        check(isValidCapability("fs.read:/etc/app"), "5: arg may contain slashes")
        check(!isValidCapability("root"), "5: missing category.action dot rejected")
        check(!isValidCapability(".listen"), "5: leading dot rejected")
        check(!isValidCapability("net.listen:"), "5: empty arg rejected")
        check(!isValidCapability("net.listen:has space"), "5: space in arg rejected")
        check(!isValidCapability(""), "5: empty capability rejected")
    }
}

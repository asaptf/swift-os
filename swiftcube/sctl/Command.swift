// SPDX-License-Identifier: Apache-2.0
// Command.swift — the `sctl` command layer: dispatch, validation, output formatting (SC9a).
//
// Everything the CLI does that is NOT host I/O lives here, written against the `ControlClient`
// seam so it is fully testable host-side (case 2 drives it over an in-process store). The host
// `main` is a thin shell: it loads config, reads a `-f` file into bytes, builds a client, calls
// `dispatch`, prints the output, and exits with the returned code.
//
// Verbs (the kubectl analog): apply -f, get <kind>, describe <kind> <name>, scale <app>
// --replicas=N, delete <kind> <name>, rollout status <app>. `rollout undo/pause/resume` and
// `token create` are surfaced as SC9b seams (the rollout state machine + a token-mint RPC).
//
// One `apply` wires the whole pipeline the lower milestones already implement:
//   /apps/<app>/spec     (SC4 scheduler)      — the Deployment
//   /svcspec/<app>       (SC7 east-west)      — the Service
//   /expose/<app>        (SC6 LB programmer)  — the LB exposure (when a port is exposed via lb)
// Revision discipline (the rollout seam SC9b consumes): a TEMPLATE change bumps the Deployment
// revision (old.revision + 1); a pure replica change (scale, or `apply` differing only in
// replicas) keeps it; an unchanged manifest is a no-op. Foundation-free.

// MARK: - Result

struct CommandResult: Equatable {
    var output: String
    var exitCode: Int32
    static func ok(_ s: String) -> CommandResult { CommandResult(output: s, exitCode: 0) }
    static func err(_ s: String) -> CommandResult { CommandResult(output: "error: " + s, exitCode: 1) }
}

private let usageText = """
sctl — SwiftCube CLI
usage:
  sctl apply -f <manifest.yaml>
  sctl get <deployments|services|endpoints|nodes|expose|pending>
  sctl describe <deployment|service|expose> <name>
  sctl scale <app> --replicas=N
  sctl delete <deployment|service|expose> <name>
  sctl rollout status <app>
"""

// MARK: - Dispatch

/// Parse `args` (excluding the program name) and run the verb against `client`. When the verb is
/// `apply`, the manifest file's bytes are passed in `manifest` (the host shell read the `-f` file);
/// the rest of `apply`'s flag handling is validated here so the parsing stays testable.
func dispatch(_ args: [String], client: ControlClient, manifest: [UInt8]? = nil) -> CommandResult {
    guard let verb = args.first else { return CommandResult.ok(usageText) }
    let rest = Array(args.dropFirst())
    switch verb {
    case "apply":
        // Require a `-f <file>` flag; the bytes themselves arrive via `manifest`.
        guard hasFlag(rest, "-f") || hasFlag(rest, "--filename") else {
            return CommandResult.err("apply requires -f <manifest.yaml>")
        }
        guard let bytes = manifest else { return CommandResult.err("could not read manifest file") }
        return applyManifest(bytes, client: client)
    case "get":
        guard let kind = rest.first else { return CommandResult.err("get requires a <kind>") }
        return getKind(kind, client: client)
    case "describe":
        guard rest.count >= 2 else { return CommandResult.err("describe requires <kind> <name>") }
        return describe(kind: rest[0], name: rest[1], client: client)
    case "scale":
        return scale(rest, client: client)
    case "delete":
        guard rest.count >= 2 else { return CommandResult.err("delete requires <kind> <name>") }
        return deleteObject(kind: rest[0], name: rest[1], client: client)
    case "rollout":
        return rollout(rest, client: client)
    case "token":
        return CommandResult.err("token create needs a control-plane mint RPC — SC9b seam")
    case "help", "-h", "--help":
        return CommandResult.ok(usageText)
    default:
        return CommandResult.err("unknown command '\(verb)'\n" + usageText)
    }
}

// MARK: - apply

func applyManifest(_ bytes: [UInt8], client: ControlClient) -> CommandResult {
    switch parseManifest(bytes) {
    case .failure(let errs):
        return CommandResult.err("manifest invalid:\n  - " + errs.joined(separator: "\n  - "))
    case .success(let m):
        let appKey = SchedulerKeys.appSpec(m.app)
        let existing = client.get(appKey).flatMap { DeploymentSpec.decode($0.value) }

        // Decide the revision: bump on a template change, keep on a pure scale, start at 1.
        let revision: UInt64
        if let old = existing {
            revision = sameRolloutSpec(old, m.toDeployment(revision: old.revision)) ? old.revision : old.revision + 1
        } else {
            revision = 1
        }
        let dep = m.toDeployment(revision: revision)

        // Idempotency: identical desired Deployment ⇒ no write, report unchanged.
        if let old = existing, old == dep {
            // Still ensure the service/expose objects exist (first apply may have partially run).
            writeServiceObjects(m, client: client)
            return CommandResult.ok("deployment/\(m.app) unchanged (revision \(revision))")
        }
        client.put(appKey, dep.encode())
        writeServiceObjects(m, client: client)
        let verb = existing == nil ? "created" : "configured"
        return CommandResult.ok("deployment/\(m.app) \(verb) (revision \(revision), replicas \(m.replicas))")
    }
}

/// Write the east-west Service and the LB expose object (or remove a stale expose).
private func writeServiceObjects(_ m: Manifest, client: ControlClient) {
    client.put(ServiceKeys.svcSpec(m.app), m.toServiceSpec().encode())
    let exposeKey = LBKeys.expose(m.app)
    if let expose = m.toExpose() {
        client.put(exposeKey, expose.encode())
    } else if client.get(exposeKey) != nil {
        _ = client.delete(exposeKey)
    }
}

/// Two Deployments describe the same rollout template iff they are equal once revision and
/// replicas (the non-template fields) are normalized away.
func sameRolloutSpec(_ a: DeploymentSpec, _ b: DeploymentSpec) -> Bool {
    var x = a; var y = b
    x.revision = 0; y.revision = 0
    x.replicas = 0; y.replicas = 0
    return x == y
}

// MARK: - get

func getKind(_ kind: String, client: ControlClient) -> CommandResult {
    switch normalizeKind(kind) {
    case "deployments":
        var rows = [["NAME", "REPLICAS", "REVISION", "STRATEGY-REQ"]]
        for kv in client.range(prefix: SchedulerKeys.appsPrefix) {
            guard SchedulerKeys.appOfSpecKey(kv.key) != nil, let d = DeploymentSpec.decode(kv.value) else { continue }
            rows.append([d.app, "\(d.replicas)", "\(d.revision)", "cpu=\(d.request.cpuMillis)m/mem=\(humanBytes(d.request.memBytes))"])
        }
        return table(rows, empty: "no deployments")
    case "services":
        var rows = [["NAME", "SELECTOR", "PORT"]]
        for kv in client.range(prefix: ServiceKeys.svcSpecPrefix) {
            guard let s = ServiceSpec.decode(kv.value) else { continue }
            rows.append([s.name, s.selector, "\(s.servicePort)"])
        }
        return table(rows, empty: "no services")
    case "endpoints":
        var rows = [["SERVICE", "READY", "ADDRESSES"]]
        for kv in client.range(prefix: EndpointKeys.endpointsPrefix) {
            guard let set = EndpointSet.decode(kv.value) else { continue }
            let addrs = set.endpoints.map { "\($0.address):\($0.port)" }.joined(separator: ",")
            rows.append([set.service, "\(set.endpoints.count)", addrs.isEmpty ? "-" : addrs])
        }
        return table(rows, empty: "no endpoints")
    case "nodes":
        var rows = [["ID", "STATUS", "CPU", "MEM", "LABELS"]]
        for kv in client.range(prefix: CubeKeys.nodesPrefix) {
            guard let n = NodeRecord.decode(kv.value) else { continue }
            rows.append([n.id, n.status == .ready ? "ready" : "joining",
                         "\(n.capacityCpuMillis)m", humanBytes(n.capacityMemBytes),
                         n.labels.isEmpty ? "-" : n.labels.joined(separator: ",")])
        }
        return table(rows, empty: "no nodes")
    case "expose":
        var rows = [["SERVICE", "PROVIDER", "LISTEN", "PROTO", "CERT"]]
        for kv in client.range(prefix: LBKeys.exposePrefix) {
            guard let e = ServiceExpose.decode(kv.value) else { continue }
            rows.append([e.service, e.provider, "\(e.listenPort)", protoName(e.proto), e.tlsCertRef.isEmpty ? "-" : e.tlsCertRef])
        }
        return table(rows, empty: "no exposed services")
    case "pending":
        var rows = [["APP", "SLOT", "REASON"]]
        for kv in client.range(prefix: SchedulerKeys.pendingPrefix) {
            guard let p = PendingRecord.decode(kv.value) else { continue }
            rows.append([p.app, "\(p.slot)", p.reason])
        }
        return table(rows, empty: "nothing pending")
    default:
        return CommandResult.err("unknown kind '\(kind)' (deployments|services|endpoints|nodes|expose|pending)")
    }
}

// MARK: - describe

func describe(kind: String, name: String, client: ControlClient) -> CommandResult {
    switch normalizeKind(kind) {
    case "deployments":
        guard let kv = client.get(SchedulerKeys.appSpec(name)), let d = DeploymentSpec.decode(kv.value) else {
            return CommandResult.err("deployment/\(name) not found")
        }
        var s = "Deployment: \(d.app)\n"
        s += "  revision:   \(d.revision)\n"
        s += "  replicas:   \(d.replicas)\n"
        s += "  request:    cpu=\(d.request.cpuMillis)m mem=\(humanBytes(d.request.memBytes))\n"
        s += "  selector:   \(d.nodeSelector.isEmpty ? "-" : d.nodeSelector.joined(separator: ","))\n"
        s += "  image:      \(hexShort(d.template.image.digest)) (\(d.template.image.signature.isEmpty ? "unsigned — registry seam" : "signed"))\n"
        s += "  command:    \(d.template.args.joined(separator: " "))\n"
        s += "  caps:       \(d.template.capabilities.joined(separator: ","))\n"
        s += "  service:    \(d.template.service) port=\(d.template.port)\n"
        s += "  readiness:  \(probeDesc(d.template.readiness))\n"
        s += "  liveness:   \(probeDesc(d.template.liveness))\n"
        if let v = d.template.volume { s += "  volume:     \(v.name) at \(v.mountPath) (\(humanBytes(v.sizeBytes)))\n" }
        return CommandResult.ok(s)
    case "services":
        guard let kv = client.get(ServiceKeys.svcSpec(name)), let s = ServiceSpec.decode(kv.value) else {
            return CommandResult.err("service/\(name) not found")
        }
        return CommandResult.ok("Service: \(s.name)\n  selector: \(s.selector)\n  port:     \(s.servicePort)")
    case "expose":
        guard let kv = client.get(LBKeys.expose(name)), let e = ServiceExpose.decode(kv.value) else {
            return CommandResult.err("expose/\(name) not found")
        }
        return CommandResult.ok("Expose: \(e.service)\n  provider: \(e.provider)\n  listen:   \(e.listenPort) (\(protoName(e.proto)))\n  cert:     \(e.tlsCertRef.isEmpty ? "-" : e.tlsCertRef)\n  health:   \(e.healthPath.isEmpty ? "tcp" : e.healthPath) port=\(e.healthPort)")
    default:
        return CommandResult.err("cannot describe kind '\(kind)'")
    }
}

// MARK: - scale

func scale(_ args: [String], client: ControlClient) -> CommandResult {
    guard let app = args.first else { return CommandResult.err("scale requires <app> --replicas=N") }
    guard let replicasArg = flagValue(args, "--replicas"), let n = parseUInt(replicasArg), n <= UInt64(UInt32.max) else {
        return CommandResult.err("scale requires --replicas=N (a non-negative integer)")
    }
    let key = SchedulerKeys.appSpec(app)
    guard let kv = client.get(key), var d = DeploymentSpec.decode(kv.value) else {
        return CommandResult.err("deployment/\(app) not found")
    }
    if d.replicas == UInt32(n) { return CommandResult.ok("deployment/\(app) unchanged (replicas \(n))") }
    d.replicas = UInt32(n)   // scale keeps the revision: a replica count is not a template change
    // CAS on the read revision so a concurrent writer is not clobbered.
    if !client.casPut(key, d.encode(), expect: kv.modRevision) {
        return CommandResult.err("deployment/\(app) changed concurrently — retry")
    }
    return CommandResult.ok("deployment/\(app) scaled to \(n) (revision \(d.revision))")
}

// MARK: - delete

func deleteObject(kind: String, name: String, client: ControlClient) -> CommandResult {
    switch normalizeKind(kind) {
    case "deployments":
        let removed = client.delete(SchedulerKeys.appSpec(name))
        _ = client.delete(ServiceKeys.svcSpec(name))
        _ = client.delete(LBKeys.expose(name))
        // The scheduler/endpoints/LB loops converge the rest (assignments, endpoints) to absent.
        return removed ? CommandResult.ok("deployment/\(name) deleted") : CommandResult.err("deployment/\(name) not found")
    case "services":
        return client.delete(ServiceKeys.svcSpec(name)) ? CommandResult.ok("service/\(name) deleted") : CommandResult.err("service/\(name) not found")
    case "expose":
        return client.delete(LBKeys.expose(name)) ? CommandResult.ok("expose/\(name) deleted") : CommandResult.err("expose/\(name) not found")
    default:
        return CommandResult.err("cannot delete kind '\(kind)'")
    }
}

// MARK: - rollout (read-only status in SC9a; the state machine is SC9b)

func rollout(_ args: [String], client: ControlClient) -> CommandResult {
    guard let sub = args.first else { return CommandResult.err("rollout requires status|undo|pause|resume <app>") }
    let rest = Array(args.dropFirst())
    switch sub {
    case "status":
        guard let app = rest.first else { return CommandResult.err("rollout status requires <app>") }
        guard let kv = client.get(SchedulerKeys.appSpec(app)), let d = DeploymentSpec.decode(kv.value) else {
            return CommandResult.err("deployment/\(app) not found")
        }
        // Ready endpoints currently routed for this service (SC5 output).
        var ready = 0
        if let ekv = client.get(EndpointKeys.endpoints(app)), let set = EndpointSet.decode(ekv.value) {
            ready = set.endpoints.count
        }
        // Live assignments for the current revision (SC4 output).
        var current = 0
        for akv in client.range(prefix: SletKeys.assignmentsPrefix) {
            guard let a = Assignment.decode(akv.value) else { continue }
            if a.revision == d.revision && a.spec.service == app { current += 1 }
        }
        var s = "rollout \(app):\n"
        s += "  revision:  \(d.revision)\n"
        s += "  desired:   \(d.replicas)\n"
        s += "  scheduled: \(current)\n"
        s += "  ready:     \(ready)\n"
        s += "  phase:     \(ready >= Int(d.replicas) ? "Complete" : "Progressing") (read-only — rollout controller is SC9b)"
        return CommandResult.ok(s)
    case "undo", "pause", "resume":
        return CommandResult.err("rollout \(sub) needs the rollout state machine — SC9b")
    default:
        return CommandResult.err("unknown rollout subcommand '\(sub)'")
    }
}

// MARK: - Formatting / arg helpers

/// Normalize a kind alias to its canonical plural.
private func normalizeKind(_ k: String) -> String {
    switch k {
    case "deployment", "deployments", "deploy", "app", "apps": return "deployments"
    case "service", "services", "svc": return "services"
    case "endpoint", "endpoints", "ep": return "endpoints"
    case "node", "nodes": return "nodes"
    case "expose", "exposes": return "expose"
    case "pending": return "pending"
    default: return k
    }
}

private func hasFlag(_ args: [String], _ flag: String) -> Bool {
    for a in args where a == flag { return true }
    return false
}

/// Value of `--flag=value` or `--flag value`.
private func flagValue(_ args: [String], _ flag: String) -> String? {
    let pfx = flag + "="
    for (i, a) in args.enumerated() {
        if a == flag, i + 1 < args.count { return args[i + 1] }
        if startsWith(a, pfx) { return String(decoding: Array(a.utf8)[pfx.utf8.count...], as: UTF8.self) }
    }
    return nil
}

private func startsWith(_ s: String, _ pfx: String) -> Bool {
    let sb = Array(s.utf8), pb = Array(pfx.utf8)
    if pb.count > sb.count { return false }
    for i in 0..<pb.count where sb[i] != pb[i] { return false }
    return true
}

private func protoName(_ p: ListenProtocol) -> String {
    switch p { case .http: return "http"; case .https: return "https"; case .tcp: return "tcp" }
}

private func probeDesc(_ p: ProbeSpec) -> String {
    switch p.kind {
    case .none: return "none"
    case .http: return "http \(p.httpPath) port=\(p.port) period=\(p.periodSeconds)s"
    case .tcp: return "tcp port=\(p.port) period=\(p.periodSeconds)s"
    case .exec: return "exec (C6 seam)"
    }
}

/// Human-readable byte count using binary suffixes when exact.
func humanBytes(_ n: UInt64) -> String {
    let units: [(UInt64, String)] = [(1 << 30, "Gi"), (1 << 20, "Mi"), (1 << 10, "Ki")]
    for (u, name) in units where n >= u && n % u == 0 { return "\(n / u)\(name)" }
    return "\(n)"
}

private func hexShort(_ b: [UInt8]) -> String {
    let n = min(6, b.count)
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for i in 0..<n { out.append(digits[Int(b[i] >> 4)]); out.append(digits[Int(b[i] & 0x0F)]) }
    return String(decoding: out, as: UTF8.self) + (b.count > n ? "…" : "")
}

/// Render rows as a left-aligned column table; `empty` is shown when only the header is present.
private func table(_ rows: [[String]], empty: String) -> CommandResult {
    guard rows.count > 1 else { return CommandResult.ok(empty) }
    let cols = rows[0].count
    var widths = [Int](repeating: 0, count: cols)
    for r in rows { for c in 0..<cols where c < r.count { widths[c] = max(widths[c], r[c].utf8.count) } }
    var out = ""
    for (ri, r) in rows.enumerated() {
        var line = ""
        for c in 0..<cols {
            let cell = c < r.count ? r[c] : ""
            line += cell
            if c != cols - 1 { line += pad(widths[c] - cell.utf8.count + 2) }
        }
        out += line
        if ri != rows.count - 1 { out += "\n" }
    }
    return CommandResult.ok(out)
}

private func pad(_ n: Int) -> String {
    if n <= 0 { return "" }
    return String(decoding: [UInt8](repeating: 0x20, count: n), as: UTF8.self)
}

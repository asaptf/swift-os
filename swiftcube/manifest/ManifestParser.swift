// SPDX-License-Identifier: Apache-2.0
// ManifestParser.swift — the YAML tree → typed `Manifest`, with validation (SC9).
//
// This is the pure, golden-testable validator the milestone calls for: it walks the `YamlNode`
// tree (Yaml.swift) into a typed `Manifest`, checking every field the §10 schema constrains —
// required fields, the resource formats (`100m`, `64Mi`, `1Gi`), port ranges (1–65535), capability
// syntax (`category.action[:arg]`), and the `update:` strategy block. It accumulates ALL problems
// into a `failure([String])` rather than bailing on the first, so a user fixing a manifest sees the
// whole list. Foundation-free: `sctld` links this file to re-validate a submitted manifest, so a bad
// manifest is rejected identically at the CLI and at the controller.
//
// Parsing never throws and never reads I/O — it is a total function of the input bytes, which is
// what makes the golden tests (case 1) deterministic.

// MARK: - Result

enum ManifestResult: Equatable {
    case success(Manifest)
    case failure([String])
}

// MARK: - Entry point

/// Parse + validate a manifest document. Returns the typed `Manifest` or every validation error.
func parseManifest(_ bytes: [UInt8]) -> ManifestResult {
    switch parseYaml(bytes) {
    case .error(let msg): return .failure([msg])
    case .ok(let node):
        guard case .mapping = node else { return .failure(["manifest root must be a mapping"]) }
        var p = ManifestValidator(root: node)
        return p.validate()
    }
}

// MARK: - Validator

private struct ManifestValidator {
    let root: YamlNode
    var errors: [String] = []

    init(root: YamlNode) { self.root = root }

    mutating func fail(_ msg: String) { errors.append(msg) }

    mutating func validate() -> ManifestResult {
        let app = requireScalar("app")
        if let a = app {
            if a.isEmpty { fail("app: must not be empty") }
            else if contains(a, "--") { fail("app: name must not contain '--' (reserved cellId separator)") }
            else if !isDNSName(a) { fail("app: '\(a)' is not a valid name (lowercase letters, digits, '-')") }
        }

        let image = parseImage()
        let replicas = parseReplicas()
        let command = parseStringList("command")
        let update = parseUpdate()
        let resources = parseResources()
        let ports = parsePorts()
        let env = parseEnv()
        let secrets = parseStringList("secrets")
        let volumes = parseVolumes()
        let capabilities = parseCapabilities()
        let health = parseHealth()
        let placement = parsePlacement()

        if !errors.isEmpty { return .failure(errors) }

        // All required pieces are present once errors is empty.
        let m = Manifest(app: app!, image: image!, replicas: replicas,
                         command: command, update: update, resources: resources!,
                         ports: ports, env: env, secrets: secrets, volumes: volumes,
                         capabilities: capabilities, health: health, placement: placement)
        return .success(m)
    }

    // MARK: Field accessors

    private func node(_ key: String) -> YamlNode? { root.child(key) }

    private mutating func requireScalar(_ key: String) -> String? {
        guard let n = node(key) else { fail("\(key): required field is missing"); return nil }
        guard let s = n.asScalar else { fail("\(key): expected a scalar value"); return nil }
        return s
    }

    // MARK: image

    private mutating func parseImage() -> ManifestImage? {
        guard let ref = requireScalar("image") else { return nil }
        // Form: <reference>@<algo>:<hex>. Split at the LAST '@'.
        let bytes = Array(ref.utf8)
        var at = -1
        for i in stride(from: bytes.count - 1, through: 0, by: -1) where bytes[i] == 0x40 { at = i; break }
        guard at > 0, at + 1 < bytes.count else {
            fail("image: '\(ref)' must be content-addressed as <reference>@<algo>:<hex>"); return nil
        }
        let digestPart = String(decoding: bytes[(at + 1)...], as: UTF8.self)
        let db = Array(digestPart.utf8)
        var colon = -1
        for i in 0..<db.count where db[i] == 0x3A { colon = i; break }
        guard colon > 0, colon + 1 < db.count else {
            fail("image: digest '\(digestPart)' must be <algo>:<hex>"); return nil
        }
        let algo = String(decoding: db[0..<colon], as: UTF8.self)
        let hex = String(decoding: db[(colon + 1)...], as: UTF8.self)
        guard let digest = hexDecode(hex) else { fail("image: digest is not valid hex"); return nil }
        guard digest.count == 32 else {
            fail("image: digest must be 32 bytes (got \(digest.count)) — the implemented CAS width"); return nil
        }
        return ManifestImage(reference: ref, algorithm: algo, digest: digest)
    }

    // MARK: replicas

    private mutating func parseReplicas() -> UInt32 {
        guard let n = node("replicas") else { return 1 }   // default 1
        guard let s = n.asScalar, let v = parseUInt(s), v <= UInt64(UInt32.max) else {
            fail("replicas: expected a non-negative integer"); return 1
        }
        return UInt32(v)
    }

    // MARK: command / generic string lists

    private mutating func parseStringList(_ key: String) -> [String] {
        guard let n = node(key) else { return [] }
        guard let seq = n.asSequence else {
            // Tolerate a single scalar as a one-element list.
            if let s = n.asScalar { return [s] }
            fail("\(key): expected a sequence"); return []
        }
        var out: [String] = []
        for item in seq {
            if let s = item.asScalar { out.append(s) } else { fail("\(key): entries must be scalars") }
        }
        return out
    }

    // MARK: update strategy

    private mutating func parseUpdate() -> UpdateStrategy {
        var u = UpdateStrategy()
        guard let n = node("update") else { return u }
        guard case .mapping = n else { fail("update: expected a mapping"); return u }
        if let s = n.child("strategy")?.asScalar {
            switch s {
            case "rolling":               u.strategy = .rolling
            case "blue-green", "bluegreen": u.strategy = .blueGreen
            case "canary":                u.strategy = .canary
            default: fail("update.strategy: '\(s)' must be one of rolling|blue-green|canary")
            }
        }
        if let v = uintChild(n, "maxSurge", "update.maxSurge") { u.maxSurge = UInt32(truncatingIfNeeded: v) }
        if let v = uintChild(n, "maxUnavailable", "update.maxUnavailable") { u.maxUnavailable = UInt32(truncatingIfNeeded: v) }
        if let v = uintChild(n, "progressDeadlineSeconds", "update.progressDeadlineSeconds") {
            u.progressDeadlineSeconds = UInt32(truncatingIfNeeded: v)
        }
        if let steps = n.child("canarySteps")?.asSequence {
            var pcts: [UInt32] = []
            for item in steps {
                guard let s = item.asScalar, let v = parseUInt(s), v >= 1, v <= 100 else {
                    fail("update.canarySteps: each step must be a percentage 1–100"); continue
                }
                pcts.append(UInt32(v))
            }
            u.canaryStepPercents = pcts
        }
        // Cross-field checks.
        if u.strategy == .rolling && u.maxSurge == 0 && u.maxUnavailable == 0 {
            fail("update: rolling requires maxSurge or maxUnavailable to be non-zero (else no progress)")
        }
        if u.strategy == .canary && u.canaryStepPercents.isEmpty {
            // Default ramp if none specified.
            u.canaryStepPercents = [25, 50, 100]
        }
        if u.strategy == .canary, let last = u.canaryStepPercents.last, last != 100 {
            fail("update.canarySteps: the final canary step must reach 100")
        }
        return u
    }

    // MARK: resources

    private mutating func parseResources() -> ManifestResources? {
        guard let n = node("resources") else { fail("resources: required field is missing"); return nil }
        guard case .mapping = n else { fail("resources: expected a mapping"); return nil }
        guard let cpuS = n.child("cpu")?.asScalar else { fail("resources.cpu: required"); return nil }
        guard let memS = n.child("memory")?.asScalar else { fail("resources.memory: required"); return nil }
        guard let cpu = parseMillicpu(cpuS) else { fail("resources.cpu: '\(cpuS)' is not a valid cpu quantity (e.g. 100m, 1, 1.5)"); return nil }
        guard let mem = parseBytes(memS) else { fail("resources.memory: '\(memS)' is not a valid memory quantity (e.g. 64Mi, 1Gi)"); return nil }
        if cpu == 0 { fail("resources.cpu: must be > 0") }
        if mem == 0 { fail("resources.memory: must be > 0") }
        return ManifestResources(cpuMillis: cpu, memBytes: mem)
    }

    // MARK: ports

    private mutating func parsePorts() -> [ManifestPort] {
        guard let n = node("ports") else { return [] }
        guard let seq = n.asSequence else { fail("ports: expected a sequence"); return [] }
        var out: [ManifestPort] = []
        for (i, item) in seq.enumerated() {
            guard case .mapping = item else { fail("ports[\(i)]: expected a mapping"); continue }
            let name = item.child("name")?.asScalar ?? "port\(i)"
            guard let cs = item.child("container")?.asScalar, let c = parseUInt(cs), c >= 1, c <= 65535 else {
                fail("ports[\(i)].container: required, must be a port 1–65535"); continue
            }
            var expose: ManifestExpose? = nil
            if let ex = item.child("expose") {
                expose = parseExpose(ex, index: i)
            }
            out.append(ManifestPort(name: name, container: UInt16(c), expose: expose))
        }
        return out
    }

    private mutating func parseExpose(_ n: YamlNode, index: Int) -> ManifestExpose? {
        guard case .mapping = n else { fail("ports[\(index)].expose: expected a mapping"); return nil }
        let via = n.child("via")?.asScalar ?? "lb"
        if via != "lb" { fail("ports[\(index)].expose.via: only 'lb' is supported in v1") }
        let provider = n.child("provider")?.asScalar ?? "nginx"
        if provider != "nginx" {
            // Hetzner/AWS providers are out of scope for SC6/SC9 (surfaced, not failed).
            fail("ports[\(index)].expose.provider: only 'nginx' is implemented (hetzner/aws are seams)")
        }
        guard let ls = n.child("listen")?.asScalar, let l = parseUInt(ls), l >= 1, l <= 65535 else {
            fail("ports[\(index)].expose.listen: required, must be a port 1–65535"); return nil
        }
        var proto: ListenProtocol = .http
        if let ps = n.child("protocol")?.asScalar {
            switch ps {
            case "http": proto = .http
            case "https": proto = .https
            case "tcp": proto = .tcp
            default: fail("ports[\(index)].expose.protocol: '\(ps)' must be http|https|tcp")
            }
        }
        let tls = n.child("tlsCertRef")?.asScalar ?? ""
        if proto == .https && tls.isEmpty {
            fail("ports[\(index)].expose: https requires tlsCertRef (the secrets/cert seam)")
        }
        return ManifestExpose(via: via, provider: provider, listen: UInt16(l), proto: proto, tlsCertRef: tls)
    }

    // MARK: env

    private mutating func parseEnv() -> [String] {
        guard let n = node("env") else { return [] }
        guard let entries = n.asMapping else { fail("env: expected a mapping of KEY: value"); return [] }
        var out: [String] = []
        for e in entries {
            guard let v = e.value.asScalar else { fail("env.\(e.key): value must be a scalar"); continue }
            out.append("\(e.key)=\(v)")
        }
        return out
    }

    // MARK: volumes

    private mutating func parseVolumes() -> [ManifestVolume] {
        guard let n = node("volumes") else { return [] }
        guard let seq = n.asSequence else { fail("volumes: expected a sequence"); return [] }
        var out: [ManifestVolume] = []
        for (i, item) in seq.enumerated() {
            guard case .mapping = item else { fail("volumes[\(i)]: expected a mapping"); continue }
            guard let name = item.child("name")?.asScalar, !name.isEmpty else { fail("volumes[\(i)].name: required"); continue }
            guard let mount = item.child("mount")?.asScalar, mount.first == "/" else {
                fail("volumes[\(i)].mount: required, must be an absolute path"); continue
            }
            let persistent = parseBool(item.child("persistent")?.asScalar) ?? false
            var size: UInt64 = 0
            if let ss = item.child("size")?.asScalar {
                guard let b = parseBytes(ss) else { fail("volumes[\(i)].size: '\(ss)' is not a valid size"); continue }
                size = b
            }
            out.append(ManifestVolume(name: name, mount: mount, persistent: persistent, sizeBytes: size))
        }
        return out
    }

    // MARK: capabilities

    private mutating func parseCapabilities() -> [String] {
        let caps = parseStringList("capabilities")
        for c in caps where !isValidCapability(c) {
            fail("capabilities: '\(c)' is not a valid capability (expected category.action[:arg])")
        }
        return caps
    }

    // MARK: health

    private mutating func parseHealth() -> ManifestHealth {
        var h = ManifestHealth()
        guard let n = node("health") else { return h }
        guard case .mapping = n else { fail("health: expected a mapping"); return h }
        if let r = n.child("readiness") { h.readiness = parseProbe(r, "health.readiness") }
        if let l = n.child("liveness") { h.liveness = parseProbe(l, "health.liveness") }
        return h
    }

    private mutating func parseProbe(_ n: YamlNode, _ path: String) -> ProbeSpec {
        var p = ProbeSpec()
        guard case .mapping = n else { fail("\(path): expected a mapping"); return p }
        if let httpPath = n.child("http")?.asScalar {
            p.kind = .http; p.httpPath = httpPath
        } else if n.child("tcp") != nil {
            p.kind = .tcp
        }
        if let ps = n.child("port")?.asScalar {
            guard let v = parseUInt(ps), v >= 1, v <= 65535 else { fail("\(path).port: must be a port 1–65535"); return p }
            p.port = UInt16(v)
        }
        if let per = n.child("period")?.asScalar {
            guard let s = parseSeconds(per) else { fail("\(path).period: '\(per)' is not a duration (e.g. 1s, 5s)"); return p }
            p.periodSeconds = s
        }
        if let to = n.child("timeout")?.asScalar {
            guard let s = parseSeconds(to) else { fail("\(path).timeout: '\(to)' is not a duration"); return p }
            p.timeoutSeconds = s
        }
        if let id = n.child("initialDelay")?.asScalar {
            guard let s = parseSeconds(id) else { fail("\(path).initialDelay: '\(id)' is not a duration"); return p }
            p.initialDelaySeconds = s
        }
        if let v = uintChild(n, "successThreshold", "\(path).successThreshold") { p.successThreshold = UInt32(truncatingIfNeeded: v) }
        if let v = uintChild(n, "failureThreshold", "\(path).failureThreshold") { p.failureThreshold = UInt32(truncatingIfNeeded: v) }
        return p
    }

    // MARK: placement

    private mutating func parsePlacement() -> ManifestPlacement {
        var pl = ManifestPlacement()
        guard let n = node("placement") else { return pl }
        guard case .mapping = n else { fail("placement: expected a mapping"); return pl }
        if let s = n.child("spread")?.asScalar { pl.spread = s }
        if let sel = n.child("nodeSelector") {
            if let entries = sel.asMapping {
                for e in entries {
                    guard let v = e.value.asScalar else { fail("placement.nodeSelector.\(e.key): value must be a scalar"); continue }
                    pl.nodeSelector.append("\(e.key)=\(v)")
                }
            } else if let s = sel.asScalar, contains(s, "=") {
                pl.nodeSelector.append(s)
            } else {
                fail("placement.nodeSelector: expected a mapping of key: value")
            }
        }
        if let pin = n.child("pin")?.asScalar { pl.pinHint = pin }
        return pl
    }

    // MARK: small typed-child helper

    private mutating func uintChild(_ n: YamlNode, _ key: String, _ path: String) -> UInt64? {
        guard let s = n.child(key)?.asScalar else { return nil }
        guard let v = parseUInt(s) else { fail("\(path): expected a non-negative integer"); return nil }
        return v
    }
}

// MARK: - Scalar parsers (Foundation-free)

/// Parse a non-negative decimal integer. Returns nil on any non-digit.
func parseUInt(_ s: String) -> UInt64? {
    let b = Array(s.utf8)
    if b.isEmpty { return nil }
    var v: UInt64 = 0
    for c in b { guard c >= 0x30 && c <= 0x39 else { return nil }; v = v &* 10 &+ UInt64(c - 0x30) }
    return v
}

/// Parse a `true`/`false` (also `yes`/`no`, `on`/`off`).
func parseBool(_ s: String?) -> Bool? {
    guard let s = s else { return nil }
    switch s {
    case "true", "yes", "on": return true
    case "false", "no", "off": return false
    default: return nil
    }
}

/// cpu quantity → millicpu. `100m`→100, `1`→1000, `1.5`→1500, `2`→2000. One decimal point allowed.
func parseMillicpu(_ s: String) -> UInt32? {
    let b = Array(s.utf8)
    if b.isEmpty { return nil }
    if b.last == 0x6D {     // 'm' suffix → already millicpu
        guard let v = parseUInt(String(decoding: b[0..<(b.count - 1)], as: UTF8.self)), v <= UInt64(UInt32.max) else { return nil }
        return UInt32(v)
    }
    // Possibly fractional cores → ×1000.
    var dot = -1
    for i in 0..<b.count where b[i] == 0x2E { if dot >= 0 { return nil }; dot = i }
    if dot < 0 {
        guard let whole = parseUInt(s) else { return nil }
        let m = whole &* 1000
        return m <= UInt64(UInt32.max) ? UInt32(m) : nil
    }
    let wholeStr = String(decoding: b[0..<dot], as: UTF8.self)
    let fracStr = String(decoding: b[(dot + 1)...], as: UTF8.self)
    let whole = wholeStr.isEmpty ? 0 : parseUInt(wholeStr)
    guard let w = whole else { return nil }
    // Take up to 3 fractional digits (milli precision); pad/truncate.
    var fb = Array(fracStr.utf8)
    while fb.count < 3 { fb.append(0x30) }
    fb = Array(fb[0..<3])
    guard let frac = parseUInt(String(decoding: fb, as: UTF8.self)) else { return nil }
    let total = w &* 1000 &+ frac
    return total <= UInt64(UInt32.max) ? UInt32(total) : nil
}

/// memory/size quantity → bytes. Suffixes: Ki/Mi/Gi/Ti (1024ⁿ), K/M/G/T (1000ⁿ), or bare bytes.
func parseBytes(_ s: String) -> UInt64? {
    let b = Array(s.utf8)
    if b.isEmpty { return nil }
    // Find where the numeric prefix ends.
    var i = 0
    while i < b.count && b[i] >= 0x30 && b[i] <= 0x39 { i += 1 }
    guard i > 0 else { return nil }
    guard let num = parseUInt(String(decoding: b[0..<i], as: UTF8.self)) else { return nil }
    let suffix = String(decoding: b[i...], as: UTF8.self)
    let mult: UInt64
    switch suffix {
    case "":   mult = 1
    case "Ki": mult = 1 << 10
    case "Mi": mult = 1 << 20
    case "Gi": mult = 1 << 30
    case "Ti": mult = 1 << 40
    case "K", "k": mult = 1_000
    case "M":  mult = 1_000_000
    case "G":  mult = 1_000_000_000
    case "T":  mult = 1_000_000_000_000
    default: return nil
    }
    return num &* mult
}

/// duration → whole seconds. `1s`→1, `5s`→5, `2m`→120, `1h`→3600, bare int → seconds. Sub-second
/// (`ms`) is rejected (probe periods are whole seconds).
func parseSeconds(_ s: String) -> UInt32? {
    let b = Array(s.utf8)
    if b.isEmpty { return nil }
    var i = 0
    while i < b.count && b[i] >= 0x30 && b[i] <= 0x39 { i += 1 }
    guard i > 0, let num = parseUInt(String(decoding: b[0..<i], as: UTF8.self)) else { return nil }
    let suffix = String(decoding: b[i...], as: UTF8.self)
    let mult: UInt64
    switch suffix {
    case "", "s": mult = 1
    case "m": mult = 60
    case "h": mult = 3600
    default: return nil      // e.g. "ms" — not representable in whole seconds
    }
    let total = num &* mult
    return total <= UInt64(UInt32.max) ? UInt32(total) : nil
}

/// Decode a hex string to bytes (nil on odd length or a non-hex digit).
func hexDecode(_ s: String) -> [UInt8]? {
    let cs = Array(s.utf8)
    if cs.count % 2 != 0 { return nil }
    func v(_ c: UInt8) -> Int? {
        if c >= 0x30 && c <= 0x39 { return Int(c - 0x30) }
        if c >= 0x61 && c <= 0x66 { return Int(c - 0x61 + 10) }
        if c >= 0x41 && c <= 0x46 { return Int(c - 0x41 + 10) }
        return nil
    }
    var out: [UInt8] = []; out.reserveCapacity(cs.count / 2)
    var i = 0
    while i < cs.count {
        guard let hi = v(cs[i]), let lo = v(cs[i + 1]) else { return nil }
        out.append(UInt8(hi << 4 | lo)); i += 2
    }
    return out
}

// MARK: - Name / capability validation

/// A lowercase-DNS-ish name: starts with a letter/digit, body of letters/digits/'-', no trailing '-'.
func isDNSName(_ s: String) -> Bool {
    let b = Array(s.utf8)
    if b.isEmpty { return false }
    func isLowerAlnum(_ c: UInt8) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) }
    if !isLowerAlnum(b.first!) || !isLowerAlnum(b.last!) { return false }
    for c in b where !(isLowerAlnum(c) || c == 0x2D) { return false }
    return true
}

/// A capability is `category.action` optionally followed by `:arg`. The name part is lowercase
/// letters/digits/'.'; the arg (after the first ':') is free-form but non-empty and space-free.
func isValidCapability(_ s: String) -> Bool {
    if s.isEmpty { return false }
    let b = Array(s.utf8)
    var colon = -1
    for i in 0..<b.count where b[i] == 0x3A { colon = i; break }
    let nameEnd = colon < 0 ? b.count : colon
    if nameEnd == 0 { return false }
    // name part
    func isNameChar(_ c: UInt8) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2E }
    for i in 0..<nameEnd where !isNameChar(b[i]) { return false }
    if b[0] == 0x2E || b[nameEnd - 1] == 0x2E { return false }       // no leading/trailing dot
    var sawDot = false
    for i in 0..<nameEnd where b[i] == 0x2E { sawDot = true }
    if !sawDot { return false }                                       // require category.action
    // arg part (if present): non-empty, no spaces.
    if colon >= 0 {
        if colon + 1 >= b.count { return false }
        for i in (colon + 1)..<b.count where b[i] == 0x20 { return false }
    }
    return true
}

/// Substring containment (Foundation-free).
func contains(_ haystack: String, _ needle: String) -> Bool {
    let h = Array(haystack.utf8), n = Array(needle.utf8)
    if n.isEmpty { return true }
    if n.count > h.count { return false }
    var i = 0
    while i + n.count <= h.count {
        var j = 0
        while j < n.count && h[i + j] == n[j] { j += 1 }
        if j == n.count { return true }
        i += 1
    }
    return false
}

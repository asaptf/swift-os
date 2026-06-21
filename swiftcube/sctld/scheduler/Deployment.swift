// SPDX-License-Identifier: Apache-2.0
// Deployment.swift — the scheduler's desired-state object + key schema (SC4).
//
// A `Deployment` is the user-facing desired state `sctl apply` writes: "run N replicas
// of this app, fitting this request, on nodes matching this selector." The scheduler
// (Schedule.swift) expands one Deployment into N `Assignment` objects — the desired
// state SC3's `slet` consumes — spread across nodes and fit by cpu/mem. SC4 schedules a
// single (current) `revision`; SC9 layers multi-revision rollout on top, which is why
// each Assignment carries the revision it belongs to.
//
// Three new object families enter the cubestore schema here (SC2 owns /nodes,/leases,
// /tokens; SC3 owns /assignments,/status/cells):
//
//   /apps/<app>/spec       — DESIRED: a Deployment (DeploymentSpec). Written by sctl.
//   /pending/<app>/s<slot> — OBSERVED: a replica the scheduler could not place, with a
//                            human reason. Cleared when the slot is placed. Never a
//                            silent drop — replicas reappear here until capacity exists.
//
// Foundation-free; little-endian ByteIO, like every other cubestore record.

// MARK: - Key schema

enum SchedulerKeys {
    static let appsPrefix: Bytes    = Array("/apps/".utf8)
    static let pendingPrefix: Bytes = Array("/pending/".utf8)

    /// `/apps/<app>/spec` — the Deployment object for one app.
    static func appSpec(_ app: String) -> Bytes {
        appsPrefix + Array(app.utf8) + Array("/spec".utf8)
    }

    /// The app name from a `/apps/<app>/spec` key, or nil if it is not such a key.
    static func appOfSpecKey(_ key: Bytes) -> String? {
        let suffix: Bytes = Array("/spec".utf8)
        guard key.count > appsPrefix.count + suffix.count else { return nil }
        for i in 0..<appsPrefix.count where key[i] != appsPrefix[i] { return nil }
        let tail = key.count - suffix.count
        for i in 0..<suffix.count where key[tail + i] != suffix[i] { return nil }
        return String(decoding: key[appsPrefix.count..<tail], as: UTF8.self)
    }

    /// `/pending/<app>/s<slot>` — one unplaced replica's marker.
    static func pending(app: String, slot: UInt32) -> Bytes {
        pendingPrefix + Array(app.utf8) + Array("/s".utf8) + Array("\(slot)".utf8)
    }

    /// Split a `/assignments/<node>/<cellId>` key into (node, cellId). The reconcile
    /// loop scans the whole `/assignments/` subtree (all nodes), so — unlike SC3's
    /// `slet`, which knows its own node — it must recover the node from the key.
    static func parseAssignmentKey(_ key: Bytes) -> (node: String, cellId: String)? {
        let pfx = SletKeys.assignmentsPrefix
        guard key.count > pfx.count else { return nil }
        for i in 0..<pfx.count where key[i] != pfx[i] { return nil }
        // node = bytes up to the next '/', cellId = the remainder.
        var slash = -1
        var i = pfx.count
        while i < key.count { if key[i] == 0x2F { slash = i; break }; i += 1 }
        guard slash > pfx.count, slash + 1 < key.count else { return nil }
        let node = String(decoding: key[pfx.count..<slash], as: UTF8.self)
        let cellId = String(decoding: key[(slash + 1)...], as: UTF8.self)
        return (node, cellId)
    }
}

// MARK: - Deterministic Cell identity

/// `cellId` is derived from `(app, revision, slot ordinal, generation)` — never random —
/// so a reschedule of the same slot is reproducible and a test can predict every id.
/// Wire form `"<app>--r<rev>-s<slot>-g<gen>"`: the `--` separates the (possibly
/// hyphenated) app name from the numeric suffix. App names must not contain `--`.
enum CellIdCodec {
    static func make(app: String, revision: UInt64, slot: UInt32, generation: UInt64) -> String {
        "\(app)--r\(revision)-s\(slot)-g\(generation)"
    }

    static func parse(_ id: String) -> (app: String, revision: UInt64, slot: UInt32, generation: UInt64)? {
        let b = Array(id.utf8)
        // Last "--" splits app from suffix (app may itself contain single hyphens).
        var sep = -1
        var i = b.count - 2
        while i >= 0 { if b[i] == 0x2D && b[i + 1] == 0x2D { sep = i; break }; i -= 1 }
        guard sep > 0 else { return nil }
        let app = String(decoding: b[0..<sep], as: UTF8.self)
        // suffix = r<rev>-s<slot>-g<gen>
        var parts: [[UInt8]] = []
        var cur: [UInt8] = []
        var j = sep + 2
        while j < b.count { if b[j] == 0x2D { parts.append(cur); cur = [] } else { cur.append(b[j]) }; j += 1 }
        parts.append(cur)
        guard parts.count == 3,
              parts[0].first == 0x72, parts[1].first == 0x73, parts[2].first == 0x67, // 'r','s','g'
              let rev = decimal(parts[0].dropFirst()),
              let slot = decimal(parts[1].dropFirst()),
              let gen = decimal(parts[2].dropFirst()) else { return nil }
        return (app, rev, UInt32(truncatingIfNeeded: slot), gen)
    }

    private static func decimal(_ s: ArraySlice<UInt8>) -> UInt64? {
        var v: UInt64 = 0
        var any = false
        for c in s { guard c >= 0x30 && c <= 0x39 else { return nil }; v = v &* 10 &+ UInt64(c - 0x30); any = true }
        return any ? v : nil
    }
}

// MARK: - The Cell template (Deployment → per-slot CellSpec)

/// Everything a Cell needs except its per-instance identity (`cellId`) and placement
/// (`node`) — those the scheduler fills per slot. Mirrors `CellSpec` minus those two.
struct CellTemplate: Equatable {
    var image: ImageRef
    var capabilities: [String]
    var resources: ResourceLimits   // the cell's enforced limits (≥ the scheduling request)
    var namespaceRoot: String
    var args: [String]
    var env: [String]
    var tmpfsScratch: Bool
    var volume: VolumeMount?
    var restartPolicy: RestartPolicy

    func materialize(cellId: String, node: String) -> CellSpec {
        CellSpec(cellId: cellId, node: node, image: image, capabilities: capabilities,
                 resources: resources, namespaceRoot: namespaceRoot, args: args, env: env,
                 tmpfsScratch: tmpfsScratch, volume: volume, restartPolicy: restartPolicy)
    }

    func encode(into w: inout ByteWriter) {
        image.encode(into: &w)
        w.u32(UInt32(capabilities.count)); for c in capabilities { w.blob(Array(c.utf8)) }
        resources.encode(into: &w)
        w.blob(Array(namespaceRoot.utf8))
        w.u32(UInt32(args.count)); for a in args { w.blob(Array(a.utf8)) }
        w.u32(UInt32(env.count)); for e in env { w.blob(Array(e.utf8)) }
        w.u8(tmpfsScratch ? 1 : 0)
        if let v = volume { w.u8(1); v.encode(into: &w) } else { w.u8(0) }
        w.u8(restartPolicy.rawValue)
    }

    static func decode(_ r: inout ByteReader) -> CellTemplate? {
        guard let img = ImageRef.decode(&r), let nCaps = r.u32() else { return nil }
        var caps: [String] = []; var i: UInt32 = 0
        while i < nCaps { guard let b = r.blob() else { return nil }; caps.append(String(decoding: b, as: UTF8.self)); i += 1 }
        guard let res = ResourceLimits.decode(&r), let rootB = r.blob(), let nArgs = r.u32() else { return nil }
        var args: [String] = []; i = 0
        while i < nArgs { guard let b = r.blob() else { return nil }; args.append(String(decoding: b, as: UTF8.self)); i += 1 }
        guard let nEnv = r.u32() else { return nil }
        var env: [String] = []; i = 0
        while i < nEnv { guard let b = r.blob() else { return nil }; env.append(String(decoding: b, as: UTF8.self)); i += 1 }
        guard let tmpfsB = r.u8(), let hasVol = r.u8() else { return nil }
        var vol: VolumeMount? = nil
        if hasVol == 1 { guard let v = VolumeMount.decode(&r) else { return nil }; vol = v }
        guard let polB = r.u8(), let pol = RestartPolicy(rawValue: polB) else { return nil }
        return CellTemplate(image: img, capabilities: caps, resources: res,
                            namespaceRoot: String(decoding: rootB, as: UTF8.self), args: args,
                            env: env, tmpfsScratch: tmpfsB != 0, volume: vol, restartPolicy: pol)
    }
}

// MARK: - DeploymentSpec (desired state)

struct DeploymentSpec: Equatable {
    var app: String
    var replicas: UInt32
    var revision: UInt64               // the current revision SC4 schedules (SC9 rolls across)
    var request: ResourceLimits        // scheduling request the scheduler fits against
    var nodeSelector: [String]         // required "key=value" labels (node must have all)
    var pinHint: String                // SC8 seam: a node id to pin to; "" = unpinned
    var template: CellTemplate

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)                         // record version
        w.blob(Array(app.utf8))
        w.u32(replicas)
        w.u64(revision)
        request.encode(into: &w)
        w.u32(UInt32(nodeSelector.count)); for s in nodeSelector { w.blob(Array(s.utf8)) }
        w.blob(Array(pinHint.utf8))
        template.encode(into: &w)
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> DeploymentSpec? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let appB = r.blob(), let reps = r.u32(),
              let rev = r.u64(), let req = ResourceLimits.decode(&r), let nSel = r.u32() else { return nil }
        var sel: [String] = []; var i: UInt32 = 0
        while i < nSel { guard let b = r.blob() else { return nil }; sel.append(String(decoding: b, as: UTF8.self)); i += 1 }
        guard let pinB = r.blob(), let tmpl = CellTemplate.decode(&r) else { return nil }
        return DeploymentSpec(app: String(decoding: appB, as: UTF8.self), replicas: reps,
                              revision: rev, request: req, nodeSelector: sel,
                              pinHint: String(decoding: pinB, as: UTF8.self), template: tmpl)
    }
}

// MARK: - PendingRecord (observed: a replica that could not be placed)

struct PendingRecord: Equatable {
    var app: String
    var slot: UInt32
    var reason: String

    func encode() -> Bytes {
        var w = ByteWriter()
        w.u8(1)
        w.blob(Array(app.utf8))
        w.u32(slot)
        w.blob(Array(reason.utf8))
        return w.bytes
    }

    static func decode(_ bytes: Bytes) -> PendingRecord? {
        var r = ByteReader(bytes)
        guard let ver = r.u8(), ver == 1, let appB = r.blob(), let slot = r.u32(), let reasonB = r.blob() else { return nil }
        return PendingRecord(app: String(decoding: appB, as: UTF8.self), slot: slot,
                             reason: String(decoding: reasonB, as: UTF8.self))
    }
}

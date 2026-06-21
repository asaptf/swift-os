// SPDX-License-Identifier: Apache-2.0
// CellSpec.swift — the deployable-instance spec that maps onto C6 Cell properties (SC3).
//
// A SwiftCube instance is a Cell (SWIFTCUBE_DESIGN §5): the manifest fields map onto
// Cell properties almost one-to-one. A `CellSpec` is the desired shape of one Cell —
// everything the C6 supervisor needs to assemble `job + handle set + resource domain
// + namespace` and launch a process inside it. `slet` derives a `CellSpec` from an
// `Assignment` it watches in cubestore and hands it to a `CellSupervisor`; it does NOT
// re-implement Cell lifecycle.
//
//   CellSpec field      → Cell property (CAPABILITIES C6)
//   image               → read-only, content-addressed signed packed base
//   capabilities        → explicit kernel capability grant set (NOT root-in-container)
//   resources           → resource-accounting domain + limits, keyed by CellId
//   namespaceRoot       → the cell's VFS root view
//   args/env            → the launched process's argv/environment
//   tmpfsScratch        → private RAM scratch (the writable half of the "image")
//   volume              → an optional node-local PV handle slot (SC8 seam; unwired here)
//
// Foundation-free: serialized with cubestore's little-endian ByteIO so the same code
// compiles into the on-device `slet` and the host test.

/// What the kernel does when the cell's main process exits — the orchestrator-level
/// supervision policy carried in desired state (Kubernetes `restartPolicy`).
enum RestartPolicy: UInt8, Equatable {
    case always    = 0   // restart on any exit
    case onFailure = 1   // restart only on a non-zero exit
    case never     = 2   // never restart; a crash is terminal (`failed`)
}

/// A content-addressed, signed reference to a Cell's read-only base image.
///
/// `digest` is the 32-byte SHA-256 content address of the packed base (so two specs
/// naming the same bytes dedupe on disk); `signature` is a detached 64-byte Ed25519
/// signature over `digest` under the trusted image-signing key. Verification reuses
/// swift-os's existing `ed25519Verify` + `sha256` — no new signature scheme. The
/// network pull / registry that *stages* these bytes locally is the SC3 out-of-scope
/// seam (see `ImageStore`).
struct ImageRef: Equatable {
    var digest: [UInt8]      // 32-byte SHA-256 content address
    var signature: [UInt8]   // 64-byte Ed25519 signature over `digest`

    func encode(into w: inout ByteWriter) { w.blob(digest); w.blob(signature) }
    static func decode(_ r: inout ByteReader) -> ImageRef? {
        guard let d = r.blob(), let s = r.blob() else { return nil }
        return ImageRef(digest: d, signature: s)
    }
}

/// Resource limits for the cell's accounting domain (keyed by `CellId` in C6).
struct ResourceLimits: Equatable {
    var cpuMillis: UInt32    // milli-cpu, e.g. 100m → 100
    var memBytes: UInt64     // hard memory limit

    func encode(into w: inout ByteWriter) { w.u32(cpuMillis); w.u64(memBytes) }
    static func decode(_ r: inout ByteReader) -> ResourceLimits? {
        guard let c = r.u32(), let m = r.u64() else { return nil }
        return ResourceLimits(cpuMillis: c, memBytes: m)
    }
}

/// A node-local persistent-volume handle slot (SWIFTCUBE_DESIGN §7). SC3 leaves this
/// a *seam*: the slot is carried through to the supervisor and the fencing hook, but
/// the actual PV wiring (datafs handle, sticky placement) and the fencing
/// implementation are SC8. `handleSlot == 0` means "unbound".
struct VolumeMount: Equatable {
    var name: String
    var mountPath: String
    var handleSlot: UInt32    // SC8 fills the real volume handle; 0 = unbound

    func encode(into w: inout ByteWriter) {
        w.blob(Array(name.utf8)); w.blob(Array(mountPath.utf8)); w.u32(handleSlot)
    }
    static func decode(_ r: inout ByteReader) -> VolumeMount? {
        guard let n = r.blob(), let p = r.blob(), let h = r.u32() else { return nil }
        return VolumeMount(name: String(decoding: n, as: UTF8.self),
                           mountPath: String(decoding: p, as: UTF8.self), handleSlot: h)
    }
}

/// The full desired shape of one Cell. Equatable so the reconciler can detect drift
/// (a changed spec ⇒ recreate) cheaply.
struct CellSpec: Equatable {
    var cellId: String              // cluster-unique instance id (the accounting domain key)
    var node: String                // the node this instance is assigned to
    var image: ImageRef             // content-addressed signed base
    var capabilities: [String]      // explicit grants, e.g. "net.listen:8080", "fs.read:/etc/app"
    var resources: ResourceLimits   // cpu/mem limits for the CellId domain
    var namespaceRoot: String       // the cell's VFS root view
    var args: [String]              // launched process argv
    var env: [String]               // "KEY=VALUE" environment entries
    var tmpfsScratch: Bool          // mount a private tmpfs scratch
    var volume: VolumeMount?        // optional PV slot (SC8 seam)
    var restartPolicy: RestartPolicy

    // SC5 trailing section (defaulted so SC3/SC4 call sites and v1 records are unaffected).
    var service: String = ""        // the service this Cell backs (service = app for now)
    var port: UInt16 = 0            // the Cell's exposed/endpoint port (the manifest container port)
    var readiness: ProbeSpec = ProbeSpec()  // readiness probe (gates endpoints; never restarts)
    var liveness: ProbeSpec = ProbeSpec()   // liveness probe (failure ⇒ restart)

    func encode(into w: inout ByteWriter) {
        w.blob(Array(cellId.utf8))
        w.blob(Array(node.utf8))
        image.encode(into: &w)
        w.u32(UInt32(capabilities.count))
        for c in capabilities { w.blob(Array(c.utf8)) }
        resources.encode(into: &w)
        w.blob(Array(namespaceRoot.utf8))
        w.u32(UInt32(args.count))
        for a in args { w.blob(Array(a.utf8)) }
        w.u32(UInt32(env.count))
        for e in env { w.blob(Array(e.utf8)) }
        w.u8(tmpfsScratch ? 1 : 0)
        if let v = volume { w.u8(1); v.encode(into: &w) } else { w.u8(0) }
        w.u8(restartPolicy.rawValue)
        // SC5 trailing section. A v1 record ends above; this is appended unconditionally so
        // there is one canonical form, and `decode` tolerates its absence (EOF ⇒ defaults).
        w.blob(Array(service.utf8))
        w.u32(UInt32(port))
        readiness.encode(into: &w)
        liveness.encode(into: &w)
    }

    static func decode(_ r: inout ByteReader) -> CellSpec? {
        guard let cidB = r.blob(), let nodeB = r.blob(), let img = ImageRef.decode(&r),
              let nCaps = r.u32() else { return nil }
        var caps: [String] = []; caps.reserveCapacity(Int(nCaps))
        var i: UInt32 = 0
        while i < nCaps { guard let b = r.blob() else { return nil }; caps.append(String(decoding: b, as: UTF8.self)); i += 1 }
        guard let res = ResourceLimits.decode(&r), let rootB = r.blob(), let nArgs = r.u32() else { return nil }
        var args: [String] = []; args.reserveCapacity(Int(nArgs)); i = 0
        while i < nArgs { guard let b = r.blob() else { return nil }; args.append(String(decoding: b, as: UTF8.self)); i += 1 }
        guard let nEnv = r.u32() else { return nil }
        var env: [String] = []; env.reserveCapacity(Int(nEnv)); i = 0
        while i < nEnv { guard let b = r.blob() else { return nil }; env.append(String(decoding: b, as: UTF8.self)); i += 1 }
        guard let tmpfsB = r.u8() else { return nil }
        guard let hasVol = r.u8() else { return nil }
        var vol: VolumeMount? = nil
        if hasVol == 1 { guard let v = VolumeMount.decode(&r) else { return nil }; vol = v }
        guard let polB = r.u8(), let pol = RestartPolicy(rawValue: polB) else { return nil }
        // SC5 trailing section: present ⇒ read service/port/readiness/liveness; absent
        // (a v1 record at EOF) ⇒ keep the defaults. `r.blob()` returns nil at EOF.
        var service = ""; var port: UInt16 = 0
        var readiness = ProbeSpec(); var liveness = ProbeSpec()
        if let svcB = r.blob() {
            service = String(decoding: svcB, as: UTF8.self)
            guard let p = r.u32(), let rp = ProbeSpec.decode(&r), let lp = ProbeSpec.decode(&r) else { return nil }
            port = UInt16(truncatingIfNeeded: p); readiness = rp; liveness = lp
        }
        return CellSpec(cellId: String(decoding: cidB, as: UTF8.self),
                        node: String(decoding: nodeB, as: UTF8.self),
                        image: img, capabilities: caps, resources: res,
                        namespaceRoot: String(decoding: rootB, as: UTF8.self),
                        args: args, env: env, tmpfsScratch: tmpfsB != 0, volume: vol,
                        restartPolicy: pol, service: service, port: port,
                        readiness: readiness, liveness: liveness)
    }
}

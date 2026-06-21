// SPDX-License-Identifier: Apache-2.0
// slet.swift — the SwiftCube node agent (/bin/slet), SC2.
//
// slet is the per-node agent: it joins a controller with a bootstrap token, gets a
// CA-signed node certificate, registers a Node + lease, and keeps the lease alive
// by heartbeat while watching its assignments (SC3+). Its production form connects
// to a remote `sctld` over mTLS-TCP (swiftos_socket_stream / connect + the
// MutualTLS engine over swiftos_read/write); that real-NIC client loop is the
// daemon-ization seam recorded in FORMAT.md.
//
// For SC2 this binary boots and exercises the node-side identity path on-device —
// generate an EC P-256 key, build a PKCS#10 CSR (proof of possession), and verify
// it parses back to the same key — proving the agent's crypto/identity code runs
// under Embedded Swift on real aarch64. The end-to-end join/register/lease
// lifecycle is exercised by /bin/sctld's self-test. Built on the swift_user bridge.
//
// SC3 adds the node-side reconcile loop (Reconciler) and the C6 Cell-supervisor seam
// (CellSupervisor + image verifier + C6 adapter). All of it compiles into this ELF, so
// the build itself proves the reconcile loop is Embedded-Swift-clean. The SC3 self-check
// below exercises the image-verifier seam and the C6 adapter and reports the C6 gap
// HONESTLY: C6 (the userland Cell supervisor) is not implemented yet — only the CellId
// tag + syscalls 51–53 exist — so the adapter is a documented stub, the real Cell path
// is deferred, and the SC3 QEMU end-to-end gate is not claimed.

private func bootRNG(_ buf: inout [UInt8]) {
    buf.withUnsafeMutableBytes { p in
        if let a = p.baseAddress, p.count > 0 { _ = swiftos_random(a, UInt(p.count)) }
    }
}

/// An on-device image store with nothing pre-staged (the local read-only base store is
/// empty in this self-check; the network pull / registry is the SC3 out-of-scope seam).
private final class EmptyImageStore: ImageStore {
    func resolve(digest: [UInt8]) -> [UInt8]? { nil }
}

/// Exercise the SC3 Cell seam under Embedded Swift and surface the C6 gap. Returns true
/// on success.
private func sc3SelfCheck() -> Bool {
    let imageStore = EmptyImageStore()
    let verifier = ImageVerifier(trustedKey: [UInt8](repeating: 0, count: 32))
    let ref = ImageRef(digest: [UInt8](repeating: 0, count: 32),
                       signature: [UInt8](repeating: 0, count: 64))
    // Nothing staged locally ⇒ the verifier reports notStaged (no Cell would be created).
    guard verifier.verify(ref, store: imageStore) == .notStaged else { return false }

    let supervisor = C6CellSupervisor(imageStore: imageStore)
    let spec = CellSpec(cellId: "selftest", node: "node-1", image: ref, capabilities: [],
                        resources: ResourceLimits(cpuMillis: 0, memBytes: 0), namespaceRoot: "/",
                        args: [], env: [], tmpfsScratch: true, volume: nil, restartPolicy: .never)
    // The C6 adapter is a documented stub: it creates no Cell and reports unavailable.
    if case .unavailable = supervisor.create(spec) { return true }
    return false
}

/// Exercise the SC5 probe seam under Embedded Swift: the ProbeSpec byte codec round-trips,
/// the on-device NetProbe's pure parsers are correct, and the ProbeRunner tracks/untracks.
/// No network I/O is performed (the real http/tcp path needs real Cells over virtio-net —
/// gated on C6, like SC3). Returns true on success.
private func sc5SelfCheck() -> Bool {
    // ProbeSpec round-trips through the same little-endian codec it rides in CellSpec on.
    let rp = ProbeSpec(kind: .http, port: 8080, httpPath: "/healthz", periodSeconds: 1,
                       timeoutSeconds: 1, initialDelaySeconds: 0, successThreshold: 1, failureThreshold: 3)
    var w = ByteWriter(); rp.encode(into: &w)
    var r = ByteReader(w.bytes)
    guard let back = ProbeSpec.decode(&r), back == rp else { return false }

    // The on-device prober's pure parsers: dotted-quad → host-order u32, and HTTP status.
    guard NetProbe.parseIPv4("10.0.2.15") == 0x0A00_020F else { return false }
    guard NetProbe.statusIs2xx3xx(Array("HTTP/1.0 200 OK".utf8), count: 15) else { return false }
    guard !NetProbe.statusIs2xx3xx(Array("HTTP/1.0 503 NO".utf8), count: 15) else { return false }

    // The runner tracks and untracks a Cell (no probe fires — both specs inactive).
    let runner = ProbeRunner(prober: NetProbe(), clock: ManualClock(0))
    runner.track(cellId: "selftest", address: "10.0.2.15", readiness: ProbeSpec(),
                 liveness: ProbeSpec(), startedAt: 0)
    guard runner.isTracked("selftest") else { return false }
    runner.untrack("selftest")
    return !runner.isTracked("selftest")
}

@_cdecl("main")
func main(_ argc: Int32,
          _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
          _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    _ = argc; _ = argv; _ = envp
    swiftos_puts("slet: SwiftCube node agent (SC2) — node identity self-check\n")

    guard let key = generateECKeyPair(bootRNG) else { swiftos_puts("slet: FAIL keygen\n"); return 1 }
    guard let csr = acmeCSR(dnsNames: [Array("node-1".utf8)], pubX: key.pubX, pubY: key.pubY, priv32: key.priv) else {
        swiftos_puts("slet: FAIL csr\n"); return 1
    }
    guard let parsed = parseAndVerifyCSR(csr), parsed.point65 == key.point65 else {
        swiftos_puts("slet: FAIL csr-verify\n"); return 1
    }
    swiftos_puts("slet: node identity OK (P-256 key + verified CSR)\n")

    guard sc3SelfCheck() else { swiftos_puts("slet: FAIL SC3 cell seam\n"); return 1 }
    swiftos_puts("slet: SC3 reconcile loop + image verifier OK; C6 adapter UNAVAILABLE (stub) — Cell path deferred\n")

    guard sc5SelfCheck() else { swiftos_puts("slet: FAIL SC5 probe seam\n"); return 1 }
    swiftos_puts("slet: SC5 probe runner + NetProbe OK; live http/tcp probing deferred with C6\n")
    return 0
}

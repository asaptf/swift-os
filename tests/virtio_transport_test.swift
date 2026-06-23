// SPDX-License-Identifier: Apache-2.0
// virtio_transport_test.swift — host unit test for the QW7 transport abstraction.
//
// Compiled with the host Swift toolchain against kernel/drivers/virtio_transport_ops.swift
// alone (the protocol + its extension + the status-bit constants), which is
// deliberately free of `mmio_*` / VirtioPciDevice references so it links with no C
// bridge. The two real transports do real MMIO and are not part of this test; what
// IS tested is the abstraction QW7 introduced — that a generic `bringUpLike<T:
// VirtioTransportOps>` drives any conformer, that the shared extension helpers
// (reset / setFeaturesOk / negotiateVersion1) behave correctly, and that a pure
// in-memory test double (the whole point of QW7 — host-test doubles for the
// transport) can stand in for hardware. Mirrors tests/handle_test.swift's style.

import Foundation

// Reference-backed register store: the transport's status/feature/notify methods
// are non-mutating (on real hardware they write MMIO), so the fake records into a
// class it holds rather than into struct storage.
final class FakeRegs {
    var status: UInt32 = 0
    var driverFeatures: UInt64 = 0
    var offeredFeatures: UInt64 = UInt64(1) << 32   // VIRTIO_F_VERSION_1
    var config: [UInt: UInt32] = [:]
    var lastQueueDesc: UInt64 = 0
    var notified: [UInt16] = []
    var acks = 0
    // Model a device that clears FEATURES_OK in its status when it rejects the
    // negotiated feature set (virtio 1.0 §3.1.1 step 6/7).
    var acceptFeatures = true
}

// In-memory VirtioTransportOps conformer — the host-test double QW7 enables.
struct FakeTransport: VirtioTransportOps {
    let regs: FakeRegs
    let pci: Bool
    var isPci: Bool { pci }

    init(pci: Bool, regs: FakeRegs) { self.pci = pci; self.regs = regs }

    func setStatus(_ value: UInt32) { regs.status = value }
    func getStatus() -> UInt32 {
        regs.acceptFeatures ? regs.status : (regs.status & ~VIRTIO_STATUS_FEATURES_OK)
    }
    func deviceFeatures() -> UInt64 { regs.offeredFeatures }
    func setDriverFeatures(_ features: UInt64) { regs.driverFeatures = features }
    func configRead32(_ offset: UInt) -> UInt32 { regs.config[offset] ?? 0 }
    mutating func setupQueue(_ q: UInt16, requested: UInt32,
                             desc: UInt64, avail: UInt64, used: UInt64) -> UInt32 {
        regs.lastQueueDesc = desc
        return requested        // device echoes the requested size
    }
    func notify(queue q: UInt16) { regs.notified.append(q) }
    func ackInterrupt() { regs.acks += 1 }
}

// The shape every driver uses: a single generic function, monomorphized per
// conformer, with no `any` and no allocation on the call path.
func bringUpLike<T: VirtioTransportOps>(_ t: inout T) -> Bool {
    t.reset()
    t.setStatus(VIRTIO_STATUS_ACK)
    t.setStatus(VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER)
    if !t.negotiateVersion1() { return false }
    let size = t.setupQueue(0, requested: 8, desc: 0xCAFE_F00D, avail: 0x1000, used: 0x2000)
    if size == 0 { return false }
    t.notify(queue: 0)
    t.ackInterrupt()
    return true
}

@main
struct VirtioTransportTest {
    static var failed = false

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed = true
        }
    }

    static func main() {
        // ---- 1. Stable status-bit constants --------------------------------
        check(VIRTIO_STATUS_ACK == 1, "ACK bit is stable")
        check(VIRTIO_STATUS_DRIVER == 2, "DRIVER bit is stable")
        check(VIRTIO_STATUS_DRIVER_OK == 4, "DRIVER_OK bit is stable")
        check(VIRTIO_STATUS_FEATURES_OK == 8, "FEATURES_OK bit is stable")

        // ---- 2. reset() is a pure setStatus(0) composition -----------------
        let regs = FakeRegs()
        let t = FakeTransport(pci: false, regs: regs)
        t.setStatus(0xFF)
        t.reset()
        check(regs.status == 0, "reset() writes status 0 via the extension default")

        // ---- 3. isPci reports the conformer's kind -------------------------
        check(!FakeTransport(pci: false, regs: FakeRegs()).isPci, "mmio-like fake reports isPci == false")
        check(FakeTransport(pci: true, regs: FakeRegs()).isPci, "pci-like fake reports isPci == true")

        // ---- 4. negotiateVersion1 writes feature word 1 bit 0 --------------
        let accept = FakeRegs()
        let ok = FakeTransport(pci: false, regs: accept)
        check(ok.negotiateVersion1(), "negotiateVersion1 succeeds when the device accepts")
        check((accept.driverFeatures >> 32) & 1 == 1,
              "negotiateVersion1 sets VIRTIO_F_VERSION_1 (feature word 1, bit 0)")
        check(accept.driverFeatures == UInt64(1) << 32,
              "negotiateVersion1 publishes exactly VIRTIO_F_VERSION_1")

        // ---- 5. setFeaturesOk reflects the device's acceptance -------------
        check(ok.setFeaturesOk(), "setFeaturesOk returns true when the device keeps FEATURES_OK set")
        check(accept.status == (VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK),
              "setFeaturesOk writes ACK|DRIVER|FEATURES_OK")

        let reject = FakeRegs()
        reject.acceptFeatures = false
        let bad = FakeTransport(pci: true, regs: reject)
        check(!bad.setFeaturesOk(), "setFeaturesOk returns false when the device clears FEATURES_OK")
        check(!bad.negotiateVersion1(), "negotiateVersion1 fails when feature negotiation is rejected")

        // ---- 6. The generic bring-up drives the double end to end ----------
        let run = FakeRegs()
        var dev = FakeTransport(pci: true, regs: run)
        check(bringUpLike(&dev), "bringUpLike<T> completes against the in-memory double")
        check(run.lastQueueDesc == 0xCAFE_F00D, "setupQueue received the descriptor ring address")
        check(run.notified == [0], "notify(queue: 0) was recorded exactly once")
        check(run.acks == 1, "ackInterrupt was recorded exactly once")
        check(run.status == VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK,
              "bring-up left the negotiated status latched")

        if failed {
            FileHandle.standardError.write(Data("virtio_transport_test: FAILURES\n".utf8))
            exit(1)
        }
        print("virtio_transport_test: OK")
    }
}

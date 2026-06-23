// SPDX-License-Identifier: Apache-2.0
// virtio_transport_ops.swift — the virtio 1.0 control-plane surface, expressed as
// a protocol used ONLY as a compile-time generic constraint (QW7).
//
// `VirtioTransportOps` captures the status / feature-negotiation / queue-setup /
// doorbell behaviour shared by the two virtio attach kinds (legacy MMIO on QEMU
// `virt`, modern PCI on `-cpu max` / the Hetzner ARM VM). The two concrete
// conformers — `VirtioMmioTransport` and `VirtioPciTransport` — live in
// virtio_transport.swift and do the real `mmio_*` work; this file holds only the
// abstraction and the parts that are identical for both.
//
// The contract is deliberate (see docs/ARCHITECTURE.md §"Swift protocol use"):
// drivers take the transport through a generic parameter — `func f<T:
// VirtioTransportOps>(_ t: inout T)` — so Embedded Swift monomorphizes every call
// into a direct one (no vtable, no witness table). It is NEVER stored as `any
// VirtioTransportOps`; doing so would reintroduce dynamic dispatch the freestanding
// kernel forbids. Keeping this file free of `mmio_*` / `VirtioPciDevice` references
// also lets the host unit test (tests/virtio_transport_test.swift) compile the
// protocol + extension against an in-memory fake transport with no C bridge.

// Device status bits (virtio 1.0 §2.1).
let VIRTIO_STATUS_ACK: UInt32 = 1
let VIRTIO_STATUS_DRIVER: UInt32 = 2
let VIRTIO_STATUS_DRIVER_OK: UInt32 = 4
let VIRTIO_STATUS_FEATURES_OK: UInt32 = 8

// Control-plane surface shared by the MMIO and PCI virtio transports. Used only as
// a generic constraint, never a stored `any` — Embedded Swift monomorphizes every
// call. The conformers (in virtio_transport.swift) are ordinary copyable structs.
protocol VirtioTransportOps {
    func setStatus(_ value: UInt32)
    func getStatus() -> UInt32
    func deviceFeatures() -> UInt64
    func setDriverFeatures(_ features: UInt64)
    func configRead32(_ offset: UInt) -> UInt32
    mutating func setupQueue(_ q: UInt16, requested: UInt32,
                             desc: UInt64, avail: UInt64, used: UInt64) -> UInt32
    func notify(queue q: UInt16)
    func ackInterrupt()
    var isPci: Bool { get }
}

// These three are pure compositions of the requirements above and are identical for
// both transports, so they live here once instead of being duplicated per struct.
extension VirtioTransportOps {
    func reset() { setStatus(0) }

    /// Set FEATURES_OK and confirm the device accepted the negotiated set.
    func setFeaturesOk() -> Bool {
        setStatus(VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK)
        return (getStatus() & VIRTIO_STATUS_FEATURES_OK) != 0
    }

    /// Convenience for single-feature devices: accept only VIRTIO_F_VERSION_1
    /// (feature bit 32 → select word 1, bit 0).
    func negotiateVersion1() -> Bool {
        setDriverFeatures(UInt64(1) << 32)
        return setFeaturesOk()
    }
}

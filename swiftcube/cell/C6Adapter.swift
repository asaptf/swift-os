// SPDX-License-Identifier: Apache-2.0
// C6Adapter.swift — the real CellSupervisor adapter onto the kernel C6 Cell primitives.
//
// **STATUS: documented stub. C6 is not implemented yet.** Per CAPABILITIES §6 and
// docs/RISK_REMEDIATION_ROADMAP.md, only the per-process `CellId` tag and a few syscall
// numbers (51–53) exist; the C1–C6 capability/handle/IPC/cell arc has not been built.
// SC3 is the first SwiftCube milestone gated on C6, so — following the milestone's
// "scope honestly" rule — this adapter does NOT fake a Cell. It rejects nothing it can
// honestly check (image verification is the reconciler's job and runs regardless) and
// returns `.unavailable` from `create`, which the reconcile loop surfaces as a Cell
// status the operator/SC4 can see. The QEMU end-to-end gate (SC3 case 9) is therefore
// DEFERRED, not claimed.
//
// When C6 lands, this is the only file that changes to light up the on-device path:
//   create  → assemble a cell (job root + spawn-with-handles for the granted caps +
//             a CellId-keyed resource domain + a namespace rooted at spec.namespaceRoot
//             over the verified read-only base + a private tmpfs scratch), launch the
//             main process, return its CellHandle.
//   status  → read the CellId domain's lifecycle + counters.
//   destroy → walk the cell's job tree, kill every member, reclaim every domain-tagged
//             handle/resource (atomic teardown is the supervisor's duty — CAPABILITIES
//             §5.3), invoking `fence` before releasing volume handles (SC8).
//   liveCells → enumerate processes tagged with a CellId.
// The reconcile loop above this seam is unchanged by that work. Foundation-free.

/// The real C6 adapter. Holds the local image store so a future `create` can map the
/// verified content-addressed base into the cell's namespace; today it only records the
/// C6 gap. `imageStore` is retained to keep the construction site honest about what the
/// real adapter will need.
final class C6CellSupervisor: CellSupervisor {
    let imageStore: ImageStore

    init(imageStore: ImageStore) { self.imageStore = imageStore }

    func create(_ spec: CellSpec) -> CellCreateResult {
        // No kernel Cell primitive exists to assemble. Do not fabricate a handle.
        _ = spec
        return .unavailable(reason: "C6 cell supervisor not implemented (CellId tag only)")
    }

    func status(_ handle: CellHandle) -> CellRuntimeStatus {
        _ = handle
        return CellRuntimeStatus(phase: .failed, healthy: false, startedAtSeconds: 0)
    }

    func destroy(_ handle: CellHandle, fence: VolumeFence?) -> Bool {
        // Nothing was ever created, so teardown is trivially complete.
        _ = handle; _ = fence
        return true
    }

    func liveCells() -> [CellHandle] { [] }
}

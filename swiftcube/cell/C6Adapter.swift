// SPDX-License-Identifier: Apache-2.0
// C6Adapter.swift — the real CellSupervisor adapter onto the kernel C6 Cell primitives.
//
// **STATUS: kernel C6 is implemented; this adapter is NOT yet wired to it (SC3).**
// The C1–C6 capability/handle/IPC/cell arc has landed in the kernel: cells have
// per-domain accounting, creation + spawn-into-cell by handle, namespace-root
// confinement, a resident-page cap, and enumerate + teardown — exposed as syscalls
// `cell_stat(107)`, `cell_create(108)`, `cell_spawn(109)`, `cell_pids(110)`,
// `cell_destroy(111)` (see docs/CAPABILITIES.md §6 and docs/NOTES.md C6a–C6e). What is
// still missing is the SwiftCube-side wiring (the SC3 milestone): mapping a CellSpec
// onto those syscalls. Until SC3, this adapter does NOT fake a Cell — it returns
// `.unavailable` from `create`, which the reconcile loop surfaces as a Cell status the
// operator/SC4 can see. The QEMU end-to-end gate (SC3 case 9) is DEFERRED, not claimed.
//
// SC3 lights up the on-device path here (this is the only file that changes):
//   create  → assemble a cell via cell_create(namespaceRoot, pageCap) + cell_spawn the
//             main process with the granted handles (spawn-with-handles), over the
//             verified read-only base + a private tmpfs scratch; return its CellHandle.
//   status  → cell_stat the CellId domain's counters.
//   destroy → cell_pids to enumerate the job tree, reap every member, then cell_destroy
//             to reclaim the domain (teardown is the supervisor's duty — CAPABILITIES
//             §5.3), invoking `fence` before releasing volume handles (SC8).
//   liveCells → enumerate processes tagged with a CellId.
// The reconcile loop above this seam is unchanged by that work. Foundation-free.

/// The real C6 adapter. Holds the local image store so a future `create` can map the
/// verified content-addressed base into the cell's namespace; today it only records the
/// SC3-wiring gap. `imageStore` is retained to keep the construction site honest about
/// what the real adapter will need.
final class C6CellSupervisor: CellSupervisor {
    let imageStore: ImageStore

    init(imageStore: ImageStore) { self.imageStore = imageStore }

    func create(_ spec: CellSpec) -> CellCreateResult {
        // Kernel C6 exists (cell_create/cell_spawn/…), but the SwiftCube-side mapping
        // from a CellSpec onto those syscalls is the SC3 milestone and is not built
        // yet. Do not fabricate a handle until that path is wired + tested.
        _ = spec
        return .unavailable(reason: "SwiftCube cell adapter not wired to kernel C6 yet (SC3)")
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

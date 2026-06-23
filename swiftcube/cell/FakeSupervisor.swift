// SPDX-License-Identifier: Apache-2.0
// FakeSupervisor.swift — a deterministic host CellSupervisor for the SC3 acceptance tests.
//
// The fake models exactly the two things the atomic-teardown contract turns on — a
// per-Cell PROCESS count and a HANDLE/resource count — so a test can assert that
// `destroy` left nothing running (every process stopped, every handle released). It
// also models generations (a fresh `token` per create) and lets a test inject a crash,
// so the reconciler's restart/policy/backoff logic is exercised end to end without a
// kernel. It is NOT wired into the on-device `slet` (only the C6 adapter is); it lives
// in swiftcube/cell/ beside the seam it implements, compiled only into `slet-test`.
//
// Foundation-free; uses the injected `CubeClock` for `startedAt`.

final class FakeCellSupervisor: CellSupervisor {
    struct Cell {
        var handle: CellHandle
        var spec: CellSpec
        var processesRunning: Int   // simulated process group size (1 main process in v1)
        var handlesHeld: Int        // simulated capability/resource handles held
        var phase: CellPhase
        var startedAt: UInt64
    }

    private(set) var cells: [String: Cell] = [:]
    private var nextToken: UInt64 = 1
    let clock: CubeClock

    // Teardown audit (assertions read these).
    private(set) var destroyCalls = 0
    private(set) var lastDestroyFullyStopped = false
    private(set) var fencedVolumes: [String] = []
    // Process/handle leak ledger: a non-empty entry means a Cell was dropped while it
    // still held processes or handles (an atomicity violation). The fake never does
    // this, so the test asserts it stays empty.
    private(set) var leaks: [String] = []

    init(clock: CubeClock) { self.clock = clock }

    // MARK: CellSupervisor

    func create(_ spec: CellSpec) -> CellCreateResult {
        let h = CellHandle(cellId: spec.cellId, token: nextToken)
        nextToken &+= 1
        // One main process (v1: instance = one Cell with one main process); handles =
        // one per granted capability + one for the read-only base + tmpfs scratch.
        let handles = spec.capabilities.count + 1 + (spec.tmpfsScratch ? 1 : 0) + (spec.volume != nil ? 1 : 0)
        cells[spec.cellId] = Cell(handle: h, spec: spec, processesRunning: 1, handlesHeld: handles,
                                  phase: .running, startedAt: clock.nowSeconds())
        return .created(h)
    }

    func status(_ handle: CellHandle) -> CellRuntimeStatus {
        guard let c = cells[handle.cellId], c.handle.token == handle.token else {
            return CellRuntimeStatus(phase: .failed, healthy: false, startedAtSeconds: 0)
        }
        return CellRuntimeStatus(phase: c.phase, healthy: c.phase == .running, startedAtSeconds: c.startedAt)
    }

    func destroy(_ handle: CellHandle, fence: VolumeFence?) -> Bool {
        destroyCalls += 1
        guard var c = cells[handle.cellId], c.handle.token == handle.token else {
            // Already gone (or a stale generation handle) — teardown is trivially complete.
            lastDestroyFullyStopped = true
            return true
        }
        // Fence volumes BEFORE releasing the handle (SC8 contract).
        if let v = c.spec.volume, let f = fence { f.fence(cellId: handle.cellId, volume: v); fencedVolumes.append(v.name) }
        // Stop every process; release every handle — atomically, as one act.
        c.processesRunning = 0
        c.handlesHeld = 0
        let fully = c.processesRunning == 0 && c.handlesHeld == 0
        cells[handle.cellId] = nil
        lastDestroyFullyStopped = fully
        if !fully { leaks.append(handle.cellId) }
        return fully
    }

    func liveCells() -> [CellHandle] { cells.values.map { $0.handle } }

    // MARK: Test controls

    /// Inject a crash: the Cell's current generation exits with `exitCode`.
    func crash(_ cellId: String, exitCode: Int32) {
        guard var c = cells[cellId] else { return }
        c.phase = .dead(exitCode: exitCode); c.processesRunning = 0
        cells[cellId] = c
    }

    func isRunning(_ cellId: String) -> Bool { cells[cellId]?.phase == .running }
    func processCount(_ cellId: String) -> Int { cells[cellId]?.processesRunning ?? 0 }
    func handleCount(_ cellId: String) -> Int { cells[cellId]?.handlesHeld ?? 0 }
    func exists(_ cellId: String) -> Bool { cells[cellId] != nil }
    func token(_ cellId: String) -> UInt64? { cells[cellId]?.handle.token }
}

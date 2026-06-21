// SPDX-License-Identifier: Apache-2.0
// Schedule.swift — the pure placement function: Deployments → desired Assignments (SC4).
//
// `schedule(...)` is a deterministic pure function: same inputs ⇒ identical output, no
// clock, no store, no I/O. That is what makes placement trivially testable (case 9 calls
// it directly) and what lets the reconcile loop (SchedulerLoop.swift) treat it as the
// single source of placement truth, diffing its result against the store each pass.
//
// Inputs (all distilled by the loop from cubestore):
//   • deployments — desired state: per app, replicas / request / nodeSelector / pin hint.
//   • nodes       — availability (live lease ⇒ healthy), capacity, labels.
//   • placements  — the CURRENT world: every live Assignment joined with its observed
//                   Cell status. A placement on a healthy node is a running replica we
//                   keep; one whose node is gone never reaches us (the loop drops it),
//                   so its slot is simply missing and gets re-placed — that is the whole
//                   node-loss reschedule. A placement flagged `terminalFailed` (restart
//                   policy exhausted, §"reschedule vs restart") is also re-placed; a
//                   transient crash is NOT flagged, so it is kept (no churn).
//
// Algorithm per app (design §4): filter candidate nodes (healthy ∧ selector ∧ fits) →
// keep healthy non-failed replicas → scale up by spread-scoring onto the best nodes,
// scale down by evicting the most-loaded → unplaceable slots become `pending`, never
// dropped. Foundation-free and Dictionary-free (small linear scans, like the SC3
// reconciler): a cluster's node and per-app replica counts are small.

// MARK: - Distilled inputs / outputs

/// A node as the scheduler sees it (capacity lifted into the cell layer's ResourceLimits).
struct NodeView: Equatable {
    var id: String
    var healthy: Bool
    var capacity: ResourceLimits
    var labels: [String]        // "key=value"
}

/// One current placement: a live Assignment joined with its observed status.
struct Placement: Equatable {
    var cellId: String
    var app: String
    var revision: UInt64
    var slot: UInt32
    var generation: UInt64
    var node: String
    var request: ResourceLimits // what this replica consumes (its Deployment's request)
    var terminalFailed: Bool    // restart policy exhausted ⇒ re-place; transient crash ⇒ false
}

/// One Assignment the scheduler wants to exist, plus the node to write it under.
struct DesiredAssignment: Equatable {
    var node: String
    var assignment: Assignment
    var cellId: String { assignment.spec.cellId }
}

/// A replica that could not be placed this pass — surfaced, never silently dropped.
struct PendingPlacement: Equatable {
    var app: String
    var slot: UInt32
    var reason: String
}

struct ScheduleResult: Equatable {
    var desired: [DesiredAssignment]
    var pending: [PendingPlacement]
}

// MARK: - Resource fit helpers (free = capacity − Σ requests)

private func fits(_ free: ResourceLimits, _ req: ResourceLimits) -> Bool {
    free.cpuMillis >= req.cpuMillis && free.memBytes >= req.memBytes
}
private func minus(_ a: ResourceLimits, _ b: ResourceLimits) -> ResourceLimits {
    ResourceLimits(cpuMillis: a.cpuMillis >= b.cpuMillis ? a.cpuMillis - b.cpuMillis : 0,
                   memBytes: a.memBytes >= b.memBytes ? a.memBytes - b.memBytes : 0)
}
private func plus(_ a: ResourceLimits, _ b: ResourceLimits) -> ResourceLimits {
    ResourceLimits(cpuMillis: a.cpuMillis &+ b.cpuMillis, memBytes: a.memBytes &+ b.memBytes)
}

// MARK: - Working node state (mutated across the pass; cross-app free, per-app count)

/// Mutable per-node bookkeeping for one schedule() call. `free` is cross-app residual
/// capacity (persists across deployments in this pass); `appCount` is reset per app.
private struct WorkNode {
    let id: String
    let labels: [String]
    var free: ResourceLimits
    var appCount: Int
}

private func nodeIndex(_ nodes: [WorkNode], _ id: String) -> Int? {
    for i in 0..<nodes.count where nodes[i].id == id { return i }
    return nil
}

// MARK: - The pure function

/// Compute the desired Assignment set + pending list. Deterministic in `deployments`,
/// `nodes`, `placements`; the result's `desired` is sorted by (node, cellId) and
/// `pending` by (app, slot), so equal inputs yield byte-identical output.
func schedule(deployments: [DeploymentSpec], nodes: [NodeView], placements: [Placement]) -> ScheduleResult {
    // Only healthy nodes are placement targets, kept in id order for determinism.
    var work: [WorkNode] = []
    for n in nodes.sorted(by: { $0.id < $1.id }) where n.healthy {
        work.append(WorkNode(id: n.id, labels: n.labels, free: n.capacity, appCount: 0))
    }
    // Placements whose node is no longer healthy are lost replicas (their slot re-places).
    let live = placements.filter { nodeIndex(work, $0.node) != nil }

    // Free capacity = capacity − Σ requests of the non-failed replicas already resident
    // (a terminally failed replica is about to be replaced, so it frees its resources).
    for p in live where !p.terminalFailed {
        if let i = nodeIndex(work, p.node) { work[i].free = minus(work[i].free, p.request) }
    }

    var desired: [DesiredAssignment] = []
    var pending: [PendingPlacement] = []
    for dep in deployments.sorted(by: { $0.app < $1.app }) {
        scheduleApp(dep, work: &work, live: live, desired: &desired, pending: &pending)
    }

    desired.sort { a, b in a.node != b.node ? a.node < b.node : a.cellId < b.cellId }
    pending.sort { a, b in a.app != b.app ? a.app < b.app : a.slot < b.slot }
    return ScheduleResult(desired: desired, pending: pending)
}

// MARK: - Per-app placement

private func scheduleApp(_ dep: DeploymentSpec, work: inout [WorkNode], live: [Placement],
                         desired: inout [DesiredAssignment], pending: inout [PendingPlacement]) {
    let R = Int(dep.replicas)

    // Current replicas of THIS app at THIS revision (SC4 schedules one revision; other
    // revisions still consumed capacity above and are left to SC9).
    let mine = live.filter { $0.app == dep.app && $0.revision == dep.revision }
    let active = mine.filter { !$0.terminalFailed }   // keep candidates

    // Reset and seed this app's per-node replica count (the primary spread signal).
    for i in 0..<work.count { work[i].appCount = 0 }
    for p in active { if let i = nodeIndex(work, p.node) { work[i].appCount += 1 } }

    // --- Survivors vs scale-down victims ---
    var survivors: [Placement]
    if active.count > R {
        // Evict the most-loaded first: node with the most replicas of this app, then the
        // most resource pressure (least free), then a stable id/slot tie-break.
        let ranked = active.sorted { a, b in mostLoaded(a, b, work) }
        let victims = Array(ranked.prefix(active.count - R))
        for v in victims {                       // hand resources back; drop their count
            if let i = nodeIndex(work, v.node) {
                work[i].free = plus(work[i].free, v.request)
                work[i].appCount -= 1
            }
        }
        survivors = active.filter { v in !victims.contains(where: { $0.cellId == v.cellId }) }
    } else {
        survivors = active
    }

    // Survivors keep their (slot, generation, node, cellId) verbatim — no churn.
    for s in survivors {
        let spec = dep.template.materialize(cellId: s.cellId, node: s.node)
        desired.append(DesiredAssignment(node: s.node,
            assignment: Assignment(generation: s.generation, revision: dep.revision, spec: spec)))
    }

    // --- Scale up: fill the missing replicas onto the lowest free slot ordinals ---
    let need = R - survivors.count
    if need <= 0 { return }

    var occupied: [UInt32] = survivors.map { $0.slot }
    var placed = 0
    var slot: UInt32 = 0
    while placed < need {
        while occupied.contains(slot) { slot += 1 }          // next free slot ordinal
        occupied.append(slot)
        // A terminally failed slot's replacement bumps generation past the failed one;
        // a fresh slot starts at generation 1.
        var gen: UInt64 = 1
        for p in mine where p.terminalFailed && p.slot == slot { gen = max(gen, p.generation + 1) }

        if let i = bestNode(dep: dep, work: work) {
            work[i].free = minus(work[i].free, dep.request)
            work[i].appCount += 1
            let cellId = CellIdCodec.make(app: dep.app, revision: dep.revision, slot: slot, generation: gen)
            let spec = dep.template.materialize(cellId: cellId, node: work[i].id)
            desired.append(DesiredAssignment(node: work[i].id,
                assignment: Assignment(generation: gen, revision: dep.revision, spec: spec)))
        } else {
            pending.append(PendingPlacement(app: dep.app, slot: slot, reason: pendingReason(dep: dep, work: work)))
        }
        placed += 1
        slot += 1
    }
}

// MARK: - Scoring

/// Scale-down victim order: most replicas of this app first, then least free (most
/// loaded), then a stable id-desc / slot-desc tie-break. `true` ⇒ `a` is evicted before `b`.
private func mostLoaded(_ a: Placement, _ b: Placement, _ work: [WorkNode]) -> Bool {
    let ca = work[nodeIndex(work, a.node)!].appCount
    let cb = work[nodeIndex(work, b.node)!].appCount
    if ca != cb { return ca > cb }
    let fa = work[nodeIndex(work, a.node)!].free
    let fb = work[nodeIndex(work, b.node)!].free
    if fa.memBytes != fb.memBytes { return fa.memBytes < fb.memBytes }
    if fa.cpuMillis != fb.cpuMillis { return fa.cpuMillis < fb.cpuMillis }
    if a.node != b.node { return a.node > b.node }
    return a.slot > b.slot
}

/// Index of the best node for one more replica of `dep`, or nil if none is a candidate
/// (healthy ∧ selector ∧ fits). Spread first (fewest replicas of this app), then most
/// free resources, then node id. A pin hint that is itself a candidate wins outright —
/// the SC8 sticky-PV seam.
private func bestNode(dep: DeploymentSpec, work: [WorkNode]) -> Int? {
    var best: Int? = nil
    for i in 0..<work.count {                      // work is already id-sorted
        let n = work[i]
        guard matchesSelector(n.labels, dep.nodeSelector), fits(n.free, dep.request) else { continue }
        if !dep.pinHint.isEmpty && dep.pinHint == n.id { return i }   // pin wins outright
        if best == nil { best = i; continue }
        if betterCandidate(n, than: work[best!]) { best = i }
    }
    return best
}

/// True if candidate `a` outranks `b`: fewer replicas of this app, else more free memory,
/// else more free cpu, else lower id (work order already favors lower id, so this only
/// needs the strict wins).
private func betterCandidate(_ a: WorkNode, than b: WorkNode) -> Bool {
    if a.appCount != b.appCount { return a.appCount < b.appCount }
    if a.free.memBytes != b.free.memBytes { return a.free.memBytes > b.free.memBytes }
    if a.free.cpuMillis != b.free.cpuMillis { return a.free.cpuMillis > b.free.cpuMillis }
    return a.id < b.id
}

/// A node matches iff it carries every "key=value" the selector requires.
private func matchesSelector(_ labels: [String], _ selector: [String]) -> Bool {
    for req in selector where !labels.contains(req) { return false }
    return true
}

/// Why a slot could not be placed — distinguishes "no node matched the selector" from
/// "nodes matched but none had room", so the pending marker is actionable.
private func pendingReason(dep: DeploymentSpec, work: [WorkNode]) -> String {
    if work.isEmpty { return "no healthy node" }
    var anyMatch = false
    for n in work where matchesSelector(n.labels, dep.nodeSelector) { anyMatch = true; break }
    if !anyMatch { return "no node matches nodeSelector" }
    return "insufficient capacity (cpu=\(dep.request.cpuMillis)m mem=\(dep.request.memBytes))"
}

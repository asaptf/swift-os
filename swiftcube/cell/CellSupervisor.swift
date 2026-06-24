// SPDX-License-Identifier: Apache-2.0
// CellSupervisor.swift — the seam between slet's cluster reconcile loop and the C6
// userland Cell supervisor (SC3).
//
// This is the single boundary the SC3 design rule turns on: "slet is a cluster-aware
// wrapper over the C6 supervisor, not a replacement" (SWIFTCUBE_DESIGN §5). The
// supervisor owns the *local* mechanism — assemble a cell (job + handle set + resource
// domain + namespace) from a CellSpec, launch a process, supervise it, tear it down.
// slet owns the *cluster* loop — watch assignments, drive the supervisor toward
// desired state, report status. Everything below the protocol is C6's job; everything
// that consumes the protocol is the orchestrator's.
//
// Two implementations sit behind this seam: a host `FakeCellSupervisor` (deterministic,
// for the SC3 acceptance tests) and the real `C6CellSupervisor` adapter. Kernel C6 is
// implemented (cell_create/cell_spawn/cell_pids/cell_destroy, syscalls 107–111 — see
// CAPABILITIES §5/§6 and RISK_REMEDIATION_ROADMAP), but the SwiftCube-side wiring of a
// CellSpec onto those syscalls is the SC3 milestone and is not built yet, so the real
// adapter still returns `.unavailable` and the on-device gate is deferred (see
// C6Adapter.swift). Class-bound (`AnyObject`)
// so it monomorphizes to a single existential under Embedded Swift, matching the
// `CubeClock` seam. Foundation-free.

/// A Cell's lifecycle phase (SWIFTCUBE_DESIGN §5: `created → running → stopping →
/// dead`). `dead` carries the process exit code so the orchestrator can apply
/// `restartPolicy`; `failed` is a fatal state (could not launch / image rejected).
enum CellPhase: Equatable {
    case created
    case running
    case stopping
    case dead(exitCode: Int32)
    case failed
}

/// An opaque handle to a created Cell. `cellId` is the stable cluster identity (also
/// the resource-accounting domain key); `token` distinguishes generations so a stale
/// handle to a torn-down generation cannot be confused with a fresh one.
struct CellHandle: Equatable {
    var cellId: String
    var token: UInt64
}

/// A snapshot of a Cell's runtime state, polled by the reconciler.
struct CellRuntimeStatus: Equatable {
    var phase: CellPhase
    var healthy: Bool             // basic liveness (SC5 adds real probes)
    var startedAtSeconds: UInt64  // when the current generation launched
}

/// The outcome of `create`. A clean three-way split so the reconciler can tell a
/// policy decision (rejected — do not retry, e.g. a bad image) from an environment
/// gap (unavailable — C6 not present) from success.
enum CellCreateResult: Equatable {
    case created(CellHandle)
    case rejected(reason: String)     // spec/image refused; no Cell exists
    case unavailable(reason: String)  // the supervisor cannot create Cells here (C6 stub)
}

/// A fencing hook for SC8 persistent volumes (SWIFTCUBE_DESIGN §7). On teardown the
/// supervisor invokes this BEFORE releasing a volume handle, so no process of an old
/// Cell can still write to the volume after a reschedule. SC3 leaves it a seam (the
/// reconciler passes `nil`); SC8 supplies a real implementation (the `VolumeManager`).
/// Class-bound for the same existential reason as the supervisor.
protocol VolumeFence: AnyObject {
    func fence(cellId: String, volume: VolumeMount)
}

/// The mount half of the SC8 fencing contract (SWIFTCUBE_DESIGN §7). Before a Cell that
/// declares a persistent volume is (re)created, the reconciler asks the mounter to acquire
/// the volume's SINGLE writer. `acquire` returns false when the volume is still held by a
/// prior generation (its teardown/`fence` has not completed) or when this node's fencing
/// token is stale (a partitioned controller rebound the volume elsewhere) — in either case
/// the Cell must NOT be created this pass. This is the kernel-less, orchestrator-owned
/// single-writer guarantee: there is no atomic kernel destroy-Cell op, so serialization is
/// `slet`'s duty (CAPABILITIES §5.3). SC3 leaves it nil; SC8 supplies the `VolumeManager`.
protocol VolumeMounter: AnyObject {
    /// Provision-if-needed, bind-if-unbound, and acquire the single writer for the volume
    /// the given Cell owns. Returns true iff the mount is granted; false ⇒ defer creation.
    func acquire(cellId: String, volume: VolumeMount) -> Bool
}

/// The C6 Cell supervisor as seen by the cluster reconcile loop.
protocol CellSupervisor: AnyObject {
    /// Assemble and launch a Cell for `spec`. The caller (slet) has already resolved
    /// and signature-verified the image; the supervisor maps the spec onto kernel
    /// primitives and starts the main process.
    func create(_ spec: CellSpec) -> CellCreateResult

    /// Poll the current runtime state of a created Cell. A handle to a generation that
    /// is gone reports `.failed` (the caller treats an unknown handle as terminal).
    func status(_ handle: CellHandle) -> CellRuntimeStatus

    /// Atomic teardown: stop EVERY process of the Cell and release EVERY handle/
    /// resource, guaranteeing nothing of the Cell still runs. Because there is no single
    /// kernel "destroy-Cell" op (CAPABILITIES §5.3), this atomicity is the supervisor's
    /// duty. `fence` (SC8 seam) is invoked before releasing volume handles. Returns
    /// true iff teardown is fully verified.
    func destroy(_ handle: CellHandle, fence: VolumeFence?) -> Bool

    /// Enumerate the Cells the supervisor currently runs (the CellId-tagged jobs). This
    /// lets a freshly (re)started slet ADOPT already-running Cells instead of creating
    /// duplicates — the basis of level-triggered idempotency across slet restarts.
    func liveCells() -> [CellHandle]
}

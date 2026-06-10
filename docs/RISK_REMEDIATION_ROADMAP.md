// SPDX-License-Identifier: Apache-2.0
// RISK_REMEDIATION_ROADMAP.md — post-M13 plan to address architectural risks,
// with SMP as a required deliverable.
//
// This document is the living plan. It is intentionally separate from the
// core ARCHITECTURE.md so that the main design stays stable while we
// execute a deliberate remediation arc. All work here follows the project
// rules: one milestone (or sub-milestone) at a time, each builds + boots in
// QEMU (including with -smp) + has executable tests + is committed + review
// before the next.

# Risk Remediation Roadmap (post-M13)

## Why this arc exists

This document is **Phase 1** of the swift-os direction: hardening the bring-up system into a foundation that can credibly carry the product profiles — **application & AI hosting** (flagship) and **embedded/appliance** deployment (co-primary), with desktop use not excluded. (Phase 0 was bring-up: M0–M13 + the N-series network stack. Phase 2 is the forward full-OS build-out, sketched at the end of this document.)

The Phase 0 bring-up (M0–M8) and the portability/security/network arcs (M9–M13 + N-series) deliberately took single-core as a hard constraint. This kept the trusted core small, the scheduler simple, IRQ and context-switch paths easy to reason about, and the test surface manageable.

As of 2026-06 the system has a real capability model, real networking, real native Swift userland, and a realistic UEFI boot path. At this point several structural risks are visible in the code and contradict (or at least fall short of) the long-term vision recorded in ARCHITECTURE.md, PHILOSOPHY.md, and CAPABILITIES.md:

1. **Single-core assumption is now the largest blocker for the stated product profiles** (hosting application/AI/Node/Swift/JVM workloads at any scale; multi-tenant appliances). Cloud elasticity, multiple concurrent servers, and believable throughput all require SMP. (Single-purpose embedded appliances may stay single-core, but the kernel must still be concurrency-correct for the hosting profile.)

2. **Capability model is still the "flag + ambient inheritance" version.** CAPABILITIES.md describes the target (typed handles, per-handle Rights, spawn-with-handles, attenuation, IPC transfer). Only a CellId tag and a few syscall numbers (51–53) exist; the real C1–C6 work has not been done. This weakens every security and isolation claim.

3. **Privileged in-kernel drivers and the entire network stack contradict the documented architecture.** ARCHITECTURE.md and the driver-loading model call for restartable userland driver services with explicit capabilities (MMIO, IRQ endpoint, DMA windows) and a userland TCP/IP service. Today virtio-blk/net/input and the sans-IO stack live in the kernel. This bloats the trusted computing base and makes hot update / fault isolation aspirational.

4. **Global mutable state was written under a single-CPU execution model.** Scheduler tables, PMM bitmap, VFS shared description/pool tables, network engine state (ARP cache, connection tables), timer counters, etc. have no atomics, no per-CPU structure, and rely on IRQ masking + "only one CPU runs kernel code" for safety. Adding cores without fixing this will create data races and heisenbugs.

5. **Signal delivery is incomplete.** Custom handlers are recorded but not delivered via signal frames / sigreturn (noted in signal.swift and NOTES.md).

6. **Observability, resource domains, and A/B update/rollback are still only vision.** The CellId tag exists; real per-cell accounting, health, and signed image discipline do not.

7. **Allocator and hot-path simplicity assumptions** (bitmap PMM, simple VFS pools) will not survive real concurrency or larger workloads.

These are not small missing features. They are places where the current implementation diverges from the written architecture and from the "modern, lightweight, secure by construction, testable" priorities.

## Guiding principles (do not violate)

- Follow the strict workflow: one (sub)milestone at a time. After each: builds, boots under QEMU (both 1-CPU and -smp N), meets an acceptance criterion that includes concurrency stress where relevant, has a test, is committed, then stop for review.
- "Modern over legacy" and "lightweight by design" still win. SMP must not turn the kernel into a lock-heavy monolith.
- The C-arc (explicit capabilities + IPC) is a risk mitigation in its own right and a prerequisite for a sane multi-core driver/service model. We should not do heavy SMP work while still assuming ambient authority and in-kernel services.
- Record every major assumption (GIC version for SMP on QEMU virt, locking strategy, whether we keep a uniprocessor fast path, etc.) and re-verify against current QEMU source / hardware when we change boards.
- At any fork with serious consequences (locking model, GICv2 vs v3, uniprocessor fastpath, scheduler policy, etc.) — ask, do not guess. Note the decision in NOTES.md.
- Tests must catch races: add stress workloads that run on multiple CPUs simultaneously (alloc/free churn, fork/exec while other CPUs are busy, network under concurrent load, TLB shootdown scenarios, etc.).

## Recommended high-level sequence

Because the risks interact, a pure "SMP first" or "C first" ordering is suboptimal.

**Preferred order (subject to review before each phase):**

1. **Land the missing parts of the C-arc (C1–C4 at minimum)** that are already designed in CAPABILITIES.md.
   - This gives us real handles, spawn-with-explicit-handles (flips the inheritance default), and minimal zero-copy + batched IPC with poll integration.
   - These changes touch the same hot files (process.swift, vfs.swift, security.swift) that SMP will also touch.
   - IPC + handles are prerequisites for moving any driver out of the kernel (C5) and for a credible multi-core service model.
   - Existing busybox + Swift userland must continue to work (fork is emulated on top of the new spawn primitive).

2. **S0–S5 SMP series** (detailed below). During S work we treat the kernel as "SMP-aware but still mostly running on CPU 0" until S2/S3; only after basic cross-CPU execution is stable do we enable real concurrent EL0 work.

3. **C5 (first restartable userland driver)** + move at least the virtio-net (or input) path out of the kernel, using the new IPC + handle machinery. This makes the architecture documents honest again.

4. **Network service-ization** (the N-stack becomes a supervised userland service reachable only via capability-gated IPC endpoints). High-pps optimizations and TLS can ride on top.

5. **C6 (Cells as userland composition)** + richer observability + per-cell resource accounting. The CellId tag already exists; this turns it into a real (but still cheap) domain.

6. **A/B update story**, signed base images, manifest-driven boot, rollback health checks (builds on the two-tier FS and the now-smaller trusted core).

7. **Signal frames / sigreturn**, full custom handler delivery, and any remaining M13 follow-ups that were deferred.

Interleaving is allowed only when a sub-piece is small, reviewable, and has its own test. Large rewrites of scheduler + VFS + PMM at the same time are forbidden.

## SMP series (S0 – S5) — phased plan

All S milestones run on `qemu-system-aarch64 -M virt -smp 4` (or 2 for faster local iteration) in addition to the classic 1-CPU path. `make test` must cover both. The `-kernel` and UEFI/disk paths must continue to work.

### S0 — Foundations (no secondary CPUs executing kernel code yet)
Goal: make the kernel "SMP-aware in data structures and primitives" while still correct on one CPU.

- Add a reliable "current CPU id" (MPIDR_EL1 or a kernel-maintained per-CPU slot; decide and record).
- Introduce per-CPU data structures (array indexed by CPU id, or a small struct with one entry per possible CPU). Move at least scheduler current-thread / runqueue state and timer tick counters toward per-CPU.
- Provide (or expose) atomic operations and the necessary barriers (`dmb`, `dsb sy`, `isb`) that Swift code and C bridges can use. PageAllocator bitmap operations and VFS pool refcounts will need them later.
- Update boot.S: keep the secondary park path, but make the "park" code a clean WFE loop that can later be woken by an IPI or mailbox write. Add early per-CPU init hooks that are safe to call on secondaries (they must not touch global allocator state yet).
- Discover the QEMU `virt` secondary CPU release facts from the DTB (CPU Aff0 list, per-CPU `enable-method`, and PSCI call method/function IDs) without issuing CPU_ON yet. This is the S0/S1 handoff contract, not secondary bring-up.
- Audit and annotate every global `current*`, `systemTicks`, scheduler table, etc. with "SMP: will become per-CPU or protected".
- Add a host or early-boot unit test that exercises the new atomic/barrier shims if they are non-trivial.
- Acceptance: the system still boots and passes the full existing `make test` suite on 1 CPU. A new "S0" line appears in the boot log. No behavior change for userland.

Decision recorded at S1 (2026-06-09): always go through the general SMP paths.
No compile-time or boot-time uniprocessor fast path exists unless later
measurement justifies adding one.

### S1 — Secondary CPU bring-up and per-CPU early init (QEMU virt)
- On `-smp 2` / `-smp 4`, discover secondary CPUs and bring at least one (preferably all) to a state where they can execute kernel C/Swift code (EL1, MMU on, own stack, own vector table if needed, IRQs unmasked but no work yet).
- For QEMU virt the common mechanisms are a spin-table / mailbox or PSCI CPU_ON. Choose one, document the exact protocol and the addresses used, and verify against the QEMU version in use (see NOTES.md discipline).
  Current S0g evidence from QEMU 11.0.1 DTBs shows PSCI via `method = "hvc"` and
  `cpu_on = <0xc4000003>`, with `enable-method = "psci"` on secondary-capable
  CPU nodes. S1 uses that PSCI `CPU_ON` path and also publishes the existing
  mailbox release slot before `sev`, so eager parked secondaries and PSCI-started
  secondaries converge on the same `smp_secondary_entry`.
- Per-CPU GIC CPU interface initialization (GICC for each core). PPIs are already banked — good. SPIs still need routing policy.
- Per-CPU generic timer enable (the PPI is banked; each core can have its own periodic tick).
- A reliable "CPU N online" log line (or counter) visible on the console.
- Secondaries must be able to take a timer IRQ and EOI it without crashing, even if they do no scheduling yet.
- Acceptance: boot with `-smp 4` shows N "CPU x online" messages, all CPUs can see their own timer ticks (a cheap per-CPU counter is enough), the 1-CPU path is unaffected, and `make test` (both configurations) is green. Existing single-threaded demos and busybox still work. S1 keeps scheduler/process/VFS/driver work on CPU0; broad multi-CPU EL0 execution starts in S2.

Risk note: GICv2 on QEMU virt with >4 or 8 CPUs has known limitations in real silicon and sometimes in emulation. Record the maximum we intend to support for the first SMP release and the GIC version assumptions.

### S2 — Per-CPU scheduling and timer-driven preemption on all CPUs
- Pre-S2 readiness checkpoint (S2a, 2026-06-09): S1 now makes the banked
  timer heartbeat evidence explicit for every discovered CPU and verifies that
  secondary CPUs still have no scheduler/process ownership. After
  `schedulerInit` / `processInit`, CPU0 also records the scheduler-owner state
  in the per-CPU scaffold before S2 proper starts assigning EL0 or
  kernel-thread work away from CPU0.
- Pre-S2 readiness checkpoint (S2b, 2026-06-09): the EL0 process scheduler
  context storage is now fixed-size per-CPU and selected by `currentCpuId()`,
  while the runtime and static guards still prove that only CPU0 owns process
  scheduling before S2 intentionally enables secondary EL0 work. A post-userland
  boot check records CPU0 EL0 switches and verifies every secondary CPU still
  has zero EL0 switch activity.
- Pre-S2 readiness checkpoint (S2c, 2026-06-09): the kernel-thread scheduler is
  explicitly CPU0-owned, marks the CPU0 kernel scheduler ready in per-CPU
  state, records per-CPU kernel scheduler activity for real kernel-thread
  switches, and verifies after the scheduler demo that no secondary CPU ran
  kernel scheduler work. This keeps the M4.5 scheduler boundary executable
  until S2 introduces real per-CPU run queues.
- Pre-S2 readiness checkpoint (S2d, 2026-06-09): the EL0 process scheduler now
  uses a CPU-owned FIFO run queue scaffold instead of a global round-robin scan.
  The placement hook still assigns all runnable processes to CPU0 and the boot
  guard verifies secondary process run queues remain empty, so this is a
  reviewable step toward S2 without enabling secondary EL0 execution yet.
- Pre-S2 readiness checkpoint (S2e, 2026-06-10): CPU0 now publishes the dormant
  EL0 scheduler context pointer and empty process run queue mirror for every
  supported CPU. The idle/readiness checks distinguish dormant resources from
  execution, and the post-userland guard still proves secondary CPUs did not
  dispatch EL0 work.
- Pre-S2 readiness checkpoint (S2f, 2026-06-10): each actual EL0 process
  dispatch now records the dispatching CPU in per-process telemetry and a
  per-CPU aggregate counter. The per-process dispatch mask preserves enough
  history for the later "ran on multiple CPUs" assertion. The readiness guard
  cross-checks telemetry against the per-CPU EL0 switch counter while still
  proving all dispatches stay CPU0-owned before secondary EL0 execution is
  deliberately enabled.
- Pre-S2 readiness checkpoint (S2g, 2026-06-10): the existing `coproc` pair
  demo now captures both processes' dispatch counts and CPU masks before the
  slots are reaped. The guard requires both processes to have run and to have
  CPU0-only masks today, turning the future "two EL0 processes ran on different
  CPUs" acceptance into a ready executable check rather than a new harness.
- Pre-S2 readiness checkpoint (S2h, 2026-06-10): secondary EL0 execution is now
  controlled by an explicit closed gate in the process scheduler. Placement,
  dispatch telemetry, and scheduler-entry checks all go through that gate; boot
  logs readiness and "gate held" markers while preserving CPU0-only behavior.
  This makes the next S2 policy change a deliberate contract change instead of
  a search-and-replace of scattered `cpu != 0` guards.
- Give each CPU its own scheduler context / runqueue (or a carefully designed global structure with per-CPU current-thread). The old global `currentThread` / round-robin array must be replaced or indexed by CPU.
- Timer tick on every CPU drives local preemption (`schedulerTick` / `processOnTick` equivalents become per-CPU).
- Cross-CPU wake (a thread blocked on one CPU must be made runnable on another) requires an IPI or a shared ready queue + reschedule IPI. Start with the simplest thing that works.
- The careful IRQ-save / yieldToScheduler / schedule dance that was added to avoid re-entrancy panics must be generalized to per-CPU scheduler contexts.
- Acceptance: on `-smp 4` we can run the existing `coproc` demo (two EL0 processes) and observe them actually running on different CPUs (add a cheap "last CPU" field to the process record and assert it changes). Stress test: N busy-loop processes + timer preemption; no lost wakeups, no scheduler corruption. Full test suite green on both 1-CPU and 4-CPU QEMU invocations.

### S3 — IPI, TLB shootdown, and cross-CPU address-space / page-table safety
- S3a preflight (2026-06-10): the process scheduler now records a per-process
  address-space CPU mask and per-CPU activation counters on the real
  `address_space_switch(pTtbr0[slot])` path. The gate remains CPU0-only, so the
  marker proves no secondary address-space activation happened yet while giving
  S3 a concrete mask source for future shootdown targeting.
- S3b preflight (2026-06-10): the GICv2 SGI path now provides a minimal IPI
  substrate. Parked secondary CPUs remain IRQ-enabled after their timer
  heartbeat, can receive the reserved SGI, and only update fixed atomic IPI
  counters. Scheduler, VFS, PMM, and EL0 work remain gated to CPU0.
- Implement a minimal IPI / SGI mechanism (or use GIC SGI) for "reschedule this CPU", "TLB invalidate range on these CPUs", etc.
- When a page table change (munmap, mprotect, process exec/exit) happens on CPU A for an address space that may be active on CPU B, we must shoot down the TLB on B (or the relevant set of CPUs). Single-CPU `tlbi vmalle1` / `tlbi vae1` is no longer sufficient.
- `address_space_switch` and the TTBR0 install path must be safe when the same AS can be on multiple CPUs (or when we migrate a process).
- Add a "CPU mask" or "active CPUs for this AS" tracking (cheap for small core counts).
- Acceptance: a test that maps a page on one CPU, writes from another CPU's user thread, then unmaps from a third CPU, with TLB invalidation, and observes correct behavior (no stale translations, no kernel data abort). Existing mmap/mprotect/W^X tests plus a new cross-CPU variant pass. No regression in fork/exec heavy workloads.

### S4 — Concurrent physical memory and VFS / kernel object pools
- Make the PMM (PageAllocator bitmap + pmm_alloc/free) safe for concurrent calls from multiple CPUs. Options (choose and record): atomic bit operations (LDSET/STCLR or similar), a per-CPU magazine / cache layer in front of a locked central allocator, or a coarse spinlock + IRQ disable for the bitmap walk. The host PageAllocator unit test must be extended to concurrent alloc/free stress.
- Protect the shared VFS pools (`openDescriptions`, `pipes`, `endpoints`, the node table itself if mutations happen). Most per-process state is already indexed by slot; the shared descriptions need refcounting that is atomic or locked.
- Network engine state (if still in-kernel at this point) gets the same treatment or is explicitly documented as "will be moved out in the next phase".
- Add a concurrency stress test that runs many alloc/free, pipe create/close, fork/exec, and tmpfs create/write cycles while all CPUs are under timer load. Look for use-after-free, double-free, or lost updates.
- Acceptance: the stress test runs for a long time without corruption or panic on `-smp 4`. `pmm_free_count` and VFS handle accounting remain accurate. All prior tests still pass.

### S5 — Full multi-CPU EL0 execution + end-to-end validation
- EL0 threads belonging to the same address space (or different spaces) can truly execute on different CPUs at the same time.
- Scheduler can (even with a simple policy) place work on multiple CPUs; basic affinity or "run on any" is enough.
- All existing userland (busybox ash with pipes/redirects/fork/exec, native Swift tools, `/bin/httpd` under concurrent client load, vi, calc/kv REPLs, the network demos) must behave correctly and show utilization across CPUs (add a cheap per-CPU idle tick counter exposed via sysinfo or a new `top` column).
- Full `make test` (1-CPU and `-smp 4`, both -kernel and UEFI paths) is green, plus new dedicated SMP stress suites (`tests/smp_*`).
- The system is now "SMP complete" for the current workload class. Higher-level policy (load balancing, CPU hotplug awareness, cgroups-like limits) can come later.

After S5 we have a credible multi-core OS. At that point we immediately follow with C5 (move a driver) so that the architecture vision and the implementation are aligned again.

## Interaction with other risks (C-arc, network, observability, updates)

- C1–C4 should be substantially complete before or during early S work. The handle-passing IPC design in CAPABILITIES.md already calls for the zero-copy + batching + async rings properties that a multi-core network service will need.
- Once IPC + handles exist and SMP is basic, C5 (restartable driver) + network service-ization become the highest-leverage follow-ups.
- The CellId tag + per-process resource accounting (pages, handles, CPU time) become per-cell domains in C6. SMP makes the accounting visible and enforceable.
- A real A/B update + rollback story becomes both more necessary and more feasible once the trusted core is smaller (drivers and network out) and we have explicit capabilities.

## What success looks like (measurable)

- The kernel boots and runs the full existing workload on QEMU virt with `-smp 4` (and 8 for headroom testing) with no more panics or corruption than on 1 CPU.
- `make test` has explicit SMP configurations and at least one long-running concurrency stress that would have failed under the old global-state assumptions.
- The gap between ARCHITECTURE.md / CAPABILITIES.md and the code has narrowed: at least one driver lives outside the kernel, the network stack is reachable only through handles, and the capability model supports explicit grants rather than only ambient bits.
- We have a recorded, reviewed decision log for every hard SMP choice (locking, GIC, scheduler policy, uniprocessor fastpath, etc.).

## Non-goals for the first remediation arc (keep scope tight)

- Full NUMA awareness and big.LITTLE scheduling.
- CPU hotplug / physical hot-add at runtime (memory ballooning can come earlier, as already recorded).
- High-end lock-free data structures or complex RCU everywhere (start with correct + simple + tested; optimize only where profiles show pain).
- Changing the single address-space-per-process model or introducing kernel threads that are heavier than today.
- amd64 or other architectures (still out of scope).

## How to work on this document and the arc

- Update this file when a sub-milestone is completed or when a decision is recorded.
- Every Sx or Cx sub-milestone must have an entry in `docs/NOTES.md` (the same way M9–M13 and net-a..g were recorded).
- Before starting any S-phase that touches scheduler + VFS + PMM at once, raise it for explicit review — those three files are the highest-risk intersection.
- The plan can be adjusted, but only after a review checkpoint and with the rationale written here.

This roadmap turns the current set of "we deliberately didn't do X" into a deliberate, testable, reviewable sequence that brings the implementation back in line with the written architecture while delivering the SMP capability the project now requires.

## Phase 2 — toward a full hosting/embedded OS (record, don't build yet)

Once Phase 1 lands (real handles + IPC, basic SMP, at least one driver out of the kernel), the forward build-out makes swift-os a complete OS for its product profiles. Recorded here so Phase 1 decisions don't foreclose it; **not** to be implemented early:

- **Observability & metrics:** per-cell/per-process accounting, health states, request/latency/throughput metrics, memory-pressure and restart counters (see PHILOSOPHY.md "Observability" and the hosting metrics list in ARCHITECTURE.md).
- **A/B signed-image updates with rollback:** immutable signed base images, two slots, atomic switch, automatic rollback on failed health checks. This is shared between the hosting and embedded profiles.
- **Application runtimes:** native Swift application runtime first, then Node.js and the JVM, on the threads + futex + `mmap`(W^X) + poll + TLS primitives the ABI already keeps open.
- **Embedded footprint profile:** a build/config profile that strips optional services, minimizes the static image, and tightens deterministic boot for single-purpose appliances.
- **Service-ization completion:** move the remaining drivers and the network stack into restartable userland services reachable only via capability-gated IPC.
- **Richer device/display support:** as needed for the (not-excluded) desktop profile — beyond the current basic framebuffer + virtio-input.

(End of plan document. Next step after review: pick the first concrete Phase 1 sub-milestone — most likely a C-arc piece or S0 — write its acceptance criteria, implement, test, commit, report.)

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

2. ~~**Capability model is still the "flag + ambient inheritance" version.**~~ **Update (2026-06): RESOLVED.** The C1–C6 arc has landed (see the per-milestone sections below): a typed handle table with per-handle Rights and attenuation (C1), spawn-with-handles explicit inheritance (C2), object-scoped/confinement authority (C3), handle-passing IPC (C4), restartable userland driver services + real device grants (C5), and the full Cell arc — per-cell accounting, creation + spawn-into-cell by handle, namespace-root confinement, resource cap + enumerate + teardown, and a one-service-per-cell payoff (C6a–C6e, syscalls 107–111). The flat `caps` word remains a coarse class gate beside the handle table, as designed. Remaining capability work is incremental (richer per-cell limits, nested cells) — the structural risk is closed.

3. **Privileged in-kernel drivers and the entire network stack contradict the documented architecture.** ARCHITECTURE.md and the driver-loading model call for restartable userland driver services with explicit capabilities (MMIO, IRQ endpoint, DMA windows) and a userland TCP/IP service. Today virtio-blk/net/input and the sans-IO stack live in the kernel. This bloats the trusted computing base and makes hot update / fault isolation aspirational.

4. **Global mutable state was written under a single-CPU execution model.** Scheduler tables, PMM bitmap, VFS shared description/pool tables, network engine state (ARP cache, connection tables), timer counters, etc. have no atomics, no per-CPU structure, and rely on IRQ masking + "only one CPU runs kernel code" for safety. Adding cores without fixing this will create data races and heisenbugs.

5. **Signal delivery is still incomplete.** Current-process custom handlers have
   signal-frame/`sigreturn` delivery, but signal masks, process groups,
   blocked-syscall interruption, and remote async custom-handler delivery remain
   incomplete.

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

7. **Remaining signal semantics**: masks, process groups, blocked-syscall
   interruption, remote async custom-handler delivery, and any remaining M13
   follow-ups that were deferred.

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
- Restricted S2 execution checkpoint (S2h, 2026-06-10): `processRunPair` can
  temporarily start one secondary EL0 scheduler CPU and place the independent
  `coproc` pair across CPU0 and that secondary CPU. The process scheduler now
  uses per-CPU `currentProc` state, records secondary dispatch telemetry, and
  waits for scheduler-stack quiescence before reaping cross-CPU zombies. This
  is deliberately limited to independent top-level address spaces; migration,
  shared-address-space threads, cross-CPU wakeups, and broad VFS/PMM concurrency
  remain below.
- Give each CPU its own scheduler context / runqueue (or a carefully designed global structure with per-CPU current-thread). The old global `currentThread` / round-robin array must be replaced or indexed by CPU.
- Timer tick on every CPU drives local preemption (`schedulerTick` / `processOnTick` equivalents become per-CPU).
- Cross-CPU wake (a thread blocked on one CPU must be made runnable on another) requires an IPI or a shared ready queue + reschedule IPI. Start with the simplest thing that works.
- The careful IRQ-save / yieldToScheduler / schedule dance that was added to avoid re-entrancy panics must be generalized to per-CPU scheduler contexts.
- Acceptance: on `-smp 4` we can run the existing `coproc` demo (two EL0 processes) and observe them actually running on different CPUs (add a cheap "last CPU" field to the process record and assert it changes). Stress test: N busy-loop processes + timer preemption; no lost wakeups, no scheduler corruption. Full test suite green on both 1-CPU and 4-CPU QEMU invocations.

### S3 — IPI, TLB shootdown, and cross-CPU address-space / page-table safety
- S3a preflight (2026-06-10): the process scheduler now records a per-process
  address-space CPU mask and per-CPU activation counters on the real
  `address_space_switch(pTtbr0[slot])` path. S2h permits only CPU0 plus one
  explicitly started secondary scheduler CPU for the `coproc` acceptance path,
  and the post-run marker cross-checks address-space activations against
  dispatch telemetry while giving S3 a concrete mask source for future
  shootdown targeting.
- S3b preflight (2026-06-10): the GICv2 SGI path now provides a minimal IPI
  substrate. Parked secondary CPUs poll the restricted S2h scheduler hook, sleep
  IRQ-enabled after their timer heartbeat, can receive the reserved SGI, and
  only update fixed atomic IPI counters in the IPI handler. VFS, PMM, broad
  process scheduling, and reschedule/TLB IPI work remain gated off.
- S3c preflight (2026-06-10): TLB shootdown now has a fixed request/ack
  generation protocol on top of the S3b SGI path. CPU0 can publish a shootdown
  request to discovered secondaries, send the reserved IPI, and wait for each
  target to run a local `tlbi vmalle1` and atomically acknowledge it while the
  kernel scheduler remains CPU0-owned.
- S3d preflight (2026-06-10): VM TLB invalidation sites now route through an
  active-CPU-mask facade. Process-owned mmap/munmap/mprotect, demand paging,
  COW, and fork/COW parent rewrites pass the S3a address-space CPU mask into
  the S3c shootdown substrate; today that mask is limited to CPU0 plus the
  explicitly started S2h secondary scheduler CPU, but the page-table mutation
  boundary is now the future cross-CPU hook.
- Implement a minimal IPI / SGI mechanism (or use GIC SGI) for "reschedule this CPU", "TLB invalidate range on these CPUs", etc.
- When a page table change (munmap, mprotect, process exec/exit) happens on CPU A for an address space that may be active on CPU B, we must shoot down the TLB on B (or the relevant set of CPUs). Single-CPU `tlbi vmalle1` / `tlbi vae1` is no longer sufficient.
- `address_space_switch` and the TTBR0 install path must be safe when the same AS can be on multiple CPUs (or when we migrate a process).
- Add a "CPU mask" or "active CPUs for this AS" tracking (cheap for small core counts).
- Acceptance: a test that maps a page on one CPU, writes from another CPU's user thread, then unmaps from a third CPU, with TLB invalidation, and observes correct behavior (no stale translations, no kernel data abort). Existing mmap/mprotect/W^X tests plus a new cross-CPU variant pass. No regression in fork/exec heavy workloads.

### S4 — Concurrent physical memory and VFS / kernel object pools
- S4a preflight (2026-06-10): PMM allocation/free/refcount entry points now
  serialize access to the shared `PageAllocator` with a small IRQ-save coarse
  spinlock. The COW last-reference release path is a single locked PMM
  operation, host PageAllocator tests include a threaded allocation/free stress,
  and boot runs a bounded SGI-delivered PMM stress on discovered secondary CPUs.
  VFS/kernel object pools remain the next S4 target.
- S4b preflight (2026-06-10): VFS node/fd/open-description/pipe/endpoint/cwd
  and confinement tables now share an IRQ-save VFS lock. Long pipe, endpoint,
  socket, and disk-backed operations borrow their open description so the lock
  can be released before peer waits or network/block work. Boot validates VFS
  handle/open-description/pipe/endpoint accounting after `vfsInit` and again
  after the userland demos.
- S4c preflight (2026-06-10): the C bump heap behind
  `swiftos_kernel_alloc`, Swift allocation hooks, and `posix_memalign` now
  serializes cursor updates with an IRQ-save spinlock. Boot validates alignment,
  monotonic heap use, and lock balance before scheduler/userland demos and
  after them.
- S4d preflight (2026-06-10): package-store activation/append state now has a
  short IRQ-save lock around in-memory tables, active payload publication,
  record offsets, and counters. Target-side installs use a writer gate so
  hashing and virtio-blk writes do not run under the spinlock; readers copy an
  active payload snapshot before doing block I/O. Boot validates the
  package-store invariants before VFS consumes active package payloads and
  again after the userland demos.
- S4e preflight (2026-06-10): the in-kernel network/socket engine now has a
  short IRQ-save lock around `gNet`, DNS scratch state, socket tables, TCP
  connection state, RX datagram rings, and the virtio-net poll/TX/RX boundary.
  Blocking recv/accept/connect paths pump or wait outside the lock, while the
  boot net-a probe goes through locked helpers instead of touching `gNet`
  directly. Boot validates network invariants after the net probe and again
  after the userland demos.
- S4f preflight (2026-06-10): `/bin/s4stress` now runs as a normal userland
  program under the QEMU `-smp 4` boot harness, while secondary timer heartbeat
  and restricted scheduler scaffolding are active. It repeatedly exercises
  anonymous `mmap`/`munmap`, pipe create/dup/read/write/close, tmpfs
  write/rename/read cycles plus bounded create/unlink/mkdir/rmdir smoke paths,
  `fork`/`waitpid`, and `spawn`/exec of `/bin/argvdemo`. This is the
  restricted-SMP stress slice for the current S2h gate and fixed-size tmpfs
  vnode table; S5 still owns broad secondary EL0 execution.
- S4f stress gate (2026-06-10): `make test` also includes a dedicated
  `tests/smp_resource_stress_test.sh` run under `-smp 4`. The test keeps the
  current S2h policy intact (general EL0 work is still CPU0-owned), but repeats
  fork/IPC handle transfer, fd/pipe/poll/tmpfs churn, exec, futex-thread churn,
  and tmpfs create/write/move/remove loops after the boot demos while
  secondaries are online and ticking. It also verifies the S4a-S4e post-demo
  lock-boundary markers stayed balanced.
- Make the PMM (PageAllocator bitmap + pmm_alloc/free) safe for concurrent calls from multiple CPUs. Options (choose and record): atomic bit operations (LDSET/STCLR or similar), a per-CPU magazine / cache layer in front of a locked central allocator, or a coarse spinlock + IRQ disable for the bitmap walk. The host PageAllocator unit test must be extended to concurrent alloc/free stress.
- Protect the shared VFS pools (`openDescriptions`, `pipes`, `endpoints`, the node table itself if mutations happen). Most per-process state is already indexed by slot; the shared descriptions need refcounting that is atomic or locked.
- Network engine state (if still in-kernel at this point) gets the same treatment or is explicitly documented as "will be moved out in the next phase". S4e gives the current in-kernel engine a coarse correctness boundary; moving it to a userland service remains the architectural target.
- Add a concurrency stress test that runs many alloc/free, pipe create/close, fork/exec, and tmpfs create/write cycles while all CPUs are under timer load. Look for use-after-free, double-free, or lost updates. S4f provides the first bounded `make test` gate; S5 still needs the full general multi-CPU EL0 stress once broad secondary scheduling is enabled.
- Acceptance: the stress test runs without corruption or panic on `-smp 4`. `pmm_free_count` and VFS handle accounting remain accurate. All prior tests still pass.

### S5 — Full multi-CPU EL0 execution + end-to-end validation
- S5a preflight (2026-06-10): per-CPU timer and idle counters are exported
  through `SYS_sysinfo` and rendered by `/bin/top` as aggregate busy/idle plus
  a per-CPU busy line. The boot path validates the counter export for present
  CPUs, `tests/top_test.sh` can run under `-smp 4`, and
  `make smp-cpu-utilization-test` is the runtime gate. This gives S5 a cheap
  utilization signal before broad secondary EL0 scheduling is enabled.
- S5b placement batch (2026-06-10): the restricted S2h EL0 gate now has a
  bounded three-process acceptance path. CPU0 starts one secondary scheduler
  CPU, places a stable `coproc` pair across CPU0 and that secondary, runs a
  third CPU0 `coproc` tail in the same batch before reaping, captures dispatch
  telemetry, and logs the S5b marker under `-smp 4`. This proves repeatable
  batch placement across CPUs without enabling arbitrary secondary scheduling,
  shared-address-space concurrency, migration, or load balancing.
- S5c placement stress (2026-06-10): EL0 run queue enqueue/dequeue is protected
  by a per-CPU IRQ-save spinlock, and the restricted gate now runs repeated
  independent `coproc` placement rounds through one secondary scheduler CPU plus
  CPU0 tails. The guard captures aggregate dispatch masks/counts before reap,
  checks that the secondary role stayed on a non-primary online CPU under
  `-smp 4`, and verifies all run queues and gate masks are idle afterward.
- S5d fanout (2026-06-10): the restricted gate can start every online secondary
  scheduler CPU and run one independent EL0 process per scheduler CPU in the
  same acceptance window. The guard proves the dispatch CPU mask exactly matches
  the fanout scheduler mask, each process stayed on its home CPU, all queues are
  idle after stop, and the single-CPU fallback still works.
- S5e thread fanout (2026-06-10): `/bin/threadsdemo` now has a gated
  shared-address-space SMP acceptance path. The futex wait table is protected by
  an IRQ-save spinlock, `FUTEX_WAIT` releases that lock before yielding, and the
  S5e gate places created EL0 threads round-robin on active secondary scheduler
  CPUs while their creator stays on CPU0. The guard proves two sibling threads
  shared the creator TTBR0, exited from their home CPUs, used the futex lock, and
  left futex waiters, run queues, and secondary gate masks idle afterward.
- S5f run-any placement (2026-06-10): the default process placement hook now has
  a gated run-any acceptance policy that round-robins across CPU0 plus active
  secondary scheduler CPUs. The boot demo creates more `/bin/coproc` processes
  than scheduler CPUs without explicit home CPU affinity, then proves the policy
  selection count matched process creation, the dispatch CPU mask exactly matched
  the scheduler CPU mask, every process stayed on its selected home CPU, and all
  queues/gates were idle after stop. Secondary scheduler start waits send the
  reserved SGI/IPI so the S5f gate is not dependent on a timer tick waking a CPU
  sleeping in `wfi`; secondary timer preemption is gated by active+run masks and
  rejects the stop mask while the gate closes.
- S5 aggregate readiness gate (2026-06-10): `make s5-test` now runs the S5a-S5f
  focused gates in order, giving reviews one aggregate runtime-readiness command
  while preserving the narrow milestone targets.
- All existing userland (busybox ash with pipes/redirects/fork/exec, native Swift tools, `/bin/httpd` under concurrent client load, vi, calc/kv REPLs, the network demos) must behave correctly and show utilization across CPUs (add a cheap per-CPU idle tick counter exposed via sysinfo or a new `top` column).
- Full `make test` (1-CPU and `-smp 4`, both -kernel and UEFI paths) is green, plus new dedicated SMP stress suites (`tests/smp_*`).
- The system is now "SMP complete" for the current workload class. Higher-level policy (load balancing, CPU hotplug awareness, cgroups-like limits) can come later.

After S5 we have a credible multi-core OS. At that point we immediately follow with C5 (move a driver) so that the architecture vision and the implementation are aligned again.

### C5a — restartable driver-service supervisor smoke (DONE, 2026-06-10)

- `/bin/drvsvcdemo` now supervises `/bin/drvinputd`, a pseudo input-driver
  service. The supervisor creates endpoint pairs, starts the service, receives a
  readiness message, sends a command, receives an event, stops the service, and
  repeats the flow with a fresh generation.
- The boot path requires `C5a OK: restartable driver service recovered over IPC`;
  `make c5-driver-service-test` is the focused `-smp 4` direct-boot gate.
- Non-goals: C5a does not grant MMIO, IRQ, DMA, or real virtio-input ownership to
  userland yet. C5b/C5 proper still owns the device-handle and real driver
  extraction work.

### C5b — opaque device-handle handoff scaffold (DONE, 2026-06-10)

- `HandleKind.device` now exists as a non-duplicable, transferable, opaque
  device-ownership grant. The first registry entry is `pseudo-input.0`, a C5
  scaffold device with no MMIO, IRQ, or DMA grant.
- New `device_claim` / `device_info` syscalls let the boot authority claim the
  pseudo device, inspect fixed metadata, and transfer the resulting handle over
  C4 IPC.
- `/bin/drvsvcdemo` now moves the device handle to `/bin/drvinputd`, proves the
  supervisor's source fd is invalid after the move, proves a second claim is
  busy while the service owns the grant, stops the service, and reclaims the
  device after release.
- The boot path requires `C5b OK: opaque device handle transferred and released`;
  `make c5-device-handle-test` is the focused direct-boot gate.
- Non-goals: C5b still does not expose MMIO mapping, IRQ endpoints, DMA windows,
  or real virtio-input ownership. The next C5 slice should make discovery
  manifest matching executable and then begin moving a non-boot-critical driver
  out of the kernel.

### C5c — virtio-input device discovery and manifest matching (DONE, 2026-06-10)

- New `device_discover(index, info*)` syscall exposes read-only device registry
  metadata to the boot authority. It returns the same fixed `device_info` record
  used by device handles and reports `-2` when enumeration is exhausted.
- The device registry now prefers a discovered `virtio-input.0` grant when the
  QEMU virtio-mmio input transport is present. The registry records the
  transport window, bus/kind metadata, and `DISCOVERED`/`NO_MMIO_GRANT` flags.
  Headless direct boots without a keyboard device keep `pseudo-input.0` as a
  fallback so the C5 supervisor/lifecycle path remains executable.
- `/bin/drvsvcdemo` discovers the registry manifest first, claims the discovered
  device name, validates the metadata, transfers the grant to `/bin/drvinputd`,
  proves busy/reclaim behavior, and emits
  `C5c OK: virtio-input device grant discovered and matched` when the focused
  QEMU keyboard path is present. The broad headless boot still emits
  `C5c OK: device discovery manifest matched pseudo input`.
- `make c5-device-discovery-test` attaches QEMU `virtio-keyboard-device` and
  runs the focused `-smp 4` acceptance gate; `make c5-device-handle-test`
  remains a compatibility alias for the same C5 driver-service gate.
- Non-goals: C5c still does not grant userland MMIO mappings, IRQ endpoints, or
  DMA windows, and the in-kernel virtio-input path still owns the actual input
  queue. The next C5 slice should decide the first real hardware authority
  grant and driver replacement boundary.

### C5d — virtio-input discovery metadata (DONE, 2026-06-10)

- The virtio-input probe now uses the discovered `platform.virtioMmio*` window
  instead of fixed QEMU constants. The device registry reuses that probe to
  surface a `VIRTIO_MMIO` bus, MMIO base, and MMIO length for `virtio-input.0`
  when a `virtio-keyboard-device` is attached.
- The grant still carries `NO_MMIO_GRANT`; MMIO fields are discovery metadata,
  not authority. IRQ remains zero because the current keyboard path is polled and
  IRQ endpoints are still future work.
- `/bin/drvsvcdemo` and `/bin/drvinputd` accept both the synthetic fallback and
  discovered virtio-input metadata, and the focused boot gate requires
  `C5d OK: virtio input discovery metadata surfaced`.
- `make c5-device-metadata-test` is the focused `-smp 4` gate. It attaches a
  QEMU virtio keyboard while preserving the headless fallback lifecycle tests.
- Non-goals: C5d still does not map MMIO into userland, deliver IRQs as
  endpoints, create DMA windows, or replace the in-kernel virtio-input driver.

### C5e — device authority envelope preflight (DONE, 2026-06-10)

- The public device flag ABI now reserves explicit future hardware-authority
  bits for MMIO, IRQ, and DMA grants. Current C5 grants must keep those bits
  clear and continue to set `NO_MMIO_GRANT`.
- `/bin/drvsvcdemo` and `/bin/drvinputd` reject device metadata that advertises
  MMIO/IRQ/DMA authority before the kernel implements the corresponding handoff.
  The smoke path emits `C5e OK: device authority withheld until explicit handoff`.
- `make c5-device-authority-test` is the focused `-smp 4` gate. It attaches a
  QEMU virtio keyboard and proves that discovered metadata remains metadata-only.
- Non-goals: C5e does not choose the first real authority type or move the
  virtio-input queue to userland. It creates the guardrail for that next step.

### C5f — metadata-only device grant rights contract (DONE, 2026-06-10)

- Device handles are minted through the shared `deviceMetadataGrantRights()`
  helper. Until a real MMIO/IRQ/DMA handoff lands, the only device rights are
  `.getattr` and `.transfer`: services can inspect and receive a grant, but they
  cannot duplicate it, map it, or treat it as read/write/execute authority.
- `/bin/drvsvcdemo` now emits
  `C5f OK: device grant rights stayed metadata-only` after proving the grant can
  be inspected and transferred but cannot be duplicated.
- `make c5-device-rights-test` runs the host handle vocabulary test plus a
  static guard that the VFS claim path uses the shared metadata-only rights
  helper and that the C5 runtime marker is wired into the focused driver-service
  smoke.
- Non-goals: C5f still does not expose a userland MMIO mapping syscall, IRQ
  endpoint, DMA window, or virtio-input queue ownership. It is the rights-side
  contract before the first real authority grant.

### C5g — device authority capability gate (DONE, 2026-06-11)

- `/bin/deviceauthdemo` is a negative EL0 probe for restricted principals. It
  calls `device_discover(0, info*)` and `device_claim("pseudo-input.0", info*)`
  after the guest login path has adopted principal 3 with only `capSpawn`.
- The probe emits `DEVICE-AUTH-DISCOVER-DENY-OK err=-13`,
  `DEVICE-AUTH-CLAIM-DENY-OK err=-13`, and
  `C5g OK: non-console principal cannot discover or claim device grants`.
- `make device-authority-cap-test` is the focused QEMU gate. It proves C5
  authority is capability-gated before any opaque grant exists, complementing
  C5e/C5f's metadata-only and rights checks after the boot authority has minted
  a grant.
- Non-goals: C5g does not add a new authority type, does not change device
  registry policy, and does not move virtio-input out of the kernel. It freezes
  the existing `capConsole` minting boundary as an executable check.

### C5 aggregate readiness gate (DONE, 2026-06-10)

- `make c5-test` is the review-facing aggregate for the C5 driver-service and
  device-authority readiness slice. It names the existing C5a-C5g focused gates
  in order: `c5-driver-service-test`, `c5-device-handle-test`,
  `c5-device-discovery-test`, `c5-device-metadata-test`,
  `c5-device-authority-test`, `c5-device-rights-test`, and
  `device-authority-cap-test`.
- The aggregate preserves the narrow gates for targeted debugging while giving
  broader reviews a single command that covers restartable supervision, opaque
  device grants, discovery metadata, withheld hardware authority, the
  metadata-only rights contract, and guest denial before grant minting.
- The full `make test` gate now runs `make c5-test`, and
  `make stability-coverage-test` statically guards the required memory/resource,
  hardware/SMP, security/isolation, update/rollback, package, network, C5, and
  UEFI coverage categories. The hardware/SMP category includes an executable
  QEMU `virt` DTB hardware-map guard for PL011, GIC, timer, PSCI, CPU topology,
  and virtio-mmio facts, plus a `.swpkg` header-integrity negative test for
  package artifact trust fields.

### C5h — MMIO authority grant reaches the supervised userland driver (DONE, 2026-06-23)

- First slice of "C5 proper": real hardware authority leaves the kernel through the
  supervised capability-transfer path. `virtio-input.0` is now registered with
  `deviceFlagMmioGrant | deviceFlagDiscovered` (no `deviceFlagNoMmioGrant`), so a
  `capConsole` claim yields a `.map` right. The LA1 supervisor claims it and
  transfers the grant over IPC to `/bin/svc-input`, which `sys_device_mmap`s the
  window and verifies the virtio magic/device-id registers through the userland
  mapping.
- Registry decision: `virtio-input.0` carries the real grant going forward; the
  former mappable alias `virtio-input-mmio.0` is removed and replaced by an inert,
  discoverable `virtio-input-meta.0` that preserves the metadata-only negative-path
  coverage (legacy `drvsvcdemo`/`drvinputd` and the LA2 `devicemmapprobe` EACCES
  refusal). See `docs/NOTES.md` (C5h) for the full rationale.
- Acceptance: `make c5-mmio-grant-test` requires
  `C5h OK: MMIO 0x<base> mapped from userland, MAGIC verified`; `make c5-test` and
  `make device-mmio-map-test` stay green. The kernel's polled keyboard driver still
  owns the device at C5h (both read the same read-only ID registers); the kernel
  exit is C5i and userland TTY injection is C5j.
- Non-goals: C5h does not remove the in-kernel polled driver, does not add IRQ or
  DMA authority, and does not yet make the userland driver feed the TTY.

### C5i — virtio-input driver runs entirely in userland; kernel exits the device (DONE, 2026-06-23)

- The kernel skips `virtioKbdInit()` and the per-tick drain when the registry shows
  a mappable virtio-input grant (queried once via `vfsVirtioInputUserlandOwned()`),
  so the device is driven only from EL0. `/bin/svc-input` brings the event virtqueue
  up entirely in userland (reset → features → queue setup → DRIVER_OK → kick).
- VA→PA for virtqueue setup uses **Option A**: a new `SYS_virt_to_phys(va, handle_fd)`
  (syscall 105) gated on owning a mappable device grant, so only an actual device
  owner can resolve physical addresses. Volatile MMIO/ring access uses new
  `swiftos_mmio_*`/`swiftos_dmb` C bridges. Poll strategy stays polled (no userland
  IRQ delivery yet); the C5i self-test does a bounded used-ring drain.
- The supervisor hands the device to every generation, so a kill+restart genuinely
  re-claims, re-maps, and re-initializes the live device — recovery, not just first
  init. Acceptance: `make c5-userland-driver-test`
  (`C5i OK: userland virtio-input driver initialized and recovered`).
- Intentional transitional regression: the kernel no longer feeds virtio-input
  keystrokes to the tty, so the graphical-window keyboard is dead until C5j restores
  it via userland tty injection. Serial/headless input (PL011 UART) is unaffected.
- Non-goals: C5i does not deliver IRQs to userland, does not make the driver a
  persistent forever-running service, and does not yet feed the tty.

### C5j — userland driver injects keystrokes into the tty; interactive keyboard restored (DONE, 2026-06-24)

- Adds `SYS_tty_inject(byte)` (syscall 106), gated on **capConsole** (the ambient
  option; the capability-handle alternative was deferred). It feeds the same
  `ttyOnInput` line-discipline entry the UART IRQ uses, so injected bytes reach a
  blocked `ttyRead` like typed serial input.
- New persistent `/bin/inputd`, launched by swos-init (`SERVICE_INPUTD` + an `inputd`
  token in `/etc/swos/services`): it owns virtio-input, runs a forever poll loop that
  decodes evdev key presses (shared `virtio_input_user.swift` core) and injects each
  byte into the tty, yielding 1 ms between polls. A no-op (clean exit) on boards with
  no virtio-input device, so it is safe to list unconditionally.
- Acceptance: `make c5-tty-inject-test` QMP `send-key`s "guest<Enter>" into the
  virtio device and asserts `C5j OK: TTY bytes injected from userland driver` plus
  console-login advancing to the `Password:` prompt (a full username line read driven
  by injected keys). `make run` interactive keyboard works again.

### C5 proper — DONE (2026-06-24)

C5h + C5i + C5j complete "C5 proper": real hardware authority reaches a supervised
EL0 driver, the kernel exits the virtio-input device entirely (userland owns the
virtqueue), and the userland driver feeds the tty so interactive keyboard works. Next
high-leverage steps: network serviceization (a restartable userland net service
reusing the device-grant + shmring plumbing) or C6 Cells.

## Network serviceization (NS series)

Move the in-kernel net stack toward a restartable userland service, reusing the C5
plumbing (device grant + `device_mmap` + `virt_to_phys` + shmring). Strictly
incremental and non-disruptive: the in-kernel net driver keeps serving sshd/nginx/
DHCP until a userland service can fully replace it. NS1–NS3 prove the architecture on
a path that does not touch the live primary NIC; full replacement of the in-kernel
TCP/socket stack is a separate long-horizon epic, out of NS1–NS3 scope.

### NS1 — virtio-net MMIO grant reaches userland (DONE, 2026-06-24)

- `resetDeviceRegistry()` publishes a mappable `virtio-net.0` grant
  (`deviceFlagMmioGrant`, kind `deviceKindVirtioNet`) for the virtio-net transport
  window, claimed by name (non-discoverable, to keep the legacy C5 demo's discovery
  contract intact). `/bin/netmmapprobe` claims it, maps the window, and reads the
  device identity + config MAC from userland — coexisting with the live kernel NIC.
- Acceptance: `make ns1-net-grant-test` requires `NS1 OK: virtio-net MMIO mapped from
  userland, MAC … DEVID verified` plus the kernel net stack staying up (ICMP echo).
- Non-goals: NS1 does not run a userland NIC driver, does not touch the kernel net
  path, and does not move any socket/TCP logic.

### NS2 — userland virtio-net driver does real TX/RX on a secondary NIC (DONE, 2026-06-24)

- `virtioNetDiscoverGrant(ordinal:)` selects which NIC window to expose; the registry
  publishes a drivable `virtio-net.1` grant only when a SECOND NIC exists (the kernel
  always binds the first). `/bin/netdriverprobe` claims it, brings up RX+TX
  virtqueues entirely from EL0 (per-page `virt_to_phys`, no contiguity assumption),
  and does an ARP round-trip against slirp — proving real TX and RX from userland
  without disturbing the primary kernel NIC. `maxDevices` 4→6.
- Acceptance: `make ns2-net-driver-test` (two virtio-net devices) requires the NS2 OK
  ARP-reply marker plus the primary kernel NIC's ICMP echo reply.
- Non-goals: NS2 does not make the driver persistent/restartable (NS3), does not use
  a shmring data plane yet, and does not touch the kernel net path or socket layer.

### NS3 — restartable userland net service over a shmring data plane (DONE, 2026-06-24)

- `/bin/netsvc` is a supervised, restartable userland service that owns the secondary
  NIC (virtio-net.1, via the shared userland virtio-net core) and relays frames over a
  full-duplex shmring (LA3) channel: it consumes frames from ring0 and TRANSMITS them
  on the NIC, and PRODUCES received frames into ring1 — zero kernel net stack involved.
  `/bin/netsvc-demo` (the supervisor/client) creates the channel, spawns netsvc across
  two generations, and relays an ARP request/reply through it, proving kill+restart
  recovery over the same data plane.
- Acceptance: `make ns3-net-service-test` (two virtio-net devices) requires the gen-1
  and gen-2 relayed-ARP-reply markers, the restart marker, `NS3 OK`, and the primary
  kernel NIC's ICMP echo. No-op on the single-NIC profile.
- Non-goals: NS3 does not replace the in-kernel TCP/socket stack (a separate
  long-horizon epic), does not make the secondary NIC a general-purpose interface, and
  does not add userland IRQ delivery (the service polls).

### NS arc — DONE (NS1 + NS2 + NS3, 2026-06-24)

The network-serviceization architecture is proven end to end on a non-disruptive path:
a userland driver can map a NIC (NS1), drive real TX/RX on a dedicated NIC (NS2), and
run as a restartable service with an shmring zero-copy data plane (NS3) — all without
touching the live primary kernel NIC. Remaining long-horizon work (its own epic):
moving the actual TCP/socket stack and the primary NIC's path to userland, plus
real-HW cache maintenance for userland DMA and userland IRQ delivery.

## Cells (C6 series) — userland composition over the CellId tag

Turn the long-reserved per-process `CellId` tag into a real (but still cheap)
resource-accounting + namespace-rooting domain, with the cell *policy* assembled by a
userland supervisor (docs/CAPABILITIES.md §5 — **no fat in-kernel `Cell` object**).

### C6a — per-cell resource-accounting domain (DONE, 2026-06-24)

- `SYS_cell_stat(107)` aggregates one `CellId`'s live `{processes, residentPages,
  cpuTicks, handles}` by an on-demand scan of the bounded process table (filtering on
  each process's existing `pSecurity[i].cell`) — no per-cell counter table, so there
  is **zero per-op accounting cost** and a reaped process drops out of the total for
  free. Gated on `capProcessInspect`. `vfsHandleCount(slot:)` supplies the per-process
  handle count. Children already inherit the parent's `CellId`; everything runs in
  `globalCell` today.
- Acceptance: `make c6-cell-accounting-test` — the `/bin/cellstatprobe` boot probe
  forks 3 children (pipe-barrier liveness, no timing race), asserts the aggregate grew
  by exactly 3 live processes (and pages + handles grew), then that reaping them
  reclaims the charge (`processes` back to baseline). Single-core and `-smp 4`; wired
  into `make test`.
- Non-goals: C6a does not create cells (C6b), confine namespaces (C6c), or enforce
  limits/teardown (C6d) — it only makes the accounting domain observable.

### C6b — cell creation + control handle + spawn-into-cell (DONE, 2026-06-24)

- `HandleKind.cell`: an opaque, transferable capability token naming a CellId
  (rights `[.write, .duplicate, .transfer]`; no byte stream). A bounded `cells[]`
  table (`maxCells = 8`, index 0 = globalCell) in vfs.swift under `vfsLock`.
- `SYS_cell_create(108)` (capConsole) allocates a fresh CellId and returns a `.cell`
  control-handle fd, writing the new id to an out-param. Closing the handle does NOT
  free the cell (teardown is explicit, C6d) — a crashed supervisor leaves the domain
  contained + accounted, the honest trade-off from §5.3.
- `SYS_cell_spawn(109, cell_fd, path, argv, specs, count)` launches a child into the
  cell named by `cell_fd`. Authority is **by handle**: a caller without the handle
  cannot name the cell (EBADF). The child inherits explicit handles (same ABI as
  `spawn_handles_async`) and is re-tagged into the cell, so its resources charge to
  the new domain, not globalCell.
- Acceptance: `make c6-cell-create-test` — the `/bin/cellcreateprobe` supervisor
  refuses a spawn without the handle, creates cell 2, launches `/bin/cellchild` into
  it, and asserts via cell_stat that the child is charged to cell 2 (not globalCell)
  and reclaimed on reap. Single-core + `-smp 4`; wired into `make test`.
- Non-goals: C6b does not confine the cell's namespace (C6c) or enforce
  limits/teardown (C6d). The cell shares the global VFS root until C6c.

### C6c — per-cell namespace root (DONE, 2026-06-24)

- `CellSlot.root`: a cell carries a VFS root node (0 = unconfined). `SYS_cell_create`
  grows a `root_path` arg (NULL/"/" = unconfined); other paths resolve to a directory
  the cell's processes are confined to. `vfsApplyCellNamespace` sets a spawned
  member's C3 `confineNodes` + `cwd` to the cell root, so it resolves `/` within the
  subtree and any path outside (including the global root) is refused by the existing
  `isDescendant` check. No separate per-cell mount table — pure C3 reuse.
- Acceptance: `make c6-cell-namespace-test` — `/bin/cellnsprobe` creates a cell
  rooted at /www and launches `/bin/cellnschild`; the child resolves a file inside
  the root but is refused /etc/motd and `/`, while the default cell stays unconfined.
  The existing C3 confinement markers (boot_test.sh) stay green. Single-core + `-smp
  4`; wired into `make test`.
- Non-goals: C6c does not tear cells down or enforce limits (C6d).

### C6d — cell lifecycle: resource cap + enumerate + teardown (DONE, 2026-06-24)

- Hard resident-page cap: `cell_create` grows a `page_cap` arg (0 = unlimited),
  enforced before `createProcess` in the spawn-into-cell path — a new member is
  refused (ENOMEM) once the cell's aggregate resident pages reach the cap. A
  pre-allocation guard, so no teardown path / SMP race; soft to within one member.
- `SYS_cell_pids(110)` enumerates a cell's live members by tag (the supervisor's
  job-tree walk). `SYS_cell_destroy(111)` frees the CellId, refused with EBUSY while
  any member is live (the supervisor reaps first); on free the cell generation is
  bumped (monotonic) so the dangling control handle resolves stale — the `.cell`
  handle carries a generation stamp validated on every resolve, closing the
  slot-reuse confused-deputy hole.
- Acceptance: `make c6-cell-lifecycle-test` — `/bin/cellcapprobe` caps a cell, spawns
  until the cap refuses, enumerates the members, proves destroy is EBUSY while live,
  then reaps + frees the CellId and reuses it (stale handle rejected). Single-core +
  `-smp 4`; C6a–C6c + the C3 markers stay green; wired into `make test`.
- The honest trade-off (§5.3) stands: no atomic kernel "destroy the cell" — teardown
  is the supervisor walking the enumerated job tree, with the per-process tag +
  destroy-refuses-while-live as the backstop.

### C6e — one service per cell, end to end (DONE, 2026-06-24)

- The payoff: `/bin/cellsvcprobe` (a cell supervisor) assembles a cell = { a /www
  namespace root + a restricted handle set + a resident-page cap }, `cell_spawn`s a
  real request/reply service `/bin/cellhello` inside it with exactly three granted
  handles (stdout + the two RPC endpoint ends), drives a live `ping`→`pong`
  round-trip, confirms `cell_stat` charges the service to the cell, then stops +
  reaps it and `cell_destroy`s the cell. The service proves its own isolation on
  startup (a path outside /www is denied; the ungranted fd 0 is absent).
- Acceptance: `make c6-cell-service-test` — the cell-assembly + the service's two
  isolation proofs + the pong round-trip + `processes=1` + clean teardown + `C6e OK`.
  Single-core + `-smp 4`; wired into `make test`.

### C6 arc — DONE (C6a + C6b + C6c + C6d + C6e, 2026-06-24)

The per-process CellId tag is now a real (still cheap) isolation/accounting domain,
assembled and supervised entirely in userland over small kernel primitives — **no fat
in-kernel `Cell` object** (CAPABILITIES.md §5). A cell has per-domain resource
accounting (C6a), is created + launched into by handle (C6b), confines its processes
to a namespace root (C6c), supports a resource cap + member enumeration + explicit
teardown (C6d), and hosts a real isolated service end to end (C6e — the
"one service per cell" shape). Remaining Cell work hardens this into production-grade
cells (the C7 arc): intra-member page enforcement (C7a, below), a per-cell handle cap
(C7b), a persistent restart/FDIR cell supervisor (C7c), and lifting a real in-tree
service into a cell (C7d).

### C7a — intra-member resident-page cap enforcement (DONE, 2026-06-24)

- Closes the first C6d gap: the resident-page cap was enforced only at spawn-into-cell
  time (refuse a NEW member past the ceiling), so a single existing member could still
  grow its own heap/mmap past the cap. C7a enforces the cap at the per-process
  resident-page **growth** sites, so a capped cell's *aggregate* can never exceed it.
- One guard helper `processCellGrowthAllowed(slot, addPages)` is consulted at the
  growth sites (`processSbrk`, both `processMmap` commit paths, `processMprotect`
  anon-commit, `processMapSharedFrames`), refusing with a clean errno (ENOMEM) before
  allocating. The common case is zero-cost: a `globalCell` member short-circuits on one
  integer compare (no lock, no scan); only a capped cell takes the lock + bounded scan.
  Out of scope (documented): the demand-paged file-fault path and device MMIO map still
  charge the cell but are not hard-refused — the refusal lives on the anonymous-growth
  syscalls a service uses to balloon.
- Acceptance: `make c7-cell-pagecap-test` — `/bin/cellgrowprobe` caps a cell, launches
  `/bin/cellgrower` into it; the grower `sbrk`s until refused (cap bites mid-member),
  confirms `mmap` is also refused (cross-path), and the supervisor asserts
  `cell_stat.residentPages <= cap` while an uncapped global member grows past `cap`
  pages unaffected. Single-core + `-smp 4`; wired into `make test`.

### C7b — per-cell handle cap (DONE, 2026-06-24)

- A per-cell **handle** cap, the analogue of the page cap, **folded into `cell_create`**
  (symmetric with `page_cap`, no new syscall): `cell_create(root, page_cap, handle_cap,
  out_cell_id)`; `CellSlot.handleCap`. Enforced at the user-facing handle constructors
  (open/dup/pipe/socket/accept/endpoint/openpty/socketpair via an `allocUserFD` wrapper,
  plus an inline `dup2` guard) — a capped member that mints a handle past the cell's
  aggregate count is refused with **EMFILE**. Delegation paths (spawn-grant install, IPC
  handle transfer) are deliberately NOT capped — authority handed in, not self-growth.
  globalCell + uncapped cells short-circuit (zero cost).
- Acceptance: `make c7-cell-handlecap-test` — `/bin/cellhandleprobe` caps a cell + launches
  `/bin/cellopener`; the opener `open()`s until refused (EMFILE), the supervisor asserts
  `cell_stat.handles <= cap`, and an uncapped global member opens past `cap` handles
  unaffected. Single-core + `-smp 4`; wired into `make test`.

### C7c — persistent restart/FDIR cell supervisor (DONE, 2026-06-24)

- A dedicated long-running **`/bin/cell-supervisor`** that hosts **`/bin/cell-svc`** in a
  cell, detects its exit/crash via `waitpid`, tears the cell down (`cell_pids` → reap →
  `cell_destroy`), and restarts in a FRESH cell with bounded restarts. Phase A: gen 1 up
  (ping→pong), faulted, gen 2 restarted in a **different CellId** (allocated before the
  faulted one is reclaimed) with accounting reclaimed across generations. Phase B: a
  crash-looping service is restarted up to a bounded cap (3), each generation reclaimed,
  then the loop halts. Each cell carries the C7a page cap + C7b handle cap. (Chosen per
  review: dedicated supervisor; demo service in C7c, real service in C7d; CPU budget
  deferred.)
- Acceptance: `make c7-cell-supervisor-test` — the gen-up / fault / fresh-CellId /
  accounting-reset / bounded-crash-loop markers + `C7c OK`. Single-core + `-smp 4`; wired
  into `make test`.

### C7d — a real in-tree service in a supervised cell (DONE, 2026-06-24)

- The C7 payoff: lift the EXISTING real service **`/bin/kv`** (in-memory key-value store)
  into a supervised cell, unchanged, over pipes (chosen over HTTP/TCP and a new KV-over-IPC
  service — offline, deterministic, least new code). **`/bin/cell-kv-supervisor`** assembles
  a cell { `/tmp` root + page cap + handle cap }, `cell_spawn`s kv with exactly two handles
  (stdin pipe + stdout pipe), drives a real `SET`/`GET` round-trip, asserts isolation +
  accounting, faults it (closes stdin), detects the exit, restarts in a **fresh cell** whose
  store is empty (`GET` → `(nil)`, proving a new process), then reclaims + tears down. Caps
  are generous (pageCap 4096 / handleCap 16) so a real service is not strangled — C7a's
  intra-member page cap correctly trapped kv at the first too-tight value (96), recorded as
  the lesson.
- Acceptance: `make c7-cell-realservice-test` — round-trip + isolation + fresh-cell restart
  + fresh-state + clean teardown markers + `C7d OK`. Single-core + `-smp 4`; wired into
  `make test`. **C7 arc complete (C7a–C7d).**

## Process-table capacity (PT series) — scale the slot table for the hosting profile

The EL0 process table was capped at 16 slots since bring-up. That is tight for the
flagship application/AI-hosting profile once you count init, the login path, the
supervised services the C5/C7 arcs add, and a real app plus its workers. This short
series raises the cap and — the substantive part — removes the latent coupling that
made raising it unsafe. Full design + measurement in docs/NOTES.md (PT series).

### PT1 — unify the process-slot cap and raise 16 → 64 (DONE, 2026-06-24)

- The cap lived as **three** independent `16` literals that all meant "number of
  process slots" and silently had to move together: `maxProc` (process.swift, the
  table), `maxVFSProcesses` (vfs.swift — the per-process VFS handle/cwd/confine
  tables are slot-keyed, so a drift corrupts FD indexing), and `maxFutexWaiters`
  (futex.swift — at most one parked waiter per thread, so bounded by the slot count;
  if `maxProc` exceeded it the dead queue-full EAGAIN branch would come alive
  untested). PT1 makes all three derive from one `let kMaxProcesses = 64`
  (process.swift), so the cap can never again be raised in one table without the
  others. `maxEndpoints` (IPC, not per-process) is intentionally left at 16.
- **Measurement set the value, and killed a fancier design.** Per-slot static cost is
  ~26 KB, dominated by two heavyweight per-process tables sized for real runtimes
  (the `maxFDs = 512` handle table ≈ 12 KB and the `maxAnonVmas = 512` anon-VMA table
  ≈ 12 KB, "512 covers Node"). So 64 slots ≈ 1.7 MB static — noise on the 4 GB
  hosting target. A two-tier decouple (small default + on-demand pool for FD/VMA) was
  **rejected** as premature: ~1.5–3 MB saved against hot-path indirection on every FD
  op + a pooled allocator under `vfsLock` + a large SMP/test surface. The
  embedded/appliance profile, where footprint matters, lowers `kMaxProcesses` (and,
  later, the FD/VMA sizes) in one place instead.
- Userland `/bin/ps` and `/bin/top` keep their own mirrors (`SWIFTOS_PS_MAX`,
  `SWIFTOS_TOP_MAX`, `pidMax`), all raised 16 → 64 so they don't truncate the listing.
- Acceptance: `make procmax-test` — `/bin/procmaxprobe` forks pipe-barriered children
  until `fork()` returns `-EAGAIN`, asserting > 16 were live at once, a clean EAGAIN at
  the boundary, exact live-count growth, and no slot leak after saturate-and-reap.
  Single-core + `-smp 4`; wired into `make test`.
- Follow-ups (not blocking): bump `maxEndpoints` for IPC-heavy multi-service loads; an
  `embedded` build profile that lowers `kMaxProcesses` + the FD/VMA table sizes together.

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

## D-series — persistent /data storage (durable SQLite) (DONE, 2026-06-16)

Driven by the website-hosting goal (nginx + Let's Encrypt + Node/Strapi + SQLite):
the stack needs storage that survives reboot, which the two-tier bring-up FS
(read-only signed base + RAM tmpfs) does not provide. The D-series adds a third,
**persistent writable tier** at `/data` — an explicit, reviewed change to the
"data loss on reboot is acceptable by design" hard decision (CLAUDE.md is updated
to describe a three-tier FS). The base stays immutable and unjournaled; datafs is
a small inode-table + block-bitmap filesystem with no journaling, and crash-safety
relies on honest `fsync` plus the application's own journaling (SQLite's rollback
journal). Full design + decisions are in `docs/NOTES.md` (D-series).

- **D0** (`acd659d`): a second, writable virtio-blk "data" disk (`SWDATAFS` magic),
  with raw read/write/flush; boot self-test proves a counter survives reboot.
  Gate: `make data-persist-test`.
- **D1** (`7deacfb`): `kernel/fs/datafs.swift`, mounted at `/data`, mirrored into
  the VFS; create/open/read/write/lseek/ftruncate/mkdir/unlink/rmdir/rename route
  to disk. Gate: `make datafs-test`.
- **D2** (`4a61aef`): `fsync`/`fdatasync`/`sync` syscalls flush the data disk to
  stable media. Gate: `make datafs-fsync-test`.
- **D3** (`4bcb6d4`): the packaged `sqlite3` shell baked into the base image;
  POSIX record locks accepted (no-op) in `vfsFcntl`. Acceptance:
  `make datafs-sqlite-test` — a database on `/data` survives reboot.

Follow-ups (not blocking): double-indirect blocks for >4 MiB files; moving the FS
into a userland service in line with the driver-serviceization arc; per-cell
quotas on `/data`.

## K-series — mutable credentials over the immutable base (DONE, 2026-06-27)

The identity store `/etc/swos/passwd` lives in the read-only, Ed25519-signed base
image, so a password change cannot edit it in place — and must not, or it would
break the immutability/signature guarantee. The K-series adds a **crash-safe
credential overlay** on the persistent `/data` tier (built on the D-series), merged
over the base at authentication time. Because datafs has no journal and no atomic
rename (only honest `fsync`), crash-safety is built at the application layer, as
CLAUDE.md prescribes.

Design (full crash analysis in the `swos_identity.swift` header):
- **Dual-bank ping-pong.** The overlay is two fixed-size, SHA-256-checksummed,
  generation-stamped banks (`/data/swos/passwd.{0,1}`). A change is written to the
  non-winning bank then `fsync`'d; the `fsync` is the single commit point. A crash
  only ever tears the non-winning bank (caught by checksum, ignored), so the last
  committed credential always survives — no single crash reverts a committed
  non-default password to the base default.
- **Provisioned anchor.** A second dual-bank pair (`/data/swos/prov.{0,1}`) records
  a monotonic high-water generation. After provisioning, if both passwd banks are
  lost/corrupt or a stale lower-generation overlay is restored (rollback — disk rot
  or `/data` tampering, never a single crash), auth **fails closed** instead of
  falling back to the factory default. Recovery is a physically-gated path (K4).
- **Hashing.** Passwords are hashed with PBKDF2-HMAC-SHA256 (field format
  `pbkdf2-sha256$<iters>$<salthex>$<dkhex>`); the legacy `salt$sha256hex` base-seed
  format is still verified for compatibility.

- **K1 (this commit):** `userland/lib/swos_identity.swift` — PBKDF2, the password-
  field codec, the bank serializer/checksum, dual-bank selection, and the merge +
  ping-pong + anchor resolve policy. Pure (no syscalls): builds into userland ELFs
  and the host test alike. Gate: `make test` runs `tests/identity_test.swift`
  (PBKDF2 vectors + the full crash/rollback permutation matrix proving the
  anti-rollback property). No boot-path change yet.
- **K2 (DONE):** `/bin/passwd` — self-service change: verify old password, write the
  new passwd bank (ping-pong) + advance the anchor, honest `fsync`/report. Salt from
  the kernel RNG (`swiftos_random`). Gate: `tests/passwd_change_test.sh` (login →
  change ×2 → original rejected, all within one boot). Requires the PT1 process-table
  fix to avoid boot-time exec exhaustion.
- **K3 (DONE):** console-login authenticates through the shared resolver, so a
  changed password works at login and the default is refused; a provisioned-but-
  corrupt store fails closed (recovery message) instead of restoring the default.
  Gate: `tests/passwd_persist_test.sh` — two QEMU boots over one data disk prove the
  change persists across reboot (old/default rejected, new password accepted).
- **K4 (DONE):** boot-flag recovery path so fail-closed never bricks the box. The
  kernel reads `/chosen/bootargs` from the parsed DTB; the token `recovery` sets a
  kernel-wide `recoveryMode`, exposed to userland via the `recovery_mode` syscall
  (116). In recovery, console-login and passwd authenticate against the read-only
  base store only — bypassing the overlay and its fail-closed state — so an operator
  with boot access logs in with factory credentials and re-provisions (the new
  password is written above the anchor watermark, repairing the store). Physically
  gated by boot access (the recovery flag rides in the loaded device tree). Gate:
  `tests/passwd_recovery_test.sh` — four boots prove recovery bypasses a changed
  overlay with factory creds, re-provisions, and that normal boots stay
  overlay-authoritative.

The K-series is complete: passwords are mutable over the immutable signed base via
a crash-safe `/data` overlay, changes work at login and survive reboot, anti-rollback
fails closed instead of reverting to default, and recovery prevents a brick.

## H-series — bare-metal Hetzner ARM bring-up (IN PROGRESS, 2026-06-16)

Driven by the website-hosting goal: make SwiftOS boot as the *actual OS* of the
user's Hetzner ARM cloud VM (`swiftos.tech:651`, wipeable), reachable over SSH —
not as a QEMU guest under Linux. The VM presents a different device model than the
QEMU `virt` board SwiftOS targets today; this arc writes the missing drivers/boot
support. All work stays **dual-path** (detect, don't replace) so the existing
QEMU-virt (DT / virtio-mmio / GICv2 / virtio-blk) profile and its tests keep
passing. Full design + per-stage findings are in `docs/NOTES.md` (H-series).

Gaps vs SwiftOS today (probed from the live VM): ACPI firmware (no FDT), virtio
over PCIe, GICv3, virtio-scsi boot disk, virtio-net-pci. Console (PL011) and RAM
base (`0x4000_0000`) match.

- **H0** (DONE, this branch): `make hetzner-run` — a local QEMU profile that
  reproduces the VM device model (`-M virt,gic-version=3 -cpu max -m 4G -smp 2`,
  ACPI on, virtio-scsi-pci boot disk, virtio-net-pci, virtio-rng-pci) so H1–H5
  develop without the server. **Key findings:** the EFI loader already reads the
  kernel from the ESP over virtio-scsi-pci via firmware (so H3's ESP-ramdisk root
  is viable); under ACPI mode the firmware publishes **no FDT config table** (only
  ACPI/RSDP) — so **H5 must parse ACPI, there is no FDT fallback**; the kernel
  panics at GICv2 CPU-interface MMIO (`0x0801_0000`) under GICv3, the concrete H1
  signal. See `docs/NOTES.md` H0 for the full survey.
- **H1** (DONE, this branch): GICv3 driver — `kernel/drivers/gic.swift` is now
  dual-path. Version detected from `ID_AA64PFR0_EL1.GIC` (fault-free, unlike
  probing GICD_PIDR2 which aborts on the v2 distributor). GICv3 adds distributor
  ARE + per-PE redistributor wake + a system-register CPU interface (ICC_SRE/PMR/
  IGRPEN1/IAR1/EOIR1/SGI1R) and SPI routing via GICD_IROUTER. Acceptance:
  `make gicv3-test` proves interrupts live multi-core on `-M virt,gic-version=3`
  (CPU0 + secondary timer IRQ, secondary online, SGI/IPI), GICv2 path unchanged.
  Bonus: `make hetzner-run` now clears GIC init too. See `docs/NOTES.md` H1.
- **H2** (DONE, this branch): PCIe ECAM enumeration + virtio-PCI transport.
  `kernel/drivers/pci.swift` scans the ECAM (0x40_1000_0000), assigns BARs (or
  reuses firmware's), and parses the modern virtio capabilities; matches modern
  and transitional device ids. `virtio_transport.swift` is the `mmio | pci`
  control-plane abstraction; `virtio_rng` now binds over either. The early MMU
  map gained the high-ECAM and 64-bit-PCI-window device blocks (+40-bit IPS).
  Acceptance: `make virtio-pci-test` exchanges an entropy virtqueue over
  virtio-pci; also reached on `make hetzner-run` (UEFI firmware BARs). See
  `docs/NOTES.md` H2.
- **H3** (DONE, this branch): root FS without virtio-scsi. The EFI loader reads
  `base.img` from the ESP into RAM (below 2 GiB) and hands the kernel a ramdisk
  via a new x4/x5 entry ABI; `kernel/fs/ramdisk.swift` + the VFS mount the
  read-only base from RAM (preferring a virtio-blk base when one is attached, so
  `-kernel` boots are unchanged). Acceptance: `make h3-ramdisk-test` boots the
  GPT disk under UEFI on the Hetzner profile (virtio-scsi boot disk, no
  virtio-blk) to `swift-os login:` with no block driver bound. See `docs/NOTES.md`
  H3. H0–H3 now boot the real-target device model end-to-end to login.
- **H4** (DONE, this branch): virtio-net over PCI + SSH. `virtio_net` binds over
  the `VirtioTransport` (mmio|pci) abstraction (extended for per-queue notify,
  device-feature negotiation, and device-config/MAC reads). Also fixed a GICv3
  SPI-delivery bug (SPIs must be put in Group 1 via `GICD_IGROUPR`; the UART RX /
  NIC IRQs were silent — H1 had only exercised the PPI timer + SGIs). Acceptance:
  `make h4-ssh-pci-test` boots GICv3 with the NIC + RNG on PCIe, gets a DHCP lease
  over virtio-net-pci, autostarts `/bin/sshd`, and a host OpenSSH client runs a
  bounded `/bin/id` end-to-end (publickey auth, exec status 0). See `docs/NOTES.md`
  H4. H0–H4 now boot the Hetzner device model end-to-end and are SSH-reachable.
- **H5** (DONE, this branch): boot on ACPI firmware. The loader forwards the RSDP
  (x6); `kernel/arch/aarch64/acpi.swift` parses RSDP→XSDT→MADT (GIC + CPUs), MCFG
  (ECAM), SPCR (UART), FADT (PSCI), all MMU-off (the tables sit high in RAM).
  `platformInit` prefers ACPI over the FDT. Acceptance: `make h5-acpi-test` boots
  the Hetzner device model and the kernel derives gic/redist/uart/ecam + CPU
  topology + PSCI from ACPI (no DTB), then the whole stack comes up on those
  values (GICv3, secondary CPU via PSCI, virtio-pci, DHCP). See `docs/NOTES.md`
  H5. H0–H5 boot the Hetzner model end-to-end, SSH-reachable, with no FDT.
- **H6** (planned): real-server bring-up — build the GPT disk, `dd` onto the VM
  boot disk via rescue, observe over serial/VNC, iterate until SSH reaches
  SwiftOS. SAFETY: confirm with the user before the destructive step; keep a
  rescue path.

## V-series — mountable multi-volume storage (planned)

Driven by the hosting/appliance profiles: the D-series gave **one** persistent
`/data` tier on **one** dedicated virtio-blk disk. The product needs to attach
**additional** persistent storage — a second/third local disk, or a **Hetzner
Cloud Volume**. A Hetzner Volume is, from the OS's point of view, *just another
block device*: on the real server it appears on the same virtio-scsi/virtio-pci
transport the H-series already brought up (H0–H5); under QEMU `virt` it is one
more `virtio-blk-device`. So "second disk" and "Hetzner Volume" are the **same
problem**, and the hard part is not discovery (the block layer already enumerates
up to 8 devices and identifies them by sector-0 magic — see `virtioBlkInit`) but
two upper-layer simplifications inherited from the D-series:

1. **datafs is a singleton.** Global inode table, global block bitmap, a single
   bound device (D0). Physically there can be many disks, but the persistent FS
   exists exactly once in the code.
2. **There is no mount table.** Mounting today is not an operation but an implicit
   graft: `/data`'s vnode carries `dataFs=true` + `dfsInode`. The VFS knows the one
   datafs instance through a hardcoded boolean on the VNode.

The "one disk" constraint thus lives in *policy* (one `blkServedDevice`, one
datafs, one graft), not in the driver.

**Decisions recorded (reviewed 2026-06-24; the "ask, don't guess" forks resolved):**

- **Namespace: global single tree first.** Mounts land in one shared VFS tree;
  per-cell visibility rides on the existing C3 / C6c confinement (`isDescendant`),
  not a separate per-cell mount table. Per-cell mount namespaces are a later option.
- **API: both declarative and runtime, converging on one source of truth.** There
  is a single mount table, persisted as a file on the root `/data` volume
  (e.g. `/data/.system/mounts`). The *declarative* path = that file edited offline
  / staged at image prep. The *runtime* path = a capability-gated `mount()` that
  applies immediately and, with a `PERSIST` flag, writes through to the same file.
  No Linux-style "fstab vs live state" divergence.
- **Manifest lives on the root data volume** (decision: on `/data`, not the signed
  base or kernel cmdline). It is read only *after* the root `/data` is mounted, so
  a plain datafs file is sufficient; no chicken-and-egg beyond the root anchor.
- **Root volume is anchored by UUID in the kernel cmdline** (the single pinned
  identity in the scheme). On first boot a blank root disk is formatted as the root
  and its UUID recorded. Everything else is discovered from the manifest on it.
- **Guardrail (because the manifest is now mutable, unsigned state):** data-disk-
  driven mounts are confined to a designated mount root (`/mnt/*`); system paths
  (`/bin`, `/etc`, `/usr`) are off-limits to manifest-driven mounting, the mountpoint
  must be an empty directory (no legacy overmount that hides contents), and a disk is
  **never** auto-formatted unless sector 0 has no valid magic (a non-blank unknown
  disk is left untouched). This keeps the immutable-base trust intact.

Sub-milestones (one at a time, each builds + boots single-core and `-smp 4`, has a
test, committed, review before the next):

- **V0** (DONE, 2026-06-24): de-singleton datafs + generic mount graft — a pure
  refactor with no new disk and no behavior change. datafs global state is now a
  `DfsVolume` record in `dfsVolumes[]` (only slot 0 used); a `vol:` param is threaded
  through the whole datafs API; `virtioBlkVolume{Read,Write,Flush,CapacitySectors}`
  are the device-indexed block layer (the `virtioBlkData*` entry points became thin
  volume-0 wrappers); the VNode carries `dfsVolume` beside `dfsInode`; `datafsMirror`
  is volume-parametrized; rename refuses crossing volumes. Acceptance met: `make
  data-persist-test` / `datafs-test` / `datafs-fsync-test` / `datafs-sqlite-test`
  stay green unchanged. See `docs/NOTES.md` (V-series).
- **V1** (DONE, 2026-06-27): mount a **second** `SWDATAFS` volume at `/mnt/data1`.
  The virtio-blk scan now records every SWDATAFS disk (`blkDataDevices[]`), not just
  the first; `vfsMountDataFs` mounts the second as datafs volume 1 under `/mnt/data1`
  (a distinct instance, scan-ordered — pre-V2 there is no on-disk label). Acceptance
  met: `make v1-volume-test` boots TWO data disks, writes the same filename to `/data`
  and `/mnt/data1` with different content (a shared store would alias them), proves a
  `/data`-only file is absent on volume 1, and that both volumes read back their own
  content after reboot. Single-core; the existing D0–D3 datafs gates stay green.
- **V2** (volume identity + declarative manifest) — split into V2a/V2b/V2c:
  - **V2a** (DONE, 2026-06-27): volume identity + mount-by-label. The datafs
    superblock gains a 128-bit UUID (generated at format, stable across reboot) and
    a human label (provisioned offline, preserved across format). `vfsMountDataFs`
    now picks the root `/data` disk by IDENTITY — the first **unlabeled** datafs disk
    — and mounts every **labeled** disk at `/mnt/<label>`, so /data and the storage
    volumes are deterministic regardless of scan/attach order. Acceptance:
    `make v2-label-test` boots with the labeled disk attached FIRST and still mounts
    it at `/mnt/media` (not `/data`), the file written there survives reboot, and the
    volume UUID is non-zero and identical across reboot. D0–D3 + V1 stay green.
  - **V2b** (DONE, 2026-06-27): the declarative mount manifest `/data/.system/mounts`
    + the guardrails. After `/data` mounts, `vfsMountDataFs` reads the manifest (a
    datafs file, one `<label> <mountpoint>` line per volume); when present it is
    AUTHORITATIVE — each labeled disk mounts at the mountpoint its label maps to, and
    a disk whose label is unlisted is left unmounted. No manifest = the V2a default
    (auto-mount every labeled disk at `/mnt/<label>`). Guardrails: a manifest
    mountpoint must be `/mnt/<name>` (single, path-safe component — `/bin`, `/etc`,
    `..` are refused), the mountpoint dir must be empty (never overmount), and
    `datafsMount` only (re)formats a disk carrying the `SWDATAFS` magic (a non-blank
    unknown disk is never auto-formatted). Acceptance: `make v2-manifest-test` —
    3 boots prove auto-mount → manifest remap (`media` → `/mnt/store`, the file
    follows the disk, `/mnt/media` gone) → guardrail refusal (`media /etc/evil`
    refused, the disk left unmounted, `/etc` untouched). D0–D3 + V1 + V2a stay green.
  - **V2c** (DONE, 2026-06-27): anchor the root `/data` volume by UUID in the kernel
    cmdline (the single pinned identity). The FDT `/chosen/bootargs` parser (shared
    with K4's `recovery` flag) extracts `datafs.root=<32 hex>` into a kernel-wide
    anchor; `vfsMountDataFs` selects `/data` as the disk whose datafs UUID matches it
    (`datafsPeekUuid`), and on first boot formats the first blank UNLABELED disk as
    the root stamping the pinned UUID (`datafsMount(..., usePinned:)`) instead of a
    generated one. No pin => the V2a default (first unlabeled). Acceptance:
    `make v2-anchor-test` (needs `dtc` to bake the pin into a DTB) — two blank
    unlabeled disks; boot 1 (order A,B) formats the pinned root + writes an anchor
    file; boot 2 SWAPS the disk order and the pinned disk is still `/data` (same
    UUID, anchor file present), proving the anchor beats scan order. D0–D3 + V1 +
    V2a + V2b stay green.

  **V2 complete (V2a + V2b + V2c).** datafs volumes have a stable identity (UUID +
  label); `/data` and `/mnt/<label>` mounts are identity-driven and order-independent;
  a declarative `/data/.system/mounts` manifest controls mounting within `/mnt`
  guardrails; and the root is pinnable by a cmdline UUID. Next: **V3** (runtime
  capability-gated `mount()`/`unmount()`), then **V4** (real Hetzner Volume — the
  enumeration port only).
- **V3** (DONE, 2026-06-28): runtime `mount()` / `unmount()` syscalls, capability-gated
  (`capConsole`, held by `init`/the cell supervisor). `PERSIST` writes the entry
  through to the manifest; `unmount` of a busy mountpoint (open fd / cwd within)
  returns `EBUSY` via a per-mount refcount. Acceptance met across V3a–c: a userland
  program mounts a labeled volume, reads/writes it, persists across reboot, a busy
  unmount is refused, and an unprivileged caller is denied (`EACCES`).
  - **V3a** (DONE, 2026-06-28): `SYS_mount`/`SYS_unmount` (118/119), `capConsole`-gated
    like `device_claim`; runtime graft of an enumerated-but-unmounted SWDATAFS volume
    by label/UUID selector into a free datafs slot; subtree teardown + slot release on
    unmount; busy (open fd / cwd in the subtree) → `EBUSY`, computed on demand;
    RO/RW + `FORMAT_IF_BLANK` flags. `/bin/mountprobe` + `make v3-mount-test`. D0–D3 +
    V1 + V2a + V2b + V2c stay green. See `docs/NOTES.md` (V3a).
  - **V3b** (DONE, 2026-06-28): the `PERSIST` flag writes the `<label> /mnt/<name>` entry
    through to `/data/.system/mounts` (`persistMountEntry`, label-keyed + idempotent), so
    the V2b authoritative-manifest path re-mounts it on reboot. Needs a labeled volume.
    `/bin/mountprobe ... persist` + `make v3-persist-test`. See `docs/NOTES.md` (V3b).
  - **V3c** (DONE, 2026-06-28): the unprivileged-principal `EACCES` acceptance — both
    `mount` and `unmount` are `capConsole`-gated (the gate sits before any mount work,
    so a denied mount creates nothing), while a still-privileged caller mounts the same
    volume. `/bin/mountprobe denytest` (drops `capConsole` via `login`) + `make v3-deny-test`.
  - **V3 complete (V3a–V3c).** Runtime mount/unmount converges on the same
    `/data/.system/mounts` table the V2b boot path reads (PERSIST writes through);
    busy mounts are refused; the surface is capability-gated. Next: **V4** (real
    Hetzner Volume — the enumeration port only).
- **V4** (later, ties to H-series): a **real** Hetzner Volume — only the enumeration
  port (virtio-scsi / virtio-pci windows the H-series already drives), not the volume
  or mount abstraction, which is identical to V0–V3. Runtime hotplug (attach a Volume
  to a live VM) is deferred (QEMU `virt`/virtio-mmio has no clean hotplug; real Hetzner
  is virtio-pci).

Full design + per-stage findings to go in `docs/NOTES.md` (V-series) as work lands.

## LM-series — scaling inference toward a real LLM (IN PROGRESS, 2026-06-27)

The flagship profile is AI hosting. The I-series (I0–I8) proved CPU inference end to
end, but only on TinyStories (stories15M, a toy). The LM-series turns that proof into
a product: serve a real (~1B) LLM, fast. The hard parts are (1) performance — the
scalar engine is far too slow for a 1B model under emulation, and (2) model delivery —
a real model cannot live in the 46 MB signed base (H3 loads it into RAM), so it needs a
dedicated block device. Per-stage findings land in `docs/NOTES.md` (LM-series).

- **LM1** (DONE, 2026-06-27): NEON-vectorize both matmul hot paths (`Llama2.matmul`
  fp32 + `QLlama2.qmatmul` int8) via Swift `SIMD`. New `USER_SWIFT_FLAGS_NEON` build
  variant; `/bin/llm` + `/bin/llmd` use it. Q8 serving ~6–7 → ~21 tok/s (≈3×) in
  QEMU, output still matches the runq.c reference. LM1b found+fixed the one function
  whose `+neon` codegen miscompiled (`quantizeBuf`, pinned scalar via
  `@_optimize(none)`). Gates: `make test` runs `llm_run_test`, `llm_serve_test`,
  `simdprobe_test`. See `docs/NOTES.md` (LM1/LM1b).
- **LM2** (planned): multi-threaded matmul across the SMP cores (threads + futex from
  the S-series) — split the output-row loop across workers. Acceptance: same output,
  parallel speedup, per-CPU utilization visible in `top`.
- **LM3** (DONE, 2026-06-27): model delivery off a dedicated virtio-blk "model disk"
  (signed packed SWOSBASE image, mmap from there, not the base) + a larger-RAM
  inference QEMU profile. See `docs/NOTES.md` (LM3a/b/c).
- **LM4** (DONE, 2026-06-29): first real model — **TinyLlama-1.1B-Chat** (Llama2 arch,
  rope 10000, SentencePiece 32k, GQA) converted GQA-correct to the v2-Q8 format
  (LM4a), shipped as a signed packed model disk (LM4b), and served end to end in QEMU
  (LM4c): coherent factual output + tokens/sec. Required a kernel enabler, **LM4-MM**:
  the kernel ran in TTBR0 with userland linked at `0x8000_0000`, so RAM was usable only
  up to the 1 GiB identity map; a high-RAM window at VA 64 GiB + `frameVA` + PMM
  low/high zoning make RAM past 1 GiB usable for bulk user data pages (the model's
  weights) while page tables stay in identity-mapped low RAM. See `docs/NOTES.md`
  (LM4a/LM4b/LM4-MM/LM4c).
- **LM5** (planned): GGUF + Q4_K_M parser (smaller footprint, opens the GGUF
  ecosystem). **LM6** (planned): sampling (temp/top-p/top-k) + chat template.

## Phase 2 — toward a full hosting/embedded OS (record, don't build yet)

Once Phase 1 lands (real handles + IPC, basic SMP, at least one driver out of the kernel), the forward build-out makes swift-os a complete OS for its product profiles. Recorded here so Phase 1 decisions don't foreclose it; **not** to be implemented early:

- **Observability & metrics:** per-cell/per-process accounting, health states, request/latency/throughput metrics, memory-pressure and restart counters (see PHILOSOPHY.md "Observability" and the hosting metrics list in ARCHITECTURE.md).
- **Production A/B update channels and rollback:** build beyond the checked A/B validation paths toward immutable signed base/kernel images, update channels, key lifecycle, atomic switch, and automatic rollback on failed health checks. This is shared between the hosting and embedded profiles.
- **Application runtimes:** native Swift application runtime first, then Node.js and the JVM, on the threads + futex + `mmap`(W^X) + poll + TLS primitives the ABI already keeps open.
- **Embedded footprint profile:** a build/config profile that strips optional services, minimizes the static image, and tightens deterministic boot for single-purpose appliances.
- **Service-ization completion:** move the remaining drivers and the network stack into restartable userland services reachable only via capability-gated IPC.
- **Richer device/display support:** as needed for the (not-excluded) desktop profile — beyond the current basic framebuffer + virtio-input.

(End of plan document. Next step after review: pick the first concrete Phase 1 sub-milestone — most likely a C-arc piece or S0 — write its acceptance criteria, implement, test, commit, report.)

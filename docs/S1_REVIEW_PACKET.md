# S1 Review Packet

S0 is intentionally a parked-SMP foundation. This packet is the review handoff
for S1, not an approval to release secondary CPUs. Every item below is pending
review until a maintainer records the decision in `docs/NOTES.md` and updates
the roadmap if the plan changes.

## Current Evidence

- `docs/RISK_REMEDIATION_ROADMAP.md` defines the S0/S1 boundary and requires
  explicit review before the first secondary CPU executes kernel code.
- `docs/SMP_STATE_AUDIT.md` lists the mutable global state that remains
  primary-owned or unprotected before S1/S2.
- `tests/smp_release_guard_test.sh` proves the S0 kernel has no `hvc`/`smc`,
  no secondary-entry branch from `boot.S`, and no release writes to the parked
  secondary mailbox.
- `tests/smp_s1_preflight_test.sh` dumps fresh QEMU `virt` DTBs for `-smp 1`,
  `2`, `4`, and `8`, validating PSCI/topology/GIC/timer facts without calling
  CPU_ON.
- `tests/smp_boot_test.sh`, `tests/smp_headroom_test.sh`, and
  `tests/uefi_boot_test.sh` cover the parked-SMP path under direct `-kernel`
  and UEFI/disk boot.

## Decisions Required Before S1

### D1 - Uniprocessor Fast Path

Pending review. Choose either an always-SMP path for simplicity or a reviewed
compile-time/boot-time uniprocessor fast path. The choice must state which
barriers, per-CPU indirections, and locks can be elided on `-smp 1`.

### D2 - Secondary Release Mechanism

Pending review. Current QEMU `virt` evidence says PSCI `method = "hvc"` and
`cpu_on = <0xc4000003>`. The S0 mailbox remains a parked observation scaffold;
S1 must choose the actual release protocol before adding any `hvc`, `smc`, or
mailbox release writes.

### D3 - First SMP Support Limit

Pending review. S0 validates parked boot for `-smp 1`, `4`, and `8`, but S1 may
choose a smaller reviewed bring-up support limit such as `-smp 4`. The decision
must record the GICv2 assumptions and what happens to `-smp 8` before full S5.

### D4 - Secondary Stack Source

Pending review. Choose static per-CPU stacks or a PMM-backed allocation path.
The choice must respect the audit rule that secondaries cannot call allocator
or Swift heap code until the relevant shared state is protected.

### D5 - Timer And Online Marker Contract

Pending review. Define the stable `CPU N online` log/counter contract and the
minimal per-CPU timer proof. S1 acceptance must show every online CPU can take
and EOI its banked physical timer PPI without scheduling user work there yet.

### D6 - Shared-State Admission Control

Pending review. State which code secondaries may execute in S1 and which paths
stay CPU0-only until S2/S3/S4. At minimum, scheduler/process/futex/timer, PMM,
heap, VFS/handles, network/virtio, TTY, framebuffer, and logging must match the
current `docs/SMP_STATE_AUDIT.md` dispositions.

## Pre-S1 Gates

Run these before reviewing a branch that attempts S1:

```sh
make s0-test
make smp-release-guard
make smp-s1-preflight
make smp-s1-review-packet
make smp-uefi-test
```

An S1 branch must first delete or deliberately update any guard that forbids
its new behavior, and the commit doing so must reference the reviewed decision.

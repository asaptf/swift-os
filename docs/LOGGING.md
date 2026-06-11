<!-- SPDX-License-Identifier: Apache-2.0 -->

# SwiftOS Logging Reference

This reference describes the current SwiftOS kernel logging surface, what an
operator or developer can rely on today, and how the logging path is expected to
grow. It is the detailed companion to the operator-focused
[Observability Guide](OBSERVABILITY_GUIDE.md).

SwiftOS logging is still serial-first. The current system provides human-readable
UART log lines, a fixed in-memory kernel ring, a panic tail dump, runtime
filtering, compact structured payloads, and a boot-time serialization sample for
future export. It does not yet provide a persistent guest log store, `/dev/klog`,
remote log shipping, or a production log daemon.

Use this guide with:

- [Observability Guide](OBSERVABILITY_GUIDE.md) for day-to-day evidence
  collection.
- [Operations Guide](OPERATIONS_GUIDE.md) for boot profiles and serial capture.
- [Support Guide](SUPPORT_GUIDE.md) for support bundles and report templates.
- [Security Guide](SECURITY_GUIDE.md) for `capLogExport` and authority limits.
- [Performance And Sizing Guide](PERFORMANCE_GUIDE.md) for metrics and
  performance-reporting boundaries.
- [Risk Remediation Roadmap](RISK_REMEDIATION_ROADMAP.md) for future
  observability hardening.

## Current Contract

| Area | Current behavior | Evidence |
| --- | --- | --- |
| Live log sink | UART serial output through the current sink dispatch | `./tests/boot_test.sh` |
| Log format | `[tick] [level] source: message` plus optional detail in dumps | `./tests/boot_test.sh` |
| Ring buffer | Fixed 256-entry in-memory ring of accepted records | `kernel/log/log.swift` |
| Panic handling | `kpanic` records a panic entry and dumps a recent ring tail | panic path and boot assertions |
| Filtering | Global minimum level plus exact-source overrides | `./tests/boot_test.sh` |
| Structured detail | Optional `UInt64` detail payload | `detail=...` boot markers |
| Context | Ring records can carry `pid` and `principal` | `pid=... principal=...` dump/export lines |
| Export sample | Allocation-free key=value serializer for ring tail | `LOG-EXPORT-BEGIN` block |
| Capability hook | `capLogExport` is reserved for future export/sink authority | security docs and boot marker |

The live UART path remains the primary user-visible logging path. The ring and
serializer are current internal foundations, not stable external APIs.

## Choose Logging Evidence

Start from the question you need the log to answer. Capture host-side files
because SwiftOS does not persist guest logs across reboot.

| Question | Capture | Expected markers | Proof |
| --- | --- | --- | --- |
| Did logging initialize during boot? | `support/boot-test.txt` or `support/serial.log` | `L0 kernel logger active`, `log: recent` | `./tests/boot_test.sh` |
| Did filtering suppress the right records? | Boot test output | `level filtering active`, `source filtering active`, and absence of the forbidden filtered line | `./tests/boot_test.sh` |
| Did structured detail and context survive into the ring? | Ring-tail dump or export sample | `detail=...`, optional `pid=... principal=...` | `./tests/boot_test.sh` |
| Did export serialization run? | `LOG-EXPORT-BEGIN` block | `source=log_export msg="tail serialization ready"` | `./tests/boot_test.sh` |
| Did a service become ready or fail? | Serial log plus host client output | Service-prefixed readiness or first failure marker | Service-specific test |
| Did a panic include enough context? | `support/panic-context.txt` | First `panic` line plus preceding markers and ring tail | Reproducer command plus panic excerpt |
| Did a future log-export authority change stay constrained? | Security test output and boot markers | `sink capability hook active`; no seeded production export command | Security guide proof plus `./tests/boot_test.sh` |

## Capture Logs

For a direct QEMU boot:

```sh
mkdir -p support
make build base-image build/virt.dtb

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -kernel build/kernel.elf >support/serial.log 2>&1
```

For the standard boot log gate:

```sh
./tests/boot_test.sh >support/boot-test.txt 2>&1
```

There is no persistent guest log store. Capture serial output on the host when
the evidence matters.

## Live Log Lines

Live kernel log lines use a compact shape:

```text
[23] [I] sched: M4.5 sched: scheduler online
```

Fields:

| Field | Meaning |
| --- | --- |
| `[23]` | Monotonic kernel tick |
| `[I]` | Level: `D`, `I`, `W`, `E`, or `P` |
| `sched` | Stable source tag |
| message | Static event text |

The live UART renderer intentionally keeps context compact. The ring dump and
export formatter can include extra fields such as `detail=`, `pid=`, and
`principal=` when available.

## Levels

| Level | Letter | Meaning |
| --- | --- | --- |
| `debug` | `D` | Verbose diagnostic detail; filtered by default |
| `info` | `I` | Normal progress, boot milestones, service readiness |
| `warn` | `W` | Recoverable anomaly or degraded path |
| `error` | `E` | Operation failed but the system continues |
| `panic` | `P` | Fatal path; never filtered |

The default global minimum is `info`. Panic records bypass filtering.

## Source Tags

Every log record carries a small source tag. Current source tags include tags
such as:

```text
log
log_filter
log_export
platform
sched
timer
pmm
boot
disk
vfs
```

Use stable, low-cardinality tags. They are the primary keys for filtering and
for future remote correlation. Avoid embedding path names, addresses, package
names, prompts, user input, or other high-cardinality data in the source tag.
Put variable data in a numeric `detail` field or in a future structured field.

## Filtering

The logger supports:

- a global minimum level through `klogSetMinLevel` and `klogGetMinLevel`;
- exact-source overrides through `klogSetSourceMinLevel` and
  `klogClearSourceMinLevels`;
- shared filtering for live `klog` and ring-only `klogRing`.

The boot smoke path proves both global and per-source filtering:

```text
level filtering active (min INFO)
source filtering active
source override allows error
```

The same test forbids an intentionally filtered source line, so the gate proves
that suppressed records do not leak to serial output.

## Ring Buffer

`kernel/log/log.swift` stores accepted records in a fixed 256-entry ring. The
ring overwrites the oldest entries first. Records currently carry:

- monotonic tick;
- level;
- source tag;
- static message;
- optional `UInt64` detail;
- current process id when available;
- current principal when available.

`logDumpRecent(n)` renders recent entries to UART. During boot, the smoke path
prints a compact ring-tail marker:

```text
log: recent
detail=100
detail=4
```

Kernel-only entries omit default context. Entries recorded from EL0 context can
include:

```text
pid=1 principal=1
```

## Export Serialization Sample

SwiftOS has an internal serializer for recent ring entries:

```text
logFormatRecentTail(maxCount, into:capacity:)
```

It writes newline-separated key=value records into a caller-provided buffer
without allocation and without UART side effects. The boot smoke path prints a
small sample:

```text
LOG-EXPORT bytes=...
LOG-EXPORT-BEGIN
tick=23 level=I source=log_export msg="tail serialization ready"
LOG-EXPORT-END
```

Optional fields appear only when present:

```text
tick=23 level=I source=psinfo msg="process snapshot" detail=4 pid=1 principal=1
```

This is not a supported external wire protocol yet. Treat it as evidence that
the ring can already produce a stable machine-readable shape for a future
log-export service.

## Capability Boundary

`capLogExport` is reserved as the future authority for exporting the kernel log
ring or installing a non-UART log sink. It is not granted to the default service
authority today.

Current hook helpers:

```text
klogCanExportRing(capabilities:)
klogCanInstallSink(capabilities:)
```

Current boot evidence:

```text
sink indirection active
sink capability hook active
```

There is no target command today that reads the ring through this capability.
When that changes, update this reference, the security docs, and the relevant
acceptance tests in the same milestone.

## Panic Behavior

`kpanic` records the panic event, prints the fatal line, and dumps recent ring
context before halting. Panic logging must remain allocation-free and defensive.

For support handoff, include:

- the first `panic` line;
- nearby register lines such as `ESR_EL1`, `ELR_EL1`, `FAR_EL1`, or
  `SCTLR_EL1`;
- the preceding boot or service markers;
- the `log: recent` ring tail if present;
- the exact commit and QEMU command.

See [Observability Guide](OBSERVABILITY_GUIDE.md#panic-triage) for a complete
panic triage recipe.

## Kernel API

Current kernel-side helpers include:

```swift
klog(.info, "log", "L0 kernel logger active")
klog(.info, "timer", "tick rate (Hz)", 100)
klogRing(.info, "psinfo", "process snapshot", detail)
klogSetMinLevel(.warn)
klogSetSourceMinLevel("vfs", .debug)
klogClearSourceMinLevels()
logDumpRecent(5)
```

Use `StaticString` source tags and messages where possible. The emit path must
avoid heap allocation and remain safe in early boot and panic-adjacent paths.

## Current Acceptance Markers

`./tests/boot_test.sh` asserts the current logging foundation through these
markers:

```text
L0 kernel logger active
level filtering active (min INFO)
source filtering active
source override allows error
sink indirection active
sink capability hook active
log: recent
detail=100
detail=4
LOG-EXPORT bytes=
LOG-EXPORT-BEGIN
source=log_export msg="tail serialization ready"
LOG-EXPORT-END
```

Run:

```sh
make build
./tests/boot_test.sh
```

For broad release confidence, run:

```sh
make test
```

## Current Limits

- No persistent guest log store.
- No supported `/dev/klog`, sysctl, or target command for ring export.
- No remote log daemon or collector protocol.
- No production central log ingestion service.
- No per-cell log namespace yet.
- No high-cardinality metrics or histograms in the logger.
- Most historical milestone banners still use direct UART output.
- Service metrics remain service-specific.
- `capLogExport` is reserved but not a seeded operational capability.

These limits are current behavior, not design gaps to paper over. Consumer docs
should describe them directly.

## Roadmap

The implemented logging arc is:

| Milestone | State | Result |
| --- | --- | --- |
| L0 | Done | Kernel log facade and live UART line shape |
| L1 | Done | Fixed ring buffer and panic tail dump |
| L2 | Done | Global minimum-level filtering |
| L3 | Done | Structured numeric detail payload |
| L4a | Done | Ring context enrichment with pid and principal |
| L4b | Done | Exact-source filtering |
| L4c | Done | Allocation-free key=value ring serializer |
| L4d | Done | Log sink indirection and `capLogExport` hook |

Future work:

- user-visible ring export through an explicit authority path;
- supervised userland `logd` or equivalent collector;
- remote batch export over a verified transport;
- per-cell log namespaces;
- correlation ids for request and service flows;
- integration with future health checks and rollback decisions;
- richer metrics and tracepoints that share the same source discipline.

Logging work follows the repository milestone rule: build, boot, test, commit,
then review before the next slice.

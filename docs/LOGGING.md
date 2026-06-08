// SPDX-License-Identifier: Apache-2.0
# Logging and Observability (LOGGING.md)

This document records the state, goals, design, and incremental plan for kernel and system logging/observability in swift-os.

See also:
- `PHILOSOPHY.md` §Observability (the vision statement).
- `ARCHITECTURE.md` (Solaris-style tracepoints, counters, per-cell accounting; future driver services and cells).
- `docs/RISK_REMEDIATION_ROADMAP.md` (observability listed among the post-M13 gaps).
- `docs/NOTES.md` (milestone log; hardware; decisions — new logging work is recorded here too).

## Current State (L0-L4 Context Landed)

The current tree has the first logging foundation:

- `kernel/log/log.swift` defines `LogLevel`, `klog(level, source, message, detail)`, `klogInfo`, `logDumpRecent`, and `kpanic`.
- `klog` emits `[tick] [L] source: message` through the UART path, so the framebuffer mirror still works through `uartPutc`.
- A fixed 256-entry in-memory ring stores accepted `StaticString` records plus an optional `UInt64` detail payload and compact process/security context (`pid`, `principal`) captured at emit time.
- `logDumpRecent` renders nonzero structured payloads as `detail=...` and non-kernel context as `pid=... principal=...`; live UART lines stay text-only for now.
- `kpanic` records a panic entry and dumps the recent ring tail before halting.
- Global runtime filtering is present via `klogSetMinLevel` / `klogGetMinLevel`; default `.info` suppresses `.debug`, while `.panic` is never filtered.
- Per-source runtime filtering is present via `klogSetSourceMinLevel` / `klogClearSourceMinLevels`; an exact source override wins over the global minimum, while `.panic` is still never filtered.
- Early adoption has moved or mirrored a small set of core boot events onto `klog`: platform discovery (mirrored after timer init), scheduler online/context-switch markers, disk/base mount success, reclaim success, the Swift `ps` launch marker, and a process syscall event stored ring-only.
- `tests/boot_test.sh` asserts the L0 line, the L2/L4 filtering announcements, representative structured details, a userland context suffix, and the ring dump header; it also forbids the intentionally filtered per-source demo line.

Most legacy milestone/probe output is still emitted by direct UART calls:

- `kernel/main.swift` still owns most "M3: ...", "Mxx OK:", probe dumps, and demo banners.
- Driver, exception, VFS, and TTY paths still have many direct `uartPuts` call sites.
- The TTY layer (`kernel/tty/tty.swift`) remains userland console only; kernel logging does not flow through TTY.

Further L4+ candidate slices exist in external worktrees, but they are not authoritative until individually reviewed, rebased onto current `main`, verified, and committed.

## Goals

1. **Event recording from the very beginning of life.** The kernel and early userland must emit structured events so that "the OS only starting its life" does not mean "we have no idea what happened on a failed boot or a mysterious crash."
2. **Human + machine readable.** Serial console (and graphical mirror) must stay useful for developers. At the same time records must be easy to parse for tools and a future collector.
3. **Foundation for central log analysis (the AI use case).** A (not-yet-existing) central server will receive logs from many swift-os instances (dev, test, production AI appliances). An AI pipeline will:
   - cluster failures across boots/builds/cells;
   - correlate "symptom X within 300 ms of event Y" with source locations or model inputs;
   - suggest or automatically trigger rollbacks / targeted diagnostics.
   Therefore the format and the set of emitted events must be designed with remote ingestion and correlation in mind (principal/session/cell ids, monotonic time, request-ish correlation tokens, error codes, latency hints, etc.).
4. **Lightweight and predictable.** Value types, `StaticString` where possible, no heap traffic on the logging hot path, safe under IRQ-masked scheduler paths, tiny code size.
5. **Evolvable toward cells + restartable services.** Logging must not assume a single global context forever. Later records will carry (or be namespaced by) cell, principal, driver instance, etc.
6. **Testable.** Every increment has an executable check (boot assertion, host unit, or stress in `make test`).

Non-goals (early phases):
- Full dynamic tracing (DTrace-style) or arbitrary probe points.
- Backtraces attached to every log line.
- Persistent on-disk logs (tmpfs is the scratch tier; data loss on reboot is by design).
- High-cardinality metrics (counters and histograms come later, alongside accounting).

## Design Principles

- **One sink at a time, swappable in the future.** L0–L2 are UART + optional in-memory ring. Later a capability-gated log service (userland) can become the primary sink; the UART becomes a debug console only.
- **Structured records first, pretty text second.** The internal representation (or the wire format we eventually emit) must be machine-readable. Human formatting is a renderer on top.
- **Cheap timestamping.** Monotonic tick (`systemTicks`) is always available after M2. Wall time (`rtcNow()`) is best-effort (0 on boards without PL031). Records carry both when possible.
- **Source discipline.** Every log line carries a small, stable source tag (`StaticString` or a tiny enum). "vfs", "pmm", "sched", "virtio_blk", "user:42", etc. This is the primary key for filtering and for the AI correlator.
- **Level model** (minimal):
  - `debug` — verbose; usually compiled out or filtered at runtime in production images.
  - `info` — normal progress, boot milestones, service ready.
  - `warn` — recoverable anomaly, degraded path taken.
  - `error` — operation failed but system continues.
  - `panic` — fatal; will be followed by a register dump + ring tail and halt.
- **No allocation on the emit path.** Early boot (pre-heap, pre-PMM) and IRQ contexts must be able to log. Use `StaticString`, fixed buffers, or caller-provided scratch.
- **Panic paths are special.** A panic log path must not itself panic or allocate. It may bypass the normal logger and go straight to UART.
- **Future export shape (for the central server).** Records (or batches) should be serializable to a simple line-oriented format:
  - JSONL (human-inspectable, easy for Python/Go collectors), or
  - a tiny binary envelope (length-prefixed, little-endian, fixed header + UTF-8 msg) for lower bandwidth.
  Required fields (minimum for AI usefulness):
  - `ts_mono` (ticks or ns)
  - `ts_wall` (Unix seconds or 0)
  - `level`
  - `source`
  - `msg`
  - optional context: `pid`, `principal`, `session`, `cell`, `cpu`, `corr_id`, numeric details.
- **Integration with the capability / cell model.** A future `capLog` or `capLogExport` will control who can read the kernel ring or attach a log sink. Per-cell logs are a natural extension once cells exist.

## Phased Implementation Plan (L-series)

All L work follows the project rule: **one (sub)milestone at a time**. After each:
- code builds (`make build`)
- boots in QEMU (both classic and any `-smp` paths that exist at the time)
- meets a crisp acceptance criterion
- has an executable test (new or extended `boot_test`, a dedicated `tests/log_*_test.sh`, or host unit)
- is committed
- then **stop, report, wait for review** before the next L piece.

### L0 — Kernel log facade (DONE, 2026-06-08)

**Scope (keep tiny):**
- New module `kernel/log/log.swift` (pure Swift, no C bridge yet).
- `enum LogLevel: UInt8`
- `func klog(_ level: LogLevel, _ source: StaticString, _ message: StaticString)`
- Output format (example):
  ```
  [0000000042] [I] sched: scheduler online
  [0000000123] [W] pmm: free frames low (512)
  ```
  Early boot (ticks==0) may emit `[0000000000]` or omit the tick field; the exact spelling is part of the acceptance.
- Safe before timer, before heap, with IRQs masked.
- Still uses the UART driver underneath (so the fb mirror continues to work for free).
- **Do not rewrite existing boot banners in L0.** The hundreds of `uartPuts("M3 OK: ...")` strings stay exactly as they are so that `boot_test.sh` and all other tests are untouched. Add *new* log lines that exercise the facade (e.g. "L0 kernel logger active", a couple of info lines from platform or vfs, one warn in a probe if natural).
- One or two tiny helper shims if needed for numbers during the transition (`klogUInt` etc.) — or document the interleaving pattern.
- Acceptance:
  - `make build` succeeds.
  - `make run` (or the test QEMU invocation) shows at least one new `[..] [I] log: L0 ...` style line on the serial output.
  - The full existing `make test` suite (all 13+ suites) still passes with no EXPECT changes required.
  - A new line is added to the default EXPECTS in `tests/boot_test.sh` (or a tiny dedicated `log_test.sh`) that greps for the L0 demo line.
- Decision record: add a short "L0 — kernel log facade" entry in `docs/NOTES.md`.

**What L0 deliberately does NOT do:**
- Change any panic path.
- Introduce a ring buffer.
- Alter the format of any existing milestone message.
- Add runtime level filtering.
- Touch userland (except that userland continues to see the same UART behavior).

### L1 — Ring buffer + panic tail dump (DONE, 2026-06-08)

- Fixed-size ring (power-of-two, 256–1024 entries) of lightweight records or pre-formatted text.
- Overwrite policy (oldest first).
- On panic (and on explicit request) dump the most recent N lines to the UART **after** the panic banner but before the final halt. This gives a developer (and the future AI collector) the last events that led to the failure.
- Minimal read path: a privileged debug call or a special read-only vnode (`/dev/klog` or similar) that a future log daemon can open.
- Test: generate a burst of events, force a recoverable "error" path, capture the log, assert the ring tail is present and in order.
- Still no change to the legacy banner strings.

### L2 — Global filtering (DONE, 2026-06-08); categories and boot policy deferred

- Done in this slice: a global minimum level (`.info` by default), `klogSetMinLevel`, and a boot assertion that `.debug` is suppressed.
- Deferred follow-ups:
- Richer filtering policy beyond the L4b exact-source override table.
- `klogSetLevel(.warn)` etc. (or a single "consoleLogLevel" for the UART sink).
- Compile-time `DEBUG` vs release stripping of `.debug` (or a simple `#if`).
- Source taxonomy documented (vfs, mm, sched, timer, net, security, user, ...).

### L3 — Structured payload foundation (DONE, 2026-06-08); serialization deferred

- Done in this slice: `LogEntry` now carries `detail: UInt64` (`0` means none), `klog` accepts an optional trailing detail argument without breaking existing three-argument call sites, and ring dumps append `detail=...` for nonzero payloads.
- Added real post-heap example call sites for timer frequency, PMM free-frame counts, scheduler capacity, and several core boot/adoption markers.
- Deferred follow-ups:
- A pure function that can render a record to a caller buffer as JSONL line (host-testable).
- Prepare the schema expected by the future central collector in this file or a dedicated `docs/log-format.md`.
- No wire protocol yet.

### L4a — Ring context enrichment (DONE, 2026-06-08)

- `LogEntry` now carries the current `pid` and `principal` alongside `tick`, `level`, `source`, `message`, and `detail`.
- `klog` captures context through `processCurrentPid()` / `processCurrentPrincipal()` after filtering, so dropped records do no extra work and early/no-process paths use the kernel defaults (`pid=0`, `principal=1`).
- `logDumpRecent` prints context only when it is useful (`pid != 0` or `principal != 1`), keeping kernel-only boot lines compact.
- The live UART format is unchanged: `[tick] [L] source: message`.
- `klogRing` records accepted events without rendering a live UART line; `psinfo` uses it to populate the ring from real EL0 process context without perturbing foreground console stdout/prompt behavior.
- Boot acceptance checks both the old structured detail fields and the new context suffix.

### L4b — Per-Source Filtering (DONE, 2026-06-08)

- A tiny fixed table holds exact source-tag minimum-level overrides.
- `klogSetSourceMinLevel(source, level)` sets or replaces an override; `klogClearSourceMinLevels()` removes all source overrides.
- Filtering now uses per-source override first, then the global `minLogLevel`; `.panic` bypasses both.
- The same filtering path applies to live `klog` and ring-only `klogRing`, so suppressed records are absent from both UART and the ring.
- Boot acceptance proves a `.info` record from `log_filter` is suppressed while a `.error` record from the same source passes.

### L4c — Kernel Log Sink Indirection + Capability Hook

- The UART is no longer hard-coded inside `klog`. A `LogSink` protocol (or a tiny vtable because we avoid existentials on hot paths) with a current global sink.
- Default sink = UART renderer.
- Hook points for a future capability check when a userland service tries to install itself as the primary sink or to export the ring.
- This is the seam that lets us move logging toward the "restartable userland driver/service" model in the architecture docs.

### L5+ (after C-arc + basic net service model) — Remote export path

- A supervised userland `logd` (or integrated into an existing small daemon) that holds an explicit `capLogExport` handle.
- It drains the kernel ring (or receives pushed records via IPC), batches them, optionally adds local context, and ships over a TLS connection (or the future capability-gated net service) to the central collector.
- The collector side (out of scope for the OS) stores logs keyed by (build hash, boot id, principal/cell, time window) and feeds an analysis LLM / classifier.
- Kernel and critical services emit "liveness markers" at a steady low rate so that "missing expected healthy event" is itself a detectable signal.
- Panic logs are tagged with a "crash" envelope and uploaded with priority.

Longer term (recorded, not scheduled):
- Per-cell log namespaces.
- Correlation IDs propagated from user requests through the stack (especially useful for AI model serving cells).
- Integration with the future A/B health checks (a "bad" generation can be detected from its own log patterns before a human looks).
- Tracepoints (cheap, disabled by default) that can emit the same record shape.

## Usage Examples (kernel Swift)

```swift
import ... // whatever module boundary we choose

klog(.info, "log", "L0 kernel logger active")

klog(.info, "platform", "M9 OK: hardware discovered from device tree") // once we migrate

klog(.warn, "pmm", "free frames below threshold")

if rc != 0 {
    klog(.error, "virtio_blk", "sector read failed")
}
```

During L0–L2, for values that do not fit a single StaticString, the transitional pattern is acceptable:

```swift
klog(.info, "pmm", "free frames ")
uartPutUInt(UInt64(pmmFreeCount()))
uartPuts("\n")
```

Later the logger will absorb the formatting.

Panic paths may continue to use raw `uartPuts` (or a `kpanic` wrapper that is guaranteed not to re-enter the logger) until L1+.

## Open Decisions (record here when made)

- Exact tick formatting width and zero-padding (acceptance of L0 will lock a spelling).
- Whether the first ring implementation stores `StaticString` pointers (requires the strings to have program lifetime, which they do) or copies a truncated UTF-8 prefix into the ring entries.
- Name of the user-visible debug device (`/dev/klog`, a sysctl-like, or a handle-only API with no path).
- Default level for production vs. debug builds.

## Migration Notes

Existing `uartPuts("M...")` and panic dumps are left in place for L0. A later dedicated cleanup sub-milestone (after L1 or L2 is stable) can systematically replace the informational banners with `klog(.info, "boot", "...")` calls and update the corresponding EXPECT strings in the test scripts. Panics should stay extremely defensive.

This document is the living spec. Update it when a sub-milestone lands or a design decision is locked.

(End of LOGGING.md)

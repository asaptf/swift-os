// SPDX-License-Identifier: Apache-2.0
# Logging and Observability (LOGGING.md)

This document records the state, goals, design, and incremental plan for kernel and system logging/observability in swift-os.

See also:
- `PHILOSOPHY.md` §Observability (the vision statement).
- `ARCHITECTURE.md` (Solaris-style tracepoints, counters, per-cell accounting; future driver services and cells).
- `docs/RISK_REMEDIATION_ROADMAP.md` (observability listed among the post-M13 gaps).
- `docs/NOTES.md` (milestone log; hardware; decisions — new logging work is recorded here too).

## Current State (pre-L0)

As of the current tree (post-M13 + net bring-up), there is **no structured logging subsystem**.

- Kernel output is performed exclusively by ad-hoc calls to the UART driver:
  - `uartPuts(_: StaticString)`, `uartPutc`, `uartPutHex`, `uartPutUInt`.
  - Defined in `kernel/drivers/uart.swift`.
  - Also mirrored to a linear framebuffer (if present from UEFI GOP) via `fb_putc` inside `uartPutc`.
- These calls are scattered across:
  - `kernel/main.swift` (all the "M3: ...", "M4.5 ...", "Mxx OK:", "panic: ...", probe dumps, reclaim reports, etc.).
  - `kernel/arch/aarch64/platform.swift` (DTB discovery banners).
  - `kernel/sched/scheduler.swift`, `kernel/timer/generic_timer.swift` (one remaining sched online line; per-tick deliberately silenced).
  - Exception/IRQ paths (`exception_handler`, `sync_lower_el...`, unexpected IRQ).
  - TTY, VFS, drivers on panic paths.
- The TTY layer (`kernel/tty/tty.swift`) is **userland console** only: it provides canonical/raw line discipline, echo, and `read(0)`/`write(1/2)` for EL0 processes. Kernel code does **not** go through the TTY.
- Per-tick logging was explicitly turned off once the timer rate was raised to 100 Hz for preemption ("it spammed the console").
- No levels, no source tags, no timestamps on messages, no ring, no filtering, no export.
- Userland `printf` (newlib) and Swift `write(1,...)` ultimately reach the same UART via the VFS stdout path when fd 1/2 are open.
- "Observability" exists only as aspirational text in the architecture docs and as the boot-time milestone banners that double as a poor man's trace.

This was acceptable for bring-up (M0–M13). It is no longer sufficient once we want to debug real workloads, cells, driver services, or feed an AI bug-analysis backend.

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

### L0 — Kernel log facade (current target)

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

### L1 — Ring buffer + panic tail dump

- Fixed-size ring (power-of-two, 256–1024 entries) of lightweight records or pre-formatted text.
- Overwrite policy (oldest first).
- On panic (and on explicit request) dump the most recent N lines to the UART **after** the panic banner but before the final halt. This gives a developer (and the future AI collector) the last events that led to the failure.
- Minimal read path: a privileged debug call or a special read-only vnode (`/dev/klog` or similar) that a future log daemon can open.
- Test: generate a burst of events, force a recoverable "error" path, capture the log, assert the ring tail is present and in order.
- Still no change to the legacy banner strings.

### L2 — Filtering, categories, boot-time policy

- Global + per-source runtime level mask (a small table or bitmask).
- `klogSetLevel(.warn)` etc. (or a single "consoleLogLevel" for the UART sink).
- Compile-time `DEBUG` vs release stripping of `.debug` (or a simple `#if`).
- Source taxonomy documented (vfs, mm, sched, timer, net, security, user, ...).

### L3 — Structured payload + serialization skeleton

- Extend the record beyond (tick, level, source, msg) — add a small fixed "detail" union or a couple of numeric fields + a detail StaticString.
- A pure function that can render a record to a caller buffer as JSONL line (host-testable).
- Prepare the shape that the future central collector expects (document the schema in this file or a `docs/log-format.md`).
- No wire protocol yet.

### L4 — Kernel log sink indirection + capability hook

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

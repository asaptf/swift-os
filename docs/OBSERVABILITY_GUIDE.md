# SwiftOS Observability Guide

This guide explains how to observe a running SwiftOS image today: what signals
exist, where they appear, which tests prove them, and what evidence to collect
when something fails.

Use it with:

- [Operations Guide](OPERATIONS_GUIDE.md) for boot and test profiles.
- [Service Guide](SERVICE_GUIDE.md) for service readiness markers.
- [AI Hosting Guide](AI_HOSTING_GUIDE.md) for `/bin/llmd` health and metrics.
- [Performance And Sizing Guide](PERFORMANCE_GUIDE.md) for resource,
  throughput, sizing, and performance-reporting guidance.
- [Support Guide](SUPPORT_GUIDE.md) for report templates and handoff bundles.
- [Logging Reference](LOGGING.md) for kernel log lines, ring buffers, export
  samples, filtering, and log authority.

## Current Signal Model

SwiftOS is serial-first. The strongest current evidence is the QEMU serial log,
focused test output, and host client output for network services.

| Signal | Current source | How to read it | Proved by |
| --- | --- | --- | --- |
| Boot milestones | Kernel UART and `klog` lines | QEMU serial output | `./tests/boot_test.sh` |
| Structured kernel ring tail | `kernel/log/log.swift` | Ring dump in serial boot log | `./tests/boot_test.sh` |
| Log export serialization sample | `logFormatRecentTail` | `LOG-EXPORT-BEGIN` block in boot log | `./tests/boot_test.sh` |
| Process snapshot | `/bin/ps` | Guest command output | `tests/busybox_test.sh`, `tests/disk_exec_test.sh` |
| System/process statistics | `/bin/top` | Guest command output | `./tests/top_test.sh` |
| Service readiness | Service-prefixed serial markers | QEMU serial output | service-specific tests |
| HTTP service health | `/health` endpoints where available | Host `curl` | `./tests/llm_serve_test.sh` |
| Service request metrics | `/metrics` endpoints where available | Host `curl` | `./tests/llm_serve_test.sh` |
| Panic diagnostics | `panic` line plus register/log context | QEMU serial output | panic paths and boot assertions |

There is no persistent log store in the guest. `/tmp` is RAM scratch and is lost
on reboot. Capture logs on the host when the evidence matters.

## Operator Triage Order

When a SwiftOS run looks unhealthy, collect signals in this order before
changing the image or rerunning a different profile:

1. Prove the boot path reached the expected boundary: `./tests/boot_test.sh`,
   `make disk-run`, or the captured QEMU serial log.
2. Check the last boot health marker reached. If `swift-os login:` is absent,
   stay in the boot-health section below.
3. After login, record identity and authority:

   ```sh
   id
   ```

4. Record process and resource state:

   ```sh
   ps -f
   top -b -n 2 -d 1
   ```

5. For a service issue, require both a guest readiness marker and a host-visible
   check such as `curl`, a TCP echo, or `/health`.
6. For a panic or hang, keep the first fatal line, the previous boot/service
   markers, the QEMU command, and the exact commit.

This order avoids mixing unrelated evidence. A missing boot marker, a missing
capability bit, a stopped process, and a host-forwarding failure are different
classes of problem even when they all look like "the service is down" from the
outside.

## Capture Serial Output

For a manual direct boot:

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

Exit a `-nographic` QEMU session with `Ctrl-A X`.

For UEFI boot evidence:

```sh
make disk base-image
make disk-run >support/uefi-serial.log 2>&1
```

For automated acceptance evidence, prefer test output because it includes the
serial excerpt that caused a failure:

```sh
./tests/boot_test.sh >support/boot-test.txt 2>&1
```

## Boot Health Markers

These markers tell you how far the system got.

| Marker | Meaning |
| --- | --- |
| `[I] platform: M9 OK: hardware discovered from device tree` | Device tree platform discovery succeeded |
| `M11c: read-only base mounted from disk` | Packed base image was mounted from virtio-blk |
| `M11d: exec loaded from disk /bin/...` | User program loaded through VFS |
| `reclaim OK: no frame leak across fork/exec/exit/reap` | Process teardown reclaim self-test passed |
| `swift-os M12c: starting console-login (init)` | Login init was launched |
| `drvsvc: C5a supervisor starting` | C5a driver-service supervisor smoke started |
| `drvsvc: C5c device manifest matched` | Registry metadata matched the expected pseudo or virtio-input manifest |
| `drvsvc: C5c discovery exhausted` | Device discovery reported end-of-registry after the current input grant |
| `drvsvc: C5d virtio-input metadata discovered` | The focused metadata gate observed a discovered virtio-input MMIO transport |
| `drvsvc: C5b device grant moved` | Opaque device grant was moved out of the supervisor fd table |
| `drvinputd: C5b device grant accepted` | Driver service validated the transferred device grant |
| `C5a OK: restartable driver service recovered over IPC` | Driver service restarted and recovered over endpoint IPC |
| `C5b OK: opaque device handle transferred and released` | Device grant was transferred and reclaimed |
| `C5c OK: device discovery manifest matched pseudo input` | Headless fallback discovery, claim, transfer, and release completed |
| `C5c OK: virtio-input device grant discovered and matched` | Focused C5c gate matched a discovered virtio-input grant and completed handoff/reclaim |
| `C5d OK: virtio input discovery metadata surfaced` | Focused C5d gate surfaced virtio-input discovery metadata without MMIO authority |
| `C5e OK: device authority withheld until explicit handoff` | Focused C5e gate proved future MMIO/IRQ/DMA authority bits remain clear |
| `swift-os login:` | Console login prompt reached |
| `Welcome to swift-os, root` | Root login succeeded |
| `M12c: session ended` | Login session exited and init recovered |

The narrow boot gate is:

```sh
./tests/boot_test.sh
```

`boot_test.sh` also asserts that selected forbidden failure markers are absent,
such as handle-inheritance leaks and source-filtered log lines that should be
hidden.

## Kernel Log Lines

The current kernel logger emits human-readable UART lines and stores accepted
records in a fixed in-memory ring.

Live line shape:

```text
[23] [I] sched: M4.5 sched: scheduler online detail=4
```

Fields:

| Field | Meaning |
| --- | --- |
| `[23]` | Monotonic kernel tick |
| `[I]` | Log level: debug, info, warn, error, or panic |
| `sched` | Stable source tag |
| message | Static event text |
| `detail=4` | Optional numeric detail payload |

The live UART renderer is intentionally compact. Ring dumps may include extra
context such as `pid=` and `principal=` when the record came from user context.

Useful logger foundation markers:

| Marker | Meaning |
| --- | --- |
| `L0 kernel logger active` | Kernel log facade is online |
| `level filtering active (min INFO)` | Global minimum-level filtering is active |
| `source filtering active` | Per-source filtering is active |
| `source override allows error` | Source override table allowed an error record |
| `sink indirection active` | Live log sink dispatch is active |
| `sink capability hook active` | Future `capLogExport` hooks are compiled in |
| `log: recent` | Ring-tail dump was rendered |

Acceptance coverage: `./tests/boot_test.sh`.

## Log Export Sample

The current tree has an internal ring serializer, not a user-visible `/dev/klog`
or remote log daemon. During boot, the smoke path prints a sample block:

```text
LOG-EXPORT bytes=...
LOG-EXPORT-BEGIN
tick=23 level=I source=log_export msg="tail serialization ready"
LOG-EXPORT-END
```

This proves the ring can be formatted into stable key=value lines for a future
export path. Treat this as a diagnostic marker, not a supported external API.

`capLogExport` is reserved for the future export authority. No seeded account
uses it as a production workflow today.

## Process And System Inspection

Use `ps` for point-in-time process state:

```sh
ps
ps -f
ps aux
ps -o pid,ppid,state,cmd
```

Use `top` for CPU, process, and memory snapshots:

```sh
top -b -n 1
top -b -n 2 -d 1
```

The batch output includes an aggregate `Cpu:` busy/idle line and a `CPUs:` line
with the discovered CPU count plus per-CPU busy percentages. In SMP reports,
capture that line and the boot `SMP_CPUS` value together.

For S5f run-any placement reports, also keep the serial markers
`S5f OK: run-any placement policy completed` and either the multi-CPU coverage
or CPU0 fallback `klog` line. Those markers prove the gated placement path ran
before the normal userland login sequence.

Prefer batch mode in logs and support bundles. Interactive `top` repaints the
serial terminal and exits on `q`.

Acceptance coverage:

| Command | Test |
| --- | --- |
| `ps` | `tests/busybox_test.sh`, `tests/disk_exec_test.sh` |
| `top` | `./tests/top_test.sh`, `make smp-cpu-utilization-test` |
| S5f placement markers | `make s5-run-any-placement-test` |
| C5 driver-service/device-authority markers | `make c5-device-authority-test` |

## Service Signals

Long-running services print readiness markers only after they have bound their
socket and entered the serving path.

| Service | Ready marker | Health | Metrics |
| --- | --- | --- | --- |
| `/bin/httpd` | `httpd: listening on 8080` | Host `curl /` | Serial `httpd: 200 ...` / `httpd: 404 ...` |
| `/bin/llmd` | `llmd: serving on 8080` | `GET /health` | `GET /metrics` plus serial `llmd: served ...` |
| `/bin/tcpecho` | `tcpecho: listening on 5555` | One host TCP echo | Serial byte count |
| `/bin/udpecho` | `udpecho: listening on 5555` | One host UDP echo | Serial byte count and peer |
| `/bin/drvsvcdemo` | `C5a OK: restartable driver service recovered over IPC`; C5e gate also expects `C5e OK: device authority withheld until explicit handoff` | n/a | Serial supervisor markers |

For service operation and authoring rules, see
[Service Guide](SERVICE_GUIDE.md).

## LLM Serving Metrics

`/bin/llmd` exposes the richest current service metrics.

Host checks:

```sh
curl -fsS http://127.0.0.1:8080/health
curl -fsS -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
curl -fsS http://127.0.0.1:8080/metrics
```

Expected metric keys:

```text
requests 1
tokens_total 64
last_ttft_ms 80
last_tok_s 11
```

The exact numbers depend on host speed, QEMU TCG behavior, cold page faults,
and model state. Use them for relative comparisons inside the same host and
build setup.

The serial request line has the same shape:

```text
llmd: served 64 tokens ttft=80 ms rate=11 tok/s
```

Acceptance coverage: `./tests/llm_serve_test.sh`.

## Panic Triage

For panics, keep the first fatal line and the surrounding context. A useful
panic excerpt includes:

- the first `panic` line;
- any AArch64 register dump lines, such as `ESR_EL1`, `ELR_EL1`, `FAR_EL1`, or
  `SCTLR_EL1`;
- the preceding boot or service markers;
- the ring-tail dump if present;
- the exact QEMU command and commit.

Capture a wide context:

```sh
grep -n "panic" support/serial.log
start=120
end=280
sed -n "${start},${end}p" support/serial.log >support/panic-context.txt
```

Replace `start` and `end` with real line numbers, for example 80 lines before
and after the first panic.

## Evidence Recipes

### Boot Regression

```sh
mkdir -p support
git status --short --branch >support/git-status.txt
git log -1 --oneline >support/git-head.txt
make tools-check >support/tools-check.txt 2>&1
make build >support/build.txt 2>&1
./tests/boot_test.sh >support/boot-test.txt 2>&1
```

### Process Or Memory Question

Inside the guest:

```sh
ps -f
top -b -n 2 -d 1
```

Capture the QEMU serial log or copy the command transcript into the report.

### HTTP Service Question

```sh
./tests/httpd_test.sh >support/httpd-test.txt 2>&1
```

Manual host evidence:

```sh
curl -v http://127.0.0.1:8080/ >support/curl-httpd-root.txt 2>&1
curl -v http://127.0.0.1:8080/nope >support/curl-httpd-404.txt 2>&1
```

### AI Serving Question

```sh
./tests/llm_serve_test.sh >support/llm-serve-test.txt 2>&1
```

Manual host evidence:

```sh
curl -v http://127.0.0.1:8080/health >support/llmd-health.txt 2>&1
curl -v -X POST --data "Once upon a time" http://127.0.0.1:8080/completion >support/llmd-completion.txt 2>&1
curl -v http://127.0.0.1:8080/metrics >support/llmd-metrics.txt 2>&1
```

## Known Limits

- There is no persistent guest log store.
- There is no supported `/dev/klog`, sysctl, or target command to dump the log
  ring yet.
- There is no remote log service or collector protocol yet.
- Kernel log export is an internal serialized sample in the boot log.
- `capLogExport` is reserved but not a seeded operational capability.
- Most historical boot banners still use direct UART output, not structured
  `klog` records.
- Service metrics are service-specific. `llmd` has `/metrics`; `httpd` uses
  serial request lines today.
- There are no stable per-cell metrics yet; Cells are roadmap work.

When these limits change, update this guide, [LOGGING.md](LOGGING.md),
[OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md), and the related acceptance tests in
the same milestone.

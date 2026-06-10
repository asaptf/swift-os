# SwiftOS Performance And Sizing Guide

This guide explains how to reason about current SwiftOS performance, resource
usage, sizing, and benchmark evidence. It is written for operators, application
authors, package maintainers, and reviewers who need to distinguish supported
measurements from roadmap goals.

SwiftOS is still QEMU-first and serial-first. Many current performance numbers
are useful for regression detection and relative comparison, not for production
capacity promises. Treat QEMU TCG results, especially AI inference throughput,
as correctness and integration evidence unless a test explicitly defines a
performance guard.

Use this guide with:

- [Observability Guide](OBSERVABILITY_GUIDE.md) for available signals.
- [Testing Guide](TESTING_GUIDE.md) for validation gates and failure reading.
- [Networking Guide](NETWORKING_GUIDE.md) for network test profiles.
- [AI Hosting Guide](AI_HOSTING_GUIDE.md) for `/bin/llmd` health and metrics.
- [Service Guide](SERVICE_GUIDE.md) for service readiness and authoring.
- [Configuration Reference](CONFIGURATION_REFERENCE.md) for QEMU and build
  knobs.
- [Risk Remediation Roadmap](RISK_REMEDIATION_ROADMAP.md) for SMP and
  observability hardening.

## Current Performance Model

| Area | Current reality |
| --- | --- |
| Primary runtime | QEMU `virt` on AArch64 |
| Default memory | 256 MiB in documented QEMU profiles |
| CPU model | Single-core default; SMP hardening includes gated S5f run-any EL0 placement tests |
| User programs | Static EL0 binaries |
| Storage | Read-only packed base image plus RAM-backed `/tmp` |
| Networking | virtio-net with QEMU user networking in tests |
| AI inference | CPU TinyStories demos under QEMU |
| Persistent metrics store | Not implemented |
| Production capacity claims | Not established yet |

The most important rule: compare measurements within the same host, QEMU
version, build mode, memory size, CPU count, and boot profile. Do not compare a
QEMU TCG number from one laptop with a different host and call it a product
capacity limit.

## What You Can Measure Today

| Signal | How to read it | Useful for |
| --- | --- | --- |
| Boot markers | Serial log or `./tests/boot_test.sh` | Boot regressions and milestone health |
| Memory and CPU snapshot | `/bin/top -b -n 1` | Current process and system resource view |
| Process list | `/bin/ps` | Which programs are alive |
| HTTP readiness and status | Host `curl` plus serial log | Service availability |
| LLM health | `GET /health` | Bundle and model readiness |
| LLM request metrics | `GET /metrics` and serial `llmd: served ...` | Relative serving regression checks |
| Network throughput guard | `tests/net_zero_copy_throughput_test.sh` | Bounded HTTP burst regression guard |
| Full acceptance suite | `make test` | Broad functional regression evidence |

## What Not To Claim Yet

Current SwiftOS documentation should not claim:

- Production multi-core throughput.
- Real hardware performance outside documented QEMU and VirtualBox notes.
- Persistent storage write performance.
- Production TLS trust performance or certificate validation cost.
- Production LLM serving capacity.
- Stable API-level service-level objectives.
- A completed scheduler load-balancing policy.
- A finished per-cell resource accounting model.

Those are roadmap topics. Current docs may describe working demos, acceptance
criteria, and relative guardrails.

## Baseline Host Profile

Record the test environment before sharing results:

```sh
git log -1 --oneline
git status --short --branch
qemu-system-aarch64 --version
make tools-check
```

Also record:

- Host machine and CPU model if relevant.
- QEMU acceleration mode if known.
- Memory size passed to QEMU.
- `SMP_CPUS` value.
- Boot path: direct `-kernel`, UEFI disk, graphical smoke, or VirtualBox.
- Whether model, package, base image, or disk artifacts were rebuilt.
- The exact test or manual command.

Use [Support Guide](SUPPORT_GUIDE.md) when handing results to another person.

## Fast Smoke Versus Performance Guard

SwiftOS tests use two different ideas:

| Test kind | Meaning |
| --- | --- |
| Smoke test | Proves behavior is present and coherent |
| Guard test | Fails when a bounded performance-sensitive path regresses too far |

Examples:

| Command | Kind | Notes |
| --- | --- | --- |
| `./tests/boot_test.sh` | Smoke | Verifies required boot and userland markers |
| `./tests/httpd_test.sh` | Smoke | Verifies HTTP behavior and concurrency |
| `./tests/llm_serve_test.sh` | Smoke plus metrics | Verifies serving and exposes relative metrics |
| `bash ./tests/net_zero_copy_throughput_test.sh` | Guard | Bounded concurrent HTTP burst and network path marker |
| `make test` | Full regression suite | Functional confidence across many areas |

A smoke test passing does not establish a throughput target. A guard test
establishes only the bounded condition encoded in the test.

## Inspect CPU And Memory

Inside the guest, use batch mode for reproducible logs:

```sh
top -b -n 1
top -b -n 2 -d 1
```

`top` reads `SYS_SYSINFO` and `SYS_PROCSTAT` and reports:

- Uptime.
- Task count.
- Aggregate CPU busy/idle percentage.
- Discovered CPU count and per-CPU busy percentages.
- Total and free memory.
- Kernel image and heap footprint.
- Per-process state, principal, CPU time, and resident bytes.

Use `ps` for a simpler process list:

```sh
ps
ps -f
ps aux
```

Current limits:

- Process count is small and fixed by current kernel tables.
- There is no persistent historical metrics database.
- There is no per-cell view yet.
- S5 per-CPU utilization is an observability signal; it is not a completed
  load-balancing or capacity contract.
- CPU numbers under QEMU are relative indicators, not production capacity
  promises.

## Boot And Image Sizing

Useful artifact sizes:

```sh
ls -lh build/kernel.elf build/kernel.bin build/base.img build/swift-os.img
```

Use this after changes that affect:

- Kernel source.
- Userland programs staged into `/bin`.
- Base files under `base/`.
- Model bundles.
- Package payloads.
- UEFI loader or disk layout.

Relevant gates:

```sh
make build
make base-image
make disk
./tests/boot_test.sh
UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

If a change increases artifact size, explain why in the review or release note.
SwiftOS prioritizes small trusted core and lightweight static images.

## Memory Sizing

The common QEMU profiles use:

```text
-m 256M
```

This is enough for the checked-in boot, userland demos, networking tests,
package tests, and TinyStories demos. Larger future workloads such as Node.js,
JVM, database ports, and full Swift runtime support will need deliberate sizing
work.

When testing memory-sensitive changes:

1. Record QEMU memory size.
2. Capture `top -b -n 1`.
3. Run the focused workload.
4. Capture `top -b -n 1` again.
5. Run the focused acceptance test.
6. If the change touches shared memory management, run `make test`.

Useful checks:

```sh
./tests/mmap_test.sh
./tests/cow_test.sh
./tests/threads_test.sh
./tests/top_test.sh
```

## Network Performance

Current network performance evidence is QEMU slirp based. Use it for regression
detection and protocol-path confidence, not real NIC capacity claims.

Functional network checks:

```sh
./tests/virtio_net_test.sh
./tests/httpd_test.sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
./tests/tcp_connect_test.sh
./tests/dns_test.sh
./tests/tls_test.sh
```

Throughput guard:

```sh
bash ./tests/net_zero_copy_throughput_test.sh
```

That guard boots `/bin/httpd`, sends a bounded concurrent HTTP burst from the
host, verifies all responses, checks that the run completes within the script's
limit, and asserts the kernel reported the expected network zero-copy/batched
path marker.

Environment override:

```sh
NET_ZC_HOST_PORT=18082 bash ./tests/net_zero_copy_throughput_test.sh
```

When reporting network performance, include:

- Host QEMU version.
- Host port and guest port.
- Test script name.
- Number of requests and concurrency when relevant.
- Serial marker lines.
- Whether the result came from QEMU slirp or another backend.

## Service Performance

For simple services, use readiness markers first, then one or more host
requests.

HTTP server:

```sh
./tests/httpd_test.sh
```

LLM server:

```sh
./tests/llm_serve_test.sh
```

Manual LLM service metrics:

```sh
curl -fsS http://127.0.0.1:8080/health
curl -fsS -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
curl -fsS http://127.0.0.1:8080/metrics
```

Expected metric keys:

```text
requests
tokens_total
last_ttft_ms
last_tok_s
```

Use `last_ttft_ms` and `last_tok_s` for same-host regression comparisons. Do
not present them as hardware-independent service-level objectives.

## AI Inference Performance

The TinyStories demos prove:

- Native EL0 inference can run.
- Model data can live in the base image.
- Verified model-bundle generations can be selected and rejected.
- `/bin/llmd` can serve HTTP completions and expose metrics.

They do not prove production LLM throughput. Under QEMU TCG, inference is
expected to be slow.

Focused checks:

```sh
./tests/llm_run_test.sh
./tests/llm_serve_test.sh
```

When comparing LLM changes:

1. Use the same host and QEMU version.
2. Use the same model generation.
3. Warm up with one request if measuring steady-state behavior.
4. Record `/metrics`.
5. Keep the serial `llmd: served ...` line.
6. Confirm bundle verification still happens.

## SMP And CPU Count

The default product contract is still conservative around broad multi-core EL0
execution. SMP foundations and hardening work exist, several tests run with
`SMP_CPUS=4`, and S5f proves a gated run-any EL0 placement policy, but
performance claims should still reflect the active roadmap state.

Useful gates:

```sh
SMP_CPUS=4 ./tests/smp_boot_test.sh
SMP_CPUS=4 UEFI_BOOT=disk ./tests/uefi_boot_test.sh
make s1-test
make s5-run-any-placement-test
```

When recording CPU-count-sensitive results:

- Include `SMP_CPUS`.
- Include whether direct or UEFI boot was used.
- Include boot markers for CPU discovery and online state.
- Avoid claiming production load balancing or throughput scaling. S5f proves
  placement coverage in a gated acceptance path, not a complete CPU policy.

## Package And Image Footprint

Packages let you test optional software without permanently growing the base
image.

Useful commands:

```sh
make package-fixture
make package-overlay-test
make package-store-test
make package-local-install-test
```

Record:

- `.swpkg` size.
- Payload image size.
- Package store image size.
- Installed paths.
- Guest command used for proof.
- Whether base image size changed.

Use packages for optional tools when they do not need to be boot-critical.

## Suggested Measurement Recipes

### Boot Smoke With Artifact Sizes

```sh
make build base-image build/virt.dtb
ls -lh build/kernel.elf build/kernel.bin build/base.img
./tests/boot_test.sh
```

### Resource Snapshot Around A Command

Inside the guest:

```sh
top -b -n 1
/bin/llm
top -b -n 1
```

For automated LLM evidence, prefer:

```sh
./tests/llm_run_test.sh
```

### HTTP Service Regression Check

```sh
./tests/httpd_test.sh
bash ./tests/net_zero_copy_throughput_test.sh
```

### LLM Serving Regression Check

```sh
./tests/llm_serve_test.sh
```

For a manual run with metrics, boot the network profile, start `/bin/llmd`, and
run:

```sh
curl -fsS http://127.0.0.1:8080/metrics
```

## Reporting Template

When reporting a performance observation, include:

```text
Revision:
Host:
QEMU version:
Boot path:
QEMU memory:
SMP_CPUS:
Artifact sizes:
Command or test:
Result:
Serial markers:
Comparison baseline:
Notes:
```

Example:

```text
Revision: 68b140f docs: add SwiftOS concepts guide
Boot path: direct -kernel
QEMU memory: 256M
SMP_CPUS: 1
Command or test: bash ./tests/net_zero_copy_throughput_test.sh
Result: PASS, 32 HTTP requests completed inside guard limit
Serial markers: net-zc OK: ...
Comparison baseline: previous local main on same host
```

## Performance Review Checklist

Before merging a performance-sensitive change:

1. State what resource or latency path should improve or stay bounded.
2. Run the focused functional test.
3. Run the relevant performance guard if one exists.
4. Capture `top -b -n 1` when memory or CPU behavior matters.
5. Record artifact sizes when image footprint changes.
6. Run `make test` for shared kernel, VFS, networking, scheduler, package, or
   ABI changes.
7. Update docs if the user-visible expectation changes.

## Roadmap Boundaries

Future performance work includes:

- Production SMP load balancing and CPU policy.
- Per-cell and per-service resource accounting.
- Persistent metrics export.
- Stronger service supervisor health and restart metrics.
- Real hardware performance profiles.
- Production package repository and update metrics.
- Larger runtime targets such as native Swift apps, Node.js, and the JVM.

Until those land, keep performance claims precise: name the artifact, test,
host, QEMU profile, and evidence.

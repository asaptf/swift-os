# SwiftOS Testing Guide

This guide explains how to validate a SwiftOS build, choose the right focused
test, interpret QEMU acceptance failures, and add new tests for user-visible
behavior. It is written for operators, application authors, package maintainers,
and kernel contributors who need repeatable evidence before promoting a change.

SwiftOS treats tests as part of the product contract. A documented workflow
should either be a normal manual operation or have a nearby executable check
that proves the same path.

Use this guide with:

- [Getting Started](GETTING_STARTED.md) for the first build and boot.
- [Installation Guide](INSTALLATION_GUIDE.md) for direct, UEFI, graphical, and
  VirtualBox boot profiles.
- [Operations Guide](OPERATIONS_GUIDE.md) for runbooks and operational evidence.
- [Performance And Sizing Guide](PERFORMANCE_GUIDE.md) for throughput guards,
  service metrics, and sizing evidence.
- [Support Guide](SUPPORT_GUIDE.md) for collecting logs and failure reports.
- [Developer Guide](DEVELOPER_GUIDE.md) for building user programs.
- [Porting Guide](PORTING_GUIDE.md) for validation expectations when bringing
  source-built software to SwiftOS.

## Test Model

SwiftOS uses three test shapes:

| Test shape | What it proves | Example |
| --- | --- | --- |
| Host unit test | Pure algorithms, parsers, formats, and low-level libraries | `tests/net_test.swift` |
| Static guard | Source-level invariants and milestone contracts | `tests/smp_release_guard_test.sh` |
| QEMU acceptance test | Boot, userland, VFS, networking, packages, services, and devices | `tests/boot_test.sh` |

The full gate is:

```sh
make test
```

It builds the kernel and key artifacts, runs host-side Swift tests, boots QEMU
through direct and UEFI paths, exercises networking and package flows, and runs
the current user-visible command and service checks.
It also runs a full-gate coverage guard so memory/resource, hardware/SMP,
security/isolation, network, package, update/rollback, C5, and UEFI coverage
cannot silently fall out of the shipped gate.

## Choose A Test Scope

Use the narrowest scope that proves the change, then broaden when the change
touches shared behavior or a release candidate.

| Change | First gate | Broaden when |
| --- | --- | --- |
| Documentation only | `git diff --check`, `make docs-test` | Links, commands, or examples depend on changed code |
| Host-only parser, manifest, or crypto logic | Host Swift unit test for that file | The logic feeds a booting user-visible path |
| Kernel or userland build rule | `make build` | The artifact is staged into `build/base.img` or booted |
| Base-image contents or accounts | `make base-image`, then the focused VFS/login test | A release candidate or shared boot path is affected |
| One guest command | Command-specific QEMU test | Shell, VFS, process, or capability behavior changes broadly |
| Network service or client | Service-specific network test, such as `make sshd-supervision-test` for SSHD restart behavior | Shared socket, virtio-net, DNS, TLS, or polling behavior changes |
| Package or ports workflow | Matching package/ports make target | Repository metadata, package-store activation, or seed catalog changes |
| Update-store or kernel-slot workflow | Matching `ab_*` or `uefi_k*` test | Boot selection, rollback, or release-candidate policy changes |
| Security boundary | Focused capability, handle, mmap, package, or C5 test | The boundary touches syscall, VFS, process, or driver-service internals |
| Release candidate | `make test` plus the deployment validation matrix | Always |

## Quick Start

For a clean local confidence pass:

```sh
make build
make base-image
./tests/boot_test.sh
```

Before handing a broad change to another person:

```sh
make test
```

For documentation-only changes, use:

```sh
git diff --check
make docs-test
```

Run the focused build or QEMU test too when a documentation change describes a
new or changed executable workflow.

## Required Host Tools

The normal test suite expects:

| Tool | Used for |
| --- | --- |
| Embedded Swift toolchain | Kernel and native userland build |
| `clang`, `lld`, `llvm-objcopy` | Freestanding objects and ELF image |
| `qemu-system-aarch64` | Direct, UEFI, network, framebuffer, and package tests |
| AAVMF firmware | UEFI disk boot tests |
| `curl` | HTTP and service tests |
| Host Swift compiler | Host Swift unit tests |

Check tool paths with:

```sh
make tools-check
```

## Artifact Prerequisites

Most focused tests assume the relevant build artifacts already exist. The common
targets are:

| Artifact | Build command |
| --- | --- |
| Kernel | `make build` |
| Base image | `make base-image` |
| Direct boot DTB | `make build/virt.dtb` |
| UEFI disk image | `make disk` |
| Package payload fixture | `make package-fixture` |
| Package store fixture | `make package-store-fixture` |
| Local package install fixture | `make package-local-install-fixture` |
| Lua/ports package install fixture | `make package-lua-install-fixture` |
| Model files | `make model` or `make base-image` |

The full `make test` target builds the prerequisites it owns. When running a
single script directly, build the narrow prerequisite first if the script does
not do it for you.

For documentation-only changes, start with:

```sh
make docs-test
```

This checks the public Markdown set (`README.md`, `docs/*.md`, and
`ports/README.md`) for balanced fenced code blocks, local links and Markdown
anchors that resolve inside the repository, syscall table sync between
`docs/API_REFERENCE.md` and `userland/lib/syscall.h`, Swift bridge coverage
between `docs/API_REFERENCE.md` and `userland/lib/swift_user.h`, coverage of
every `docs/*.md` file from the public documentation map, and command-reference
entries for every program staged into the base image's `/bin`. It also checks
that every executable host Swift tool built from `tools/*.swift` is covered by
[HOST_TOOL_REFERENCE.md](HOST_TOOL_REFERENCE.md), and that every checked
`ports/*/*/Port.json` recipe is visible from the ports/package reference docs.

## Full Gate

Run the full gate when:

- A change touches shared kernel behavior.
- A public ABI or header changes.
- A userland command or shell behavior changes broadly.
- Networking, VFS, packages, login, mmap, threads, or process behavior changes.
- A release candidate is being promoted.

Command:

```sh
make test
```

Current full-gate coverage includes:

- Documentation fence, local-link/anchor, API table, Swift bridge,
  documentation map, command reference, host tool reference, and port recipe
  reference integrity.
- Host tests for page allocation, base image format, packages, package store,
  FDT parsing, networking stack, crypto, handles, TLS primitives, LLM engine,
  model bundles, package header integrity, and Ed25519.
- Static SMP guards for mailbox layout, release contracts, state audit, and
  preflight checks.
- Direct QEMU boot and userland smoke.
- SMP boot smoke with `SMP_CPUS=4`.
- UEFI disk boot in single-core and SMP profiles.
- Virtio block and virtio net.
- IPv4, IPv6, UDP, TCP, DNS, TLS, HTTP, and zero-copy throughput guard paths.
- SSHD/static-IPv6 Hetzner deploy evidence bundle generation.
- VFS, disk exec, console login, capability enforcement, redirection, core
  commands, busybox shell, `vi`, `top`, threads, mmap, packages, and LLM
  serving.
- C5 driver-service/device-authority readiness, including restartable
  supervision, device grant transfer, discovery metadata, authority
  withholding, metadata-only rights, and guest denial before grant minting.
- Framebuffer/input smoke.
- Full-gate coverage guard for the required stability, hardware, security,
  update, package, network, C5, and SMP categories.

If `make test` fails, keep the first failing command and its log. Do not keep
rerunning the whole suite before understanding the first failure.

## Focused Test Matrix

Run the narrowest test that proves the path you changed.

| Changed area | First test |
| --- | --- |
| Documentation links/anchors, examples, API tables, Swift bridge coverage, map coverage, command references, host tool references, or port recipe references | `make docs-test` |
| Full-gate stability coverage wiring | `make stability-coverage-test` |
| QEMU `virt` hardware map drift | `make qemu-virt-hardware-map-test` |
| Kernel build only | `make build` |
| Base image format or contents | `make base-image`, `./tests/vfs_disk_test.sh` |
| Direct serial boot | `./tests/boot_test.sh` |
| UEFI boot or disk image | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| Graphical framebuffer/input | `./tests/fb_vi_test.sh` |
| Console login or identity store | `./tests/console_login_test.sh` |
| Capability enforcement | `./tests/cap_enforce_test.sh` |
| File operations and tmpfs | `./tests/swift_fileops_test.sh` |
| Core commands | `./tests/swift_coreutils_test.sh` |
| Process list or resource display | `./tests/top_test.sh` |
| Pipes and redirection | `./tests/redirect_test.sh` |
| Threads and futexes | `./tests/threads_test.sh` |
| mmap, mprotect, W^X | `./tests/mmap_test.sh` |
| `.swpkg` header integrity | `make swpkg-header-integrity-test` |
| Package payload overlay | `make package-overlay-test` |
| Package store activation | `make package-store-test` |
| Local package install flow | `make package-local-install-test` |
| Base-image A/B update store | `./tests/ab_stage_test.sh` |
| Base-image A/B rollback | `./tests/ab_rollback_test.sh` |
| Base-image A/B durability | `./tests/ab_flush_test.sh` |
| Kernel-image A/B ESP slots | `./tests/uefi_kernel_ab_test.sh` |
| Kernel-image runtime staging | `./tests/uefi_kstage_test.sh` |
| Kernel-image runtime activation | `./tests/uefi_kactivate_test.sh` |
| Kernel-image boot-attempt counter | `./tests/uefi_kattempt_test.sh` |
| Kernel-image health confirmation | `./tests/uefi_kconfirm_test.sh` |
| Kernel-image attempt rollback | `./tests/uefi_krollback_test.sh` |
| HTTP server | `./tests/httpd_test.sh` |
| TCP echo | `./tests/tcp_echo_test.sh` |
| TCP client connect | `./tests/tcp_connect_test.sh` |
| UDP echo | `./tests/udp_echo_test.sh` |
| DNS resolver | `./tests/dns_test.sh` |
| TLS client smoke path | `./tests/tls_test.sh` |
| IPv6 smoke | `./tests/ipv6_smoke_test.sh` |
| Hetzner SSHD/static-IPv6 deploy handoff | `make hetzner-deploy-bundle-test` |
| LLM local inference | `./tests/llm_run_test.sh` |
| LLM HTTP serving | `./tests/llm_serve_test.sh` |
| Busybox shell compatibility | `./tests/busybox_test.sh` |
| `vi` serial path | `./tests/vi_test.sh` |
| Restartable driver-service smoke | `make c5-driver-service-test` |
| Opaque device-handle handoff | `make c5-device-handle-test` |
| Virtio-input discovery metadata | `make c5-device-metadata-test` |
| Device authority envelope | `make c5-device-authority-test` |
| Metadata-only device grant rights | `make c5-device-rights-test` |
| Device discovery/claim capability gate | `make device-authority-cap-test` |
| C5 aggregate driver-service readiness | `make c5-test` |
| Phase 1 roadmap/test alignment | `make phase1-roadmap-test` |
| SMP readiness | `make s1-test`, `make s5-test`, or the active milestone target |

When a focused test passes but the full gate fails, the failure is probably in a
neighboring subsystem or in integration ordering. Keep both results.

## Host Unit Tests

Host unit tests compile Swift code with the host Swift compiler and run without
booting QEMU. Use them for deterministic logic that does not require hardware or
kernel state.

Examples:

```sh
/usr/bin/swiftc tests/base_image_test.swift -o build/base_image_test
build/base_image_test build/base.img
```

```sh
/usr/bin/swiftc tests/llm_bundle_test.swift \
  userland/lib/modelbundle.swift kernel/crypto/sha256.swift \
  -o build/llm_bundle_test
build/llm_bundle_test
```

Good host-test candidates:

- Parsers.
- Manifest and package validation.
- Protocol state machines.
- Cryptographic test vectors.
- Pure filesystem image format checks.
- Compatibility mapping tables.

Do not use a host unit test as the only proof for behavior that depends on EL0,
the syscall boundary, QEMU devices, process isolation, or capability checks.

## QEMU Acceptance Tests

QEMU tests boot the real kernel and assert serial markers or host-visible
network behavior. They are the strongest proof for user-visible OS behavior.

Typical script pattern:

1. Verify required artifacts.
2. Start `qemu-system-aarch64`.
3. Capture serial output to a temp log.
4. Drive the TTY smoke prompt and console login when needed.
5. Run a guest command or service.
6. Use host tools such as `curl`.
7. Assert serial markers and host outputs.
8. Stop QEMU and print useful failure context.

Run one directly:

```sh
./tests/httpd_test.sh
```

Most tests choose a temporary host port to avoid conflicts. Some support
environment overrides, for example:

```sh
HTTPD_HOST_PORT=18080 ./tests/httpd_test.sh
LLMD_HOST_PORT=18081 ./tests/llm_serve_test.sh
```

If a test times out on a busy host, rerun the same focused test once. If it
fails again, treat it as a real failure and keep the serial log.

## Network Tests

Network tests use QEMU user networking and host forwarding. They require a
virtio-net device and a guest principal with `capNet`.

Common checks:

```sh
./tests/virtio_net_test.sh
./tests/httpd_test.sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
./tests/tcp_connect_test.sh
./tests/dns_test.sh
./tests/tls_test.sh
./tests/ipv6_smoke_test.sh
```

Notes:

- `/bin/httpd` and `/bin/llmd` both bind guest TCP 8080; run one service at a
  time.
- Darwin/QEMU host-forwarding behavior can limit some IPv6 end-to-end tests.
  The host `net_test` covers protocol logic more aggressively.
- TLS support is a smoke path; certificate trust policy is not production-ready.

Use [Networking Guide](NETWORKING_GUIDE.md) for the complete runbook.

## Package Tests

Package tests cover three current paths:

| Path | Command |
| --- | --- |
| Read-only package payload overlay | `make package-overlay-test` |
| Package-store boot activation | `make package-store-test` |
| Local package install flow | `make package-local-install-test` |

Useful direct scripts:

```sh
./tests/package_overlay_test.sh
./tests/pkg_store_boot_test.sh
./tests/pkg_local_install_test.sh
```

When a package test fails, keep the `.swpkg` path, the payload or store image
path, the QEMU command or make target, the guest command output, and the serial
log around package discovery and activation.

Use [Package Guide](PACKAGE_GUIDE.md) for package workflows.

## Update And Rollback Tests

Update tests cover the checked base-image A/B store and UEFI ESP kernel-slot
flows. They are operator-facing acceptance tests: they boot QEMU, drive the
guest command path where needed, and assert stable serial evidence.

Base-image A/B store:

```sh
./tests/ab_update_test.sh
./tests/ab_stage_test.sh
./tests/ab_activate_test.sh
./tests/ab_confirm_test.sh
./tests/ab_rollback_test.sh
./tests/ab_flush_test.sh
```

Kernel-image A/B through the UEFI ESP:

```sh
./tests/uefi_kernel_ab_test.sh
./tests/uefi_kstage_test.sh
./tests/uefi_kactivate_test.sh
./tests/uefi_kattempt_test.sh
./tests/uefi_kconfirm_test.sh
./tests/uefi_krollback_test.sh
```

Keep the store image, payload image, UEFI disk image, serial log, and the exact
guest update command transcript when one of these tests fails. Use
[Update And Rollback Guide](UPDATE_GUIDE.md) for operator steps and
[Update Store](UPDATE_STORE.md) for slot state and trust boundaries.

## AI And Model Tests

AI tests cover local inference, verified bundle parsing, and HTTP serving.

Focused commands:

```sh
./tests/llm_run_test.sh
./tests/llm_serve_test.sh
```

Host bundle check:

```sh
/usr/bin/swiftc tests/llm_bundle_test.swift \
  userland/lib/modelbundle.swift kernel/crypto/sha256.swift \
  -o build/llm_bundle_test
build/llm_bundle_test
```

Expected serving evidence includes:

```text
llmd: generation 2 rejected (model size/sha256 mismatch)
llmd: bundle stories15M generation 1 verified (ed25519+sha256)
llmd: serving on 8080
llmd: served
```

The corrupt generation 2 in the checked-in image is intentional. It proves that
the server rejects a bad newest generation and falls back to the newest verified
one.

## SMP Tests

SMP work uses dedicated targets because it touches boot, CPU discovery,
mailboxes, release contracts, scheduler assumptions, and future concurrency
behavior.

Common commands:

```sh
make smp-state-audit
make smp-mailbox-layout
make smp-release-guard
make smp-release-contract
make smp-s1-preflight
make smp-test
make smp-headroom-test
make smp-uefi-test
make s4-resource-stress-test
make el0-fault-backtrace-test
make qemu-virt-hardware-map-test
make smp-cpu-utilization-test
make s5-scheduler-placement-test
make s5-placement-stress-test
make s5-el0-fanout-test
make s5-thread-fanout-test
make s5-run-any-placement-test
make s5-test
make s0c-test
make s1-test
make c5-driver-service-test
make c5-device-handle-test
make c5-device-metadata-test
make c5-device-authority-test
make c5-device-rights-test
make c5-test
make swpkg-header-integrity-test
```

Use the active roadmap milestone to choose the exact target. `smp-release-contract`
is the review-facing alias for `smp-release-guard`; `s0c-test` is the narrow
state-audit target. For broad SMP readiness, `make s1-test` covers the S0/S1
foundation gates and `make s5-test` is the aggregate S5 runtime readiness gate.
For broad C5 driver-service/device-authority readiness, use `make c5-test`.

## Reading Failures

Start with the first failing line. Most scripts print a `FAIL:` line and a tail
of the serial log.

Useful questions:

1. Did the artifact exist before QEMU started?
2. Did the kernel reach the expected boot marker?
3. Did the TTY smoke prompt complete?
4. Did `swift-os login:` appear?
5. Did the shell start?
6. Did the guest command print its readiness marker?
7. Did the host client reach the forwarded port?
8. Did the test assert the wrong marker after a legitimate output change?

Keep these outputs:

```sh
git log -1 --oneline
git status --short --branch
make build
./tests/boot_test.sh
```

For network or service failures, also keep the focused test log from the failing
script.

## Adding A Test

Add a host unit test when the behavior is pure logic. Add a QEMU acceptance test
when the behavior crosses the kernel boundary or is user-visible in the guest.

### Host Test Checklist

1. Place the test under `tests/`.
2. Compile it with the same sources used by production code.
3. Make failures print a clear message.
4. Add it to `make test` if the behavior is part of the shipped contract.
5. Document the proof in the relevant guide.

### QEMU Test Checklist

1. Use `#!/usr/bin/env bash` and `set -u`.
2. Resolve `ROOT` from the script directory.
3. Check required artifacts and print how to build missing ones.
4. Use temp files for serial logs and clean them in `trap`.
5. Start QEMU with the minimum devices required.
6. Drive login only when the tested path needs a shell.
7. Assert stable markers, not incidental formatting.
8. On failure, print the serial tail.
9. Kill QEMU reliably.
10. Add the script to `make test` when it is stable and product-relevant.

Good serial markers are short, stable, and tied to user-visible behavior:

```text
httpd: listening on 8080
pkghello: hello from package overlay
M12a OK: identity demo exited, code 0
```

Avoid markers that depend on temporary debug text, memory addresses, or timing.

## Documentation Expectations

When a test proves a documented workflow, keep the document and test aligned.

| If you change | Update |
| --- | --- |
| Command syntax | `COMMAND_REFERENCE.md` and the command test |
| Boot profile | `INSTALLATION_GUIDE.md`, `OPERATIONS_GUIDE.md`, and boot tests |
| Network behavior | `NETWORKING_GUIDE.md` and network tests |
| Service behavior | `SERVICE_GUIDE.md` and service tests |
| Package behavior | `PACKAGE_GUIDE.md` and package tests |
| API behavior | `API_REFERENCE.md`, headers, and ABI tests |
| Admin workflow | `ADMINISTRATION_GUIDE.md` and login/capability tests |
| Porting support | `PORTING_GUIDE.md` and the port-specific proof |

Do not merge a public behavior change with only a stale or unrelated test.

## Test Hygiene

- Keep focused tests focused.
- Prefer deterministic markers over sleeps.
- Use environment variables for host ports and timeouts when a test may need
  local adjustment.
- Keep generated artifacts under `build/` or temp directories.
- Avoid relying on host-global state.
- Print enough context for support handoff.
- Keep docs in English and link each public workflow to the proof that covers
  it.

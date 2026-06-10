# SwiftOS Support Guide

This guide describes how to collect evidence, classify a problem, and report a
SwiftOS issue in a way that another maintainer or operator can reproduce. It is
the support companion to [TROUBLESHOOTING.md](TROUBLESHOOTING.md) and
[OBSERVABILITY_GUIDE.md](OBSERVABILITY_GUIDE.md): use Troubleshooting to
diagnose a known failure, Observability to understand available signals, and
this guide when you need to hand off a clear report.

SwiftOS is early product software. A useful support report should distinguish
current design limits from regressions, include the exact repository revision,
and attach the serial or test output that proves the failure. For choosing and
reading focused gates, see [TESTING_GUIDE.md](TESTING_GUIDE.md).

For common product and support questions before opening a report, see
[FAQ.md](FAQ.md).

## Support Scope

Current supported support targets:

| Area | Supported evidence path |
| --- | --- |
| Direct QEMU boot | [Installation Guide](INSTALLATION_GUIDE.md) profile plus `./tests/boot_test.sh` |
| UEFI QEMU boot | [Installation Guide](INSTALLATION_GUIDE.md) profile plus `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| Serial console login | `./tests/console_login_test.sh` |
| Native commands | command-specific tests from [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md) |
| Networking demos | [Networking Guide](NETWORKING_GUIDE.md) profiles plus the socket tests |
| Package payload overlay | `make package-overlay-test` |
| Package-store activation | `make package-store-test` |
| Local package install | `make package-local-install-test` |
| Signed repository install | `make package-repo-install-test` |
| Static-host ports fixture | `make package-static-host-repo-install-test` |
| Hosted package URL fixture | `make ports-hosted-url-verify-test`, `make package-static-host-dns-repo-install-test` |
| LLM local and serving demos | `./tests/llm_run_test.sh`, `./tests/llm_serve_test.sh` |
| Driver-service supervisor smoke (`-smp 4`) | `make c5-driver-service-test` |
| SMP readiness | milestone-specific SMP targets from [RISK_REMEDIATION_ROADMAP.md](RISK_REMEDIATION_ROADMAP.md) |

Current non-support targets:

- Linux binary compatibility.
- Docker or OCI compatibility.
- Persistent writable root filesystem behavior.
- Production TLS trust decisions from `tlsget`.
- General x86-64, Raspberry Pi, or PC hardware boot.
- Target-side package remove, upgrade, rollback, and version-constraint solving
  transactions.
- Public hosted package channels outside the checked local fixtures.

For the full compatibility matrix, see
[COMPATIBILITY_GUIDE.md](COMPATIBILITY_GUIDE.md).

## First Response Checklist

Run these commands before opening a report unless the failure prevents them:

```sh
git status --short --branch
git log -1 --oneline
make tools-check
make build
```

Then run the narrowest acceptance test that proves the failing path:

| Failure area | First test |
| --- | --- |
| Direct boot | `./tests/boot_test.sh` |
| Base image or VFS | `./tests/vfs_disk_test.sh` |
| Disk exec path | `./tests/disk_exec_test.sh` |
| Login | `./tests/console_login_test.sh` |
| Capability denial | `./tests/cap_enforce_test.sh` |
| Core commands | `./tests/swift_coreutils_test.sh` |
| tmpfs mutation | `./tests/swift_fileops_test.sh` |
| HTTP server | `./tests/httpd_test.sh` |
| LLM serving | `./tests/llm_serve_test.sh` |
| Package payload overlay | `make package-overlay-test` |
| Package-store activation | `make package-store-test` |
| Local package install | `make package-local-install-test` |
| Signed repository install | `make package-repo-install-test` |
| Static-host ports fixture | `make package-static-host-repo-install-test` |
| Hosted package URL fixture | `make ports-hosted-url-verify-test`, `make package-static-host-dns-repo-install-test` |
| UEFI boot | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| Driver-service supervisor smoke (`-smp 4`) | `make c5-driver-service-test` |
| SMP readiness | `make s1-test` or the active milestone target |

If the narrow test passes, record that too. It narrows the problem and prevents
the next person from retesting the wrong layer.

## Minimum Report Template

Use this template for bugs, regressions, and failed demos.

```text
Title:
  Short symptom, command, and area.

Revision:
  git log -1 --oneline
  git status --short --branch

Host tools:
  make tools-check

What I ran:
  exact make command, test script, or QEMU command

Expected:
  what the guide or acceptance test says should happen

Actual:
  exact failure line, exit code, panic line, timeout, or wrong output

Evidence attached:
  serial log or test output
  relevant host command output
  guest command transcript, if manual

Reproducibility:
  always / intermittent / once
  number of reruns

Local changes:
  unrelated dirty files, config overrides, environment variables, or patches
```

Do not summarize away the first failing line. Include the exact line and the
nearby context.

## Collect A Support Bundle

For a general build or boot issue, collect:

```sh
mkdir -p support
git status --short --branch >support/git-status.txt
git log -1 --oneline >support/git-head.txt
make tools-check >support/tools-check.txt 2>&1
make build >support/build.txt 2>&1
./tests/boot_test.sh >support/boot-test.txt 2>&1
```

If the failing path is networked, collect the specific network test too:

```sh
./tests/httpd_test.sh >support/httpd-test.txt 2>&1
./tests/llm_serve_test.sh >support/llm-serve-test.txt 2>&1
```

If the failing path is UEFI:

```sh
make disk base-image >support/disk-build.txt 2>&1
UEFI_BOOT=disk ./tests/uefi_boot_test.sh >support/uefi-boot-test.txt 2>&1
```

If the failure is intermittent, run the same narrow test three times and record
all outputs separately:

```sh
for n in 1 2 3; do
  ./tests/boot_test.sh >"support/boot-test-$n.txt" 2>&1 || break
done
```

Do not include generated build directories unless a maintainer asks for a
specific artifact. Text logs are the first-line support artifact.

## Serial Log Capture

Most product evidence comes from the serial console. For a manual direct boot,
capture QEMU output:

```sh
make build base-image build/virt.dtb

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -kernel build/kernel.elf >support/serial.log 2>&1
```

Exit QEMU serial with `Ctrl-A X`.

For network services, include the host client output and the serial log:

```sh
curl -v http://127.0.0.1:8080/ >support/curl-httpd.txt 2>&1
curl -v http://127.0.0.1:8080/health >support/curl-llmd-health.txt 2>&1
```

## Important Log Markers

These markers help locate the failing subsystem.

| Marker | Meaning |
| --- | --- |
| `M9 OK: hardware discovered from device tree` | Platform discovery succeeded |
| `M11c: read-only base mounted from disk` | Base filesystem mounted |
| `M11d: exec loaded from disk` | User program loaded through VFS |
| `swift-os login:` | Console login reached |
| `Welcome to swift-os` | Authentication succeeded |
| `httpd: listening on 8080` | Static HTTP server is ready |
| `llmd: serving on 8080` | LLM HTTP server is ready |
| `llmd: generation 2 rejected (model size/sha256 mismatch)` | Deliberately corrupt model generation was rejected |
| `llmd: bundle stories15M generation 1 verified (ed25519+sha256)` | Signed model fallback selected generation 1 |
| `llmd: served` | LLM request completed and metrics were logged |
| `C5a OK: restartable driver service recovered over IPC` | C5a pseudo driver service restarted and recovered |
| `pkghello: hello from package overlay` | Package overlay was visible and executable |
| `LOG-EXPORT-BEGIN` | Kernel log serialization smoke path ran |
| `panic` | Fatal kernel path; include surrounding register/log lines |

When reporting a panic, include the first `panic` line and at least 80 lines
before and after it if available.

## Severity Levels

| Severity | Use for | Examples |
| --- | --- | --- |
| S0 blocker | Cannot build or boot the primary QEMU path | `make build` fails on a clean tree; `boot_test` cannot reach early markers |
| S1 critical | Primary workflow regression with a narrow repro | login broken; base image cannot mount; package overlay no longer executes |
| S2 major | Shipped command or documented workflow fails | `llmd` endpoint fails; coreutils test regresses; DNS test fails |
| S3 minor | Documentation mismatch, confusing diagnostics, non-primary smoke | typo in guide; missing troubleshooting note; framebuffer smoke instability |
| S4 roadmap | Valid request outside current support scope | Linux ABI request; persistent writable root; Docker compatibility |

Use the lowest severity that still captures the user impact. If in doubt, pick
S2 and include the evidence.

## Known Design Limits To Mention

Avoid filing these as regressions unless the behavior changed from a documented
acceptance path.

| Limit | Current expected behavior |
| --- | --- |
| Writes to `/etc` or `/bin` | Fail because the base image is read-only |
| `/tmp` persistence | Data is lost on reboot |
| `guest` reading files | Fails because `guest` has spawn-only authority |
| `user` creating sockets | Fails because `user` lacks `capNet` |
| Linux binaries | Do not run |
| Dynamic linking | Not supported |
| `tlsget` trust | TLS runtime demo only; no production certificate verification |
| Package remove, upgrade, rollback, version-constraint solving | Not implemented; local file install and P5c signed repository install with name-based dependencies are supported fixtures |
| General x86-64 boot | Not supported |

## Area-Specific Evidence

### Build And Toolchain

Attach:

```sh
make tools-check
make build
```

If the failure mentions newlib or busybox:

```sh
test -f sysroot/aarch64-elf/include/stdio.h
test -f build/busybox.elf
```

### Boot And Firmware

Attach:

```sh
./tests/boot_test.sh
UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

For firmware issues, include:

```sh
make -n disk-run
```

### Filesystem

Attach:

```sh
./tests/vfs_disk_test.sh
./tests/disk_exec_test.sh
./tests/swift_fileops_test.sh
```

Mention whether the path is in the read-only base image, `/tmp`, or a package
overlay.

### Accounts And Capabilities

Attach:

```sh
./tests/console_login_test.sh
./tests/cap_enforce_test.sh
```

From an interactive guest, include:

```sh
id
```

### Networking

Attach the exact QEMU network command and the narrow test:

```sh
./tests/virtio_net_test.sh
./tests/httpd_test.sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
./tests/tcp_connect_test.sh
./tests/dns_test.sh
```

If host ports were overridden, record the environment variable:

```sh
HTTPD_HOST_PORT=18080 ./tests/httpd_test.sh
LLMD_HOST_PORT=18081 ./tests/llm_serve_test.sh
```

### AI Hosting

Attach:

```sh
make model
./tests/llm_run_test.sh
./tests/llm_serve_test.sh
```

For `/bin/llmd`, include:

```sh
curl -v http://127.0.0.1:8080/health
curl -v -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
curl -v http://127.0.0.1:8080/metrics
```

### Package Overlays And Stores

Attach:

```sh
make package-fixture
make package-overlay-test
make package-store-test
make package-local-install-test
make package-repo-install-test
make package-static-host-repo-install-test
make ports-hosted-url-verify-test
make package-static-host-dns-repo-install-test
make c5-driver-service-test
```

Mention whether the guest saw `/usr/bin/pkghello`, whether `pkg list` reported
`pkghello-1.0.0_1`, and whether the repository flow printed
`pkg: catalog updated`. For the static-host ports fixture, mention whether
`pkg install lua` and `pkg install zlib` succeeded, whether Lua printed `42`,
whether the `minigzip` round trip printed `static-host-ok`, and whether the
hosted-URL path used an IP literal or DNS hostname.

### SMP Readiness

Attach:

```sh
make s1-test
SMP_CPUS=4 ./tests/smp_boot_test.sh
```

If the issue is CPU-count-specific, record the `SMP_CPUS` value and whether a
custom `SMP_DTB` was used.

## Redaction And Privacy

Current seeded credentials are public test credentials and may appear in logs:

| Login | Password |
| --- | --- |
| `root` | `swordfish` |
| `user` | `swordfish` |
| `guest` | `guest` |

Before sharing logs from a custom image, redact:

- private package repository URLs;
- non-public model prompts or generated output;
- locally added passwords or keys;
- host paths that should not be disclosed;
- future package signing keys or tokens.

Do not redact the actual failure marker, command line, or revision. Those are
usually required for diagnosis.

## Support Handoff Checklist

Before handing the issue to another person, confirm:

1. The report names the exact command or workflow.
2. The current `git log -1 --oneline` is included.
3. Dirty local files are listed with `git status --short --branch`.
4. `make tools-check` output is included for build or QEMU issues.
5. A narrow acceptance test was run, or the report explains why it could not be
   run.
6. The serial log or test output includes the first failing line.
7. The report says whether the failure repeats.
8. Known design limits were checked against
   [COMPATIBILITY_GUIDE.md](COMPATIBILITY_GUIDE.md).

## Related Documents

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): common failures and fixes.
- [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md): normal operating workflows.
- [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md): command syntax and acceptance
  coverage.
- [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md): build variables,
  QEMU profiles, and test knobs.
- [COMPATIBILITY_GUIDE.md](COMPATIBILITY_GUIDE.md): supported and unsupported
  compatibility paths.
- [LOGGING.md](LOGGING.md): logging reference, current limits, and roadmap.

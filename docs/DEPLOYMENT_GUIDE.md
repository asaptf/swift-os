# SwiftOS Deployment Guide

This guide explains how to prepare, validate, hand off, and roll back a
SwiftOS deployment candidate. It is written for operators, release testers,
reviewers, embedded/appliance integrators, and application or AI hosting
teams who need repeatable deployment evidence.

SwiftOS does not yet ship a downloadable installer, hosted update service,
public online package repository, or production bare-metal certification matrix.
A deployment today is a host-built immutable artifact set plus a documented boot
profile, validation record, and rollback artifact set.

Use this guide with:

- [Installation Guide](INSTALLATION_GUIDE.md) for boot profiles and artifact
  setup.
- [Update And Rollback Guide](UPDATE_GUIDE.md) for replacing immutable
  artifacts and returning to a known-good set.
- [Operations Guide](OPERATIONS_GUIDE.md) for day-to-day runbooks and QEMU
  command examples.
- [Testing Guide](TESTING_GUIDE.md) for focused and full validation gates.
- [Configuration Reference](CONFIGURATION_REFERENCE.md) for build variables,
  QEMU defaults, and test knobs.
- [Service Guide](SERVICE_GUIDE.md) for service lifecycle, readiness, and
  current supervisor limits.
- [AI Hosting Guide](AI_HOSTING_GUIDE.md) for model bundles, `/bin/llm`, and
  `/bin/llmd`.
- [Package Guide](PACKAGE_GUIDE.md) for `.swpkg`, payload overlays, and
  package-store images.
- [Performance And Sizing Guide](PERFORMANCE_GUIDE.md) for measurement
  boundaries and sizing evidence.
- [Observability Guide](OBSERVABILITY_GUIDE.md) and
  [Support Guide](SUPPORT_GUIDE.md) for logs, metrics, and handoff bundles.

## Deployment Model

The current SwiftOS deployment unit is a small, explicit set of immutable
artifacts:

| Artifact | Typical source | Deployment role |
| --- | --- | --- |
| `build/kernel.elf` | `make build` | Direct QEMU kernel image |
| `build/virt.dtb` | `make build/virt.dtb` | Device tree for direct QEMU boot |
| `build/base.img` | `make base-image` | Read-only root content: `/bin`, `/etc`, `/www`, `/models` |
| `build/swift-os.img` | `make disk` | UEFI/GPT disk with EFI loader |
| Package payload image | `make package-fixture` or package tooling | Optional read-only `/usr` payload |
| Package-store image | `make package-store-fixture` or `build/pkgstore` | Optional active package generation |
| Writable package-store image | `make package-local-install-fixture` | Optional local `pkg install FILE` target |
| Static repository fixture | `make package-repo-fixture` or `build/pkgrepo` | Optional signed HTTP package repository fixture |
| Model artifacts | `make model`, then `make base-image` | Optional TinyStories local and served models |

A complete deployment candidate records:

1. The git revision and worktree state.
2. The deployment profile.
3. The artifact list, sizes, and hashes.
4. The boot command or make target.
5. The identity and capability policy used by the image.
6. The package and model payloads, if any.
7. The validation commands and their results.
8. The rollback artifact set or rollback commit.

The running guest has only RAM-backed writable storage under `/tmp`. Data in
`/tmp` is intentionally lost on reboot. Change installed software by rebuilding
the base image or attaching package artifacts; do not treat the guest as a
mutable server.

## Supported Deployment Profiles

Choose one primary profile for the candidate, then add only the optional
capabilities the workload needs.

| Profile | Use it for | Required artifacts | Minimum proof |
| --- | --- | --- | --- |
| Direct serial candidate | Development, operator walkthroughs, fast validation | `kernel.elf`, `base.img`, `virt.dtb` | `./tests/boot_test.sh` |
| UEFI/GPT candidate | Firmware handoff, disk layout, primary boot packaging | `swift-os.img`, `base.img` | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| Application service hosting | `httpd`, echo services, network tools | Direct or UEFI artifacts plus virtio-net | Service-specific network test |
| AI hosting | Local or HTTP TinyStories inference | Base image with model bundle and optional NIC | `./tests/llm_run_test.sh`, `./tests/llm_serve_test.sh` |
| Package payload candidate | Read-only package content under `/usr` | Base artifacts plus payload image | `make package-overlay-test` |
| Package-store candidate | Active package generation boot | Base artifacts plus package-store image | `make package-store-test` |
| Signed repository install candidate | Install package content by name from the signed HTTP fixture | Base artifacts plus writable store, repository fixture, and virtio-net | `make package-repo-install-test` |
| Embedded/appliance-style candidate | Minimal fixed-purpose image | Base artifacts plus only needed devices/services | Boot test plus workload-specific test |
| VirtualBox ARM smoke | Apple Silicon firmware-adjacent evidence | `swift-os.vdi` | Manual evidence from [VIRTUALBOX.md](VIRTUALBOX.md) |

Direct serial and UEFI/GPT are the primary supported QEMU profiles. VirtualBox
ARM remains best effort.

## What Is Not A Deployment Target Yet

Do not present the current system as having:

- A graphical end-user installer.
- A Linux, Docker, OCI, DEB, RPM, APK, Homebrew, or Nix deployment path.
- A persistent writable root filesystem.
- Public hosted package channels, package upgrade, remove, or rollback commands.
- A production online update service.
- Production health-driven update channels beyond the checked A/B validation
  paths.
- A production bare-metal certification matrix.
- A production service supervisor with dependency ordering and health policy.
- Production secret provisioning or password rotation.

Those are roadmap items. Current candidates are explicit immutable artifact
sets with manual service launch or the narrow `/bin/swos-init` boot allowlist
where a service is needed.

## Build A Candidate

Start from a clean worktree or record intentional local changes:

```sh
git status --short --branch
git log -1 --oneline
```

Check host tools:

```sh
make tools-check
```

Build the common direct-boot artifact set:

```sh
make build base-image build/virt.dtb
```

Build the UEFI/GPT disk artifact when the deployment profile uses firmware
boot:

```sh
make disk
```

Build model artifacts when the profile includes `/bin/llm` or `/bin/llmd`:

```sh
make model
make base-image
```

Build package artifacts when the profile includes package content:

```sh
make package-fixture
make package-store-fixture
```

For the local package install flow, build the writable package-store fixture
with:

```sh
make package-local-install-fixture
```

## Customize The Image

SwiftOS image customization is host-side.

| Need | Current method | Rebuild |
| --- | --- | --- |
| Add or change base files | Edit files under `base/` | `make base-image` |
| Change seeded accounts or capabilities | Edit `base/etc/swos/passwd` | `make base-image` |
| Change default web content | Edit `base/www/` | `make base-image` |
| Add a native SwiftOS program to `/bin` | Add the userland target and stage it into the base image | `make build base-image` |
| Add package content under `/usr` | Build a `.swpkg`, payload image, or package-store image | Package target plus boot attachment |
| Update model payloads | Run `make model`, then rebuild the base image | `make model base-image` |

For account and capability details, see
[Administration Guide](ADMINISTRATION_GUIDE.md) and
[Security Guide](SECURITY_GUIDE.md). For package authoring, see
[Application Cookbook](APPLICATION_COOKBOOK.md) and
[Package Guide](PACKAGE_GUIDE.md).

Do not make persistent product changes from inside the guest. Edits under
`/tmp` disappear on reboot, and the base filesystem is read-only by design.

## Record Artifact Evidence

Capture artifact sizes:

```sh
ls -lh build/kernel.elf build/base.img build/virt.dtb build/swift-os.img
```

If a file is not part of the selected profile, omit it from the command.

Capture hashes:

```sh
shasum -a 256 build/kernel.elf build/base.img build/virt.dtb build/swift-os.img
```

For package deployments, also hash the package artifacts:

```sh
shasum -a 256 build/pkghello.swpkg build/pkghello-payload.img build/pkgstore-pkghello.img
```

For AI deployments, record the model manifest and trust-root files staged into
the base image. The raw downloaded model files are not tracked in git; identify
the prepared bundle by the git revision, `make model` run, base image hash, and
`llmd` startup verification markers.

## Deployment Manifest Template

Keep a small manifest beside every candidate artifact set:

```text
SwiftOS deployment candidate
revision: <git log -1 --oneline>
worktree: clean | intentional local changes listed below
profile: direct-serial | uefi-gpt | service-hosting | ai-hosting | package | appliance
boot target: make run | make disk-run | manual qemu command
memory: 256M
cpu count: 1
network: none | virtio-net slirp hostfwd ...

artifacts:
  build/kernel.elf sha256=<...> size=<...>
  build/base.img sha256=<...> size=<...>
  build/virt.dtb sha256=<...> size=<...>
  build/swift-os.img sha256=<...> size=<...>
  package image sha256=<...> size=<...>
  model bundle: <path or generation>

identity:
  accounts source: base/etc/swos/passwd
  seeded passwords changed: yes | no
  capNet principals: <list>

validation:
  ./tests/boot_test.sh: pass | fail | not run
  UEFI_BOOT=disk ./tests/uefi_boot_test.sh: pass | fail | not run
  service tests: <commands and results>
  package tests: <commands and results>
  AI tests: <commands and results>
  make test: pass | fail | not run

rollback:
  previous revision: <commit>
  previous artifact location: <path>
  rollback command: <command or runbook link>

notes:
  <known limits, host QEMU version, evidence paths>
```

This manifest is intentionally plain text so it can be pasted into release
notes, support tickets, or an operator handoff.

## Evidence Bundle Layout

For every candidate that leaves one developer's machine, keep a small evidence
bundle next to the artifacts. A predictable layout makes review, support, and
rollback much faster:

```text
support/deployment-candidate/
  manifest.txt
  git-status.txt
  git-head.txt
  tools-check.txt
  artifacts-sha256.txt
  artifacts-size.txt
  validation.txt
  serial.log
  service-health.txt
  service-metrics.txt
  rollback.txt
```

Create the host-side records before starting manual validation:

```sh
mkdir -p support/deployment-candidate
git status --short --branch >support/deployment-candidate/git-status.txt
git log -1 --oneline >support/deployment-candidate/git-head.txt
make tools-check >support/deployment-candidate/tools-check.txt 2>&1
ls -lh build/kernel.elf build/base.img build/virt.dtb \
  >support/deployment-candidate/artifacts-size.txt
shasum -a 256 build/kernel.elf build/base.img build/virt.dtb \
  >support/deployment-candidate/artifacts-sha256.txt
```

For a UEFI/GPT candidate, add the disk image:

```sh
ls -lh build/swift-os.img >>support/deployment-candidate/artifacts-size.txt
shasum -a 256 build/swift-os.img >>support/deployment-candidate/artifacts-sha256.txt
```

For package or AI candidates, also add the profile-specific package,
repository, or model artifacts to both files.

Record validation commands exactly as run:

```sh
./tests/boot_test.sh >support/deployment-candidate/validation.txt 2>&1
```

For HTTP service candidates, append the host-visible check:

```sh
curl -fsS http://127.0.0.1:8080/ \
  >support/deployment-candidate/service-health.txt 2>&1
```

For AI serving candidates, record the dedicated health and metrics endpoints:

```sh
curl -fsS http://127.0.0.1:8080/health \
  >support/deployment-candidate/service-health.txt 2>&1
curl -fsS http://127.0.0.1:8080/metrics \
  >support/deployment-candidate/service-metrics.txt 2>&1
```

Only include `service-health.txt` or `service-metrics.txt` when the selected
profile exposes that endpoint. For non-networked appliance candidates, the
serial log and focused validation output are the primary evidence.

## Profile Runbooks

### Direct Serial Candidate

Build and verify:

```sh
make build base-image build/virt.dtb
./tests/boot_test.sh
```

Manual run:

```sh
make run
```

Expected user-facing marker:

```text
swift-os login:
```

This is the fastest profile and should be used first for most kernel, userland,
base image, and documentation validation.

### UEFI/GPT Candidate

Build and verify:

```sh
make disk base-image
UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

For SMP-sensitive boot work, also run:

```sh
SMP_CPUS=4 UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

Manual run:

```sh
make disk-run
```

Use this profile for any candidate that claims the primary firmware boot path
or disk layout is ready.

### Application Service Hosting Candidate

Build the base system:

```sh
make build base-image build/virt.dtb
```

Boot with virtio-net and host forwarding. For common service commands, use
[Operations Guide](OPERATIONS_GUIDE.md#network-boot) and
[Networking Guide](NETWORKING_GUIDE.md).

Run the tests that match the exposed service:

```sh
./tests/httpd_test.sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
./tests/dns_test.sh
```

If the service is manual, record the exact login principal and command used to
start it. The current system does not yet have a production service supervisor,
so "deployed service" means "booted artifact set plus documented manual launch
or test harness launch."

### Hetzner Cloud Preparation

Hetzner Cloud deploy readiness is tracked separately from the local QEMU
application-service profile because it adds provider-specific boot, network, and
remote-login requirements.

Current Hetzner readiness status:

- The network stack attempts a DHCPv4 lease during virtio-net bring-up and
  adopts the offered IPv4 address, router, DNS server, and subnet mask before
  the existing ARP/ICMP probe runs.
- If DHCP does not answer, the QEMU/slirp fallback remains
  `10.0.2.15` / `10.0.2.2` / `10.0.2.3`, preserving local network tests.
- Outbound IPv4 sockets select their Ethernet next hop from the configured
  subnet mask: same-subnet peers are ARPed directly, while off-link destinations
  and `/32` cloud-style leases use the configured gateway.
- This matches Hetzner's documented Primary IPv4 model, where cloud servers get
  their Primary IPv4 via DHCP. Their static examples use `/32` IPv4 addressing
  with gateway `172.31.1.1`, and IPv6 is a separate manual/cloud-init path.
- A Hetzner custom ISO or snapshot must match the server architecture. For this
  repository's current `aarch64` target, use an Arm64 cloud server/ISO path.
- The base image includes `/bin/sshd` as an SSHD session/exec preflight. It is
  started at boot by `/bin/swos-init` from `/etc/swos/services`, binds guest
  TCP/22, exchanges SSH identification strings with a normal OpenSSH client,
  completes `curve25519-sha256` KEX with an `ssh-ed25519` host key derived from
  `/etc/ssh/ssh_host_ed25519_seed` and `chacha20-poly1305@openssh.com`,
  authenticates `root` with an
  `ssh-ed25519` key loaded from `/etc/ssh/authorized_keys`, opens a `session`
  channel, and executes bounded direct `/bin/<tool>` and `/usr/bin/<tool>`
  commands such as `/bin/id`, `/bin/echo HC6-OK`, and package-overlay tools;
  bounded remote stdin is forwarded into fd 0 for tools
  such as `/bin/cat`, and bounded stdout/stderr capture returns up to 4096
  bytes. The direct exec parser supports whitespace splitting, quote removal,
  and backslash escaping for argv, but it is still not a shell. The host helper
  `build/sshkey` can derive the OpenSSH public host key or a known_hosts line
  from the base image seed file, and can generate a deploy-specific replacement
  seed. Build-time provisioning uses the
  `SSHD_HOST_SEED_FILE` and `SSHD_AUTHORIZED_KEYS_FILE` make variables with
  `make base-image` to stage deploy-specific host identity and login keys into
  the signed image. `SWOS_SERVICES_FILE` can replace
  `/etc/swos/services` for a custom candidate; the `sshd-supervised` and
  `sshd-once` tokens exercise the current opt-in restart loop. The checked
  proofs are `./tests/sshd_transport_test.sh`,
  `./tests/sshd_host_key_rotation_test.sh`,
  `./tests/sshd_authorized_keys_test.sh`, and
  `./tests/sshd_supervision_test.sh`; `./tests/sshd_usr_bin_exec_test.sh`
  also boots the `pkghello` package payload and runs `/usr/bin/pkghello` over
  SSHD. Together they verify that host OpenSSH pins the
  SwiftOS host key through known_hosts, that stale fixture keys are rejected,
  that custom images can boot with rotated SSHD host-key and authorized-key
  material, that quoted argv reaches remote `/bin/echo`, that bounded stdin
  reaches remote `/bin/cat`, that long output is capped and logged without pipe
  backpressure, and that opt-in `swos-init` supervision restarts `sshd-once`.
- The base image also includes `/bin/ssh` as an outbound SSH client transport
  preflight. It connects to a host OpenSSH server, verifies the server's
  `ssh-ed25519` host-key signature over the exchange hash, matches the host key
  against `/etc/ssh/known_hosts`, handles strict KEX, derives
  `chacha20-poly1305@openssh.com` keys, and completes one encrypted
  `ssh-userauth` service request/accept. The checked proof is
  `./tests/ssh_transport_test.sh`.

Not deploy-complete yet:

- `/bin/sshd` is not a full login-capable SSH daemon yet. The next remote-login
  milestones should add runtime host-key rotation, real entropy, broader
  authorized-key options, shell/PTY behavior, larger stdin/output streaming,
  production service policy, and broader remote commands beyond bounded direct
  `/bin/<tool>` or `/usr/bin/<tool>` exec. Dropbear remains a candidate full
  server package if the first-party preflight does not grow into the supported
  daemon.
- `/bin/ssh` is not a full SSH client yet. It has a minimal file-backed
  `known_hosts` trust store, but no user authentication, session/exec channels,
  PTY, scp, or sftp.
- IPv6 Primary IP configuration, cloud metadata ingestion, firewall policy, and
  a general service manager remain follow-up work.

Provider references to re-check before a real cloud run:

- Hetzner Cloud static IP configuration:
  <https://docs.hetzner.com/cloud/servers/static-configuration/>
- Hetzner Cloud server FAQ, architecture and custom ISO notes:
  <https://docs.hetzner.com/cloud/servers/faq/>

### AI Hosting Candidate

Build model and base artifacts:

```sh
make build
make model
make base-image
```

Validate local and served paths:

```sh
./tests/llm_run_test.sh
./tests/llm_serve_test.sh
```

For model-bundle parser coverage:

```sh
/usr/bin/swiftc tests/llm_bundle_test.swift userland/lib/modelbundle.swift kernel/crypto/sha256.swift -o build/llm_bundle_test
build/llm_bundle_test
```

Record `/bin/llmd` startup markers for:

- Trust root loaded.
- Corrupt newest generation rejected.
- Valid generation selected.
- Model shape.
- Served endpoint list.

Record `/health` and `/metrics` responses for handoff:

```sh
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8080/metrics
```

Treat QEMU inference throughput as regression evidence, not production capacity.
See [Performance And Sizing Guide](PERFORMANCE_GUIDE.md).

### Package Candidate

Build package artifacts:

```sh
make build base-image build/virt.dtb
make package-fixture
make package-store-fixture
```

Validate the supported package boot paths:

```sh
make package-overlay-test
make package-store-test
make package-local-install-test
make package-repo-install-test
```

`make package-local-install-test` proves the local-file install path.
`make package-repo-install-test` proves the signed HTTP repository fixture,
including configured repository URLs, name-based dependency resolution,
expired-catalog rejection, incompatible-catalog rejection, and package-hash
rejection. Do not document public hosted channels, version-constraint solving,
remove, upgrade, or rollback as current features yet.

### Embedded Or Appliance-Style Candidate

Use the smallest profile that demonstrates the appliance behavior:

1. Start from the direct serial or UEFI/GPT profile.
2. Attach virtio-net only if the appliance exposes a network surface.
3. Include package or model artifacts only if the appliance workload needs them.
4. Keep `/tmp` usage runtime-only.
5. Record every manually launched service and the principal used to launch it.
6. Run `./tests/boot_test.sh` plus the workload-specific focused test.

Current embedded/appliance work uses the same checked-in QEMU target. There is
not yet a separate production appliance board profile.

## Validation Matrix

Run the narrow gate for the chosen profile before broader validation.

| Candidate includes | Required focused gate |
| --- | --- |
| Direct serial boot | `./tests/boot_test.sh` |
| UEFI/GPT disk boot | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| SMP-sensitive UEFI path | `SMP_CPUS=4 UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| Framebuffer or keyboard smoke | `./tests/fb_vi_test.sh` |
| HTTP static service | `./tests/httpd_test.sh` |
| TCP echo service | `./tests/tcp_echo_test.sh` |
| UDP echo service | `./tests/udp_echo_test.sh` |
| DNS resolver | `./tests/dns_test.sh` |
| TLS runtime path | `./tests/tls_test.sh` |
| Package overlay | `make package-overlay-test` |
| Package store | `make package-store-test` |
| Local package install plumbing | `make package-local-install-test` |
| Local AI inference | `./tests/llm_run_test.sh` |
| AI HTTP serving | `./tests/llm_serve_test.sh` |
| Broad release confidence | `make test` |

If a candidate changes only documentation, release notes, or comments, a direct
build plus boot smoke is usually enough. If it changes build rules, kernel,
userland, networking, package, model, or boot code, run the focused gate and
consider `make test`.

## Handoff Bundle

A deployment handoff should include:

- Deployment manifest.
- Git revision and `git status --short --branch` output.
- Artifact hashes and sizes.
- Exact QEMU command or make target.
- Serial log from a passing boot.
- Service logs, readiness markers, and health responses.
- SSHD public host key or known_hosts line derived from the exact seed staged
  into the image.
- SSHD authorized_keys source and the public-key fingerprint expected to log in.
- `top -b -n 1` output for resource-sensitive candidates.
- Test command list and pass/fail result.
- Known limits and skipped tests.
- Rollback artifact location.

For support cases, use the report structure in [Support Guide](SUPPORT_GUIDE.md).

## Rollback

Rollback is artifact-level today. Before replacing a known-good set, save it:

```sh
mkdir -p build/rollback
cp build/kernel.elf build/rollback/kernel.elf.prev
cp build/base.img build/rollback/base.img.prev
cp build/virt.dtb build/rollback/virt.dtb.prev
cp build/swift-os.img build/rollback/swift-os.img.prev
```

If a candidate fails, boot the previous artifact set or return to the previous
git revision and rebuild:

```sh
git log --oneline -5
make build base-image build/virt.dtb
./tests/boot_test.sh
```

For UEFI/GPT candidates, rebuild and retest the disk image:

```sh
make disk base-image
UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

For packages and models, keep the previous payload image, package-store image,
or verified base image available. The checked base-image and kernel-image A/B
paths have health confirmation and attempt-based rollback for unconfirmed boot
slots; service-level health rollback and package/model rollback commands are not
implemented yet.

## Release Checklist

Use this checklist before calling a candidate ready for review:

1. Worktree state recorded.
2. Candidate profile selected.
3. Artifacts rebuilt from the intended revision.
4. Artifact hashes and sizes recorded.
5. Seeded identity and capability policy reviewed.
6. Package or model payloads recorded, if present.
7. Focused validation gate passed.
8. Broader gate run or explicitly deferred.
9. Serial log and service health evidence saved.
10. Rollback artifact set prepared.
11. Current limitations documented in the manifest.

The deployment is ready only when another operator can reproduce the boot,
run the same checks, and return to the previous artifact set using the recorded
rollback path.

# SwiftOS Update And Rollback Guide

This guide explains how to update and roll back the current SwiftOS image. It is
written for operators, release testers, validation owners, and support engineers who
need a predictable way to move from one checked-in revision or artifact set to
another.

SwiftOS does not yet provide an on-target graphical installer, online updater,
or live package upgrade command. The supported update model starts from
host-built immutable artifacts, then either boots those artifacts directly or
stages them through the checked A/B validation paths. Keep the previous artifacts
available for rollback.

Use this guide with:

- [Installation Guide](INSTALLATION_GUIDE.md) for boot profiles and artifact
  setup.
- [Deployment Guide](DEPLOYMENT_GUIDE.md) for candidate manifests, validation
  gates, handoff bundles, and rollback evidence.
- [Operations Guide](OPERATIONS_GUIDE.md) for day-to-day runbooks.
- [Release Notes](RELEASE_NOTES.md) for shipped features and known limits.
- [Package Guide](PACKAGE_GUIDE.md) for `.swpkg`, package payload, and
  package-store workflows.
- [AI Hosting Guide](AI_HOSTING_GUIDE.md) for model-bundle generation,
  verification, and serving checks.
- [Observability Guide](OBSERVABILITY_GUIDE.md) for health markers, logs, and
  metrics.
- [Support Guide](SUPPORT_GUIDE.md) for evidence collection when an update
  fails.

## Current Update Model

SwiftOS is built around immutable boot and software artifacts.

| Artifact | Update method | Rollback method |
| --- | --- | --- |
| `build/kernel.elf` | Rebuild with `make build` | Boot a previously saved kernel or return to an older commit |
| `build/base.img` | Repack with `make base-image` | Boot a previously saved base image or return to an older commit |
| `build/virt.dtb` | Rebuild with `make build/virt.dtb` | Boot the previous DTB used with the previous kernel |
| `build/swift-os.img` | Rebuild with `make disk` | Boot the previous disk image |
| Package payload image | Rebuild with `make package-fixture` or package tooling | Attach the previous payload image |
| Package store image | Rebuild with `make package-store-fixture` or `tools/pkgstore.swift` | Attach the previous store image |
| Model bundle files | Rebuild with `make model` and `make base-image` | Boot a previous base image or ship an older verified generation |

The running guest has only RAM-backed writable storage under `/tmp`. An update
does not preserve `/tmp`, and a reboot clears it.

## What Is Not Implemented Yet

The current tree has a narrow signed SWOSBASE A/B update-store path with
`swos-update`, `swos-activate`, `swos-confirm`, boot-attempt rollback, and host
tools for generating the store and kernel boot manifest. It is still a
controlled validation path, not a production updater.

Current limitations:

- No live in-place kernel or root filesystem replacement; updates stage an
  inactive slot and require reboot.
- No persistent writable root filesystem.
- No target-side package `upgrade` or rollback transaction.
- No production image signing policy for the whole OS image.
- Base-image rollback is implemented for the checked A/B update-store path.
- Kernel-image staging, activation, health confirmation, boot-attempt counting,
  and rollback are implemented for the checked UEFI ESP slot path.

The current verified model-bundle flow is a narrow working example of signed
manifest verification and generation fallback for AI assets. It is not a whole
OS updater.

## Stage Base Images In The A/B Update Store

Use this path when validating the checked SWOSBOOT base-image update flow. The
store is a narrow, writable, two-slot virtio-blk disk; each slot holds a signed
SWOSBASE image. The OS never trusts the store manifest as code authority: each
slot image is still verified by its own Ed25519 signature and per-file hashes.

Build the store tooling and base image:

```sh
make updatestore base-image
```

For an end-to-end target-side update, attach a store disk and a read-only
payload disk, then run the guest flow as `root`:

```sh
swos-update
swos-activate
```

After rebooting into the trial slot, confirm it healthy:

```sh
swos-confirm
```

Minimum verification:

```sh
./tests/ab_stage_test.sh
./tests/ab_activate_test.sh
./tests/ab_confirm_test.sh
```

Rollback is automatic for the checked base-image A/B path when a trial slot
exhausts its boot attempts without confirmation. Verify that behavior with:

```sh
./tests/ab_rollback_test.sh
```

Use [Update Store](UPDATE_STORE.md) for the manifest format, slot state model,
and trust boundary.

## Stage Kernel Slots From The UEFI ESP

Use this path when validating the checked kernel-image A/B flow. The UEFI loader
selects between signed ESP kernel slots using the signed `kernel-boot` manifest;
the running OS can courier-copy already-signed artifacts but never signs new
kernel manifests.

The current operator sequence is:

```sh
swos-kstage
swos-kactivate
```

Then reboot through the UEFI disk profile. On the next boot, the loader verifies
the signed kernel manifest's slot hashes, reads the selected active slot from
`kernel-state`, and checks the selected kernel image before handoff. The loader
also persists a per-slot boot-attempt counter in `kernel-state`; an unconfirmed
kernel slot rolls back after the checked attempt window.
After a healthy trial boot, confirm that booted kernel slot:

```sh
swos-kconfirm
```

Minimum verification:

```sh
./tests/uefi_kernel_ab_test.sh
./tests/uefi_kstage_test.sh
./tests/uefi_kactivate_test.sh
./tests/uefi_kattempt_test.sh
./tests/uefi_kconfirm_test.sh
./tests/uefi_krollback_test.sh
```

Kernel-image A/B has end-to-end staging, boot-state activation, health
confirmation, and attempt-based rollback for the checked ESP layout. A real
new-kernel payload source is future work.

## Release Identity

SwiftOS does not publish stable external version numbers yet. Identify a build
by the git revision and the artifact set used to boot it.

Record the current revision:

```sh
git log -1 --oneline
```

Record the changed files for a candidate:

```sh
git diff --stat HEAD^ HEAD
```

For a support handoff, include:

- The git commit or branch.
- The exact boot profile: direct `-kernel`, UEFI disk, graphical smoke, or
  VirtualBox.
- Whether `build/base.img`, `build/swift-os.img`, package images, or model files
  were rebuilt.
- The verification commands run after the update.
- The serial log from a successful or failed boot.

## Preflight Checklist

Before replacing a working artifact set:

1. Start from a clean worktree or record intentional local changes.
2. Save the known-good artifacts if you need quick rollback.
3. Rebuild only the artifacts affected by the change.
4. Run the narrowest relevant test first.
5. Run the broader gate before calling the update release-ready.

Check the worktree:

```sh
git status --short --branch
```

Save the current artifacts:

```sh
mkdir -p build/rollback
cp build/kernel.elf build/rollback/kernel.elf.prev
cp build/base.img build/rollback/base.img.prev
cp build/virt.dtb build/rollback/virt.dtb.prev
cp build/swift-os.img build/rollback/swift-os.img.prev
```

If one of those files does not exist yet, build it first or skip that copy.

## Update Kernel Or Userland

Use this path when code under `kernel/`, `userland/`, `base/`, or shared build
rules changes.

Build the kernel and base image:

```sh
make build base-image build/virt.dtb
```

Boot the direct serial profile:

```sh
make run
```

Minimum verification:

```sh
./tests/boot_test.sh
```

Use the direct profile for fast kernel, syscall, userland, VFS, account, and
tmpfs iteration. It exercises the normal kernel and base image without the UEFI
loader layer.

## Update The UEFI Disk Image

Use this path when touching the loader, disk layout, firmware handoff, or the
primary UEFI/GPT boot story.

Build the disk and base image:

```sh
make disk base-image
```

Boot the UEFI disk profile:

```sh
make disk-run
```

Minimum verification:

```sh
UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

For SMP-sensitive boot work, also run:

```sh
SMP_CPUS=4 UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

The UEFI disk image and base image are separate in the normal QEMU flow. If the
loader starts but userland files are missing, verify that the updated
`build/base.img` is also attached.

## Update Base Image Contents

Use this path when changing files under `base/`, staged `/bin` programs,
default web content, account seed files, or model files included in the base
filesystem.

Repack the base image:

```sh
make base-image
```

Run a direct boot smoke:

```sh
./tests/boot_test.sh
```

For filesystem-only changes, also use the relevant command-level or VFS test
when one exists. Examples:

```sh
./tests/vfs_disk_test.sh
./tests/console_login_test.sh
./tests/httpd_test.sh
```

Do not edit `/etc`, `/bin`, `/www`, or `/models` from inside the guest and
expect those edits to persist. Those paths come from the read-only base image.

## Update Package Payloads

Use this path when validating package content without baking it into `/bin`.

Build the sample package fixture:

```sh
make package-fixture
```

Run the payload-overlay acceptance test:

```sh
make package-overlay-test
```

Or boot manually with the package payload image attached, then run:

```sh
/usr/bin/pkghello
```

Expected output:

```text
pkghello: hello from package overlay
```

Current package payload images are read-only and attached at boot. They are not
a production online update mechanism.

## Update Package Store Images

Use this path when validating package-store boot activation.

Build the package store fixture:

```sh
make package-store-fixture
```

Run the package-store acceptance test:

```sh
make package-store-test
```

Rollback is host-driven today: attach the previous package-store image on the
next boot. Target-side active-generation updates, garbage collection, and
rollback commands are roadmap work.

## Update AI Model Bundles

Use this path when model source files, tokenizer files, serving manifests, or
verified bundle generations change.

Rebuild model artifacts and the base image:

```sh
make model
make base-image
```

Run the local inference smoke:

```sh
./tests/llm_run_test.sh
```

Run the serving smoke:

```sh
./tests/llm_serve_test.sh
```

The default serving image intentionally includes a bad newest generation and a
valid older generation. A healthy `/bin/llmd` boot should reject the bad
generation and serve from the newest verified generation.

Expected serial evidence includes:

```text
llmd: generation 2 rejected (model size/sha256 mismatch)
llmd: bundle stories15M generation 1 verified (ed25519+sha256)
llmd: serving on 8080
```

For the full AI runbook, see [AI Hosting Guide](AI_HOSTING_GUIDE.md).

## Roll Back Quickly

There are two practical rollback paths today.

### Roll Back To Previous Artifacts

If you saved artifacts under `build/rollback`, boot the previous kernel, DTB,
base image, or disk image by copying them back or by pointing QEMU directly at
the saved files.

For a direct boot rollback:

```sh
cp build/rollback/kernel.elf.prev build/kernel.elf
cp build/rollback/base.img.prev build/base.img
cp build/rollback/virt.dtb.prev build/virt.dtb
make run
```

For a UEFI disk rollback:

```sh
cp build/rollback/swift-os.img.prev build/swift-os.img
cp build/rollback/base.img.prev build/base.img
make disk-run
```

After rollback, run the same smoke that proved the original artifact set:

```sh
./tests/boot_test.sh
```

### Roll Back To A Previous Commit

Use normal git history to rebuild an older artifact set. Prefer a separate
worktree for release comparison so the current worktree stays intact.

Example:

```sh
git worktree add ../swift-os-rollback <known-good-commit>
cd ../swift-os-rollback
make build base-image build/virt.dtb
./tests/boot_test.sh
```

Do not use destructive git commands in a shared worktree unless everyone using
that worktree has agreed.

## Validation Matrix

Run the narrowest proof that matches the update, then broaden if the change
touches shared code.

| Updated area | Minimum proof | Broader proof |
| --- | --- | --- |
| Kernel core, syscall, process, VFS | `./tests/boot_test.sh` | `make test` |
| Base image contents | `make base-image`, `./tests/boot_test.sh` | Relevant command or service test |
| UEFI loader or disk image | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` | SMP UEFI smoke plus `make test` |
| Framebuffer or input | `./tests/fb_vi_test.sh` | UEFI disk smoke |
| Networking | `./tests/httpd_test.sh`, `./tests/tcp_echo_test.sh`, or `./tests/udp_echo_test.sh` | Full networking smoke set |
| Package payload | `make package-overlay-test` | Package store test |
| Package store | `make package-store-test` | Overlay test plus boot smoke |
| Base-image A/B update store | `./tests/ab_stage_test.sh`, `./tests/ab_activate_test.sh`, `./tests/ab_confirm_test.sh` | `./tests/ab_rollback_test.sh`, `./tests/ab_flush_test.sh` |
| Kernel-image A/B ESP slots | `./tests/uefi_kernel_ab_test.sh`, `./tests/uefi_kstage_test.sh`, `./tests/uefi_kactivate_test.sh`, `./tests/uefi_kconfirm_test.sh` | `./tests/uefi_kattempt_test.sh`, `./tests/uefi_krollback_test.sh`, `UEFI_BOOT=disk ./tests/uefi_boot_test.sh`, `make test` |
| AI model bundle | `./tests/llm_run_test.sh` | `./tests/llm_serve_test.sh` |
| Documentation only | `make docs-test`, `git diff --check` | `make build`, `./tests/boot_test.sh` |

Common networking proofs:

```sh
./tests/httpd_test.sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
./tests/dns_test.sh
./tests/tls_test.sh
./tests/ipv6_smoke_test.sh
```

## Release Candidate Checklist

Before handing a candidate to another operator:

1. Record `git log -1 --oneline`.
2. Build the intended boot artifacts.
3. Boot the intended profile from a clean terminal.
4. Log in with the expected account.
5. Run one command that proves filesystem access, such as `cat /etc/motd`.
6. Run one process or observability command, such as `ps` or `top -b -n 1`.
7. If networking is in scope, run the service or socket test that matches it.
8. If packages are in scope, boot with the intended package image attached.
9. If AI serving is in scope, prove `/health`, `/metrics`, and one `/generate`
   request.
10. Save the serial log and any host-side command output.

## Troubleshooting Updates

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| New command is missing | `build/base.img` was not rebuilt or not attached | Run `make base-image` and boot with the updated image |
| UEFI boot starts old code | `build/swift-os.img` was not rebuilt | Run `make disk` |
| Direct boot starts old code | `build/kernel.elf` was not rebuilt | Run `make build` |
| Package binary disappears after reboot | Package image was not attached again | Reattach payload or package-store image |
| `/tmp` contents disappear | Expected tmpfs behavior | Store only runtime scratch in `/tmp` |
| `llmd` rejects newest model generation | Manifest or payload mismatch | Check model size, SHA-256, and generation layout |
| Network service cannot bind | Missing virtio-net profile, missing `capNet`, or port conflict | Boot with the networking QEMU command and run one service per port |

For deeper diagnosis, see [Troubleshooting](TROUBLESHOOTING.md).

## Future Direction

The intended production direction is signed immutable image updates with A/B
slots and automatic rollback after failed health checks. That model fits the
current two-tier filesystem and deterministic boot design, but it is not the
current implementation.

Until that work lands, treat every SwiftOS update as an explicit artifact
promotion:

1. Build immutable artifacts on the host.
2. Boot the candidate.
3. Verify health with tests and serial evidence.
4. Keep the previous artifact set available.
5. Promote only after the candidate passes the relevant gate.

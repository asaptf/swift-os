# SwiftOS Package Guide

This guide explains the package workflows that work in the current checked-in
SwiftOS tree. It is the practical companion to the package design documents: use
it when you want to build the sample package, inspect artifacts, boot package
content, and collect support evidence.

SwiftOS packages follow the system's immutable-image model. A package is built
on the host, verified on the host, and exposed to the guest as read-only package
content under `/usr`. Target-side `pkg install`, online repositories, live
activation, and rollback are staged work, not current behavior.

Use this guide with:

- [Package Management](PACKAGE_MANAGEMENT.md) for the long-term package manager
  design and roadmap.
- [SWPKG Format](SWPKG_FORMAT.md) for the `.swpkg` container format.
- [Package Store Format](PKGSTORE_FORMAT.md) for the P3a package-store image.
- [Operations Guide](OPERATIONS_GUIDE.md) for QEMU boot profiles.
- [Application Cookbook](APPLICATION_COOKBOOK.md) for package authoring context.
- [Troubleshooting](TROUBLESHOOTING.md) for package failure diagnosis.

## Current Package State

| Capability | Status |
| --- | --- |
| Host `.swpkg` tool | Implemented as `build/swpkg` |
| Deterministic sample package | Implemented as `build/pkghello.swpkg` |
| Payload extraction | Implemented as `build/pkghello-payload.img` |
| Direct payload overlay boot | Implemented and proven by `make package-overlay-test` |
| Package-store bootstrap image | Implemented as `build/pkgstore-pkghello.img` |
| Package-store boot activation | Implemented and proven by `make package-store-test` |
| Target-side `/bin/pkg` install/remove | Not implemented yet |
| Signed online repositories | Not implemented yet |
| Live activation and rollback commands | Not implemented yet |

The current user-visible package fixture is `/usr/bin/pkghello`. It is not part
of the base image. It appears only when a package payload image or package-store
image is attached at boot.

## Mental Model

SwiftOS does not install packages by unpacking files into a mutable root
filesystem. The current model is:

```text
read-only base image
  + active read-only package payloads
  + RAM tmpfs scratch
  = guest VFS namespace
```

The three package artifact types have different jobs:

| Artifact | Built by | Used for |
| --- | --- | --- |
| `build/pkghello.swpkg` | `build/swpkg create` | Host package container with manifest and payload |
| `build/pkghello-payload.img` | `build/swpkg extract-payload` | Sector-aligned read-only payload image attached as a virtio-blk disk |
| `build/pkgstore-pkghello.img` | `build/pkgstore create` | P3a package-store image with payload records and an active generation |

Use the direct payload overlay when you want the simplest package-content boot.
Use the package-store image when you want to test the current activation-record
path.

## Quick Start

Build the kernel, base image, DTB, host package tools, and sample package:

```sh
make build base-image build/virt.dtb
make package-fixture
```

Inspect and verify the `.swpkg` artifact:

```sh
build/swpkg inspect build/pkghello.swpkg
build/swpkg verify build/pkghello.swpkg
```

Inspect the package-store image:

```sh
make package-store-fixture
build/pkgstore inspect build/pkgstore-pkghello.img
```

Run the acceptance tests:

```sh
make package-overlay-test
make package-store-test
```

## Host Tools

### `build/swpkg`

`build/swpkg` is the host-side package container tool.

```sh
make swpkg

build/swpkg create --manifest fixtures/pkghello/manifest.json --root build/pkghello-root --output build/pkghello.swpkg
build/swpkg inspect build/pkghello.swpkg
build/swpkg verify build/pkghello.swpkg
build/swpkg extract-payload build/pkghello.swpkg build/pkghello-payload.img
```

The package fixture target runs the correct sequence for the sample package.
Most users should start with:

```sh
make package-fixture
```

### `build/pkgstore`

`build/pkgstore` is the host-side P3a package-store image tool.

```sh
make pkgstore

build/pkgstore create --package build/pkghello.swpkg --output build/pkgstore-pkghello.img --generation 1
build/pkgstore inspect build/pkgstore-pkghello.img
```

The package-store fixture target builds and inspects the sample store:

```sh
make package-store-fixture
```

## Boot A Direct Package Payload

This is the P2 overlay path. Build the fixture:

```sh
make build base-image build/virt.dtb
make package-fixture
```

Boot QEMU with the base image plus the package payload image:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -drive file=build/pkghello-payload.img,format=raw,if=none,id=swospkg0,readonly=on \
  -device virtio-blk-device,drive=swospkg0 \
  -kernel build/kernel.elf
```

Log in as `root` and run:

```sh
/usr/bin/pkghello
```

Expected output:

```text
pkghello: hello from package overlay
```

Proof:

```sh
make package-overlay-test
```

## Boot A Package Store

This is the P3a package-store activation path. Build the fixture:

```sh
make build base-image build/virt.dtb
make package-store-fixture
```

Boot QEMU with the base image plus the package-store image:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -drive file=build/pkgstore-pkghello.img,format=raw,if=none,id=swpkgstore \
  -device virtio-blk-device,drive=swpkgstore \
  -kernel build/kernel.elf
```

The serial log should include package-store activation markers:

```text
P3: package store active generation
P3: package store payload mounted
```

Log in as `root` and run:

```sh
/usr/bin/pkghello
```

Expected output:

```text
pkghello: hello from package overlay
```

The program text still says "package overlay" because the final VFS result is
the same: a read-only package payload mounted under `/usr`.

Proof:

```sh
make package-store-test
```

## Package Fixture Anatomy

The sample fixture is intentionally small so it can run in every acceptance
gate.

| Path | Purpose |
| --- | --- |
| [fixtures/pkghello/manifest.json](../fixtures/pkghello/manifest.json) | Package manifest used by `build/swpkg create` |
| [userland/pkghello.swift](../userland/pkghello.swift) | Guest program source |
| `build/pkghello-root/usr/bin/pkghello` | Staged package root file |
| `build/pkghello.swpkg` | Host package artifact |
| `build/pkghello-payload.img` | Sector-aligned direct package payload image |
| `build/pkgstore-pkghello.img` | Package-store bootstrap image |

Package files install under `/usr`. The current package verifier rejects package
payload paths outside `/usr`.

## Creating Your Own Local Package Fixture

For a local experiment, follow the fixture shape:

1. Build a static SwiftOS executable.
2. Stage it under a package root, usually `build/<name>-root/usr/bin/<name>`.
3. Write a manifest with `target: "swift-os"` and static linkage metadata.
4. Run `build/swpkg create`.
5. Run `build/swpkg verify`.
6. Extract a payload image or create a package-store image.
7. Boot QEMU with the resulting image and run the program from `/usr/bin`.

Keep current package experiments simple:

- Install real executable paths such as `/usr/bin/tool`.
- Do not rely on symlinks, maintainer scripts, or dynamic libraries.
- Do not expect dependencies to be solved.
- Do not expect files to persist in `/tmp` after reboot.
- Do not treat `.swpkg` reserved signature fields as implemented signatures.

For reusable application recipes, see
[APPLICATION_COOKBOOK.md](APPLICATION_COOKBOOK.md).

## Verification Matrix

Run the narrowest proof for the path you changed:

| Area | Command |
| --- | --- |
| Host `.swpkg` create/inspect/verify | `make package-fixture` |
| Host package-store create/inspect | `make package-store-fixture` |
| Direct payload overlay boot | `make package-overlay-test` |
| Package-store activation boot | `make package-store-test` |
| Full package tooling in the full gate | `make test` |

The underlying host tests are:

- [tests/swpkg_tool_test.swift](../tests/swpkg_tool_test.swift)
- [tests/pkgstore_tool_test.swift](../tests/pkgstore_tool_test.swift)

The QEMU tests are:

- [tests/package_overlay_test.sh](../tests/package_overlay_test.sh)
- [tests/pkg_store_boot_test.sh](../tests/pkg_store_boot_test.sh)

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `/usr/bin/pkghello` is missing | The package image was not attached, the wrong image was attached, or the fixture is stale | Run `make package-fixture`; boot with either `build/pkghello-payload.img` or `build/pkgstore-pkghello.img` |
| QEMU boots but no package-store markers appear | The package-store image was not attached with the expected virtio-blk device | Use the package-store boot profile or run `make package-store-test` |
| `build/swpkg verify` fails | Manifest and payload do not match, hashes are stale, or paths are outside `/usr` | Rebuild the package root and run `make package-fixture` |
| `build/pkgstore inspect` fails | Store image is stale, missing, or corrupt | Rebuild with `make package-store-fixture` |
| Guest command says `/bin/pkg` is missing | Target-side package manager is not implemented yet | Use host tools and boot-time package images |
| Package content disappears after reboot | The package image was not attached to the new boot | Attach the payload image or package-store image each time |

For general package diagnosis, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#package-problems).

## Security And Product Limits

Current limits that matter for package use:

- Package content is read-only in the guest.
- The package store is read by the kernel at boot; target-side writes are not
  implemented yet.
- `.swpkg` hashes prove container integrity, not publisher identity.
- Package signatures, repository catalogs, online installs, and rollback
  commands are future milestones.
- Packages cannot grant themselves process capabilities. Authority remains a
  property of the process identity and launch path.
- The base image remains immutable and wins over package content unless future
  conflict rules explicitly allow replacement.

Do not use current package images as a production software update mechanism.
They are the verified bring-up path for the package format, VFS overlay model,
and package-store activation substrate.

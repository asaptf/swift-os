# Package Store Format

`SWPKGST1` is the SwiftOS package-store disk image format. It is the current
activation substrate for package payloads: the kernel can scan one package-store
block device, find the active generation, and mount the referenced package
payload images under `/usr`. The target-side `pkg install FILE` path can also
append a new payload and activation generation to a writable store and
live-mount it without reboot.

Use this document with:

- [Package Guide](PACKAGE_GUIDE.md) for operator-facing package workflows.
- [SWPKG Package Format](SWPKG_FORMAT.md) for the package container that feeds
  the store.
- [Static Package Repository](PKGREPO_FORMAT.md) for signed repository catalogs.
- [Base Image](BASE_IMAGE.md) for the immutable root filesystem.
- [Command Reference](COMMAND_REFERENCE.md) for target-side `pkg` commands.
- [Host Tool Reference](HOST_TOOL_REFERENCE.md) for `build/pkgstore` syntax.

## User Model

The package store is not the immutable base image. It is an additional
virtio-blk disk that contains package payload generations.

| Path Or Artifact | Role | Writable In Current Tests |
| --- | --- | --- |
| `build/base.img` | Immutable root filesystem, trust roots, `/bin/pkg` | No |
| `build/pkgstore-pkghello.img` | Preseeded active package generation | No in the boot fixture |
| `build/pkgstore-install.img` | Empty package-store image used by local install tests | Yes |
| `/packages/pkghello.swpkg` | Sample package staged inside the base image | No |
| `/usr/bin/pkghello` | Package-provided executable after activation | No, mounted from payload |

The active package generation layers package payloads beside the base image.
Package files are read-only after activation. `/bin/pkg files NAME` can inspect
the file paths in an active package payload. The current store does not provide
remove, rollback, garbage collection, version solving, or history commands; those
are package-manager roadmap items.

## Current Capabilities

| Capability | Current State |
| --- | --- |
| Initialize an empty sector-aligned store | `build/pkgstore init` |
| Create a deterministic preseeded store from one or more `.swpkg` files | `build/pkgstore create` |
| Inspect active generation, payload records, and activation records | `build/pkgstore inspect` |
| Boot a preseeded active generation | `make package-store-test` |
| Install a local `.swpkg` into a writable store | `make package-local-install-test` |
| List active package records in the guest | `pkg list` |
| List files in an active package payload | `pkg files NAME` |
| Install by name from signed repository fixtures into a writable store | `make package-repo-install-test` and seed repository tests |
| Store-level signatures or encryption | Not implemented |
| Remove, rollback, garbage collection, package history | Not implemented |

## Quick Start

Build the tool and sample package:

```sh
make pkgstore package-fixture
```

Create and inspect a preseeded store:

```sh
build/pkgstore create \
  --package build/pkghello.swpkg \
  --output build/pkgstore-pkghello.img \
  --generation 1
build/pkgstore inspect build/pkgstore-pkghello.img
```

Expected inspection shape:

```text
active_generation: 1
payloads:
  pkghello-1.0.0_1 <bytes> <sha256>
activations:
  1
```

Create an empty writable store:

```sh
build/pkgstore init --output build/pkgstore-empty.img --size 1048576
```

Run the checked boot activation and live local install paths:

```sh
make package-store-test
make package-local-install-test
```

## Image Layout

All integers are little-endian. The image is sector-aligned to 512 bytes.

```text
pkgstore.img
  superblock             512 bytes
  record header          128 bytes
  record data            padded to next 512-byte boundary
  record header          128 bytes
  record data            padded to next 512-byte boundary
  ...
```

Superblock v1:

```text
0   u8[8]   magic: "SWPKGST1"
8   u32     version: 1
12  u32     header_size: 512
16  u64     first_record_offset: 512
24  ...     reserved zeroes
```

Record header v1:

```text
0    u8[8]   magic: "SWPSREC1"
8    u32     version: 1
12   u32     header_size: 128
16   u32     kind
20   u32     reserved
24   u64     generation
32   u64     data_offset
40   u64     data_size
48   u8[32]  data_sha256
80   u8[32]  package name, NUL padded
112  u8[16]  package version_revision, NUL padded
```

Record data starts immediately after its 128-byte header. The next record starts
at `align_up(data_offset + data_size, 512)`.

Record kinds:

| Kind | Name | Data |
| --- | --- | --- |
| `1` | Payload | Uncompressed `SWOSBASE` v2 package payload image from a verified `.swpkg` |
| `2` | Activation | Compact activation data listing payload hashes for one generation |
| `3` | Active pointer | Empty data; `generation` selects the active activation |

The scanner reads records in order and stops at the first non-record magic or
invalid record header. The last active-pointer record seen during the scan
selects the active activation generation.

## Activation Data

Activation data v1:

```text
0   u8[8]   magic: "SWPACT01"
8   u32     version: 1
12  u32     payload_count
16  entries[payload_count]
```

Each activation entry is 80 bytes:

```text
0   u8[32]  payload_sha256
32  u8[32]  package name, NUL padded
64  u8[16]  package version_revision, NUL padded
```

The kernel matches activation entries to payload records by the 32-byte payload
hash stored in the record header. A payload is mounted only when its hash is
referenced by the active activation generation.

When target-side `pkg install FILE` appends a package, it:

1. Verifies the `.swpkg` header, section order, reserved signature fields, and
   manifest/payload SHA-256 values.
2. Confirms the payload starts with `SWOSBASE` version 2.
3. Appends a payload record for the package payload.
4. Builds a new activation record that keeps already active payloads and adds
   the new payload when it is not already active.
5. Appends a new active-pointer record.
6. Publishes the new active generation and asks the VFS to mount active package
   payloads.

## Host Tool

`build/pkgstore` has three commands:

```text
pkgstore init --output <store.img> [--size BYTES]
pkgstore create --package <pkg.swpkg> [--package <pkg.swpkg> ...] --output <store.img> [--generation N]
pkgstore inspect <store.img>
```

Examples:

```sh
make pkgstore package-fixture
build/pkgstore init --output build/pkgstore-empty.img --size 1048576
build/pkgstore create --package build/pkghello.swpkg --output build/pkgstore-pkghello.img --generation 1
build/pkgstore inspect build/pkgstore-pkghello.img
```

`pkgstore create` validates each input `.swpkg` before copying its payload into
the store image. It requires package target `swift-os`, architecture `aarch64`,
and static linkage. It accepts repeated `--package` flags and writes one
activation generation containing all provided packages.

## QEMU Attachment

A preseeded package-store boot attaches the store as an additional virtio-blk
disk:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -drive file=build/pkgstore-pkghello.img,format=raw,if=none,id=swpkgstore,readonly=on \
  -device virtio-blk-device,drive=swpkgstore \
  -kernel build/kernel.elf
```

A live install test attaches a writable store image. Do not pass `readonly=on`
for the writable install store:

```sh
make package-local-install-fixture
make package-local-install-test
```

Inside the guest:

```sh
pkg install /packages/pkghello.swpkg
pkg list
pkg files pkghello
/usr/bin/pkghello
```

Expected serial markers include:

```text
P3: package store active generation
P3b: package installed and activated
```

## Current Limits

- One package-store block device is used.
- The kernel scans at most 128 records.
- The kernel tracks at most 32 payload records and 32 activation records.
- Activation data is limited to 4096 bytes.
- An active generation can reference at most 32 payloads.
- Target-side mutation is serialized; concurrent install attempts fail rather
  than interleave.
- Target-side install is root-only in the current principal model.
- Store records are append-only; current user commands do not remove old records
  or reclaim space.
- Boot-time store scanning trusts the attached store image as a local artifact.
  Store-level publisher signatures are not implemented; network publisher
  authenticity comes from signed repository catalogs before packages are
  installed.
- Package-store shared state has an SMP lock boundary and S4d readiness checks,
  but the package manager is still intentionally narrow.

## Verification Matrix

| Concern | Command |
| --- | --- |
| Host tool build | `make pkgstore` |
| Empty store init, deterministic create, inspect output | `build/pkgstore_tool_test` after compiling `tests/pkgstore_tool_test.swift` |
| Sample package-store fixture | `make package-store-fixture` |
| Preseeded boot activation | `make package-store-test` |
| Writable local install store | `make package-local-install-fixture` and `make package-local-install-test` |
| Repository install into writable store | `make package-repo-install-test` |
| Ports seed repository install into writable store | `make package-ports-seed-repo-install-test` |
| Documentation and link coverage | `make docs-test` |

For a narrow package-store format documentation change, run:

```sh
make pkgstore package-fixture package-store-fixture
/usr/bin/swiftc tests/pkgstore_tool_test.swift -o build/pkgstore_tool_test
build/pkgstore_tool_test
make docs-test
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `pkgstore: bad store magic` | The input is not a package-store image | Rebuild with `build/pkgstore init` or `build/pkgstore create` |
| `pkgstore: store size must be sector-aligned` | `pkgstore init --size` was not a multiple of 512 | Use a sector-aligned size such as `1048576` |
| `pkgstore: at least one --package is required` | `pkgstore create` was called without packages | Pass one or more `--package` arguments |
| `pkgstore: package signatures are reserved` | Input `.swpkg` has non-zero reserved signature fields | Recreate an unsigned v1 `.swpkg` and distribute it through a signed repository catalog |
| `pkgstore: manifest SHA-256 mismatch` or `payload SHA-256 mismatch` | Input `.swpkg` was modified after creation | Rebuild the package |
| `build/pkgstore inspect` shows `active_generation: 0` | The store is empty or has no active-pointer record | Use `pkgstore create` or run an install into a writable store |
| QEMU boots but `/usr/bin/pkghello` is missing | The store image was not attached, is stale, or has no active generation | Rebuild with `make package-store-fixture` and attach `build/pkgstore-pkghello.img` |
| `pkg install FILE` fails in the guest | Store disk is missing, read-only, full, corrupt, or the caller is not root | Attach `build/pkgstore-install.img` writable and install as root |
| Package content disappears after reboot | The updated writable store image was not reused on the next boot | Boot again with the same package-store image |

## Security Notes

- The package store is an activation log, not a signed repository. It records
  hashes and generations, but it is not currently an authenticated on-disk
  trust boundary by itself.
- `.swpkg` hashes are verified before host `pkgstore create` copies payloads and
  before target-side `pkg install FILE` appends payloads.
- Signed repository catalogs authenticate network-distributed package metadata
  and package hashes before the local install path is reused.
- Payloads are mounted read-only after activation.
- There are no package maintainer scripts in the current package model.
- The immutable base image remains the source for early boot, identity, trust
  roots, and `/bin/pkg`.

## Source Of Truth

The implementation and tests that define this document are:

- `tools/pkgstore.swift` for host-side store init, create, and inspect.
- `kernel/pkg/store.swift` for boot-time scanning, target-side append, active
  generation publishing, and SMP lock-boundary counters.
- `tools/swpkg.swift` for `.swpkg` validation before payloads enter the store.
- `kernel/vfs/vfs.swift` for mounting active package-store payloads.
- `tests/pkgstore_tool_test.swift` for deterministic host tool behavior.
- `tests/pkg_store_boot_test.sh` for boot activation.
- `tests/pkg_local_install_test.sh` for target-side local install.
- `tests/pkg_repo_install_test.sh` and seed repository tests for repository
  installs that reuse the package-store activation path.

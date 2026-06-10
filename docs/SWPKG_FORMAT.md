# SWPKG Package Format

`.swpkg` is the SwiftOS binary package artifact. It is the unit produced by the
host package tools, published in signed package repositories, staged into
package-store images, and installed by the current target-side `pkg install`
paths.

The current container format is `SWPKG001` version 1. It is deterministic,
uncompressed, statically linked by convention, and intentionally small enough
for the target-side parser. A `.swpkg` proves container integrity through
SHA-256 hashes; publisher identity is supplied by the signed repository catalog
when the package is distributed through `pkgrepo`.

Use this document with:

- [Package Guide](PACKAGE_GUIDE.md) for build, inspect, boot, and install
  workflows.
- [Package Store Format](PKGSTORE_FORMAT.md) for writable package-store images.
- [Static Package Repository](PKGREPO_FORMAT.md) for signed HTTP repositories.
- [Package Build Automation Guide](PACKAGE_BUILD_AUTOMATION.md) and
  [Ports Seed Catalog](../ports/README.md) for recipe-driven packages.
- [Host Tool Reference](HOST_TOOL_REFERENCE.md) for command syntax.

## Current Capabilities

| Capability | Current State |
| --- | --- |
| Create deterministic `.swpkg` artifacts | Implemented by `build/swpkg create` |
| Inspect package metadata and file records | Implemented by `build/swpkg inspect` |
| Verify header hashes, manifest schema, payload image, and file records | Implemented by `build/swpkg verify` |
| Extract a block-device-ready payload image | Implemented by `build/swpkg extract-payload` |
| Install from a local package staged in the base image | Implemented by `/bin/pkg install /packages/pkghello.swpkg` |
| Install by name from signed repository fixtures | Implemented by `/bin/pkg update` and `/bin/pkg install NAME` |
| Payload path policy | Package files must live under `/usr` |
| Package signatures inside `.swpkg` | Reserved; must be empty in v1 |
| Compression, maintainer scripts, upgrades, remove, version solving | Not implemented |

## Quick Start

Build the host tool and sample package:

```sh
make swpkg package-fixture
```

Inspect and verify the sample package:

```sh
build/swpkg inspect build/pkghello.swpkg
build/swpkg verify build/pkghello.swpkg
```

Expected verification output:

```text
OK: pkghello-1.0.0_1
```

Extract the payload image for direct overlay tests:

```sh
build/swpkg extract-payload build/pkghello.swpkg build/pkghello-payload.img
```

Install the sample package inside SwiftOS through the checked local install
path:

```sh
make package-local-install-test
```

Inside the guest, the equivalent command is:

```sh
pkg install /packages/pkghello.swpkg
/usr/bin/pkghello
```

## Container Layout

All integer fields are little-endian. Offsets are absolute byte offsets from the
start of the `.swpkg` file.

```text
*.swpkg
  header              fixed 128-byte SWPKG001 header
  manifest.json       canonical UTF-8 JSON package manifest
  payload.swosbase    uncompressed packed read-only payload image
  signature           reserved; absent in v1
```

Header v1:

```text
0    u8[8]   magic: "SWPKG001"
8    u32     version: 1
12   u32     header_size: 128
16   u64     manifest_offset
24   u64     manifest_size
32   u64     payload_offset
40   u64     payload_size
48   u8[32]  manifest_sha256
80   u8[32]  payload_sha256
112  u64     signature_offset
120  u64     signature_size
```

The current writer emits:

- `manifest_offset == 128`;
- `payload_offset == manifest_offset + manifest_size`;
- `signature_offset == 0`;
- `signature_size == 0`;
- no padding between the header, manifest, and payload.

The verifier rejects bad magic, bad version, bad header size, non-empty reserved
signature fields, bad section order, out-of-bounds manifest or payload ranges,
and SHA-256 mismatches for the manifest or payload byte ranges.

## Manifest JSON

The manifest is a canonical JSON object written with sorted keys. The input file
may be hand-written, but `swpkg create` normalizes it before writing the package.
In particular, the generated package file list replaces the input `files` array
with records derived from the staged payload tree.

Required or defaulted top-level fields:

| Field | Meaning | Current Rule |
| --- | --- | --- |
| `format` | Manifest format version | Defaults to `1`; must be `1` |
| `name` | Package name | Required, non-empty |
| `version` | Upstream/package version | Required, non-empty |
| `revision` | SwiftOS package revision | Defaults to `1` |
| `summary` | Human-readable summary | Preserved when present |
| `license` | SPDX-like license strings | Defaults to `[]` |
| `arch` | Target architecture | Defaults to `aarch64`; must be `aarch64` |
| `target` | Target OS | Defaults to `swift-os`; must be `swift-os` |
| `abi` | ABI contract | Defaults to `swos-0`, syscall `1`, `newlib-4.6-swos`, static linkage |
| `depends` | Runtime dependencies | Defaults to `[]`; repository install resolves names by catalog metadata |
| `provides` | Provided package names | Defaults to `[name]` |
| `conflicts` | Conflicting package names | Defaults to `[]`; not enforced by current install paths |
| `capabilities` | Requested process/service authority | Defaults to empty sets; recorded for future policy |
| `files` | Installed files | Generated from the payload tree |

Minimal input manifest:

```json
{
  "format": 1,
  "name": "helloapp",
  "version": "1.0.0",
  "summary": "Small SwiftOS package",
  "arch": "aarch64",
  "target": "swift-os",
  "abi": {
    "os": "swos-0",
    "syscall": 1,
    "libc": "newlib-4.6-swos",
    "linkage": "static"
  },
  "depends": [],
  "provides": ["helloapp"],
  "conflicts": []
}
```

Generated file records look like this:

```json
{
  "path": "/usr/bin/helloapp",
  "mode": "0755",
  "sha256": "8f7d...",
  "size": 12345
}
```

`mode` is a four-digit octal string. The hash is the SHA-256 digest of the file
payload bytes, not the digest of a tar entry or host filesystem metadata.

## Payload Image

The payload is an uncompressed packed read-only filesystem image in the
`SWOSBASE` family. The current `swpkg` writer emits payload images with:

- magic `SWOSBASE`;
- version `2`;
- 64-byte header;
- 40-byte entries;
- UTF-8 relative paths;
- NUL-terminated path strings;
- concatenated file payload bytes.

Package payload paths must live under `/usr`. The staged root therefore contains
paths such as:

```text
usr/bin/pkghello
usr/share/nginx/swiftos-nginx.version
usr/etc/ssl/cert.pem
```

Those paths become guest-visible absolute paths such as
`/usr/bin/pkghello`. Files outside `/usr` are rejected by `swpkg create`.

Executable mode is inferred from path prefixes:

| Payload Prefix | Generated Mode |
| --- | --- |
| `usr/bin/` | `0755` |
| `usr/sbin/` | `0755` |
| `usr/libexec/` | `0755` |
| Other files | `0644` |
| Directories | `0755` |

`extract-payload` verifies the package first, then writes the payload padded to a
512-byte sector boundary so it can be attached directly as a QEMU block device.
The `.swpkg` container itself is not the image mounted by the VFS; the verified
payload image is.

## Create A Package Manually

Create a small staged root:

```sh
rm -rf build/helloapp-root
mkdir -p build/helloapp-root/usr/bin
printf '#!/bin/sh\necho hello from package\n' > build/helloapp-root/usr/bin/helloapp
chmod 755 build/helloapp-root/usr/bin/helloapp
```

Create `build/helloapp-manifest.json`:

```json
{
  "format": 1,
  "name": "helloapp",
  "version": "1.0.0",
  "revision": 1,
  "summary": "Small package-format example",
  "license": ["swift-os-example"],
  "arch": "aarch64",
  "target": "swift-os",
  "abi": {
    "os": "swos-0",
    "syscall": 1,
    "libc": "newlib-4.6-swos",
    "linkage": "static"
  },
  "depends": [],
  "provides": ["helloapp"],
  "conflicts": []
}
```

Create and verify the package:

```sh
make swpkg
build/swpkg create \
  --manifest build/helloapp-manifest.json \
  --root build/helloapp-root \
  --output build/helloapp.swpkg
build/swpkg inspect build/helloapp.swpkg
build/swpkg verify build/helloapp.swpkg
```

This example demonstrates the container mechanics. Real guest execution requires
a SwiftOS-compatible static AArch64 ELF, so use [Application Cookbook](APPLICATION_COOKBOOK.md)
or [Porting Guide](PORTING_GUIDE.md) for production packages.

## Distribution And Install Paths

The same `.swpkg` artifact can flow through several checked paths:

| Path | Artifact Flow | Verification |
| --- | --- | --- |
| Direct host inspection | `build/swpkg verify PACKAGE` | Header, manifest, payload, and file records |
| Direct payload overlay | `build/swpkg extract-payload PACKAGE payload.img`, then attach payload image | Package verification before extraction; VFS mounts payload read-only |
| Package-store image | `build/pkgstore create --package PACKAGE --output store.img` | Package verifier plus package-store record checks |
| Local target install | `.swpkg` staged in `/packages`, then `pkg install FILE` | Target-side `.swpkg` parser and writable package store |
| Signed repository install | `pkgrepo create --package PACKAGE`, then `pkg install NAME` | Signed catalog, catalog package hash, `.swpkg` verification, dependency names |

Repository signatures authenticate the catalog and package hash metadata. The
v1 `.swpkg` signature fields remain reserved and empty.

## Verification Matrix

| Concern | Command |
| --- | --- |
| Host tool build | `make swpkg` |
| Deterministic create, inspect, verify, sector-aligned extraction, corrupt package rejection | `make test` or `tests/swpkg_tool_test.swift` through the `make test` host gate |
| Sample package creation | `make package-fixture` |
| Direct payload overlay boot | `make package-overlay-test` |
| Package-store image creation and boot activation | `make package-store-test` |
| Target-side local install | `make package-local-install-test` |
| Signed repository install by package name | `make package-repo-install-test` |
| Ports package creation and verification | `make ports-recipe-test` plus the relevant `ports-*-repo-fixture` target |
| Eight-package seed repository install | `make package-ports-seed-repo-install-test` |

For a narrow format-only edit, run:

```sh
make swpkg package-fixture
/usr/bin/swiftc tests/swpkg_tool_test.swift -o build/swpkg_tool_test
build/swpkg_tool_test
make docs-test
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `swpkg: package paths must live under /usr` | The staged root contains a file outside `usr/` | Move package content under `usr/bin`, `usr/share`, `usr/etc`, or another `/usr` path |
| `swpkg: manifest SHA-256 mismatch` | Manifest bytes changed after the header was written | Recreate the package |
| `swpkg: payload SHA-256 mismatch` | Payload bytes changed after the header was written | Recreate the package |
| `swpkg: package signatures are reserved for a later milestone` | Signature fields are non-zero | Use an unsigned v1 `.swpkg` and publish through a signed repository catalog |
| `swpkg: manifest file count does not match payload` | Manifest file records do not match the payload image | Let `swpkg create` regenerate `files` from the staged root |
| `swpkg: payload missing /path` | A manifest file path is not present in the payload image | Rebuild from a clean staged root |
| `pkg install FILE` cannot open the package | The guest path is wrong or the package was not staged into the base image/package source | Use `/packages/pkghello.swpkg` for the sample fixture or rebuild the base image |
| Installed command is not executable | File landed outside executable prefixes or has the wrong mode | Install binaries under `/usr/bin`, `/usr/sbin`, or `/usr/libexec` |

## Security Notes

- `.swpkg` v1 hashes protect against accidental or malicious byte changes within
  the package file, but they do not identify a publisher.
- Signed repository catalogs provide publisher authenticity for network
  distribution. Keep catalog signing keys separate from local package build
  scratch files.
- Package payloads are read-only when mounted. Current package install paths
  activate package content through the package store rather than mutating the
  immutable base image.
- There are no maintainer scripts in v1. Package installation should not run
  arbitrary post-install code.
- Current package paths are constrained to `/usr`; base-system files under
  `/bin`, `/etc`, `/models`, and `/www` remain base-image owned.

## Source Of Truth

The implementation and tests that define this document are:

- `tools/swpkg.swift` for the container writer, reader, verifier, and extractor.
- `tools/packfs.swift` for the packed payload image format.
- `fixtures/pkghello/manifest.json` for the sample manifest.
- `Makefile` targets `swpkg`, `package-fixture`, and package test targets.
- `tests/swpkg_tool_test.swift` for deterministic output, inspection, payload
  extraction, and corrupt package rejection.
- `userland/pkg.swift` and package install tests for target-side local and
  repository install behavior.

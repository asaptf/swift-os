# SWPKG Format

Developer notes for package-management P1: the host-only `.swpkg` artifact
format and verifier.

P1 defines a deterministic package container that host tools can build,
inspect, and verify. It does not add a target-side package manager, package
store, VFS overlay, repository catalog, or kernel parser.

## Goals

- Produce one portable binary artifact per package.
- Keep the container small enough for a later target-side parser.
- Reuse the packed read-only image model documented in `BASE_IMAGE.md`.
- Make host tests catch malformed manifests, wrong hashes, bad payload images,
  and non-deterministic package output.

## Non-Goals

- No Linux, FreeBSD, `.deb`, `.rpm`, APK, or pkgsrc compatibility.
- No mutable `/usr` installation.
- No dependency solving, repository metadata, downloads, activation, rollback,
  or garbage collection.
- No compression in P1.
- No maintainer scripts.
- No implemented signatures. Signature fields are reserved and must be empty.

## Container Layout

All integer fields are little-endian. Offsets are from the start of the file.

```text
*.swpkg
  header              fixed 128 bytes
  manifest.json       canonical UTF-8 JSON package manifest
  payload.swosbase    uncompressed packed read-only image
  signature           reserved for later milestones; absent in P1
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

For P1, `manifest_offset` must be `128`, `payload_offset` must be
`manifest_offset + manifest_size`, and `signature_offset` and `signature_size`
must both be zero. A P1 writer should not add padding or trailing bytes.

The header hashes are host-side consistency checks, not authenticity.

## Manifest JSON

The manifest is UTF-8 JSON. The builder emits canonical JSON with sorted object
keys. Hand-written input manifests may omit generated file sizes or hashes; the
builder fills deterministic defaults and rewrites `files` from the payload tree.

P1 packages must declare `target: "swift-os"` and `abi.linkage: "static"`.
`depends`, `provides`, and `conflicts` are recorded for future milestones, but
P1 does not solve or enforce dependencies.

## Payload Format

`payload.swosbase` is an uncompressed packed read-only image using the same
format family as `SWOSBASE`: magic `SWOSBASE`, version 2, little-endian header
and entries, UTF-8 paths relative to `/`, NUL-terminated path strings, and
concatenated regular-file data.

The manifest uses absolute paths such as `/usr/bin/pkghello`; the payload image
stores the corresponding relative path `usr/bin/pkghello`. P1 packages install
under `/usr`.

## Verification Rules

A P1 host verifier accepts a package only if all of these pass:

- Header magic, version, header size, offsets, sizes, and reserved signature
  fields are valid.
- Manifest and payload byte ranges are in bounds and in the P1 order.
- `sha256(manifest bytes)` equals `manifest_sha256`.
- `sha256(payload bytes)` equals `payload_sha256`.
- The manifest parses as JSON and satisfies the required schema.
- The payload parses as a valid `SWOSBASE` image.
- Every manifest file exists in the payload with matching mode, size, and file
  hash.
- The payload does not contain regular files omitted from `manifest.files`.

These rules prove container integrity and reproducibility. They do not prove
publisher identity.

## Boundary With Later Milestones

The `.swpkg` container format began as the P1 host tooling milestone. It creates
and verifies package artifacts; other milestones decide how those artifacts
become visible in the guest.

Current related package milestones:

- P2 mounts verified payload images as read-only VFS overlays.
- P3a adds the persistent package-store image and boot activation.
- P3b adds local target-side `pkg install FILE` and `pkg list` for `.swpkg`
  files staged in the guest.
- P4 completes the local package lifecycle with files, remove, rollback, and
  stronger diagnostics.
- P5 adds signed repository catalogs and network fetch.

For the package-store image layout, see
[PKGSTORE_FORMAT.md](PKGSTORE_FORMAT.md).

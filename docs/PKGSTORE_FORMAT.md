# Package Store Format

Developer notes for the P3 package-store bootstrap image.

P3a adds the first persistent-store substrate: a block image that carries package
payload records, activation records, and an active-generation pointer. The
kernel can discover this image on virtio-blk, read the active generation at boot,
and mount the selected payload images into the VFS package namespace.

This is not yet the full target-side installer. `/bin/pkg` will later verify
local or downloaded `.swpkg` files, append records to this store, and switch the
active generation.

## Image Layout

All integers are little-endian. The image is sector-aligned to 512 bytes.

```text
pkgstore.img
  superblock             512 bytes
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
80   u8[32]  name, NUL padded
112  u8[16]  version, NUL padded
```

Record kinds:

- `1`: payload image. Data is an uncompressed `SWOSBASE` package payload image.
- `2`: activation. Data is a compact activation payload.
- `3`: active pointer. `generation` selects the active activation record.

The current kernel parser scans records in order, remembers payload records and
activation records, then uses the last active-pointer record to choose one
activation generation.

## Activation Data

Activation data v1:

```text
0   u8[8]   magic: "SWPACT01"
8   u32     version: 1
12  u32     payload_count
16  entries[payload_count]
```

Each entry is 80 bytes:

```text
0   u8[32]  payload_sha256
32  u8[32]  package name, NUL padded
64  u8[16]  package version_revision, NUL padded
```

The kernel uses the payload SHA-256 bytes as a record identifier and mounts only
payload records referenced by the active activation.

## Current Limits

- One package-store block device is used.
- Up to 32 records, 8 payload records, and 8 activation records are scanned.
- Activation data is limited to 4096 bytes.
- The kernel treats the store as read-only in P3a.
- Target-side append, active-generation update, rollback, garbage collection,
  and signatures remain P3b/P4 work.

## Host Tool

`tools/pkgstore.swift` creates and inspects bootstrap store images:

```sh
make pkgstore package-fixture
build/pkgstore create --package build/pkghello.swpkg --output build/pkgstore-pkghello.img --generation 1
build/pkgstore inspect build/pkgstore-pkghello.img
```

The package-store QEMU test boots with `build/base.img` plus
`build/pkgstore-pkghello.img` and runs `/usr/bin/pkghello` from the active store
generation.

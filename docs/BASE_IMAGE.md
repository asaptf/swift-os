# Packed Base Image

M11 moves the read-only base filesystem out of Swift literals and onto disk.
The first step is a deterministic host-built image that the future virtio-blk
driver can read without a complex parser.

## Format v1

All integer fields are little-endian.

- Header: 64 bytes.
- Magic: `SWOSBASE`.
- Version: `1`.
- Entry size: 40 bytes.
- Entry kinds: `1` directory, `2` regular file.
- Paths: UTF-8 paths relative to `/`, without a leading slash.
- String table: NUL-terminated path strings.
- Data section: concatenated regular-file bytes.

Header layout:

```text
0   u8[8]  magic
8   u32    version
12  u32    header_size
16  u32    entry_size
20  u32    entry_count
24  u64    entries_offset
32  u64    strings_offset
40  u64    strings_size
48  u64    data_offset
56  u64    data_size
```

Entry layout:

```text
0   u32    path_offset
4   u32    path_length
8   u32    kind
12  u32    flags
16  u64    data_offset
24  u64    data_size
32  u32    mode
36  u32    reserved
```

The image is built by:

```sh
make base-image
```

The seed tree is `base/`; output is `build/base.img`. `make test` runs a host
parser over the image and verifies the files currently mirrored in the in-kernel
VFS (`/etc/motd`, `/etc/hostname`, `/readme.txt`, `/hello.txt`, `/bin/ps`).

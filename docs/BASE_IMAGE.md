# Packed Base Image

SwiftOS boots a small kernel and mounts the rest of the root filesystem from a
deterministic, read-only packed image. That image is `build/base.img`. It holds
the base `/bin` programs, default `/etc` files, static web content, package
trust roots, sample packages, and model bundles used by the checked-in product
profiles.

The current base image format is signed `SWOSBASE` version 3. Older unsigned
version 2 packed images still exist for package payload overlays, but the root
base image must be signed v3 and is refused by the kernel if its metadata
signature is invalid.

Use this document with:

- [Installation Guide](INSTALLATION_GUIDE.md) for boot profiles.
- [Update And Rollback Guide](UPDATE_GUIDE.md) and [Update Store](UPDATE_STORE.md)
  for checked A/B base-image updates.
- [Application Cookbook](APPLICATION_COOKBOOK.md) for staging native programs.
- [Package Guide](PACKAGE_GUIDE.md) for package payloads and package-store
  images that layer beside the base image.
- [AI Hosting Guide](AI_HOSTING_GUIDE.md) for model bundles staged under
  `/models`.

## User Model

The base image is the immutable system root:

| Path | Source | Writable In Guest | Purpose |
| --- | --- | --- | --- |
| `/bin` | Staged EL0 programs | No | Native Swift tools, diagnostics, services, update commands, package manager, busybox |
| `/etc` | `base/etc` plus generated trust roots | No | Login identity store, hostname, package repository trust, model signing trust |
| `/www` | `base/www` | No | Static content served by `/bin/httpd` |
| `/models` | `models/` build artifacts | No | Local LLM files and signed serving bundles |
| `/packages` | Build fixtures | No | Sample `.swpkg` files for local package install tests |
| `/tmp` | RAM tmpfs, not the base image | Yes | Scratch files that disappear on reboot |

Changes made inside `/bin`, `/etc`, `/www`, `/models`, or `/packages` in a
running guest do not persist because those paths are read-only. To make a
change durable, rebuild `build/base.img`, provide a package payload, or use a
future persistent storage profile when one exists.

## Choose A Base Image Workflow

Start from the durable content you need to change. The running guest is the
verification target, but the source of truth is always a host-side input.

| Need | Edit or generate | Rebuild | Focused proof |
| --- | --- | --- | --- |
| Change login text, hostname, SSH preflight keys, boot services, or identity seed files | `base/etc/*`; `SSHD_HOST_SEED_FILE=PATH`, `SSHD_KEX_SEED_FILE=PATH`, and `SSHD_AUTHORIZED_KEYS_FILE=PATH` for deploy-specific SSHD keys and KEX seed material; `SWOS_SERVICES_FILE=PATH` for custom boot services | `make base-image` | `./tests/console_login_test.sh` for identity, `./tests/sshd_transport_test.sh`, `make sshd-host-key-rotation-test`, `make sshd-kex-seed-test`, `make sshd-authorized-keys-test`, or `make sshd-supervision-test` for SSHD, `./tests/boot_test.sh` for general boot |
| Stage static cloud IPv6 config | `NET_IPV6_CONFIG_FILE=PATH` with `address=<ipv6>/64` and `gateway=<link-local-ipv6>` lines | `make base-image` | `make net-static-ipv6-test` |
| Change static HTTP content | `base/www/` | `make base-image` | `./tests/httpd_test.sh` |
| Add or update a default `/bin` command | `userland/`, Makefile build rules, base staging rule | `make build base-image` | Command-specific QEMU test plus command reference update |
| Update package repository trust or defaults | `build/pkgrepo-root.pub`, `PKG_DEFAULT_REPO_URL`, `PKG_DEFAULT_DNS_SERVER` | `make base-image` or custom `BASE_IMG=... base-image` | Matching package repository install test |
| Update local package-install sample payload | `build/pkghello.swpkg` or package fixture inputs | `make package-fixture`, then `make base-image` | `make package-local-install-test` |
| Update local inference files | `models/stories260K.bin`, `models/tok512.bin` | `make model`, then `make base-image` | `./tests/llm_run_test.sh` |
| Update verified serving bundle generations | `models/stories15M-q8.bin`, `models/tokenizer.bin`, generated manifests | `make model`, then `make base-image` | `./tests/llm_serve_test.sh` |
| Prove image integrity after format or signing changes | `tools/basepack.swift`, signing inputs, VFS mount code | `make base-image` | `build/base_image_test build/base.img`, `./tests/signed_image_test.sh` |

Example static-content change:

```sh
printf 'hello from SwiftOS\n' > base/www/index.html
make base-image
./tests/httpd_test.sh
```

## Build And Boot

Build the normal signed base image:

```sh
make base-image
```

Build the kernel, DTB, and base image together:

```sh
make build base-image build/virt.dtb
```

Boot the direct QEMU profile:

```sh
make run
```

Boot the UEFI/GPT profile:

```sh
make disk base-image
make disk-run
```

The base image is a separate virtio-blk disk in both the direct and UEFI QEMU
profiles. A manual direct boot uses:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -kernel build/kernel.elf
```

Expected boot evidence includes:

```text
vfs: base image signature verified (ed25519)
M11c: read-only base mounted from disk
```

## Build Inputs

`make base-image` creates a temporary staging tree at `build/base-root`, then
packs it into `build/base.img` with `build/basepack`.

| Input | Staged Into | Notes |
| --- | --- | --- |
| `base/` | `/` | Static seed files such as `/etc/motd`, `/etc/hostname`, `/etc/swos/passwd`, `/etc/ssh/authorized_keys`, `/etc/ssh/known_hosts`, `/etc/ssh/ssh_host_ed25519_seed`, `/www`, `/readme.txt`, and `/hello.txt` |
| `SSHD_HOST_SEED_FILE` | `/etc/ssh/ssh_host_ed25519_seed` | Optional deploy-specific replacement for the checked-in SSHD development host-key seed |
| `SSHD_KEX_SEED_FILE` | `/etc/ssh/ssh_kex_seed` | Optional deploy-specific KEX mix seed; runtime entropy remains a separate SSHD milestone |
| `SSHD_AUTHORIZED_KEYS_FILE` | `/etc/ssh/authorized_keys` | Optional deploy-specific replacement for the checked-in SSHD development authorized key |
| `NET_IPV6_CONFIG_FILE` | `/etc/swos/net-ipv6` | Optional static IPv6 `/64` address plus link-local gateway for cloud images |
| `SWOS_SERVICES_FILE` | `/etc/swos/services` | Optional replacement boot service manifest for custom images and service supervision tests |
| `BASE_EXEC_ELFS` in `Makefile` | `/bin` | Native Swift utilities, C diagnostic programs, services, update tools, package manager, and busybox |
| `build/pkghello.swpkg` | `/packages/pkghello.swpkg` | Local install fixture |
| `build/pkgrepo-root.pub` | `/etc/pkg/repo-root.pub` | Package repository trust root |
| `PKG_DEFAULT_REPO_URL` | `/etc/pkg/repo-url` | Optional default repository URL baked into a custom base image |
| `PKG_DEFAULT_DNS_SERVER` | `/etc/pkg/dns-server` | Optional DNS server for hosted package-repository tests |
| `models/stories260K.bin`, `models/tok512.bin` | `/models` | Local `/bin/llm` inference inputs |
| `models/stories15M-q8.bin`, `models/tokenizer.bin` | `/models/stories15M/1` | Verified `/bin/llmd` serving bundle |
| Deliberately corrupt generation 2 model | `/models/stories15M/2` | Test fixture for verify-and-fall-back behavior |
| `models/dev-signing.pub` | `/etc/swos/model-signing.pub` | Model manifest trust root |
| `models/dev-image-signing.seed` | image signature | Ed25519 seed used by `basepack` to sign the v3 metadata |
| `models/dev-image-signing.pub` | kernel trust root | Embedded through `kernel/security/trust_root.S` |

Do not edit `build/base-root` by hand. It is generated output and is removed on
the next `make base-image`.

## Signed Format v3

All integer fields are little-endian. Paths are UTF-8 paths relative to `/`
without a leading slash. Directories and regular files are the only entry kinds.

Header layout:

```text
0   u8[8]  magic          "SWOSBASE"
8   u32    version        3 for the signed root base image
12  u32    header_size    64
16  u32    entry_size     72
20  u32    entry_count
24  u64    entries_offset
32  u64    strings_offset
40  u64    strings_size
48  u64    data_offset    strings_offset + strings_size + 64-byte signature
56  u64    data_size
```

Entry layout:

```text
0   u32    path_offset    offset into the string table
4   u32    path_length    path byte length, excluding the NUL terminator
8   u32    kind           1 directory, 2 regular file
12  u32    flags          currently 0
16  u64    data_offset    offset into the payload data section
24  u64    data_size
32  u32    mode           directories and /bin files are usually 0755; other files 0644
36  u32    owner          current base image owner principal is 1 (root)
40  u8[32] content_hash   SHA-256 of file data; all zero for directories
```

The signed metadata region is:

```text
header | entries | string table
```

The 64-byte Ed25519 signature is stored immediately after the string table.
File payload bytes follow the signature. The signature authenticates filesystem
metadata, names, modes, owners, and per-file content hashes. File data is checked
against the stored SHA-256 hash lazily on first open, so metadata tampering
prevents the image from mounting and payload tampering rejects the affected file
while the rest of the guest keeps running.

Unsigned `SWOSBASE` v2 images use 40-byte entries and have no signature or
per-file hash. The kernel accepts v2 only for package payload overlays that have
already been validated by the package or package-store path; it does not accept
v2 as the root base image.

## Inspect The Image

Build and run the host parser:

```sh
make base-image
/usr/bin/swiftc tests/base_image_test.swift kernel/crypto/sha256.swift -o build/base_image_test
build/base_image_test build/base.img
```

Expected result:

```text
PASS: packed base image format is readable, deterministic, and hash-consistent (signed v3)
```

Inspect the v3 header with Python:

```sh
python3 - <<'PY'
import struct
img = open("build/base.img", "rb").read(64)
magic = img[:8].decode()
version, header_size, entry_size, entry_count = struct.unpack_from("<IIII", img, 8)
entries_offset, strings_offset, strings_size, data_offset, data_size = struct.unpack_from("<QQQQQ", img, 24)
print("magic", magic)
print("version", version)
print("header_size", header_size)
print("entry_size", entry_size)
print("entry_count", entry_count)
print("signature_offset", strings_offset + strings_size)
print("data_offset", data_offset)
print("data_size", data_size)
PY
```

For the current root base image, `version` should be `3`, `entry_size` should be
`72`, and `data_offset` should equal `strings_offset + strings_size + 64`.

## Common Changes

### Change A Static File

Edit the seed file, rebuild, and boot:

```sh
printf 'hello from the appliance profile\n' > base/www/index.html
make base-image
./tests/httpd_test.sh
```

Use this path for immutable application assets, static web content, default
configuration, and files that should be present before any package is mounted.

### Add A Native Program To `/bin`

1. Add the userland source and build rule.
2. Add its ELF to `BASE_EXEC_ELFS` in `Makefile`.
3. Copy the built ELF into `$(BASE_ROOT)/bin/<name>` in the `$(BASE_IMG)` rule.
4. Rebuild and run a focused boot test.

The full copy-paste recipe lives in
[Application Cookbook](APPLICATION_COOKBOOK.md#recipe-native-swift-command).
For command documentation, also update [Command Reference](COMMAND_REFERENCE.md)
and the relevant acceptance test.

### Bake A Default Package Repository

Build a custom base image with default package repository settings:

```sh
make BASE_IMG=build/base-hosted-url.img \
  PKG_DEFAULT_REPO_URL=http://packages.swift-os.test:8080 \
  PKG_DEFAULT_DNS_SERVER=10.0.2.3 \
  base-image
```

The generated guest files are `/etc/pkg/repo-url` and `/etc/pkg/dns-server`.
The hosted package tests use this path to prove `pkg update` and
`pkg install NAME` from a DNS-resolved repository URL.

## Verification Matrix

| Concern | Command |
| --- | --- |
| Markdown, documentation links, command coverage, API/example coverage | `make docs-test` |
| Base image packs and host parser reads signed v3 | `make base-image` then `build/base_image_test build/base.img` |
| Kernel mounts a throwaway signed image from virtio-blk | `./tests/vfs_disk_test.sh` |
| Metadata signature rejects tampering and file hashes reject payload tampering | `./tests/signed_image_test.sh` |
| Multi-sector signed metadata reads verify correctly | `./tests/multisector_test.sh` |
| Busybox and `/bin/ps` execute from the packed image | `./tests/disk_exec_test.sh` |
| Full direct boot path with the normal base image | `./tests/boot_test.sh` |
| UEFI disk boot with separate base image | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| A/B base-image update store | `./tests/ab_update_test.sh` |

Run the narrowest test that proves the change. For example, a static web-content
change should run `make base-image` and the relevant service or HTTP test; a
format or signing change should run the signed-image tests.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `make run` cannot find `build/base.img` | The image has not been built | Run `make base-image` |
| Boot reaches the kernel but `/bin` is missing | The base image was not attached or was rejected | Use the documented virtio-blk command and check serial output |
| `vfs: unsigned base image refused - signed v3 required` | `basepack` was run without a signing seed for the root image | Use `make base-image` or pass `models/dev-image-signing.seed` to `basepack` |
| `vfs: base image signature INVALID - refusing disk image` | Signed metadata changed after packing or the kernel trust root does not match the signing key | Rebuild the kernel and base image from the same tree and signing key |
| `vfs: content hash mismatch - rejecting file` | A payload byte changed after the metadata was signed | Rebuild the base image from clean inputs |
| A new command is missing in the guest | The ELF was built but not copied into `$(BASE_ROOT)/bin`, or `build/base.img` is stale | Add the copy rule and rerun `make base-image` |
| Writing under `/etc`, `/bin`, `/www`, or `/models` fails | The path is in the immutable base image | Use `/tmp` for scratch or rebuild the base image |
| `pkg update` does not use the expected default URL | The custom base image was not built with `PKG_DEFAULT_REPO_URL` or not attached | Rebuild with the intended `BASE_IMG` and boot that image |

## Security Notes

- The kernel embeds a single Ed25519 image trust root at build time through
  `kernel/security/trust_root.S`.
- The checked-in development keys are for repository validation and tests. A
  production signing story must replace them with controlled release keys and a
  key-rotation policy.
- The base image is authenticated as a whole metadata contract and then
  fail-closed per file for content reads.
- The current base image has owner and mode metadata, but it is still a
  read-only root filesystem. It is not a general writable Unix filesystem.
- Packages and package-store payloads layer beside the base image. The base
  image remains the root of early boot, identity, command availability, and
  trust-root distribution.

## Source Of Truth

The implementation and tests that define this document are:

- `tools/packfs.swift` for the packed filesystem layout.
- `tools/basepack.swift` for signed base-image construction.
- `Makefile` for `build/base-root` staging and signing inputs.
- `kernel/security/trust_root.S` for the embedded image trust root.
- `kernel/vfs/vfs.swift` for mount-time signature verification and lazy
  per-file hash checks.
- `tests/base_image_test.swift` for host-side format validation.
- `tests/signed_image_test.sh` for tamper rejection behavior.
- `tests/vfs_disk_test.sh`, `tests/disk_exec_test.sh`, and
  `tests/uefi_boot_test.sh` for boot-time acceptance coverage.

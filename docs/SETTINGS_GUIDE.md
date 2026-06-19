# SwiftOS Settings Guide

This guide answers one operator question: **"I want to change a setting — where
does it live, and how do I apply it?"** It exists because `/etc` on SwiftOS is
read-only, so the Linux habit of editing a file under `/etc` on a running system
does not apply here.

If you only need the build variables, QEMU profiles, and seeded defaults, use
[CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md). This guide is the
mental model and the decision path that sits on top of it.

## Why `/etc` Is Read-Only

SwiftOS ships the root filesystem as an immutable, signed, packed base image.
The active root is **never modified in place**. System configuration is
versioned *with the image*: it changes by rebuilding and atomically swapping the
image, not by editing files at runtime. This buys deterministic boot, integrity
by signature, and trivial rollback — at the cost of not being able to "just edit
a file in `/etc`."

See [FAQ.md](FAQ.md#why-is-the-base-filesystem-read-only),
[ARCHITECTURE.md](ARCHITECTURE.md#filesystem-and-update-storage-model), and
[BASE_IMAGE.md](BASE_IMAGE.md) for the design rationale.

## The Three Tiers Decide Where A Setting Lives

Every writable thing on SwiftOS lands in exactly one tier. Pick the tier by
asking two questions: *is it system policy or application state?* and *must it
survive reboot?*

| Tier | Mount | Writable at runtime | Survives reboot | Holds |
| --- | --- | --- | --- | --- |
| Signed base image | `/` (incl. `/etc`, `/bin`) | No | Yes (immutable) | System configuration, identity policy, service manifests |
| datafs | `/data` | Yes (with `fsync` durability) | Yes | Persistent application state: databases, site content, user data |
| tmpfs | `/tmp` | Yes (`capTmpWrite`) | No | Scratch, logs, transient service state |

## Choose How To Change A Setting

| What you want to change | Tier | How to apply | Reboot needed |
| --- | --- | --- | --- |
| Boot services, accounts, hostname, MOTD, SSH trust, static IPv6, baked service config | Base image (`/etc`) | Edit `base/`, `make base-image`, ship via A/B slot | Yes |
| Application database, hosted site content, persistent app config | datafs (`/data`) | Write the file/DB directly, then `fsync` | No |
| Temporary files, run-once scratch | tmpfs (`/tmp`) | Write directly | No (lost on reboot) |

## System Configuration — The Base Image (`/etc`)

System settings live as source files under `base/` and are baked into
`build/base.img` by the host-side `basepack` tool (Ed25519-signed). To change
one:

1. Edit the source under `base/etc/...`.
2. Rebuild the signed image:

```sh
make base-image
```

3. Boot or ship the rebuilt `build/base.img`.

On a deployed machine you do not hand-copy the image: you stage it into the
inactive A/B slot, activate it, and confirm health, with attempt-based rollback
to the previous slot if confirmation fails. See
[UPDATE_GUIDE.md](UPDATE_GUIDE.md) and [UPDATE_STORE.md](UPDATE_STORE.md) for the
`swos-update` / `swos-activate` / `swos-confirm` flow.

### Common Base Settings And Their Source Files

| Setting | Source file | Notes |
| --- | --- | --- |
| Boot services started by `swos-init` | `base/etc/swos/services` | Token allowlist (e.g. `sshd`, `sshd6`); also settable at build via `SWOS_SERVICES_FILE` |
| Accounts and capability masks | `base/etc/swos/passwd` | The real identity store (`name:principal:session:caps:salt$sha256:shell`); `base/etc/passwd`/`group` are compatibility views only, not security authority |
| sudo authorization | `base/etc/swos/sudoers` | — |
| Hostname / MOTD | `base/etc/hostname`, `base/etc/motd` | Static |
| SSH host key / authorized keys / KEX seed | `base/etc/ssh/...` | Build vars `SSHD_HOST_SEED_FILE`, `SSHD_AUTHORIZED_KEYS_FILE`, `SSHD_KEX_SEED_FILE`; checked-in seeds are test material — replace for deploy |
| Static IPv6 | `base/etc/swos/net-ipv6` | Build var `NET_IPV6_CONFIG_FILE`; `address=<ipv6>/64` and `gateway=<link-local-ipv6>` lines |
| Baked nginx config | `base/usr/etc/nginx/...` | Versioned with the image |

The build variables above let you inject deploy-specific material without
editing the checked-in tree — see the SSH Preflight and Image Build Variable
tables in [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md).

## Persistent State — `/data` (datafs)

Settings and state that must survive reboot but are *not* system policy go on the
persistent `/data` tier. This is a writable virtio-blk disk (sector-0 magic
`SWDATAFS`) carrying a small inode-table + block-bitmap filesystem. It is
mounted at `/data` after the base image is verified.

This is where the SQLite database backing the hosted site lives, where
`/data/www/current` holds the active site content, and where any persistent
application configuration belongs. You change it with ordinary file operations
at runtime — no rebuild, no reboot:

```sh
mkdir -p /data/config
printf 'key=value\n' > /data/config/app.conf
sync                       # or fsync(fd) from your program
```

Durability is honest: `fsync`, `fdatasync`, and `sync` flush through to the disk
(`virtioBlkDataFlush`). datafs has **no journaling** by design — crash-safety
relies on honest `fsync` plus the application's own journaling, exactly as
SQLite's rollback journal does. Do not treat `/data` as a general-purpose POSIX
filesystem; it is intentionally narrow.

For hosted static-site content specifically, `/bin/swupdate` performs a
reflash-free, atomic update of `/data/www/current` — see
[OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md) and the D-series in
[NOTES.md](NOTES.md).

## Ephemeral State — `/tmp`

`/tmp` is RAM-backed tmpfs, writable with `capTmpWrite`, and lost on reboot by
design. Use it for scratch and transient state only:

```sh
echo run-once > /tmp/marker
```

## Worked Examples

**Add `sshd6` to the boot services (system policy → rebuild):**

```sh
$EDITOR base/etc/swos/services        # add the sshd6 token
make base-image
./tests/sshd_ipv6_supervision_test.sh
```

**Change the `user` account's capability mask (system policy → rebuild):**

```sh
$EDITOR base/etc/swos/passwd          # edit the caps field
make base-image
./tests/console_login_test.sh
./tests/cap_enforce_test.sh
```

**Persist an application setting across reboot (runtime state → `/data`):**

```sh
mkdir -p /data/config
printf 'theme=dark\n' > /data/config/site.conf
sync
# survives reboot; verify with tests/data_persist_test.sh style boot-twice check
```

## Verification

| Change | Minimum verification |
| --- | --- |
| Boot service list | `make base-image`, the matching `sshd*` supervision test |
| Account / capability mask | `./tests/console_login_test.sh`, `./tests/cap_enforce_test.sh` |
| Any base file content | `make base-image`, `./tests/vfs_disk_test.sh` |
| `/data` persistent state | `./tests/data_persist_test.sh`, `./tests/datafs_test.sh`, `./tests/datafs_fsync_test.sh` |
| Hosted site content on `/data` | `./tests/nginx_data_test.sh`, `./tests/datafs_sqlite_test.sh` |

## See Also

- [CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md) — exact build
  variables, QEMU profiles, artifacts, and seeded defaults.
- [ADMINISTRATION_GUIDE.md](ADMINISTRATION_GUIDE.md) — operator workflows for
  accounts, capabilities, and services.
- [UPDATE_GUIDE.md](UPDATE_GUIDE.md) / [UPDATE_STORE.md](UPDATE_STORE.md) —
  shipping a changed base image via A/B slots with rollback.
- [ARCHITECTURE.md](ARCHITECTURE.md#filesystem-and-update-storage-model) — the
  filesystem and update-storage design.

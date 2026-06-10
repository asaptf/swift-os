# SwiftOS Administration Guide

This guide explains how to administer the current SwiftOS image. It is written
for operators and release owners who maintain guest accounts, capability masks,
base-image configuration, package attachments, service launch procedures, and
verification evidence.

SwiftOS administration is image-centered today. Most durable changes are made on
the host, repacked into the immutable base image, and verified by booting the
guest. The running guest can use `/tmp` for scratch state, but it cannot persist
system configuration changes across reboot.

Use this guide with:

- [User Guide](USER_GUIDE.md) for interactive shell behavior.
- [Security Guide](SECURITY_GUIDE.md) for the authority model and guarantees.
- [Update And Rollback Guide](UPDATE_GUIDE.md) for artifact promotion and
  rollback.
- [Service Guide](SERVICE_GUIDE.md) for service lifecycle and health checks.
- [Package Guide](PACKAGE_GUIDE.md) for package payload and package-store
  workflows.
- [Support Guide](SUPPORT_GUIDE.md) for evidence collection.

## Administrative Model

| Area | Current administrative path |
| --- | --- |
| Accounts | Edit `base/etc/swos/passwd`, rebuild `build/base.img`, boot, verify login |
| Compatibility names | Edit `base/etc/passwd` and `base/etc/group` when tools need names |
| Installed programs | Stage into the base image or attach package payload images |
| System configuration | Store defaults in the immutable base image |
| Runtime state | Use `/tmp`; it is RAM-backed and cleared on reboot |
| Services | Launch manually from the serial shell under the chosen principal |
| Logs and evidence | Capture QEMU serial output and run observability commands |
| Updates | Promote host-built artifacts, or use the checked A/B store and ESP slot commands for validation paths |

The current product profile is serial-first. There is no SSH server, web admin
console, target-side user database editor, or service supervisor yet.

## Admin Account Basics

The authoritative identity store is:

```text
base/etc/swos/passwd
```

It is packed into the guest as:

```text
/etc/swos/passwd
```

Each non-comment line has this shape:

```text
name:principal:session:caps:salt$sha256hex:shell
```

The checked-in accounts are:

| Login | Password | Principal | Session | Caps | Role |
| --- | --- | ---: | ---: | ---: | --- |
| `root` | `swordfish` | 1 | 1 | `63` / `0x3f` | Full seeded authority except reserved log export |
| `user` | `swordfish` | 2 | 2 | `14` / `0x0e` | Filesystem read and tmpfs write without networking |
| `guest` | `guest` | 3 | 3 | `2` / `0x02` | Spawn-only confinement checks |

Compatibility views live in:

```text
base/etc/passwd
base/etc/group
```

Those files help userland tools print names. They are not the kernel security
policy source.

## Capability Masks

Capability masks are decimal values in `base/etc/swos/passwd`. Combine the bits
you want to grant.

| Bit | Decimal | Hex | Name | Administrative meaning |
| ---: | ---: | ---: | --- | --- |
| 0 | 1 | `0x01` | `capConsole` | May call `login()` to adopt an authenticated context |
| 1 | 2 | `0x02` | `capSpawn` | May use normal process-launch paths in the identity model |
| 2 | 4 | `0x04` | `capFsRead` | May read and inspect filesystem objects |
| 3 | 8 | `0x08` | `capTmpWrite` | May write and mutate tmpfs nodes |
| 4 | 16 | `0x10` | `capProcessInspect` | Process-inspection authority bit |
| 5 | 32 | `0x20` | `capNet` | May create sockets and resolve names |
| 6 | 64 | `0x40` | `capLogExport` | Reserved for future log export authority |

Common masks:

| Mask | Meaning |
| ---: | --- |
| `2` | Spawn-only restricted account |
| `6` | Spawn plus filesystem read |
| `14` | Spawn, filesystem read, tmpfs write |
| `46` | Spawn, filesystem read, tmpfs write, networking |
| `63` | Current full seeded authority except reserved log export |

Grant `capConsole` only to the boot/login context or to deliberately privileged
admin flows. Ordinary service accounts should not need it.

## Inspect Current Authority

Inside the guest, run:

```sh
id
```

Expected examples:

```text
principal=1(root) session=1 caps=0x3f
principal=2(user) session=2 caps=0xe
principal=3 session=3 caps=0x2
```

If the process cannot read `/etc/swos/passwd`, `id` still prints numeric values.
That is expected for restricted accounts without `capFsRead`.

## Add Or Change An Account

Account changes are host-side image changes.

1. Choose a login name, principal id, session id, capability mask, salt, and
   shell.
2. Generate `sha256(salt + password)` in lowercase hex.
3. Edit `base/etc/swos/passwd`.
4. Optionally update `base/etc/passwd` and `base/etc/group` so tools can display
   names.
5. Rebuild `build/base.img`.
6. Boot and verify the login path.

Generate a password field:

```sh
salt=swos-netuser
password='change-me'
hash=$(printf '%s' "${salt}${password}" | shasum -a 256 | awk '{print $1}')
printf '%s$%s\n' "$salt" "$hash"
```

Example account with filesystem, tmpfs, and networking authority:

```text
netuser:4:4:46:swos-netuser$REPLACE_WITH_HASH:/bin/sh
```

The decimal mask `46` is:

```text
capSpawn + capFsRead + capTmpWrite + capNet
2 + 4 + 8 + 32
```

Optional compatibility view:

```text
netuser:x:4:4:netuser:/home/netuser:/bin/sh
```

Optional group view:

```text
netuser:x:4:
```

Rebuild and verify:

```sh
make base-image
./tests/console_login_test.sh
```

For a manual check, boot, log in as the new account, and run:

```sh
id
cat /etc/motd
echo ok >/tmp/netuser.txt
/bin/nslookup example.com
```

Use a QEMU network profile before testing networking.

## Disable Or Restrict An Account

Because the identity store is immutable at runtime, disabling an account means
editing `base/etc/swos/passwd` and repacking the image.

Options:

- Remove or comment out the account line.
- Change the password hash to a value no user knows.
- Reduce the capability mask.
- Change the shell to a known test shell when such a shell exists in the image.

Example: keep `user` readable but remove tmpfs write authority:

```text
user:2:2:6:swos-user$REPLACE_WITH_HASH:/bin/sh
```

The mask `6` is `capSpawn + capFsRead`.

Verification:

```sh
make base-image
./tests/console_login_test.sh
```

Manual guest checks:

```sh
id
cat /etc/motd
echo should-fail >/tmp/restricted.txt
```

The read should work and the write should fail.

## Administer Files And Configuration

Durable system files live in the base image:

| Host path | Guest path | Purpose |
| --- | --- | --- |
| `base/etc/swos/passwd` | `/etc/swos/passwd` | Identity store |
| `base/etc/passwd` | `/etc/passwd` | Compatibility user names |
| `base/etc/group` | `/etc/group` | Compatibility group names |
| `base/etc/motd` | `/etc/motd` | Login/message fixture |
| `base/www/` | `/www/` | Static HTTP content |
| `models/` through build rules | `/models/` | AI model bundles |

After editing host-side base files:

```sh
make base-image
./tests/boot_test.sh
```

Inside the guest, system directories are read-only:

```sh
echo no >/etc/motd
```

Use `/tmp` only for runtime scratch:

```sh
mkdir /tmp/admin
echo ok >/tmp/admin/check.txt
cat /tmp/admin/check.txt
```

A reboot clears `/tmp`.

## Administer Installed Software

There are two current install paths.

### Base Image Programs

Use the base image for first-party tools and boot-critical content.

Typical flow:

```sh
make build base-image
./tests/boot_test.sh
```

If the change adds a command, add or run the focused command test that proves
the new behavior.

### Package Payloads

Use package payloads for software that should be tested without baking it into
the base `/bin`.

Build and test the sample payload:

```sh
make package-fixture
make package-overlay-test
```

Build and test the package-store fixture:

```sh
make package-store-fixture
make package-store-test
```

Build and test the signed repository fixture:

```sh
make package-repo-fixture
make package-repo-install-test
```

Package payloads are read-only once active. The current system also has a narrow
local target-side install path: `pkg install FILE` can append a local `.swpkg`
to a writable package-store image and live-mount it. Signed repository install
can run `pkg repo set URL`, `pkg update [URL]`, `pkg search`,
`pkg info`, and `pkg install NAME` against the static HTTP fixture while
rejecting expired or incompatible catalogs, invalid dependency entries, and
package hash mismatches. Name-based dependency resolution is implemented;
version-constraint solving, remove, upgrade, rollback, public hosted package
channels, and large-package streaming downloads remain roadmap work.

## Administer Services

Services currently run in the foreground from the serial shell. They inherit the
current login principal and capability mask.

Common service commands:

| Service | Command | Required authority |
| --- | --- | --- |
| Static HTTP | `/bin/httpd` | `capFsRead`, `capNet` |
| TCP echo | `/bin/tcpecho` | `capNet` |
| UDP echo | `/bin/udpecho` | `capNet` |
| LLM HTTP serving | `/bin/llmd` | `capFsRead`, `capNet` |

Use the seeded `root` account for service demos unless you have created a
service-specific account with `capNet`.

Important current limits:

- There is no service supervisor yet.
- A service stops when its foreground process exits.
- `/bin/httpd` and `/bin/llmd` both bind guest TCP 8080; run one at a time.
- Service logs are primarily serial output and in-guest command output.

Verification examples:

```sh
./tests/httpd_test.sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
./tests/llm_serve_test.sh
```

## Process And Resource Administration

Inside the guest:

```sh
ps
top -b -n 2 -d 1
id
```

Use [Observability Guide](OBSERVABILITY_GUIDE.md) for structured boot markers,
process snapshots, service metrics, and panic evidence.

Current limits:

- No persistent process accounting database.
- No per-cell administrative control surface yet.
- No production daemon restart policy yet.

## Network Administration

Networking requires both a QEMU virtio-net device and a process with `capNet`.

Operational checks:

```sh
/bin/nslookup example.com
/bin/tcpget 10.0.2.2 8080 /
/bin/tcpecho
/bin/udpecho
```

Use [Networking Guide](NETWORKING_GUIDE.md) for full QEMU commands, host
forwarding, IPv4, IPv6, TCP, UDP, DNS, and TLS test coverage.

Current limits:

- No target-side network configuration command.
- No persistent network profile store.
- No firewall or routing administration surface.
- TLS client trust validation is still a demo path, not production policy.

## Administrative Verification Matrix

| Change | Minimum proof |
| --- | --- |
| Account, password, or capability mask | `make base-image`, `./tests/console_login_test.sh` |
| Compatibility names | `make base-image`, `./tests/ls_l_test.sh` |
| Base file content | `make base-image`, `./tests/boot_test.sh` |
| Command added to base image | Command-specific test plus `./tests/boot_test.sh` |
| Package payload | `make package-overlay-test` |
| Package store image | `make package-store-test` |
| Local package install | `make package-local-install-test` |
| Service launch path | Service-specific QEMU test |
| Network authority or network tool | Relevant networking test |
| AI serving admin change | `./tests/llm_run_test.sh`, `./tests/llm_serve_test.sh` |

For broad confidence:

```sh
make test
```

## Support Handoff Checklist

When handing an administrative issue to support, include:

1. `git log -1 --oneline`.
2. `git status --short --branch`.
3. The boot profile used.
4. The account or principal used.
5. The output of `id`.
6. The exact file or service changed.
7. The rebuild commands run.
8. The acceptance test that failed or passed.
9. The serial log around the failure.
10. Whether `/tmp`, base image files, package images, or model files were
    involved.

Redact any non-demo passwords, salts, private keys, model keys, or local tokens
before sharing logs.

## Roadmap Notes

The administration surface is intentionally small while the OS hardens its
application-hosting profile. Future work includes:

- Stronger password KDF and rotation workflow.
- Target-side account management.
- Service manifests and a supervisor.
- Remote administration through an SSH or equivalent package.
- Persistent package install, upgrade, rollback, and repository metadata.
- Production update channels and key rotation beyond the checked A/B validation
  paths.
- Per-cell resource accounting and administrative policy.

Until those land, administer SwiftOS by treating signed images as the source of
truth: edit host-side inputs, rebuild immutable artifacts, stage through the
checked A/B paths when appropriate, boot, verify, and keep rollback artifacts
available.

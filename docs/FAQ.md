# SwiftOS FAQ

This FAQ answers the questions people usually ask before building, testing,
porting to, or reporting an issue against SwiftOS. It describes the current
checked-in system, not only the long-term roadmap.

## Product And Scope

### What is SwiftOS?

SwiftOS is a small AArch64 operating system written primarily in Embedded Swift.
It targets application and AI hosting, embedded/appliance use, and eventually
broader native Swift workloads. The current reference platform is QEMU `virt`.

Start with [DOCUMENTATION.md](DOCUMENTATION.md), then use
[INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md) for boot profiles and
[USER_GUIDE.md](USER_GUIDE.md) for the serial console.

### Is SwiftOS Linux?

No. SwiftOS has its own POSIX-like syscall surface and does not implement the
Linux syscall ABI. Linux binaries, containers, `.deb`, `.rpm`, APK, and OCI
images do not run unchanged.

See [COMPATIBILITY_GUIDE.md](COMPATIBILITY_GUIDE.md).

### Is SwiftOS production-ready?

Not yet. The bring-up system is substantial and test-covered, but the active
work is still hardening the product profile: capability and handle authority,
SMP, service boundaries, package activation, and restartable services.

See [RELEASE_NOTES.md](RELEASE_NOTES.md) for the current snapshot and
[RISK_REMEDIATION_ROADMAP.md](RISK_REMEDIATION_ROADMAP.md) for active work.

### Is desktop use supported?

Desktop use is not excluded, but it is not the primary current product surface.
SwiftOS is serial-first today. A framebuffer and virtio keyboard smoke path
exists for validation, not as a desktop shell.

See [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md#install-profile-graphical-smoke).

### What hardware can I run today?

The primary supported target is QEMU `virt` on AArch64. QEMU+AAVMF UEFI disk
boot is also a primary path. VirtualBox ARM on Apple Silicon is best-effort and
has documented firmware/device-model limitations.

See [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md) and
[VIRTUALBOX.md](VIRTUALBOX.md).

## Build And Installation

### What is the fastest way to boot it?

Run:

```sh
make build base-image build/virt.dtb
make run
```

Complete the tty demo, then log in as `root` with password `swordfish`.

See [GETTING_STARTED.md](GETTING_STARTED.md).

### Which boot path should I use?

Use `make run` for everyday serial development. Use `make disk-run` when
validating the UEFI/GPT disk image. Use `make run-gfx` only for framebuffer and
keyboard smoke checks.

See [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md).

### Why is the base filesystem read-only?

SwiftOS intentionally uses an immutable packed base image plus RAM-backed
`/tmp`. This keeps boot deterministic and makes package/update work move toward
signed immutable images instead of in-place root mutation.

See [BASE_IMAGE.md](BASE_IMAGE.md), [PACKAGE_GUIDE.md](PACKAGE_GUIDE.md), and
[UPDATE_GUIDE.md](UPDATE_GUIDE.md).

### How do I update or roll back SwiftOS?

Today updates are host-driven. Rebuild immutable artifacts with `make build`,
`make base-image`, `make disk`, package tooling, or model targets; boot the new
artifacts; run the relevant acceptance tests; and keep the previous artifacts or
commit available for rollback.

See [UPDATE_GUIDE.md](UPDATE_GUIDE.md).

### How do I prepare a deployment candidate?

Choose a profile, rebuild the immutable artifacts, record hashes and sizes, run
the focused validation gate, save boot or service evidence, and keep a previous
artifact set for rollback.

See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md).

### Where does writable data go?

Current writable guest storage is `/tmp`, backed by RAM. It is lost on reboot.
There is no general persistent writable root filesystem yet.

### How do I verify a build?

Use the narrowest relevant test:

```sh
make build
./tests/boot_test.sh
UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

Use `make test` for the full gate.

See [TESTING_GUIDE.md](TESTING_GUIDE.md) for the full validation matrix and
failure-reading workflow.

## Accounts And Security

### What are the default accounts?

| Login | Password | Use |
| --- | --- | --- |
| `root` | `swordfish` | Full demo authority, including networking |
| `user` | `swordfish` | Filesystem read and tmpfs write without networking |
| `guest` | `guest` | Spawn-only confinement checks |

See [USER_GUIDE.md](USER_GUIDE.md), [SECURITY_GUIDE.md](SECURITY_GUIDE.md), and
[ADMINISTRATION_GUIDE.md](ADMINISTRATION_GUIDE.md).

### Is `root` the same as Unix root?

No. Principal 1 is named `root`, but authorization is capability and
handle-right based. Do not assume traditional Unix superuser semantics.

### Is the default password safe?

No. It is a seeded demo password for the checked-in image. SwiftOS does not yet
ship production password policy, rotation, or account provisioning.

### What does `capNet` mean?

`capNet` currently grants coarse socket authority. Processes without `capNet`
cannot create sockets or resolve names. The long-term model moves toward
narrower rights.

See [CAPABILITIES.md](CAPABILITIES.md).

## Userland And Applications

### Can I run native Swift programs?

Yes. Native user programs can be written in Embedded Swift against
`userland/lib/swift_user.*`, linked statically, and staged into the base image or
a package payload.

See [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) and
[APPLICATION_COOKBOOK.md](APPLICATION_COOKBOOK.md).

### Can I run normal macOS, Linux, or FreeBSD binaries?

No. Rebuild or port source for the SwiftOS ABI. Static linking is required.

### Is dynamic linking supported?

No. The current system uses static binaries only.

### Is busybox the product userland?

Busybox `ash` is used for the login shell and bring-up compatibility. The
project direction is native SwiftOS userland tools where practical.

### Where is the API documented?

Use [API_REFERENCE.md](API_REFERENCE.md) for syscall numbers, structures,
rights, mmap constants, and the native Swift bridge. The build-time source of
truth remains the headers and kernel dispatcher named in
[DOCUMENTATION.md](DOCUMENTATION.md#documentation-contract).

## Packages And Updates

### Does `pkg install` work inside the guest?

Yes, in a narrow local-file form. The current checked-in system can install a
local `.swpkg` from the guest into a writable package-store disk:

```sh
pkg list
pkg install /packages/pkghello.swpkg
pkg list
/usr/bin/pkghello
```

That path is proven by:

```sh
make package-local-install-test
```

The broader package system is still not a public repository manager. Network
repository install is available as a signed HTTP fixture with an explicit or
configured URL:

```sh
pkg repo set http://10.0.2.2:<port>/aarch64/current
pkg update
pkg update http://10.0.2.2:<port>/aarch64/current
pkg search pkghello
pkg info pkghello
pkg install pkghello
```

Current signed repository installs resolve catalog dependencies by package name.
Host-built `.swpkg` artifacts, direct read-only payload overlays, and preseeded
package-store boot activation also remain supported. Public hosted
repositories, version-constraint solving, remove, upgrade, and rollback are
future work.

See [PACKAGE_GUIDE.md](PACKAGE_GUIDE.md).

### Can I install real source-built packages from the guest package manager?

Yes, through checked-in signed local repository fixtures. The Lua path
cross-builds static AArch64 `lua` and `luac`; the P7 seed repository also
cross-builds zlib, publishes Lua and zlib into one signed local repository,
boots SwiftOS with that default repo URL, installs both packages by name, and
runs their smoke commands:

```sh
make ports-lua-repo-fixture
build/swpkg inspect build/lua.swpkg
build/pkgrepo inspect build/lua-repo-root/aarch64/current/catalog.signed
make package-lua-repo-install-test
make ports-zlib-repo-fixture
make ports-seed-repo-fixture
make package-ports-seed-repo-install-test
```

The seed test exercises `pkg install lua`, `pkg install zlib`, Lua version and
expression checks, and a `minigzip` compression/decompression round trip. This
is still a local fixture, not a public hosted package channel.

### Can package files write into `/bin` or `/etc`?

Current package payloads install under `/usr`. The base image is immutable and
boot-critical files remain part of the base image.

### Are packages signed?

The current `.swpkg` format verifies hashes and deterministic structure, but
package-level publisher signatures are future milestones. Signed static HTTP
repositories verify `catalog.signed` with Ed25519, reject expired or
incompatible catalogs, validate dependency entries, and verify downloaded
package blobs with SHA-256 before install. The Lua and ports seed repository
fixtures use the same signed catalog path on the host. Model serving bundles
have their own Ed25519 manifest verification path.

See [SWPKG_FORMAT.md](SWPKG_FORMAT.md),
[PKGSTORE_FORMAT.md](PKGSTORE_FORMAT.md),
[PKGREPO_FORMAT.md](PKGREPO_FORMAT.md), and
[AI_HOSTING_GUIDE.md](AI_HOSTING_GUIDE.md).

## Networking And Services

### Why do network commands fail under `make run`?

`make run` does not attach a NIC. Boot with a QEMU virtio-net device and run the
command as a principal with `capNet`, usually `root`.

See [NETWORKING_GUIDE.md](NETWORKING_GUIDE.md).

### Which network services are available?

Current network-facing programs include `/bin/httpd`, `/bin/llmd`,
`/bin/tcpecho`, `/bin/udpecho`, `/bin/tcpget`, `/bin/nslookup`, and
`/bin/tlsget`.

See [SERVICE_GUIDE.md](SERVICE_GUIDE.md) and
[COMMAND_REFERENCE.md](COMMAND_REFERENCE.md#networking-commands).

### Why can only one of `httpd` and `llmd` run?

Both bind guest TCP port 8080. Run one at a time or boot a separate guest.

### Is TLS production-ready?

No. `/bin/tlsget` proves the TLS 1.3 runtime path, but production certificate
verification is not complete.

## AI Hosting

### What AI demo exists today?

SwiftOS includes TinyStories inference demos:

- `/bin/llm` for local serial-console completions.
- `/bin/llmd` for HTTP completion serving with health and metrics endpoints.

See [AI_HOSTING_GUIDE.md](AI_HOSTING_GUIDE.md).

### Are model bundles verified?

Yes for the default `/bin/llmd` bundle path. It verifies signed manifests and
payload hashes, rejects the deliberately corrupt generation 2, and falls back to
the valid generation 1.

Raw model/tokenizer path overrides bypass bundle signature and payload-hash
verification.

### Is AI serving fast under QEMU?

It is a correctness and isolation demo under QEMU TCG, not a performance target.
Use metrics from `/bin/llmd` to record actual request timing.

## Operations And Support

### Where are logs?

The strongest current evidence is the serial log. Some structured log export
markers and service metrics are available from checked-in demos.

See [OBSERVABILITY_GUIDE.md](OBSERVABILITY_GUIDE.md) and
[LOGGING.md](LOGGING.md).

### How do I report a useful issue?

Include:

- `git log -1 --oneline`
- `git status --short --branch`
- `make tools-check`
- the exact command or test
- serial or test output
- whether the failure is reproducible

See [SUPPORT_GUIDE.md](SUPPORT_GUIDE.md).

### What should I read first as an operator?

Read, in order:

1. [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md)
2. [USER_GUIDE.md](USER_GUIDE.md)
3. [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md)
4. [OBSERVABILITY_GUIDE.md](OBSERVABILITY_GUIDE.md)
5. [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

### What should I read first as an application author?

Read, in order:

1. [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md)
2. [APPLICATION_COOKBOOK.md](APPLICATION_COOKBOOK.md)
3. [API_REFERENCE.md](API_REFERENCE.md)
4. [COMPATIBILITY_GUIDE.md](COMPATIBILITY_GUIDE.md)
5. [PACKAGE_GUIDE.md](PACKAGE_GUIDE.md)

### What should I read first as a maintainer?

Read, in order:

1. [ARCHITECTURE.md](ARCHITECTURE.md)
2. [CAPABILITIES.md](CAPABILITIES.md)
3. [RISK_REMEDIATION_ROADMAP.md](RISK_REMEDIATION_ROADMAP.md)
4. [NOTES.md](NOTES.md)

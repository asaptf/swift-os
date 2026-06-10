# SwiftOS Release Notes

These release notes describe the current checked-in SwiftOS snapshot. SwiftOS
does not yet publish stable external version numbers; use `git log -1 --oneline`
to identify the exact revision you are running.

SwiftOS is currently a QEMU-first AArch64 operating system with a native
Embedded Swift kernel and static userland. It is aimed at application and AI
hosting, with embedded/appliance deployment as a co-primary profile. Desktop use
is not excluded, but the current product surface is serial-first and
service-oriented.

## Snapshot Summary

| Area | Current state |
| --- | --- |
| Primary target | `qemu-system-aarch64 -M virt` |
| Boot paths | UEFI/GPT disk through AAVMF and direct `-kernel` fallback |
| Console | PL011 serial through QEMU `-nographic` |
| Filesystem | Read-only packed base image plus RAM-backed `/tmp` |
| Userland | Static native SwiftOS programs plus busybox shell compatibility |
| ABI | SwiftOS POSIX-like syscall surface, not the Linux ABI |
| Security | Principal/session/capability context plus per-handle rights |
| Networking | virtio-net, TCP/UDP/DNS demos, static HTTP server, LLM serving |
| Packages | Host-built `.swpkg` artifacts, read-only package payload overlays, package-store activation, local and signed-repository installs, plus the seven-package seed ports repository fixture |
| AI hosting | Local TinyStories demo and HTTP serving daemon with verified model bundles |
| Driver services | C5a supervisor/service smoke, C5b opaque device-handle handoff, and C5c-C5e virtio-input discovery metadata plus withheld-authority matching over endpoint IPC; real MMIO/IRQ/DMA driver handoff remains next |

## Highlights

### Boot And Platform

- Boots at EL1 on AArch64 under QEMU `virt`.
- Reads the boot device tree for platform constants instead of relying only on
  hardcoded board addresses.
- Supports the primary UEFI/GPT disk image flow and a direct `-kernel` fallback.
- Mounts the immutable base image from virtio-blk.
- Keeps VirtualBox ARM notes as a best-effort hardware-adjacent path.
- Has SMP readiness work, smoke tests, S5a per-CPU utilization telemetry in
  `/bin/top`, restricted S5b/S5c EL0 scheduler placement gates, and S5d
  independent EL0 fanout across online scheduler CPUs, S5e shared-address-space
  thread fanout, and an S5f run-any placement gate for default EL0 process
  placement.

### User Experience

- Starts `/bin/console-login` on the serial console.
- Seeds three demo accounts: `root`, `user`, and `guest`.
- Provides a busybox `ash` shell for interactive use.
- Ships native SwiftOS tools for common workflows: `ls`, `cat`, `echo`, `pwd`,
  `ps`, `top`, `id`, `mkdir`, `rmdir`, `rm`, `mv`, `chmod`, `chown`, `head`,
  `touch`, `wc`, `date`, `calc`, `kv`, and more.
- `/bin/top` can render process/resource snapshots, aggregate CPU busy/idle,
  and per-CPU busy percentages under SMP test profiles.
- Uses `/tmp` as writable scratch storage. `/tmp` is RAM-backed and cleared on
  reboot.

### Security And Isolation

- Runs EL0 user programs in separate address spaces.
- Tracks a principal, session, and capability mask per process.
- Enforces current filesystem and networking authorities through capability
  checks such as `capFsRead`, `capTmpWrite`, `capProcessInspect`, and `capNet`.
- Carries rights on handles and supports explicit handle inheritance with
  `spawn_handles`.
- Provides filesystem confinement through `confine(path)`.

### Filesystem And Packages

- Builds `build/base.img` from `base/` plus staged `/bin` programs and model
  bundle files.
- Keeps the base filesystem read-only by design.
- Provides tmpfs mutation under `/tmp` for writable runtime state.
- Builds sample `.swpkg` artifacts, read-only package payload overlays, and a
  preseeded package-store image.
- Provides a narrow local target-side `pkg install FILE` and `pkg list` path.
- Provides signed HTTP repository fixture install with `pkg repo set`,
  `pkg update [URL]`, `pkg search`, `pkg info`, dependency resolution by package
  name, and `pkg install NAME`; the QEMU acceptance path rejects expired
  catalogs, incompatible catalogs, and package SHA-256 mismatches.
- Provides maintainer-side ports scaffolding: `ports/catalog.json`, checked
  Lua, zlib, bzip2, ca-certificates, pcre2, tzdata, nginx, and sqlite recipes,
  `swport catalog validate/list/inspect`, and `swport recipe` commands for
  `validate`, `manifest`, `fetch`, `package`, and `repo-fixture`.
- Cross-builds real static AArch64 `lua` and `luac` binaries against the local
  newlib sysroot and publishes them into a signed local repository fixture with
  `make ports-lua-repo-fixture`.
- Installs real Lua from the signed local repository fixture inside QEMU and
  runs `lua -v` plus a small expression smoke with
  `make package-lua-repo-install-test`.
- Publishes Lua, zlib, bzip2, ca-certificates, pcre2, tzdata, nginx, and sqlite
  into one signed local seed
  repository and verifies `pkg install lua`, `pkg install zlib`,
  `pkg install bzip2`, `pkg install ca-certificates`, `pkg install pcre2`,
  `pkg install tzdata`, `pkg install nginx`, and `pkg install sqlite`, Lua
  smoke commands, `minigzip` and bzip2 round trips, the CA bundle marker, a
  `pcre2grep` regex match, the tzdata zoneinfo marker, nginx version/marker
  smoke, and a SQLite in-memory query with
  `make package-ports-seed-repo-install-test`.
- Publishes that seed into a static-hostable web root with `hosted-repo.json`,
  `repo-root.pub`, and SHA-256 sidecar checks, then verifies Lua, zlib, bzip2,
  ca-certificates, pcre2, tzdata, nginx, and sqlite install from that hosted
  layout with `make package-static-host-repo-install-test`.
- Verifies hosted static-root URLs from the host and proves target-side install
  from a DNS-resolved HTTP repository hostname with
  `make package-static-host-dns-repo-install-test`.
- Does not yet provide public hosted package channels, version-constraint
  solving, broad source-port coverage, remove, upgrade, rollback, or streaming
  large-package downloads.

### Networking And Services

- Exposes capability-gated socket syscalls for UDP, TCP, DNS resolution, and
  polling.
- Ships `/bin/httpd` for static files under `/www`.
- Ships `/bin/tcpecho`, `/bin/udpecho`, `/bin/tcpget`, and `/bin/nslookup` for
  network validation.
- Ships `/bin/tlsget` as a TLS 1.3 client demo path. Production certificate
  validation is not complete.
- `/bin/httpd` and `/bin/llmd` both bind guest TCP port 8080, so run one at a
  time.

### AI Hosting

- `/bin/llm` runs a local TinyStories completion from the small `stories260K`
  demo model.
- `/bin/llmd` serves TinyStories completions over HTTP on TCP 8080.
- The default server resolves the verified bundle rooted at
  `/models/stories15M`.
- Bundle generations use
  `/models/stories15M/<generation>/{manifest.toml,model.bin,tokenizer.bin}`.
- The loader tries numeric generations newest-first, verifies manifest size and
  SHA-256 entries, rejects bad generations, and serves the newest verified one.
- The checked-in image deliberately includes a corrupt generation 2 and a valid
  generation 1 to prove fallback behavior in every serving test.

## Verification

Common gates:

```sh
make build
make base-image
make test
```

Focused gates:

```sh
./tests/boot_test.sh
./tests/console_login_test.sh
./tests/httpd_test.sh
./tests/package_overlay_test.sh
./tests/pkg_store_boot_test.sh
./tests/pkg_local_install_test.sh
make package-repo-install-test
make ports-catalog-test
make ports-recipe-test
make ports-lua-repo-fixture
make package-lua-repo-install-test
make ports-zlib-repo-fixture
make ports-seed-repo-fixture
make package-ports-seed-repo-install-test
make ports-static-host-publish
make package-static-host-repo-install-test
make ports-hosted-url-verify-test
make package-static-host-dns-repo-install-test
make smp-cpu-utilization-test
make s5-el0-fanout-test
make c5-test
./tests/llm_run_test.sh
./tests/llm_serve_test.sh
```

For the verified model-bundle path:

```sh
/usr/bin/swiftc tests/llm_bundle_test.swift userland/lib/modelbundle.swift kernel/crypto/sha256.swift -o build/llm_bundle_test
build/llm_bundle_test
./tests/llm_serve_test.sh
```

Expected `/bin/llmd` serial markers include:

```text
llmd: generation 2 rejected (model size/sha256 mismatch)
llmd: bundle stories15M generation 1 verified (ed25519+sha256)
llmd: model int8 Q8_0 GS=32
llmd: serving on 8080
llmd: served
```

## Known Limits

- No Linux ABI is provided. Software must be ported or rebuilt for the SwiftOS
  syscall surface.
- User programs are statically linked. There is no dynamic loader.
- The base filesystem is read-only. Persistent writable storage is not part of
  the current product surface.
- Package payloads are read-only once active. Local target-side package install
  and signed repository fixture install with name-based dependencies exist. The
  checked seed repository can install Lua, zlib, bzip2, ca-certificates, pcre2,
  tzdata, nginx, and sqlite in QEMU, publish the same seed into a
  static-hostable web root, verify hosted static-root URLs, and install from
  target-side DNS-resolved HTTP repository URLs. Public production channels,
  broad source-port coverage, version-constraint solving, removal, upgrade,
  rollback, and streaming large-package downloads remain roadmap work.
- The current capability model is useful and tested, but the stronger long-term
  handle and service model is still being hardened.
- Many drivers and the network stack still live in the kernel. C5a-C5e prove
  the supervisor/service IPC shape, opaque device-handle ownership transfer,
  discovered virtio-input metadata/manifest matching, surfaced virtio-mmio
  metadata, and withheld hardware authority; real restartable userland driver
  services with MMIO/IRQ/DMA authority are still roadmap work.
- SMP foundations, per-CPU utilization telemetry, and restricted S5 placement
  stress gates exist, but broad multi-core EL0 scheduling is not the default
  product contract yet.
- TLS client support is a demo path. Treat production trust validation as
  incomplete.
- LLM inference under QEMU TCG is a correctness and integration demonstration,
  not a throughput target.
- The deliberately corrupt `/models/stories15M/2` generation is expected in the
  checked-in demo image. Its manifest signature is valid, but its model payload
  hash fails, proving fallback to generation 1.
- Model-bundle manifests are signed with the development Ed25519 trust root
  staged as `/etc/swos/model-signing.pub`. Production key rotation and
  revocation are future work.

## Upgrade And Rollback Notes

- Rebuild the base image after changing staged files, userland programs, or
  model bundles:

```sh
make base-image
```

- Rebuild the UEFI disk image after loader or disk-layout changes:

```sh
make disk
```

- Rebuild model artifacts when model source files or tokenizers are missing or
  stale:

```sh
make model
make base-image
```

- The checked A/B validation model now covers base-image slot staging,
  activation, confirmation, rollback, and durable writes, plus UEFI ESP kernel
  slot staging, boot-state activation, health confirmation, boot-attempt
  counting, and attempt-based rollback. Production update channels and key
  rotation remain roadmap work.
- For the current update and rollback procedures, use [UPDATE_GUIDE.md](UPDATE_GUIDE.md);
  for the store and manifest formats, use [UPDATE_STORE.md](UPDATE_STORE.md).

## More Information

- Start with [GETTING_STARTED.md](GETTING_STARTED.md) for the first boot.
- Use [USER_GUIDE.md](USER_GUIDE.md) for interactive operation.
- Use [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md) for command syntax.
- Use [HOST_TOOL_REFERENCE.md](HOST_TOOL_REFERENCE.md) for host-side package,
  repository, ports, image, and model tools.
- Use [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md) for tested runbooks.
- Use [TESTING_GUIDE.md](TESTING_GUIDE.md) for choosing and interpreting gates.
- Use [UPDATE_GUIDE.md](UPDATE_GUIDE.md) for artifact updates and rollback.
- Use [PACKAGE_BUILD_AUTOMATION.md](PACKAGE_BUILD_AUTOMATION.md) for the current
  ports recipe and package automation path.
- Use [API_REFERENCE.md](API_REFERENCE.md) and
  [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) for application development.
- Use [SUPPORT_GUIDE.md](SUPPORT_GUIDE.md) when collecting evidence for an
  issue report.

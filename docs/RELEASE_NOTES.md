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
| Packages | Host-built `.swpkg` artifacts, read-only package payload overlays, and P3a package-store boot activation |
| AI hosting | Local TinyStories demo and HTTP serving daemon with verified model bundles |

## Highlights

### Boot And Platform

- Boots at EL1 on AArch64 under QEMU `virt`.
- Reads the boot device tree for platform constants instead of relying only on
  hardcoded board addresses.
- Supports the primary UEFI/GPT disk image flow and a direct `-kernel` fallback.
- Mounts the immutable base image from virtio-blk.
- Keeps VirtualBox ARM notes as a best-effort hardware-adjacent path.
- Has SMP readiness work and smoke tests, while broad multi-core EL0 execution
  remains roadmap work.

### User Experience

- Starts `/bin/console-login` on the serial console.
- Seeds three demo accounts: `root`, `user`, and `guest`.
- Provides a busybox `ash` shell for interactive use.
- Ships native SwiftOS tools for common workflows: `ls`, `cat`, `echo`, `pwd`,
  `ps`, `top`, `id`, `mkdir`, `rmdir`, `rm`, `mv`, `chmod`, `chown`, `head`,
  `touch`, `wc`, `date`, `calc`, `kv`, and more.
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
- Does not yet provide target-side persistent package install/remove.

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
- Package overlays and package-store boot activation are read-only at runtime.
  Target-side package installation, removal, live activation, and rollback
  remain roadmap work.
- The current capability model is useful and tested, but the stronger long-term
  handle and service model is still being hardened.
- Many drivers and the network stack still live in the kernel. Restartable
  userland services are roadmap work.
- SMP foundations exist, but broad multi-core EL0 scheduling is not the default
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

- The long-term signed image and A/B rollback model is described in
  [ARCHITECTURE.md](ARCHITECTURE.md) and
  [RISK_REMEDIATION_ROADMAP.md](RISK_REMEDIATION_ROADMAP.md). The current
  verified LLM bundle is a narrow, working example of generation verification
  and fallback.

## More Information

- Start with [GETTING_STARTED.md](GETTING_STARTED.md) for the first boot.
- Use [USER_GUIDE.md](USER_GUIDE.md) for interactive operation.
- Use [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md) for command syntax.
- Use [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md) for tested runbooks.
- Use [API_REFERENCE.md](API_REFERENCE.md) and
  [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) for application development.
- Use [SUPPORT_GUIDE.md](SUPPORT_GUIDE.md) when collecting evidence for an
  issue report.

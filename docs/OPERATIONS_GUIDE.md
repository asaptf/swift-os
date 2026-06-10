# SwiftOS Operations Guide

This guide is for people who boot, test, demo, or operate a SwiftOS image. It
describes the current checked-in system: QEMU `virt` on AArch64, serial console
first, immutable base image, RAM scratch space, capability-scoped user sessions,
native Swift tools, networking demos, package payload overlays, and the AI
inference demo.

Use this guide with:

- [Getting Started](GETTING_STARTED.md) for the first boot.
- [Installation Guide](INSTALLATION_GUIDE.md) for choosing and verifying direct,
  UEFI, graphical, and VirtualBox boot profiles.
- [Update And Rollback Guide](UPDATE_GUIDE.md) for rebuilding immutable
  artifacts, validating candidates, and returning to a known-good image.
- [User Guide](USER_GUIDE.md) for shell and userland behavior.
- [Configuration Reference](CONFIGURATION_REFERENCE.md) for build variables,
  boot defaults, QEMU profiles, and test knobs.
- [Package Guide](PACKAGE_GUIDE.md) for `.swpkg` artifacts, payload overlays,
  package-store images, and package verification workflows.
- [Networking Guide](NETWORKING_GUIDE.md) for virtio-net profiles, host
  forwarding, DNS, TCP/UDP, TLS, IPv6 smoke paths, and network test coverage.
- [Service Guide](SERVICE_GUIDE.md) for service lifecycle, readiness markers,
  ports, health checks, and service authoring rules.
- [AI Hosting Guide](AI_HOSTING_GUIDE.md) for the local inference demo,
  serving daemon, model bundles, health checks, and metrics.
- [Observability Guide](OBSERVABILITY_GUIDE.md) for boot health markers,
  structured log smoke paths, process snapshots, service metrics, and panic
  evidence.
- [Troubleshooting](TROUBLESHOOTING.md) when a build, boot, login, or network
  path fails.
- [Support Guide](SUPPORT_GUIDE.md) for evidence collection and handoff
  checklists.
- [Examples](EXAMPLES.md) for copy-paste operational recipes.

## Operating Model

SwiftOS is intentionally small and static.

| Property | Current behavior |
| --- | --- |
| Primary platform | `qemu-system-aarch64 -M virt` |
| CPU mode | Kernel at EL1, user programs at EL0 |
| Console | Serial console through QEMU `-nographic`; framebuffer smoke exists |
| Boot paths | Direct `-kernel` fallback and UEFI disk image through AAVMF |
| Root filesystem | Read-only packed `SWOSBASE` image served from virtio-blk |
| Writable storage | `/tmp` tmpfs only; contents are lost on reboot |
| User sessions | `/bin/console-login` authenticates principals from `/etc/swos/passwd` |
| Program model | Static binaries; native Embedded Swift userland is the direction |
| Networking | virtio-net plus capability-gated socket syscalls |
| Packages | Host-built `.swpkg` plus read-only package payload overlay support |
| SMP status | SMP foundations and smoke tests exist; EL0 execution remains constrained by the current roadmap |

The most important operational consequence is that a running guest has no
persistent writable root. Rebuild the base image or attach a package payload to
change installed software. Use `/tmp` only for runtime scratch.

## Artifact Map

| Artifact | Built by | Used for |
| --- | --- | --- |
| `build/kernel.elf` | `make build` | Direct QEMU `-kernel` boot |
| `build/base.img` | `make base-image` | Immutable base filesystem |
| `build/virt.dtb` | `make build/virt.dtb` or `make test` prerequisites | Device tree loaded for direct QEMU boot |
| `build/swift-os.img` | `make disk` | UEFI/GPT boot disk |
| `build/BOOTAA64.EFI` | `make uefi` | AArch64 UEFI loader |
| `build/pkghello.swpkg` | `make package-fixture` | Sample host package artifact |
| `build/pkghello-payload.img` | `make package-fixture` | Read-only package payload overlay |
| `models/stories260K.bin`, `models/tok512.bin` | `make model` or `make base-image` | `/bin/llm` local inference inputs |
| `models/stories15M-q8.bin`, `models/tokenizer.bin` | `make model` or `make base-image` | Source payloads for the `/bin/llmd` verified serving bundle |

`make clean` removes build products but not downloaded toolchains. `make
newlib`, `make busybox`, and `make model` are slower setup paths and are usually
run only when their artifacts are missing or stale.

## Boot Profiles

### Direct Serial Boot

Use this for day-to-day kernel and userland work:

```sh
make build base-image build/virt.dtb
make run
```

The direct path loads `build/kernel.elf`, attaches `build/base.img`, and mirrors
the guest console to the terminal.

### UEFI Disk Boot

Use this when validating firmware handoff, the GPT image, or the primary boot
path:

```sh
make disk base-image
make disk-run
```

The disk image contains the EFI System Partition and loader. The base filesystem
is still attached as a separate read-only virtio-blk disk.

### Graphical Smoke Boot

Use this only for framebuffer/input smoke checks:

```sh
make run-gfx
```

The product shell is still serial-first. The graphical path exists to verify the
UEFI framebuffer and virtio input path, not to provide a desktop environment.

### Network Boot

Networking requires a NIC in the QEMU command. The common demo profile forwards
host TCP 8080 to guest TCP 8080 and host TCP/UDP 5555 to guest port 5555. For
service-specific profiles and troubleshooting, see
[NETWORKING_GUIDE.md](NETWORKING_GUIDE.md).

```sh
make build base-image build/virt.dtb

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080,hostfwd=tcp:127.0.0.1:5555-:5555,hostfwd=udp:127.0.0.1:5555-:5555 \
  -device virtio-net-device,netdev=n0 \
  -kernel build/kernel.elf
```

Inside the guest, log in as `root` before running socket programs. The seeded
`root` principal has `capNet`; `user` and `guest` do not.

### Package Overlay Boot

Package payload overlays are current P2 functionality. They are read-only VFS
overlays attached at boot, not target-side `pkg install` yet. For the complete
package runbook, including package-store activation, see
[PACKAGE_GUIDE.md](PACKAGE_GUIDE.md).

Build the sample package and boot with the payload image:

```sh
make package-fixture

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -drive file=build/pkghello-payload.img,format=raw,if=none,id=swospkg0,readonly=on \
  -device virtio-blk-device,drive=swospkg0 \
  -kernel build/kernel.elf
```

Inside the guest:

```sh
/usr/bin/pkghello
```

Expected output:

```text
pkghello: hello from package overlay
```

For package format details, see [SWPKG_FORMAT.md](SWPKG_FORMAT.md) and
[PACKAGE_MANAGEMENT.md](PACKAGE_MANAGEMENT.md).

### Package Store Boot

Package-store boot activation is current P3a functionality. Build the sample
store and boot with it attached:

```sh
make package-store-fixture

qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -drive file=build/pkgstore-pkghello.img,format=raw,if=none,id=swpkgstore \
  -device virtio-blk-device,drive=swpkgstore \
  -kernel build/kernel.elf
```

Inside the guest, `/usr/bin/pkghello` should produce the same output as the
direct overlay path. Acceptance coverage: `make package-store-test`.

## Access And Accounts

The default identity store is `base/etc/swos/passwd`.

| Login | Password | Principal | Operational use |
| --- | --- | ---: | --- |
| `root` | `swordfish` | 1 | Full demo and test authority, including networking |
| `user` | `swordfish` | 2 | Filesystem read and tmpfs write without network authority |
| `guest` | `guest` | 3 | Spawn-only capability tests |

Check a session:

```sh
id
```

The current capability model is deliberately explicit. Do not interpret
principal 1 as Unix `uid 0`; the kernel authorizes operations through capability
bits and handle rights.

## Filesystem Operations

The base image is immutable. Use it for software and defaults:

```sh
ls -l /
ls -l /bin
cat /etc/motd
cat /www/index.html
```

Use `/tmp` for writable runtime state:

```sh
mkdir /tmp/runbook
echo checked >/tmp/runbook/status.txt
cat /tmp/runbook/status.txt
rm /tmp/runbook/status.txt
rmdir /tmp/runbook
```

Operational rules:

1. A reboot clears `/tmp`.
2. A base-image change requires rebuilding `build/base.img`.
3. A package change requires building and attaching a package payload image.
4. File ownership and modes are visible with `ls -l`, but the current security
   boundary is still capability-first.

## Process And Resource Monitoring

Use `ps` for a static process list:

```sh
ps
```

Use `top` for resource snapshots:

```sh
top -b -n 2 -d 1
```

Interactive `top` repaints the serial terminal and exits on `q`:

```sh
top
```

For automated logs, prefer `top -b`. It avoids cursor control and raw terminal
mode.

## Networking Operations

All socket tools require a NIC and `capNet`. See
[NETWORKING_GUIDE.md](NETWORKING_GUIDE.md) for the full network runbook and
[SERVICE_GUIDE.md](SERVICE_GUIDE.md) for the service catalog, readiness
markers, health checks, and service design contract.

### HTTP

Inside the guest:

```sh
/bin/httpd
```

From the host:

```sh
curl http://127.0.0.1:8080/
curl http://127.0.0.1:8080/hello.txt
curl http://127.0.0.1:8080/sub/
curl -i http://127.0.0.1:8080/nope
```

`/bin/httpd` serves `/www`, returns MIME types for common suffixes, generates
directory listings when no `index.html` exists, and returns 404 for misses.

### TCP Echo

Inside the guest:

```sh
/bin/tcpecho
```

From the host:

```sh
printf 'hello tcp\n' | nc -w8 127.0.0.1 5555
```

`/bin/tcpecho` is a one-shot server. Start it again for another connection.

### UDP Echo

Inside the guest:

```sh
/bin/udpecho
```

From the host:

```sh
printf 'hello udp' | nc -u -w2 127.0.0.1 5555
```

`/bin/udpecho` is also one-shot.

### Guest-Initiated TCP

Start a host listener:

```sh
printf 'srv-reply\n' | nc -l 5555
```

Inside the guest:

```sh
/bin/tcpget 10.0.2.2 5555
```

`10.0.2.2` is QEMU slirp's host alias.

### DNS

With QEMU user networking attached:

```sh
/bin/nslookup example.com
```

The default resolver is QEMU slirp's DNS address (`10.0.2.3`). Tests may pass an
explicit DNS responder address and port.

## AI Hosting Demo

SwiftOS has two native Swift TinyStories inference entry points:

| Command | Use |
| --- | --- |
| `/bin/llm` | Run one local completion and print tokens plus timing on the serial console |
| `/bin/llmd` | Serve Q8_0 TinyStories completions over TCP with health and metrics endpoints |

For the complete AI runbook, bundle format, HTTP API, and support checklist, see
[AI_HOSTING_GUIDE.md](AI_HOSTING_GUIDE.md).

The local demo and the server intentionally use different default bundles:
`/bin/llm` loads the small fp32 `stories260K` checkpoint and `tok512`
tokenizer, while `/bin/llmd` serves the larger Q8_0 `stories15M` checkpoint
through a verified bundle rooted at `/models/stories15M`.

Prepare model artifacts:

```sh
make model
make base-image
```

### Local Completion

Inside the guest:

```sh
/bin/llm
/bin/llm "Once upon a time" 32
```

Under QEMU TCG this is intentionally slow compared with native execution. Treat
it as a correctness and isolation demo, not a performance target.

### TCP Model Serving

Boot with virtio-net and host TCP 8080 forwarded to guest TCP 8080. Inside the
guest:

```sh
/bin/llmd
```

By default, this resolves `/models/stories15M`, tries numeric generations
newest-first, verifies each generation's `manifest.toml`, `model.bin`, and
`tokenizer.bin`, and serves the newest generation whose size and SHA-256 checks
pass. The checked-in image includes a deliberately corrupt generation 2 and a
valid generation 1 to prove fallback behavior.

To test another supported checkpoint/tokenizer pair without signed-bundle
verification, pass both paths explicitly:

```sh
/bin/llmd /models/stories260K.bin /models/tok512.bin
```

From the host:

```sh
curl http://127.0.0.1:8080/health
curl -X POST --data "Once upon a time" http://127.0.0.1:8080/completion
curl http://127.0.0.1:8080/metrics
```

`/bin/llmd` reports `llmd: trust root loaded (/etc/swos/model-signing.pub)`,
`llmd: generation 2 rejected (model size/sha256 mismatch)` for the
intentionally corrupt demo generation, then
`llmd: bundle stories15M generation 1 verified (ed25519+sha256)`,
`llmd: model int8 Q8_0 GS=32`, and `llmd: serving on 8080` when it is ready.
`GET /health` reports the model shape, such as `ok model dim=288` for the
default serving bundle. `POST /completion` uses the request body as the prompt
and streams generated text until the HTTP/1.0 connection closes. `/metrics`
reports request count, total generated tokens, last time-to-first-token in
milliseconds, and last token rate.

`/bin/llmd` and `/bin/httpd` both bind guest TCP port 8080, so run one of them
at a time.

## Logging And Evidence

Today the strongest operational evidence is the serial log plus test output.
Capture serial by running QEMU directly and redirecting stdout:

```sh
qemu-system-aarch64 ... >swiftos-serial.log 2>&1
```

Useful markers:

| Marker | Meaning |
| --- | --- |
| `M11c: read-only base mounted from disk` | Base image mounted from virtio-blk |
| `swift-os login:` | `console-login` is running |
| `Welcome to swift-os, root` | Authentication succeeded |
| `httpd: listening on 8080` | HTTP server bound and entered its event loop |
| `llmd: generation 2 rejected (model size/sha256 mismatch)` | Deliberately corrupt demo generation was rejected |
| `llmd: bundle stories15M generation 1 verified (ed25519+sha256)` | Signed model-bundle fallback selected generation 1 |
| `llmd: model int8 Q8_0 GS=32` | Quantized serving engine selected |
| `llmd: serving on 8080` | Inference server bound and entered its event loop |
| `llmd: served` | Inference server completed a request and logged serving metrics |
| `tcpecho: listening on 5555` | TCP echo server is waiting in accept |
| `udpecho: listening on 5555` | UDP echo server bound |
| `pkghello: hello from package overlay` | Package payload overlay was visible and executable |
| `llm: done` | Inference demo completed and returned to userland |

The kernel has a structured in-memory log ring and sink indirection groundwork;
userland log export remains gated by future capability work. See
[OBSERVABILITY_GUIDE.md](OBSERVABILITY_GUIDE.md) for practical signal reading
and [LOGGING.md](LOGGING.md) for the design record.

## Verification Matrix

Run the narrowest test that proves the path you touched:

| Area | Command |
| --- | --- |
| Kernel build | `make build` |
| Base image | `make base-image` |
| Direct boot | `./tests/boot_test.sh` |
| UEFI boot | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| SMP smoke | `SMP_CPUS=4 ./tests/smp_boot_test.sh` |
| VFS from disk | `./tests/vfs_disk_test.sh` |
| Package overlay | `make package-overlay-test` |
| Console login | `./tests/console_login_test.sh` |
| Capability enforcement | `./tests/cap_enforce_test.sh` |
| HTTP server | `./tests/httpd_test.sh` |
| TCP echo | `./tests/tcp_echo_test.sh` |
| UDP echo | `./tests/udp_echo_test.sh` |
| DNS | `./tests/dns_test.sh` |
| Swift coreutils | `./tests/swift_coreutils_test.sh` |
| `top` | `./tests/top_test.sh` |
| LLM demo | `./tests/llm_run_test.sh` |
| LLM serving | `./tests/llm_serve_test.sh` |
| Full gate | `make test` |

Some QEMU tests drive an interactive serial boot and then attach host clients.
If a single smoke test times out on a busy host, rerun that exact test before
claiming a product failure; if it repeats, keep the serial log.

## Shutdown And Reset

There is no persistent writable guest state to flush. Exit the shell to return
to login:

```sh
exit
```

Stop QEMU from the host terminal with Ctrl-C, or from the QEMU monitor sequence
Ctrl-A then X when using `-nographic`.

## Operational Limits

Current limits that matter during operation:

- No persistent writable filesystem.
- No target-side package install/remove command yet.
- No dynamic linker or Linux ABI.
- No graphical desktop shell.
- No production password policy or password rotation workflow.
- No general service manager; demos are started manually from the shell.
- IPv6 support exists in the stack and smoke tests, but Darwin/QEMU hostfwd
  behavior can limit end-to-end host tests.
- In-kernel drivers and networking are still current reality; the roadmap moves
  more services out of the trusted core.

Document new operational behavior in this guide when it becomes part of the
checked-in system.

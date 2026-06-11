# SwiftOS Troubleshooting

This guide turns common build, boot, login, filesystem, networking, package, and
test failures into concrete checks. It assumes the current QEMU `virt` workflow.

For normal operation, see [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md). For
copy-paste success paths, see [EXAMPLES.md](EXAMPLES.md). For evidence
collection, report templates, and handoff checklists, see
[SUPPORT_GUIDE.md](SUPPORT_GUIDE.md).

## First Triage

Start by recording the exact state:

```sh
git status --short --branch
git log -1 --oneline
make tools-check
```

Then identify the failing layer:

| Symptom | Start here |
| --- | --- |
| Compiler, linker, or sysroot error | [Build Problems](#build-problems) |
| QEMU starts but no login prompt | [Boot Problems](#boot-problems) |
| Password accepted nowhere | [Login Problems](#login-problems) |
| `open`, `cat`, `ls`, or writes fail | [Filesystem Problems](#filesystem-problems) |
| `swos-*` update command or rollback behaves unexpectedly | [Update And Rollback Problems](#update-and-rollback-problems) |
| Socket tools fail | [Networking Problems](#networking-problems) |
| `/usr/bin/pkghello` is missing | [Package Problems](#package-problems) |
| `/bin/llm` cannot load files | [LLM Inference Problems](#llm-inference-problems) |
| A QEMU smoke test flakes | [Test Driver Problems](#test-driver-problems) |

Keep the serial log when reporting a failure. It is usually the most useful
artifact.

## Failure Signature Index

Use the first visible failure line to choose the next check. If several
signatures appear, start with the earliest one in the serial log or test output.

| First signal | Likely layer | Run next | Then collect |
| --- | --- | --- | --- |
| `stdio.h` missing, `libc.a` missing, or newlib include error | Host sysroot | `make newlib`, then `make build` | `make tools-check` output |
| `build/busybox.elf` missing | Host userland prerequisite | `make busybox`, then `make base-image` | `test -f build/busybox.elf` |
| QEMU prints nothing | Direct boot artifact or QEMU command | `make build base-image build/virt.dtb`, then `make run` | Full QEMU command and serial log |
| `M7 tty: type a line then Enter` remains on screen | Expected interactive smoke gate | Type one line, press Enter, then Ctrl-C at the next prompt | Serial transcript through `swift-os login:` |
| Missing `M11c: read-only base mounted from disk` | Base image or virtio-blk attach | `make base-image`, then `./tests/vfs_disk_test.sh` | QEMU drive/device arguments |
| Login rejected for seeded users | Identity store or stale base image | `make base-image`, then `./tests/console_login_test.sh` | `base/etc/swos/passwd` diff if changed |
| `permission denied (need capConsole)` | Update command under wrong authority | Log in as `root`, run `id`, then retry the update command | `./tests/cap_enforce_test.sh` if behavior changed |
| `socket failed` | Missing NIC, missing `capNet`, or unsupported socket path | Boot a networking profile and run `id` | Network QEMU command and service marker |
| Host `curl` cannot connect | Missing readiness marker, hostfwd mismatch, or host port conflict | Confirm `httpd: listening on 8080` or `llmd: serving on 8080` | Host `curl -v` output |
| `/usr/bin/pkghello` missing | Package payload or store not attached or installed | `make package-overlay-test` or `make package-store-test` | Package image paths and guest `pkg` transcript |
| `pkg: catalog updated` missing | Repository fetch, signature, URL, or network issue | `make package-repo-install-test` | Served repository root and `/bin/pkg` output |
| `llmd: generation ... rejected` without later verified generation | Model bundle manifest or payload mismatch | `make model`, `make base-image`, `./tests/llm_serve_test.sh` | `/models/stories15M` listing and serial log |
| `panic` | Kernel fatal path | Keep the first panic line and surrounding context before rerunning | 80 lines before and after the panic |
| One smoke test flakes once | Host timing, stale artifact, or one-shot service timing | Rerun the same test once, then run the narrow prerequisite | Both test outputs |

## Build Problems

### `stdio.h` Or Newlib Headers Are Missing

Cause: the newlib sysroot has not been built.

Fix:

```sh
make newlib
make build
```

Evidence:

```sh
test -f sysroot/aarch64-elf/include/stdio.h
test -f sysroot/aarch64-elf/lib/libc.a
```

### `build/busybox.elf` Is Missing

Cause: busybox has not been cross-built yet, but the base image or a VFS test
needs it.

Fix:

```sh
make busybox
make base-image
```

Evidence:

```sh
test -f build/busybox.elf
```

### Model Files Are Missing

Cause: the AI model has not been fetched.

Fix:

```sh
make model
make base-image
```

Evidence:

```sh
test -f models/stories260K.bin
test -f models/tok512.bin
test -f models/stories15M-q8.bin
test -f models/tokenizer.bin
test -f build/base-root/models/stories15M/1/manifest.toml
```

### Embedded Swift Flags Fail

Cause: the installed Swift toolchain does not match the Makefile's pinned
toolchain assumptions.

Checks:

```sh
make tools-check
ls ~/Library/Developer/Toolchains
```

Fix: either install the pinned toolchain recorded in [NOTES.md](NOTES.md), or
override `SWIFTC`/`TOOLCHAIN` explicitly:

```sh
make TOOLCHAIN=/path/to/toolchain.xctoolchain build
```

Do not guess Embedded Swift flags from memory. They are version-specific.

## Boot Problems

### QEMU Prints Nothing

Checks:

```sh
test -f build/kernel.elf
test -f build/base.img
test -f build/virt.dtb
```

Rebuild the direct-boot artifacts:

```sh
make build base-image build/virt.dtb
```

Then run the known-good direct profile:

```sh
make run
```

If using a hand-written QEMU command, confirm it includes:

- `-M virt -cpu cortex-a72`
- `-nographic`
- `-global virtio-mmio.force-legacy=false`
- `-device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on`
- `-drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on`
- `-device virtio-blk-device,drive=swosbase`
- `-kernel build/kernel.elf`

### Boot Reaches The TTY Smoke Prompt But Not Login

The early TTY smoke prompt expects one line and then Ctrl-C:

```text
M7 tty: type a line then Enter
```

Type any line and press Enter. When prompted:

```text
M7 tty: running; press Ctrl-C to interrupt
```

Press Ctrl-C. The next stage should print:

```text
swift-os login:
```

### Base Image Did Not Mount

Look for:

```text
M11c: read-only base mounted from disk
```

If it is missing, rebuild the base image:

```sh
make base-image
./tests/vfs_disk_test.sh
```

When using a custom QEMU command, ensure the base disk id is attached to a
virtio-blk device and `force-legacy=false` is present.

### UEFI Boot Fails But Direct Boot Works

Rebuild UEFI artifacts:

```sh
make disk base-image
UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

Check host firmware path from the Makefile:

```sh
make -n disk-run
```

On macOS/Homebrew systems, AAVMF is commonly under
`/opt/homebrew/share/qemu/edk2-aarch64-code.fd`.

## Login Problems

### Known Seeded Credentials

| Login | Password |
| --- | --- |
| `root` | `swordfish` |
| `user` | `swordfish` |
| `guest` | `guest` |

The identity source is:

```text
base/etc/swos/passwd
```

If a local edit changed it, rebuild the base image:

```sh
make base-image
```

### Login Succeeds But A Command Is Denied

Check the current capability mask:

```sh
id
```

Expected masks:

| Account | Mask |
| --- | ---: |
| `root` | `0x3f` |
| `user` | `0xe` |
| `guest` | `0x2` |

Common causes:

- `guest` cannot read the filesystem.
- `user` cannot create sockets.
- Only the console/login path should hold `capConsole`.

Use `root` for network and full-system validation.

## Filesystem Problems

### Writes To `/etc` Or `/bin` Fail

This is expected. The base image is read-only.

Use `/tmp`:

```sh
echo hello >/tmp/hello.txt
cat /tmp/hello.txt
```

To change installed files, edit `base/`, rebuild `build/base.img`, and reboot.

### `/tmp` Data Disappears

This is expected. `/tmp` is RAM-backed scratch and is lost on reboot.

### `ls -l` Shows Unexpected Owner Or Mode

Base-image metadata comes from the packed image. tmpfs files are created with
the current principal as owner. Rebuild the base image after changing files
under `base/`.

Useful checks:

```sh
ls -l /etc
ls -l /tmp
id
```

## Update And Rollback Problems

SwiftOS currently has checked A/B validation paths, not a production online
updater. Base-image updates use the dedicated SWOSBOOT store; kernel-image
updates use signed UEFI ESP slots. For the normal operator flow, see
[UPDATE_GUIDE.md](UPDATE_GUIDE.md).

### `swos-*` Says `permission denied`

All update commands require the privileged console authority. Confirm the guest
session:

```sh
id
```

Use the seeded `root` login for update tests:

```text
root / swordfish
```

The expected failure text is:

```text
permission denied (need capConsole)
```

Run the capability gate if the wrong account is allowed to update:

```sh
./tests/cap_enforce_test.sh
```

### Base-Image Update Does Not Stage Or Activate

`swos-update` requires the update-store boot profile with an attached signed
SWOSBASE payload disk. Rebuild the known-good artifacts and run the focused
gates:

```sh
make base-image updatestore
./tests/ab_stage_test.sh
./tests/ab_activate_test.sh
```

Expected guest markers:

```text
swos-update: payload staged into the inactive slot; run swos-activate then reboot
swos-activate: inactive slot activated (on trial); reboot to use it
```

If the trial boot is healthy but later rolls back, the slot was never confirmed:

```sh
swos-confirm
```

Verify the full base-image safety path:

```sh
./tests/ab_confirm_test.sh
./tests/ab_rollback_test.sh
./tests/ab_flush_test.sh
```

### Kernel Slot Does Not Switch After `swos-kactivate`

Kernel-slot updates require the UEFI disk profile, not direct `-kernel` boot.
Rebuild the ESP disk and base image:

```sh
make disk base-image
```

Then run the focused gates:

```sh
./tests/uefi_kernel_ab_test.sh
./tests/uefi_kstage_test.sh
./tests/uefi_kactivate_test.sh
./tests/uefi_kconfirm_test.sh
```

Expected guest markers:

```text
swos-kstage: active kernel image staged into the inactive ESP slot (verified)
swos-kactivate: inactive kernel slot activated; reboot to use it
```

If a manual run still boots the old slot, confirm the QEMU command boots the
same writable disk image that `swos-kactivate` modified. A fresh disk image has
a fresh ESP and will not contain the previous activation. The current activate
path writes `\EFI\swift-os\kernel-state`; the signed `kernel-boot` manifest may
still report its default active slot while the boot-state selects the trial slot.

### UEFI Loader Rolls Back The Kernel Slot

This can be expected. The loader records per-slot boot attempts in
`\EFI\swift-os\kernel-state`. An unconfirmed active slot that reaches the
attempt cap is treated as unhealthy, so the loader boots the fallback slot and
marks the original slot failed.

Expected rollback markers:

```text
UEFI: kernel slot A boot attempt 0x0000000000000003
UEFI: kernel slot A unconfirmed after 0x0000000000000003 attempts, rolling back to slot B
UEFI: booted kernel slot B
```

Verify boot-state persistence and rollback:

```sh
./tests/uefi_kattempt_test.sh
./tests/uefi_kconfirm_test.sh
./tests/uefi_krollback_test.sh
```

If the trial kernel is healthy, log in and run:

```sh
swos-kconfirm
```

That marks the booted slot `CONFIRMED` in `\EFI\swift-os\kernel-state`, resets
its attempt counter, and prevents later healthy boots from exercising rollback.
Repeated unconfirmed trials are expected to roll back.

## Networking Problems

### Socket Program Says `socket failed`

Checks:

1. Was QEMU launched with `-netdev user,...` and `-device virtio-net-device`?
2. Are you logged in as `root` or another principal with `capNet`?
3. Did the kernel detect virtio-net during boot?

Use the known-good network profile from [NETWORKING_GUIDE.md](NETWORKING_GUIDE.md#qemu-network-profiles).

### `curl 127.0.0.1:8080` Cannot Reach `/bin/httpd`

Inside the guest, confirm:

```sh
/bin/httpd
```

The serial log should include:

```text
httpd: listening on 8080
```

Host QEMU must include a matching host forward:

```text
hostfwd=tcp:127.0.0.1:8080-:8080
```

Then:

```sh
curl http://127.0.0.1:8080/
```

If port 8080 is already used on the host, pick another host port:

```text
hostfwd=tcp:127.0.0.1:18080-:8080
```

and connect to `http://127.0.0.1:18080/`.

### TCP Or UDP Echo Does Not Reply

`/bin/tcpecho` and `/bin/udpecho` are one-shot servers. Start a fresh guest
command for each attempt.

TCP host forward:

```text
hostfwd=tcp:127.0.0.1:5555-:5555
```

UDP host forward:

```text
hostfwd=udp:127.0.0.1:5555-:5555
```

Known-good tests:

```sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
```

### DNS Fails

With QEMU user networking, the default resolver is slirp DNS at `10.0.2.3`.

Inside the guest:

```sh
/bin/nslookup example.com
```

If a test uses an explicit DNS server, confirm the host responder started and
the QEMU command includes the expected UDP path. Use:

```sh
./tests/dns_test.sh
```

### IPv6 Host Forwarding Is Skipped

On Darwin, QEMU/slirp IPv6 host forwarding can be unavailable or inconsistent.
The test suite still validates the IPv6 protocol core and link-local smoke path.
Treat skipped Darwin IPv6 hostfwd echo tests as host-environment limitations
unless the protocol-core unit tests fail too.

## Package Problems

### `/usr/bin/pkghello` Is Missing

Build the package fixture:

```sh
make package-fixture
```

Then boot with both the base image and the package payload image:

```text
-drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on
-device virtio-blk-device,drive=swosbase
-drive file=build/pkghello-payload.img,format=raw,if=none,id=swospkg0,readonly=on
-device virtio-blk-device,drive=swospkg0
```

Run:

```sh
make package-overlay-test
```

Remember: `.swpkg` creation and payload extraction are host-side today. Guest
install works through the local-file form, `pkg install FILE`, through the
signed static HTTP repository fixture, `pkg repo set URL && pkg update` or
`pkg update URL` followed by `pkg install NAME`, and through the static-host
ports fixture for Lua, zlib, bzip2, zstd, xz, libarchive, ca-certificates, OpenSSL, pcre2, tzdata, nginx, and
sqlite.
Name-based dependency resolution and streamed repository package installs are
implemented for signed catalogs. Remove, upgrade, rollback,
version-constraint solving, and public hosted channels are future work.

For the package-store boot path, use:

```sh
make package-store-fixture
make package-store-test
```

For the local install path, use:

```sh
make package-local-install-fixture
make package-local-install-test
```

For the signed repository install path, use:

```sh
make package-repo-fixture
make package-repo-install-test
```

The tested guest flow is:

```sh
pkg repo set http://10.0.2.2:<port>/good/aarch64/current
pkg repo show
pkg update
pkg search pkghello
pkg info pkghello
pkg install pkghello
/usr/bin/pkghello
```

The serial log should include:

```text
P3: package store active generation
P3: package store payload mounted
pkg: catalog updated
depends: pkgdep
pkg: installed pkgdep-1.0.0_1
pkg: installed pkghello-1.0.0_1
```

If `pkg update [URL]` fails, confirm that the base image contains
`/etc/pkg/repo-root.pub`, the host HTTP server is serving the same fixture that
produced the key, and the guest was booted with virtio-net. The repository
client also rejects expired catalogs, catalogs whose package entries target the
wrong architecture, target, ABI, or linkage, and catalogs with invalid
dependency entries.

If `pkg install NAME` fails after a successful update, inspect
`build/pkgrepo-root/aarch64/current`, check whether the guest printed
`pkg: package SHA-256 mismatch`, and rerun `make package-repo-install-test`.

For the ports seed static-host path, use:

```sh
make ports-static-host-publish
make package-static-host-repo-install-test
make ports-hosted-url-verify-test
make package-static-host-dns-repo-install-test
```

The tested guest flow is:

```sh
pkg update
pkg search lua
pkg search zlib
pkg install lua
pkg install zlib
/usr/bin/lua -e 'print(21 * 2)'
echo static-host-ok > /tmp/zlib.txt
/usr/bin/minigzip /tmp/zlib.txt
/usr/bin/minigzip -d /tmp/zlib.txt.gz
cat /tmp/zlib.txt
```

The serial log should include:

```text
pkg: catalog updated
pkg: installed lua-5.4.8_1
pkg: installed zlib-1.3.1_1
42
static-host-ok
```

If this path fails, inspect `build/ports-static-host-root`, verify that
`hosted-repo.json`, `repo-root.pub`, and `SHA256SUMS` exist, and rerun
`make ports-static-host-publish`. The guest still needs virtio-net and a
default repository URL pointing at the served `/aarch64/current` path. If the
DNS-hosted smoke fails, confirm that the fixture DNS server started, the URL is
`http://host/aarch64/current`, and `/bin/pkg` did not print `pkg: bad URL`.
Public production package channels are not implemented yet; these are local
static-host and hosted-URL fixtures.

### `swpkg verify` Fails

Rebuild the fixture from source inputs:

```sh
rm -f build/pkghello.swpkg build/pkghello-payload.img
make package-fixture
```

Inspect the package:

```sh
build/swpkg inspect build/pkghello.swpkg
build/swpkg verify build/pkghello.swpkg
```

Package paths must live under `/usr`.

## LLM Inference Problems

### `/bin/llm` Cannot Load The Model

Prepare and repack model files:

```sh
make model
make base-image
```

Inside the guest:

```sh
ls -l /models
/bin/llm
```

Run the acceptance test:

```sh
./tests/llm_run_test.sh
```

### `/bin/llm` Is Slow

This is expected under QEMU TCG. The command proves isolated EL0 inference and
reference output, not production throughput.

### `/bin/llmd` Cannot Load The Model Or Tokenizer

Prepare and repack the serving bundle:

```sh
make model
make base-image
```

The default server expects a verified bundle inside the guest:

```text
/models/stories15M/1/manifest.toml
/models/stories15M/1/model.bin
/models/stories15M/1/tokenizer.bin
```

The checked-in image also stages `/models/stories15M/2` as a deliberately
corrupt generation so the fallback path is exercised during the serving test.

Inside the guest:

```sh
ls -l /models
/bin/llmd
```

Expected serial markers:

```text
llmd: generation 2 rejected (model size/sha256 mismatch)
llmd: bundle stories15M generation 1 verified (ed25519+sha256)
llmd: model int8 Q8_0 GS=32
llmd: serving on 8080
```

Run the acceptance test:

```sh
./tests/llm_serve_test.sh
```

### `/bin/llmd` Starts Or Completes Slowly

This is expected under QEMU TCG. The default serving path verifies bundle
manifest signatures and payload hashes, parses the full 32000-entry tokenizer,
and demand-pages the quantized `stories15M` checkpoint before or during the
first request. Treat the current serving path as a correctness and integration
path, not as a throughput target.

## Driver-Service Smoke Problems

### `make c5-device-authority-test` Fails

The C5 gate boots QEMU with `SMP_CPUS=4` and `virtio-keyboard-device`, starts
`/bin/drvsvcdemo`, expects `/bin/drvinputd` to recover across two generations,
and validates the discovered `virtio-input.0` device grant plus C5d/C5e
metadata and withheld-authority markers. Rebuild the normal prerequisites and
run the focused gate:

```sh
make build build/virt-smp4.dtb base-image
make c5-device-authority-test
```

Expected serial markers include:

```text
drvsvc: C5a supervisor starting
drvsvc: generation 1 ready
drvsvc: generation 1 event
drvsvc: generation 1 stopped
drvsvc: generation 2 ready
drvsvc: generation 2 event
drvsvc: C5c device manifest matched
drvsvc: C5c discovery exhausted
drvsvc: C5d virtio-input metadata discovered
drvsvc: C5b device grant claimed
drvsvc: C5c virtio-input grant matched
drvsvc: C5b device grant moved
drvinputd: C5b device grant accepted
drvinputd: C5c virtio-input grant accepted
drvsvc: C5b device busy while service owns grant
drvsvc: generation 2 stopped
drvsvc: C5b device grant reclaimed
C5a OK: restartable driver service recovered over IPC
C5b OK: opaque device handle transferred and released
C5c OK: virtio-input device grant discovered and matched
C5d OK: virtio input discovery metadata surfaced
C5e OK: device authority withheld until explicit handoff
```

The broad headless boot path exercises the same lifecycle through
`pseudo-input.0` and should instead print
`C5c OK: device discovery manifest matched pseudo input`.

If the test fails, keep the serial tail printed by
`tests/driver_service_test.sh`. A marker such as `drvinputd: missing endpoint
args`, `drvsvc: ready message mismatch`, or `drvsvc: service wait failed`
usually points at endpoint inheritance, IPC transfer, or process wait behavior
rather than at real hardware. C5e proves the future MMIO/IRQ/DMA authority bits
remain clear; it still does not hand MMIO, IRQ, DMA, or virtio-input queue
ownership to userland yet.

## Test Driver Problems

Many acceptance tests drive an interactive serial login through a FIFO. A busy
host can occasionally delay QEMU enough that a line lands late or a one-shot
network server times out.

When a single smoke test fails:

1. Rerun the exact test once.
2. If it repeats, keep the serial log printed by the test.
3. Run the narrower prerequisite if one exists (`make base-image`, `make
   package-fixture`, `make model`).
4. Only then run the full `make test` again.

Useful targeted tests:

```sh
./tests/boot_test.sh
./tests/console_login_test.sh
./tests/vfs_disk_test.sh
./tests/package_overlay_test.sh
./tests/httpd_test.sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
./tests/top_test.sh
./tests/llm_run_test.sh
./tests/driver_service_test.sh
```

### Host Port Collisions

Most tests choose randomized host ports. If you write a manual command and bind
8080 or 5555, confirm the port is free:

```sh
lsof -iTCP:8080 -sTCP:LISTEN
lsof -iTCP:5555 -sTCP:LISTEN
```

Use another host-side port if needed; the guest port can stay fixed.

### Stale Generated Artifacts

When behavior looks impossible, remove only generated outputs, not source files:

```sh
make clean
make build base-image
```

For slow prerequisites:

```sh
make newlib
make busybox
make model
```

## What To Include In A Bug Report

Include:

- Git commit: `git log -1 --oneline`.
- Branch and dirty state: `git status --short --branch`.
- Exact command that failed.
- Host OS and QEMU version.
- Serial log tail from the first failing marker.
- Whether the targeted test fails repeatedly.
- Any local tool overrides (`SWIFTC`, `TOOLCHAIN`, `QEMU`, `LLVM`, `LDBIN`).

Do not include only "make test failed"; the useful part is the first failing
test and its serial region.

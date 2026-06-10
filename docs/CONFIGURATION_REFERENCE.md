# SwiftOS Configuration Reference

This reference documents the build, boot, test, and guest defaults used by the
current checked-in SwiftOS system. It is the place to look when you need the
exact Make variables, generated artifacts, QEMU profiles, seeded accounts,
runtime paths, or acceptance-test knobs.

Use this with:

- [GETTING_STARTED.md](GETTING_STARTED.md) for the first boot.
- [INSTALLATION_GUIDE.md](INSTALLATION_GUIDE.md) for choosing and verifying
  direct, UEFI, graphical, and VirtualBox boot profiles.
- [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md) for operator workflows.
- [PACKAGE_GUIDE.md](PACKAGE_GUIDE.md) for package artifact and package-store
  workflows.
- [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md) for in-guest command syntax.
- [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) for adding userland programs.

## Defaults At A Glance

| Area | Default |
| --- | --- |
| Architecture | `aarch64` |
| Kernel/userland ABI target | `aarch64-none-none-elf` |
| Primary board | QEMU `virt` |
| Direct boot CPU | `cortex-a72` |
| Direct boot RAM | `256M` |
| Direct console | QEMU `-nographic` serial |
| Direct kernel image | `build/kernel.elf` |
| Direct base filesystem | `build/base.img` attached read-only through virtio-blk |
| Direct DTB | `build/virt.dtb` loaded at `0x4FF00000` |
| UEFI firmware | AAVMF/edk2 AArch64 firmware |
| UEFI disk image | `build/swift-os.img` |
| Guest init | `/bin/console-login` |
| Login shell | `/bin/busybox` `ash` |
| Writable guest storage | `/tmp` tmpfs only |
| Package overlay fixture | `build/pkghello-payload.img` |
| Package-store fixture | `build/pkgstore-pkghello.img` |
| LLM model files | `stories260K.bin` and `tok512.bin` staged directly under `/models`; verified `stories15M` serving generations staged under `/models/stories15M` |

The target is static and intentionally small. There is no Linux syscall ABI, no
dynamic loader, and no persistent writable guest filesystem in the current
product profile.

## Toolchain Variables

The top-level `Makefile` is the source of truth for host tool defaults. Every
variable below can be overridden on the `make` command line.

| Variable | Default | Purpose |
| --- | --- | --- |
| `TOOLCHAIN` | `$(HOME)/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain` | Embedded Swift toolchain root |
| `SWIFTC` | `$(TOOLCHAIN)/usr/bin/swiftc` | Target Embedded Swift compiler |
| `HOST_SWIFTC` | `/usr/bin/swiftc` | Host Swift compiler for tests and tools |
| `LLVM` | `/opt/homebrew/opt/llvm/bin` | LLVM tool directory |
| `CLANG` | `$(LLVM)/clang` | C, assembly, and EFI compile driver |
| `OBJCOPY` | `$(LLVM)/llvm-objcopy` | Kernel binary extraction |
| `LDBIN` | `/opt/homebrew/opt/lld/bin/ld.lld` | ELF linker for the kernel |
| `LLDLINK` | `/opt/homebrew/opt/lld/bin/lld-link` | PE/COFF linker for the EFI app |
| `AAVMF_CODE` | `/opt/homebrew/share/qemu/edk2-aarch64-code.fd` | AArch64 UEFI firmware |
| `QEMU` | `qemu-system-aarch64` | QEMU binary used by make targets and tests |
| `GDB` | `aarch64-elf-gdb` | Debugger for the QEMU gdbstub |
| `NEWLIB_GCC` | `aarch64-elf-gcc` | GNU cross compiler used for newlib-linked userland |

Examples:

```sh
make SWIFTC=/path/to/swiftc build
make QEMU=/path/to/qemu-system-aarch64 run
make AAVMF_CODE=/path/to/edk2-aarch64-code.fd disk-run
```

Check resolved tools:

```sh
make tools-check
```

Embedded Swift flags are toolchain-version-specific. Confirm the current
Makefile and [NOTES.md](NOTES.md) before changing them.

## Board Selection

`BOARD` selects the target board configuration.

| Value | Status | Kernel physical base | Notes |
| --- | --- | ---: | --- |
| `qemu` | Default, primary | `0x40080000` | QEMU `virt`, RAM base `0x40000000` |
| `virtualbox` | Best-effort | `0x08080000` | VirtualBox ARM profile; see [VIRTUALBOX.md](VIRTUALBOX.md) |

Examples:

```sh
make BOARD=qemu build
make BOARD=virtualbox disk
```

Changing `BOARD` changes the link/load base and board compile defines. The
Makefile tracks the active board in `build/.board` and removes board-dependent
artifacts when the value changes. Board-independent, slow artifacts such as
busybox, the packed base image, and the newlib sysroot are kept.

## Build Targets

| Target | Purpose |
| --- | --- |
| `make build` | Build `build/kernel.elf` and `build/kernel.bin`. |
| `make base-image` | Build `build/base.img` from `base/`, staged `/bin`, and model files. |
| `make run` | Build direct-boot prerequisites and boot QEMU on the serial console. |
| `make debug` | Boot QEMU with `-s -S`, paused for debugger attach. |
| `make gdb` | Attach `GDB` to QEMU's gdbstub on `:1234`. |
| `make uefi` | Build the AArch64 EFI application at `build/BOOTAA64.EFI`. |
| `make uefi-run` | Boot through AAVMF using a QEMU virtual-FAT ESP. |
| `make disk` | Build the bootable GPT image `build/swift-os.img`. |
| `make disk-run` | Boot the GPT disk image through AAVMF. |
| `make run-gfx` | Boot the UEFI disk with ramfb, virtio keyboard, and a Cocoa display. |
| `make model` | Fetch LLM demo checkpoints/tokenizers and build the Q8 serving artifacts. |
| `make swpkg` | Build the host-side `.swpkg` tool. |
| `make pkgstore` | Build the host-side package-store image tool. |
| `make package-fixture` | Build and verify the sample package plus payload image. |
| `make package-store-fixture` | Build and inspect the sample package-store image. |
| `make package-overlay-test` | Run the package overlay acceptance test. |
| `make package-store-test` | Run the package-store boot activation acceptance test. |
| `make package-static-host-repo-install-test` | Run the hosted-layout package repository install test. |
| `make ports-hosted-url-verify-test` | Verify the static package host root through an HTTP URL from the host. |
| `make package-static-host-dns-repo-install-test` | Run target-side package install from a DNS-resolved hosted repository URL. |
| `make test` | Run host tests plus QEMU acceptance tests. |
| `make smp-test` | Run the default SMP boot smoke. |
| `make smp-release-guard` | Run static SMP release-readiness contract checks. |
| `make smp-release-contract` | Alias for the SMP release-readiness guard. |
| `make s4-resource-stress-test` | Run the SMP resource-boundary stress gate under `-smp 4`. |
| `make smp-cpu-utilization-test` | Run the per-CPU utilization `top` gate under `-smp 4`. |
| `make s5-run-any-placement-test` | Run the S5f run-any EL0 placement gate under `-smp 4`. |
| `make c5-driver-service-test` | Run the C5 driver-service/device-discovery smoke under `-smp 4`. |
| `make c5-device-handle-test` | Run the C5b opaque device-handle handoff gate under `-smp 4`. |
| `make c5-device-discovery-test` | Alias for the focused C5c virtio-input discovery and grant handoff gate. |
| `make s0c-test` | Run only the SMP state-audit target. |
| `make s0-test` | Run the S0 SMP readiness gate. |
| `make s1-test` | Run the Phase 1 SMP readiness gate. |
| `make newlib` | Build the local newlib sysroot. |
| `make busybox` | Build the static busybox binary used as the shell. |
| `make busybox-check` | Validate the busybox configuration. |
| `make clean` | Remove generated build products under `build/`. |
| `make tools-check` | Print resolved tool paths and versions. |

`make clean` intentionally removes generated artifacts, not downloaded
toolchains. Re-run `make model`, `make newlib`, or `make busybox` when those
inputs are missing or stale.

## Build Artifacts

| Artifact | Producer | Consumer |
| --- | --- | --- |
| `build/kernel.elf` | `make build` | Direct QEMU `-kernel`, debugger symbols |
| `build/kernel.bin` | `make build` | UEFI loader embedding |
| `build/base.img` | `make base-image` | Read-only guest base filesystem |
| `build/virt.dtb` | QEMU DTB capture target | Direct QEMU boot |
| `build/virt-smp4.dtb` | QEMU DTB capture target | SMP tests |
| `build/BOOTAA64.EFI` | `make uefi` | EFI System Partition |
| `build/swift-os.img` | `make disk` | UEFI/GPT boot |
| `build/base-root` | `make base-image` | Staging tree before packing |
| `build/basepack` | host Swift tool | Packs the base image |
| `build/swpkg` | host Swift tool | Creates, verifies, and extracts packages |
| `build/pkgstore` | host Swift tool | Creates and inspects package-store images |
| `build/pkghello.swpkg` | `make package-fixture` | Sample package file |
| `build/pkghello-payload.img` | `make package-fixture` | Read-only package payload overlay |
| `build/pkgstore-pkghello.img` | `make package-store-fixture` | Package-store bootstrap image |
| `build/pkgstore-lua-install.img` | `make package-lua-install-fixture` | Writable package-store image used by Lua/ports install tests |

## Direct QEMU Profile

The default direct boot profile is:

```text
-M virt
-cpu cortex-a72
-m 256M
-nographic
-global virtio-mmio.force-legacy=false
-device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on
-drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on
-device virtio-blk-device,drive=swosbase
-kernel build/kernel.elf
```

Important details:

- `force-legacy=false` selects the modern virtio-mmio transport used by the
  drivers.
- The DTB is loaded into guest RAM at `0x4FF00000`.
- The base image is read-only and identified as `swosbase`.
- `make run` does not attach a NIC by default.

## Network QEMU Profile

Attach virtio-net when running socket programs. This common profile forwards
host TCP 8080 to guest TCP 8080, and host TCP/UDP 5555 to guest port 5555:

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

Guest defaults:

| Guest service | Port | Host access with the profile above |
| --- | ---: | --- |
| `/bin/httpd` | TCP 8080 | `http://127.0.0.1:8080/` |
| `/bin/llmd` | TCP 8080 | `http://127.0.0.1:8080/health` |
| `/bin/tcpecho` | TCP 5555 | `nc 127.0.0.1 5555` |
| `/bin/udpecho` | UDP 5555 | `nc -u 127.0.0.1 5555` |
| `/bin/tcpget` outbound default | TCP `10.0.2.2:5555` | Host listener on TCP 5555 |
| `/bin/nslookup` default resolver | UDP `10.0.2.3:53` | QEMU slirp DNS |

The seeded `root` principal has `capNet`; `user` and `guest` do not.
`/bin/httpd` and `/bin/llmd` both bind guest TCP port 8080, so run one at a
time or use separate boots.

## UEFI And Graphical Profiles

UEFI boot uses AAVMF and an EFI System Partition containing
`\EFI\BOOT\BOOTAA64.EFI`.

Virtual-FAT UEFI boot:

```sh
make uefi-run
```

GPT disk UEFI boot:

```sh
make disk-run
```

Graphical smoke boot:

```sh
make run-gfx
```

The graphical profile adds:

- `ramfb` for an EFI GOP framebuffer.
- `virtio-keyboard-device` for input smoke coverage.
- `-display cocoa` on macOS hosts.
- `-serial stdio` so serial logs remain visible.

The current product shell remains serial-first.

## Guest Defaults

### Accounts

The seeded identity source is `base/etc/swos/passwd`.

| Login | Password | Principal | Capability mask | Operational role |
| --- | --- | ---: | ---: | --- |
| `root` | `swordfish` | 1 | `0x3f` | Full demo and test authority |
| `user` | `swordfish` | 2 | `0x0e` | Spawn, filesystem read, tmpfs write |
| `guest` | `guest` | 3 | `0x02` | Spawn-only capability checks |

The compatibility files `base/etc/passwd` and `base/etc/group` are generated or
maintained for POSIX-like tools. Kernel authorization uses SwiftOS principals,
capabilities, and handle rights.

### Filesystem

| Path | Source | Writable | Lifetime |
| --- | --- | --- | --- |
| `/bin` | `build/base.img` | No | Immutable across boot |
| `/etc` | `build/base.img` | No | Immutable across boot |
| `/www` | `build/base.img` | No | Immutable across boot |
| `/models` | `build/base.img` | No | Immutable across boot |
| `/tmp` | tmpfs | Yes, with `capTmpWrite` | Lost on reboot |
| `/usr/bin/pkghello` | package overlay fixture | No | Present only when overlay is attached |

To change installed base files, edit `base/` or staged userland sources, then
rebuild `build/base.img`.

To change package payload files, rebuild the package fixture or the relevant
`.swpkg` package.

### Console

`/bin/console-login` runs as init. After successful authentication it starts the
configured shell. When the shell exits, console-login starts again for the next
session.

The default shell is busybox `ash`, staged as `/bin/busybox`.

## Package Overlay Configuration

The package fixture builds:

| Artifact | Meaning |
| --- | --- |
| `build/pkghello.swpkg` | Sample package container |
| `build/pkghello-payload.img` | Extracted read-only payload image |
| `build/pkgstore-pkghello.img` | Package-store image with active generation 1 |
| `/usr/bin/pkghello` | Guest-visible executable from the payload |

Build and verify it:

```sh
make package-fixture
```

Boot with the payload attached:

```sh
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

Package overlays are read-only. The current target-side install path is the
narrow local `.swpkg` flow backed by a writable package-store image:

```sh
make package-local-install-fixture
make package-local-install-test
```

Repository install with name-based dependency resolution works for signed
fixtures. Remove, upgrade, rollback, public hosting, and version-constraint
solving remain future package-manager work.

For the package-store boot profile and current package limits, see
[PACKAGE_GUIDE.md](PACKAGE_GUIDE.md).

## Test Harness Knobs

Most acceptance tests accept a small set of environment overrides.

| Variable | Used by | Purpose |
| --- | --- | --- |
| `QEMU` | Most QEMU tests | Select QEMU binary |
| `TIMEOUT` | Boot and SMP tests | Override boot wait in seconds |
| `AAVMF_CODE` | UEFI and framebuffer tests | Select AAVMF firmware |
| `HOST_SWIFTC` | Host Swift tests and SMP preflight | Select host Swift compiler |
| `LLVM_OBJDUMP` | SMP object-layout tests | Select `llvm-objdump` |
| `FDT_TEST` | SMP S1 preflight | Reuse a prebuilt FDT test binary |
| `SMP_CPUS` | SMP and UEFI tests | Select CPU count, usually 1 to 8 |
| `SMP_DTB` | SMP and C5 driver-service/device-discovery tests | Provide a prebuilt SMP DTB |
| `SMP_HEADROOM_CPUS` | SMP headroom test | Space-separated CPU counts to probe |
| `SMP_S1_PREFLIGHT_CPUS` | SMP S1 preflight | Space-separated CPU counts to validate |
| `UEFI_BOOT` | UEFI boot test | Select `disk` or `fat` boot mode |
| `HTTPD_HOST_PORT` | HTTP server test | Override host-forwarded HTTP port |
| `LLMD_HOST_PORT` | LLM serving test | Override host-forwarded LLM server port |
| `NET_ZC_HOST_PORT` | HTTP throughput test | Override host-forwarded throughput port |
| `TCP_CONNECT_HOST_PORT` | TCP active-open test | Override host listener port |
| `C4B_SOCK_HOST_PORT` | IPC socket-transfer test | Override host UDP port |

Network tests choose high host ports automatically when their override is not
set. Use overrides when running multiple trees on one host or when a firewall
allows only a specific range.

Examples:

```sh
QEMU=/opt/qemu/bin/qemu-system-aarch64 ./tests/boot_test.sh
TIMEOUT=180 ./tests/smp_boot_test.sh
HTTPD_HOST_PORT=18080 ./tests/httpd_test.sh
LLMD_HOST_PORT=18081 ./tests/llm_serve_test.sh
SMP_CPUS=4 UEFI_BOOT=disk ./tests/uefi_boot_test.sh
SMP_CPUS=4 SMP_DTB=build/virt-smp4.dtb ./tests/driver_service_test.sh
```

## Common Configuration Changes

### Use A Different Swift Toolchain

```sh
make TOOLCHAIN=/path/to/swift-toolchain build
```

Then run:

```sh
make tools-check
make build
```

If Embedded Swift flags changed between toolchains, update the Makefile and
document the decision in [NOTES.md](NOTES.md).

### Change Guest Base Files

1. Edit files under `base/`.
2. Rebuild the base image:

```sh
make base-image
```

3. Boot or test with the rebuilt `build/base.img`.

### Add A Native `/bin` Program

Follow [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md). The short version is:

1. Add the userland source.
2. Add a build rule and ELF variable in the Makefile.
3. Stage the resulting ELF in the `$(BASE_IMG)` rule.
4. Add an acceptance test.
5. Update [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md).

### Change Seeded Accounts

1. Edit `base/etc/swos/passwd`.
2. Keep compatibility views aligned when relevant.
3. Rebuild `build/base.img`.
4. Run login and capability tests:

```sh
./tests/console_login_test.sh
./tests/cap_enforce_test.sh
```

### Change Network Ports

For manual QEMU runs, edit the `hostfwd=` entries in the QEMU command. For
tests, prefer the port override variables listed above.

After changing socket behavior, run the relevant acceptance tests:

```sh
./tests/httpd_test.sh
./tests/tcp_echo_test.sh
./tests/udp_echo_test.sh
./tests/tcp_connect_test.sh
./tests/dns_test.sh
./tests/llm_serve_test.sh
```

### Change Package Fixture Contents

1. Edit `fixtures/pkghello/manifest.json` or the staged package root rule.
2. Rebuild:

```sh
make package-fixture
```

3. Verify in QEMU:

```sh
make package-overlay-test
```

## Verification Matrix

| Change | Minimum verification |
| --- | --- |
| Tool path or compiler override | `make tools-check`, `make build` |
| Kernel or direct QEMU profile | `make build`, `./tests/boot_test.sh` |
| Base filesystem content | `make base-image`, `./tests/vfs_disk_test.sh`, command-specific tests |
| Login or identity store | `./tests/console_login_test.sh`, `./tests/cap_enforce_test.sh` |
| Network profile | Relevant socket test plus `./tests/virtio_net_test.sh` |
| LLM serving profile | `make base-image`, `./tests/llm_serve_test.sh` |
| Package overlay | `make package-overlay-test` |
| Package-store activation | `make package-store-test` |
| Local package install | `make package-local-install-test` |
| Signed repository install | `make package-repo-install-test` |
| Static-host or hosted package repository | `make package-static-host-repo-install-test`, `make ports-hosted-url-verify-test`, or `make package-static-host-dns-repo-install-test` |
| UEFI loader or disk | `make disk`, `./tests/uefi_boot_test.sh` |
| SMP boot parameters | `make s1-test`, `make s4-resource-stress-test`, or the milestone-specific SMP target |
| C5 driver-service/device-discovery path | `make c5-device-discovery-test` |
| Documentation-only configuration update | Markdown link check, `git diff --check`, and a build or relevant acceptance test |

When in doubt, run `make test`. It is the broad acceptance gate for this
repository revision.

## Not Configurable Yet

These are intentional current limits:

- No Linux ABI mode.
- No dynamic loader.
- No persistent writable filesystem.
- No public hosted package channel, package upgrade, remove, rollback,
  version-constraint solver, or streaming large-package install path. Local
  `pkg install FILE` and P5c `pkg repo set`/`pkg update [URL]`/
  `pkg install NAME` work for signed fixtures when a writable package-store
  image is attached, including name-based dependency resolution and rejection
  paths for expired or incompatible catalogs and package hash mismatches.
- No production certificate store for `tlsget`.
- No default graphical desktop shell.

Track product hardening in
[RISK_REMEDIATION_ROADMAP.md](RISK_REMEDIATION_ROADMAP.md).

# SwiftOS Installation Guide

This guide explains how to build, install, boot, and verify the current SwiftOS
image. SwiftOS does not yet ship as a downloadable end-user installer; the
supported installation flow today is to build the system from this repository
and run one of the checked-in boot profiles.

Use this guide when you need to choose the right artifact:

- Direct serial QEMU boot for everyday development and demos.
- UEFI/GPT disk image boot through QEMU+AAVMF for firmware validation.
- Graphical smoke boot for framebuffer and keyboard checks.
- VirtualBox ARM preparation for best-effort Apple Silicon validation.

For the shortest first login path, see [GETTING_STARTED.md](GETTING_STARTED.md).
For exact variables and artifacts, see
[CONFIGURATION_REFERENCE.md](CONFIGURATION_REFERENCE.md).
For deployment candidate assembly, validation evidence, handoff, and rollback,
see [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md).

## Supported Install Targets

| Target | Status | Artifact | Verification |
| --- | --- | --- | --- |
| QEMU direct serial boot | Primary development path | `build/kernel.elf`, `build/base.img`, `build/virt.dtb` | `./tests/boot_test.sh` |
| QEMU UEFI/GPT disk boot | Primary firmware path | `build/swift-os.img` plus `build/base.img` | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| QEMU graphical smoke boot | Smoke path only | `build/swift-os.img`, ramfb, virtio keyboard | `./tests/fb_vi_test.sh` |
| VirtualBox ARM on Apple Silicon | Best effort | `build/swift-os.vdi` from `BOARD=virtualbox` | Manual validation; see [VIRTUALBOX.md](VIRTUALBOX.md) |

Current non-targets:

- No x86-64 PC installer.
- No Linux, Docker, OCI, DEB, RPM, APK, Homebrew, or Nix installation path.
- No persistent writable root filesystem.
- No production bare-metal hardware matrix beyond the documented QEMU and
  best-effort VirtualBox ARM profiles.

## Host Requirements

The default checked-in configuration expects a macOS/Homebrew-style development
host:

| Tool | Default |
| --- | --- |
| Embedded Swift toolchain | `~/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain` |
| Host Swift compiler | `/usr/bin/swiftc` |
| LLVM tools | `/opt/homebrew/opt/llvm/bin` |
| LLD | `/opt/homebrew/opt/lld/bin` |
| QEMU | `qemu-system-aarch64` in `PATH` |
| AAVMF firmware | `/opt/homebrew/share/qemu/edk2-aarch64-code.fd` |

Check resolved paths:

```sh
make tools-check
```

Most paths can be overridden on the command line:

```sh
make QEMU=/path/to/qemu-system-aarch64 AAVMF_CODE=/path/to/edk2-aarch64-code.fd disk-run
```

`aarch64-elf-gcc`, the local newlib sysroot, and busybox sources are required
when rebuilding C/newlib or busybox artifacts. The normal image build reuses
existing generated artifacts when they are already present.

## Artifact Map

| Artifact | Build command | Meaning |
| --- | --- | --- |
| `build/kernel.elf` | `make build` | Kernel image used by direct QEMU `-kernel` boot |
| `build/kernel.bin` | `make build` | Kernel payload embedded into the UEFI loader |
| `build/base.img` | `make base-image` | Immutable read-only guest filesystem |
| `build/virt.dtb` | `make build/virt.dtb` | Device tree loaded for direct QEMU boot |
| `build/BOOTAA64.EFI` | `make uefi` | AArch64 UEFI loader |
| `build/swift-os.img` | `make disk` | GPT disk image with an EFI System Partition |
| `build/swift-os.vdi` | `./run_in_virtual_box.sh` | VirtualBox disk image converted from `build/swift-os.img` |

The base image is separate from the UEFI boot disk in QEMU runs. The firmware
boots from `build/swift-os.img`, while the kernel mounts `build/base.img` as a
read-only virtio-blk device.

## Install Profile: Direct Serial QEMU

Use this profile for day-to-day SwiftOS work. It has the shortest loop and the
strongest test coverage.

Build:

```sh
make build base-image build/virt.dtb
```

Run:

```sh
make run
```

Manual equivalent:

```sh
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 256M -nographic \
  -global virtio-mmio.force-legacy=false \
  -device loader,file=build/virt.dtb,addr=0x4FF00000,force-raw=on \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase \
  -kernel build/kernel.elf
```

Verify:

```sh
./tests/boot_test.sh
```

Expected user-facing result:

```text
swift-os login:
```

Complete the interactive TTY smoke prompt, then log in as `root` with password
`swordfish`.

## Install Profile: UEFI GPT Disk

Use this profile when validating the firmware loader, GPT image, AAVMF handoff,
or disk-boot packaging.

Build:

```sh
make disk base-image
```

Run:

```sh
make disk-run
```

Manual equivalent:

```sh
qemu-system-aarch64 -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
  -drive file=build/swift-os.img,format=raw,if=virtio \
  -global virtio-mmio.force-legacy=false \
  -drive file=build/base.img,format=raw,if=none,id=swosbase,readonly=on \
  -device virtio-blk-device,drive=swosbase
```

Verify:

```sh
UEFI_BOOT=disk ./tests/uefi_boot_test.sh
```

Healthy serial markers include:

```text
swift-os UEFI loader (M10)
UEFI: kernel staged, launching
Hello from Swift kernel
built-in shell (ash)
```

`make uefi-run` is also available for the older virtual-FAT ESP profile. Use the
real GPT disk path when validating installation artifacts.

## Install Profile: Graphical Smoke

SwiftOS is serial-first. The graphical path exists to smoke-test the UEFI
framebuffer and virtio keyboard path, not to provide a desktop shell.

Build and run:

```sh
make run-gfx
```

Verify:

```sh
./tests/fb_vi_test.sh
```

Use this only when you need framebuffer/input evidence. For normal operations,
prefer `make run` or `make disk-run`.

## Install Profile: VirtualBox ARM

VirtualBox ARM on Apple Silicon is best-effort and currently documented as a
hardware-adjacent validation path, not the primary supported runtime.

Prepare the image with the helper script:

```sh
./run_in_virtual_box.sh --check
./run_in_virtual_box.sh
```

The script builds the VirtualBox board profile and converts the raw disk image
to `build/swift-os.vdi`.

Manual build:

```sh
make BOARD=virtualbox disk
VBoxManage convertfromraw build/swift-os.img build/swift-os.vdi --format VDI
```

Important current status:

- The `BOARD=virtualbox` kernel variant is buildable.
- The QEMU+AAVMF disk path remains the reference UEFI target.
- VirtualBox ARM firmware/device behavior differs from QEMU `virt`; see
  [VIRTUALBOX.md](VIRTUALBOX.md) for the known bootloader-launch limitation and
  the exact evidence to collect.

## First Login

Seeded accounts:

| Login | Password | Use |
| --- | --- | --- |
| `root` | `swordfish` | Full seeded authority, including networking |
| `user` | `swordfish` | Filesystem read and tmpfs write without networking |
| `guest` | `guest` | Spawn-only confinement checks |

After login:

```sh
id
cat /etc/motd
ls -l /
ps
top -b -n 2 -d 1
```

The root identity should report `principal=1(root)` and `caps=0x3f`.

## Optional Install Add-Ons

### Networking

`make run` does not attach a NIC. For network services, boot with a virtio-net
device and host forwarding. See [NETWORKING_GUIDE.md](NETWORKING_GUIDE.md).

### Packages

Package payloads and package-store images are attached as additional read-only
virtio-blk disks at boot. See [PACKAGE_GUIDE.md](PACKAGE_GUIDE.md).

### AI Hosting

The base image can include TinyStories model artifacts and the `/bin/llmd`
serving daemon. See [AI_HOSTING_GUIDE.md](AI_HOSTING_GUIDE.md).

## Verification Matrix

Run the narrowest proof for the install path you changed:

| Path | Command |
| --- | --- |
| Tool paths | `make tools-check` |
| Kernel build | `make build` |
| Base image | `make base-image` |
| Direct serial boot | `./tests/boot_test.sh` |
| UEFI GPT disk boot | `UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| UEFI SMP smoke | `SMP_CPUS=4 UEFI_BOOT=disk ./tests/uefi_boot_test.sh` |
| Graphical framebuffer/input smoke | `./tests/fb_vi_test.sh` |
| Full gate | `make test` |

If a QEMU test fails, keep the serial log. If the path is VirtualBox-specific,
also keep the VirtualBox serial raw file and the VM screenshot requested in
[VIRTUALBOX.md](VIRTUALBOX.md).

## Updating Or Rebuilding

Generated artifacts live under `build/`.

```sh
make clean
make build base-image build/virt.dtb
make disk
```

When switching board profiles, use the `BOARD` variable:

```sh
make BOARD=qemu disk
make BOARD=virtualbox disk
```

The Makefile tracks the active board and removes board-dependent artifacts when
the board changes. Slow board-independent inputs such as busybox, newlib, and
model files are kept unless their own targets are rebuilt or cleaned.

For update planning, rollback artifacts, release-candidate validation, and
package or model refresh procedures, see
[UPDATE_GUIDE.md](UPDATE_GUIDE.md).

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `make run` cannot find `build/base.img` | Base image was not built | Run `make base-image` |
| Direct boot has no login prompt | Boot sequence failed before `console-login` | Run `./tests/boot_test.sh` and keep the serial log |
| `make disk-run` cannot find AAVMF | Firmware path differs on the host | Set `AAVMF_CODE=/path/to/edk2-aarch64-code.fd` |
| UEFI loader runs but kernel cannot mount files | `build/base.img` was not attached or is stale | Run `make base-image` and use the documented QEMU command |
| Graphical window opens but no desktop appears | Expected current behavior | Use the serial console; graphical mode is a smoke path |
| VirtualBox produces no loader output | Known best-effort limitation | Follow [VIRTUALBOX.md](VIRTUALBOX.md) and capture requested evidence |

For detailed diagnosis, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

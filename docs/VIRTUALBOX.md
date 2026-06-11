# SwiftOS On VirtualBox ARM

This guide describes the best-effort VirtualBox ARM boot path for Apple Silicon
hosts. Use it when you need firmware-adjacent evidence outside QEMU, or when you
are investigating whether a VirtualBox release can launch the SwiftOS UEFI disk.

VirtualBox ARM is not the primary supported runtime. The primary firmware boot
target remains QEMU with AAVMF:

```sh
make disk-run
```

For the general install matrix, use [Installation Guide](INSTALLATION_GUIDE.md).

## Current Support Status

| Area | Status |
| --- | --- |
| Build a VirtualBox-targeted kernel and disk | Supported by `BOARD=virtualbox` |
| Convert the disk to VDI | Supported with `VBoxManage convertfromraw` |
| Boot the same disk under QEMU+AAVMF | Supported reference check |
| Boot under VirtualBox ARM | Best effort; currently blocked by firmware not launching `\EFI\BOOT\BOOTAA64.EFI` on observed 7.2.x previews |
| Graphics console | Not expected; observed framebuffer is 0x0 |
| Serial evidence | Required for useful reports |

Observed VirtualBox ARM devices differ from QEMU `virt`: RAM starts at
`0x0800_0000`, the PL011 UART is at `0xFFDD_F000`, and the GIC is at
`0xFCD3_0000`. The `BOARD=virtualbox` build relinks the kernel for that map and
uses VirtualBox HAL defaults. The remaining open problem is firmware boot
selection, not the QEMU disk image itself.

## Choose A VirtualBox Evidence Path

Use VirtualBox evidence only for firmware-adjacent investigation. QEMU+AAVMF is
still the reference UEFI path, so every useful VirtualBox report should separate
disk/loader correctness from VirtualBox firmware behavior.

| Need | Run First | Evidence To Keep | What It Proves |
| --- | --- | --- | --- |
| Check whether the host can run the helper | `./run_in_virtual_box.sh --check` | Tool paths and reported VirtualBox version | Host prerequisites are present or the missing dependency is known |
| Prove the SwiftOS disk and loader before opening VirtualBox | `make BOARD=virtualbox disk-run` | QEMU+AAVMF serial log with `UEFI:` lines | The board-specific disk image can boot on the reference firmware path |
| Try the best-effort VirtualBox VM path | `./run_in_virtual_box.sh`, then boot the VM with serial raw-file capture enabled | Serial raw file, screenshot, `VBox.log`, VirtualBox version, VM settings, and `build/swift-os.vdi` hash | Whether the VirtualBox firmware launched `\EFI\BOOT\BOOTAA64.EFI` and how far handoff progressed |
| Report a silent or firmware-setup-only boot | Re-run the QEMU reference check, then capture the failed VirtualBox boot | QEMU reference log plus the full VirtualBox evidence bundle | The disk is healthy and the remaining blocker is likely VirtualBox firmware, NVRAM, storage controller, or board HAL behavior |

## Quick Path

Run the helper:

```sh
./run_in_virtual_box.sh --check
./run_in_virtual_box.sh
```

The script checks host dependencies, builds the VirtualBox board profile, and
creates:

```text
build/swift-os.img
build/swift-os.vdi
```

After the script finishes, create a VirtualBox ARM VM and attach
`build/swift-os.vdi`.

## Manual Build

Build the VirtualBox board profile:

```sh
make BOARD=virtualbox disk
```

Convert the raw GPT disk image to VDI:

```sh
VBoxManage convertfromraw build/swift-os.img build/swift-os.vdi --format VDI
```

Before testing VirtualBox itself, prove the disk/loader path still works under
the reference firmware path:

```sh
make BOARD=virtualbox disk-run
```

That QEMU+AAVMF check should reach the SwiftOS serial boot path. If it does not,
fix the disk or board build before spending time in VirtualBox.

## Create The VM

Use VirtualBox 7.1 or newer on Apple Silicon with ARM guest support.

Recommended VM settings:

| Setting | Value |
| --- | --- |
| Type/version | ARM 64-bit guest, such as Other ARM 64-bit |
| Memory | 256 MB or more |
| CPU | 1 core |
| Firmware | EFI enabled |
| Disk | Existing disk: `build/swift-os.vdi` |
| Boot order | Hard disk enabled |
| Network | Optional for this validation |
| Display | Optional; do not rely on graphics output |

Attach the disk to any storage controller the ARM VM offers. If the VM reaches
the EFI Boot Manager instead of launching SwiftOS, retry with another controller
type before changing the disk image.

## Capture Evidence

Enable serial capture before the first boot:

1. Open VM Settings.
2. Select Serial Ports.
3. Enable Port 1.
4. Set Port Mode to Raw File.
5. Set the path, for example `/tmp/swiftos-virtualbox-serial.log`.

Start the VM and let it run for about 15 seconds. Save:

- the serial raw file;
- a screenshot of the VM window;
- `Logs/VBox.log` from the VM directory;
- the VirtualBox version.

The useful lines begin with `UEFI:`. A healthy QEMU+AAVMF reference run looks
like:

```text
swift-os UEFI loader (M10)
UEFI: kernel staged, launching
Hello from Swift kernel
```

On VirtualBox, the most useful evidence is whether any loader text appears at
all. If there is no loader text, the current blocker is the firmware boot path.
If loader text appears but the kernel stays silent after handoff, collect the
reported memory, ACPI, device-tree, and exception-level lines; that points to
board HAL work.

## Expected Outcomes

| Outcome | Meaning | Next action |
| --- | --- | --- |
| `swift-os UEFI loader` appears | VirtualBox launched the EFI app | Capture all `UEFI:` lines and continue HAL validation |
| Loader reaches `kernel staged, launching` then stops | Firmware worked; kernel board assumptions need work | Report serial log and `VBox.log` |
| No serial or screen output | Current known VirtualBox ARM limitation | Check Boot Manager, controller type, and NVRAM; keep QEMU+AAVMF as reference |
| Firmware setup opens | Disk was not selected as bootable | Confirm disk attachment and boot order |

## Observed VirtualBox ARM Machine Model

The following values were captured from VirtualBox ARM 7.2.x preview logs and
are encoded by the `BOARD=virtualbox` build:

| Resource | QEMU `virt` | VirtualBox ARM observed |
| --- | ---: | ---: |
| RAM base | `0x4000_0000` | `0x0800_0000` |
| Kernel physical base | `0x4008_0000` | `0x0808_0000` |
| PL011 UART MMIO | `0x0900_0000` | `0xFFDD_F000` |
| GIC | QEMU `virt` layout | `0xFCD3_0000` |
| EFI flash | n/a for direct `-kernel` | `0x0400_0000` to `0x07FF_FFFF` |
| PL061 GPIO | not used | `0xFFDD_D000` |
| PL031 RTC | QEMU `virt` RTC | `0xFFDD_E000` |

## Troubleshooting

`VBoxManage` is not found.

: Use the copy inside the app bundle:
  `/Applications/VirtualBox.app/Contents/MacOS/VBoxManage`.

The VM shows firmware setup or Boot Manager.

: The firmware did not boot `\EFI\BOOT\BOOTAA64.EFI`. Confirm the VDI is
  attached, boot order includes the disk, and the controller type is usable by
  the ARM firmware.

The VM has no serial output.

: Confirm Serial Port 1 is enabled in Raw File mode. On the observed ARM board,
  legacy 16550 settings such as `--uart1 0x3f8 4` are not the PL011 console and
  will not capture SwiftOS output.

VirtualBox reports a corrupt NVRAM store.

: Some 7.2 ARM preview builds leave a corrupt NVRAM file after power-off. Delete
  the VM NVRAM file and retry:

```sh
rm -f "$HOME/VirtualBox VMs/SwiftOS/SwiftOS.nvram"
```

Deleting NVRAM can also remove manually added boot entries, so keep testing the
removable-media fallback path `\EFI\BOOT\BOOTAA64.EFI`.

The QEMU reference path works but VirtualBox is silent.

: Treat this as the current known limitation. Keep the serial raw file,
  screenshot, `VBox.log`, VirtualBox version, storage-controller type, and exact
  disk image hash with the report.

## Report Template

```text
VirtualBox version:
Host Mac:
SwiftOS commit:
Build command:
Disk hash:
VM type/version:
Storage controller:
Serial raw file attached: yes/no
Screenshot attached: yes/no
VBox.log attached: yes/no
Observed output:
```

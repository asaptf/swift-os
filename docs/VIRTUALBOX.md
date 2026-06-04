# Running swift-os in VirtualBox (Apple Silicon) — M10.5 validation

This is the manual validation step for **M10.5**: boot the M10 UEFI image under VirtualBox's
experimental ARM support on an Apple Silicon Mac, capture the console, and send the log back so the HAL
can be adapted to VirtualBox's device model.

VirtualBox ARM is a developer preview and its `virt`-style machine model differs from QEMU (UART,
interrupt controller, ACPI vs device tree). So the realistic goal of the **first** run is *diagnostic*:
confirm the firmware launches our loader and capture what hardware it exposes. The kernel may stay silent
after handoff if VirtualBox's UART differs from QEMU's — that is expected, and the loader prints the
information we need *before* it hands off.

## 1. Build the bootable disk image

On the dev host (this repo):

```sh
make disk            # builds build/swift-os.img (GPT + EFI System Partition + BOOTAA64.EFI)
```

`build/swift-os.img` is a real 96 MiB GPT disk: one EFI System Partition (FAT32) containing
`\EFI\BOOT\BOOTAA64.EFI`, which embeds the kernel. It already boots to busybox under QEMU+AAVMF
(`make disk-run`), so it is a known-good image — any VirtualBox-specific failure is about the device
model, not the image.

## 2. Convert the image for VirtualBox

VirtualBox prefers VDI/VMDK over raw. Convert with the bundled tool:

```sh
VBoxManage convertfromraw build/swift-os.img swift-os.vdi --format VDI
```

(`VBoxManage` ships with VirtualBox; run on the machine that has VirtualBox installed.)

## 3. Create the VM

Use VirtualBox **7.1 or newer** on Apple Silicon (the build with ARM guest support).

- **New VM** → Type/Version: an **ARM / 64-bit** guest (e.g. "Linux … ARM 64-bit" / "Other ARM 64-bit").
- **Memory:** 256 MB (matches our bring-up; more is fine).
- **CPU:** 1 core (swift-os is single-core).
- **Firmware: EFI must be enabled** (required for ARM; this is what launches our loader).
- **Disk:** attach `swift-os.vdi` as the VM's hard disk (whatever storage controller the ARM VM offers —
  virtio / NVMe / SATA; any is fine, the firmware enumerates it).
- **Boot order:** hard disk enabled.

## 4. Capture the console

Our loader prints through the UEFI console. Capture it both ways so we do not miss it:

- **Serial to file (preferred):** VM **Settings → Serial Ports → Port 1 → Enable**, Port Mode =
  **Raw File**, Path = e.g. `/tmp/swiftos-serial.log`. After the run, send that file.
- **Screen:** also take a **screenshot** of the VM window after boot — if VirtualBox routes the UEFI
  console to the graphics adapter rather than serial, the text will be on screen.

Start the VM, let it sit ~15 seconds, then grab the serial file and/or screenshot.

## 5. What to send back

The lines beginning `UEFI:` are the payload. From QEMU+AAVMF they look like:

```
swift-os UEFI loader (M10)
UEFI: device tree found at 0x0000000047EF2000
UEFI: CurrentEL 0x0000000000000001 MMU 0x0000000000000001
UEFI: ACPI 2.0 table absent
UEFI: largest RAM region base 0x0000000048000000 size 0x00000000045DD000
UEFI: kernel staged, launching (no more firmware output)
Hello from Swift kernel
...
```

From VirtualBox we specifically want:

- whether **`swift-os UEFI loader (M10)`** appears at all (proves VBox launches our EFI app);
- **`device tree found …`** vs **`device tree NOT in config table`** (DTB vs ACPI-only — VBox is likely
  ACPI, which changes how we discover hardware);
- **`ACPI 2.0 table present/absent`**;
- the **`largest RAM region base … size …`** (VBox's RAM base may not be `0x40000000`);
- **`CurrentEL …`** (do we enter at EL1 or EL2?);
- whether anything appears **after** `kernel staged, launching` (if `Hello from Swift kernel` shows, the
  kernel's UART assumptions already match; if not, we adapt the HAL to VBox's UART/RAM).

Paste the captured `UEFI:` lines (and any later output) back into the session. That report is what M10.5
uses to adjust `kernel/arch/aarch64/platform.swift` (and, if VBox is ACPI-only, to add minimal ACPI
table discovery alongside the M9 device-tree path).

## Troubleshooting

- **VM shows the firmware setup/Boot Manager, no loader text:** the firmware did not find
  `\EFI\BOOT\BOOTAA64.EFI`. Re-check the disk is attached and bootable; in the EFI Boot Manager you can
  also pick the disk manually.
- **`VBoxManage` not found:** it is inside the VirtualBox app bundle
  (`/Applications/VirtualBox.app/Contents/MacOS/VBoxManage`).
- **No serial output but a screen:** the firmware is using the graphics console; screenshot it.

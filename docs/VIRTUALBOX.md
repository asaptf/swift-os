# Running swift-os in VirtualBox (Apple Silicon) — M10.5 validation

This is the manual validation step for **M10.5**: boot the M10 UEFI image under VirtualBox's
experimental ARM support on an Apple Silicon Mac, capture the console, and send the log back so the HAL
can be adapted to VirtualBox's device model.

VirtualBox ARM is a developer preview and its `virt`-style machine model differs from QEMU (UART,
interrupt controller, ACPI vs device tree). So the realistic goal of the **first** run is *diagnostic*:
confirm the firmware launches our loader and capture what hardware it exposes. The kernel may stay silent
after handoff if VirtualBox's UART differs from QEMU's — that is expected, and the loader prints the
information we need *before* it hands off.

## 0. One command (recommended)

`./run_in_virtual_box.sh` checks every dependency (Homebrew, llvm/clang, lld, mtools, gptfdisk, the Swift
Embedded toolchain, and VirtualBox), offers to install anything missing, then builds the image and
converts it to `build/swift-os.vdi`. Use `./run_in_virtual_box.sh --check` to only report what is
missing, or `-y` to auto-accept installs. After it finishes, jump to step 3 (create the VM).

The manual steps below are what that script automates.

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

## Observed VirtualBox ARM machine model (7.2.x preview)

Captured from the VM's `Logs/VBox.log` device tree. These differ fundamentally from the QEMU
`virt` board the kernel currently targets, which is why an unmodified swift-os produces **no**
output here (serial or graphics): the kernel is linked/located for RAM at `0x4000_0000` and talks
to a PL011 at `0x0900_0000`, neither of which exists on this board.

| Resource        | QEMU `virt` (current kernel) | VirtualBox ARM (observed)        |
|-----------------|------------------------------|----------------------------------|
| RAM base        | `0x4000_0000`                | `0x0800_0000` (–`0x17ff_ffff`)   |
| PL011 UART MMIO | `0x0900_0000`                | `0xFFDD_F000`                    |
| GIC             | QEMU layout                  | `0xFCD3_0000`                    |
| Flash (EFI ROM) | n/a (`-kernel`)              | `0x0400_0000`–`0x07ff_ffff`      |
| PL061 GPIO      | —                            | `0xFFDD_D000`                    |
| PL031 RTC       | —                            | `0xFFDD_E000`                    |

VBox ARM also brings up **no graphics console** (headless and GUI both report a 0x0 framebuffer),
so its EFI console is serial-only via the PL011 at `0xFFDD_F000`.

### M10.5 build (done)

The kernel is now buildable for this board: `make BOARD=virtualbox disk` (the default `BOARD=qemu`
is unchanged). The board switch relinks the kernel at `0x0808_0000`, compiles in the VBox HAL
defaults (`platform.swift`), maps the VBox RAM/MMIO split in `kernel/mm/vm.c`, and — because VBox
leaves the PL011 disabled (it is not the EFI console) — explicitly enables it (`uartInit`) before
the banner. `run_in_virtual_box.sh` builds this variant. Verified end-to-end under **QEMU UEFI**
(`make disk-run`): loader → `Hello from Swift kernel` → `M9 platform`, proving the ESP/loader/kernel
chain is correct.

### Open: VBox EFI does not launch our bootloader

The same disk image boots cleanly under QEMU's EDK2/AAVMF firmware but produces **no** output under
VirtualBox — not even the loader's first line written directly to the (now-enabled) PL011. So VBox's
ARM EFI is not starting `\EFI\BOOT\BOOTAA64.EFI` from our GPT/ESP. Suspected cause: the removable-media
fallback boot policy combined with the NVRAM-corruption workaround (deleting the NVRAM to boot also
clears any boot entry). Next step is a VBox-side boot investigation (persisted boot entry / controller
/ ESP layout), independent of the kernel port.

## Troubleshooting

- **VM shows the firmware setup/Boot Manager, no loader text:** the firmware did not find
  `\EFI\BOOT\BOOTAA64.EFI`. Re-check the disk is attached and bootable; in the EFI Boot Manager you can
  also pick the disk manually.
- **`VBoxManage` not found:** it is inside the VirtualBox app bundle
  (`/Applications/VirtualBox.app/Contents/MacOS/VBoxManage`).
- **No serial output but a screen:** the firmware is using the graphics console; screenshot it.
- **`Failed to load the NVRAM store ... VERR_TAR_BAD_CHKSUM_FIELD`:** the VBox 7.2 ARM preview
  sometimes persists a corrupt EFI NVRAM on power-off, which then blocks the next start. Delete the
  VM's NVRAM file before booting — VirtualBox re-initialises a clean one:
  `rm -f "$HOME/VirtualBox VMs/SwiftOS/SwiftOS.nvram"`. Boot entries are not needed; the disk boots
  via the removable-media fallback path `\EFI\BOOT\BOOTAA64.EFI`.
- **Capturing the PL011 console:** on the ARM board, `--uart1 0x3f8 4` (the legacy 16550) is **not**
  the PL011 and captures nothing. The PL011 (`0xFFDD_F000`) is wired to VBox serial port 1; enable it
  in Settings → Serial Ports → Port 1 → Raw File. (No output will appear until the kernel HAL targets
  that address — see the machine-model note above.)

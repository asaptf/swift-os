#!/usr/bin/env bash
# make-disk.sh - build a real bootable GPT disk image with an EFI System
# Partition holding \EFI\BOOT\BOOTAA64.EFI (the swift-os UEFI loader, which
# embeds the kernel). Unlike the QEMU virtual-FAT path, this is a genuine disk
# image: bootable under QEMU+AAVMF, and attachable to VirtualBox / real hardware.
#
# Host tools: sgdisk (gptfdisk) for the GPT, mtools (mformat/mmd/mcopy) to format
# and populate the ESP via byte-offset access (no mount, no root).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
EFI_APP="$BUILD/BOOTAA64.EFI"
KERNEL_BIN="$BUILD/kernel.bin"
ESP_SRC="$BUILD/esp/EFI/swift-os"   # U1g-2: staged kernel A/B slots + boot manifest
IMG="${1:-$BUILD/swift-os.img}"
SIZE_MB="${DISK_MB:-96}"
PART_START_SECTOR=2048
PART_OFFSET=$((PART_START_SECTOR * 512))

SGDISK="${SGDISK:-/opt/homebrew/bin/sgdisk}"
MFORMAT="${MFORMAT:-/opt/homebrew/bin/mformat}"
MMD="${MMD:-/opt/homebrew/bin/mmd}"
MCOPY="${MCOPY:-/opt/homebrew/bin/mcopy}"
MDIR="${MDIR:-/opt/homebrew/bin/mdir}"

[[ -f "$EFI_APP" ]] || { echo "make-disk: $EFI_APP missing - run 'make uefi' first" >&2; exit 2; }
[[ -f "$KERNEL_BIN" ]] || { echo "make-disk: $KERNEL_BIN missing - run 'make build' first" >&2; exit 2; }
for f in kernelA.bin kernelB.bin kernel-boot kernel-boot-alt; do
    [[ -f "$ESP_SRC/$f" ]] || { echo "make-disk: $ESP_SRC/$f missing - run 'make uefi' first" >&2; exit 2; }
done
for tool in "$SGDISK" "$MFORMAT" "$MMD" "$MCOPY" "$MDIR"; do
    [[ -x "$tool" ]] || { echo "make-disk: missing executable $tool" >&2; exit 2; }
done

echo "make-disk: creating ${SIZE_MB}MiB image at $IMG"
rm -f "$IMG"
if command -v mkfile >/dev/null 2>&1; then
    mkfile -n "${SIZE_MB}m" "$IMG"
else
    truncate -s "${SIZE_MB}M" "$IMG"
fi

echo "make-disk: writing GPT with one EFI System Partition"
"$SGDISK" -Z "$IMG" >/dev/null
"$SGDISK" -n 1:${PART_START_SECTOR}:0 -t 1:EF00 -c 1:"swift-os ESP" "$IMG" >/dev/null

echo "make-disk: formatting + populating the ESP (FAT32)"
# mtools accesses the partition at a byte offset inside the image (drive@@offset).
export MTOOLS_SKIP_CHECK=1
"$MFORMAT" -i "${IMG}@@${PART_OFFSET}" -F -v ESP ::
"$MMD"     -i "${IMG}@@${PART_OFFSET}" ::/EFI ::/EFI/BOOT ::/EFI/swift-os
"$MCOPY"   -i "${IMG}@@${PART_OFFSET}" "$EFI_APP" ::/EFI/BOOT/BOOTAA64.EFI
# U1g-2: the kernel A/B slots + boot manifest the loader reads from the ESP.
"$MCOPY"   -i "${IMG}@@${PART_OFFSET}" "$ESP_SRC/kernelA.bin"  ::/EFI/swift-os/kernelA.bin
"$MCOPY"   -i "${IMG}@@${PART_OFFSET}" "$ESP_SRC/kernelB.bin"  ::/EFI/swift-os/kernelB.bin
"$MCOPY"   -i "${IMG}@@${PART_OFFSET}" "$ESP_SRC/kernel-boot"  ::/EFI/swift-os/kernel-boot
"$MCOPY"   -i "${IMG}@@${PART_OFFSET}" "$ESP_SRC/kernel-boot-alt" ::/EFI/swift-os/kernel-boot-alt

echo "make-disk: done -> $IMG"
echo "make-disk: ESP contents:"
"$MDIR" -i "${IMG}@@${PART_OFFSET}" ::/EFI/BOOT
"$MDIR" -i "${IMG}@@${PART_OFFSET}" ::/EFI/swift-os
ls -l "$IMG"

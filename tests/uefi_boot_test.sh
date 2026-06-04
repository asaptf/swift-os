#!/usr/bin/env bash
# uefi_boot_test.sh - M10a acceptance: boot the UEFI loader under real firmware.
#
# Boots QEMU `virt` with the prebuilt AAVMF/edk2 firmware (NOT `-kernel`). The
# firmware mounts the EFI System Partition (served as virtual FAT from a
# directory) and launches \EFI\BOOT\BOOTAA64.EFI. We capture the serial console
# and assert the loader ran, located the device tree, and proved the early
# handoff facts needed by the next ExitBootServices step.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ESP_DIR="$ROOT/build/esp"
EFI_APP="$ESP_DIR/EFI/BOOT/BOOTAA64.EFI"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
TIMEOUT="${TIMEOUT:-30}"

EXPECTS="${EXPECTS:-swift-os UEFI loader (M10a)
UEFI: device tree found at 0x
UEFI: M10a OK loader reached firmware handoff point
UEFI: CurrentEL 0x0000000000000001
UEFI: AllocatePages(0x40080000) status 0x0000000000000000
UEFI: M10b-prep OK fixed kernel load address reserved}"

if [[ ! -f "$EFI_APP" ]]; then
    echo "FAIL: $EFI_APP not found - run 'make uefi' first." >&2
    exit 2
fi
if [[ ! -f "$AAVMF_CODE" ]]; then
    echo "FAIL: AAVMF firmware not found at $AAVMF_CODE (override with AAVMF_CODE=)." >&2
    exit 2
fi

LOG="$(mktemp -t swiftos-uefi.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

# acpi=off boots the firmware in device-tree mode so it publishes the FDT
# configuration table the loader reads (swift-os is a device-tree OS).
"$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
        -bios "$AAVMF_CODE" \
        -drive file=fat:rw:"$ESP_DIR",format=raw,if=virtio >"$LOG" 2>&1 &
QEMU_PID=$!

all_found() {
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qF "$line" "$LOG" 2>/dev/null || return 1
    done <<<"$EXPECTS"
    return 0
}

found=0
for _ in $(seq 1 "$((TIMEOUT * 10))"); do
    if all_found; then found=1; break; fi
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 0.1
done

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

if [[ "$found" -eq 1 ]]; then
    echo "PASS: UEFI loader booted under AAVMF and proved the handoff prep"
    while IFS= read -r line; do [[ -n "$line" ]] && echo "  - $line"; done <<<"$EXPECTS"
    exit 0
fi

echo "FAIL: expected UEFI loader output not seen within ${TIMEOUT}s. Serial log was:" >&2
echo "---------------------------------------------" >&2
cat -v "$LOG" >&2
echo "---------------------------------------------" >&2
exit 1

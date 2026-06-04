#!/usr/bin/env bash
# uefi_boot_test.sh - M10 acceptance: boot to busybox from disk via UEFI firmware.
#
# Boots QEMU `virt` with the prebuilt AAVMF/edk2 firmware (NOT `-kernel`). The
# firmware loads \EFI\BOOT\BOOTAA64.EFI from the EFI System Partition (served as
# virtual FAT); the loader locates the device tree, stages the embedded kernel,
# ExitBootServices, and jumps into it. We then drive the kernel exactly like the
# `-kernel` busybox test (satisfy the M7 tty demo, then run echo/ls/cat in the
# busybox shell) and assert the whole UEFI -> kernel -> userland path.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ESP_DIR="$ROOT/build/esp"
EFI_APP="$ESP_DIR/EFI/BOOT/BOOTAA64.EFI"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"

[[ -f "$EFI_APP" ]] || { echo "FAIL: $EFI_APP missing (run 'make uefi')" >&2; exit 2; }
[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }

LOG="$(mktemp -t swiftos-uefi.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

# acpi=off -> firmware publishes the FDT table the loader hands to the kernel.
(
  sleep 11; printf 'tty-line\n'          # M7 ttydemo: a line (firmware adds boot latency)
  sleep 1;  printf '\003'                # Ctrl-C -> ttydemo exits, busybox starts
  sleep 2;  printf 'echo M10-UEFI-OK\n'
  sleep 1;  printf 'ls /\n'
  sleep 1;  printf 'cat /etc/motd\n'
  sleep 1;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
        -bios "$AAVMF_CODE" \
        -drive file=fat:rw:"$ESP_DIR",format=raw,if=virtio >"$LOG" 2>&1 &
QP=$!
sleep 24
kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null

ok=1
check() { grep -qF "$1" "$LOG" || { echo "FAIL: missing '$1'" >&2; ok=0; }; }
check "swift-os UEFI loader (M10)"            # loader ran under firmware
check "UEFI: kernel staged, launching"        # ExitBootServices handoff
check "Hello from Swift kernel"               # kernel entered via UEFI
check "M9 OK: hardware discovered from device tree"  # DTB the loader passed
check "built-in shell (ash)"                  # busybox came up
check "M10-UEFI-OK"                           # echo applet
check "readme.txt"                            # ls applet
grep -c "Welcome to swift-os." "$LOG" | grep -qvx 0 || { echo "FAIL: cat applet" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
    echo "PASS: UEFI firmware booted swift-os to busybox from disk (M10 acceptance)"
    exit 0
fi
echo "--- serial log ---" >&2
sed 's/\r//' "$LOG" >&2
exit 1
